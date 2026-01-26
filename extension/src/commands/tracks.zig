const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../core/protocol.zig");
const mod = @import("mod.zig");
const gesture_state = @import("../server/gesture_state.zig");
const logging = @import("../core/logging.zig");

// Helper to get track by index from command
// Uses unified indexing: 0 = master, 1+ = user tracks
pub fn getTrackFromCmd(api: anytype, cmd: protocol.CommandMessage) ?*anyopaque {
    const track_idx = cmd.getInt("trackIdx") orelse return null;
    return api.getTrackByUnifiedIdx(track_idx);
}

/// Result of resolving track from command - includes both pointer and index.
/// Index is needed for gesture tracking (ControlId).
pub const TrackResolution = struct {
    track: *anyopaque,
    idx: c_int,
};

/// Resolve track from command using either trackIdx or trackGuid.
/// trackIdx takes precedence if both are present.
/// Returns null if track not found or GUID is stale.
pub fn resolveTrack(api: anytype, cmd: protocol.CommandMessage) ?TrackResolution {
    // Try trackIdx first (faster, direct lookup)
    if (cmd.getInt("trackIdx")) |track_idx| {
        if (api.getTrackByUnifiedIdx(track_idx)) |track| {
            return .{ .track = track, .idx = track_idx };
        }
        return null; // Invalid index
    }

    // Try trackGuid (requires cache lookup + validation)
    const guid = cmd.getString("trackGuid") orelse return null;
    const cache = mod.g_ctx.guid_cache orelse return null;

    const track = cache.resolve(guid) orelse return null;

    // Validate the pointer is still valid (O(n) scan for safety after track deletion)
    if (!api.validateTrackPtr(track)) {
        return null; // Stale GUID - track was deleted
    }

    // Get the index for gesture tracking
    const idx = api.getTrackIdx(track);
    if (idx < 0) return null;

    return .{ .track = track, .idx = idx };
}

// Set track volume (0..inf, 1.0 = 0dB)
// Uses CSurf API for undo coalescing - multiple rapid changes become one undo point
// Accepts trackIdx or trackGuid parameter
pub fn handleSetVolume(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const resolution = resolveTrack(api, cmd) orelse {
        response.err("NOT_FOUND", "trackIdx or trackGuid required, or track not found");
        return;
    };
    const volume = cmd.getFloat("volume") orelse {
        response.err("MISSING_VOLUME", "volume is required");
        return;
    };
    // Clamp to valid range
    const clamped = @max(0.0, volume);

    // Use CSurf API for undo coalescing (allowGang=true to respect track grouping)
    _ = api.csurfSetVolume(resolution.track, clamped, true);

    // Record activity for gesture timeout tracking
    if (response.gestures) |gestures| {
        gestures.recordActivity(gesture_state.ControlId.volume(resolution.idx));
    }

    logging.debug("Set track volume to {d:.3}", .{clamped});
    response.success(null);
}

// Set track pan (-1.0..1.0)
// Uses CSurf API for undo coalescing - multiple rapid changes become one undo point
// Accepts trackIdx or trackGuid parameter
pub fn handleSetPan(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const resolution = resolveTrack(api, cmd) orelse {
        response.err("NOT_FOUND", "trackIdx or trackGuid required, or track not found");
        return;
    };
    const pan = cmd.getFloat("pan") orelse {
        response.err("MISSING_PAN", "pan is required");
        return;
    };
    // Clamp to valid range
    const clamped = @max(-1.0, @min(1.0, pan));

    // Use CSurf API for undo coalescing (allowGang=true to respect track grouping)
    _ = api.csurfSetPan(resolution.track, clamped, true);

    // Record activity for gesture timeout tracking
    if (response.gestures) |gestures| {
        gestures.recordActivity(gesture_state.ControlId.pan(resolution.idx));
    }

    logging.debug("Set track pan to {d:.2}", .{clamped});
    response.success(null);
}

// Set track mute (toggle if no value provided)
// Uses CSurf API for proper master track support
// Accepts trackIdx or trackGuid parameter
pub fn handleSetMute(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const resolution = resolveTrack(api, cmd) orelse {
        response.err("NOT_FOUND", "trackIdx or trackGuid required, or track not found");
        return;
    };
    // Toggle if no explicit value
    // For master track (idx=0), use GetMasterMuteSoloFlags for reliable state
    const current_mute = if (resolution.idx == 0) api.isMasterMuted() else api.getTrackMute(resolution.track);
    const mute = if (cmd.getInt("mute")) |v| v != 0 else !current_mute;
    // Use CSurf API - properly handles master track unlike SetMediaTrackInfo_Value
    if (api.csurfSetMute(resolution.track, mute, true)) {
        logging.debug("Set track mute to {}", .{mute});
    }
    response.success(null);
}

// Set track solo (0=off, 1=solo, 2=solo in place, etc.)
// Uses CSurf API for proper master track support
// Accepts trackIdx or trackGuid parameter
pub fn handleSetSolo(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const resolution = resolveTrack(api, cmd) orelse {
        response.err("NOT_FOUND", "trackIdx or trackGuid required, or track not found");
        return;
    };
    // Toggle between 0 and 1 if no explicit value
    // For master track (idx=0), use GetMasterMuteSoloFlags for reliable state
    const current_solo = if (resolution.idx == 0)
        (if (api.isMasterSoloed()) @as(c_int, 1) else @as(c_int, 0))
    else
        api.getTrackSolo(resolution.track) catch {
            response.err("INVALID_STATE", "Track returned invalid solo state");
            return;
        };
    const solo = if (cmd.getInt("solo")) |v| v else if (current_solo > 0) @as(c_int, 0) else @as(c_int, 1);
    // Use CSurf API - properly handles master track unlike SetMediaTrackInfo_Value
    if (api.csurfSetSolo(resolution.track, solo, true)) {
        logging.debug("Set track solo to {d}", .{solo});
    }
    response.success(null);
}

// Action ID for "Unsolo all tracks"
const ACTION_UNSOLO_ALL: c_int = 40340;

// Exclusive solo: unsolo all tracks, then solo this one
// Atomic operation with single undo point
// Accepts trackIdx or trackGuid parameter
pub fn handleSetSoloExclusive(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const resolution = resolveTrack(api, cmd) orelse {
        response.err("NOT_FOUND", "trackIdx or trackGuid required, or track not found");
        return;
    };

    // Begin undo block for atomic operation
    api.undoBeginBlock();

    // Unsolo all tracks via action
    api.runCommand(ACTION_UNSOLO_ALL);

    // Solo the target track
    _ = api.csurfSetSolo(resolution.track, 1, false); // allowGang=false for exclusive

    // End undo block with descriptive name
    api.undoEndBlock("REAmo: Solo track exclusively");

    logging.debug("Exclusive solo on track {d}", .{resolution.idx});
    response.success(null);
}

// Set track record arm (toggle if no value provided)
// Uses CSurf API for gang support (respects track grouping when allowGang=true)
// Accepts trackIdx or trackGuid parameter
pub fn handleSetRecArm(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const resolution = resolveTrack(api, cmd) orelse {
        response.err("NOT_FOUND", "trackIdx or trackGuid required, or track not found");
        return;
    };
    const arm = if (cmd.getInt("arm")) |v| v != 0 else !api.getTrackRecArm(resolution.track);
    // Use CSurf API for gang support
    if (api.csurfSetRecArm(resolution.track, arm, true)) {
        logging.debug("Set track rec arm to {}", .{arm});
    }
    response.success(null);
}

// Set track record monitoring (0=off, 1=normal, 2=not when playing)
// Uses CSurf API for gang support (respects track grouping when allowGang=true)
// Accepts trackIdx or trackGuid parameter
pub fn handleSetRecMon(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const resolution = resolveTrack(api, cmd) orelse {
        response.err("NOT_FOUND", "trackIdx or trackGuid required, or track not found");
        return;
    };
    // Cycle through 0,1,2 if no explicit value
    const mon = if (cmd.getInt("mon")) |v| v else blk: {
        const current = api.getTrackRecMon(resolution.track) catch {
            response.err("INVALID_STATE", "Track returned invalid rec mon state");
            return;
        };
        break :blk @mod(current + 1, 3);
    };
    // Use CSurf API for gang support
    const result = api.csurfSetRecMon(resolution.track, mon, true);
    if (result >= 0) {
        logging.debug("Set track rec mon to {d}", .{result});
    }
    response.success(null);
}

// Set track FX enabled (toggle if no value provided)
// Accepts trackIdx or trackGuid parameter
pub fn handleSetFxEnabled(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const resolution = resolveTrack(api, cmd) orelse {
        response.err("NOT_FOUND", "trackIdx or trackGuid required, or track not found");
        return;
    };
    const enabled = if (cmd.getInt("enabled")) |v| v != 0 else !api.getTrackFxEnabled(resolution.track);
    if (api.setTrackFxEnabled(resolution.track, enabled)) {
        logging.debug("Set track FX enabled to {}", .{enabled});
    }
    response.success(null);
}

// Set track selected (toggle if no value provided)
// Accepts trackIdx or trackGuid parameter
pub fn handleSetSelected(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const resolution = resolveTrack(api, cmd) orelse {
        response.err("NOT_FOUND", "trackIdx or trackGuid required, or track not found");
        return;
    };
    const selected = if (cmd.getInt("selected")) |v| v != 0 else !api.getTrackSelected(resolution.track);
    if (api.setTrackSelected(resolution.track, selected)) {
        logging.debug("Set track selected to {}", .{selected});
    }
    response.success(null);
}

// Unselect all tracks (including master)
pub fn handleDeselectAll(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    _ = cmd;

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
    response.success(null);
}

// Clear clip indicator for a track's input meter
// Accepts trackIdx or trackGuid parameter
pub fn handleClearClip(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const resolution = resolveTrack(api, cmd) orelse {
        response.err("NOT_FOUND", "trackIdx or trackGuid required, or track not found");
        return;
    };
    // Clear REAPER's internal peak hold for both channels
    // Next metering poll will see hold is now clear (no clipping)
    api.clearTrackPeakHold(resolution.track);
    logging.debug("Cleared clip indicator for track", .{});
    response.success(null);
}

// =============================================================================
// Track Management Commands
// =============================================================================

// Rename a track (master track cannot be renamed)
// Accepts trackIdx or trackGuid parameter
pub fn handleRename(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const resolution = resolveTrack(api, cmd) orelse {
        response.err("NOT_FOUND", "trackIdx or trackGuid required, or track not found");
        return;
    };

    // Master track cannot be renamed
    if (resolution.idx == 0) {
        response.err("INVALID_OPERATION", "Master track cannot be renamed");
        return;
    }

    // Get name - use getStringUnescaped to handle JSON escape sequences
    var name_buf: [256]u8 = undefined;
    const name = cmd.getStringUnescaped("name", &name_buf) orelse {
        response.err("INVALID_PARAMS", "name is required");
        return;
    };

    if (api.setTrackName(resolution.track, name)) {
        logging.debug("Renamed track {d}", .{resolution.idx});
        response.success(null);
    } else {
        response.err("FAILED", "Could not rename track");
    }
}

// Set track color
// Accepts trackIdx or trackGuid parameter
// color: OS-native color value (0 to reset to default)
pub fn handleSetColor(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const resolution = resolveTrack(api, cmd) orelse {
        response.err("NOT_FOUND", "trackIdx or trackGuid required, or track not found");
        return;
    };

    const color = cmd.getInt("color") orelse {
        response.err("INVALID_PARAMS", "color is required");
        return;
    };

    // Build descriptive undo message
    var track_name_buf: [128]u8 = undefined;
    var undo_buf: [256:0]u8 = undefined;
    const track_name = api.getTrackNameStr(resolution.track, &track_name_buf);

    const undo_desc: [*:0]const u8 = if (resolution.idx == 0)
        std.fmt.bufPrintZ(&undo_buf, "REAmo: Set track color: Master", .{}) catch "REAmo: Set track color"
    else
        std.fmt.bufPrintZ(&undo_buf, "REAmo: Set track color: Track {d} {s}", .{ resolution.idx, track_name }) catch "REAmo: Set track color";

    api.undoBeginBlock();
    api.setTrackColor(resolution.track, color);
    api.undoEndBlock(undo_desc);

    logging.debug("Set color for track {d} to {d}", .{ resolution.idx, color });
    response.success(null);
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
// Accepts trackIdx or trackGuid parameter
// Returns: {"trackIdx": N} with the duplicated track's unified index
pub fn handleDuplicate(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const resolution = resolveTrack(api, cmd) orelse {
        response.err("NOT_FOUND", "trackIdx or trackGuid required, or track not found");
        return;
    };

    // Master track cannot be duplicated
    if (resolution.idx == 0) {
        response.err("INVALID_OPERATION", "Master track cannot be duplicated");
        return;
    }

    // Begin undo block for clean single undo point
    api.undoBeginBlock();

    // Unselect all tracks
    api.runCommand(reaper.Command.UNSELECT_ALL_TRACKS);

    // Select the source track
    _ = api.setTrackSelected(resolution.track, true);

    // Duplicate selected tracks
    api.runCommand(reaper.Command.DUPLICATE_TRACKS);

    // Get the newly selected track (the duplicate)
    const new_track = api.getSelectedTrackByIdx(0);

    // End undo block with descriptive name (needs null-terminated string)
    var desc_buf: [64:0]u8 = undefined;
    const desc_ptr: [*:0]const u8 = if (std.fmt.bufPrintZ(&desc_buf, "Duplicate track {d}", .{resolution.idx})) |_|
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
    const new_unified_idx = resolution.idx + 1;

    // Return the new track index
    var resp_buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&resp_buf, "{{\"trackIdx\":{d}}}", .{new_unified_idx}) catch {
        response.err("INTERNAL", "Buffer overflow");
        return;
    };
    response.success(json);
    logging.debug("Duplicated track {d} to {d}", .{ resolution.idx, new_unified_idx });
}

// Delete a track (master track cannot be deleted)
// Accepts trackIdx or trackGuid parameter
pub fn handleDelete(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const resolution = resolveTrack(api, cmd) orelse {
        response.err("NOT_FOUND", "trackIdx or trackGuid required, or track not found");
        return;
    };

    // Master track cannot be deleted
    if (resolution.idx == 0) {
        response.err("INVALID_OPERATION", "Master track cannot be deleted");
        return;
    }

    // Delete the track (REAPER creates undo point automatically)
    api.deleteTrackPtr(resolution.track);

    logging.debug("Deleted track {d}", .{resolution.idx});
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

// =============================================================================
// On-Demand Data Commands
// =============================================================================
// These commands fetch full detail data that is NOT included in the regular
// track polling events (which only contain sparse counts like fx_count, send_count).
// Frontend calls these when user expands track details or opens FX/routing views.

// Maximum FX per response (soft limit)
const MAX_FX_RESPONSE = 256;
// Maximum sends per response (soft limit)
const MAX_SENDS_RESPONSE = 128;
// FX name buffer size
const FX_NAME_LEN = 128;
// Preset name buffer size
const PRESET_NAME_LEN = 128;

/// Get full FX detail for a single track with pagination.
/// Input: { trackIdx: number, offset?: number, limit?: number }
/// Response: { fx: [...], total: number, offset: number, hasMore: boolean }
pub fn handleGetFx(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track_idx = cmd.getInt("trackIdx") orelse {
        response.err("INVALID_PARAMS", "trackIdx is required");
        return;
    };
    const track = api.getTrackByUnifiedIdx(track_idx) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };

    // Pagination parameters
    const offset_raw = cmd.getInt("offset") orelse 0;
    const offset: usize = if (offset_raw > 0) @intCast(offset_raw) else 0;
    const limit_raw = cmd.getInt("limit") orelse MAX_FX_RESPONSE;
    const limit: usize = if (limit_raw > 0) @intCast(@min(limit_raw, MAX_FX_RESPONSE)) else MAX_FX_RESPONSE;

    const fx_count_raw = api.trackFxCount(track);
    const total: usize = if (fx_count_raw > 0) @intCast(fx_count_raw) else 0;

    // Calculate range to return
    const start: usize = @min(offset, total);
    const end: usize = @min(start + limit, total);
    const fx_count = end - start;
    const has_more = end < total;

    // Serialize directly to response buffer
    var buf: [32768]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    var w = stream.writer();

    w.print("{{\"fx\":[", .{}) catch {
        response.err("SERIALIZE_ERROR", "Buffer overflow");
        return;
    };

    var i: usize = start;
    var written: usize = 0;
    while (i < end) : (i += 1) {
        const fx_idx: c_int = @intCast(i);

        // Get FX name
        var name_buf: [FX_NAME_LEN]u8 = undefined;
        const name = api.trackFxGetName(track, fx_idx, &name_buf);

        // Get preset info
        var preset_count: c_int = 0;
        const preset_index = api.trackFxGetPresetIndex(track, fx_idx, &preset_count);

        var preset_name_buf: [PRESET_NAME_LEN]u8 = undefined;
        const preset_info = api.trackFxGetPreset(track, fx_idx, &preset_name_buf);

        const enabled = api.trackFxGetEnabled(track, fx_idx);

        // Write JSON object
        if (written > 0) w.writeByte(',') catch {
            response.err("SERIALIZE_ERROR", "Buffer overflow");
            return;
        };
        written += 1;

        w.print("{{\"fxIndex\":{d},\"name\":\"", .{fx_idx}) catch {
            response.err("SERIALIZE_ERROR", "Buffer overflow");
            return;
        };
        writeJsonEscaped(w, name) catch {
            response.err("SERIALIZE_ERROR", "Buffer overflow");
            return;
        };
        w.writeAll("\",\"presetName\":\"") catch {
            response.err("SERIALIZE_ERROR", "Buffer overflow");
            return;
        };
        writeJsonEscaped(w, preset_info.name) catch {
            response.err("SERIALIZE_ERROR", "Buffer overflow");
            return;
        };
        w.print("\",\"presetIndex\":{d},\"presetCount\":{d},\"modified\":{s},\"enabled\":{s}}}", .{
            preset_index,
            preset_count,
            if (!preset_info.matches_preset) "true" else "false",
            if (enabled) "true" else "false",
        }) catch {
            response.err("SERIALIZE_ERROR", "Buffer overflow");
            return;
        };
    }

    w.print("],\"total\":{d},\"offset\":{d},\"hasMore\":{s}}}", .{
        total,
        offset,
        if (has_more) "true" else "false",
    }) catch {
        response.err("SERIALIZE_ERROR", "Buffer overflow");
        return;
    };

    response.success(stream.getWritten());
    logging.debug("Returned {d} FX for track {d} (offset={d}, total={d})", .{ fx_count, track_idx, offset, total });
}

/// Get full send detail for a single track with pagination.
/// Input: { trackIdx: number, offset?: number, limit?: number }
/// Response: { sends: [...], total: number, offset: number, hasMore: boolean }
pub fn handleGetSends(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track_idx = cmd.getInt("trackIdx") orelse {
        response.err("INVALID_PARAMS", "trackIdx is required");
        return;
    };
    const track = api.getTrackByUnifiedIdx(track_idx) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };

    // Pagination parameters
    const offset_raw = cmd.getInt("offset") orelse 0;
    const offset: usize = if (offset_raw > 0) @intCast(offset_raw) else 0;
    const limit_raw = cmd.getInt("limit") orelse MAX_SENDS_RESPONSE;
    const limit: usize = if (limit_raw > 0) @intCast(@min(limit_raw, MAX_SENDS_RESPONSE)) else MAX_SENDS_RESPONSE;

    const send_count_raw = api.trackSendCount(track);
    const total: usize = if (send_count_raw > 0) @intCast(send_count_raw) else 0;

    // Calculate range to return
    const start: usize = @min(offset, total);
    const end: usize = @min(start + limit, total);
    const send_count = end - start;
    const has_more = end < total;

    // Serialize directly to response buffer
    var buf: [16384]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    var w = stream.writer();

    w.print("{{\"sends\":[", .{}) catch {
        response.err("SERIALIZE_ERROR", "Buffer overflow");
        return;
    };

    var i: usize = start;
    var written: usize = 0;
    while (i < end) : (i += 1) {
        const send_idx: c_int = @intCast(i);

        // Get send properties
        var dest_name_buf: [FX_NAME_LEN]u8 = undefined;
        const dest_name = api.trackSendGetDestName(track, send_idx, &dest_name_buf);
        const volume = api.trackSendGetVolume(track, send_idx);
        const muted = api.trackSendGetMute(track, send_idx);
        const mode = api.trackSendGetMode(track, send_idx) catch 0;

        // Write JSON object
        if (written > 0) w.writeByte(',') catch {
            response.err("SERIALIZE_ERROR", "Buffer overflow");
            return;
        };
        written += 1;

        w.print("{{\"sendIndex\":{d},\"destName\":\"", .{send_idx}) catch {
            response.err("SERIALIZE_ERROR", "Buffer overflow");
            return;
        };
        writeJsonEscaped(w, dest_name) catch {
            response.err("SERIALIZE_ERROR", "Buffer overflow");
            return;
        };
        w.print("\",\"volume\":{d:.6},\"muted\":{s},\"mode\":{d}}}", .{
            volume,
            if (muted) "true" else "false",
            mode,
        }) catch {
            response.err("SERIALIZE_ERROR", "Buffer overflow");
            return;
        };
    }

    w.print("],\"total\":{d},\"offset\":{d},\"hasMore\":{s}}}", .{
        total,
        offset,
        if (has_more) "true" else "false",
    }) catch {
        response.err("SERIALIZE_ERROR", "Buffer overflow");
        return;
    };

    response.success(stream.getWritten());
    logging.debug("Returned {d} sends for track {d} (offset={d}, total={d})", .{ send_count, track_idx, offset, total });
}

/// On-demand sparse-field retrieval for track hardware outputs.
/// Returns paginated HW output list with volume, pan, mute, mode.
const MAX_HW_OUTPUTS_RESPONSE = 64;

pub fn handleGetHwOutputs(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track_idx = cmd.getInt("trackIdx") orelse {
        response.err("INVALID_PARAMS", "trackIdx is required");
        return;
    };
    const track = api.getTrackByUnifiedIdx(track_idx) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };

    // Pagination parameters
    const offset_raw = cmd.getInt("offset") orelse 0;
    const offset: usize = if (offset_raw > 0) @intCast(offset_raw) else 0;
    const limit_raw = cmd.getInt("limit") orelse MAX_HW_OUTPUTS_RESPONSE;
    const limit: usize = if (limit_raw > 0) @intCast(@min(limit_raw, MAX_HW_OUTPUTS_RESPONSE)) else MAX_HW_OUTPUTS_RESPONSE;

    const hw_count_raw = api.trackHwOutputCount(track);
    const total: usize = if (hw_count_raw > 0) @intCast(hw_count_raw) else 0;

    // Calculate range to return
    const start: usize = @min(offset, total);
    const end: usize = @min(start + limit, total);
    const hw_count = end - start;
    const has_more = end < total;

    // Serialize directly to response buffer
    var buf: [16384]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    var w = stream.writer();

    w.print("{{\"hwOutputs\":[", .{}) catch {
        response.err("SERIALIZE_ERROR", "Buffer overflow");
        return;
    };

    var i: usize = start;
    var written: usize = 0;
    while (i < end) : (i += 1) {
        const hw_idx: c_int = @intCast(i);

        // Get HW output properties
        const volume = api.trackHwOutputGetVolume(track, hw_idx);
        const pan = api.trackHwOutputGetPan(track, hw_idx);
        const muted = api.trackHwOutputGetMute(track, hw_idx);
        const mode = api.trackHwOutputGetMode(track, hw_idx) catch 0;
        const dest_chan = api.trackHwOutputGetDestChannel(track, hw_idx) catch 0;

        // Write JSON object
        if (written > 0) w.writeByte(',') catch {
            response.err("SERIALIZE_ERROR", "Buffer overflow");
            return;
        };
        written += 1;

        w.print("{{\"hwIdx\":{d},\"destChannel\":{d},\"volume\":{d:.6},\"pan\":{d:.3},\"muted\":{s},\"mode\":{d}}}", .{
            hw_idx,
            dest_chan,
            volume,
            pan,
            if (muted) "true" else "false",
            mode,
        }) catch {
            response.err("SERIALIZE_ERROR", "Buffer overflow");
            return;
        };
    }

    w.print("],\"total\":{d},\"offset\":{d},\"hasMore\":{s}}}", .{
        total,
        offset,
        if (has_more) "true" else "false",
    }) catch {
        response.err("SERIALIZE_ERROR", "Buffer overflow");
        return;
    };

    response.success(stream.getWritten());
    logging.debug("Returned {d} hw outputs for track {d} (offset={d}, total={d})", .{ hw_count, track_idx, offset, total });
}

/// Helper to write JSON-escaped string
fn writeJsonEscaped(writer: anytype, str: []const u8) !void {
    for (str) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    // Skip control characters
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "handleSetColor requires trackIdx or trackGuid" {
    // Command handlers require ResponseWriter with SharedState.
    // Integration tests via websocat verify full behavior.
    // See mock/mod.zig for MockBackend method tests.
}

test "handleSetColor with color=0 resets to default" {
    // Verifies color=0 clears custom color (restores theme default).
    // See mock/mod.zig "MockBackend setTrackColor" test.
}
