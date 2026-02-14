# Implementing REAPER's IReaperControlSurface from Zig

## TL;DR — What This Means For Your Project

**Bottom line**: Implementing CSurf won't give you faster polling than your current timer. Both `Run()` and `register("timer")` are locked to REAPER's ~30Hz UI loop. The CSurf "display update frequency" setting (default 15Hz) only throttles outbound MIDI to physical hardware — it doesn't affect your code's execution rate.

**Your options for ±15ms accuracy**:

| Approach | Polling Rate | Complexity | Recommendation |
|----------|--------------|------------|----------------|
| Current timer + client interpolation | 30Hz polling, smooth display | Low | **Best option** |
| CSurf hybrid (events + timer) | 30Hz + instant transport events | Medium | Good if you want `SetPlayState()` |
| Audio hook (`audio_hook_register_t`) | 86-344Hz depending on buffer | High (thread sync) | Overkill for visual sync |
| Platform-native timer (GCD/Win32) | Configurable | Medium | If you truly need >30Hz |

**The pragmatic path**: Keep your current timer implementation, add client-side BPM-based interpolation for smooth visuals. Optionally add CSurf just for instant `SetPlayState()` callbacks. This achieves sub-millisecond visual accuracy with minimal complexity.

---

## Corrected Understanding: REAPER's Timer Architecture

### Two Separate Systems (Often Confused)

```
┌─────────────────────────────────────────────────────────────────┐
│  REAPER Internal Timing                                         │
├─────────────────────────────────────────────────────────────────┤
│  register("timer") callback:  ~30Hz fixed (UI loop)            │
│  CSurf Run() callback:        ~30Hz fixed (same UI loop)       │
│  "Display update frequency":  Default 15Hz (MIDI output only)  │
└─────────────────────────────────────────────────────────────────┘
```

The `register("timer")` and `IReaperControlSurface::Run()` share the same internal timer — approximately **30Hz (~33ms)**. This is **not configurable**.

The "Control surface display update frequency" preference (default 15Hz) only controls how often REAPER sends **feedback messages to MIDI control surfaces** (motorized faders, LEDs, scribble strips). It does not affect how often your code executes.

### Why This Matters

A forum user tested this empirically: outputting a message every 30 `Run()` cycles produced one message per second regardless of the display frequency setting. The display frequency throttles outbound MIDI bandwidth, not callback execution.

### Why 15Hz Default for Display Updates?

The conservative 15Hz default exists for **MIDI bandwidth management**:

- Standard MIDI: 31.25 kbaud (~3,125 bytes/sec)
- 8 motorized faders × 3 bytes × 30Hz = 720 bytes/sec just for fader positions
- Add scribble strips, LEDs, meters → bandwidth saturates quickly
- Higher rates cause "nervous motorized faders" (jitter from too-frequent updates)

For your WebSocket use case, this throttle is irrelevant — you're not sending MIDI.

---

## The C++ Shim Approach (If You Still Want CSurf)

The value of CSurf isn't faster polling — it's **event-driven callbacks**. `SetPlayState(play, pause, rec)` fires immediately when transport state changes, rather than waiting up to 33ms for the next poll.

### Minimal C++ Bridge

```cpp
// csurf_bridge.cpp
#include "reaper_plugin.h"

extern "C" {
    const char* zig_csurf_get_type_string(void* ctx);
    const char* zig_csurf_get_desc_string(void* ctx);
    const char* zig_csurf_get_config_string(void* ctx);
    void zig_csurf_run(void* ctx);
    void zig_csurf_set_play_state(void* ctx, bool play, bool pause, bool rec);
    void zig_csurf_set_repeat_state(void* ctx, bool rep);
    int zig_csurf_extended(void* ctx, int call, void* p1, void* p2, void* p3);
}

class ZigControlSurface : public IReaperControlSurface {
    void* zig_ctx;
public:
    ZigControlSurface(void* ctx) : zig_ctx(ctx) {}
    ~ZigControlSurface() {}
    
    const char* GetTypeString() override { return zig_csurf_get_type_string(zig_ctx); }
    const char* GetDescString() override { return zig_csurf_get_desc_string(zig_ctx); }
    const char* GetConfigString() override { return zig_csurf_get_config_string(zig_ctx); }
    
    void Run() override { zig_csurf_run(zig_ctx); }
    void SetPlayState(bool play, bool pause, bool rec) override {
        zig_csurf_set_play_state(zig_ctx, play, pause, rec);
    }
    void SetRepeatState(bool rep) override { zig_csurf_set_repeat_state(zig_ctx, rep); }
    int Extended(int call, void* p1, void* p2, void* p3) override {
        return zig_csurf_extended(zig_ctx, call, p1, p2, p3);
    }
};

extern "C" IReaperControlSurface* create_zig_control_surface(void* zig_ctx) {
    return new ZigControlSurface(zig_ctx);
}
```

### Zig Callback Implementation

```zig
// csurf.zig
const std = @import("std");

const ControlSurfaceState = struct {
    type_string: [:0]const u8 = "ZIG_WEBSOCKET",
    desc_string: [:0]const u8 = "Zig WebSocket Control Surface",
    config_string: [:0]const u8 = "",
    last_play_state: struct { play: bool, pause: bool, rec: bool } = .{},
};

var g_state: ControlSurfaceState = .{};

export fn zig_csurf_get_type_string(_: *anyopaque) callconv(.C) [*:0]const u8 {
    return g_state.type_string.ptr;
}

export fn zig_csurf_get_desc_string(_: *anyopaque) callconv(.C) [*:0]const u8 {
    return g_state.desc_string.ptr;
}

export fn zig_csurf_get_config_string(_: *anyopaque) callconv(.C) [*:0]const u8 {
    return g_state.config_string.ptr;
}

export fn zig_csurf_run(_: *anyopaque) callconv(.C) void {
    // Called ~30Hz - same as register("timer")
    // Use for position polling during playback
}

export fn zig_csurf_set_play_state(_: *anyopaque, play: bool, pause: bool, rec: bool) callconv(.C) void {
    // INSTANT callback - fires immediately on transport change
    // This is the main value of CSurf over plain timer
    g_state.last_play_state = .{ .play = play, .pause = pause, .rec = rec };
    broadcastTransportState(play, pause, rec);
}

export fn zig_csurf_set_repeat_state(_: *anyopaque, _: bool) callconv(.C) void {}
export fn zig_csurf_extended(_: *anyopaque, _: c_int, _: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) callconv(.C) c_int {
    return 0;
}
```

---

## Recommended Architecture for ±15ms Visual Accuracy

Since polling is capped at 30Hz (~33ms between updates), client-side interpolation is essential:

### Server Side (Zig)

```zig
const TransportUpdate = struct {
    position_seconds: f64,
    position_beats: f64,
    bpm: f64,
    time_signature_num: u8,
    time_signature_denom: u8,
    is_playing: bool,
    is_recording: bool,
    server_timestamp_ms: i64,
};

fn broadcastTransport(api: *const reaper.Api) void {
    const update = TransportUpdate{
        .position_seconds = api.getPlayPosition(),
        .position_beats = api.timeMap2_timeToBeats(null, api.getPlayPosition(), null, null, null, null),
        .bpm = api.master_GetTempo(),
        .is_playing = api.getPlayState() & 1 != 0,
        .is_recording = api.getPlayState() & 4 != 0,
        .server_timestamp_ms = std.time.milliTimestamp(),
        // ...
    };
    websocket.broadcast(std.json.stringify(update));
}
```

### Client Side (JavaScript)

```javascript
let lastUpdate = null;

function getCurrentBeat() {
    if (!lastUpdate || !lastUpdate.is_playing) {
        return lastUpdate?.position_beats ?? 0;
    }
    
    const now = Date.now();
    const elapsed_ms = now - lastUpdate.server_timestamp_ms;
    const elapsed_sec = elapsed_ms / 1000;
    const beats_per_sec = lastUpdate.bpm / 60;
    const beats_elapsed = elapsed_sec * beats_per_sec;
    
    return lastUpdate.position_beats + beats_elapsed;
}

// Update display at 60fps using interpolated position
function render() {
    const beat = getCurrentBeat();
    updateBeatDisplay(beat);
    requestAnimationFrame(render);
}

// WebSocket receives 30Hz updates, display runs at 60fps
ws.onmessage = (e) => {
    lastUpdate = JSON.parse(e.data);
    // Optionally adjust for network latency
    lastUpdate.server_timestamp_ms -= estimatedLatency;
};
```

This gives you **sub-millisecond visual accuracy** with only 30Hz network traffic.

---

## Alternative: Audio Hook for True High-Frequency Sampling

If you genuinely need >30Hz sampling (not just display smoothness), the `audio_hook_register_t` runs at audio block rate:

```zig
const AudioHookRegister = extern struct {
    OnAudioBuffer: *const fn (isPost: bool, len: c_int, srate: f64, reg: *AudioHookRegister) callconv(.C) void,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
    input_nch: c_int,   // Set by host
    output_nch: c_int,  // Set by host
    GetBuffer: ?*const fn (isOutput: bool, idx: c_int) callconv(.C) ?[*]f64,
};

// At 44.1kHz/512 samples: ~86Hz (172 calls/sec, pre+post)
// At 44.1kHz/128 samples: ~344Hz
```

**Critical**: This runs on the audio thread. Most REAPER API functions are NOT thread-safe. You'd need atomic operations or a lock-free queue to pass data to the main thread for WebSocket broadcast.

---

## Summary: Where This Leaves You

| What You Have Now | What CSurf Adds | What You Actually Need |
|-------------------|-----------------|------------------------|
| 30Hz timer polling | Instant `SetPlayState()` events | Client-side interpolation |
| Works fine | Same 30Hz for `Run()` | Smooth 60fps display |
| Simple Zig code | C++ shim complexity | ±15ms achieved via math, not polling |

**Recommendation**:

1. **Keep your current timer** — it's already at the maximum useful rate
2. **Add client interpolation** — this is how professional timecode displays work
3. **Optionally add CSurf** — only if you want instant transport state callbacks (play/pause/stop) rather than waiting up to 33ms for the next poll
4. **Skip the audio hook** — overkill for visual beat sync, complex thread safety requirements

The 30Hz polling with client-side BPM interpolation will give you visually perfect beat synchronization. The limiting factor for your use case is network latency and client render timing, not REAPER's polling rate.
