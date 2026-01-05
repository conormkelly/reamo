# Reamo Backend Architecture Audit

**Date:** 2026-01-04
**Zig Version:** 0.15
**Purpose:** Stability audit of the REAPER extension backend for review by an external expert

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Architecture Overview](#architecture-overview)
3. [Threading Model](#threading-model)
4. [Memory Management Patterns](#memory-management-patterns)
5. [FFI Safety Layer](#ffi-safety-layer)
6. [Pointer Lifecycle Management](#pointer-lifecycle-management)
7. [Error Handling Patterns](#error-handling-patterns)
8. [Command Dispatch Architecture](#command-dispatch-architecture)
9. [State Polling System](#state-polling-system)
10. [Identified Concerns](#identified-concerns)
11. [Tradeoffs Analysis](#tradeoffs-analysis)
12. [Research Query](#research-query-for-external-review)

---

## Executive Summary

Reamo is a WebSocket-based remote control surface for REAPER (Digital Audio Workstation). The extension runs as a native plugin inside REAPER, polling DAW state at ~30Hz and broadcasting JSON events to connected clients (iPads/tablets). The core constraint is **never crash REAPER** — musicians may have hours of unsaved work.

The backend is written in Zig 0.15, using:
- Comptime duck-typing (`anytype`) for testability without runtime overhead
- Static memory allocation for large state structs to avoid stack overflow
- Ring buffers and fixed-size arrays to bound memory usage
- A layered FFI safety system to handle invalid data from REAPER's C API

**Overall Assessment:** The architecture is thoughtfully designed with safety as a primary concern. Several patterns are used consistently, but there are areas that warrant expert review to ensure we're following Zig 0.15 best practices and not introducing subtle bugs.

---

## Architecture Overview

### Project Structure

```
extension/src/
├── main.zig              # Entry point, timer callbacks, polling orchestration
├── reaper.zig            # API abstraction facade (re-exports backends)
├── reaper/
│   ├── raw.zig           # Pure C function pointer bindings (~80 functions)
│   ├── real.zig          # Production backend wrapper with FFI validation
│   ├── backend.zig       # Comptime interface validation
│   ├── types.zig         # Shared data types (BeatsInfo, MarkerInfo, etc.)
│   └── mock/             # Test mock implementation (7 files)
├── commands/
│   ├── mod.zig           # Dispatch logic and ResponseWriter
│   ├── registry.zig      # Comptime tuple of all ~70 handlers
│   └── [domain].zig      # Domain-specific handlers (tracks, transport, etc.)
├── [state modules]       # transport.zig, tracks.zig, markers.zig, items.zig...
├── ws_server.zig         # WebSocket server and client management
├── protocol.zig          # JSON parsing (zero allocation)
├── ffi.zig               # Safe float-to-int conversion, pointer validation
├── errors.zig            # Error type hierarchy and event broadcasting
├── logging.zig           # Ring buffer logging with crash recovery
└── gesture_state.zig     # Undo coalescing for continuous controls
```

### Key Files by Size (indicates complexity)

| File | Size | Purpose |
|------|------|---------|
| `reaper/raw.zig` | ~30KB | C API bindings (~80 function pointers) |
| `tracks.zig` | ~25KB | Track state polling (128 tracks × FX × sends) |
| `main.zig` | ~25KB | Timer callbacks, polling orchestration |
| `ws_server.zig` | ~20KB | WebSocket server, thread-safe client management |
| `protocol.zig` | ~19KB | Zero-allocation JSON parsing |
| `playlist.zig` | ~36KB | Cue list/playlist engine (complex state machine) |

---

## Threading Model

### Two Threads

```
┌─────────────────────────┐     ┌──────────────────────────┐
│  Main Thread            │     │  WebSocket Thread        │
│  (REAPER UI context)    │     │  server.listen()         │
│                         │     │                          │
│  Timer callback @30Hz:  │◄───►│  Event handlers:         │
│  - Poll REAPER state    │     │  - clientMessage()       │
│  - Diff & broadcast     │     │  - close()               │
│  - Process command queue│     │                          │
└───────────┬─────────────┘     └──────────┬───────────────┘
            │                              │
            └──────────────┬───────────────┘
                           ▼
                ┌────────────────────────────┐
                │  SharedState (mutex)       │
                │  - CommandRingBuffer       │
                │  - Client connections map  │
                │  - Snapshot request queue  │
                └────────────────────────────┘
```

### Thread Safety Pattern

**All REAPER API calls happen on the main thread.** The WebSocket thread:
1. Receives client messages
2. Pushes commands to a mutex-protected ring buffer
3. Main thread timer callback pops and processes commands
4. Responses/broadcasts sent via mutex-protected client map

**Key files:**
- `ws_server.zig:71` — `SharedState` struct with `Thread.Mutex`
- `ws_server.zig:28` — `CommandRingBuffer` (fixed-size, O(1) push/pop)
- `main.zig:332-336` — Command processing loop in timer callback

### Atomic Operations

Only one atomic is used — for the `time_precise` function pointer:

```zig
// ws_server.zig:98
time_precise_fn_ptr: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

// Store (main thread, release semantics)
pub fn setTimePreciseFn(self: *SharedState, func: TimePreciseFn) void {
    self.time_precise_fn_ptr.store(@intFromPtr(func), .release);
}

// Load (WS thread, acquire semantics)
pub fn timePreciseMs(self: *SharedState) f64 {
    const ptr_val = self.time_precise_fn_ptr.load(.acquire);
    if (ptr_val != 0) {
        const func: TimePreciseFn = @ptrFromInt(ptr_val);
        return func() * 1000.0;
    }
    return 0;
}
```

**Question:** Is this pattern correct for sharing a function pointer between threads? The function itself (`time_precise`) is a REAPER API call that's documented as thread-safe for reading time.

---

## Memory Management Patterns

### Pattern 1: Static Storage for Large State

Large state structs (~2.5MB tracks, ~600KB items, ~95KB markers) are stored statically to avoid stack overflow:

```zig
// main.zig:266-289 — Static state storage
const ProcessingState = struct {
    var snap_transport: transport.State = .{};
    var snap_tracks: tracks.State = .{};  // ~2.5MB
    var snap_items: items.State = .{};    // ~600KB
    // ... etc
};

// Global state for change detection
var g_last_tracks: tracks.State = .{};
var g_last_items: items.State = .{};
```

**Why:** REAPER timer callbacks can fire during modal dialogs with ~45+ stack frames. Zig allocates all local variables at function entry, so a 2.5MB local variable would overflow the stack.

**Pattern usage:** `pollInto(self: *State, api: anytype)` mutates existing state instead of returning a new struct:

```zig
// tracks.zig:158
pub fn pollInto(self: *State, api: anytype) void {
    self.count = 0; // Reset existing struct
    // ... populate fields
}
```

### Pattern 2: Static Buffers for JSON Serialization

```zig
// main.zig:224-245
const StaticBuffers = struct {
    var snapshot_transport: [512]u8 = undefined;
    var snapshot_tracks: [16384]u8 = undefined;
    var tracks_buf: [16384]u8 = undefined;
    // ... etc
};
```

**Concern:** These are shared across the entire timer callback. If any code path writes to the same buffer concurrently (within the same callback, since it's single-threaded), there could be corruption. Currently this appears safe because buffers are used sequentially, but it's implicit rather than enforced.

### Pattern 3: Heap Allocation for Dynamic Data

Command data is heap-allocated when crossing thread boundary:

```zig
// ws_server.zig:245-261
pub fn pushCommand(self: *SharedState, client_id: usize, data: []const u8) bool {
    self.mutex.lock();
    defer self.mutex.unlock();

    // Make a copy of the data for the main thread
    const data_copy = self.allocator.dupe(u8, data) catch return false;

    self.commands.push(.{
        .client_id = client_id,
        .data = data_copy,
        .allocator = self.allocator,
    }) catch {
        self.allocator.free(data_copy);
        return false;
    };
    return true;
}
```

### Pattern 4: Per-Call Heap Allocation for Large Responses

```zig
// commands/mod.zig:115-134
pub fn successLargePayload(self: *ResponseWriter, payload: []const u8) void {
    const allocator = std.heap.c_allocator;
    const buf = allocator.alloc(u8, 131072) catch {
        self.err("ALLOC_FAILED", "Failed to allocate response buffer");
        return;
    };
    defer allocator.free(buf);
    // ... format and send
}
```

**Rationale from research/ZIG_MEMORY_MANAGEMENT.md:** Timer callbacks run on main thread, not audio thread, so heap allocation is safe. Per-call allocation avoids shared state issues between concurrent commands (though commands are processed sequentially, this provides defense in depth).

### Memory Bounds

All arrays have compile-time size limits:

| Structure | Limit | Size Impact |
|-----------|-------|-------------|
| Tracks | 128 | ~20KB per track struct |
| FX per track | 64 | ~256 bytes per FX |
| Sends per track | 16 | ~140 bytes per send |
| Items | 512 | ~1KB per item |
| Takes per item | 8 | ~100 bytes per take |
| Markers | 256 | ~150 bytes per marker |
| Regions | 256 | ~180 bytes per region |
| Playlists | 16 | ~8KB per playlist |
| Entries per playlist | 64 | ~16 bytes per entry |

Comptime assertions guard against accidental increases:

```zig
// main.zig:250-261
comptime {
    const MAX_STATE_SIZE = 4 * 1024 * 1024; // 4MB threshold
    if (@sizeOf(tracks.State) > MAX_STATE_SIZE) {
        @compileError("tracks.State exceeds 4MB");
    }
}
```

---

## FFI Safety Layer

### Architecture

```
REAPER C API (untrusted)
         │
         ▼
┌─────────────────────────┐
│  raw.zig                │  Pure C bindings, returns what REAPER returns
│  Returns: f64, ?*ptr    │
└────────────┬────────────┘
             │
             ▼
┌─────────────────────────┐
│  real.zig (RealBackend) │  Validation layer
│  Returns: FFIError!T    │  Uses ffi.safeFloatToInt()
└────────────┬────────────┘
             │
             ▼
┌─────────────────────────┐
│  State modules          │  Handle errors with catch
│  tracks.zig, etc.       │  t.solo = api.getTrackSolo(track) catch null;
└─────────────────────────┘
```

### ffi.zig — Core Safety Functions

```zig
// ffi.zig:30-40
pub fn safeFloatToInt(comptime T: type, value: f64) FFIError!T {
    if (std.math.isNan(value)) return error.FloatIsNaN;
    if (std.math.isInf(value)) return error.FloatIsInf;

    const min_val: f64 = @floatFromInt(std.math.minInt(T));
    const max_val: f64 = @floatFromInt(std.math.maxInt(T));

    if (value < min_val or value > max_val) return error.IntegerOverflow;

    return @intFromFloat(value);
}
```

**Why this matters:** Zig's `@intFromFloat` **panics** on NaN/Inf. REAPER can return NaN/Inf from stale pointers or corrupt state. Without this layer, a single corrupt track pointer could crash REAPER.

### Usage Pattern in RealBackend

```zig
// reaper/real.zig:301-303
pub fn getTrackSolo(self: *const RealBackend, track: *anyopaque) ffi.FFIError!c_int {
    return ffi.safeFloatToInt(c_int, self.inner.getTrackSolo(track));
}
```

### Usage Pattern in State Modules

```zig
// tracks.zig:189-191
// getTrackSolo returns error on NaN/Inf - propagate as null to client
t.solo = api.getTrackSolo(track) catch null;
```

**Propagation to frontend:** JSON serialization handles null values — clients see `"solo": null` for corrupt data instead of garbage or crashes.

---

## Pointer Lifecycle Management

### The Problem

REAPER objects (tracks, items, takes) are returned as opaque pointers (`*anyopaque`). These can become invalid if the user deletes the object while our code holds a reference.

### Current Approach: Index-Based Lookup per Call

We don't cache pointers between timer callbacks:

```zig
// tracks.zig:167
if (api.getTrackByUnifiedIdx(idx)) |track| {
    // Use track within this scope only
    t.volume = api.getTrackVolume(track);
    // ...
}
```

Every poll cycle re-fetches pointers by index. This is safer but means:
1. We never hold stale pointers across callbacks
2. If a track is deleted mid-callback, subsequent API calls return null/garbage
3. FFI layer catches garbage and returns errors

### Commands: Lookup + Immediate Use

```zig
// commands/tracks.zig:42-44
const track = api.getTrackByUnifiedIdx(track_idx) orelse {
    response.err("NOT_FOUND", "Track not found");
    return;
};
// Immediate use, no storage
_ = api.csurfSetVolume(track, clamped, true);
```

**Question:** What happens if the track is deleted between the lookup and the API call? This is a race condition window, though extremely small. REAPER's API doesn't provide a way to validate pointers before use (ValidatePtr2 exists but we're not using it).

### Unified Indexing

Our API uses "unified indexing" where 0 = master track, 1+ = user tracks. REAPER's native API treats master separately:

```zig
// reaper/raw.zig (somewhere in the file)
pub fn getTrackByUnifiedIdx(self: *const Api, idx: c_int) ?*anyopaque {
    if (idx == 0) {
        return self.masterTrack();
    } else {
        return self.getTrackByIdx(idx - 1);  // Adjust for REAPER's 0-based user tracks
    }
}
```

---

## Error Handling Patterns

### Error Type Hierarchy

```zig
// errors.zig
pub const FFIError = error{
    NullPointer,
    FloatIsNaN,
    FloatIsInf,
    IntegerOverflow,
    InvalidPointer,
};

pub const ReaperStateError = error{
    TrackDeleted,
    ItemDeleted,
    TakeDeleted,
    NoActiveProject,
    InvalidProject,
    IndexOutOfBounds,
};

pub const ResourceError = error{
    OutOfMemory,
    BufferFull,
    QueueOverflow,
    TooManyClients,
    LimitExceeded,
};
```

### Error Propagation Strategies

1. **Nullable fields** — For non-critical data, propagate as `null`:
   ```zig
   t.color = api.getTrackColor(track) catch null;
   ```

2. **Default values** — For required data with safe defaults:
   ```zig
   t.solo = api.getTrackSolo(track) catch 0;
   ```

3. **Early return with error response** — For commands:
   ```zig
   const track = api.getTrackByUnifiedIdx(track_idx) orelse {
       response.err("NOT_FOUND", "Track not found");
       return;
   };
   ```

4. **Silent skip** — For non-essential operations:
   ```zig
   const json = state.toJson(&buf) orelse return;  // Skip broadcast
   ```

### Rate-Limited Error Broadcasting

```zig
// errors.zig:299-330
pub const ErrorRateLimiter = struct {
    last_broadcast: [MAX_ERROR_CODES]i64 = [_]i64{0} ** MAX_ERROR_CODES,
    const MIN_INTERVAL_SECS: i64 = 1;

    pub fn shouldBroadcast(self: *ErrorRateLimiter, code: ErrorCode, time: i64) bool {
        // ...
    }
};
```

Prevents flooding clients with repeated errors.

---

## Command Dispatch Architecture

### Comptime Registry Pattern

```zig
// commands/registry.zig
pub const all = .{
    .{ "transport/play", transport.handlePlay },
    .{ "transport/stop", transport.handleStop },
    // ... ~70 entries
};
```

### Inline For Dispatch

```zig
// commands/mod.zig:217-222
inline for (comptime_registry.all) |entry| {
    if (std.mem.eql(u8, cmd.command, entry[0])) {
        entry[1](api, cmd, &response);
        return;
    }
}
```

**Why `inline for`:** Unrolls at compile time, resulting in a series of if-else checks. Zero runtime overhead for the registry lookup.

**Why not a HashMap:** Function pointers in Zig require concrete types. Using `anytype` for duck-typing prevents storing handlers in a runtime data structure. The comptime tuple approach preserves type information.

### Handler Signature

```zig
pub fn handleSetVolume(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    // api accepts RealBackend or MockBackend via duck typing
}
```

---

## State Polling System

### Tiered Polling

```zig
// main.zig:70-78
// HIGH TIER (30Hz): Transport, Tracks, Metering - every frame
// MEDIUM TIER (5Hz): Markers, Regions, Items, Project - every 6th frame
// LOW TIER (1Hz): Tempomap, Project Notes - every 30th frame

var g_frame_counter: u32 = 0;
const MEDIUM_TIER_INTERVAL: u32 = 6;
const LOW_TIER_INTERVAL: u32 = 30;
```

### Change Detection

Each state module has an `eql()` function:

```zig
// tracks.zig:146-152
pub fn eql(self: *const State, other: *const State) bool {
    if (self.count != other.count) return false;
    for (0..self.count) |i| {
        if (!self.tracks[i].eql(other.tracks[i])) return false;
    }
    return true;
}
```

Only broadcast on change:

```zig
// main.zig:473-481
const tracks_changed = !ProcessingState.cur_tracks.eql(&g_last_tracks);
if (tracks_changed or has_metering) {
    if (ProcessingState.cur_tracks.toJson(&StaticBuffers.tracks_buf, metering_ptr)) |json| {
        shared_state.broadcast(json);
    }
}
g_last_tracks = ProcessingState.cur_tracks;
```

---

## Identified Concerns

### 1. Static Buffer Sharing (Medium Risk)

Multiple JSON serialization operations share the same static buffers. While currently used sequentially, there's no compile-time enforcement:

```zig
const StaticBuffers = struct {
    var tracks_buf: [16384]u8 = undefined;  // Used for track broadcasts
    var snapshot_tracks: [16384]u8 = undefined;  // Used for snapshots
};
```

**Question:** Is there a Zig pattern to enforce that a buffer is "in use" at compile time?

### 2. Pointer Validation Gap (Low Risk)

We lookup pointers and use them immediately, but there's no validation step:

```zig
const track = api.getTrackByUnifiedIdx(track_idx) orelse return;
// What if track becomes invalid here?
_ = api.csurfSetVolume(track, volume, true);
```

REAPER has `ValidatePtr2` but we don't use it. The risk is low because:
- Window is microseconds
- FFI layer catches NaN/Inf from invalid reads
- Writes to invalid pointers are the real concern

**Question:** Should we wrap all pointer-accepting functions with validation?

### 3. Command Queue Overflow Handling (Low Risk)

When the command queue is full, we silently drop commands:

```zig
// ws_server.zig:399-402
if (!self.state.pushCommand(self.id, data)) {
    try self.conn.writeText("{\"type\":\"error\",\"error\":{\"code\":\"QUEUE_FULL\",...}}");
}
```

Client gets an error, but there's no backpressure mechanism. With 256 slots and ~30Hz processing, this would require ~8000 commands/second to overflow — extremely unlikely in practice.

### 4. Allocator Choice Consistency

We use different allocators in different contexts:

| Location | Allocator | Why |
|----------|-----------|-----|
| `doInitialization` | `std.heap.page_allocator` | Long-lived allocations |
| `successLargePayload` | `std.heap.c_allocator` | Per-call, needs libc compat |
| `GestureState` | Passed in (page_allocator) | Inherited from main |
| `SharedState` | Passed in (page_allocator) | Inherited from main |

**Question:** Should we standardize on one allocator? `c_allocator` is needed for C ABI compatibility anyway.

### 5. Error Swallowing in Cleanup

Some cleanup operations silently ignore errors:

```zig
// main.zig:889-891
if (api) |*a| {
    a.unregisterTimer(&processTimerCallback);  // What if this fails?
}
```

For shutdown, this is probably fine (best-effort cleanup), but it's inconsistent with the defensive programming elsewhere.

### 6. Large State Copy on Change Detection

```zig
g_last_tracks = ProcessingState.cur_tracks;  // ~2.5MB copy
```

This happens every frame where tracks changed. Zig should optimize this to a memcpy, but it's still 2.5MB of data movement.

**Question:** Is there a better pattern? Copy-on-write? Double buffering with pointer swap?

---

## Tradeoffs Analysis

### Static vs Heap Allocation

**Current:** Static storage for state, heap for commands/responses.

| Approach | Pros | Cons |
|----------|------|------|
| Static (current) | No allocation overhead, deterministic | Fixed size, can't grow, reentrancy concerns |
| Heap everywhere | Flexible, clear ownership | More allocation points, harder to bound memory |
| Arena per callback | Clear lifetime, batch free | Still needs sizing, overhead |

**Recommendation:** Current approach is reasonable. Document the reentrancy assumption (single-threaded timer callback).

### Polling vs Event-Driven

**Current:** Polling at fixed intervals.

| Approach | Pros | Cons |
|----------|------|------|
| Polling (current) | Simple, works with any REAPER version | CPU overhead even when idle |
| Control Surface API | Event-driven, lower overhead | Complex integration, version dependent |
| Hybrid | Best of both | Implementation complexity |

**Recommendation:** Polling is appropriate for this use case. Control Surface API would be a major architectural change.

### Comptime vs Runtime Dispatch

**Current:** Comptime tuple with `inline for`.

| Approach | Pros | Cons |
|----------|------|------|
| Comptime (current) | Zero runtime overhead, type-safe | Binary size, compile time |
| Runtime HashMap | Smaller binary, dynamic registration | Runtime lookup cost, type erasure |

**Recommendation:** Comptime approach is idiomatic for Zig and appropriate here.

---

## Research Query for External Review

### Context

We are building **Reamo**, a WebSocket-based remote control surface for REAPER (a Digital Audio Workstation). The backend is a native Zig 0.15 plugin that runs inside REAPER's process. Our primary constraint is **never crash REAPER** — musicians may have unsaved work.

The plugin:
- Runs a timer callback at ~30Hz on REAPER's main/UI thread
- Polls DAW state and broadcasts JSON to WebSocket clients
- Processes commands from clients via a mutex-protected command queue
- Uses ~4MB of static memory for state structs

### Questions for Review

1. **Thread Safety Model**
   - We use a single mutex for `SharedState` containing command queue, client map, and miscellaneous state.
   - One atomic (`Value(usize)`) stores a function pointer for cross-thread time queries.
   - Is the atomic usage correct? (release on store, acquire on load)
   - Are there any data race risks we're missing?

2. **Memory Management**
   - We use static storage for large state structs (~4MB total) to avoid stack overflow during deeply nested REAPER callbacks.
   - Per existing research, heap allocation is safe in timer callbacks (main thread, not audio thread).
   - Is there a better pattern than static storage for this use case?
   - The ~2.5MB state copy on change detection (`g_last_tracks = cur_tracks`) — is this a performance concern?

3. **FFI Safety**
   - We wrap all REAPER float returns with `safeFloatToInt()` that checks NaN/Inf before `@intFromFloat`.
   - Nullable fields (`?c_int`) propagate corrupt data as JSON nulls.
   - Is this approach sufficient? Are there edge cases we're missing?
   - Should we use REAPER's `ValidatePtr2` to check pointers before use?

4. **Comptime Duck Typing**
   - We use `anytype` parameters with a comptime `validateBackend(T)` check for mock injection.
   - Dispatch uses `inline for` over a comptime tuple of handlers.
   - Is this idiomatic Zig 0.15? Any pitfalls?

5. **Error Handling**
   - We have a semantic error hierarchy (`FFIError`, `ReaperStateError`, etc.).
   - Cleanup operations sometimes silently ignore errors.
   - Is this appropriate for plugin shutdown, or should we be more explicit?

6. **Buffer Management**
   - Static JSON buffers are used sequentially within the timer callback.
   - There's no compile-time enforcement of exclusive access.
   - Is there a Zig pattern to prevent accidental concurrent use of the same buffer?

7. **Pointer Lifecycle**
   - We lookup REAPER object pointers by index and use immediately, never storing across callbacks.
   - There's a theoretical race window between lookup and use if user deletes the object.
   - Is this acceptable, or should we add explicit validation?

### Specific Code Patterns to Review

**Atomic function pointer sharing (ws_server.zig:142-155):**
```zig
pub fn setTimePreciseFn(self: *SharedState, func: TimePreciseFn) void {
    self.time_precise_fn_ptr.store(@intFromPtr(func), .release);
}

pub fn timePreciseMs(self: *SharedState) f64 {
    const ptr_val = self.time_precise_fn_ptr.load(.acquire);
    if (ptr_val != 0) {
        const func: TimePreciseFn = @ptrFromInt(ptr_val);
        return func() * 1000.0;
    }
    return 0;
}
```

**Comptime dispatch (commands/mod.zig:217-222):**
```zig
inline for (comptime_registry.all) |entry| {
    if (std.mem.eql(u8, cmd.command, entry[0])) {
        entry[1](api, cmd, &response);
        return;
    }
}
```

**FFI validation (ffi.zig:30-40):**
```zig
pub fn safeFloatToInt(comptime T: type, value: f64) FFIError!T {
    if (std.math.isNan(value)) return error.FloatIsNaN;
    if (std.math.isInf(value)) return error.FloatIsInf;
    const min_val: f64 = @floatFromInt(std.math.minInt(T));
    const max_val: f64 = @floatFromInt(std.math.maxInt(T));
    if (value < min_val or value > max_val) return error.IntegerOverflow;
    return @intFromFloat(value);
}
```

**Static state storage (main.zig:266-289):**
```zig
const ProcessingState = struct {
    var snap_tracks: tracks.State = .{};  // ~2.5MB
    var cur_tracks: tracks.State = .{};   // ~2.5MB
    // ...
};
```

### Expected Output

Please provide:
1. Assessment of whether our patterns follow Zig 0.15 best practices
2. Any correctness issues or subtle bugs identified
3. Alternative patterns that might be more idiomatic or safer
4. Performance concerns and mitigation strategies
5. Recommendations for improving robustness without sacrificing the "never crash" requirement
