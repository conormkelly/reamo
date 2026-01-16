const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");

/// Send MIDI Control Change (dual-sends to VKB + Control paths)
/// Params: cc (0-127), value (0-127), channel (0-15, default 0)
pub fn handleCC(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const cc = cmd.getInt("cc") orelse {
        response.err("MISSING_CC", "cc (0-127) is required");
        return;
    };

    if (cc < 0 or cc > 127) {
        response.err("INVALID_CC", "cc must be 0-127");
        return;
    }

    const value = cmd.getInt("value") orelse {
        response.err("MISSING_VALUE", "value (0-127) is required");
        return;
    };

    if (value < 0 or value > 127) {
        response.err("INVALID_VALUE", "value must be 0-127");
        return;
    }

    const channel = cmd.getInt("channel") orelse 0;
    if (channel < 0 or channel > 15) {
        response.err("INVALID_CHANNEL", "channel must be 0-15");
        return;
    }

    api.sendMidiCC(@intCast(channel), @intCast(cc), @intCast(value));
    response.success(null);
}

/// Send MIDI Program Change (dual-sends to VKB + Control paths)
/// Params: program (0-127), channel (0-15, default 0)
pub fn handlePC(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const program = cmd.getInt("program") orelse {
        response.err("MISSING_PROGRAM", "program (0-127) is required");
        return;
    };

    if (program < 0 or program > 127) {
        response.err("INVALID_PROGRAM", "program must be 0-127");
        return;
    }

    const channel = cmd.getInt("channel") orelse 0;
    if (channel < 0 or channel > 15) {
        response.err("INVALID_CHANNEL", "channel must be 0-15");
        return;
    }

    api.sendMidiPC(@intCast(channel), @intCast(program));
    response.success(null);
}

/// Send MIDI Note On message (VKB mode for instrument tracks)
/// Use velocity=0 for note-off (standard running status optimization)
/// Params: note (0-127), velocity (0-127), channel (0-15, default 0)
pub fn handleNoteOn(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const note = cmd.getInt("note") orelse {
        response.err("MISSING_NOTE", "note (0-127) is required");
        return;
    };

    if (note < 0 or note > 127) {
        response.err("INVALID_NOTE", "note must be 0-127");
        return;
    }

    const velocity = cmd.getInt("velocity") orelse {
        response.err("MISSING_VELOCITY", "velocity (0-127) is required");
        return;
    };

    if (velocity < 0 or velocity > 127) {
        response.err("INVALID_VELOCITY", "velocity must be 0-127");
        return;
    }

    const channel = cmd.getInt("channel") orelse 0;
    if (channel < 0 or channel > 15) {
        response.err("INVALID_CHANNEL", "channel must be 0-15");
        return;
    }

    api.sendNoteOn(@intCast(channel), @intCast(note), @intCast(velocity));
    response.success(null);
}
