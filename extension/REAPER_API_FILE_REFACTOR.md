# REAPER API File Refactor - Phase 8 Testability

## Executive Summary

Migrate from runtime vtables to **comptime generics with `anytype`**. This eliminates boilerplate, provides zero runtime overhead, and enables mock injection for focused unit tests.

**Status: Phase 1-5 COMPLETE ✅**

---

## Current State (After Phase 5)

### Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    State Modules                        │
│   transport.zig, tracks.zig, markers.zig, etc.         │
│         fn poll(api: anytype) State                     │
└──────────────────────────┬──────────────────────────────┘
                           │ duck typing via anytype
          ┌────────────────┴────────────────┐
          ▼                                 ▼
  ┌──────────────────┐            ┌───────────────────┐
  │   RealBackend    │            │   MockBackend     │
  │  (production)    │            │  (tests)          │
  │  used by main.zig│            │  field-based mock │
  └────────┬─────────┘            └───────────────────┘
           │
           ▼
  ┌──────────────────┐
  │     raw.Api      │
  │ C function ptrs  │
  └──────────────────┘

┌─────────────────────────────────────────────────────────┐
│                  Command Handlers                       │
│     ~70 handlers using pub fn xxx(api: anytype, ...)   │
└──────────────────────────┬──────────────────────────────┘
                           │ inline for dispatch
                           ▼
          ┌──────────────────────────────────┐
          │    commands/registry.zig         │
          │    Comptime tuple of handlers    │
          └──────────────────────────────────┘
```

### File Structure

```
extension/src/reaper/
├── types.zig          # Shared types (BeatsInfo, MarkerInfo, TempoMarker, etc.)
├── raw.zig            # C function pointers, ~80 raw functions
├── backend.zig        # validateBackend() comptime check (~100 methods)
├── real.zig           # RealBackend - thin wrapper around raw.Api
└── mock/              # MockBackend implementation
    ├── mod.zig        # MockBackend struct with all method re-exports
    ├── state.zig      # MockTrack, MockItem, MockTake, MockMarkerInfo, encoding
    ├── transport.zig  # Transport/timing mock methods
    ├── tracks.zig     # Track/item/take mock methods
    ├── markers.zig    # Marker/region mock methods
    └── project.zig    # Project/undo/extstate/MIDI mock methods

extension/src/commands/
├── mod.zig            # dispatch() with inline for, ResponseWriter
├── registry.zig       # Comptime tuple of all handlers
├── transport.zig      # pub fn handleXxx(api: anytype, ...)
├── markers.zig        # pub fn handleXxx(api: anytype, ...)
├── regions.zig        # pub fn handleXxx(api: anytype, ...)
├── items.zig          # pub fn handleXxx(api: anytype, ...)
├── takes.zig          # pub fn handleXxx(api: anytype, ...)
├── tracks.zig         # pub fn handleXxx(api: anytype, ...)
├── time_sel.zig       # pub fn handleXxx(api: anytype, ...)
├── repeat.zig         # pub fn handleXxx(api: anytype, ...)
├── tempo.zig          # pub fn handleXxx(api: anytype, ...)
├── timesig.zig        # pub fn handleXxx(api: anytype, ...)
├── metronome.zig      # pub fn handleXxx(api: anytype, ...)
├── master.zig         # pub fn handleXxx(api: anytype, ...)
├── extstate.zig       # pub fn handleXxx(api: anytype, ...)
├── undo.zig           # pub fn handleXxx(api: anytype, ...)
├── actions.zig        # pub fn handleXxx(api: anytype, ...)
├── gesture.zig        # pub fn handleXxx(api: anytype, ...)
├── toggle_state.zig   # pub fn handleXxx(api: anytype, ...)
├── midi.zig           # pub fn handleXxx(api: anytype, ...)
└── project_notes.zig  # pub fn handleXxx(api: anytype, ...)

extension/src/
├── reaper.zig         # Re-exports: RealBackend, MockBackend
├── transport.zig      # poll(api: anytype)
├── tracks.zig         # poll(api: anytype), MeteringState.poll(api: anytype)
├── items.zig          # poll(api: anytype)
├── markers.zig        # poll(api: anytype)
├── project.zig        # poll(api: anytype)
├── tempomap.zig       # poll(api: anytype)
├── toggle_subscriptions.zig  # subscribe/poll(api: anytype)
├── project_notes.zig  # poll/getCurrentNotes(api: anytype)
└── main.zig           # Uses RealBackend for both state polling and dispatch
```

---

## Completed Work

### Phase 1: Foundation ✅

1. **Created `reaper/backend.zig`**
   - `validateBackend(comptime T: type)` function
   - Validates ~100 required methods at compile time
   - Used by both RealBackend and MockBackend

2. **Created `reaper/real.zig`**
   - `RealBackend` struct wrapping `*const raw.Api`
   - Direct method delegation (no vtable indirection)
   - Comptime validated via `backend.validateBackend(RealBackend)`

3. **Created `reaper/mock/` directory structure**
   - `state.zig`: Field types and index-as-pointer encoding
   - `transport.zig`: Transport/timing mock methods
   - `tracks.zig`: Track/item/take/metering mock methods
   - `markers.zig`: Marker/region mock methods
   - `project.zig`: Project/undo/extstate/MIDI mock methods
   - `mod.zig`: Composes `MockBackend` with all method re-exports

### Phase 2: Migrate State Modules ✅

All state modules updated from vtable to `anytype`:

```zig
// Before (vtable)
pub fn poll(api: ApiInterface) State

// After (comptime duck typing)
pub fn poll(api: anytype) State
```

Migrated files:
- `transport.zig` - 728 lines, 75 tests
- `tracks.zig` - track enumeration, control, and metering
- `items.zig` - items and takes
- `markers.zig` - markers and regions
- `project.zig` - project state, undo/redo
- `tempomap.zig` - tempo markers

### Phase 3: Test Migration ✅

All tests updated to use `MockBackend` instead of `MockApi.interface()`:

```zig
// Before
var mock = MockApi{...};
const state = State.poll(mock.interface());

// After
var mock = MockBackend{...};
const state = State.poll(&mock);
```

**Result: 309/309 tests pass**

### Phase 4: Migrate main.zig & Delete Legacy Files ✅

1. **Migrated `main.zig` to use `RealBackend` directly**
2. **Deleted legacy vtable files** (`api.zig`, `mock.zig` - 2,069 lines removed)
3. **Updated `reaper.zig`** - now only exports: `RealBackend`, `MockBackend`, raw types

### Phase 5: Command Handler Testability ✅

**Problem**: Command handlers used function pointer registry with `*const reaper.Api`. Function pointers cannot use `anytype`.

**Solution**: Comptime tuple registry with `inline for` dispatch.

1. **Created `commands/registry.zig`** - Comptime tuple of ~70 handlers:
   ```zig
   pub const all = .{
       .{ "transport/play", transport.handlePlay },
       .{ "transport/stop", transport.handleStop },
       .{ "marker/add", markers.handleMarkerAdd },
       // ... ~70 entries
   };
   ```

2. **Updated `commands/mod.zig`** - dispatch() using `inline for`:
   ```zig
   pub fn dispatch(api: anytype, client_id: usize, data: []const u8, ...) void {
       // ...
       inline for (comptime_registry.all) |entry| {
           if (std.mem.eql(u8, cmd.command, entry[0])) {
               entry[1](api, cmd, &response);
               return;
           }
       }
   }
   ```

3. **Converted all 70 handlers to `anytype`**:
   ```zig
   // Before
   fn handlePlay(api: *const reaper.Api, cmd: CommandMessage, response: *ResponseWriter) void

   // After
   pub fn handlePlay(api: anytype, cmd: CommandMessage, response: *ResponseWriter) void
   ```

4. **Updated `main.zig`** to pass `*RealBackend` to dispatch:
   ```zig
   var backend = reaper.RealBackend{ .inner = api };
   commands.dispatch(&backend, command.client_id, command.data, shared_state, g_gesture_state);
   ```

5. **Updated subscription modules** to use `anytype`:
   - `toggle_subscriptions.zig`: `subscribe()` and `poll()` now use `anytype`
   - `project_notes.zig`: `poll()` and `getCurrentNotes()` now use `anytype`

6. **Extended `RealBackend`** with additional methods needed by handlers:
   - `undoAddPoint`, `makeTakeAccessor`, `destroyTakeAccessor`
   - `accessorValidate`, `accessorGetPeaks`, `readAccessorSamples`
   - `clearTrackPeakHold`, `getTrackPeakHoldDB`

**Result**: All handlers can now be tested with `MockBackend`. Zero `*const reaper.Api` references remain in source code.

---

## Key Design Decisions

### 1. `anytype` vs Comptime Generics

Chose `anytype` with a single `validateBackend()` comptime check instead of `fn poll(comptime B: type, api: *B)`. Research confirmed:
- `anytype` with validation is cleaner than full generics
- Single validation point catches missing methods at compile time
- Duck typing works for both `*RealBackend` and `*MockBackend`

### 2. Comptime Tuple Registry for Commands

Function pointers cannot use `anytype`, so command handlers use a comptime tuple registry:
- `inline for` unrolls at comptime - no runtime loop overhead
- Each handler is called directly with concrete type
- ~70 handlers at 30Hz is negligible (~50-100ns vs 33ms frame budget)

### 3. Asymmetric Backend Split

- **RealBackend**: Monolithic (all methods in one file)
  - Simple, thin wrapper around raw.Api
  - No domain split needed - just delegation

- **MockBackend**: Split by domain
  - Easier to navigate and maintain
  - Each domain file ~100-200 lines
  - `mod.zig` composes via method re-exports

### 4. No Legacy Compatibility Layer

After Phase 5, there is no legacy vtable or function pointer layer. Everything uses `anytype`:
```zig
// Production (main.zig)
var backend = reaper.RealBackend{ .inner = api };
const state = transport.State.poll(&backend);
commands.dispatch(&backend, ...);

// Tests
var mock = MockBackend{...};
const state = State.poll(&mock);
handlePlay(&mock, cmd, &response);
```

---

## Remaining Work

### Phase 6: Handler Unit Tests (Optional)

Now that handlers accept `anytype`, they can be unit tested:

```zig
test "transport/play runs correct command" {
    var mock = MockBackend{};
    var response = TestResponseWriter{};
    transport.handlePlay(&mock, .{}, &response);
    try testing.expectEqual(reaper.Command.PLAY, mock.last_command);
}
```

This is optional as integration tests via WebSocket already cover handler behavior.

---

## Context Handover Checklist

If continuing in a new session:

1. **Build & Test**
   ```bash
   cd extension && zig build test --summary all
   # Should pass all tests
   ```

2. **Key Files to Read**
   - `reaper/backend.zig` - validateBackend() function
   - `reaper/mock/mod.zig` - MockBackend composition
   - `reaper/real.zig` - RealBackend structure
   - `commands/registry.zig` - Comptime handler registry
   - `commands/mod.zig` - dispatch() with inline for

3. **Current State**
   - State modules: Migrated to `anytype` ✅
   - Command handlers: Migrated to `anytype` ✅
   - Subscription modules: Migrated to `anytype` ✅
   - Tests: Use `MockBackend` ✅
   - main.zig: Uses `RealBackend` for state and dispatch ✅
   - Legacy files deleted: `api.zig`, `mock.zig` ✅
   - Zero `*const reaper.Api` references remain ✅

---

## Test Commands

```bash
# Build and run all tests
cd extension && zig build test --summary all

# Build only (no tests)
cd extension && zig build

# Run specific test file (if needed)
cd extension && zig test src/transport.zig
```

---

## Architecture Diagram

```
                    ┌──────────────────────────────────────┐
                    │           State Modules              │
                    │  transport.zig, tracks.zig, etc.     │
                    │                                      │
                    │     fn poll(api: anytype) State      │
                    └──────────────────┬───────────────────┘
                                       │
                    ┌──────────────────────────────────────┐
                    │         Command Handlers             │
                    │  ~70 handlers in commands/*.zig      │
                    │                                      │
                    │  pub fn handleXxx(api: anytype, ...) │
                    └──────────────────┬───────────────────┘
                                       │
                                       │ duck typing via anytype
                                       │
           ┌───────────────────────────┴───────────────────────┐
           │                                                   │
           ▼                                                   ▼
┌─────────────────────┐                         ┌─────────────────────────┐
│     RealBackend     │                         │      MockBackend        │
│   (real.zig)        │                         │   (mock/mod.zig)        │
│                     │                         │                         │
│ Used by main.zig    │                         │ Field-based state:      │
│ Wraps raw.Api       │                         │ - play_state, bpm, etc  │
│ Direct delegation   │                         │ - tracks[], markers[]   │
│ ~110 methods        │                         │ - call_log[] for verify │
│                     │                         │                         │
│ comptime validated  │                         │ comptime validated      │
└─────────┬───────────┘                         └─────────────────────────┘
          │
          ▼
┌─────────────────────┐
│       raw.Api       │
│                     │
│ C function pointers │
│ ~80 raw functions   │
│ ~70 wrapper methods │
└─────────────────────┘
```
