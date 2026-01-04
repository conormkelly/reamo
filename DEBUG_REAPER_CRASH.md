# REAPER Startup Crash — Debugging Guide

**Status:** ✅ RESOLVED
**Last Updated:** 2026-01-04

This document tracks the investigation and resolution of a crash that occurred when REAPER was launched directly (via Finder/double-click) but NOT when launched via `make dev` (terminal).

## Solution Summary

**Root Cause:** Zig allocates ALL local variables at function entry. Our `poll()` functions were creating 2.5MB+ State structs on the stack just by being called, overflowing the 8MB main thread stack when combined with REAPER's deep startup call stack (~45+ frames during modal dialogs).

**The Fix:** Created `pollInto()` methods that write directly into pre-allocated static storage instead of returning by value:
```zig
// Before (crashes - creates 2.5MB on stack)
ProcessingState.cur_tracks = tracks.State.poll(&backend);

// After (safe - writes to existing static storage)
ProcessingState.cur_tracks.pollInto(&backend);
```

**Key insight:** Even though we had moved the *storage* to static memory (`ProcessingState`), the old `poll()` functions still allocated local State structs, copied data into them, then returned them. The function prologue would reserve 2.5MB before any code ran.

---

---

## Quick Context for New Sessions

**The Problem:**
- REAPER crashes with SIGSEGV when opened directly (Finder, `open` command)
- REAPER works fine when launched via `make dev` (which runs `/Applications/REAPER.app/Contents/MacOS/REAPER` from terminal)
- Crash is a **stack overflow** — hitting the stack guard region

**Key Finding:**
The crash occurs because REAPER's startup sequence shows modal dialogs (like "CheckFaultyProject") which fire timer callbacks while deeply nested (~45+ stack frames). Our timer callback adds to this, overflowing the 8MB stack.

---

## Log File Locations

| Log | Path | Purpose |
|-----|------|---------|
| Extension log | `~/Library/Application Support/REAPER/Logs/reamo.log` | Our extension's debug output |
| macOS crash reports | `~/Library/Logs/DiagnosticReports/REAPER-*.ips` | Detailed crash analysis with stack traces |

### Reading Crash Reports

```bash
# Find latest crash report
ls -lt ~/Library/Logs/DiagnosticReports/ | grep -i reaper | head -5

# Key fields to check in .ips files (JSON format):
# - "exception" — crash type (EXC_BAD_ACCESS = memory access violation)
# - "vmRegionInfo" — shows STACK GUARD if stack overflow
# - "faultingThread" — which thread crashed (0 = main thread)
# - "threads[0].frames" — stack trace of crashed thread
```

### Reading Extension Logs

```bash
# Tail the extension log
tail -50 ~/Library/Application\ Support/REAPER/Logs/reamo.log

# Watch live
tail -f ~/Library/Application\ Support/REAPER/Logs/reamo.log
```

---

## The Crash Pattern

### Stack Trace (from crash report)

When launched directly, REAPER's startup creates this deep call stack:

```
start
  → NSApplicationMain
    → NSApplication run
      → macAppFinishInit (REAPER timer)
        → SWELL_CreateDialog
          → MainProc
            → OnStartup_LoadProjects
              → CheckFaultyProject
                → MessageBox (NSRunAlertPanel)
                  → Modal run loop
                    → Timer fires
                      → MainProc
                        → runMiscTimers
                          → OUR processTimerCallback  ← CRASH HERE
```

This is ~45+ stack frames BEFORE our code even runs. When our `processTimerCallback` tries to allocate its local variables (~150KB of buffers originally), it overflows into the stack guard.

### Why `make dev` Works

When launched from terminal:
1. Terminal is the parent process (not launchd)
2. Timing is slightly different
3. The modal dialogs may not appear, or appear with less nesting
4. The startup sequence may complete before our timer fires

---

## What We've Tried

### 1. Disable WebSocket Server Entirely
**Result:** ✅ WORKS — REAPER opens fine, no crash

```zig
// In initTimerCallback:
g_server = null;
g_port = 0;
logging.info("DEBUG: WebSocket server DISABLED for crash testing", .{});
```

**Conclusion:** The crash is related to our code, not REAPER itself.

---

### 2. Add Delay Before WebSocket Server Start
**Result:** ❌ STILL CRASHES — delay just moves when crash occurs

```zig
std.Thread.sleep(2000 * std.time.ns_per_ms); // 2000ms delay
```

The crash happened after the delay, when the WebSocket server tried to start. The UI was visible but frozen during the sleep, then crashed.

**Conclusion:** Sleep blocks the main thread which keeps the deep startup stack alive.

---

### 3. Warmup Period Before Switching to Processing Timer
**Result:** ⚠️ PARTIAL — got further, warmup completed, then crashed

```zig
const WARMUP_TICKS: u32 = 60; // Wait ~2 seconds

fn initTimerCallback() callconv(.c) void {
    if (!g_initialized) {
        g_initialized = true;
        doInitialization();
        return;
    }

    g_warmup_ticks += 1;
    if (g_warmup_ticks < WARMUP_TICKS) {
        return; // Do nothing during warmup
    }

    // Switch to processing timer after warmup
    api.unregisterTimer(&initTimerCallback);
    api.registerTimer(&processTimerCallback);
    g_init_complete = true;
}
```

Log showed:
```
[04:45:11.063] Initialization complete, waiting for warmup
[04:45:13.020] Warmup complete, switching to processing timer
                ← CRASH immediately after
```

**Conclusion:** Warmup lets startup stack unwind, but processTimerCallback itself has too much stack usage.

---

### 4. Move Large Buffers to Static Memory
**Result:** ⚠️ PARTIAL — Helped but not enough

Original: ~150KB of stack-allocated buffers in `processTimerCallback`:
```zig
var buf5: [32768]u8 = undefined;  // 32KB
var buf4: [16384]u8 = undefined;  // 16KB
var buf: [8192]u8 = undefined;    // 8KB x many
// ... etc
```

Fixed: All large buffers moved to static struct:
```zig
const StaticBuffers = struct {
    var snapshot_items: [32768]u8 = undefined;
    var snapshot_tracks: [16384]u8 = undefined;
    var items: [32768]u8 = undefined;
    var tracks: [16384]u8 = undefined;
    // ... etc (~150KB total, now in static memory)
};
```

**Conclusion:** Buffers were not the main issue. The REAL problem is the State structs.

---

### 5. Move State Structs to Static Memory (ProcessingState)
**Result:** ✅ MAJOR PROGRESS — doProcessing() now enters, crash moved deeper

**The Discovery:**
Research revealed the actual stack sizes of our State structs:
- `tracks.State` — ~2.5MB (!)
- `items.State` — ~600KB
- `markers.State` — ~95KB

Zig allocates ALL local `var` declarations at function entry, not lazily. So a function with these as locals needs ~3.2MB of stack space just to enter.

**The Fix:**
Created `ProcessingState` struct for static storage:
```zig
const ProcessingState = struct {
    // Snapshot states (for sending initial state to new clients)
    var snap_transport: transport.State = .{};
    var snap_project: project.State = .{};
    var snap_markers: markers.State = .{};
    var snap_tracks: tracks.State = .{};
    var snap_items: items.State = .{};
    var snap_tempomap: tempomap.State = .{};

    // Current poll states (for change detection)
    var cur_transport: transport.State = .{};
    var cur_project: project.State = .{};
    var cur_markers: markers.State = .{};
    var cur_tracks: tracks.State = .{};
    var cur_items: items.State = .{};
    var cur_tempomap: tempomap.State = .{};
    var cur_metering: tracks.MeteringState = .{};

    // Small arrays that still add up
    var disconnected_buf: [16]usize = undefined;
    var flush_buf: [16]gesture_state.ControlId = undefined;
    var timeout_buf: [16]gesture_state.ControlId = undefined;
    var snapshot_clients: [16]usize = undefined;
};
```

Also added compile-time size assertions:
```zig
comptime {
    const MAX_STATE_SIZE = 4 * 1024 * 1024; // 4MB threshold
    if (@sizeOf(tracks.State) > MAX_STATE_SIZE) {
        @compileError("tracks.State exceeds 4MB");
    }
    // ... similar for items.State, markers.State
}
```

**Result:** `doProcessing()` now enters and passes safety checks! But crash still occurs ~8s after project load.

---

### 6. Checkpoint Logging to Narrow Down Crash Location
**Result:** 🔍 IDENTIFIED — Crash is INSIDE tracks.State.poll()

Added granular checkpoints in doProcessing():
```
checkpoint 1: before WS server check
checkpoint 2: before command processing
checkpoint 3: before HIGH TIER polling
checkpoint 4: after transport poll
checkpoint 4a: before tracks.State.poll  ← LAST LOG BEFORE CRASH
checkpoint 4b: after tracks.State.poll   ← NEVER REACHED
...
```

**Latest log (05:32):**
```
doProcessing() checkpoint 4: after transport poll
doProcessing() checkpoint 4a: before tracks.State.poll
                              ← CRASH HERE, inside tracks.State.poll()
```

**Conclusion:** The crash is now happening inside `tracks.State.poll()` function, not in doProcessing(). The tracks module likely has its own large stack allocations.

---

## Current Architecture (Post-Fix)

### Timer Flow (Simplified)

```
ReaperPluginEntry (called by REAPER on load)
  └── Registers initTimerCallback

initTimerCallback (first call)
  └── doInitialization()
      └── Allocates SharedState
      └── Initializes state caches using pollInto()
      └── Sets g_initialized = true

initTimerCallback (second call)
  └── Unregisters self
  └── Registers processTimerCallback
  └── Sets g_init_complete = true

processTimerCallback (normal operation, ~30Hz)
  └── Calls doProcessing() directly
      └── Deferred WS server start (first 30 frames)
      └── State polling using pollInto() - NO large stack allocations
      └── Change detection and broadcasting
```

### Key Design Decisions

1. **pollInto() instead of poll()**: Large State structs (tracks ~2.5MB, items ~600KB, markers ~95KB) use output pointers instead of return-by-value
2. **ProcessingState static storage**: All poll results stored in static struct, not stack
3. **No warmup delays**: Root cause fixed, so delays removed for faster startup
4. **WS_START_DELAY_FRAMES**: Still used (30 frames = ~1s) to let REAPER UI settle before binding port

---

## Theories & Next Steps

### Current Theory
Even with warmup complete, `processTimerCallback` may still be called from a moderately deep stack. The function's prologue (entering the function, setting up stack frame) may still overflow if the stack frame is too large.

### Things to Try

1. **✅ Static buffers** — Current attempt. Reduces stack frame from ~150KB to ~1KB.

2. **Reduce function complexity** — Split processTimerCallback into smaller functions called conditionally. Only allocate what's needed per-frame.

3. **Check if crash still happens** — If static buffers fix it, we're done. If not, need to investigate further.

4. **Profile stack usage** — Add logging at function entry to see how much stack is available.

5. **Defer more aggressively** — Move ALL processing to a later phase, not just WS server startup.

---

## Useful Commands

### Build and Install
```bash
cd "/Users/conor/Library/Application Support/REAPER/reaper_www_root"
make extension
```

### Launch REAPER (terminal — works)
```bash
make dev
# or directly:
/Applications/REAPER.app/Contents/MacOS/REAPER
```

### Launch REAPER (Finder — crashes)
```bash
open /Applications/REAPER.app
```

### Check Latest Crash
```bash
ls -lt ~/Library/Logs/DiagnosticReports/ | grep -i reaper | head -1
cat ~/Library/Logs/DiagnosticReports/REAPER-*.ips | head -100
```

### Disable Extension Temporarily
```bash
mv ~/Library/Application\ Support/REAPER/UserPlugins/reaper_reamo.dylib \
   ~/Library/Application\ Support/REAPER/UserPlugins/reaper_reamo.dylib.disabled
```

---

## Progress Log

| Date | Attempt | Result |
|------|---------|--------|
| 2026-01-04 | Disabled WS server | Works — confirms our code causes crash |
| 2026-01-04 | 100ms delay before WS start | Crash, got further |
| 2026-01-04 | 2000ms delay before WS start | Crash, UI visible then crashed |
| 2026-01-04 | 60-tick warmup before switching timers | Crash, warmup completed then crashed |
| 2026-01-04 | Static buffers for processTimerCallback | ❌ Still crashes at offset 24 |
| 2026-01-04 | Try Release build (smaller stack frames) | ❌ Still crashes |
| 2026-01-04 | Increase warmup to 5 seconds (150 ticks) | ⚠️ Got further, still crashed |
| 2026-01-04 | Add 3s trampoline before processTimerCallback | ⚠️ Trampoline works, crash at processTimerCallback entry |
| 2026-01-04 | ReleaseSafe build + trampoline | ⚠️ Got to 15s, still crashed at offset 24 |
| 2026-01-04 | Split: processTimerCallback wrapper + doProcessing | ✅ processTimerCallback entered! Crash now in doProcessing |
| 2026-01-04 | Move State structs to ProcessingState static storage | ✅ doProcessing entered, crash in tracks.State.poll() |
| 2026-01-04 | **pollInto() for tracks/items/markers** | ✅ **FIXED!** No crash after 30s+ |
| 2026-01-04 | Remove warmup delays (no longer needed) | ✅ Simplified timer flow, still works |

---

## Notes & Gotchas

- **Stack size:** macOS provides 8MB stack for main thread, with 56MB guard region
- **Modal dialogs:** REAPER's startup shows modal dialogs that run nested event loops
- **Timer callbacks:** Fire during modal loops, adding to already-deep stack
- **Zig stack allocation:** All local `var` declarations are allocated at function entry, not lazily
- **`make dev` vs direct:** Different parent process (terminal vs launchd), different timing
- **Crash offset 24:** Crash happens at function entry (prologue), not deep in function body

---

## Related Files

- `extension/src/main.zig` — Timer callbacks, initialization, StaticBuffers
- `extension/src/ws_server.zig` — WebSocket server (not the direct cause, but related)
- `extension/src/logging.zig` — Log file setup
