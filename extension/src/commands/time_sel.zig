const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../core/protocol.zig");
const mod = @import("mod.zig");
const logging = @import("../core/logging.zig");

/// Set time selection by seconds
pub fn handleSet(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
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
    logging.debug("Set time selection {d:.2} - {d:.2}", .{ start, end });
}

/// Set time selection by bar (with optional beat precision)
/// Supports flexible input: {startBar, endBar} at minimum, optionally startBeat, endBeat
pub fn handleSetBars(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
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
    logging.debug("Set time selection bar {d}.{d:.1} - bar {d}.{d:.1}", .{ start_bar, start_beat, end_bar, end_beat });
}

/// Clear time selection (uses REAPER's built-in command)
pub fn handleClear(api: anytype, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.TIME_SEL_CLEAR);
}

/// Go to start of time selection
pub fn handleGoStart(api: anytype, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.TIME_SEL_GO_START);
}

/// Go to end of time selection
pub fn handleGoEnd(api: anytype, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.TIME_SEL_GO_END);
}

/// Set time selection start at current cursor position
pub fn handleSetStart(api: anytype, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.TIME_SEL_SET_START);
}

/// Set time selection end at current cursor position
pub fn handleSetEnd(api: anytype, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.TIME_SEL_SET_END);
}
