/// REAPER API abstraction layer.
///
/// This module provides both the raw REAPER C API bindings and an abstract
/// interface for testability.
///
/// ## Quick Start
///
/// Production code:
/// ```zig
/// const reaper = @import("reaper.zig");
/// var real = reaper.RealApi{ .inner = &raw_api };
/// const api = real.interface();
/// ```
///
/// Test code:
/// ```zig
/// const reaper = @import("reaper.zig");
/// var mock = reaper.mock.MockApi{
///     .play_state = 1,
///     .bpm = 140.0,
/// };
/// const api = mock.interface();
/// ```
///
/// ## Module Structure
///
/// - `raw`: C function pointers and runtime loading (raw.zig)
/// - `api`: Abstract interface + RealApi wrapper (api.zig)
/// - `mock`: MockApi for testing (mock.zig)
/// - `types`: Shared type definitions (types.zig)
///
/// ## Backward Compatibility
///
/// For existing code, the following are re-exported at the top level:
/// - `Api` (from raw.zig)
/// - `PluginInfo` (from raw.zig)
/// - `Command` (from raw.zig)
/// - All shared types (BeatsInfo, MarkerInfo, etc.)

// =============================================================================
// Submodule namespaced access (preferred for new code)
// =============================================================================

pub const raw = @import("reaper/raw.zig");
pub const api = @import("reaper/api.zig");
pub const mock = @import("reaper/mock.zig");
pub const types = @import("reaper/types.zig");

// =============================================================================
// Re-exports for backward compatibility (existing code continues to work)
// =============================================================================

// Core types from raw.zig
pub const Api = raw.Api;
pub const PluginInfo = raw.PluginInfo;
pub const Command = raw.Command;
pub const PLUGIN_VERSION = raw.PLUGIN_VERSION;
pub const DEBUG_LOGGING = raw.DEBUG_LOGGING;

// Interface types from api.zig
pub const ApiInterface = api.ApiInterface;
pub const RealApi = api.RealApi;

// Shared types (from types.zig via api.zig)
pub const BeatsInfo = types.BeatsInfo;
pub const TempoAtPosition = types.TempoAtPosition;
pub const TempoMarker = types.TempoMarker;
pub const TimeSelection = types.TimeSelection;
pub const TimeSignature = types.TimeSignature;
pub const MarkerInfo = types.MarkerInfo;
pub const MarkerCount = types.MarkerCount;

// =============================================================================
// Tests
// =============================================================================

test {
    // Ensure all submodules compile
    _ = raw;
    _ = api;
    _ = mock;
    _ = types;
}

test "backward compatibility - Api type accessible" {
    // This ensures existing code like `const api: *const reaper.Api` still works
    const T = Api;
    _ = T;
}

test "backward compatibility - Command constants accessible" {
    // This ensures existing code like `reaper.Command.PLAY` still works
    const play_cmd = Command.PLAY;
    try @import("std").testing.expectEqual(@as(c_int, 1007), play_cmd);
}
