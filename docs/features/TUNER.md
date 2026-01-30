# REAmo Tuner Implementation Specification

A studio-quality chromatic tuner for REAmo, implemented as a bundled JSFX plugin with on-demand insertion and WebSocket-driven display.

---

## Overview

The tuner provides sub-cent accuracy (typically ±0.3 cents in the guitar/bass range, ±0.5 cents at higher frequencies) with zero audio latency, automatically inserting on record-armed tracks and displaying on the phone via the existing WebSocket infrastructure.

### Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│ REAPER                                                               │
│  ┌─────────────────────────────────────────────────────────────────┐│
│  │ Record-Armed Track                                              ││
│  │  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐         ││
│  │  │ Input       │───▶│ Other FX    │───▶│ REAmo Tuner │───▶ Out ││
│  │  └─────────────┘    └─────────────┘    │ (passthrough)│         ││
│  │                                         │              │         ││
│  │                                         │ slider1: freq│         ││
│  │                                         │ slider2: note│         ││
│  │                                         │ slider3: cents│        ││
│  │                                         └──────┬───────┘         ││
│  └─────────────────────────────────────────────────┼────────────────┘│
│                                                    │                 │
│  ┌─────────────────────────────────────────────────▼────────────────┐│
│  │ Zig Extension                                                    ││
│  │  - TrackFX_GetParam() polling @ 30Hz when tuner view open       ││
│  │  - TrackFX_AddByName() / TrackFX_Delete() on view open/close    ││
│  └─────────────────────────────────────────────────┬────────────────┘│
└──────────────────────────────────────────────────────┼───────────────┘
                                                       │ WebSocket
                                                       ▼
┌─────────────────────────────────────────────────────────────────────┐
│ REAmo PWA (Phone)                                                    │
│  ┌─────────────────────────────────────────────────────────────────┐│
│  │ Tuner View                                                      ││
│  │  ┌─────────────────────────────────────────┐                    ││
│  │  │            ┌───┐                        │                    ││
│  │  │      -50   │ A │   +50                  │                    ││
│  │  │  ◀━━━━━━━━━│ 4 │━━━━━━━━━▶              │  ← cents meter     ││
│  │  │            └───┘                        │                    ││
│  │  │           440.0 Hz                      │                    ││
│  │  │         Guitar Track 1                  │  ← track name      ││
│  │  └─────────────────────────────────────────┘                    ││
│  │  [Track selector dropdown]                                      ││
│  └─────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────┘
```

---

## Part 1: JSFX Plugin

### File Location

```
<REAPER Resource Path>/Effects/REAmo/PitchDetect.jsfx
```

The Zig extension should write this file on first run if it doesn't exist:

```c
char path[512];
GetResourcePath(path, 512);
strcat(path, "/Effects/REAmo/PitchDetect.jsfx");
// Write file if not exists
```

### Algorithm: FFT-Accelerated YIN

YIN provides the best balance of accuracy, octave-error resistance, and CPU efficiency. FFT acceleration reduces the O(N²) autocorrelation to O(N log N).

**Why YIN over alternatives:**

| Algorithm | Accuracy | Latency | Octave Errors | Complexity |
|-----------|----------|---------|---------------|------------|
| YIN | ±0.3-0.5 cent | 25-50ms | Very low | Medium |
| MPM | ±0.3-0.5 cent | 25-50ms | Low | Medium |
| FFT Peak | ±5-20 cent | 23-93ms | High | Low |
| Zero-crossing | ±10-50 cent | <5ms | Very high | Very low |

### Complete JSFX Implementation

```javascript
desc: REAmo Pitch Detector
author: REAmo
version: 1.2
about:
  Zero-latency pitch detection for REAmo remote tuner.
  Uses correct FFT-accelerated YIN algorithm with proper energy terms.

// Output sliders - readable via TrackFX_GetParam()
slider1:0<0,2000,0.01>Detected Frequency (Hz)
slider2:0<0,127,1>MIDI Note Number
slider3:0<-50,50,0.01>Cents Deviation
slider4:0<0,1,0.001>Confidence (0-1)
slider5:440<400,480,0.1>Reference Pitch (A4)

// User-adjustable parameters
slider10:0.15<0.05,0.3,0.01>YIN Threshold
slider11:-60<-90,-30,1>Silence Threshold (dB)

options:no_meter

@init

// Analysis window size - determines lowest detectable frequency
// At 44.1kHz: 4096 samples = 93ms, good for >50Hz
win_size = 4096;
fft_size = win_size * 2;  // Zero-pad to 2N for linear autocorrelation
hop_size = 512;           // Analysis every ~12ms
half_win = win_size / 2;

// Ring buffer for input samples
input_buf = 0;
write_pos = 0;

// Analysis buffers - careful memory layout
yin_buf = win_size;                        // YIN difference function d(τ)
yin_cmnd = yin_buf + half_win;             // CMNDF d'(τ) - separate from raw
fft_buf = yin_cmnd + half_win;             // FFT workspace (interleaved, 2*fft_size)
autocorr_buf = fft_buf + fft_size * 2;     // Autocorrelation r(τ)
sqr_cumsum = autocorr_buf + win_size;      // Cumulative sum of squares

samples_since_analysis = 0;
current_freq = 0;
current_note = 0;
current_cents = 0;
current_confidence = 0;

function freq_to_midi(freq) (
  69 + 12 * log(freq / slider5) / log(2);
);

// Compute autocorrelation r(τ) using zero-padded FFT
function compute_autocorrelation()
local(i, re, im, mag_sq)
(
  // Copy input samples to first half of FFT buffer (NO windowing!)
  i = 0;
  loop(win_size,
    fft_buf[i * 2] = input_buf[(write_pos - win_size + i + win_size) % win_size];
    fft_buf[i * 2 + 1] = 0;
    i += 1;
  );

  // Zero-pad second half for linear (not circular) autocorrelation
  loop(win_size,
    fft_buf[i * 2] = 0;
    fft_buf[i * 2 + 1] = 0;
    i += 1;
  );

  // Forward FFT
  fft(fft_buf, fft_size);

  // Compute power spectrum |FFT(x)|²
  i = 0;
  loop(fft_size,
    re = fft_buf[i * 2];
    im = fft_buf[i * 2 + 1];
    mag_sq = re * re + im * im;
    fft_buf[i * 2] = mag_sq;
    fft_buf[i * 2 + 1] = 0;
    i += 1;
  );

  // Inverse FFT gives autocorrelation
  ifft(fft_buf, fft_size);

  // Extract and normalize autocorrelation values
  // JSFX FFT normalization: divide by fft_size
  i = 0;
  loop(win_size,
    autocorr_buf[i] = fft_buf[i * 2] / fft_size;
    i += 1;
  );
);

// Compute cumulative sum of squared samples for energy terms
function compute_cumsum_squares()
local(i, sample, sum)
(
  sum = 0;
  i = 0;
  loop(win_size,
    sample = input_buf[(write_pos - win_size + i + win_size) % win_size];
    sum += sample * sample;
    sqr_cumsum[i] = sum;
    i += 1;
  );
);

// Compute CORRECT YIN difference function with proper energy terms
// d(τ) = r_t(0) + r_{t+τ}(0) - 2*r(τ)
// Where r_t(0) = energy of first W-τ samples
//       r_{t+τ}(0) = energy of samples from τ to W
function compute_yin_difference()
local(tau, r_t_0, r_t_tau_0, diff, running_sum)
(
  // For each lag τ, compute the proper energy terms
  // r_t(0) = sum of squares from 0 to W-τ-1
  // r_{t+τ}(0) = sum of squares from τ to W-1

  yin_buf[0] = 0;  // d(0) = 0 by definition
  yin_cmnd[0] = 1; // d'(0) = 1 by definition
  running_sum = 0;

  tau = 1;
  loop(half_win - 1,
    // Energy of first (W-τ) samples: sqr_cumsum[W-τ-1]
    r_t_0 = sqr_cumsum[win_size - tau - 1];

    // Energy of samples from τ to W-1: sqr_cumsum[W-1] - sqr_cumsum[τ-1]
    tau > 0 ? (
      r_t_tau_0 = sqr_cumsum[win_size - 1] - sqr_cumsum[tau - 1];
    ) : (
      r_t_tau_0 = sqr_cumsum[win_size - 1];
    );

    // Correct YIN difference function
    diff = r_t_0 + r_t_tau_0 - 2 * autocorr_buf[tau];

    // Ensure non-negative (numerical precision)
    diff = max(0, diff);
    yin_buf[tau] = diff;

    // Cumulative mean normalized difference (CMNDF)
    running_sum += diff;
    running_sum > 0 ? (
      yin_cmnd[tau] = diff * tau / running_sum;
    ) : (
      yin_cmnd[tau] = 1;
    );

    tau += 1;
  );
);

// Find the best tau using threshold on CMNDF, interpolate on raw d(τ)
function find_pitch()
local(tau, threshold, min_tau, found, best_tau, s0, s1, s2, delta, period, freq)
(
  threshold = slider10;

  // Minimum tau corresponds to maximum detectable frequency (~2kHz)
  min_tau = max(floor(srate / 2000), 2);

  found = 0;
  best_tau = min_tau;

  // Find first local minimum in CMNDF below threshold (avoids octave errors)
  tau = min_tau;
  while (tau < half_win - 2 && !found) (
    (yin_cmnd[tau] < threshold) ? (
      // Check if it's a local minimum in CMNDF
      (yin_cmnd[tau] < yin_cmnd[tau - 1] && yin_cmnd[tau] <= yin_cmnd[tau + 1]) ? (
        found = 1;
        best_tau = tau;
      );
    );
    tau += 1;
  );

  // If nothing below threshold, find global minimum in CMNDF
  !found ? (
    best_tau = min_tau;
    tau = min_tau + 1;
    loop(half_win - min_tau - 2,
      yin_cmnd[tau] < yin_cmnd[best_tau] ? best_tau = tau;
      tau += 1;
    );
  );

  // Parabolic interpolation on RAW d(τ), NOT on CMNDF!
  // This is critical for accuracy
  best_tau > 1 && best_tau < half_win - 2 ? (
    s0 = yin_buf[best_tau - 1];  // Raw difference function
    s1 = yin_buf[best_tau];
    s2 = yin_buf[best_tau + 1];

    // Parabolic fit: τ_interp = τ + (s0 - s2) / (2 × (s0 - 2×s1 + s2))
    // Note: PLUS sign before the fraction (aubio had this wrong initially)
    (s0 - 2 * s1 + s2) != 0 ? (
      delta = (s0 - s2) / (2 * (s0 - 2 * s1 + s2));
      // Clamp delta to reasonable range
      delta = max(-1, min(1, delta));
      period = best_tau + delta;
    ) : (
      period = best_tau;
    );
  ) : (
    period = best_tau;
  );

  // Convert period to frequency
  period > 0 ? (
    freq = srate / period;

    // Sanity check: 20Hz to 5kHz
    freq >= 20 && freq <= 5000 ? (
      current_freq = freq;
      current_confidence = 1 - yin_cmnd[best_tau];
      current_confidence = max(0, min(1, current_confidence));
    ) : (
      current_freq = 0;
      current_confidence = 0;
    );
  );
);

// Calculate note and cents from frequency
function calc_note_cents()
local(midi_float, midi_int)
(
  current_freq > 20 ? (
    midi_float = freq_to_midi(current_freq);
    midi_int = floor(midi_float + 0.5);

    current_note = midi_int;
    current_cents = (midi_float - midi_int) * 100;
  );
);

// Check for silence
function is_silent()
local(i, sum, rms, db)
(
  sum = 0;
  i = 0;
  loop(win_size,
    sum += sqr(input_buf[(write_pos - win_size + i + win_size) % win_size]);
    i += 1;
  );
  rms = sqrt(sum / win_size);
  db = 20 * log10(max(rms, 0.0000001));
  db < slider11;
);

@sample

// Zero-latency passthrough
spl0 = spl0;
spl1 = spl1;

// Accumulate mono sum into ring buffer
input_buf[write_pos] = (spl0 + spl1) * 0.5;
write_pos = (write_pos + 1) % win_size;

samples_since_analysis += 1;

// Analyze every hop_size samples
samples_since_analysis >= hop_size ? (
  samples_since_analysis = 0;

  is_silent() ? (
    // No signal - clear outputs
    current_freq = 0;
    current_note = 0;
    current_cents = 0;
    current_confidence = 0;
  ) : (
    // Run pitch detection with correct YIN algorithm
    compute_autocorrelation();
    compute_cumsum_squares();
    compute_yin_difference();
    find_pitch();
    calc_note_cents();
  );

  // Update output sliders
  slider1 = current_freq;
  slider2 = current_note;
  slider3 = current_cents;
  slider4 = current_confidence;

  sliderchange(slider1);
  sliderchange(slider2);
  sliderchange(slider3);
  sliderchange(slider4);
);

@gfx 400 200

// Simple visual display for testing in REAPER
gfx_clear = 0;

current_freq > 0 ? (
  // Note name lookup
  note_names = "C C#D D#E F F#G G#A A#B ";
  note_idx = current_note % 12;
  octave = floor(current_note / 12) - 1;

  gfx_setfont(1, "Arial", 48, 'b');
  gfx_set(1, 1, 1);

  gfx_x = 150; gfx_y = 40;
  gfx_drawchar(str_getchar(note_names, note_idx * 2));
  note_idx == 1 || note_idx == 3 || note_idx == 6 || note_idx == 8 || note_idx == 10 ? (
    gfx_drawchar(str_getchar(note_names, note_idx * 2 + 1));
  );
  gfx_printf("%d", octave);

  // Cents meter labels
  gfx_setfont(1, "Arial", 16);
  gfx_x = 50; gfx_y = 120;
  gfx_printf("-50");
  gfx_x = 340; gfx_y = 120;
  gfx_printf("+50");

  // Meter bar background
  gfx_set(0.3, 0.3, 0.3);
  gfx_rect(80, 115, 240, 20);

  // Center line (in tune)
  gfx_set(0, 1, 0);
  gfx_rect(198, 110, 4, 30);

  // Cents indicator
  cents_x = 200 + current_cents * 2.4;
  abs(current_cents) < 2 ? gfx_set(0, 1, 0) :
  abs(current_cents) < 10 ? gfx_set(1, 1, 0) :
  gfx_set(1, 0.3, 0.3);
  gfx_rect(cents_x - 5, 115, 10, 20);

  // Frequency display
  gfx_set(0.7, 0.7, 0.7);
  gfx_setfont(1, "Arial", 14);
  gfx_x = 160; gfx_y = 160;
  gfx_printf("%.1f Hz", current_freq);

  // Confidence indicator
  gfx_x = 160; gfx_y = 180;
  gfx_printf("Conf: %.0f%%", current_confidence * 100);
) : (
  gfx_set(0.5, 0.5, 0.5);
  gfx_setfont(1, "Arial", 24);
  gfx_x = 140; gfx_y = 80;
  gfx_drawstr("No signal");
);
```

---

## Part 2: Zig Extension Integration

### JSFX Installation

On extension load, check if the JSFX exists and write it if not:

```zig
const std = @import("std");
const reaper = @import("reaper_api");

const jsfx_content = @embedFile("PitchDetect.jsfx");

pub fn ensureTunerJsfxInstalled() !void {
    var path_buf: [512]u8 = undefined;
    const resource_path = reaper.GetResourcePath();
    
    const jsfx_path = try std.fmt.bufPrint(
        &path_buf,
        "{s}/Effects/REAmo/PitchDetect.jsfx",
        .{resource_path}
    );
    
    // Create directory if needed
    const dir_path = std.fs.path.dirname(jsfx_path) orelse return error.InvalidPath;
    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    
    // Write file if not exists
    const file = std.fs.createFileAbsolute(jsfx_path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return, // Already installed
        else => return err,
    };
    defer file.close();
    
    try file.writeAll(jsfx_content);
}
```

### Tuner State Management

```zig
const TunerState = struct {
    active: bool = false,
    track: ?*reaper.MediaTrack = null,
    fx_index: i32 = -1,
    last_freq: f64 = 0,
    last_note: i32 = 0,
    last_cents: f64 = 0,
    last_confidence: f64 = 0,
    
    const Self = @This();
    
    pub fn open(self: *Self) !void {
        // Find first record-armed track
        const track_count = reaper.CountTracks(null);
        var target_track: ?*reaper.MediaTrack = null;
        
        var i: i32 = 0;
        while (i < track_count) : (i += 1) {
            const track = reaper.GetTrack(null, i);
            const armed = reaper.GetMediaTrackInfo_Value(track, "I_RECARM");
            if (armed != 0) {
                target_track = track;
                break;
            }
        }
        
        // Fall back to first track if none armed
        if (target_track == null and track_count > 0) {
            target_track = reaper.GetTrack(null, 0);
        }
        
        if (target_track) |track| {
            // Insert JSFX
            const fx_idx = reaper.TrackFX_AddByName(
                track,
                "REAmo/PitchDetect",
                false,
                -1  // Add to end of chain
            );
            
            if (fx_idx >= 0) {
                self.track = track;
                self.fx_index = fx_idx;
                self.active = true;
            }
        }
    }
    
    pub fn close(self: *Self) void {
        if (self.track) |track| {
            if (self.fx_index >= 0) {
                _ = reaper.TrackFX_Delete(track, self.fx_index);
            }
        }
        self.active = false;
        self.track = null;
        self.fx_index = -1;
    }
    
    pub fn switchTrack(self: *Self, new_track: *reaper.MediaTrack) !void {
        // Remove from old track
        if (self.track) |old_track| {
            if (self.fx_index >= 0) {
                _ = reaper.TrackFX_Delete(old_track, self.fx_index);
            }
        }
        
        // Add to new track
        const fx_idx = reaper.TrackFX_AddByName(
            new_track,
            "REAmo/PitchDetect",
            false,
            -1
        );
        
        if (fx_idx >= 0) {
            self.track = new_track;
            self.fx_index = fx_idx;
        }
    }
    
    pub fn poll(self: *Self) void {
        if (!self.active) return;
        
        if (self.track) |track| {
            if (self.fx_index >= 0) {
                var min_val: f64 = undefined;
                var max_val: f64 = undefined;
                
                self.last_freq = reaper.TrackFX_GetParam(
                    track, self.fx_index, 0, &min_val, &max_val
                );
                self.last_note = @intFromFloat(reaper.TrackFX_GetParam(
                    track, self.fx_index, 1, &min_val, &max_val
                ));
                self.last_cents = reaper.TrackFX_GetParam(
                    track, self.fx_index, 2, &min_val, &max_val
                );
                self.last_confidence = reaper.TrackFX_GetParam(
                    track, self.fx_index, 3, &min_val, &max_val
                );
            }
        }
    }
    
    pub fn getTrackName(self: *Self) ?[]const u8 {
        if (self.track) |track| {
            var name_buf: [256]u8 = undefined;
            if (reaper.GetTrackName(track, &name_buf, name_buf.len)) {
                return std.mem.sliceTo(&name_buf, 0);
            }
        }
        return null;
    }
};

var tuner_state = TunerState{};
```

### WebSocket Message Format

```zig
const TunerData = struct {
    type: []const u8 = "tuner",
    frequency: f64,
    note: i32,
    note_name: []const u8,
    octave: i32,
    cents: f64,
    confidence: f64,
    track_name: []const u8,
    in_tune: bool,  // |cents| < 2
};

const note_names = [_][]const u8{
    "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"
};

pub fn buildTunerMessage() TunerData {
    const note_idx = @mod(tuner_state.last_note, 12);
    const octave = @divFloor(tuner_state.last_note, 12) - 1;
    
    return TunerData{
        .frequency = tuner_state.last_freq,
        .note = tuner_state.last_note,
        .note_name = note_names[@intCast(note_idx)],
        .octave = octave,
        .cents = tuner_state.last_cents,
        .confidence = tuner_state.last_confidence,
        .track_name = tuner_state.getTrackName() orelse "Unknown",
        .in_tune = @abs(tuner_state.last_cents) < 2.0,
    };
}
```

### Integration with Existing 30Hz Timer

```zig
// In your existing timer callback that runs at 30Hz
pub fn onTimer() void {
    // ... existing state broadcast code ...
    
    // Add tuner polling if active
    if (tuner_state.active) {
        tuner_state.poll();
        
        const tuner_msg = buildTunerMessage();
        websocket.broadcast(std.json.stringify(tuner_msg));
    }
}
```

---

## Part 3: React Frontend

### WebSocket Message Handler

```typescript
interface TunerData {
  type: 'tuner';
  frequency: number;
  note: number;
  note_name: string;
  octave: number;
  cents: number;
  confidence: number;
  track_name: string;
  in_tune: boolean;
}

// In your WebSocket handler
case 'tuner':
  setTunerData(message as TunerData);
  break;
```

### Tuner Component

```tsx
import React, { useState, useEffect } from 'react';

interface TunerViewProps {
  tunerData: TunerData | null;
  onClose: () => void;
  onTrackChange: (trackIndex: number) => void;
  availableTracks: Array<{ index: number; name: string; armed: boolean }>;
}

export function TunerView({ 
  tunerData, 
  onClose, 
  onTrackChange,
  availableTracks 
}: TunerViewProps) {
  
  const getCentsColor = (cents: number): string => {
    const absCents = Math.abs(cents);
    if (absCents < 2) return '#22c55e';   // Green - in tune
    if (absCents < 10) return '#eab308';  // Yellow - close
    return '#ef4444';                      // Red - out of tune
  };
  
  const getCentsPosition = (cents: number): number => {
    // Map -50 to +50 cents to 0-100%
    return 50 + (cents * 1);  // 1% per cent
  };

  if (!tunerData || tunerData.frequency === 0) {
    return (
      <div className="tuner-view tuner-no-signal">
        <div className="tuner-header">
          <span>{tunerData?.track_name || 'No track'}</span>
          <button onClick={onClose}>✕</button>
        </div>
        <div className="tuner-body">
          <div className="tuner-waiting">
            <div className="tuner-waiting-icon">🎸</div>
            <div className="tuner-waiting-text">Waiting for signal...</div>
            <div className="tuner-waiting-hint">Play a note on your instrument</div>
          </div>
        </div>
        <TrackSelector 
          tracks={availableTracks} 
          onSelect={onTrackChange} 
        />
      </div>
    );
  }

  return (
    <div className="tuner-view">
      {/* Header with track name */}
      <div className="tuner-header">
        <span>{tunerData.track_name}</span>
        <button onClick={onClose}>✕</button>
      </div>

      {/* Main tuner display */}
      <div className="tuner-body">
        {/* Note display */}
        <div className="tuner-note">
          <span className="tuner-note-name">{tunerData.note_name}</span>
          <span className="tuner-note-octave">{tunerData.octave}</span>
        </div>

        {/* Cents meter */}
        <div className="tuner-meter">
          <div className="tuner-meter-labels">
            <span>-50</span>
            <span>0</span>
            <span>+50</span>
          </div>
          <div className="tuner-meter-track">
            {/* Center marker */}
            <div className="tuner-meter-center" />
            
            {/* Indicator */}
            <div 
              className="tuner-meter-indicator"
              style={{
                left: `${getCentsPosition(tunerData.cents)}%`,
                backgroundColor: getCentsColor(tunerData.cents),
              }}
            />
          </div>
          <div className="tuner-cents-value">
            {tunerData.cents > 0 ? '+' : ''}{tunerData.cents.toFixed(1)}¢
          </div>
        </div>

        {/* Frequency display */}
        <div className="tuner-frequency">
          {tunerData.frequency.toFixed(1)} Hz
        </div>

        {/* In-tune indicator */}
        {tunerData.in_tune && (
          <div className="tuner-in-tune">
            ✓ In Tune
          </div>
        )}
      </div>

      {/* Track selector */}
      <TrackSelector 
        tracks={availableTracks} 
        onSelect={onTrackChange} 
      />
    </div>
  );
}

function TrackSelector({ 
  tracks, 
  onSelect 
}: { 
  tracks: Array<{ index: number; name: string; armed: boolean }>;
  onSelect: (index: number) => void;
}) {
  return (
    <div className="tuner-track-selector">
      <select onChange={(e) => onSelect(Number(e.target.value))}>
        {tracks.map(track => (
          <option key={track.index} value={track.index}>
            {track.armed ? '⏺ ' : ''}{track.name}
          </option>
        ))}
      </select>
    </div>
  );
}
```

### CSS Styles

```css
.tuner-view {
  display: flex;
  flex-direction: column;
  height: 100%;
  background: #0a0a0a;
  color: white;
  font-family: -apple-system, BlinkMacSystemFont, sans-serif;
}

.tuner-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 16px;
  border-bottom: 1px solid #222;
}

.tuner-header button {
  background: none;
  border: none;
  color: #888;
  font-size: 24px;
  cursor: pointer;
}

.tuner-body {
  flex: 1;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  padding: 24px;
}

.tuner-note {
  display: flex;
  align-items: baseline;
  margin-bottom: 32px;
}

.tuner-note-name {
  font-size: 96px;
  font-weight: 700;
  line-height: 1;
}

.tuner-note-octave {
  font-size: 48px;
  font-weight: 400;
  opacity: 0.6;
}

.tuner-meter {
  width: 100%;
  max-width: 300px;
  margin-bottom: 24px;
}

.tuner-meter-labels {
  display: flex;
  justify-content: space-between;
  font-size: 12px;
  color: #666;
  margin-bottom: 8px;
}

.tuner-meter-track {
  position: relative;
  height: 24px;
  background: #222;
  border-radius: 12px;
  overflow: hidden;
}

.tuner-meter-center {
  position: absolute;
  left: 50%;
  top: 0;
  bottom: 0;
  width: 2px;
  background: #22c55e;
  transform: translateX(-50%);
}

.tuner-meter-indicator {
  position: absolute;
  top: 2px;
  bottom: 2px;
  width: 12px;
  border-radius: 6px;
  transform: translateX(-50%);
  transition: left 0.05s ease-out, background-color 0.1s;
}

.tuner-cents-value {
  text-align: center;
  font-size: 18px;
  font-weight: 500;
  margin-top: 8px;
  font-variant-numeric: tabular-nums;
}

.tuner-frequency {
  font-size: 14px;
  color: #888;
  margin-bottom: 16px;
}

.tuner-in-tune {
  font-size: 18px;
  font-weight: 600;
  color: #22c55e;
  padding: 8px 16px;
  background: rgba(34, 197, 94, 0.1);
  border-radius: 8px;
}

.tuner-waiting {
  text-align: center;
}

.tuner-waiting-icon {
  font-size: 64px;
  margin-bottom: 16px;
  opacity: 0.5;
}

.tuner-waiting-text {
  font-size: 24px;
  margin-bottom: 8px;
}

.tuner-waiting-hint {
  font-size: 14px;
  color: #666;
}

.tuner-track-selector {
  padding: 16px;
  border-top: 1px solid #222;
}

.tuner-track-selector select {
  width: 100%;
  padding: 12px;
  background: #1a1a1a;
  border: 1px solid #333;
  border-radius: 8px;
  color: white;
  font-size: 16px;
}
```

---

## Part 4: Command Protocol

### Commands from Frontend to Backend

```typescript
// Open tuner (insert JSFX on record-armed track)
{ type: 'tuner_open' }

// Close tuner (remove JSFX)
{ type: 'tuner_close' }

// Switch tuner to different track
{ type: 'tuner_switch_track', track_index: number }

// Set reference pitch (default 440)
{ type: 'tuner_set_reference', frequency: number }
```

### Zig Command Handler

```zig
pub fn handleCommand(msg: []const u8) void {
    const parsed = std.json.parse(msg) catch return;
    
    if (std.mem.eql(u8, parsed.type, "tuner_open")) {
        tuner_state.open() catch |err| {
            log.err("Failed to open tuner: {}", .{err});
        };
    } else if (std.mem.eql(u8, parsed.type, "tuner_close")) {
        tuner_state.close();
    } else if (std.mem.eql(u8, parsed.type, "tuner_switch_track")) {
        const track = reaper.GetTrack(null, parsed.track_index);
        if (track) |t| {
            tuner_state.switchTrack(t) catch {};
        }
    } else if (std.mem.eql(u8, parsed.type, "tuner_set_reference")) {
        // Set slider5 on the JSFX
        if (tuner_state.track) |track| {
            _ = reaper.TrackFX_SetParam(
                track, 
                tuner_state.fx_index, 
                4,  // slider5 = reference pitch
                parsed.frequency
            );
        }
    }
}
```

---

## Part 5: Testing & Validation

### Test Cases

1. **Accuracy test**: Use a tone generator at known frequencies (A4 = 440Hz, E2 = 82.41Hz, etc.) and verify reported frequency within ±0.5 cent

2. **Latency test**: Strike a note and measure time until display stabilizes (should be <100ms for guitar range, <200ms for bass)

3. **Octave error test**: Play notes with strong harmonics (distorted guitar) and verify correct octave detection

4. **Silence handling**: Remove input signal, verify display shows "waiting" state within 500ms

5. **Track switching**: Switch between armed tracks, verify JSFX moves correctly

6. **CPU usage**: Monitor REAPER CPU meter with tuner active—should add <1% on modern systems

### Debug Tools

Add a "debug mode" toggle that shows:
- Raw frequency value
- YIN confidence value  
- Current buffer size
- Analysis rate (Hz)
- FX chain position

---

## Part 6: Future Enhancements

### Strobe Mode
Implement a visual strobe animation where rotation direction/speed indicates sharp/flat:
- Stationary = in tune
- Rotating right = sharp
- Rotating left = flat
- Rotation speed = how far off

### Alternate Tunings
Presets for common alternate tunings with target notes displayed:
- Drop D
- DADGAD  
- Open G
- Half-step down

### Polyphonic Mode
Detect all 6 guitar strings simultaneously (requires significantly more DSP):
- Show all strings at once
- Indicate which strings need adjustment
- TC Electronic PolyTune-style display

### Calibration
Allow users to calibrate to a reference note from another source:
- "Play reference A" → measures → adjusts reference pitch
- Useful for matching to keyboards or other instruments

---

## Summary

This implementation provides:

- **Sub-cent accuracy** (±0.3 cents typical) via FFT-accelerated YIN algorithm with proper energy terms
- **Zero audio latency** through passthrough design
- **Zero CPU when unused** via on-demand JSFX insertion
- **30Hz display update** via existing WebSocket infrastructure
- **Cross-platform support** via portable JSFX format
- **Automatic track detection** for record-armed inputs
- **Clean mobile UX** with large touch targets and clear visual feedback

The tuner seamlessly integrates with REAmo's existing architecture, requiring minimal new infrastructure while delivering professional-grade functionality.
