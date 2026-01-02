const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");
const gesture_state = @import("../gesture_state.zig");

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
    .{ .name = "track/unselectAll", .handler = handleDeselectAll },
    .{ .name = "meter/clearClip", .handler = handleClearClip },
};

// Helper to get track by index from command
// Uses unified indexing: 0 = master, 1+ = user tracks
fn getTrackFromCmd(api: *const reaper.Api, cmd: protocol.CommandMessage) ?*anyopaque {
    const track_idx = cmd.getInt("trackIdx") orelse return null;
    return api.getTrackByUnifiedIdx(track_idx);
}

// Set track volume (0..inf, 1.0 = 0dB)
// Uses CSurf API for undo coalescing - multiple rapid changes become one undo point
fn handleSetVolume(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track_idx = cmd.getInt("trackIdx") orelse {
        response.err("NOT_FOUND", "trackIdx is required");
        return;
    };
    const track = api.getTrackByUnifiedIdx(track_idx) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };
    const volume = cmd.getFloat("volume") orelse {
        response.err("MISSING_VOLUME", "volume is required");
        return;
    };
    // Clamp to valid range
    const clamped = @max(0.0, volume);

    // Use CSurf API for undo coalescing (allowGang=true to respect track grouping)
    _ = api.csurfSetVolume(track, clamped, true);

    // Record activity for gesture timeout tracking
    if (response.gestures) |gestures| {
        gestures.recordActivity(gesture_state.ControlId.volume(track_idx));
    }

    api.log("Reamo: Set track volume to {d:.3}", .{clamped});
}

// Set track pan (-1.0..1.0)
// Uses CSurf API for undo coalescing - multiple rapid changes become one undo point
fn handleSetPan(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track_idx = cmd.getInt("trackIdx") orelse {
        response.err("NOT_FOUND", "trackIdx is required");
        return;
    };
    const track = api.getTrackByUnifiedIdx(track_idx) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };
    const pan = cmd.getFloat("pan") orelse {
        response.err("MISSING_PAN", "pan is required");
        return;
    };
    // Clamp to valid range
    const clamped = @max(-1.0, @min(1.0, pan));

    // Use CSurf API for undo coalescing (allowGang=true to respect track grouping)
    _ = api.csurfSetPan(track, clamped, true);

    // Record activity for gesture timeout tracking
    if (response.gestures) |gestures| {
        gestures.recordActivity(gesture_state.ControlId.pan(track_idx));
    }

    api.log("Reamo: Set track pan to {d:.2}", .{clamped});
}

// Set track mute (toggle if no value provided)
// Uses CSurf API for proper master track support
fn handleSetMute(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track_idx = cmd.getInt("trackIdx") orelse {
        response.err("NOT_FOUND", "trackIdx is required");
        return;
    };
    const track = api.getTrackByUnifiedIdx(track_idx) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };
    // Toggle if no explicit value
    // For master track (idx=0), use GetMasterMuteSoloFlags for reliable state
    const current_mute = if (track_idx == 0) api.isMasterMuted() else api.getTrackMute(track);
    const mute = if (cmd.getInt("mute")) |v| v != 0 else !current_mute;
    // Use CSurf API - properly handles master track unlike SetMediaTrackInfo_Value
    if (api.csurfSetMute(track, mute, true)) {
        api.log("Reamo: Set track mute to {}", .{mute});
    }
}

// Set track solo (0=off, 1=solo, 2=solo in place, etc.)
// Uses CSurf API for proper master track support
fn handleSetSolo(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track_idx = cmd.getInt("trackIdx") orelse {
        response.err("NOT_FOUND", "trackIdx is required");
        return;
    };
    const track = api.getTrackByUnifiedIdx(track_idx) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };
    // Toggle between 0 and 1 if no explicit value
    // For master track (idx=0), use GetMasterMuteSoloFlags for reliable state
    const current_solo = if (track_idx == 0)
        (if (api.isMasterSoloed()) @as(c_int, 1) else @as(c_int, 0))
    else
        api.getTrackSolo(track) catch {
            response.err("INVALID_STATE", "Track returned invalid solo state");
            return;
        };
    const solo = if (cmd.getInt("solo")) |v| v else if (current_solo > 0) @as(c_int, 0) else @as(c_int, 1);
    // Use CSurf API - properly handles master track unlike SetMediaTrackInfo_Value
    if (api.csurfSetSolo(track, solo, true)) {
        api.log("Reamo: Set track solo to {d}", .{solo});
    }
}

// Set track record arm (toggle if no value provided)
// Uses CSurf API for gang support (respects track grouping when allowGang=true)
fn handleSetRecArm(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track = getTrackFromCmd(api, cmd) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };
    const arm = if (cmd.getInt("arm")) |v| v != 0 else !api.getTrackRecArm(track);
    // Use CSurf API for gang support
    if (api.csurfSetRecArm(track, arm, true)) {
        api.log("Reamo: Set track rec arm to {}", .{arm});
    }
}

// Set track record monitoring (0=off, 1=normal, 2=not when playing)
// Uses CSurf API for gang support (respects track grouping when allowGang=true)
fn handleSetRecMon(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track = getTrackFromCmd(api, cmd) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };
    // Cycle through 0,1,2 if no explicit value
    const mon = if (cmd.getInt("mon")) |v| v else blk: {
        const current = api.getTrackRecMon(track) catch {
            response.err("INVALID_STATE", "Track returned invalid rec mon state");
            return;
        };
        break :blk @mod(current + 1, 3);
    };
    // Use CSurf API for gang support
    const result = api.csurfSetRecMon(track, mon, true);
    if (result >= 0) {
        api.log("Reamo: Set track rec mon to {d}", .{result});
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

// Unselect all tracks (including master)
fn handleDeselectAll(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    _ = cmd;
    _ = response;

    // Unselect master track
    if (api.masterTrack()) |master| {
        _ = api.setTrackSelected(master, false);
    }

    // Unselect all user tracks
    const count = api.trackCount();
    var i: c_int = 0;
    while (i < count) : (i += 1) {
        if (api.getTrackByIdx(i)) |track| {
            _ = api.setTrackSelected(track, false);
        }
    }

    api.log("Reamo: Unselected all tracks", .{});
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
