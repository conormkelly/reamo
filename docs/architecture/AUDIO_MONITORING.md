# Audio Monitoring Design (Sonobus-Style Listen-Through-Device)

**Status:** Research complete, ready for implementation planning
**Date:** 2026-02-15

Stream REAPER's master output to the phone/tablet so users can hear their mix through their device's speakers or headphones. This is the "Mix Monitoring" feature from the v3.0+ roadmap.

---

## Executive Summary

REAPER exposes `Audio_RegHardwareHook` which gives us real-time access to the master output audio buffer on the audio thread. For the MVP, we stream **raw 16-bit PCM** (no codec) over binary WebSocket frames to the frontend, where a Web Audio API AudioWorklet plays them back. Opus encoding is deferred to a v2 phase.

**Realistic latency target:** 75-160ms over WiFi, 50-100ms over USB tethering. This is NOT Sonobus-level (~20ms, uses UDP). But it's good enough for monitoring a mix while recording, checking playback from across the room, or hearing the click track through earbuds.

**Key constraint:** WebSocket is TCP, not UDP. We get reliability but pay for it with latency. This is a monitoring feature, not a live performance feature.

**Biggest risk:** iOS background audio. `AudioContext` gets suspended when an iOS PWA goes to background or the screen locks. The MVP accepts foreground-only operation with robust reconnection. Background audio requires an `<audio>` element-based approach (Phase 3).

---

## Architecture Overview

```
REAPER Audio Thread (256-1024 samples @ 44.1-96kHz)
    │
    ▼
Audio_RegHardwareHook (OnAudioBuffer callback, isPost=true)
    │ GetBuffer(true, 0) → left channel (f64*)
    │ GetBuffer(true, 1) → right channel (f64*)
    │ Convert f64 → i16, interleave, write to ring buffer
    │
    ▼
Lock-Free SPSC Ring Buffer (audio thread → network thread)
    │ ~500ms capacity, interleaved stereo i16 samples
    │ No allocations, no locks, no I/O in audio callback
    │
    ▼
Network Thread (reads ring buffer, sends to clients)
    │ Reads 5-10ms chunks (480-960 stereo samples = 1,920-3,840 bytes)
    │ Prepends header: sequence (u32) + play position (f64) + sample rate (u32)
    │ Sends as binary WebSocket frame via conn.writeBin()
    │ ~192 KB/s = 1.54 Mbps (48kHz stereo 16-bit)
    │
    ▼
Frontend AudioWorklet (Web Audio API)
    │ Receives binary frames via MessagePort (Transferable ArrayBuffer)
    │ Convert i16 → f32 (sample / 32768.0)
    │ Ring buffer with 200-500ms capacity (jitter absorption)
    │ Outputs 128-sample render quanta @ 48kHz
    │ Plays through device speakers/headphones
```

---

## REAPER API: Audio Capture

### The Critical API: `Audio_RegHardwareHook`

From `docs/reaper_plugin.h` line 1181:

```c
typedef struct audio_hook_register_t {
    // Called twice per frame: isPost=false (before processing), isPost=true (after)
    void (*OnAudioBuffer)(bool isPost, int len, double srate,
                          struct audio_hook_register_t *reg);
    void *userdata1;
    void *userdata2;

    // Set by host — only call GetBuffer from within OnAudioBuffer!
    int input_nch, output_nch;
    ReaSample *(*GetBuffer)(bool isOutput, int idx);
} audio_hook_register_t;
```

**Registration:** `Audio_RegHardwareHook(true, &reg)` to add, `Audio_RegHardwareHook(false, &reg)` to remove.

**Key facts:**
- `OnAudioBuffer` is called on the **audio thread** — must be real-time safe
- `isPost=true` gives us the **post-master-FX** output (what goes to speakers)
- `len` = number of samples in this buffer (typically 256-1024)
- `srate` = current sample rate (44100, 48000, 96000, etc.)
- `GetBuffer(true, idx)` returns pointer to output channel `idx` (0=left, 1=right)
- `ReaSample` is `double` (f64)
- `output_nch` tells us how many output channels are available

**What we do in the callback:**
1. Check `isPost == true` (we want post-FX output)
2. Get left/right buffers via `GetBuffer(true, 0)` and `GetBuffer(true, 1)`
3. Copy `len` samples from each channel into a lock-free ring buffer
4. Return immediately — no encoding, no I/O, no allocations

### Supporting APIs

| API | Purpose |
|-----|---------|
| `GetAudioDeviceInfo("SRATE", ...)` | Get current sample rate |
| `GetAudioDeviceInfo("BSIZE", ...)` | Get buffer size |
| `Audio_IsRunning()` | Check if audio engine is active |
| `IsInRealTimeAudio()` | Verify we're on audio thread |
| `GetMasterTrack(NULL)` | Get master track for metering |

### New Bindings Required

The extension's `reaper/raw.zig` needs these new function bindings:

```zig
// In raw.zig function pointer table:
Audio_RegHardwareHook: ?*const fn (isAdd: bool, reg: *audio_hook_register_t) callconv(.c) c_int,
Audio_IsRunning: ?*const fn () callconv(.c) c_int,
GetAudioDeviceInfo: ?*const fn (attribute: [*:0]const u8, desc_out: [*]u8, desc_out_sz: c_int) callconv(.c) bool,
```

And a Zig struct mirroring `audio_hook_register_t`:

```zig
pub const AudioHookRegister = extern struct {
    OnAudioBuffer: *const fn (isPost: bool, len: c_int, srate: f64, reg: *AudioHookRegister) callconv(.c) void,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
    input_nch: c_int,
    output_nch: c_int,
    GetBuffer: ?*const fn (isOutput: bool, idx: c_int) callconv(.c) ?[*]f64,
};
```

---

## Transport Layer Analysis

### Option A: Binary WebSocket Frames (Recommended)

The websocket.zig library already supports binary frames:
```zig
// In websocket server library (confirmed in source):
pub fn writeBin(self: *Conn, data: []const u8) !void {
    return self.writeFrame(.binary, data);
}
```

Currently the extension only uses `writeText()`. Adding binary support requires:
1. Using `conn.writeBin(data)` for audio frames
2. Frontend sets `ws.binaryType = 'arraybuffer'`
3. Frontend routes binary messages to audio pipeline, text to JSON parser

**Advantages:**
- Reuses existing WebSocket connection (no new port/socket)
- Library already supports it
- Per-client subscription model fits naturally
- Authentication/session token already handled

**Bandwidth at various quality levels:**

| Quality | Opus Bitrate | Bandwidth | Use Case |
|---------|-------------|-----------|----------|
| Voice | 24 kbps mono | ~30 kbps | Monitoring speech/VO |
| Music Low | 48 kbps stereo | ~55 kbps | Background monitoring |
| Music Med | 96 kbps stereo | ~105 kbps | Active mixing |
| Music High | 128 kbps stereo | ~140 kbps | Critical listening |

All well within WiFi and even poor cellular bandwidth.

### Option B: Separate HTTP Audio Stream

Serve audio as a chunked HTTP response (like internet radio):
```
GET /api/audio/stream?quality=medium
Content-Type: audio/ogg
Transfer-Encoding: chunked
```

Frontend plays via `<audio src="/api/audio/stream">`.

**Advantages:** Simplest frontend (one line of HTML). Browser handles buffering/playback.
**Disadvantages:** No per-frame control, harder to sync with transport, can't do adaptive quality, browser caching/buffering adds latency.

### Option C: Dedicated Audio WebSocket

Open a second WebSocket connection just for audio on a different path (`/ws/audio`).

**Advantages:** Complete separation from control channel. Can't accidentally block control messages.
**Disadvantages:** Extra connection management, extra port complexity, doubles Safari iOS reconnection headaches.

### Recommendation: Option A (Binary on existing WebSocket)

The existing WebSocket infrastructure handles 30Hz meter updates + 1.1MB action lists without issue. Audio at 50 frames/sec of ~150 bytes = ~7.5 KB/sec is trivial compared to existing traffic. Binary frames won't interfere with JSON text frames — WebSocket protocol natively distinguishes them.

---

## Encoding: Opus

**Why Opus:**
- Designed for low-latency real-time audio (5-60ms frame sizes)
- Excellent quality at low bitrates (48-128 kbps for music)
- Supported in all modern browsers via Web Audio API decodeAudioData
- WebCodecs API provides hardware-accelerated decode on newer browsers
- Open source, no licensing fees

**Frame parameters:**
- Frame size: 20ms (standard Opus frame, good latency/efficiency tradeoff)
- Sample rate: 48kHz (Opus native, avoids internal resampling)
- Channels: Stereo (configurable to mono for lower bandwidth)
- Bitrate: 96 kbps default (music quality)

**Encoding library:** Link against libopus (C library) from Zig.
- `zig build-lib` can link C libraries via `@cImport`
- libopus is ~100KB, well-tested, standard
- Alternative: Build opus from source as Zig build dependency

### If REAPER sample rate ≠ 48kHz

Need resampling. Options:
1. **Simple linear interpolation** — adequate for monitoring quality
2. **libspeexdsp resampler** — high quality, small, C library
3. **Opus handles this internally** if we use its resampler mode

For a monitoring feature, simple interpolation is likely sufficient.

---

## Backend Implementation Plan

### New Files

```
extension/src/audio/
├── audio_hook.zig          # Audio_RegHardwareHook registration, OnAudioBuffer callback
├── ring_buffer.zig         # Lock-free SPSC ring buffer (audio → encoder)
├── encoder_thread.zig      # Opus encoding thread, WebSocket frame building
├── opus.zig                # Zig bindings for libopus
└── stream_state.zig        # Per-client stream subscription state
```

### 1. Ring Buffer (`ring_buffer.zig`)

Lock-free single-producer single-consumer ring buffer:
- Producer: audio thread (writes interleaved stereo f64 samples)
- Consumer: encoder thread (reads in 20ms chunks)
- Capacity: ~500ms of audio (enough to absorb jitter)
- Overflow policy: drop oldest samples (don't block audio thread)
- Uses atomic read/write indices

```zig
pub const AudioRingBuffer = struct {
    buffer: []f64,           // Heap-allocated, interleaved stereo
    capacity: usize,         // In stereo sample pairs
    write_pos: std.atomic.Value(usize),
    read_pos: std.atomic.Value(usize),
    sample_rate: std.atomic.Value(u32),

    pub fn write(self: *AudioRingBuffer, left: [*]const f64, right: [*]const f64, len: usize) void { ... }
    pub fn read(self: *AudioRingBuffer, out: []f64, len: usize) usize { ... }
    pub fn available(self: *AudioRingBuffer) usize { ... }
};
```

### 2. Audio Hook (`audio_hook.zig`)

```zig
var g_ring_buffer: ?*AudioRingBuffer = null;
var g_hook_reg: AudioHookRegister = .{
    .OnAudioBuffer = onAudioBuffer,
    .userdata1 = null,
    .userdata2 = null,
    .input_nch = 0,
    .output_nch = 0,
    .GetBuffer = null,
};

fn onAudioBuffer(isPost: bool, len: c_int, srate: f64, reg: *AudioHookRegister) callconv(.c) void {
    if (!isPost) return;  // Only capture post-FX output

    const ring = g_ring_buffer orelse return;
    const left = reg.GetBuffer.?(true, 0) orelse return;
    const right = reg.GetBuffer.?(true, 1) orelse return;

    ring.sample_rate.store(@intFromFloat(srate), .release);
    ring.write(left, right, @intCast(len));
}
```

### 3. Encoder Thread (`encoder_thread.zig`)

Dedicated thread that:
1. Reads 20ms chunks from ring buffer
2. Resamples to 48kHz if needed
3. Opus-encodes the chunk
4. Builds a binary WebSocket frame with header
5. Sends to subscribed clients via `conn.writeBin()`

Frame format:
```
[0..3]   u32 LE: sequence number (for gap detection)
[4..11]  f64 LE: REAPER play position at frame start (for sync)
[12..13] u16 LE: opus payload length
[14..]   Opus-encoded audio data
```

### 4. Stream Subscription (`stream_state.zig`)

Per-client subscription, similar to existing peaks/routing subscriptions:
```zig
pub const StreamSubscription = struct {
    client_id: usize,
    quality: Quality,        // voice/low/medium/high
    channels: Channels,      // mono/stereo
    active: bool,
};

pub const Quality = enum { voice, low, medium, high };
pub const Channels = enum { mono, stereo };
```

### 5. Commands

Add to `registry.zig`:
```zig
.{ "audio/startStream", audio_stream.handleStartStream },
.{ "audio/stopStream", audio_stream.handleStopStream },
.{ "audio/setQuality", audio_stream.handleSetQuality },
.{ "audio/getStatus", audio_stream.handleGetStatus },
```

---

## Frontend Implementation Plan

### New Files

```
frontend/src/audio/
├── AudioStreamManager.ts    # Manages stream lifecycle, WebSocket binary routing
├── AudioWorkletProcessor.ts # Runs in AudioWorklet, decodes Opus, feeds playback
├── JitterBuffer.ts          # Smooths network jitter, handles gaps
└── audioMonitorSlice.ts     # Zustand slice for monitoring state
```

### 1. Binary WebSocket Routing

In `WebSocketConnection.ts`, add binary message handling:
```typescript
this.ws.binaryType = 'arraybuffer';
this.ws.onmessage = (event) => {
    if (event.data instanceof ArrayBuffer) {
        // Binary frame → audio pipeline
        this.audioStreamManager?.handleAudioFrame(event.data);
    } else {
        // Text frame → existing JSON handler
        this.handleMessage(event.data);
    }
};
```

### 2. AudioWorklet Approach (Recommended)

```typescript
// AudioStreamManager.ts
class AudioStreamManager {
    private audioContext: AudioContext | null = null;
    private workletNode: AudioWorkletNode | null = null;

    async start() {
        this.audioContext = new AudioContext({ sampleRate: 48000 });
        await this.audioContext.audioWorklet.addModule('/audio-worklet-processor.js');
        this.workletNode = new AudioWorkletNode(this.audioContext, 'opus-playback-processor');
        this.workletNode.connect(this.audioContext.destination);
    }

    handleAudioFrame(data: ArrayBuffer) {
        // Forward to worklet via MessagePort
        this.workletNode?.port.postMessage(data, [data]); // Transfer ownership
    }
}
```

### 3. Jitter Buffer

The AudioWorklet maintains a jitter buffer:
- Target: 3-5 frames ahead (60-100ms)
- If buffer underflows: insert silence, increment underflow counter
- If buffer overflows: drop oldest frame
- Adaptive: adjust target based on observed jitter

### 4. Opus Decoding in Browser

**Option A: WebCodecs API** (preferred if available)
```typescript
const decoder = new AudioDecoder({
    output: (frame) => { /* feed to jitter buffer */ },
    error: (e) => console.error(e),
});
decoder.configure({ codec: 'opus', sampleRate: 48000, numberOfChannels: 2 });
decoder.decode(new EncodedAudioChunk({ type: 'key', data: opusFrame, timestamp }));
```

**Option B: decodeAudioData** (broader compatibility)
```typescript
// Wrap Opus frame in Ogg container, then:
audioContext.decodeAudioData(oggBuffer).then(audioBuffer => { ... });
```

**Option C: opus-decoder WASM** (most compatible)
```typescript
import { OpusDecoder } from 'opus-decoder';
const decoder = new OpusDecoder({ sampleRate: 48000, channels: 2 });
const pcm = decoder.decode(opusFrame);
```

### 5. UI Components

Minimal UI — this is a background feature with a simple toggle:
- Toggle button in settings or toolbar: "Monitor Audio"
- Volume slider for monitor output
- Latency indicator (ms)
- Quality selector (Low/Medium/High)
- Status: Streaming / Buffering / Disconnected

---

## iOS PWA Considerations (CONFIRMED BY RESEARCH)

### Background Audio — The Biggest Risk
- **`AudioContext` gets suspended when iOS PWA goes to background or screen locks**
- WebSocket dies ~30s after backgrounding (close code 1005)
- JavaScript execution halts entirely — no keepalive, no reconnection
- **Only an actively playing `<audio>` element keeps the process alive** (iOS 15.4+)
- WakeLock API is NOT available on iOS Safari

### MVP Strategy: Foreground-Only
- Accept that audio monitoring stops when the app is backgrounded
- Implement robust reconnection on `visibilitychange` — resume streaming when user returns
- This is acceptable for a DAW remote: users are typically looking at the screen while mixing

### Phase 3 Strategy: HTTP Audio Stream for Background
- Serve audio as an HTTP streaming endpoint that an `<audio>` element can consume
- `<audio>` element keeps the iOS process alive + gets lock screen controls
- WebSocket remains for control messages only
- Media Session API (iOS 15+) for Now Playing metadata and play/pause handlers

### AudioWorklet Compatibility
- AudioWorklet works from **iOS 14.5+** (Safari 14.1), target **iOS 15+** for stability
- Works identically in standalone PWA mode — no PWA-specific restrictions
- Fixed 128-frame render quantum (~2.67ms at 48kHz)
- Transferable ArrayBuffers via `MessagePort.postMessage()` work in Safari

---

## Latency Budget (Raw PCM MVP)

| Stage | Estimated Latency |
|-------|------------------|
| REAPER audio buffer | 5-23ms (256-1024 samples @ 44.1kHz) |
| Ring buffer read + frame | ~5-10ms (5-10ms chunks, no codec) |
| Network (WiFi LAN) | 1-10ms |
| Network (USB tethering) | <1ms |
| Jitter buffer (frontend) | 50-100ms (adaptive, absorbs WiFi spikes) |
| AudioWorklet output | ~2.7ms (128 samples @ 48kHz) |
| **Total (WiFi)** | **~75-160ms** |
| **Total (USB)** | **~50-100ms** |

Raw PCM has **zero codec latency** — no encode/decode step. This is comparable to Bluetooth audio latency (~150-200ms) and significantly better than most "listen on phone" solutions.

---

## Open Questions ~~Requiring External Research~~ (ALL RESOLVED)

### 1. Opus Encoding from Zig
- Can we `@cImport("opus/opus.h")` and link libopus?
- Is there a Zig package for libopus, or do we build from C source?
- What's the minimum libopus API surface needed? (Probably just `opus_encoder_create`, `opus_encode_float`, `opus_encoder_destroy`)
- Alternative: Use a simpler codec (raw PCM with optional compression) for v1 and add Opus later

### 2. AudioWorklet + Opus Decode on iOS Safari
- Does Safari PWA support AudioWorklet? (It does as of Safari 14.1+)
- What Opus decode approach works best in Safari? WebCodecs API support is inconsistent.
- opus-decoder WASM library compatibility with iOS Safari
- Memory/battery impact of continuous decode on iPhone

### 3. REAPER Audio Hook Behavior
- When REAPER is stopped (not playing), does `OnAudioBuffer` still fire?
  - If yes with silence: we can stream silence (or detect and pause)
  - If no: we need to detect start/stop and manage stream accordingly
- Does `GetBuffer(true, idx)` give us the EXACT same audio as goes to hardware?
- What happens if the user changes audio device/sample rate mid-stream?

### 4. iOS Background Audio Limits
- How long can a PWA play audio in background before iOS suspends it?
- Does the Web Audio API count as "actively playing audio" for iOS background policy?
- Do we need a silent audio workaround to keep the connection alive?

### 5. Bandwidth Adaptation
- Should we implement adaptive bitrate (reduce quality when network degrades)?
- How to detect network quality from WebSocket RTT?
- Existing clock sync could provide RTT estimates

---

## External Research Query

```markdown
# Audio Monitoring Research: Opus Encoding from Zig + Web Audio Playback on iOS Safari PWA

## Context
Building a REAPER DAW remote control (PWA) that streams the master audio output
to the user's phone. The backend is a REAPER C plugin written in Zig 0.15 that
captures audio via `Audio_RegHardwareHook` (real-time audio thread callback,
f64 interleaved samples at 44.1-96kHz). Audio is streamed over binary WebSocket
frames to a React 19 frontend PWA.

## Questions

### 1. Opus Encoding from Zig
- What's the cleanest way to use libopus from Zig 0.15?
  - @cImport + system library linking?
  - Build libopus from source as a Zig build step?
  - Is there a zig-opus package?
- Minimal API surface needed:
  - `opus_encoder_create(Fs, channels, application, &error)`
  - `opus_encode_float(encoder, pcm, frame_size, data, max_data_bytes)`
  - `opus_encoder_ctl(encoder, OPUS_SET_BITRATE(bitrate))`
  - `opus_encoder_destroy(encoder)`
- Do we need to handle resampling separately (REAPER may be at 44.1kHz,
  Opus wants 48kHz), or does Opus handle internal resampling?
- Memory allocation: does libopus allocate internally or can we provide
  a buffer? (Important for real-time safety of the encoder thread)

### 2. Opus Decoding in iOS Safari PWA (AudioWorklet)
- Does AudioWorklet work reliably in iOS Safari PWA (standalone mode)?
  Minimum iOS version required?
- Best approach for Opus decoding in the browser:
  a) WebCodecs AudioDecoder — does Safari support this for Opus as of 2026?
  b) opus-decoder WASM package (npm) — works in AudioWorklet?
  c) decodeAudioData with Ogg container wrapping — latency overhead?
  d) Raw PCM streaming (skip Opus, just send 16-bit PCM) — bandwidth?
- What's the right AudioWorklet buffer/output size for low latency?
- Can an AudioWorklet receive data via MessagePort.postMessage with
  Transferable ArrayBuffers without copies?

### 3. iOS PWA Background Audio
- If a PWA creates an AudioContext and plays audio, how long will iOS
  keep the app running in background?
- Does the app need to be in "Now Playing" (Media Session API) to
  avoid suspension?
- If the user locks their phone, does audio continue playing?
- Is there a pattern to keep the WebSocket alive while playing
  background audio?

### 4. REAPER Audio_RegHardwareHook Behavior
- Does OnAudioBuffer continue firing when REAPER transport is stopped?
  (i.e., does the audio engine still process silence?)
- If the user changes audio device settings (sample rate, buffer size),
  does the hook automatically get called with new parameters, or do
  we need to re-register?
- Is GetBuffer() safe to call for channels beyond output_nch? (e.g.,
  if output_nch is 2 but we call GetBuffer(true, 2))
- Any known issues with audio hooks and REAPER closing/restarting
  the audio engine?

### 5. Alternative: Raw PCM Streaming Without Opus
- For a v1 MVP, is streaming raw 16-bit PCM at 48kHz stereo viable?
  Bandwidth: 48000 * 2 * 2 = 192 KB/s = 1.5 Mbps
- Could use simple ADPCM or mu-law for 4:1 compression (~384 kbps)
  without an external library dependency
- Would this be acceptable for LAN-only monitoring? (defer Opus to v2)
```

### RESEARCH RESULTS

```markdown
# REAPER WebSocket audio streaming: a full technical feasibility study

**Raw 16-bit PCM over WebSocket is the correct MVP choice for LAN monitoring — it eliminates all codec complexity, delivers perfect quality at 1.54 Mbps (trivial on WiFi), and zero codec latency.** The biggest risk to the project isn't audio encoding but rather iOS background audio: Web Audio API's `AudioContext` gets suspended when a PWA loses focus, which will kill both audio output and the WebSocket connection. A hybrid architecture using a hidden `<audio>` element is required for background playback. Opus can be cleanly integrated from Zig via the hexops/opus package for a future v2 targeting WAN use, but browser-side Opus decoding on Safari remains fragmented until iOS 26+ brings WebCodecs AudioDecoder.

---

## 1. Opus encoding from Zig 0.15: build from source, skip the package manager

The cleanest integration path is **building libopus from C source as a Zig build step** using the [hexops/opus](https://github.com/hexops/opus) fork, which replaces CMake/autotools with a native `build.zig`. Add it as a dependency in `build.zig.zon`, and Zig compiles the C sources directly with its bundled Clang — no system library needed, cross-compilation works out of the box. This is ideal for distributing a REAPER plugin. The alternative `mach-opus` Zig bindings exist but are marked experimental with a removed documentation page, suggesting uncertain maintenance.

The four API functions you need (`opus_encoder_create`, `opus_encode_float`, `opus_encoder_ctl`, `opus_encoder_destroy`) map cleanly through `@cImport(@cInclude("opus/opus.h"))`, with one caveat: **the CTL macros like `OPUS_SET_BITRATE(x)` are variadic C macros** that Zig's `@cImport` won't translate. You'll need to call the underlying request codes directly — `OPUS_SET_BITRATE_REQUEST` is `4002`, so the call becomes `c.opus_encoder_ctl(enc, @as(c_int, 4002), @as(c.opus_int32, 128000))`.

**Memory allocation is fully controllable for real-time safety.** Rather than `opus_encoder_create` (which calls `malloc` internally), use the two-step pattern: call `opus_encoder_get_size(2)` at init time to learn the required allocation size, allocate memory yourself, then call `opus_encoder_init()` to initialize the pre-allocated state. The docs explicitly endorse this for custom allocators. Critically, **`opus_encode_float()` performs zero allocations** — it writes into a caller-provided output buffer, making it safe to call on the real-time audio thread.

**Opus does not accept 44.1 kHz input.** Supported rates are 8, 12, 16, 24, and 48 kHz only. If the REAPER project runs at 44.1 kHz, you must resample to 48 kHz before encoding. The Opus FAQ notes quality degradation from a good resampler is "far less than the distortion caused by the best lossy codec at its highest bitrate." The simplest fix is configuring REAPER to run at 48 kHz; failing that, libspeexdsp's resampler (BSD-licensed, included with opus-tools) is the standard solution. At 48 kHz, use **960-sample frames (20 ms)** for the best latency/quality tradeoff.

---

## 2. Browser-side Opus decoding on Safari is still messy

AudioWorklet is supported from **iOS 14.5+** (Safari 14.1), though iOS 15+ is the practical minimum given early bugs and negligible iOS 14 market share in 2026. AudioWorklet works identically in standalone/home-screen PWA mode — there are no PWA-specific restrictions. The fixed **128-frame render quantum** (~2.67 ms at 48 kHz) applies to all browsers including Safari.

For Opus decoding specifically, the landscape is fragmented across four approaches:

**WebCodecs AudioDecoder** is the cleanest browser-native path but requires **iOS 26+** (Safari 26.0, September 2025). Safari added AudioDecoder/AudioEncoder only in that release. Even then, Opus support within WebCodecs has had reported bugs (WebKit bugs 238546, 245428), so runtime feature detection via `AudioDecoder.isConfigSupported()` is essential. This rules out WebCodecs for any users on iOS 17–18.

**WASM Opus decoding** via the [`opus-decoder`](https://github.com/eshaz/wasm-audio-decoders) npm package is the most practical current approach. It decodes raw Opus frames (not Ogg-wrapped) to Float32 PCM, uses inline WASM (no separate `.wasm` file to fetch), and produces output directly usable in AudioWorklet. The inline WASM approach sidesteps the AudioWorkletGlobalScope's lack of `fetch()`. Load the decoder + processor as a single JS module via `audioContext.audioWorklet.addModule()`. **This specific combination (WASM in AudioWorklet on iOS Safari) needs empirical testing** — most community documentation focuses on Chrome.

**`decodeAudioData` with Ogg container wrapping** is not viable for real-time streaming. Ogg Opus is only supported since iOS 18.4, and `decodeAudioData()` is designed for complete file decoding — each call adds **50–200 ms of latency** from container parsing, async Promise resolution, and AudioBuffer allocation.

**Raw PCM streaming** avoids all codec complexity. The browser-side implementation is trivial: receive binary WebSocket messages, convert Int16 to Float32 (`sample / 32768.0`), feed into an AudioWorklet ring buffer. This works on any iOS version with AudioWorklet support and is **the most reliable path for an MVP**.

For data transfer into AudioWorklet, **Transferable ArrayBuffers via `MessagePort.postMessage()` work in Safari** and provide zero-copy ownership transfer. SharedArrayBuffer offers higher performance (lock-free ring buffer between threads) but requires cross-origin isolation headers (`Cross-Origin-Opener-Policy: same-origin` + `Cross-Origin-Embedder-Policy: require-corp`), and Safari doesn't support the `credentialless` COEP mode. Since you control the REAPER plugin's HTTP server, you can set these headers, making SharedArrayBuffer feasible.

---

## 3. iOS background audio is the project's biggest risk

**This is the critical architectural constraint: `AudioContext` playback is suspended when an iOS PWA goes to background or the screen locks.** Unlike a native app with `AVAudioSession` background mode, a PWA's Web Audio API processing stops when iOS freezes the web process. The WebSocket connection dies approximately 30 seconds after backgrounding (close code 1005). JavaScript execution halts entirely — no keepalive pings, no reconnection logic, nothing runs.

The only mechanism that keeps an iOS PWA process alive is **an actively playing `<audio>` HTML element**. This was fixed for standalone PWAs in iOS 15.4 (WebKit Bug 198277/232909). When an `<audio>` element is playing, iOS grants the web process an audio session assertion similar to native apps, enabling lock screen playback and Now Playing integration. However, several caveats apply: pausing for ~30 seconds causes process suspension, track transitions in background are broken on iOS 16–17 (WebKit Bug 261858), and iOS 18 has reports of audio muting (not pausing) in background.

| Behavior | `<audio>` element | `AudioContext` only |
|---|---|---|
| Background playback | ✅ Works (iOS 15.4+) | ❌ Suspended |
| Lock screen controls | ✅ Via Media Session API | ❌ None |
| Keeps WebSocket alive | ✅ While actively playing | ❌ Process frozen |
| Low-latency output | ❌ No | ✅ Yes |

The **Media Session API** (supported since iOS 15) is essential for setting Now Playing metadata and registering play/pause handlers, but it only functions in conjunction with an `<audio>` element — it won't independently prevent suspension.

### Architectural options for the REAPER PWA

The ideal approach would pipe WebSocket audio data into an `<audio>` element via MediaSource Extensions (MSE), but **MSE support on iOS Safari is limited** — historically available only for HLS in `<video>`, not arbitrary audio streams. Three viable strategies remain:

- **Accept foreground-only operation** for the MVP. Implement robust WebSocket reconnection on `visibilitychange` events. When the user returns to the PWA, reconnect and resume streaming. This is the simplest approach and may be acceptable for a DAW remote control (users are typically looking at the screen while mixing).

- **Hybrid silent `<audio>` trick**: play a short silent MP3 on loop through a hidden `<audio>` element to keep the process alive, while using AudioContext for actual audio rendering. This is fragile — newer iOS versions may detect and ignore silent audio — but has been used successfully by some developers.

- **HTTP audio stream endpoint**: Instead of (or in addition to) WebSocket, have the REAPER plugin serve audio as an HTTP chunked response or simple streaming endpoint that an `<audio>` element can consume directly. This leverages iOS's native audio session handling. The WebSocket would remain for control messages only.

**The WakeLock API is not available on iOS Safari** (WebKit Bug 254545). Background Sync API is also unsupported. NoSleep.js (silent video playback) is unreliable on iOS 14+ and produces confusing UX.

---

## 4. REAPER's audio hook fires continuously, survives engine restarts

The `audio_hook_register_t` struct (from `reaper_plugin.h`) provides direct access to the audio engine's processing loop:

```c
typedef struct audio_hook_register_t {
    void (*OnAudioBuffer)(bool isPost, int len, double srate, 
                          struct audio_hook_register_t *reg);
    void *userdata1, *userdata2;
    int input_nch, output_nch;           // set by host
    ReaSample *(*GetBuffer)(bool isOutput, int idx);  // set by host
} audio_hook_register_t;
```

**`OnAudioBuffer` continues firing when the transport is stopped.** The hook operates at the hardware audio driver level, not the transport level. ASIO/CoreAudio drivers continuously request audio buffers regardless of transport state. When stopped, output buffers contain silence (zeros) unless live input monitoring is active. The only exception is if REAPER's "Close audio device when stopped and application is inactive" preference is enabled, which shuts down the engine entirely.

**The hook automatically receives updated parameters on device changes.** When sample rate, buffer size, or audio device changes, REAPER internally restarts the audio engine — callbacks stop temporarily, then resume with new `srate`, `len`, `input_nch`, and `output_nch` values. **No re-registration is needed.** The hook registration persists across engine restarts. Your plugin should read these parameters from every callback invocation rather than caching them.

For tapping master output, use the **`isPost=true` callback** — this fires after REAPER's full mix processing. Buffers are non-interleaved `double*` arrays (one per channel, `len` samples each): `GetBuffer(true, 0)` for left, `GetBuffer(true, 1)` for right. **Always bounds-check channel index against `output_nch` before calling `GetBuffer`**, and null-check the return value. The header warns with triple exclamation marks that `GetBuffer` and channel counts must only be accessed from within `OnAudioBuffer`.

The recommended real-time architecture is:

- **Audio thread** (`OnAudioBuffer`): read output buffers, convert `double` → `int16` (or `float` for Opus), write to a **lock-free ring buffer**. No allocations, no locks, no I/O.
- **Network thread**: read from ring buffer, frame into WebSocket binary messages, send to clients.
- **Init/shutdown**: register hook from main thread, pre-allocate all buffers. Unregister with `Audio_RegHardwareHook(false, &reg)` before plugin unload. Use `Audio_IsRunning()` (threadsafe) to monitor engine state from the network thread.

---

## 5. Raw PCM is the right MVP — defer Opus to v2

**48 kHz stereo 16-bit PCM at 1.54 Mbps consumes roughly 1–3% of even the worst WiFi 4 connection.** WebSocket binary framing adds negligible overhead (~400 bytes/sec at 100 frames/sec). This is less bandwidth than a single 720p YouTube stream. For a LAN-only monitoring tool, bandwidth is a non-issue.

| Codec | Bitrate | Quality | Implementation | Codec latency |
|---|---|---|---|---|
| **Raw PCM** | **1.54 Mbps** | **Perfect** | **~50 lines** | **0 ms** |
| IMA ADPCM | 384 kbps | Good (some artifacts) | ~100 lines C/Zig | 0 ms |
| QOA | ~307 kbps | Very good | ~400 lines C | ~0.4 ms |
| μ-law | 768 kbps | Fair for music | ~30 lines | 0 ms |
| Opus | 64–128 kbps | Excellent | Large C library | 5–26.5 ms |

If compression becomes desirable (multiple simultaneous clients, congested networks), **QOA (Quite OK Audio)** is the best intermediate step before Opus. It achieves ~5:1 compression in a single-header C file (~400 lines, MIT license) with quality better than IMA ADPCM. The reference implementation at `github.com/phoboslab/qoa` ports easily to Zig, and a transpiled JavaScript decoder exists for the browser side. IMA ADPCM at ~100 lines is even simpler if you want minimal code, and the ADPCM-XQ variant (by WavPack creator David Bryant) adds noise shaping for significantly better encoding quality with standard-compatible decoding.

### Implementation blueprint for the raw PCM MVP

Send **5–10 ms chunks** (480–960 stereo samples = 1,920–3,840 bytes) as WebSocket binary frames. On the browser, create the AudioContext with `{sampleRate: 48000}` to match the source and avoid resampling. The AudioWorklet processor maintains a ring buffer (~200–500 ms capacity to absorb WiFi jitter), receives Int16 data via `postMessage` with Transferable ArrayBuffer, converts to Float32, and outputs 128-sample render quanta. Monitor ring buffer fill level for adaptive latency — if falling behind, skip to the latest data rather than accumulating delay.

---

## Conclusion: what the architecture should look like

The full system breaks down cleanly into a real-time pipeline with well-understood components. The REAPER plugin's `OnAudioBuffer(isPost=true)` callback reads master output as non-interleaved doubles, converts to interleaved Int16, and writes to a lock-free ring buffer. A separate network thread reads the ring buffer and sends binary WebSocket frames. The React PWA receives these frames and transfers them into an AudioWorklet ring buffer for playback.

Three decisions shape the v1 scope. First, **use raw PCM** — it eliminates the libopus dependency, the browser-side codec question, and all resampling concerns. Second, **accept foreground-only audio** on iOS for the MVP, implementing robust reconnection on `visibilitychange`. Background audio on iOS requires either piping data through an `<audio>` element (architecturally complex) or a native app wrapper. Third, **target iOS 15+** for AudioWorklet reliability, which covers effectively all devices still in use.

The upgrade path to Opus is clear: add hexops/opus as a Zig build dependency, pre-allocate the encoder with `opus_encoder_get_size` + `opus_encoder_init` for RT safety, ensure 48 kHz input (resample if needed), and decode in the browser via the `opus-decoder` WASM package in the AudioWorklet. WebCodecs AudioDecoder becomes viable once iOS 26+ adoption is sufficient. QOA offers a compelling middle ground — near-Opus compression ratios with a single-file C implementation and no algorithmic latency.
```

---

## Implementation Phases

### Phase 1: MVP — Raw 16-bit PCM over Binary WebSocket
- Add `Audio_RegHardwareHook` binding + `AudioHookRegister` struct in Zig
- Lock-free SPSC ring buffer (audio thread → network thread)
- Network thread reads ring buffer, sends 5-10ms chunks as binary WebSocket frames
- **48kHz stereo 16-bit PCM = 1.54 Mbps** (trivial on LAN WiFi, perfect quality, zero codec latency)
- Frontend: `AudioContext({sampleRate: 48000})` + AudioWorklet with ring buffer
- Binary WebSocket routing (`instanceof ArrayBuffer` → audio pipeline)
- `audio/startStream` and `audio/stopStream` commands
- Foreground-only on iOS (accept suspension on background)
- **Target: iOS 15+ (AudioWorklet), all modern desktop browsers**
- **No Opus, no WASM, no resampling — simplest possible path to audio**

### Phase 2: Compression (QOA or Opus)
- **QOA first** (if bandwidth becomes an issue): single-header C file (~400 lines), ~5:1 compression, ports easily to Zig, JS decoder exists. No resampling needed.
- **Opus later** (for WAN/cellular): hexops/opus Zig build dep, pre-allocate encoder with `opus_encoder_get_size` + `opus_encoder_init` for RT safety, 960-sample frames (20ms @ 48kHz)
- Must resample 44.1kHz → 48kHz if REAPER not at 48k (Opus doesn't accept 44.1)
- Frontend Opus decode: `opus-decoder` WASM package in AudioWorklet (most compatible)
- Quality selector (voice/low/med/high)

### Phase 3: iOS Background Audio + Polish
- HTTP audio stream endpoint (`/api/audio/stream`) for `<audio>` element playback
- This keeps the PWA process alive when backgrounded (iOS 15.4+)
- Media Session API for lock screen controls ("REAmo - Monitoring")
- Jitter buffer with adaptive depth
- Transport sync (detect silence when REAPER stopped, optionally pause stream)
- Latency display and buffer health indicator
- Volume control (independent of REAPER master volume)
- Mono/stereo toggle

### Phase 4: Advanced
- Per-track monitoring (listen to individual track output)
- Headphone mix (custom mix sent to phone, different from main output)
- Click-only mode (only metronome routed to phone)
- SharedArrayBuffer ring buffer (requires COOP/COEP headers — we control the server)

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| iOS PWA background suspend | **High** | **High** | MVP: foreground-only. Phase 3: HTTP audio stream + `<audio>` element |
| iOS Safari AudioWorklet bugs | Medium | High | Fallback to ScriptProcessorNode; target iOS 15+ |
| Audio thread instability | Low | High | Ring buffer completely isolates audio thread |
| WiFi latency spikes | High | Medium | Jitter buffer (200-500ms); USB tethering as fallback |
| 44.1kHz resampling (Opus phase) | Medium | Medium | Raw PCM MVP avoids this; libspeexdsp for Opus phase |
| Battery drain on phone | Medium | Medium | Auto-pause when silence detected, configurable quality |
| REAPER "close audio when inactive" | Low | Low | Detect via `Audio_IsRunning()`, show status to user |

---

## Files That Will Change

### Extension (Backend)
| File | Change |
|------|--------|
| `extension/src/reaper/raw.zig` | Add `Audio_RegHardwareHook`, `Audio_IsRunning`, `GetAudioDeviceInfo` bindings |
| `extension/src/reaper/real.zig` | Add wrapper methods for new bindings |
| `extension/src/commands/registry.zig` | Add `audio/*` command entries |
| `extension/src/main.zig` | Add audio hook initialization/cleanup, encoder thread lifecycle |
| `extension/src/audio/` (new) | All audio capture, encoding, streaming logic |
| `extension/build.zig` | Link libopus (Phase 2) |

### Frontend
| File | Change |
|------|--------|
| `frontend/src/core/WebSocketConnection.ts` | Add binary message routing |
| `frontend/src/core/WebSocketCommands.ts` | Add `audio/*` commands |
| `frontend/src/core/WebSocketTypes.ts` | Add audio event types |
| `frontend/src/audio/` (new) | AudioStreamManager, AudioWorklet, JitterBuffer |
| `frontend/src/store/` | Add audioMonitorSlice |
| `frontend/public/audio-worklet-processor.js` | AudioWorklet script |
