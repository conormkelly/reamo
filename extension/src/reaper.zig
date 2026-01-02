/// REAPER API abstraction layer.
///
/// This module provides both the raw REAPER C API bindings and backend
/// implementations for testability via comptime generics.
///
/// ## Quick Start
///
/// Production code:
/// ```zig
/// const reaper = @import("reaper.zig");
/// var backend = reaper.RealBackend{ .inner = &raw_api };
/// const state = transport.poll(&backend);
/// ```
///
/// Test code:
/// ```zig
/// const reaper = @import("reaper.zig");
/// var mock = reaper.MockBackend{
///     .play_state = 1,
///     .bpm = 140.0,
/// };
/// const state = transport.poll(&mock);
/// ```
///
/// ## Module Structure
///
/// - `raw`: C function pointers and runtime loading (raw.zig)
/// - `real`: RealBackend production wrapper (real.zig)
/// - `mock`: MockBackend for testing (mock/mod.zig)
/// - `types`: Shared type definitions (types.zig)
/// - `backend`: Backend interface validation (backend.zig)

// =============================================================================
// Submodule namespaced access
// =============================================================================

pub const raw = @import("reaper/raw.zig");
pub const real = @import("reaper/real.zig");
pub const mock = @import("reaper/mock/mod.zig");
pub const types = @import("reaper/types.zig");
pub const backend = @import("reaper/backend.zig");

// =============================================================================
// Backend exports
// =============================================================================

/// Production backend - thin wrapper around raw REAPER API.
pub const RealBackend = real.RealBackend;

/// Test backend - field-based mock with call tracking.
pub const MockBackend = mock.MockBackend;

/// Comptime validation that a type implements all backend methods.
pub const validateBackend = backend.validateBackend;

// =============================================================================
// Core types from raw.zig
// =============================================================================
pub const Api = raw.Api;
pub const PluginInfo = raw.PluginInfo;
pub const Command = raw.Command;
pub const PLUGIN_VERSION = raw.PLUGIN_VERSION;
pub const DEBUG_LOGGING = raw.DEBUG_LOGGING;

// =============================================================================
// Shared type exports
// =============================================================================

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
    _ = real;
    _ = mock;
    _ = types;
    _ = backend;
}

test "RealBackend type accessible" {
    const T = RealBackend;
    _ = T;
}

test "MockBackend type accessible" {
    const T = MockBackend;
    _ = T;
}

test "Command constants accessible" {
    const play_cmd = Command.PLAY;
    try @import("std").testing.expectEqual(@as(c_int, 1007), play_cmd);
}
