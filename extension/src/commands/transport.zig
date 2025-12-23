const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");

// Transport command handlers
pub const handlers = [_]mod.Entry{
    .{ .name = "transport/play", .handler = handlePlay },
    .{ .name = "transport/stop", .handler = handleStop },
    .{ .name = "transport/pause", .handler = handlePause },
    .{ .name = "transport/record", .handler = handleRecord },
    .{ .name = "transport/playPause", .handler = handlePlayPause },
    .{ .name = "transport/seek", .handler = handleSeek },
    .{ .name = "transport/stopAndDelete", .handler = handleStopAndDelete },
    .{ .name = "transport/goStart", .handler = handleGoStart },
    .{ .name = "transport/goEnd", .handler = handleGoEnd },
    .{ .name = "transport/seekBeats", .handler = handleSeekBeats },
};

fn handlePlay(api: *const reaper.Api, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.PLAY);
}

fn handleStop(api: *const reaper.Api, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.STOP);
}

fn handlePause(api: *const reaper.Api, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.PAUSE);
}

fn handleRecord(api: *const reaper.Api, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.RECORD);
}

fn handlePlayPause(api: *const reaper.Api, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.PLAY_PAUSE);
}

fn handleSeek(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const pos = mod.validatePosition(cmd.getFloat("position")) orelse {
        response.err("INVALID_POSITION", "Position must be a non-negative number");
        return;
    };
    api.setCursorPos(pos);
}

// Stop and DELETE all recorded media - use with caution!
fn handleStopAndDelete(api: *const reaper.Api, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.STOP_AND_DELETE);
}

// Go to project start
fn handleGoStart(api: *const reaper.Api, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.GO_TO_PROJECT_START);
}

// Go to project end
fn handleGoEnd(api: *const reaper.Api, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.GO_TO_PROJECT_END);
}

// Seek by bar.beat position
// Supports flexible input: {bar} at minimum, optionally beat
fn handleSeekBeats(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const bar = cmd.getInt("bar") orelse {
        response.err("MISSING_BAR", "bar is required");
        return;
    };

    // Beat defaults to 1 (start of bar) if not provided
    const beat: f64 = if (cmd.getFloat("beat")) |b| b else 1.0;

    // Convert bar.beat to time using REAPER's native conversion
    const time = api.barBeatToTime(bar, beat);
    api.setCursorPos(time);
    api.log("Reamo: Seek to bar {d}.{d:.1} ({d:.3}s)", .{ bar, beat, time });
}
