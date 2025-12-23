# Remaining Implementation Items

This document details the three incomplete items from REFACTORING_STRATEGY.md Phase 4b.

---

## Overview

| Item | Phase | Difficulty | Dependencies |
|------|-------|------------|--------------|
| Input metering | 4b-4 | Medium | None |
| meter/clearClip | 4b-4 | Easy | Input metering |
| metronome/setVolume | 4b-5 | Medium | None |

---

## 1. Input Metering

### Purpose

Provide real-time peak level data for record-armed tracks with input monitoring enabled. Used for:
- Visual level meters in the client UI
- Clip detection with sticky indicator

### REAPER APIs Required

Add to `reaper.zig`:

```zig
// In Api struct fields:
track_GetPeakInfo: ?*const fn (?*anyopaque, c_int) callconv(.c) f64 = null,
track_GetPeakHoldDB: ?*const fn (?*anyopaque, c_int, bool) callconv(.c) f64 = null,

// In Api.load():
.track_GetPeakInfo = getFunc(info, "Track_GetPeakInfo", fn (?*anyopaque, c_int) callconv(.c) f64),
.track_GetPeakHoldDB = getFunc(info, "Track_GetPeakHoldDB", fn (?*anyopaque, c_int, bool) callconv(.c) f64),
```

**API Details:**

| Function | Returns | Notes |
|----------|---------|-------|
| `Track_GetPeakInfo(track, channel)` | `f64` | Peak value: 1.0 = 0dB, 0.0 = -inf. Channel: 0=L, 1=R |
| `Track_GetPeakHoldDB(track, channel, clear)` | `f64` | Hold value in dB×0.01 (0 = 0dB, -100 = -1dB). Set `clear=true` to reset |

### Implementation in tracks.zig

Add `InputMeter` struct and integrate with existing `State`:

```zig
// Maximum armed tracks to meter (keeps polling bounded)
pub const MAX_METERED_TRACKS: usize = 16;

pub const InputMeter = struct {
    track_idx: c_int,
    peak_l: f64,      // 0.0-1.0+ (1.0 = 0dB)
    peak_r: f64,      // 0.0-1.0+
    clipped: bool,    // Sticky flag: true if peak ever exceeded 1.0
};

pub const MeteringState = struct {
    meters: [MAX_METERED_TRACKS]InputMeter = undefined,
    count: usize = 0,

    /// Poll input meters for armed+monitoring tracks only
    /// NOTE: Currently runs at ~30ms with track state. May separate to
    /// higher frequency (10-15ms) if UI smoothness requires it.
    pub fn poll(api: *const reaper.Api, prev: *const MeteringState) MeteringState {
        var state = MeteringState{};
        const track_count: usize = @intCast(@max(0, api.trackCount()));

        for (0..track_count) |i| {
            if (state.count >= MAX_METERED_TRACKS) break;

            const idx: c_int = @intCast(i);
            const track = api.getTrackByIdx(idx) orelse continue;

            // Only meter tracks that are: record armed AND input monitoring enabled
            if (!api.getTrackRecArm(track)) continue;
            if (api.getTrackRecMon(track) == 0) continue;

            const peak_l = api.getTrackPeakInfo(track, 0);
            const peak_r = api.getTrackPeakInfo(track, 1);

            // Preserve sticky clip flag from previous state
            var clipped = peak_l > 1.0 or peak_r > 1.0;
            if (!clipped) {
                // Check if this track was clipped before
                for (prev.meters[0..prev.count]) |m| {
                    if (m.track_idx == idx and m.clipped) {
                        clipped = true;
                        break;
                    }
                }
            }

            state.meters[state.count] = .{
                .track_idx = idx,
                .peak_l = peak_l,
                .peak_r = peak_r,
                .clipped = clipped,
            };
            state.count += 1;
        }
        return state;
    }

    pub fn clearClip(self: *MeteringState, track_idx: c_int) void {
        for (self.meters[0..self.count]) |*m| {
            if (m.track_idx == track_idx) {
                m.clipped = false;
                return;
            }
        }
    }
};
```

### Wrapper Methods in reaper.zig

```zig
/// Get track peak level (1.0 = 0dB, 0.0 = -inf)
pub fn getTrackPeakInfo(self: *const Api, track: *anyopaque, channel: c_int) f64 {
    const f = self.track_GetPeakInfo orelse return 0.0;
    return f(track, channel);
}

/// Get track peak hold in dB×0.01, optionally clearing the hold
pub fn getTrackPeakHoldDB(self: *const Api, track: *anyopaque, channel: c_int, clear: bool) f64 {
    const f = self.track_GetPeakHoldDB orelse return -10000.0;
    return f(track, channel, clear);
}
```

### JSON Event Format

Include metering in the existing `tracks` event:

```json
{
  "type": "event",
  "event": "tracks",
  "payload": {
    "tracks": [...],
    "meters": [
      {"trackIdx": 0, "peakL": 0.75, "peakR": 0.68, "clipped": false},
      {"trackIdx": 2, "peakL": 1.02, "peakR": 0.95, "clipped": true}
    ]
  }
}
```

### Change Detection

Metering values change constantly during recording/monitoring. Options:

1. **Always send meters** - Simple, slight bandwidth overhead
2. **Threshold-based** - Only send if change > 0.01 (may miss transients)
3. **Separate event** - Metering at higher rate, track state at lower rate

**Recommendation:** Start with option 1 (always send). Add comment about potential separation.

---

## 2. meter/clearClip Command

### Purpose

Reset the sticky clip indicator for a specific track.

### Command Format

```json
{
  "type": "command",
  "command": "meter/clearClip",
  "id": "optional-correlation-id",
  "payload": {
    "trackIdx": 0
  }
}
```

### Implementation in commands/tracks.zig

```zig
// Add to handlers array:
.{ .name = "meter/clearClip", .handler = handleClearClip },

fn handleClearClip(api: *const reaper.Api, msg: protocol.CommandMessage, writer: *mod.ResponseWriter) void {
    const track_idx = msg.getInt("trackIdx") orelse {
        writer.err("INVALID_PARAMS", "trackIdx required");
        return;
    };

    // Clear the sticky flag in metering state
    // This requires access to the shared metering state - see integration notes below

    // Optionally also clear REAPER's internal peak hold:
    if (api.getTrackByIdx(@intCast(track_idx))) |track| {
        _ = api.getTrackPeakHoldDB(track, 0, true);  // Clear L
        _ = api.getTrackPeakHoldDB(track, 1, true);  // Clear R
    }

    writer.ok(null);
}
```

### Integration Notes

The `clearClip` command needs to modify `MeteringState`, which is polled in `main.zig`. Options:

1. **Pass metering state to command handler** - Requires signature change
2. **Use atomic flag** - Track indices to clear, polled in main loop
3. **Just clear REAPER's hold** - Let next poll pick up the cleared state

**Recommendation:** Option 3 is simplest. The next poll (within 30ms) will see the cleared REAPER hold and update the sticky flag accordingly.

---

## 3. metronome/setVolume Command

### Purpose

Get and set the metronome (click track) volume programmatically.

### REAPER APIs Required

The metronome volume is stored in project config variables, not a direct API:

```zig
// In Api struct fields:
projectconfig_var_getoffs: ?*const fn ([*:0]const u8, ?*c_int) callconv(.c) c_int = null,
projectconfig_var_addr: ?*const fn (?*anyopaque, c_int) callconv(.c) ?*anyopaque = null,

// In Api.load():
.projectconfig_var_getoffs = getFunc(info, "projectconfig_var_getoffs", fn ([*:0]const u8, ?*c_int) callconv(.c) c_int),
.projectconfig_var_addr = getFunc(info, "projectconfig_var_addr", fn (?*anyopaque, c_int) callconv(.c) ?*anyopaque),
```

### Config Variables

| Variable | Type | Description |
|----------|------|-------------|
| `projmetrov1` | f64 | Primary beat volume (linear amplitude) |
| `projmetrov2` | f64 | Secondary beat volume (linear amplitude) |

### Volume Scale Conversion

REAPER stores linear amplitude. Client UI uses dB. The metronome range is approximately **-inf to +12dB**.

**Conversion formulas:**

```zig
const MIN_DB: f64 = -60.0;  // Treat as -inf below this
const MAX_DB: f64 = 12.0;

/// Convert linear amplitude to dB
fn linearToDb(linear: f64) f64 {
    if (linear <= 0.0) return MIN_DB;
    const db = 20.0 * @log10(linear);
    return @max(MIN_DB, @min(MAX_DB, db));
}

/// Convert dB to linear amplitude
fn dbToLinear(db: f64) f64 {
    if (db <= MIN_DB) return 0.0;
    return std.math.pow(f64, 10.0, db / 20.0);
}
```

**Reference values:**

| dB | Linear |
|----|--------|
| -inf | 0.0 |
| -12 | 0.251 |
| -6 | 0.501 |
| 0 | 1.0 |
| +6 | 1.995 |
| +12 | 3.981 |

### Wrapper Methods in reaper.zig

```zig
/// Get metronome primary beat volume (linear amplitude)
pub fn getMetronomeVolume(self: *const Api) f64 {
    const getoffs = self.projectconfig_var_getoffs orelse return 1.0;
    const getaddr = self.projectconfig_var_addr orelse return 1.0;

    var sz: c_int = 0;
    const offs = getoffs("projmetrov1", &sz);
    if (offs < 0) return 1.0;
    if (sz != 8) return 1.0;  // sizeof(f64)

    const ptr = getaddr(null, offs) orelse return 1.0;
    const vol_ptr: *f64 = @ptrCast(@alignCast(ptr));
    return vol_ptr.*;
}

/// Set metronome primary beat volume (linear amplitude)
pub fn setMetronomeVolume(self: *const Api, vol: f64) bool {
    const getoffs = self.projectconfig_var_getoffs orelse return false;
    const getaddr = self.projectconfig_var_addr orelse return false;

    var sz: c_int = 0;
    const offs = getoffs("projmetrov1", &sz);
    if (offs < 0) return false;
    if (sz != 8) return false;

    const ptr = getaddr(null, offs) orelse return false;
    const vol_ptr: *f64 = @ptrCast(@alignCast(ptr));

    // Clamp to valid range (0.0 to ~4.0 for +12dB max)
    vol_ptr.* = @max(0.0, @min(4.0, vol));
    return true;
}
```

### Command Implementation in commands/metronome.zig

```zig
// Add to handlers array:
.{ .name = "metronome/getVolume", .handler = handleGetVolume },
.{ .name = "metronome/setVolume", .handler = handleSetVolume },

fn handleGetVolume(api: *const reaper.Api, _: protocol.CommandMessage, writer: *mod.ResponseWriter) void {
    const linear = api.getMetronomeVolume();
    const db = linearToDb(linear);

    var buf: [128]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"volume\":{d:.6},\"volumeDb\":{d:.2}}}", .{ linear, db }) catch {
        writer.err("INTERNAL", "Buffer overflow");
        return;
    };
    writer.ok(json);
}

fn handleSetVolume(api: *const reaper.Api, msg: protocol.CommandMessage, writer: *mod.ResponseWriter) void {
    // Accept either volumeDb (preferred) or volume (linear)
    var linear: f64 = undefined;

    if (msg.getFloat("volumeDb")) |db| {
        linear = dbToLinear(db);
    } else if (msg.getFloat("volume")) |vol| {
        linear = vol;
    } else {
        writer.err("INVALID_PARAMS", "volumeDb or volume required");
        return;
    }

    if (api.setMetronomeVolume(linear)) {
        writer.ok(null);
    } else {
        writer.err("FAILED", "Could not set metronome volume");
    }
}
```

### Command Formats

**Get volume:**
```json
{"type": "command", "command": "metronome/getVolume", "id": "123"}
```

**Response:**
```json
{"type": "response", "id": "123", "success": true, "payload": {"volume": 0.501, "volumeDb": -6.0}}
```

**Set volume (dB - preferred):**
```json
{"type": "command", "command": "metronome/setVolume", "payload": {"volumeDb": -6.0}}
```

**Set volume (linear - fallback):**
```json
{"type": "command", "command": "metronome/setVolume", "payload": {"volume": 0.501}}
```

### Transport Event Integration

Add metronome volume to the transport event so clients stay in sync:

```json
{
  "type": "event",
  "event": "transport",
  "payload": {
    "playState": 0,
    "position": 12.5,
    "metronome": {
      "enabled": true,
      "volume": 0.501,
      "volumeDb": -6.0
    }
  }
}
```

This requires polling `getMetronomeVolume()` in the transport state module.

---

## Implementation Order

1. **Input metering** (tracks.zig, reaper.zig)
   - Add REAPER API bindings
   - Add MeteringState struct
   - Integrate with track polling
   - Add to tracks event JSON

2. **meter/clearClip** (commands/tracks.zig)
   - Add command handler
   - Use REAPER's peak hold clear

3. **metronome/setVolume** (reaper.zig, commands/metronome.zig, transport.zig)
   - Add projectconfig_var APIs
   - Add wrapper methods with dB conversion
   - Add getVolume/setVolume commands
   - Add to transport event

---

## Testing

### Input Metering
1. Arm a track for recording with input monitoring on
2. Connect WebSocket client
3. Verify `meters` array appears in tracks event
4. Feed audio input, verify peak values update
5. Clip the input, verify `clipped: true`
6. Send `meter/clearClip`, verify flag resets

### Metronome Volume
1. Get current volume via `metronome/getVolume`
2. Compare with REAPER UI slider position
3. Set volume to -6dB via `metronome/setVolume`
4. Verify REAPER UI updates
5. Toggle metronome, verify volume persists

---

## Design Decisions

| Question | Decision |
|----------|----------|
| Secondary beat volume (`projmetrov2`) | Skip for v1 - rarely needed, users can access via REAPER UI |
| Meter smoothing/ballistics | Client-side - extension sends raw peaks, client applies smoothing as needed |
| Clip threshold | 0dB (linear 1.0) - industry standard |
