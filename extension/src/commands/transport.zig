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

    // Beat defaults to 1 (start of bar) if not provided
    const beat: f64 = if (cmd.getFloat("beat")) |b| b else 1.0;

    // Convert bar.beat to time using REAPER's native conversion
    const time = api.barBeatToTime(bar, beat);
    api.setCursorPos(time);
    logging.info("Seek to bar {d}.{d:.1} ({d:.3}s)", .{ bar, beat, time });
}
