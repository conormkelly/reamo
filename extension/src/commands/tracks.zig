const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");

// Track command handlers
pub const handlers = [_]mod.Entry{
    .{ .name = "track/setVolume", .handler = handleSetVolume },
    .{ .name = "track/setPan", .handler = handleSetPan },
    .{ .name = "track/setMute", .handler = handleSetMute },
    .{ .name = "track/setSolo", .handler = handleSetSolo },
    .{ .name = "track/setRecArm", .handler = handleSetRecArm },
    .{ .name = "track/setRecMon", .handler = handleSetRecMon },
    .{ .name = "track/setFxEnabled", .handler = handleSetFxEnabled },
    .{ .name = "track/setSelected", .handler = handleSetSelected },
    .{ .name = "meter/clearClip", .handler = handleClearClip },
};

// Helper to get track by index from command
// Uses unified indexing: 0 = master, 1+ = user tracks
fn getTrackFromCmd(api: *const reaper.Api, cmd: protocol.CommandMessage) ?*anyopaque {
    const track_idx = cmd.getInt("trackIdx") orelse return null;
    return api.getTrackByUnifiedIdx(track_idx);
}

// Set track volume (0..inf, 1.0 = 0dB)
fn handleSetVolume(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track = getTrackFromCmd(api, cmd) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };
    const volume = cmd.getFloat("volume") orelse {
        response.err("MISSING_VOLUME", "volume is required");
        return;
    };
    // Clamp to valid range
    const clamped = @max(0.0, volume);
    if (api.setTrackVolume(track, clamped)) {
        api.log("Reamo: Set track volume to {d:.3}", .{clamped});
    }
}

// Set track pan (-1.0..1.0)
fn handleSetPan(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track = getTrackFromCmd(api, cmd) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };
    const pan = cmd.getFloat("pan") orelse {
        response.err("MISSING_PAN", "pan is required");
        return;
    };
    // Clamp to valid range
    const clamped = @max(-1.0, @min(1.0, pan));
    if (api.setTrackPan(track, clamped)) {
        api.log("Reamo: Set track pan to {d:.2}", .{clamped});
    }
}

// Set track mute (toggle if no value provided)
fn handleSetMute(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track = getTrackFromCmd(api, cmd) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };
    // Toggle if no explicit value
    const mute = if (cmd.getInt("mute")) |v| v != 0 else !api.getTrackMute(track);
    if (api.setTrackMute(track, mute)) {
        api.log("Reamo: Set track mute to {}", .{mute});
    }
}

// Set track solo (0=off, 1=solo, 2=solo in place, etc.)
fn handleSetSolo(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track = getTrackFromCmd(api, cmd) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };
    // Toggle between 0 and 1 if no explicit value
    const solo = if (cmd.getInt("solo")) |v| v else if (api.getTrackSolo(track) > 0) @as(c_int, 0) else @as(c_int, 1);
    if (api.setTrackSolo(track, solo)) {
        api.log("Reamo: Set track solo to {d}", .{solo});
    }
}

// Set track record arm (toggle if no value provided)
fn handleSetRecArm(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track = getTrackFromCmd(api, cmd) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };
    const arm = if (cmd.getInt("arm")) |v| v != 0 else !api.getTrackRecArm(track);
    if (api.setTrackRecArm(track, arm)) {
        api.log("Reamo: Set track rec arm to {}", .{arm});
    }
}

// Set track record monitoring (0=off, 1=normal, 2=not when playing)
fn handleSetRecMon(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track = getTrackFromCmd(api, cmd) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };
    // Cycle through 0,1,2 if no explicit value
    const mon = if (cmd.getInt("mon")) |v| v else blk: {
        const current = api.getTrackRecMon(track);
        break :blk @mod(current + 1, 3);
    };
    if (api.setTrackRecMon(track, mon)) {
        api.log("Reamo: Set track rec mon to {d}", .{mon});
    }
}

// Set track FX enabled (toggle if no value provided)
fn handleSetFxEnabled(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track = getTrackFromCmd(api, cmd) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };
    const enabled = if (cmd.getInt("enabled")) |v| v != 0 else !api.getTrackFxEnabled(track);
    if (api.setTrackFxEnabled(track, enabled)) {
        api.log("Reamo: Set track FX enabled to {}", .{enabled});
    }
}

// Set track selected (toggle if no value provided)
fn handleSetSelected(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track = getTrackFromCmd(api, cmd) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };
    const selected = if (cmd.getInt("selected")) |v| v != 0 else !api.getTrackSelected(track);
    if (api.setTrackSelected(track, selected)) {
        api.log("Reamo: Set track selected to {}", .{selected});
    }
}

// Clear clip indicator for a track's input meter
fn handleClearClip(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track = getTrackFromCmd(api, cmd) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };
    // Clear REAPER's internal peak hold for both channels
    // Next metering poll will see hold is now clear (no clipping)
    api.clearTrackPeakHold(track);
    api.log("Reamo: Cleared clip indicator for track", .{});
    response.success(null);
}
