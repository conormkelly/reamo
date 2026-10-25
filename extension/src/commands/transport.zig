const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../core/protocol.zig");
const mod = @import("mod.zig");
const logging = @import("../core/logging.zig");

pub fn handlePlay(api: anytype, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.PLAY);
}

pub fn handleStop(api: anytype, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.STOP);
}

pub fn handlePause(api: anytype, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.PAUSE);
}

pub fn handleRecord(api: anytype, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.RECORD);
}

pub fn handlePlayPause(api: anytype, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.PLAY_PAUSE);
}

pub fn handleSeek(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const pos = mod.validatePosition(cmd.getFloat("position")) orelse {
        response.err("INVALID_POSITION", "Position must be a non-negative number");
        return;
    };
    api.setCursorPos(pos);
}

/// Stop and DELETE all recorded media - use with caution!
pub fn handleStopAndDelete(api: anytype, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.STOP_AND_DELETE);
}

/// Go to project start
pub fn handleGoStart(api: anytype, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.GO_TO_PROJECT_START);
}

/// Go to project end
pub fn handleGoEnd(api: anytype, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.GO_TO_PROJECT_END);
}

/// Seek by bar.beat position
/// Supports flexible input: {bar} at minimum, optionally beat
pub fn handleSeekBeats(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const bar = cmd.getInt("bar") orelse {
        response.err("MISSING_BAR", "bar is required");
        return;
    };
    if (mod.validateBar(bar) == null) {
        response.err("INVALID_BAR", "bar is out of range");
        return;
    }

    // Beat defaults to 1 (start of bar) if not provided
    const beat: f64 = if (cmd.getFloat("beat")) |b| b else 1.0;

    const time = mod.displayedBarBeatToTime(api, bar, beat) orelse {
        response.err("INVALID_BAR", "bar is out of range");
        return;
    };
    api.setCursorPos(time);
    logging.debug("Seek to bar {d}.{d:.1} ({d:.3}s)", .{ bar, beat, time });
}

// ============================================================================
// Tests
// ============================================================================

test "transport/seekBeats goes to the bar the ruler shows when the project starts at measure -5" {
    const mock = @import("../reaper/mock/mod.zig");
    // 120 BPM 4/4: a bar is 2 s; with start measure -5, time 0 reads -4.1.00.
    var m = mock.MockBackend{ .bar_offset = -5 };
    mod.testRunHandler(&m, handleSeekBeats, "{\"type\":\"command\",\"command\":\"transport/seekBeats\",\"bar\":1,\"beat\":3}");
    try std.testing.expectApproxEqAbs(@as(f64, 5 * 2.0 + 1.0), m.cursor_position, 1e-9);
}

test "transport/seekBeats rejects bars that would overflow bar arithmetic" {
    const mock = @import("../reaper/mock/mod.zig");
    var m = mock.MockBackend{};
    mod.testRunHandler(&m, handleSeekBeats,
        \\{"type":"command","command":"transport/seekBeats","bar":-2147483648}
    );
    try std.testing.expectEqual(@as(usize, 0), m.getCallCount(.setCursorPos));

    mod.testRunHandler(&m, handleSeekBeats,
        \\{"type":"command","command":"transport/seekBeats","bar":3}
    );
    try std.testing.expectEqual(@as(usize, 1), m.getCallCount(.setCursorPos));
}
