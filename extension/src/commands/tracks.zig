const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");
const gesture_state = @import("../gesture_state.zig");
const logging = @import("../logging.zig");

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
    .{ .name = "track/rename", .handler = handleRename },
    .{ .name = "track/create", .handler = handleCreate },
    .{ .name = "track/duplicate", .handler = handleDuplicate },
    .{ .name = "track/duplicateSelected", .handler = handleDuplicateSelected },
    .{ .name = "track/delete", .handler = handleDelete },
    .{ .name = "track/deleteSelected", .handler = handleDeleteSelected },
    .{ .name = "meter/clearClip", .handler = handleClearClip },
};

// Helper to get track by index from command
// Uses unified indexing: 0 = master, 1+ = user tracks
pub fn getTrackFromCmd(api: anytype, cmd: protocol.CommandMessage) ?*anyopaque {
    const track_idx = cmd.getInt("trackIdx") orelse return null;
    return api.getTrackByUnifiedIdx(track_idx);
}

// Set track volume (0..inf, 1.0 = 0dB)
// Uses CSurf API for undo coalescing - multiple rapid changes become one undo point
pub fn handleSetVolume(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
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

    logging.debug("Set track volume to {d:.3}", .{clamped});
}

// Set track pan (-1.0..1.0)
// Uses CSurf API for undo coalescing - multiple rapid changes become one undo point
pub fn handleSetPan(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
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

    logging.debug("Set track pan to {d:.2}", .{clamped});
}

// Set track mute (toggle if no value provided)
// Uses CSurf API for proper master track support
pub fn handleSetMute(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
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
        logging.debug("Set track mute to {}", .{mute});
    }
}

// Set track solo (0=off, 1=solo, 2=solo in place, etc.)
// Uses CSurf API for proper master track support
pub fn handleSetSolo(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
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
        logging.debug("Set track solo to {d}", .{solo});
    }
}

// Set track record arm (toggle if no value provided)
// Uses CSurf API for gang support (respects track grouping when allowGang=true)
pub fn handleSetRecArm(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track = getTrackFromCmd(api, cmd) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };
    const arm = if (cmd.getInt("arm")) |v| v != 0 else !api.getTrackRecArm(track);
    // Use CSurf API for gang support
    if (api.csurfSetRecArm(track, arm, true)) {
        logging.debug("Set track rec arm to {}", .{arm});
    }
}

// Set track record monitoring (0=off, 1=normal, 2=not when playing)
// Uses CSurf API for gang support (respects track grouping when allowGang=true)
pub fn handleSetRecMon(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
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
        logging.debug("Set track rec mon to {d}", .{result});
    }
}

// Set track FX enabled (toggle if no value provided)
pub fn handleSetFxEnabled(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track = getTrackFromCmd(api, cmd) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };
    const enabled = if (cmd.getInt("enabled")) |v| v != 0 else !api.getTrackFxEnabled(track);
    if (api.setTrackFxEnabled(track, enabled)) {
        logging.debug("Set track FX enabled to {}", .{enabled});
    }
}

// Set track selected (toggle if no value provided)
pub fn handleSetSelected(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track = getTrackFromCmd(api, cmd) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };
    const selected = if (cmd.getInt("selected")) |v| v != 0 else !api.getTrackSelected(track);
    if (api.setTrackSelected(track, selected)) {
        logging.debug("Set track selected to {}", .{selected});
    }
}

// Unselect all tracks (including master)
pub fn handleDeselectAll(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
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

    logging.debug("Unselected all tracks", .{});
}

// Clear clip indicator for a track's input meter
pub fn handleClearClip(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track = getTrackFromCmd(api, cmd) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };
    // Clear REAPER's internal peak hold for both channels
    // Next metering poll will see hold is now clear (no clipping)
    api.clearTrackPeakHold(track);
    logging.debug("Cleared clip indicator for track", .{});
    response.success(null);
}

// =============================================================================
// Track Management Commands
// =============================================================================

// Rename a track (master track cannot be renamed)
pub fn handleRename(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track_idx = cmd.getInt("trackIdx") orelse {
        response.err("INVALID_PARAMS", "trackIdx is required");
        return;
    };

    // Master track cannot be renamed
    if (track_idx == 0) {
        response.err("INVALID_OPERATION", "Master track cannot be renamed");
        return;
    }

    const track = api.getTrackByUnifiedIdx(track_idx) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };

    // Get name - use getStringUnescaped to handle JSON escape sequences
    var name_buf: [256]u8 = undefined;
    const name = cmd.getStringUnescaped("name", &name_buf) orelse {
        response.err("INVALID_PARAMS", "name is required");
        return;
    };

    if (api.setTrackName(track, name)) {
        logging.debug("Renamed track {d}", .{track_idx});
        response.success(null);
    } else {
        response.err("FAILED", "Could not rename track");
    }
}

// Create a new track
// Optional params: name (string), afterTrackIdx (int, unified index)
// Returns: {"trackIdx": N} with the new track's unified index
pub fn handleCreate(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const current_count = api.trackCount();

    // Determine insert position (regular track index, 0-based)
    // afterTrackIdx uses unified indexing (0=master, 1+=user tracks)
    const insert_idx: c_int = if (cmd.getInt("afterTrackIdx")) |after_idx| blk: {
        // Validate: must be >= 0 and <= current_count (unified)
        if (after_idx < 0 or after_idx > current_count) {
            response.err("INVALID_PARAMS", "afterTrackIdx out of range");
            return;
        }
        // Insert after unified index = insert at regular index after_idx
        // (since unified 0=master maps to "insert at beginning" = regular 0)
        break :blk after_idx;
    } else blk: {
        // No afterTrackIdx: append at end
        break :blk current_count;
    };

    // Insert the track (wantDefaults=true for normal track settings)
    api.insertTrack(insert_idx, true);

    // New track is now at unified index insert_idx + 1
    const new_unified_idx = insert_idx + 1;

    // Optionally set the name
    var name_buf: [256]u8 = undefined;
    if (cmd.getStringUnescaped("name", &name_buf)) |name| {
        if (name.len > 0) {
            if (api.getTrackByUnifiedIdx(new_unified_idx)) |track| {
                _ = api.setTrackName(track, name);
            }
        }
    }

    // Return the new track index
    var resp_buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&resp_buf, "{{\"trackIdx\":{d}}}", .{new_unified_idx}) catch {
        response.err("INTERNAL", "Buffer overflow");
        return;
    };
    response.success(json);
    logging.debug("Created track at unified index {d}", .{new_unified_idx});
}

// Duplicate a track (master track cannot be duplicated)
// Uses undo block + action 40062 for full duplication (FX, items, envelopes, routing)
// Returns: {"trackIdx": N} with the duplicated track's unified index
pub fn handleDuplicate(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track_idx = cmd.getInt("trackIdx") orelse {
        response.err("INVALID_PARAMS", "trackIdx is required");
        return;
    };

    // Master track cannot be duplicated
    if (track_idx == 0) {
        response.err("INVALID_OPERATION", "Master track cannot be duplicated");
        return;
    }

    const track = api.getTrackByUnifiedIdx(track_idx) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };

    // Begin undo block for clean single undo point
    api.undoBeginBlock();

    // Unselect all tracks
    api.runCommand(reaper.Command.UNSELECT_ALL_TRACKS);

    // Select the source track
    _ = api.setTrackSelected(track, true);

    // Duplicate selected tracks
    api.runCommand(reaper.Command.DUPLICATE_TRACKS);

    // Get the newly selected track (the duplicate)
    const new_track = api.getSelectedTrackByIdx(0);

    // End undo block with descriptive name (needs null-terminated string)
    var desc_buf: [64:0]u8 = undefined;
    const desc_ptr: [*:0]const u8 = if (std.fmt.bufPrintZ(&desc_buf, "Duplicate track {d}", .{track_idx})) |_|
        &desc_buf
    else |_|
        "Duplicate track";
    api.undoEndBlock(desc_ptr);

    if (new_track == null) {
        response.err("FAILED", "Could not get duplicated track");
        return;
    }

    // Find the unified index of the new track
    // The duplicate is inserted immediately after the source, so it's at track_idx + 1
    const new_unified_idx = track_idx + 1;

    // Return the new track index
    var resp_buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&resp_buf, "{{\"trackIdx\":{d}}}", .{new_unified_idx}) catch {
        response.err("INTERNAL", "Buffer overflow");
        return;
    };
    response.success(json);
    logging.debug("Duplicated track {d} to {d}", .{ track_idx, new_unified_idx });
}

// Delete a track (master track cannot be deleted)
pub fn handleDelete(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track_idx = cmd.getInt("trackIdx") orelse {
        response.err("INVALID_PARAMS", "trackIdx is required");
        return;
    };

    // Master track cannot be deleted
    if (track_idx == 0) {
        response.err("INVALID_OPERATION", "Master track cannot be deleted");
        return;
    }

    const track = api.getTrackByUnifiedIdx(track_idx) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };

    // Delete the track (REAPER creates undo point automatically)
    api.deleteTrackPtr(track);

    logging.debug("Deleted track {d}", .{track_idx});
    response.success(null);
}

// Duplicate all currently selected tracks
// Uses native REAPER action 40062 which handles full duplication
pub fn handleDuplicateSelected(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    _ = cmd;
    _ = response;
    api.runCommand(reaper.Command.DUPLICATE_TRACKS);
    logging.debug("Duplicated selected tracks", .{});
}

// Delete all currently selected tracks
// Uses native REAPER action 40005 which handles deletion with undo
pub fn handleDeleteSelected(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    _ = cmd;
    _ = response;
    api.runCommand(reaper.Command.DELETE_SELECTED_TRACKS);
    logging.debug("Deleted selected tracks", .{});
}
