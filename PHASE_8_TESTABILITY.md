# Phase 8: Testability Infrastructure

This document contains the detailed implementation plan for Phase 8 of the Extension Resilience Plan. It captures research findings on Zig testing patterns and provides a step-by-step migration strategy.

## Executive Summary

**Goal**: Make all state modules and command handlers testable without REAPER running.

**Approach**: Use the **vtable pattern** for API abstraction with **partial mocks** and **field-based state**. Since `reaper.Api` already uses runtime-loaded function pointers, vtable abstraction adds zero overhead.

**Key Insight**: At 30Hz (33ms per frame), even 60 vtable calls at ~5ns each total just 300 nanoseconds—0.0009% of frame time.

---

## Architecture Decisions

These decisions were made after external research on Zig FFI patterns:

| Decision | Choice | Rationale |
|----------|--------|-----------|
| VTable completeness | **Upfront** | Define all methods in one PR, cross-check against reaper.zig |
| File structure | **Two-layer** | `reaper/raw.zig` (C bindings) + `reaper/api.zig` (interface + validation) |
| Track handles in mock | **Index-as-pointer** | Encode index as `@ptrFromInt(idx + 1)`, can't dangle, easy to debug |
| Iteration mocking | **Fixed arrays + count** | Matches REAPER's `enumMarker(idx)` pattern |
| Return type consistency | **Match real API** | Don't normalize to error unions; preserve test fidelity |
| Runtime vs comptime | **Runtime vtable** | Negligible overhead, maximum flexibility for integration tests |
| Re-exports | **Namespaced** | `reaper.transport.foo`, avoid `usingnamespace` |
| Modules needing interface | See list below | `transport`, `tracks`, `markers`, `items`, `project`, `tempomap`, `toggle_subscriptions` |
| Modules NOT needing interface | `gesture_state` | No API calls - pure state management |

---

## Target File Structure

After Phase 8, the extension will have this structure:

```
extension/src/
├── reaper/
│   ├── raw.zig              # C function pointers, types, runtime loading
│   ├── api.zig              # ApiInterface + RealApi (validation layer)
│   ├── mock.zig             # MockApi for testing
│   ├── transport.zig        # Transport domain wrappers (optional)
│   ├── tracks.zig           # Track domain wrappers (optional)
│   └── types.zig            # Shared types (BeatsInfo, MarkerInfo, etc.)
├── reaper.zig               # Re-exports with namespaced access
├── state/
│   ├── transport.zig        # Uses ApiInterface, testable
│   ├── tracks.zig           # Uses ApiInterface, testable
│   ├── markers.zig          # Uses ApiInterface, testable
│   └── ...
├── ffi.zig                  # FFI utilities (safeFloatToInt, etc.)
├── logging.zig              # Logging infrastructure
└── main.zig                 # Entry point
```

**Re-export pattern** (`reaper.zig`):
```zig
// Namespaced access (preferred)
pub const raw = @import("reaper/raw.zig");
pub const api = @import("reaper/api.zig");

// Re-export commonly used types at top level for convenience
pub const Api = raw.Api;
pub const ApiInterface = api.ApiInterface;
pub const RealApi = api.RealApi;

// For testing
pub const mock = @import("reaper/mock.zig");
```

---

## Current Architecture Problem

`reaper.Api` is a struct of runtime-loaded function pointers:

```zig
pub const Api = struct {
    showConsoleMsg: *const fn ([*:0]const u8) callconv(.c) void,
    getPlayState: ?*const fn () callconv(.c) c_int = null,
    getPlayPosition: ?*const fn () callconv(.c) f64 = null,
    // ... 60+ more function pointer fields

    // Convenience wrappers call through function pointers
    pub fn playState(self: *const Api) c_int {
        return if (self.getPlayState) |f| f() else 0;
    }
};
```

State modules call these directly:

```zig
// transport.zig
pub fn poll(api: *const reaper.Api) State {
    const play_state = api.playState();
    const play_pos = api.playPosition();
    // ...
}
```

**Problem**: Cannot test `poll()` without REAPER because we can't inject mock return values.

---

## Solution: Vtable Interface Pattern

The vtable pattern mirrors `std.mem.Allocator` (post-Allocgate). This is the same pattern used by TigerBeetle, Ghostty, and the Zig standard library.

### Step 1: Define the Interface

Create `src/api_interface.zig`:

```zig
const std = @import("std");
const ffi = @import("ffi.zig");

/// Abstract API interface for REAPER functions.
/// Enables dependency injection of mock implementations for testing.
pub const ApiInterface = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        // Transport
        playState: *const fn (*anyopaque) c_int,
        playPosition: *const fn (*anyopaque) f64,
        cursorPosition: *const fn (*anyopaque) f64,
        timePreciseMs: *const fn (*anyopaque) f64,

        // Time conversion
        timeToBeats: *const fn (*anyopaque, f64) BeatsInfo,
        beatsToTime: *const fn (*anyopaque, f64) f64,
        getTempoAtPosition: *const fn (*anyopaque, f64) TempoAtPosition,
        getBarOffset: *const fn (*anyopaque) c_int,
        tempoMarkerCount: *const fn (*anyopaque) c_int,

        // Time selection
        timeSelection: *const fn (*anyopaque) TimeSelection,

        // Tracks
        trackCount: *const fn (*anyopaque) c_int,
        getTrackByUnifiedIdx: *const fn (*anyopaque, c_int) ?*anyopaque,
        getTrackNameStr: *const fn (*anyopaque, *anyopaque, []u8) []const u8,
        getTrackVolume: *const fn (*anyopaque, *anyopaque) f64,
        getTrackPan: *const fn (*anyopaque, *anyopaque) f64,
        getTrackMute: *const fn (*anyopaque, *anyopaque) bool,
        getTrackSolo: *const fn (*anyopaque, *anyopaque) ffi.FFIError!c_int,
        getTrackRecArm: *const fn (*anyopaque, *anyopaque) bool,
        getTrackRecMon: *const fn (*anyopaque, *anyopaque) ffi.FFIError!c_int,
        getTrackFxEnabled: *const fn (*anyopaque, *anyopaque) bool,
        getTrackSelected: *const fn (*anyopaque, *anyopaque) bool,
        getTrackColor: *const fn (*anyopaque, *anyopaque) c_int,
        isMasterMuted: *const fn (*anyopaque) bool,
        isMasterSoloed: *const fn (*anyopaque) bool,

        // Markers (add as needed)
        markerCount: *const fn (*anyopaque) MarkerCount,
        enumMarker: *const fn (*anyopaque, c_int) ?MarkerInfo,

        // ... add remaining methods as modules are migrated
    };

    // Return types (copied from reaper.zig for interface use)
    pub const BeatsInfo = struct {
        beats: f64,
        measures: c_int,
        beats_in_measure: f64,
        time_sig_denom: c_int,
    };

    pub const TempoAtPosition = struct {
        bpm: f64,
        timesig_num: c_int,
        timesig_denom: c_int,
    };

    pub const TimeSelection = struct {
        start: f64,
        end: f64,
    };

    pub const MarkerCount = struct {
        total: c_int,
        markers: c_int,
        regions: c_int,
    };

    pub const MarkerInfo = struct {
        idx: c_int,
        id: c_int,
        is_region: bool,
        pos: f64,
        end: f64,
        name: []const u8,
        color: c_int,
    };

    // Ergonomic wrapper methods (inline for performance)
    pub inline fn playState(self: ApiInterface) c_int {
        return self.vtable.playState(self.ptr);
    }

    pub inline fn playPosition(self: ApiInterface) f64 {
        return self.vtable.playPosition(self.ptr);
    }

    pub inline fn cursorPosition(self: ApiInterface) f64 {
        return self.vtable.cursorPosition(self.ptr);
    }

    pub inline fn timePreciseMs(self: ApiInterface) f64 {
        return self.vtable.timePreciseMs(self.ptr);
    }

    pub inline fn timeToBeats(self: ApiInterface, time: f64) BeatsInfo {
        return self.vtable.timeToBeats(self.ptr, time);
    }

    pub inline fn beatsToTime(self: ApiInterface, beats: f64) f64 {
        return self.vtable.beatsToTime(self.ptr, beats);
    }

    pub inline fn getTempoAtPosition(self: ApiInterface, time: f64) TempoAtPosition {
        return self.vtable.getTempoAtPosition(self.ptr, time);
    }

    pub inline fn getBarOffset(self: ApiInterface) c_int {
        return self.vtable.getBarOffset(self.ptr);
    }

    pub inline fn tempoMarkerCount(self: ApiInterface) c_int {
        return self.vtable.tempoMarkerCount(self.ptr);
    }

    pub inline fn timeSelection(self: ApiInterface) TimeSelection {
        return self.vtable.timeSelection(self.ptr);
    }

    pub inline fn trackCount(self: ApiInterface) c_int {
        return self.vtable.trackCount(self.ptr);
    }

    // ... remaining wrapper methods
};
```

### Step 2: Wrap Real API

Create `src/real_api.zig`:

```zig
const reaper = @import("reaper.zig");
const api_interface = @import("api_interface.zig");
const ApiInterface = api_interface.ApiInterface;

/// Wraps the real reaper.Api to implement ApiInterface
pub const RealApi = struct {
    inner: *const reaper.Api,

    pub fn interface(self: *RealApi) ApiInterface {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: ApiInterface.VTable = .{
        .playState = struct {
            fn f(ctx: *anyopaque) c_int {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.playState();
            }
        }.f,
        .playPosition = struct {
            fn f(ctx: *anyopaque) f64 {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.playPosition();
            }
        }.f,
        .cursorPosition = struct {
            fn f(ctx: *anyopaque) f64 {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.cursorPosition();
            }
        }.f,
        .timePreciseMs = struct {
            fn f(ctx: *anyopaque) f64 {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.timePreciseMs();
            }
        }.f,
        .timeToBeats = struct {
            fn f(ctx: *anyopaque, time: f64) ApiInterface.BeatsInfo {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                const info = self.inner.timeToBeats(time);
                return .{
                    .beats = info.beats,
                    .measures = info.measures,
                    .beats_in_measure = info.beats_in_measure,
                    .time_sig_denom = info.time_sig_denom,
                };
            }
        }.f,
        // ... implement remaining vtable entries
    };
};
```

### Step 3: Create Mock API

Create `src/mock_api.zig`:

```zig
const std = @import("std");
const api_interface = @import("api_interface.zig");
const ApiInterface = api_interface.ApiInterface;
const ffi = @import("ffi.zig");

/// Mock API for testing. Uses field-based state for fast access.
pub const MockApi = struct {
    // Transport state
    play_state: c_int = 0,
    play_position: f64 = 0.0,
    cursor_position: f64 = 0.0,
    server_time_ms: f64 = 0.0,

    // Tempo/timing
    bpm: f64 = 120.0,
    timesig_num: c_int = 4,
    timesig_denom: c_int = 4,
    bar_offset: c_int = 0,
    tempo_marker_count: c_int = 0,

    // Time selection
    time_sel_start: f64 = 0.0,
    time_sel_end: f64 = 0.0,

    // Tracks (fixed array for testing)
    track_count: c_int = 0,
    tracks: [32]MockTrack = [_]MockTrack{.{}} ** 32,

    // Error injection flags
    inject_nan_position: bool = false,
    inject_nan_beats: bool = false,
    inject_solo_error: bool = false,
    inject_recmon_error: bool = false,

    // Call tracking (fixed-size, no allocation)
    const MAX_CALLS = 128;
    call_log: [MAX_CALLS]CallEntry = undefined,
    call_count: usize = 0,

    pub const CallEntry = struct {
        method: Method,
        timestamp_ns: i128 = 0,
    };

    pub const Method = enum {
        playState,
        playPosition,
        cursorPosition,
        timeToBeats,
        trackCount,
        getTrackByUnifiedIdx,
        // ... add as needed
    };

    pub const MockTrack = struct {
        name: [128]u8 = undefined,
        name_len: usize = 0,
        volume: f64 = 1.0,
        pan: f64 = 0.0,
        mute: bool = false,
        solo: c_int = 0,
        rec_arm: bool = false,
        rec_mon: c_int = 0,
        fx_enabled: bool = true,
        selected: bool = false,
        color: c_int = 0,
    };

    pub fn interface(self: *MockApi) ApiInterface {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn recordCall(self: *MockApi, method: Method) void {
        if (self.call_count < MAX_CALLS) {
            self.call_log[self.call_count] = .{
                .method = method,
                .timestamp_ns = std.time.nanoTimestamp(),
            };
            self.call_count += 1;
        }
    }

    pub fn getCallCount(self: *const MockApi, method: Method) usize {
        var count: usize = 0;
        for (self.call_log[0..self.call_count]) |entry| {
            if (entry.method == method) count += 1;
        }
        return count;
    }

    pub fn reset(self: *MockApi) void {
        self.call_count = 0;
    }

    const vtable: ApiInterface.VTable = .{
        .playState = struct {
            fn f(ctx: *anyopaque) c_int {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.playState);
                return self.play_state;
            }
        }.f,

        .playPosition = struct {
            fn f(ctx: *anyopaque) f64 {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.playPosition);
                if (self.inject_nan_position) return std.math.nan(f64);
                return self.play_position;
            }
        }.f,

        .cursorPosition = struct {
            fn f(ctx: *anyopaque) f64 {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                return self.cursor_position;
            }
        }.f,

        .timePreciseMs = struct {
            fn f(ctx: *anyopaque) f64 {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                return self.server_time_ms;
            }
        }.f,

        .timeToBeats = struct {
            fn f(ctx: *anyopaque, time: f64) ApiInterface.BeatsInfo {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.timeToBeats);

                if (self.inject_nan_beats) {
                    return .{
                        .beats = std.math.nan(f64),
                        .measures = 1,
                        .beats_in_measure = std.math.nan(f64),
                        .time_sig_denom = 4,
                    };
                }

                // Simple calculation for testing
                const beats_per_second = self.bpm / 60.0;
                const total_beats = time * beats_per_second;
                const beats_per_bar: f64 = @floatFromInt(self.timesig_num);
                const bar = @as(c_int, @intFromFloat(@floor(total_beats / beats_per_bar)));
                const beat_in_bar = @mod(total_beats, beats_per_bar);

                return .{
                    .beats = total_beats,
                    .measures = bar + 1,
                    .beats_in_measure = beat_in_bar,
                    .time_sig_denom = self.timesig_denom,
                };
            }
        }.f,

        .getTempoAtPosition = struct {
            fn f(ctx: *anyopaque, _: f64) ApiInterface.TempoAtPosition {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                return .{
                    .bpm = self.bpm,
                    .timesig_num = self.timesig_num,
                    .timesig_denom = self.timesig_denom,
                };
            }
        }.f,

        .getBarOffset = struct {
            fn f(ctx: *anyopaque) c_int {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                return self.bar_offset;
            }
        }.f,

        .tempoMarkerCount = struct {
            fn f(ctx: *anyopaque) c_int {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                return self.tempo_marker_count;
            }
        }.f,

        .timeSelection = struct {
            fn f(ctx: *anyopaque) ApiInterface.TimeSelection {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                return .{ .start = self.time_sel_start, .end = self.time_sel_end };
            }
        }.f,

        .trackCount = struct {
            fn f(ctx: *anyopaque) c_int {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.trackCount);
                return self.track_count;
            }
        }.f,

        // Index-as-pointer pattern: encode index as pointer, can't dangle
        .getTrackByUnifiedIdx = struct {
            fn f(ctx: *anyopaque, idx: c_int) ?*anyopaque {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getTrackByUnifiedIdx);
                if (idx < 0 or idx >= self.track_count) return null;
                // Encode index as pointer (+1 to avoid null)
                return @ptrFromInt(@as(usize, @intCast(idx)) + 1);
            }
        }.f,

        .getTrackSolo = struct {
            fn f(ctx: *anyopaque, track_ptr: *anyopaque) ffi.FFIError!c_int {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                if (self.inject_solo_error) return ffi.FFIError.FloatIsNaN;
                // Decode index from pointer
                const idx = @intFromPtr(track_ptr) - 1;
                if (idx >= self.tracks.len) return 0;
                return self.tracks[idx].solo;
            }
        }.f,

        .getTrackRecMon = struct {
            fn f(ctx: *anyopaque, track_ptr: *anyopaque) ffi.FFIError!c_int {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                if (self.inject_recmon_error) return ffi.FFIError.FloatIsNaN;
                // Decode index from pointer
                const idx = @intFromPtr(track_ptr) - 1;
                if (idx >= self.tracks.len) return 0;
                return self.tracks[idx].rec_mon;
            }
        }.f,

        // ... implement remaining vtable entries
        // Methods not yet mocked can @panic with helpful message
        .beatsToTime = struct {
            fn f(_: *anyopaque, _: f64) f64 {
                @panic("beatsToTime not mocked - add to MockApi if needed");
            }
        }.f,

        .markerCount = struct {
            fn f(_: *anyopaque) ApiInterface.MarkerCount {
                @panic("markerCount not mocked - add to MockApi if needed");
            }
        }.f,

        .enumMarker = struct {
            fn f(_: *anyopaque, _: c_int) ?ApiInterface.MarkerInfo {
                @panic("enumMarker not mocked - add to MockApi if needed");
            }
        }.f,

        // ... remaining stubs
    };
};

// =============================================================================
// Tests for MockApi itself
// =============================================================================

test "MockApi returns configured values" {
    var mock = MockApi{
        .play_state = 1,
        .play_position = 5.5,
        .bpm = 140.0,
    };
    const api = mock.interface();

    try std.testing.expectEqual(@as(c_int, 1), api.playState());
    try std.testing.expectEqual(@as(f64, 5.5), api.playPosition());
}

test "MockApi injects NaN for position" {
    var mock = MockApi{
        .inject_nan_position = true,
    };
    const api = mock.interface();

    try std.testing.expect(std.math.isNan(api.playPosition()));
}

test "MockApi tracks call counts" {
    var mock = MockApi{};
    const api = mock.interface();

    _ = api.playState();
    _ = api.playState();
    _ = api.playPosition();

    try std.testing.expectEqual(@as(usize, 2), mock.getCallCount(.playState));
    try std.testing.expectEqual(@as(usize, 1), mock.getCallCount(.playPosition));
}

test "MockApi injects solo error" {
    var mock = MockApi{
        .inject_solo_error = true,
        .track_count = 1,
    };
    const api = mock.interface();
    // getTrackByUnifiedIdx returns index encoded as pointer
    const track = api.vtable.getTrackByUnifiedIdx(api.ptr, 0).?;

    const result = api.vtable.getTrackSolo(api.ptr, track);
    try std.testing.expectError(ffi.FFIError.FloatIsNaN, result);
}

test "MockApi index-as-pointer pattern" {
    var mock = MockApi{
        .track_count = 2,
    };
    mock.tracks[0].solo = 1;
    mock.tracks[1].solo = 2;
    const api = mock.interface();

    // Get track handles (encoded indices)
    const track0 = api.vtable.getTrackByUnifiedIdx(api.ptr, 0).?;
    const track1 = api.vtable.getTrackByUnifiedIdx(api.ptr, 1).?;

    // Verify they decode correctly
    try std.testing.expectEqual(@as(c_int, 1), try api.vtable.getTrackSolo(api.ptr, track0));
    try std.testing.expectEqual(@as(c_int, 2), try api.vtable.getTrackSolo(api.ptr, track1));
}
```

---

## Migration Strategy

Migrate incrementally without breaking existing tests.

### Phase 8.1: Create Infrastructure

1. Create `src/reaper/` directory
2. Move `reaper.zig` → `src/reaper/raw.zig` (rename Api loading)
3. Create `src/reaper/types.zig` with shared types (BeatsInfo, MarkerInfo, etc.)
4. Create `src/reaper/api.zig` with ApiInterface + RealApi (upfront, all methods)
5. Create `src/reaper/mock.zig` with MockApi (index-as-pointer pattern)
6. Create new `src/reaper.zig` as re-export shim
7. Add tests for mock API itself
8. Ensure `zig build test` still passes

### Phase 8.2: Migrate transport.zig (Week 1-2)

**Current signature:**
```zig
pub fn poll(api: *const reaper.Api) State
```

**New signature:**
```zig
pub fn poll(api: ApiInterface) State
```

**Backward compatibility wrapper:**
```zig
/// Legacy wrapper for existing code during migration
pub fn pollLegacy(api: *const reaper.Api) State {
    var real = RealApi{ .inner = api };
    return poll(real.interface());
}
```

**New tests to add:**
```zig
test "poll handles NaN position gracefully" {
    var mock = MockApi{
        .inject_nan_position = true,
        .play_state = 1,
    };
    const state = poll(mock.interface());
    try std.testing.expect(state.full_beat_position == null);
}

test "poll handles NaN beats gracefully" {
    var mock = MockApi{
        .inject_nan_beats = true,
        .play_state = 1,
    };
    const state = poll(mock.interface());
    try std.testing.expect(state.position_beat == null);
}

test "poll calculates bar.beat from time" {
    var mock = MockApi{
        .play_state = 1,
        .play_position = 2.0,  // 2 seconds
        .bpm = 120.0,          // 2 beats per second
        .timesig_num = 4,
    };
    const state = poll(mock.interface());
    try std.testing.expectEqual(@as(c_int, 2), state.position_bar);
}
```

### Phase 8.3: Migrate tracks.zig (Week 2)

Similar pattern. Key tests:

```zig
test "poll handles solo error gracefully" {
    var mock = MockApi{
        .inject_solo_error = true,
        .track_count = 2,
    };
    mock.tracks[0].name_len = 6;
    @memcpy(mock.tracks[0].name[0..6], "Track1");

    const state = tracks.State.poll(mock.interface());

    try std.testing.expectEqual(@as(usize, 2), state.count);
    try std.testing.expect(state.tracks[0].solo == null);  // Error propagated as null
}

test "poll handles recmon error gracefully" {
    var mock = MockApi{
        .inject_recmon_error = true,
        .track_count = 1,
    };
    const state = tracks.State.poll(mock.interface());
    try std.testing.expect(state.tracks[0].rec_mon == null);
}
```

### Phase 8.4: Migrate remaining state modules

Order by complexity:
1. `project.zig` (simple, few API calls)
2. `markers.zig` (medium, iteration pattern)
3. `items.zig` (complex, nested iteration)
4. `tempomap.zig` (simple)
5. `toggle_subscriptions.zig` (uses allocator, calls `api.getCommandState()`)

**Note**: `gesture_state.zig` does NOT need interface - it has no API calls.

### Phase 8.5: Update main.zig (Week 3)

Update processTimerCallback to use interface:

```zig
fn processTimerCallback() callconv(.c) void {
    const legacy_api = &(g_api orelse return);
    var real = RealApi{ .inner = legacy_api };
    const api = real.interface();

    // All poll calls now use interface
    const current_transport = transport.State.poll(api);
    const current_tracks = tracks.State.poll(api);
    // ...
}
```

---

## Test Organization

Follow Zig standard library convention: **colocate tests with source**.

### File Structure

```
extension/src/
├── main.zig                    # Entry point, imports test modules
├── reaper/
│   ├── raw.zig                # C function pointers (from original reaper.zig)
│   ├── api.zig                # ApiInterface + RealApi
│   ├── mock.zig               # MockApi for testing
│   └── types.zig              # Shared types
├── reaper.zig                 # Re-exports
├── transport.zig              # Contains transport tests
├── tracks.zig                 # Contains tracks tests
├── markers.zig                # Contains markers tests
└── ...
```

### Test Discovery

In `main.zig`, ensure all tests are discovered:

```zig
test {
    _ = @import("reaper/api.zig");
    _ = @import("reaper/mock.zig");
    _ = @import("transport.zig");
    _ = @import("tracks.zig");
    // ... all modules with tests
}
```

### Running Specific Tests

```bash
# Run all tests
zig build test

# Run tests matching pattern
zig build test -- "transport"
zig build test -- "handles NaN"
```

---

## Zig 0.15 Considerations

### ArrayList is Unmanaged

Pass allocator per-call. For mocks, prefer fixed-size buffers:

```zig
// AVOID (requires allocator threading)
calls: std.ArrayList(CallEntry),

// PREFER (zero allocation)
const MAX_CALLS = 128;
calls: [MAX_CALLS]CallEntry = undefined,
call_count: usize = 0,
```

### Use std.testing.allocator

Automatically detects memory leaks:

```zig
test "mock cleans up properly" {
    // Any leaked memory will fail the test
    var mock = MockApiWithAlloc.init(std.testing.allocator);
    defer mock.deinit();
    // ...
}
```

### Custom Panic Handler

Already using `std.debug.FullPanic` in logging.zig - compatible with Zig 0.15.

---

## Success Criteria

Phase 8 is complete when:

1. [ ] `reaper/raw.zig` contains C function pointers (moved from reaper.zig)
2. [ ] `reaper/api.zig` defines ApiInterface for ALL poll-used methods (upfront)
3. [ ] `reaper/api.zig` contains RealApi wrapping raw.Api
4. [ ] `reaper/mock.zig` supports error injection (NaN, null, errors) with index-as-pointer
5. [ ] `reaper.zig` re-exports with namespaced access
6. [ ] `transport.zig` poll() uses ApiInterface with 5+ new tests
7. [ ] `tracks.zig` poll() uses ApiInterface with 5+ new tests
8. [ ] All ~140 existing tests still pass
9. [ ] New tests cover NaN/Inf/null error paths
10. [ ] `zig build test` runs in <5 seconds

---

## Advanced: Deterministic Session Simulator

Inspired by TigerBeetle's deterministic simulation approach, the **SessionSimulator** enables timeline-based testing of state machine transitions across multiple poll cycles. This is invaluable for testing:

- Play/pause/stop state transitions
- Position changes during playback
- Tempo changes mid-song
- Track mute/solo toggle sequences
- Edge cases like rapid state flipping

### SessionSimulator Implementation

Add to `src/session_simulator.zig`:

```zig
const std = @import("std");
const api_interface = @import("api_interface.zig");
const ApiInterface = api_interface.ApiInterface;

/// A snapshot of REAPER state at a point in time.
/// Add fields as needed for your test scenarios.
pub const StateSnapshot = struct {
    // Transport
    play_state: c_int = 0,
    play_position: f64 = 0.0,
    cursor_position: f64 = 0.0,

    // Timing
    bpm: f64 = 120.0,
    timesig_num: c_int = 4,
    timesig_denom: c_int = 4,

    // Time selection
    time_sel_start: f64 = 0.0,
    time_sel_end: f64 = 0.0,

    // Tracks (simplified - first 4 tracks)
    track_count: c_int = 0,
    track_mutes: [4]bool = .{ false, false, false, false },
    track_solos: [4]c_int = .{ 0, 0, 0, 0 },

    // Error injection at specific frames
    inject_nan_position: bool = false,
    inject_nan_beats: bool = false,
};

/// Deterministic session simulator for timeline-based testing.
/// Replays a sequence of state snapshots, one per advanceFrame() call.
pub const SessionSimulator = struct {
    timeline: []const StateSnapshot,
    current_frame: usize = 0,

    /// Returns an ApiInterface that reads from the current timeline frame.
    pub fn api(self: *SessionSimulator) ApiInterface {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Advance to the next frame in the timeline.
    /// Wraps around if past the end.
    pub fn advanceFrame(self: *SessionSimulator) void {
        self.current_frame = (self.current_frame + 1) % self.timeline.len;
    }

    /// Get current snapshot (for assertions)
    pub fn currentSnapshot(self: *const SessionSimulator) StateSnapshot {
        return self.timeline[self.current_frame];
    }

    /// Check if timeline is exhausted (for non-wrapping tests)
    pub fn isExhausted(self: *const SessionSimulator) bool {
        return self.current_frame >= self.timeline.len;
    }

    /// Reset to beginning
    pub fn reset(self: *SessionSimulator) void {
        self.current_frame = 0;
    }

    const vtable: ApiInterface.VTable = .{
        .playState = struct {
            fn f(ctx: *anyopaque) c_int {
                const self: *SessionSimulator = @ptrCast(@alignCast(ctx));
                return self.currentSnapshot().play_state;
            }
        }.f,

        .playPosition = struct {
            fn f(ctx: *anyopaque) f64 {
                const self: *SessionSimulator = @ptrCast(@alignCast(ctx));
                const snap = self.currentSnapshot();
                if (snap.inject_nan_position) return std.math.nan(f64);
                return snap.play_position;
            }
        }.f,

        .cursorPosition = struct {
            fn f(ctx: *anyopaque) f64 {
                const self: *SessionSimulator = @ptrCast(@alignCast(ctx));
                return self.currentSnapshot().cursor_position;
            }
        }.f,

        .timePreciseMs = struct {
            fn f(ctx: *anyopaque) f64 {
                const self: *SessionSimulator = @ptrCast(@alignCast(ctx));
                // Simulate 33ms per frame (30Hz)
                return @as(f64, @floatFromInt(self.current_frame)) * 33.333;
            }
        }.f,

        .timeToBeats = struct {
            fn f(ctx: *anyopaque, time: f64) ApiInterface.BeatsInfo {
                const self: *SessionSimulator = @ptrCast(@alignCast(ctx));
                const snap = self.currentSnapshot();

                if (snap.inject_nan_beats) {
                    return .{
                        .beats = std.math.nan(f64),
                        .measures = 1,
                        .beats_in_measure = std.math.nan(f64),
                        .time_sig_denom = 4,
                    };
                }

                const beats_per_second = snap.bpm / 60.0;
                const total_beats = time * beats_per_second;
                const beats_per_bar: f64 = @floatFromInt(snap.timesig_num);
                const bar = @as(c_int, @intFromFloat(@floor(total_beats / beats_per_bar)));

                return .{
                    .beats = total_beats,
                    .measures = bar + 1,
                    .beats_in_measure = @mod(total_beats, beats_per_bar),
                    .time_sig_denom = snap.timesig_denom,
                };
            }
        }.f,

        .getTempoAtPosition = struct {
            fn f(ctx: *anyopaque, _: f64) ApiInterface.TempoAtPosition {
                const self: *SessionSimulator = @ptrCast(@alignCast(ctx));
                const snap = self.currentSnapshot();
                return .{
                    .bpm = snap.bpm,
                    .timesig_num = snap.timesig_num,
                    .timesig_denom = snap.timesig_denom,
                };
            }
        }.f,

        .trackCount = struct {
            fn f(ctx: *anyopaque) c_int {
                const self: *SessionSimulator = @ptrCast(@alignCast(ctx));
                return self.currentSnapshot().track_count;
            }
        }.f,

        // ... implement remaining vtable methods reading from currentSnapshot()
        // Stub remaining methods for now
        .beatsToTime = struct { fn f(_: *anyopaque, _: f64) f64 { @panic("not mocked"); } }.f,
        .getBarOffset = struct { fn f(_: *anyopaque) c_int { return 0; } }.f,
        .tempoMarkerCount = struct { fn f(_: *anyopaque) c_int { return 0; } }.f,
        .timeSelection = struct {
            fn f(ctx: *anyopaque) ApiInterface.TimeSelection {
                const self: *SessionSimulator = @ptrCast(@alignCast(ctx));
                const snap = self.currentSnapshot();
                return .{ .start = snap.time_sel_start, .end = snap.time_sel_end };
            }
        }.f,
        .getTrackByUnifiedIdx = struct { fn f(_: *anyopaque, _: c_int) ?*anyopaque { return null; } }.f,
        .getTrackNameStr = struct { fn f(_: *anyopaque, _: *anyopaque, buf: []u8) []const u8 { return buf[0..0]; } }.f,
        .getTrackVolume = struct { fn f(_: *anyopaque, _: *anyopaque) f64 { return 1.0; } }.f,
        .getTrackPan = struct { fn f(_: *anyopaque, _: *anyopaque) f64 { return 0.0; } }.f,
        .getTrackMute = struct { fn f(_: *anyopaque, _: *anyopaque) bool { return false; } }.f,
        .getTrackSolo = struct { fn f(_: *anyopaque, _: *anyopaque) @import("ffi.zig").FFIError!c_int { return 0; } }.f,
        .getTrackRecArm = struct { fn f(_: *anyopaque, _: *anyopaque) bool { return false; } }.f,
        .getTrackRecMon = struct { fn f(_: *anyopaque, _: *anyopaque) @import("ffi.zig").FFIError!c_int { return 0; } }.f,
        .getTrackFxEnabled = struct { fn f(_: *anyopaque, _: *anyopaque) bool { return true; } }.f,
        .getTrackSelected = struct { fn f(_: *anyopaque, _: *anyopaque) bool { return false; } }.f,
        .getTrackColor = struct { fn f(_: *anyopaque, _: *anyopaque) c_int { return 0; } }.f,
        .isMasterMuted = struct { fn f(_: *anyopaque) bool { return false; } }.f,
        .isMasterSoloed = struct { fn f(_: *anyopaque) bool { return false; } }.f,
        .markerCount = struct { fn f(_: *anyopaque) ApiInterface.MarkerCount { return .{ .total = 0, .markers = 0, .regions = 0 }; } }.f,
        .enumMarker = struct { fn f(_: *anyopaque, _: c_int) ?ApiInterface.MarkerInfo { return null; } }.f,
    };
};

// =============================================================================
// Tests for SessionSimulator
// =============================================================================

test "SessionSimulator advances through timeline" {
    var sim = SessionSimulator{
        .timeline = &.{
            .{ .play_state = 0, .play_position = 0.0 },
            .{ .play_state = 1, .play_position = 0.0 },
            .{ .play_state = 1, .play_position = 0.5 },
            .{ .play_state = 0, .play_position = 0.5 },
        },
    };

    try std.testing.expectEqual(@as(c_int, 0), sim.api().playState());
    sim.advanceFrame();
    try std.testing.expectEqual(@as(c_int, 1), sim.api().playState());
    sim.advanceFrame();
    try std.testing.expectEqual(@as(f64, 0.5), sim.api().playPosition());
}

test "SessionSimulator wraps around" {
    var sim = SessionSimulator{
        .timeline = &.{
            .{ .play_state = 0 },
            .{ .play_state = 1 },
        },
    };

    sim.advanceFrame(); // frame 1
    sim.advanceFrame(); // wraps to frame 0
    try std.testing.expectEqual(@as(c_int, 0), sim.api().playState());
}

test "SessionSimulator injects errors at specific frames" {
    var sim = SessionSimulator{
        .timeline = &.{
            .{ .play_position = 1.0, .inject_nan_position = false },
            .{ .play_position = 2.0, .inject_nan_position = true },  // Error frame
            .{ .play_position = 3.0, .inject_nan_position = false },
        },
    };

    try std.testing.expectEqual(@as(f64, 1.0), sim.api().playPosition());
    sim.advanceFrame();
    try std.testing.expect(std.math.isNan(sim.api().playPosition()));
    sim.advanceFrame();
    try std.testing.expectEqual(@as(f64, 3.0), sim.api().playPosition());
}
```

### Example: Testing Transport State Transitions

```zig
const transport = @import("transport.zig");
const SessionSimulator = @import("session_simulator.zig").SessionSimulator;
const StateSnapshot = @import("session_simulator.zig").StateSnapshot;

test "transport handles play/pause sequence" {
    var sim = SessionSimulator{
        .timeline = &.{
            .{ .play_state = 0, .play_position = 0.0 },   // Stopped
            .{ .play_state = 1, .play_position = 0.0 },   // Play pressed
            .{ .play_state = 1, .play_position = 0.033 }, // Playing, one frame
            .{ .play_state = 1, .play_position = 0.066 }, // Playing, two frames
            .{ .play_state = 0, .play_position = 0.066 }, // Pause pressed
        },
    };

    // Frame 0: Stopped
    var state = transport.poll(sim.api());
    try std.testing.expect(!state.is_playing);

    sim.advanceFrame();

    // Frame 1: Just started playing
    state = transport.poll(sim.api());
    try std.testing.expect(state.is_playing);
    try std.testing.expectEqual(@as(f64, 0.0), state.position);

    sim.advanceFrame();
    sim.advanceFrame();

    // Frame 3: Playing, position advanced
    state = transport.poll(sim.api());
    try std.testing.expect(state.is_playing);
    try std.testing.expect(state.position > 0.05);

    sim.advanceFrame();

    // Frame 4: Paused
    state = transport.poll(sim.api());
    try std.testing.expect(!state.is_playing);
}

test "transport handles tempo change mid-playback" {
    var sim = SessionSimulator{
        .timeline = &.{
            .{ .play_state = 1, .play_position = 0.0, .bpm = 120.0 },
            .{ .play_state = 1, .play_position = 0.5, .bpm = 120.0 },
            .{ .play_state = 1, .play_position = 1.0, .bpm = 140.0 }, // Tempo change!
            .{ .play_state = 1, .play_position = 1.5, .bpm = 140.0 },
        },
    };

    _ = transport.poll(sim.api());
    sim.advanceFrame();
    sim.advanceFrame();

    // After tempo change
    const state = transport.poll(sim.api());
    try std.testing.expectEqual(@as(f64, 140.0), state.bpm);
}

test "transport handles NaN position mid-playback" {
    var sim = SessionSimulator{
        .timeline = &.{
            .{ .play_state = 1, .play_position = 1.0 },
            .{ .play_state = 1, .inject_nan_position = true },  // Corrupt frame
            .{ .play_state = 1, .play_position = 1.1 },         // Recovery
        },
    };

    var state = transport.poll(sim.api());
    try std.testing.expect(state.full_beat_position != null);

    sim.advanceFrame();
    state = transport.poll(sim.api());
    // Module should handle NaN gracefully (null or last-known-good)
    try std.testing.expect(state.full_beat_position == null);

    sim.advanceFrame();
    state = transport.poll(sim.api());
    try std.testing.expect(state.full_beat_position != null);
}
```

### When to Use SessionSimulator vs MockApi

| Scenario | Use |
|----------|-----|
| Single-frame behavior | `MockApi` |
| State transitions over time | `SessionSimulator` |
| Error injection at specific moment | `SessionSimulator` |
| Static configuration testing | `MockApi` |
| Playback sequence testing | `SessionSimulator` |
| Performance testing | `MockApi` (simpler overhead) |

### Extending SessionSimulator

When adding new test scenarios:

1. Add fields to `StateSnapshot` for the state you need
2. Implement the vtable method to read from `currentSnapshot()`
3. Create timeline arrays that exercise the state transitions

```zig
// Example: Adding track selection state
pub const StateSnapshot = struct {
    // ... existing fields ...
    selected_track_idx: ?c_int = null,  // New field
};

// In vtable:
.getTrackSelected = struct {
    fn f(ctx: *anyopaque, track_ptr: *anyopaque) bool {
        const self: *SessionSimulator = @ptrCast(@alignCast(ctx));
        const track_idx = getTrackIdx(track_ptr);  // Helper to get index
        const snap = self.currentSnapshot();
        return snap.selected_track_idx == track_idx;
    }
}.f,
```

---

## Design Principles

1. **Interface matches REAPER API exactly**: Return types, error unions, and signatures mirror `reaper.Api`. Don't normalize or "improve" - this preserves test fidelity.

2. **Two-layer architecture**: Raw FFI (C bindings, no validation) → Interface layer (vtable + validation). Keeps concerns separate.

3. **Index-as-pointer for mocks**: Encode track/item indices as pointers (`@ptrFromInt(idx + 1)`). Can't dangle, easy to debug.

4. **Fixed arrays for iteration**: Match REAPER's `enumMarker(idx)` pattern with `markers: [MAX]MarkerInfo` + `count: usize`.

5. **Namespaced re-exports**: Use `reaper.transport.foo` not `usingnamespace`. Explicit is better.

---

## References

- TigerBeetle deterministic simulation: https://github.com/tigerbeetle/tigerbeetle
- Ghostty comptime interface selection: https://github.com/ghostty-org/ghostty
- Zig Allocgate discussion on vtables: https://github.com/ziglang/zig/issues/12882
- std.mem.Allocator implementation pattern
- zig-gamedev bindings/wrapper split pattern

---

*Created: 2026-01-02*
*Updated: 2026-01-02 - Added architecture decisions from research*
*For: EXTENSION_RESILIENCE_PLAN.md Phase 8*
