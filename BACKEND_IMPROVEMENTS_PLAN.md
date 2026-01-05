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
- `MEMORY_ARCHITECTURE_OVERHAUL.md` — **NEW** Flattened data model + dynamic allocation plan
- `research/ZIG_MEMORY_MANAGEMENT.md` — Memory allocation patterns for timer callbacks

**Key concepts from audit:**
- Timer callbacks run on main thread (not audio thread) — heap allocation is safe
- Static storage avoids stack overflow during deeply nested REAPER callbacks
- FFI layer converts REAPER's f64 returns to safe Zig types
- Single mutex currently protects all shared state between threads
- **Arena pattern** — Frame-based lifetimes are perfect for arena allocation

**Key architectural decisions (from memory research):**
- **Flattened data model** — Tracks don't contain nested FX/sends; these are separate top-level collections
- **Sparse polling** — Heavy data (notes, takes, FX params) fetched on-demand, not every poll cycle
- **Project-size detection** — Count entities on project load, allocate with 2x headroom, minimum 20 MB
- **No fixed entity limits** — Support 1 track with 200 FX or 3000 tracks with 2 FX each
- **Graceful degradation** — Skip entities when arena full, broadcast warning, never crash

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

**Decision:** ~~Store limits in REAPER ExtState, apply at runtime.~~ **SUPERSEDED** — See Flattened Data Model below.

**Original Rationale:** Power users need higher limits, constrained devices want lower limits.

**New Approach:** Automatic project-size detection with 2x headroom. No user configuration needed. Fully automatic by default, with architecture open for future power-user overrides if needed.

### Flattened Data Model (NEW)

**Decision:** Remove nested FX/sends from Track struct. Poll as separate top-level collections.

**Rationale:**
- Eliminates cross-tier pointer dependencies (HIGH tier held pointers into MEDIUM tier arenas)
- Reduces Track struct from ~232B to ~150B
- Enables proper separation of polling frequencies
- FX/sends now polled at MEDIUM tier (5Hz) independently
- Track struct just holds counts: `fx_count`, `send_count`, `receive_count`

**Pattern:**
```zig
// OLD: nested slices (cross-tier pointer problem)
const Track = struct {
    fx: []FxSlot,      // Points into MEDIUM tier — DANGLING after swap!
    sends: []SendSlot,
};

// NEW: sparse counts only
const Track = struct {
    fx_count: u16,
    send_count: u16,
    receive_count: u16,
};

// FX/sends are separate flat arrays in MEDIUM tier
const FxSlot = struct {
    track_idx: c_int,  // Parent reference
    fx_index: u16,
    name: [128]u8,
    enabled: bool,
};
```

### Dynamic Memory Allocation (NEW)

**Decision:** Project-size detection with automatic arena sizing.

**Memory Budget:**
```
Minimum:  20 MB (covers typical projects)
Ceiling:  200 MB (absolute maximum)
Headroom: 2x calculated requirement
```

**Strategy:**
1. On startup/project load: count entities via REAPER API
2. Calculate: `(tracks×150 + fx×281 + sends×157 + items×700 + markers×172 + regions×228) × 2`
3. Allocate: `max(calculated, 20MB)` capped at `200MB`
4. Resize only on project change (detected via `GetProjectPath()`)
5. Graceful degradation at 90% utilization (skip entities, broadcast warning)

### Sparse Polling Pattern (NEW)

**Decision:** Heavy data fetched on-demand, not every poll cycle.

**Rationale:**
- Item notes: 1024B buffer → `has_notes: bool` flag (fetch via `item/getNotes`)
- Item takes: 1488B array → `take_count` + `active_take_idx` (fetch via `item/getTakes`)
- FX params: Not in regular polling (fetch via `track/getFx`)
- Send routing detail: Not in regular polling (fetch via `track/getSends`)

**Struct size reductions:**
- Item: ~2,211B → ~700B (68% reduction)
- Track: ~232B → ~150B (35% reduction)

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

### Phase 6: Config System — ⚠️ SUPERSEDED

**Status:** Replaced by automatic project-size detection. See `MEMORY_ARCHITECTURE_OVERHAUL.md`.

**Original plan:** User-configurable max limits via ExtState.

**New approach:** No user configuration needed. Arena sizing is automatic:
- Count entities on project load
- Calculate required memory with 2x headroom
- Minimum 20 MB, maximum 200 MB
- Resize on project change only

User config may be added later as power-user escape hatches, but not in initial implementation.

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
- [ ] (Deferred) Remove `g_last_*` globals — still used for playlist engine (FX/sends buffers removed in Phase A)

**Note:** Core arena integration complete. Change detection now uses arena previousState()
instead of memcpy. Static buffers kept for JSON serialization (toJson functions use fixed-size
buffer pointers). Old globals kept for compatibility with playlist engine.

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

### Phase 10: Graceful Degradation — ✅ COMPLETE

**Status:** Implemented.

**Approach:** Piggyback on existing `project` event + on-demand `debug/memoryStats`.

**Backend:**
- [x] `debug/memoryStats` command already exists (Phase G)
- [x] Track peak utilization across tiers, set warning flag when any tier > 80%
- [x] Add `memoryWarning: boolean` field to `project` event payload
- [x] Added `isMemoryWarning()` to TieredArenas and DiagnosticUsage

**Frontend:**
- [x] Handle `memoryWarning` in `project` event (projectSlice.ts)
- [x] Show dismissable warning bar: "REAmo memory usage is high"
- [x] "Info" button → modal with `debug/memoryStats` details
- [x] "Dismiss" button → hide warning (stored in session state)
- [x] Info modal text explains memory reservation and suggests restart

**Files:**
- `extension/src/tiered_state.zig` — add `isDegraded()` method
- `extension/src/main.zig` — include in project event
- `frontend/src/store/slices/projectSlice.ts` — handle memoryWarning
- `frontend/src/components/` — warning bar component

**Why this approach:**
- Zero extra messages under normal operation
- New clients get status on connect via `project` event
- Detailed stats available on-demand via `debug/memoryStats`
- User-friendly explanation with actionable resolution

---

### Phase 11: Documentation Updates
- [ ] Update `DEVELOPMENT.md` with new patterns:
  - Arena-based state management
  - DoubleBufferedState usage
  - Flattened data model
  - Sparse polling pattern
  - ValidatePtr2 usage
  - Fine-grained locking
  - Panic-safe entry points
- [ ] Add "Memory Patterns" section covering arenas
- [ ] Update "Common Pitfalls" with new gotchas discovered
- [ ] Mark this plan as ✅ COMPLETE

**Files:** `DEVELOPMENT.md`, `README.md`, this file

---

## Memory Architecture Overhaul (NEW)

**See `MEMORY_ARCHITECTURE_OVERHAUL.md` for full details.**

These phases implement the flattened data model and dynamic memory allocation:

### Phase A: Flatten Track Struct ✅ COMPLETE
- [x] Remove `fx: []FxSlot` and `sends: []SendSlot` from Track struct
- [x] Add `fx_count: u16`, `send_count: u16`, `receive_count: u16`
- [x] Update `pollInto()` to populate counts from REAPER API
- [x] Update `toJson()` to serialize counts instead of arrays
- [x] Update `eql()` comparison
- [x] Update tests
- [x] Added `trackReceiveCount` to all backends

**Files:** `extension/src/tracks.zig`, backends (raw.zig, real.zig, mock/*.zig, backend.zig)

### Phase B: Create FX/Sends Modules ✅ COMPLETE
- [x] Create `FxSlot` struct with `track_idx` parent reference
- [x] Create `fx.State` with flat `[]FxSlot` slice
- [x] Create `fx.poll()` that iterates all tracks, all FX
- [x] Create `fx.toJson()` for `fx_state` event
- [x] Create `SendSlot` struct with src/dest track references
- [x] Create `sends.State` with flat `[]SendSlot` slice
- [x] Create `sends.poll()` and `sends.toJson()` for `sends_state` event
- [x] Added `trackFxGetEnabled` to all backends
- [x] Integrated FX/sends polling into MEDIUM tier (5Hz)
- [x] Updated `tiered_state.zig` MediumTierState with `fx_slots` and `send_slots`

**Files:** `extension/src/fx.zig` (new), `extension/src/sends.zig` (new), `extension/src/main.zig`, `extension/src/tiered_state.zig`

### Phase C: Sparse Item Fields ✅ COMPLETE
- [x] Remove `notes: [1024]u8` and `takes: [8]Take` from Item struct
- [x] Add `has_notes: bool`, `take_count: u8` (kept existing `active_take_idx: ?c_int`)
- [x] Update `pollIntoBuffer()` to check if item has notes (non-empty), count takes
- [x] Update `toJson()` to serialize sparse fields (`hasNotes`, `takeCount`)
- [x] Update tests

**Files:** `extension/src/items.zig`

### Phase D: On-Demand Commands ✅ COMPLETE
- [x] Add `track/getFx` handler — fetch full FX detail for single track
- [x] Add `track/getSends` handler — fetch full send detail for single track
- [x] Add `item/getNotes` handler — fetch notes content for single item
- [x] Add `item/getTakes` handler — fetch take list for single item
- [x] Register in `commands/registry.zig`

**Files:** `extension/src/commands/tracks.zig`, `extension/src/commands/items.zig`, `extension/src/commands/registry.zig`

### Phase E: Arena Sizing ✅ COMPLETE
- [x] Add `calculateRequiredSize()` that counts entities via REAPER API
- [x] Update `TieredArenas.init()` to use calculated size with 2x headroom
- [x] Add minimum 20 MB floor, 200 MB ceiling
- [x] Add `usage()` method to each arena for monitoring (already existed)
- [ ] Add project path tracking for resize detection (moved to Phase F)

**Files:** `extension/src/tiered_state.zig`, `extension/src/main.zig`

**Implementation details:**
- Added `EntityCounts` struct with `countFromApi()` to count tracks, items, markers, regions, FX, sends, tempo events
- Added `CalculatedSizes` struct with `fromCounts()` to compute tier sizes with 2x headroom
- Added `MemoryBounds` constants: 20 MB minimum, 200 MB ceiling
- Added `TieredArenas.initWithSizes()` to accept calculated sizes
- main.zig now counts entities at startup and passes calculated sizes to arena init
- Added 7 new unit tests for arena sizing

### Phase F: Project Change Detection ✅ COMPLETE
- [x] Add `TieredArenas.resize()` method to reinitialize arenas with new sizes
- [x] Add `TieredArenas.shouldResize()` to check if resize is warranted (threshold-based)
- [x] Detect project change via existing `projectChanged()` check (uses project hash/name)
- [x] Recount entities and calculate new sizes on project change
- [x] Resize arenas if allocation differs by >25% from current
- [x] Log entity counts and resize events

**Files:** `extension/src/tiered_state.zig`, `extension/src/main.zig`

**Implementation details:**
- Added `TieredArenas.resize(allocator, new_sizes)` that deinits all arenas and reinits with new sizes
- Added `TieredArenas.shouldResize(new_sizes, threshold_percent)` for threshold-based resize decisions
- On project change (detected in MEDIUM tier polling via `projectChanged()`):
  - Count entities in new project via `EntityCounts.countFromApi()`
  - Calculate new sizes via `CalculatedSizes.fromCounts()`
  - If `shouldResize()` returns true (25% threshold), call `resize()`
  - Graceful fallback: if resize fails, continue with existing arenas
- Added 4 new unit tests for resize and shouldResize functionality

### Phase G: Memory Stats Command ✅ COMPLETE
- [x] Create `debug/memoryStats` handler
- [x] Collect stats from all arenas: used, capacity, peak, utilization
- [x] Report total allocation and sizes per tier
- [x] Add frame count for debugging
- [x] Register in registry and mod.zig
- [x] Expose tiered arenas via global pointer from main.zig

**Files:** `extension/src/commands/debug.zig` (new), `extension/src/commands/mod.zig`, `extension/src/commands/registry.zig`, `extension/src/main.zig`

**Implementation details:**
- New `debug.zig` command module with `handleMemoryStats` handler
- Returns JSON with per-tier usage (used, capacity, peak, utilization %)
- Returns total allocation in bytes and MB
- Returns configured sizes for each tier
- Global `g_tiered` pointer set in main.zig doInitialization, cleared on shutdown
- Added tiered_state.zig to build.zig test_modules for comprehensive testing
- Fixed mock backend for loop syntax for Zig 0.15 compatibility
- Fixed tests for default transport.bpm value (120, not 0)

**Response format:**
```json
{
  "high": {"used": N, "capacity": N, "peak": N, "utilization": N.N},
  "medium": {"used": N, "capacity": N, "peak": N, "utilization": N.N},
  "low": {"used": N, "capacity": N, "peak": N, "utilization": N.N},
  "scratch": {"used": N, "capacity": N},
  "total": {"allocated": N, "allocatedMB": N.N},
  "sizes": {"high": N, "medium": N, "low": N, "scratch": N},
  "frameCount": N
}
```

### Phase H: Frontend Updates ✅ COMPLETE
- [x] Update `WSTrack` type — add fxCount/sendCount/receiveCount sparse fields
- [x] Update `WSItem` type — remove notes/takes arrays, add hasNotes/takeCount/activeTakeGuid/activeTakeIsMidi sparse fields
- [x] Add `fxStateSlice` for `fx_state` events
- [x] Add `sendsStateSlice` for `sends_state` events
- [x] Add on-demand fetch commands (track/getFx, track/getSends, item/getNotes, item/getTakes)
- [x] Update ItemInfoBar component for sparse fields with on-demand notes fetching
- [x] Update WaveformItem and usePeaksFetch to use sparse fields

**Files:** `frontend/src/core/WebSocketTypes.ts`, `frontend/src/core/WebSocketCommands.ts`, `frontend/src/core/types.ts`, `frontend/src/store/index.ts`, `frontend/src/store/slices/fxStateSlice.ts` (new), `frontend/src/store/slices/sendsStateSlice.ts` (new), `frontend/src/components/ItemsTimeline/ItemInfoBar.tsx`, `frontend/src/components/ItemsTimeline/WaveformItem.tsx`, `frontend/src/hooks/usePeaksFetch.ts`

**Implementation details:**
- WSTrack now includes fxCount, sendCount, receiveCount sparse fields
- WSItem now uses hasNotes, takeCount, activeTakeGuid, activeTakeIsMidi instead of full arrays
- New WSFxSlot and WSSendSlot types for fx_state/sends_state event payloads
- fxStateSlice and sendsStateSlice store flat arrays indexed by trackIdx
- ItemInfoBar fetches notes on-demand when user clicks to edit
- WaveformItem uses activeTakeIsMidi sparse field for MIDI detection
- usePeaksFetch uses activeTakeGuid sparse field for cache keys
- Track type in types.ts extended with fxCount field

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
| 2026-01-05 | Memory Research | Conducted struct size analysis, researched memory patterns for REAPER extensions |
| 2026-01-05 | Architecture | Decided on flattened data model (FX/sends as separate collections, not nested in Track) |
| 2026-01-05 | Architecture | Decided on dynamic allocation: project-size detection, 2x headroom, 20-200 MB bounds |
| 2026-01-05 | Architecture | Created MEMORY_ARCHITECTURE_OVERHAUL.md with implementation phases A-H |
| 2026-01-05 | Phase A | ✅ Flatten Track struct - removed fx/sends slices, added fx_count/send_count/receive_count, added trackReceiveCount to backends |
| 2026-01-05 | Phase B | ✅ Create FX/Sends modules - fx.zig and sends.zig with flat arrays, integrated into MEDIUM tier, broadcasts fx_state/sends_state events at 5Hz |
| 2026-01-05 | Phase C | ✅ Sparse Item fields - removed notes buffer (1024B) and takes array (8×Take), added has_notes/take_count sparse fields |
| 2026-01-05 | Phase D | ✅ On-Demand Commands - added track/getFx, track/getSends, item/getNotes, item/getTakes handlers for fetching sparse data |
| 2026-01-05 | Phase E | ✅ Arena Sizing - dynamic sizing from entity counts, 20 MB min/200 MB max, 2x headroom, EntityCounts/CalculatedSizes structs |
| 2026-01-05 | Phase F | ✅ Project Change Detection - TieredArenas.resize() and shouldResize(), 25% threshold, graceful fallback on resize failure |
| 2026-01-05 | Phase G | ✅ Memory Stats Command - debug/memoryStats handler, per-tier usage/capacity/peak/utilization, total allocation, frame count |
| 2026-01-05 | Phase H | ✅ Frontend Updates - WSTrack/WSItem sparse fields, fxStateSlice/sendsStateSlice, on-demand fetch commands, ItemInfoBar/WaveformItem updated |

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
- `g_last_*` globals kept for playlist engine compatibility (FX/sends buffers removed in Phase A)
- Small projects use fraction of arena; large projects use more
- `threadlocal` in Zig uses TLS, may have platform-specific behavior on Windows
- SPSC queue alternative: `std.atomic.Queue` is MPSC, need custom for true SPSC
- RwLock can starve writers under heavy read load — monitor for issues
- **Fine-grained locking**: command_mutex for queue, client_rwlock for client map/aux maps
- Token validation uses atomic release/acquire: set token value first, then store flag with `.release`; load flag with `.acquire` to see token value
- Arena doubles memory (2 buffers), but eliminates per-frame copies
- Slice-based state requires allocator parameter threading through poll functions
- Config changes require arena reinitialization — do between frames only
- ~~FX/sends use flat buffer pattern~~ **SUPERSEDED by Phase A**: Track now has sparse `fx_count`, `send_count`, `receive_count` fields. Full FX/sends data fetched on-demand via `track/getFx`, `track/getSends` commands.
- ~~HIGH_TIER copies FX/send slice *pointers*~~ **SUPERSEDED by Phase A**: FX/sends buffers removed. Counts populated directly in poll().
- **Flattened data model (Phase A)**: Track contains sparse counts only (`fx_count`, `send_count`, `receive_count`). FX/sends become separate top-level collections in Phase B. Eliminates cross-tier pointer dependencies.
- **Sparse fields**: Item notes → `has_notes: bool` (fetch via `item/getNotes`), takes → `take_count + active_take_idx` (fetch via `item/getTakes`). Reduces Item from ~2,211B to ~700B.
- **Memory bounds**: 20 MB minimum (typical projects), 200 MB ceiling (absolute max), 2x headroom on calculated size.
- **Resize timing**: Only resize arenas on project change (detected via `GetProjectPath()` changing). Never resize mid-session.
- **Graceful degradation**: At 90% arena utilization, skip newest entities, broadcast `ARENA_FULL` warning. Never crash REAPER.

---

## Open Questions

1. **SPSC vs Mutex for commands?** Lock-free is faster but more complex. Current ring buffer with mutex is simple and likely fast enough at our message rate.

2. ~~**Arena size calculation accuracy?**~~ **RESOLVED**: Now using project-size detection with 2x headroom. Minimum 20 MB floor, 200 MB ceiling. `debug/memoryStats` command provides runtime visibility.

3. **ValidatePtr2 overhead?** Need to measure. If significant, consider caching validation per-frame or skipping for hot paths.

4. ~~**FX/Send slices within Track?**~~ **RESOLVED → SUPERSEDED**: Original slice approach had cross-tier pointer dependency issues. New approach: **flattened data model** — FX/sends are separate top-level collections, not nested in Track. Track just holds counts (`fx_count`, `send_count`). Detail fetched on-demand via `track/getFx`, `track/getSends` commands.

5. ~~**Config UI location?**~~ **RESOLVED**: No user config needed. Automatic project-size detection handles everything. May add power-user overrides later if needed.

6. ~~**Default limits?**~~ **RESOLVED**: No fixed limits. Dynamic allocation based on actual project size. Minimum 20 MB, maximum 200 MB, 2x headroom.

7. **NEW: Delta updates for bandwidth optimization?** Currently sending full state on change. Could implement delta updates (only changed values) for large projects. Deferred — not a concern over LAN, adds frontend complexity.

8. **NEW: Project load detection reliability?** Using `GetProjectPath()` change to detect new project. Need to verify this catches all cases (new project, open project, close project).
