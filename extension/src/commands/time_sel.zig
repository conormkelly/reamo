const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");

// Time selection command handlers
pub const handlers = [_]mod.Entry{
    .{ .name = "timeSelection/set", .handler = handleSet },
    .{ .name = "timeSelection/setBars", .handler = handleSetBars },
    .{ .name = "timeSelection/clear", .handler = handleClear },
    .{ .name = "timeSelection/goStart", .handler = handleGoStart },
    .{ .name = "timeSelection/goEnd", .handler = handleGoEnd },
    .{ .name = "timeSelection/setStart", .handler = handleSetStart },
    .{ .name = "timeSelection/setEnd", .handler = handleSetEnd },
};

// Set time selection by seconds
fn handleSet(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const start = mod.validatePosition(cmd.getFloat("start")) orelse {
        response.err("INVALID_START", "Start must be a non-negative number");
        return;
    };
    const end = mod.validatePosition(cmd.getFloat("end")) orelse {
        response.err("INVALID_END", "End must be a non-negative number");
        return;
    };

    if (end < start) {
        response.err("INVALID_RANGE", "End must be greater than or equal to start");
        return;
    }

    api.setTimeSelection(start, end);
    api.log("Reamo: Set time selection {d:.2} - {d:.2}", .{ start, end });
}

// Set time selection by bar (with optional beat precision)
// Supports flexible input: {startBar, endBar} at minimum, optionally startBeat, endBeat
fn handleSetBars(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const start_bar = cmd.getInt("startBar") orelse {
        response.err("MISSING_START_BAR", "startBar is required");
        return;
    };
    const end_bar = cmd.getInt("endBar") orelse {
        response.err("MISSING_END_BAR", "endBar is required");
        return;
    };

    // Beat defaults to 1 (start of bar) if not provided
    const start_beat: f64 = if (cmd.getFloat("startBeat")) |b| b else 1.0;
    const end_beat: f64 = if (cmd.getFloat("endBeat")) |b| b else 1.0;

    // Convert bar.beat to time using REAPER's native conversion
    const start_time = api.barBeatToTime(start_bar, start_beat);
    const end_time = api.barBeatToTime(end_bar, end_beat);

    if (end_time < start_time) {
        response.err("INVALID_RANGE", "End must be greater than or equal to start");
        return;
    }

    api.setTimeSelection(start_time, end_time);
    api.log("Reamo: Set time selection bar {d}.{d:.1} - bar {d}.{d:.1}", .{ start_bar, start_beat, end_bar, end_beat });
}

// Clear time selection (uses REAPER's built-in command)
fn handleClear(api: *const reaper.Api, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.TIME_SEL_CLEAR);
}

// Go to start of time selection
fn handleGoStart(api: *const reaper.Api, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.TIME_SEL_GO_START);
}

// Go to end of time selection
fn handleGoEnd(api: *const reaper.Api, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.TIME_SEL_GO_END);
}

// Set time selection start at current cursor position
fn handleSetStart(api: *const reaper.Api, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.TIME_SEL_SET_START);
}

// Set time selection end at current cursor position
fn handleSetEnd(api: *const reaper.Api, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.TIME_SEL_SET_END);
}
