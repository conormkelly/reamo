# Command Queue Latency Optimization

## Summary

Reduce command latency from ~19ms average to ~8ms by adding a dedicated 100Hz timer for command queue processing, separate from the 30Hz UI polling timer. Benefits ALL WebSocket commands (MIDI, transport, parameters, track selection), not just MIDI.

---

## Current Architecture

```
WebSocket Thread                    Main Thread (30Hz timer)
────────────────                    ────────────────────────
Receive command (any type)
        ↓
pushCommand() ──── mutex queue ────→ popCommand()
                                          ↓
                                    dispatch() → handler()
```

**Problem**: Commands wait 0-33ms in the queue (average ~16ms) because the timer only fires at 30Hz.

---

## Proposed Architecture

```
WebSocket Thread          Main Thread (100Hz)         Main Thread (30Hz)
────────────────          ──────────────────          ──────────────────
Receive command
        ↓
pushCommand() ─── queue ──→ commandQueueCallback()    Tiered polling
                                   ↓                  Broadcasts
                             dispatch()               Client management
                                   ↓                  (fallback drain)
                             handler()
```

**Solution**: Separate 100Hz timer drains the command queue. UI polling stays at 30Hz.

The 30Hz timer retains a fallback drain in case the 100Hz timer fails to start.

---

## Latency Comparison

| Metric | Before (30Hz) | After (100Hz) |
|--------|---------------|---------------|
| Timer interval | 33ms | 10ms |
| Queue wait (worst) | 33ms | 10ms |
| Queue wait (avg) | ~16ms | ~5ms |
| Network RTT | ~0.5ms | ~0.5ms |
| Audio buffer (128@48k) | ~2.7ms | ~2.7ms |
| **Total worst-case** | **~36ms** | **~13ms** |
| **Total average** | **~19ms** | **~8ms** |

8ms average is comparable to USB MIDI controllers.

---

## Platform Implementation

### TIMERPROC Pattern (Key Insight)

Use `SetTimer` with a **TIMERPROC callback** — no window procedure or `WM_TIMER` handling needed:

```c
// Windows - callback fires directly on main thread
SetTimer(NULL, 0, 10, myTimerProc);

void CALLBACK myTimerProc(HWND hwnd, UINT msg, UINT_PTR id, DWORD time) {
    drainCommandQueue();  // Safe for REAPER API calls
}
```

This works identically on Windows (Win32) and macOS/Linux (SWELL).

### Platform APIs

| Platform | API | Notes |
|----------|-----|-------|
| Windows | Native Win32 `SetTimer()` | TIMERPROC callback on main thread |
| macOS | SWELL `SetTimer()` | Wraps CFRunLoopTimer, millisecond precision |
| Linux | SWELL `SetTimer()` | Wraps glib/GTK timers |

SWELL provides Win32-compatible API on macOS and Linux.

### Windows Timer Resolution Caveat

Windows `SetTimer()` has default ~15.6ms resolution. Requesting 10ms may fire at 15-16ms unless system timer resolution is increased.

**Mitigation**: REAPER likely already calls `timeBeginPeriod(1)` for audio timing. Test empirically first — if intervals are ~15ms instead of ~10ms, consider:

```c
timeBeginPeriod(1);  // At extension init
// ... extension runs ...
timeEndPeriod(1);    // At extension deinit
```

Even 15ms intervals are a significant improvement over 33ms.

### macOS Timer Resolution

SWELL's `SetTimer` on macOS wraps `CFRunLoopTimerCreate`. CFRunLoopTimer has millisecond-level precision — no 15.6ms floor like Windows. 10ms intervals work reliably.

---

## Implementation Plan

### Phase 1: SWELL Bindings

**File**: `extension/src/platform/swell.zig`

Add timer function bindings (~5 lines):

```zig
// Timer callback type
pub const TIMERPROC = *const fn (?HWND, c_uint, usize, c_uint) callconv(.c) void;

// Timer message (for reference, not needed with TIMERPROC)
pub const WM_TIMER: c_uint = 0x0113;

// SWELL timer functions (need C bridge wrappers)
extern fn zig_swell_SetTimer(hwnd: ?HWND, nIDEvent: usize, uElapse: c_uint, lpTimerFunc: ?TIMERPROC) usize;
extern fn zig_swell_KillTimer(hwnd: ?HWND, uIDEvent: usize) c_int;

pub fn setTimer(hwnd: ?HWND, id: usize, interval_ms: c_uint, callback: ?TIMERPROC) usize {
    if (comptime !is_swell_platform) {
        // Windows: use native Win32 (handled in fast_timer.zig)
        return 0;
    }
    return zig_swell_SetTimer(hwnd, id, interval_ms, callback);
}

pub fn killTimer(hwnd: ?HWND, id: usize) bool {
    if (comptime !is_swell_platform) {
        return false;
    }
    return zig_swell_KillTimer(hwnd, id) != 0;
}
```

**File**: `extension/src/platform/zig_swell_bridge.mm`

Add C wrappers for SWELL functions:

```objc
extern "C" uintptr_t zig_swell_SetTimer(HWND hwnd, uintptr_t nIDEvent, unsigned int uElapse, TIMERPROC lpTimerFunc) {
    return SetTimer(hwnd, nIDEvent, uElapse, lpTimerFunc);
}

extern "C" int zig_swell_KillTimer(HWND hwnd, uintptr_t uIDEvent) {
    return KillTimer(hwnd, uIDEvent);
}
```

### Phase 2: Fast Timer Module

**File**: `extension/src/platform/fast_timer.zig`

Unified interface using TIMERPROC pattern:

```zig
const std = @import("std");
const builtin = @import("builtin");
const swell = @import("swell.zig");
const logging = @import("../core/logging.zig");

pub const TIMERPROC = *const fn (?*anyopaque, c_uint, usize, c_uint) callconv(.c) void;

const COMMAND_TIMER_INTERVAL: c_uint = 10; // 10ms = 100Hz

// Win32 imports (Windows only)
const win32 = if (builtin.os.tag == .windows) struct {
    extern "user32" fn SetTimer(hwnd: ?*anyopaque, nIDEvent: usize, uElapse: c_uint, lpTimerFunc: ?TIMERPROC) callconv(.c) usize;
    extern "user32" fn KillTimer(hwnd: ?*anyopaque, uIDEvent: usize) callconv(.c) c_int;
} else struct {};

pub const FastTimer = struct {
    timer_id: usize = 0,
    running: bool = false,

    pub fn start(self: *FastTimer, callback: TIMERPROC) !void {
        if (self.running) return;

        const id = if (builtin.os.tag == .windows)
            win32.SetTimer(null, 0, COMMAND_TIMER_INTERVAL, callback)
        else
            swell.setTimer(null, 0, COMMAND_TIMER_INTERVAL, callback);

        if (id == 0) {
            logging.err("FastTimer: SetTimer failed", .{});
            return error.TimerCreationFailed;
        }

        self.timer_id = id;
        self.running = true;
        logging.info("FastTimer: started at {}ms interval (id={})", .{ COMMAND_TIMER_INTERVAL, id });
    }

    pub fn stop(self: *FastTimer) void {
        if (!self.running) return;

        if (builtin.os.tag == .windows) {
            _ = win32.KillTimer(null, self.timer_id);
        } else {
            _ = swell.killTimer(null, self.timer_id);
        }

        self.running = false;
        self.timer_id = 0;
        logging.info("FastTimer: stopped", .{});
    }

    pub fn isRunning(self: *const FastTimer) bool {
        return self.running;
    }
};
```

### Phase 3: Integration

**File**: `extension/src/main.zig`

1. Add fast timer global and callback:

```zig
const fast_timer = @import("platform/fast_timer.zig");

var g_fast_timer: fast_timer.FastTimer = .{};

/// 100Hz command queue timer callback
/// Called directly by OS timer via TIMERPROC - runs on main thread
fn commandQueueTimerCallback(_: ?*anyopaque, _: c_uint, _: usize, _: c_uint) callconv(.c) void {
    const shared_state = g_shared_state orelse return;

    // Drain all pending commands
    while (shared_state.popCommand()) |cmd| {
        var command = cmd;
        defer command.deinit();
        commands.dispatch(&backend, command.client_id, command.data, shared_state, g_gesture_state, &g_playlist_state);
    }
}
```

1. Start timer after WebSocket server starts (in `doProcessing`):

```zig
// After WebSocket server starts successfully
if (!g_fast_timer.isRunning()) {
    g_fast_timer.start(&commandQueueTimerCallback) catch |err| {
        logging.warn("FastTimer failed to start: {s} - falling back to 30Hz", .{@errorName(err)});
    };
}
```

1. Keep fallback drain in 30Hz timer:

```zig
// In doProcessing() - fallback only if fast timer not running
if (!g_fast_timer.isRunning()) {
    while (shared_state.popCommand()) |cmd| {
        var command = cmd;
        defer command.deinit();
        commands.dispatch(&backend, command.client_id, command.data, shared_state, g_gesture_state, &g_playlist_state);
    }
}
```

1. Stop timer during shutdown:

```zig
fn shutdown() void {
    g_fast_timer.stop();
    // ... rest of shutdown
}
```

### Phase 4: Testing & Validation

Add temporary delta logging to verify timer intervals:

```zig
var g_last_timer_tick: i64 = 0;

fn commandQueueTimerCallback(_: ?*anyopaque, _: c_uint, _: usize, _: c_uint) callconv(.c) void {
    const now = std.time.milliTimestamp();
    const delta = now - g_last_timer_tick;
    g_last_timer_tick = now;

    if (delta > 15 and g_last_timer_tick != 0) {
        logging.warn("FastTimer slip: {}ms", .{delta});
    }

    // ... drain queue ...
}
```

**Test on**:

- macOS (ARM64 + Intel)
- Windows 10/11
- Linux (if available)

**Validate**:

- Timer fires at ~10ms intervals (or ~15ms on Windows without timeBeginPeriod)
- No timer slips under normal load
- No impact on UI responsiveness
- All commands feel more responsive (not just MIDI)

---

## Queue Implementation

**Decision**: Keep existing mutex-based queue.

| Implementation | Cost per operation | Benefit |
|----------------|-------------------|---------|
| Mutex (current) | ~20-100ns | Already working, tested |
| Lock-free SPSC | ~10-50ns | ~50ns savings |

The timer interval (10,000,000ns) dwarfs the queue operation time. Lock-free is a micro-optimization that yields <0.1ms improvement.

---

## Rollback Plan

If issues arise:

1. Fast timer fails to start → automatic fallback to 30Hz (built-in)
2. Runtime issues → call `g_fast_timer.stop()` to disable
3. No user-visible change except latency returns to current levels

---

## Success Criteria

- [ ] Timer fires reliably at ≤15ms intervals on all platforms
- [ ] Average command latency reduced from ~19ms to <10ms
- [ ] No regressions in UI responsiveness
- [ ] No increase in CPU usage under normal operation
- [ ] Zero user-facing configuration required
- [ ] Graceful fallback if timer fails

---

## Future Considerations

### Virtual MIDI Ports (Deferred)

For users requiring absolute minimum latency (<5ms), virtual MIDI ports bypass the timer entirely:

- **macOS**: CoreMIDI virtual ports (trivial, no drivers)
- **Windows**: Requires virtualMIDI SDK licensing or user-installed loopMIDI

**Tradeoffs**: Users must manually select the virtual port in REAPER preferences. Current approach "just works" with armed tracks.

### Audio Hook Callback (Not Recommended)

REAPER's audio hook fires at audio buffer rate (~750Hz at 128 samples/48kHz) but runs on the audio thread. Cannot call `StuffMIDIMessage` safely from there.

---

## References

- REAPER Extension SDK: `StuffMIDIMessage(mode, msg1, msg2, msg3)`
- [cfillion's timer boost gist](https://gist.github.com/cfillion/d4d3e16b65c90bb7609a97edadf4bff9) - "Make REAPER scripts go brrr"
- SWS Extension patterns (queue-then-dispatch)
- ReaLearn architecture (VST for lowest latency)
- cameron314/readerwriterqueue (lock-free SPSC, if ever needed)
