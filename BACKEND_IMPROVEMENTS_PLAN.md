# Backend Stability Improvements — Implementation Plan

**Status:** 🚧 IN PROGRESS
**Last Updated:** 2026-01-05
**Source:** `BACKEND_AUDIT.md` + `BACKEND_AUDIT_RESPONSE.md` + `BACKEND_ARENA_RESEARCH.md`

This is a living document tracking stability and correctness improvements identified during the backend architecture audit.

---

## Quick Context for New Sessions

**Read these files first:**
- `DEVELOPMENT.md` — Architecture, conventions, FFI validation layer pattern
- `BACKEND_AUDIT.md` — Original audit document with architecture overview
- `BACKEND_AUDIT_RESPONSE.md` — Expert review with specific recommendations
- `BACKEND_ARENA_RESEARCH.md` — Arena allocation strategy for dynamic limits
- `research/ZIG_MEMORY_MANAGEMENT.md` — Memory allocation patterns for timer callbacks

**Key concepts from audit:**
- Timer callbacks run on main thread (not audio thread) — heap allocation is safe
- Static storage avoids stack overflow during deeply nested REAPER callbacks
- FFI layer converts REAPER's f64 returns to safe Zig types
- Single mutex currently protects all shared state between threads
- **Arena pattern** — Frame-based lifetimes are perfect for arena allocation

---

## Summary of Improvements

| Priority | Improvement | Impact | Complexity |
|----------|-------------|--------|------------|
| High | Panic-safe entry points | Prevents crashes escaping to REAPER | Low |
| High | Typed atomic for fn pointer | Cleaner code, eliminates casts | Low |
| High | Complete FFI safety | Negative-to-unsigned check | Low |
| High | ValidatePtr2 for commands | Catches deleted objects | Low |
| High | Arena-based state management | Eliminates copies, enables dynamic limits | High |
| Medium | Fine-grained locking | Reduces contention at 30Hz | Medium |
| Medium | User-configurable limits | Runtime config via ExtState | Medium |

---

## Design Decisions

### Arena-Based State Management (Replaces Double Buffering)

**Decision:** Use per-frame arena allocation with double-buffered arenas.

**Rationale:**
- Our polling has frame-based lifetimes: poll → diff → serialize → discard
- Arenas are *designed* for this: bulk allocate, use, reset
- No individual frees needed, no fragmentation, no bookkeeping
- Eliminates 2.5MB memcpy — just swap arena pointers
- Enables dynamic limits (slices instead of fixed arrays)
- Aligns with REAPER's "audio production without limits" philosophy

**Pattern:**
```zig
// Every 33ms:
g_state.beginFrame();           // Swap arenas, reset the one we're about to use
const alloc = g_state.currentAllocator();
state.tracks = pollTracks(alloc, api);  // Allocate from arena
if (!state.eql(prev)) broadcast(state.toJson(alloc));  // JSON buffer from arena too
// End of frame — nothing to free! Next beginFrame() resets this arena.
```

### Slice-Based State (Replaces Fixed Arrays)

**Decision:** Change state structs from fixed arrays to slices.

**Rationale:**
- `tracks: [128]Track` → `tracks: []Track`
- Allocated from arena each frame based on actual count
- Limits become config values, not compile-time constants
- Users can increase limits for massive projects
- Memory usage proportional to actual data, not max limits

### Fine-Grained Locking Strategy

**Decision:** Separate locks per resource type.

**Rationale:**
- Current single mutex creates serialization even for independent data
- Priority inversion risk: WS thread holding lock blocks timer callback
- Command queue → dedicated mutex (or lock-free SPSC)
- Client map → RwLock (read-heavy during broadcasts)
- Simple values → atomics where possible

### ValidatePtr2 Scope

**Decision:** Use for command handlers, skip for polling loops.

**Rationale:**
- Commands receive user-controlled indices — higher risk
- Polling loops iterate by index and use immediately — self-validating
- ValidatePtr2 has overhead; reserve for trust boundaries
- Consider GUID-based references for long-lived track refs

### User-Configurable Limits

**Decision:** Store limits in REAPER ExtState, apply at runtime.

**Rationale:**
- Power users with 1000+ track orchestral templates need higher limits
- Users on constrained devices may want lower limits
- Config persists across sessions via ExtState
- Changing limits reinitializes arenas (safe between frames)
- Soft limits with warnings instead of silent truncation

---

## Implementation Phases

### Phase 1: Panic-Safe Entry Points ✅
- [x] Audit all `export fn` callbacks in `main.zig`
- [x] Wrap `doInitialization()` call in catch-all
- [x] Wrap `doProcessing()` call in catch-all
- [x] Add `logging.err()` for caught errors
- [ ] **Test:** Trigger error path, verify REAPER doesn't crash

**Files:** `extension/src/main.zig`

**Pattern:**
```zig
export fn timer_callback() callconv(.C) void {
    doProcessing() catch |err| {
        logging.err("Timer callback failed: {}", .{err});
        // Don't propagate — would panic at FFI boundary
    };
}
```

---

### Phase 2: Typed Atomic for Function Pointer ✅
- [x] Change `time_precise_fn_ptr: std.atomic.Value(usize)` to `Value(?TimePreciseFn)`
- [x] Remove `@intFromPtr/@ptrFromInt` conversions
- [x] Update `setTimePreciseFn()` to store directly
- [x] Update `timePreciseMs()` to use optional unwrap
- [ ] **Build & test:** Verify clock sync still works

**Files:** `extension/src/ws_server.zig`

**Before:**
```zig
time_precise_fn_ptr: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

pub fn timePreciseMs(self: *SharedState) f64 {
    const ptr_val = self.time_precise_fn_ptr.load(.acquire);
    if (ptr_val != 0) {
        const func: TimePreciseFn = @ptrFromInt(ptr_val);
        return func() * 1000.0;
    }
    return 0;
}
```

**After:**
```zig
time_precise_fn: std.atomic.Value(?TimePreciseFn) = std.atomic.Value(?TimePreciseFn).init(null),

pub fn timePreciseMs(self: *SharedState) f64 {
    if (self.time_precise_fn.load(.acquire)) |func| {
        return func() * 1000.0;
    }
    return 0;
}
```

---

### Phase 3: Complete FFI Safety (Negative-to-Unsigned) ✅
- [x] Add explicit negative check for unsigned target types in `safeFloatToInt()`
- [x] Add new error variant `NegativeToUnsigned` to `FFIError`
- [x] Update `ErrorCode.fromError()` mapping
- [x] Add tests for negative → unsigned cases
- [x] **Build & test:** Run `make test-extension`

**Files:** `extension/src/ffi.zig`, `extension/src/errors.zig`

**Addition to safeFloatToInt:**
```zig
// For unsigned types, explicitly reject negative values
if (@typeInfo(T).int.signedness == .unsigned and value < 0) {
    return error.NegativeToUnsigned;
}
```

---

### Phase 4: ValidatePtr2 for Command Handlers ✅
- [x] Add `validatePtr2` to `raw.zig` (C binding)
- [x] Add `validateTrackPtr()` to `RealBackend`
- [x] Add mock implementation to `MockBackend`
- [x] Add to `backend.zig` required methods
- [ ] Update `commands/tracks.zig` handlers to validate before use
- [ ] Update other command files that use track/item pointers
- [ ] **Build & test:** Delete track while command in flight

**Files:**
- `extension/src/reaper/raw.zig`
- `extension/src/reaper/real.zig`
- `extension/src/reaper/mock/mod.zig`
- `extension/src/reaper/backend.zig`
- `extension/src/commands/tracks.zig`

**REAPER API:**
```c
bool ValidatePtr2(ReaProject* proj, void* pointer, const char* ctypename);
// ctypename: "MediaTrack*", "MediaItem*", "MediaItem_Take*"
```

**Usage pattern:**
```zig
const track = api.getTrackByUnifiedIdx(track_idx) orelse {
    response.err("NOT_FOUND", "Track not found");
    return;
};

if (!api.validateTrackPtr(track)) {
    response.err("INVALID_TRACK", "Track no longer exists");
    return;
}

// Now safe to use
_ = api.csurfSetVolume(track, volume, true);
```

---

### Phase 5: Arena Infrastructure ✅
- [x] Create `extension/src/frame_arena.zig` with `FrameArena` struct
- [x] Implement `init()`, `allocator()`, `reset()`, `deinit()`
- [x] Create `DoubleBufferedState` generic for ping-pong pattern
- [x] Implement `beginFrame()`, `currentAllocator()`, `currentState()`, `previousState()`
- [x] Add `usage()` diagnostics for peak tracking
- [x] Add tests for arena reset and double-buffer swap
- [x] **Build & test:** Unit tests pass (313/313)

**Files:** `extension/src/frame_arena.zig` (new)

**Implementation:**
```zig
pub const FrameArena = struct {
    buffer: []u8,
    fba: std.heap.FixedBufferAllocator,

    pub fn init(backing: Allocator, size: usize) !FrameArena {
        const buffer = try backing.alloc(u8, size);
        return .{
            .buffer = buffer,
            .fba = std.heap.FixedBufferAllocator.init(buffer),
        };
    }

    pub fn allocator(self: *FrameArena) Allocator {
        return self.fba.allocator();
    }

    pub fn reset(self: *FrameArena) void {
        self.fba.reset();
    }

    pub fn deinit(self: *FrameArena, backing: Allocator) void {
        backing.free(self.buffer);
    }
};

pub fn DoubleBufferedState(comptime StateType: type) type {
    return struct {
        arenas: [2]FrameArena,
        states: [2]*StateType,
        current: u1 = 0,

        const Self = @This();

        pub fn beginFrame(self: *Self) !void {
            self.current = 1 - self.current;
            self.arenas[self.current].reset();
            self.states[self.current] = try self.arenas[self.current].allocator().create(StateType);
            self.states[self.current].* = StateType.empty();
        }

        pub fn currentState(self: *Self) *StateType { return self.states[self.current]; }
        pub fn previousState(self: *Self) *const StateType { return self.states[1 - self.current]; }
        pub fn currentAllocator(self: *Self) Allocator { return self.arenas[self.current].allocator(); }
    };
}
```

---

### Phase 6: Config System
- [ ] Create `extension/src/config.zig` with `Config` struct
- [ ] Add `max_tracks`, `max_items`, `max_markers`, `max_regions` fields
- [ ] Implement `arenaSize()` calculation with headroom
- [ ] Implement `loadFromExtState()` and `saveToExtState()`
- [ ] Add default config values
- [ ] **Build & test:** Config loads/saves correctly

**Files:** `extension/src/config.zig` (new)

**Implementation:**
```zig
pub const Config = struct {
    max_tracks: u32 = 256,
    max_items: u32 = 1024,
    max_markers: u32 = 256,
    max_regions: u32 = 256,

    pub fn arenaSize(self: Config) usize {
        const track_bytes = self.max_tracks * @sizeOf(Track) * 2;  // *2 for FX/sends overhead
        const item_bytes = self.max_items * @sizeOf(Item);
        const marker_bytes = self.max_markers * @sizeOf(Marker);
        const region_bytes = self.max_regions * @sizeOf(Region);
        const overhead = 4 * 1024 * 1024;  // 4MB for strings, JSON buffers

        return track_bytes + item_bytes + marker_bytes + region_bytes + overhead;
    }

    pub fn loadFromExtState(api: anytype) Config {
        // Parse from REAPER ExtState or return defaults
    }

    pub fn saveToExtState(self: Config, api: anytype) void {
        // Serialize to REAPER ExtState with persist=true
    }
};
```

---

### Phase 7: Migrate State Structs to Slices ✅
- [x] Change `tracks.State.tracks` from `[MAX_TRACKS]Track` to `[]Track`
- [x] Update `tracks.State.empty()` to return empty slice
- [x] Add `tracks.poll(allocator, api)` allocator-based API
- [x] Add `tracks.pollWithLimit(allocator, api, max_tracks)` for configurable limits
- [x] Update `tracks.pollInto(static_buffer, api)` to take buffer parameter
- [x] Update `tracks.State.eql()` for slice comparison
- [x] Update main.zig with static buffers and proper data copy with `@memcpy`
- [x] Repeat for `items.State` (similar pattern: slice, pollInto with buffer, pollStatic for tests)
- [x] Repeat for `markers.State` (similar pattern: markers/regions slices, pollInto with two buffers)
- [x] **Build & test:** All tests pass (324/324)

**Files:**
- `extension/src/tracks.zig`
- `extension/src/items.zig`
- `extension/src/markers.zig`

**Before:**
```zig
pub const State = struct {
    tracks: [MAX_TRACKS]Track = undefined,
    count: usize = 0,
};
```

**After:**
```zig
pub const State = struct {
    tracks: []Track = &.{},

    pub fn empty() State {
        return .{ .tracks = &.{} };
    }
};

pub fn poll(alloc: Allocator, api: anytype, config: Config) !State {
    const count = @min(api.trackCount(), config.max_tracks);
    const tracks = try alloc.alloc(Track, count);
    // ... populate tracks ...
    return .{ .tracks = tracks };
}
```

---

### Phase 8: Integrate Arenas into Main Loop ✅
- [x] Create `TieredArenas` struct with per-tier double buffers + scratch
- [x] Initialize `TieredArenas` at plugin init
- [x] Update timer callback to use `beginFrame()` pattern
- [x] Migrate HIGH tier (transport, tracks, metering) to arena allocation
- [x] Migrate MEDIUM tier (project, markers, regions, items) to arena allocation
- [x] Migrate LOW tier (tempomap) to arena allocation
- [x] Update polling calls to pass `currentAllocator()`
- [x] **Build & test:** All tests pass (313/313)
- [ ] (Deferred) Remove `StaticBuffers` — requires toJson signature changes
- [ ] (Deferred) Remove `ProcessingState` — still used for snapshots
- [ ] (Deferred) Remove `g_last_*` globals — still used for FX/sends and playlist engine

**Note:** Core arena integration complete. Change detection now uses arena previousState()
instead of memcpy. Static buffers kept for JSON serialization (toJson functions use fixed-size
buffer pointers). Old globals kept for compatibility with FX/sends polling and playlist engine.

**Files:** `extension/src/main.zig`

**Before:**
```zig
const ProcessingState = struct {
    var cur_tracks: tracks.State = .{};
};
var g_last_tracks: tracks.State = .{};

fn doProcessing() void {
    ProcessingState.cur_tracks.pollInto(api);
    if (!ProcessingState.cur_tracks.eql(&g_last_tracks)) {
        // broadcast
    }
    g_last_tracks = ProcessingState.cur_tracks;  // 2.5MB copy!
}
```

**After:**
```zig
var g_frame_state: DoubleBufferedState(FrameState) = undefined;
var g_config: Config = .{};

fn doProcessing() !void {
    try g_frame_state.beginFrame();
    const alloc = g_frame_state.currentAllocator();
    const state = g_frame_state.currentState();
    const prev = g_frame_state.previousState();

    state.tracks = try tracks.poll(alloc, api, g_config);

    if (!state.tracks.eql(prev.tracks)) {
        const json = try state.tracks.toJson(alloc);
        shared_state.broadcast(json);
    }
    // No copy! Next beginFrame() swaps arenas.
}
```

---

### Phase 9: Fine-Grained Locking ✅
- [x] Create separate `command_mutex` for command queue
- [x] Create `client_rwlock` for client map (RwLock for read-heavy)
- [x] Extract simple values to atomics where possible
- [x] Update all lock sites in `ws_server.zig`
- [ ] (Deferred) Consider SPSC queue for commands — current mutex is simple and fast enough
- [ ] (Deferred) Stress test with multiple clients, rapid commands — basic testing done, defer load testing

**Files:** `extension/src/ws_server.zig`

**Implementation:**
- `command_mutex: Thread.Mutex` — dedicated lock for command queue (SPSC pattern)
- `client_rwlock: Thread.RwLock` — RwLock for client map (read-heavy during broadcasts)
- `token_set: std.atomic.Value(bool)` — set once at startup, then read-only
- `html_mtime: std.atomic.Value(i128)` — infrequently updated
- `time_precise_fn: std.atomic.Value(?TimePreciseFn)` — already was atomic

**Lock usage pattern:**
- Command operations: `command_mutex.lock()` / `unlock()`
- Client writes (add/remove): `client_rwlock.lock()` / `unlock()`
- Client reads (broadcast/send/count): `client_rwlock.lockShared()` / `unlockShared()`
- Token/mtime: atomic load/store with acquire/release semantics

```zig
const SharedState = struct {
    // Separate locks for independent resources
    command_mutex: std.Thread.Mutex = .{},
    commands: CommandRingBuffer,

    client_rwlock: std.Thread.RwLock = .{},
    clients: std.AutoArrayHashMap(usize, *websocket.Conn),

    // Atomics for simple values
    token_set: std.atomic.Value(bool) = .init(false),
    html_mtime: std.atomic.Value(i128) = .init(0),
    time_precise_fn: std.atomic.Value(?TimePreciseFn) = .init(null),
};
```

---

### Phase 10: Soft Limits and Warnings
- [ ] Add limit checking in poll functions
- [ ] Broadcast `LIMIT_EXCEEDED` warning event when truncating
- [ ] Track high-water marks for diagnostics
- [ ] Add `APPROACHING_LIMIT` warning at 80% threshold
- [ ] **Build & test:** Warnings appear when limits approached/exceeded

**Files:** `extension/src/tracks.zig`, `extension/src/items.zig`, etc.

**Pattern:**
```zig
pub fn poll(alloc: Allocator, api: anytype, config: Config, broadcast_fn: anytype) !State {
    const actual_count = api.trackCount();

    if (actual_count > config.max_tracks) {
        broadcast_fn(.{
            .code = "TRACK_LIMIT_EXCEEDED",
            .message = "Project has more tracks than limit. Increase in settings.",
            .actual = actual_count,
            .limit = config.max_tracks,
        });
    } else if (actual_count > config.max_tracks * 8 / 10) {
        broadcast_fn(.{
            .code = "APPROACHING_TRACK_LIMIT",
            .message = "Using 80%+ of track limit.",
        });
    }

    const capped = @min(actual_count, config.max_tracks);
    // ... continue with capped count
}
```

---

### Phase 11: Documentation Updates
- [ ] Update `DEVELOPMENT.md` with new patterns:
  - Arena-based state management
  - DoubleBufferedState usage
  - Config system and ExtState persistence
  - ValidatePtr2 usage
  - Fine-grained locking
  - Panic-safe entry points
- [ ] Add "Memory Patterns" section covering arenas
- [ ] Update "Common Pitfalls" with new gotchas discovered
- [ ] Document user-configurable limits in README or user docs
- [ ] Mark this plan as ✅ COMPLETE

**Files:** `DEVELOPMENT.md`, `README.md`, this file

---

## Testing Strategy

### After Phase 1 (Panic Safety)
- Trigger an error in timer callback (e.g., corrupt state)
- Verify REAPER stays running, error is logged

### After Phase 2 (Typed Atomic)
- Connect client, verify clock sync messages work
- Check `tt` events contain valid timestamps

### After Phase 3 (FFI Safety)
- Run `make test-extension`
- Specifically test negative float → unsigned int paths

### After Phase 4 (ValidatePtr2)
- Start playback, send `track/setVolume` command
- Delete track in REAPER while command queued
- Verify error response, not crash

### After Phase 5 (Arena Infrastructure)
- Run unit tests for FrameArena and DoubleBufferedState
- Verify reset() clears allocations
- Verify swap works correctly

### After Phase 6 (Config System)
- Set custom limits via ExtState
- Restart REAPER, verify limits persist
- Test `arenaSize()` calculation

### After Phase 7 (Slice Migration)
- Open project with various track counts
- Verify polling works with slice-based state
- Verify `eql()` comparison works

### After Phase 8 (Arena Integration)
- Full integration test with real project
- Profile: confirm no 2.5MB copies
- Verify memory stays bounded (check arena usage)
- Long-running test (1 hour) — verify no memory growth

### After Phase 9 (Fine-Grained Locking)
- Connect 4+ clients simultaneously
- Rapid command spam from all clients
- Verify no deadlocks, reasonable latency

### After Phase 10 (Soft Limits)
- Open project exceeding limits
- Verify warning events broadcast
- Verify data truncated gracefully (no crash)

---

## Progress Log

| Date | Phase | Notes |
|------|-------|-------|
| 2026-01-05 | Phase 0 | Plan created from audit response |
| 2026-01-05 | Phase 1 | ✅ Panic-safe entry points - wrapped timer callbacks with catch-all |
| 2026-01-05 | Phase 2 | ✅ Typed atomic - changed time_precise_fn to `Value(?TimePreciseFn)` |
| 2026-01-05 | Phase 3 | ✅ FFI safety - added `NegativeToUnsigned` error for unsigned int conversion |
| 2026-01-05 | Phase 4 | ✅ ValidatePtr2 - added validation methods to raw.zig, RealBackend, MockBackend |
| 2026-01-05 | Phase 5 | ✅ Arena Infrastructure - created frame_arena.zig with FrameArena and DoubleBufferedState |
| 2026-01-05 | Phase 7 | ✅ Migrated tracks.State, items.State, markers.State to slice-based with static buffer backing |
| 2026-01-05 | Phase 7+ | ✅ Migrated Track.fx and Track.sends to slices with flat buffer backing (resolves Open Question #4) |
| 2026-01-05 | Phase 8 | ✅ Arena integration - TieredArenas with per-tier double buffers (HIGH/MEDIUM/LOW) + scratch arena |
| 2026-01-05 | Phase 9 | ✅ Fine-grained locking - separate command_mutex, client_rwlock, atomics for token_set/html_mtime |

---

## Notes & Gotchas

- `ValidatePtr2` requires project pointer — use `null` for current project
- `FixedBufferAllocator.reset()` is O(1) — just sets index to 0
- Arena size is virtual memory — OS only commits pages actually touched
- **Tiered arenas**: Each tier swaps independently based on polling frequency:
  - HIGH (30Hz): swaps every frame
  - MEDIUM (5Hz): swaps every 6 frames
  - LOW (1Hz): swaps every 30 frames
  - SCRATCH: resets every frame for JSON, temps
- Change detection uses `previousState()` from arena — no memcpy needed
- `g_last_*` globals kept for FX/sends polling and playlist engine compatibility
- Small projects use fraction of arena; large projects use more
- `threadlocal` in Zig uses TLS, may have platform-specific behavior on Windows
- SPSC queue alternative: `std.atomic.Queue` is MPSC, need custom for true SPSC
- RwLock can starve writers under heavy read load — monitor for issues
- **Fine-grained locking**: command_mutex for queue, client_rwlock for client map/aux maps
- Token validation uses atomic release/acquire: set token value first, then store flag with `.release`; load flag with `.acquire` to see token value
- Arena doubles memory (2 buffers), but eliminates per-frame copies
- Slice-based state requires allocator parameter threading through poll functions
- Config changes require arena reinitialization — do between frames only
- FX/sends use flat buffer pattern: `g_last_fx_buf[track_idx * MAX_FX_PER_TRACK..][0..fx_count]` gives per-track slice
- HIGH_TIER copies FX/send slice *pointers* (not data) since they point into stable g_last_*_buf backing storage

---

## Open Questions

1. **SPSC vs Mutex for commands?** Lock-free is faster but more complex. Current ring buffer with mutex is simple and likely fast enough at our message rate.

2. **Arena size calculation accuracy?** The `arenaSize()` function is an estimate. May need tuning based on real-world usage. Add telemetry to track peak arena usage.

3. **ValidatePtr2 overhead?** Need to measure. If significant, consider caching validation per-frame or skipping for hot paths.

4. ~~**FX/Send slices within Track?**~~ **RESOLVED**: Migrated `Track.fx` and `Track.sends` to slices. Uses flat buffer backing (`g_last_fx_buf`, `g_last_sends_buf`) with per-track slicing during MEDIUM_TIER polling. Memory savings: ~3.6KB per track (fx: ~2.4KB, sends: ~1.2KB) when tracks have no FX/sends.

5. **Config UI location?** REAPER menu action? Settings panel in web UI? Both? Web UI is more discoverable for users.

6. **Default limits?** Current plan: 256 tracks, 1024 items, 256 markers/regions. Are these reasonable defaults? May need user feedback.
