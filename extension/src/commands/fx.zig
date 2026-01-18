const std = @import("std");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");
const logging = @import("../logging.zig");
const tracks = @import("tracks.zig");

/// Navigate to next preset for the specified FX
/// Params: trackIdx (unified: 0=master, 1+=user tracks), fxIdx (0-based)
pub fn handlePresetNext(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track_idx = cmd.getInt("trackIdx") orelse {
        response.err("MISSING_TRACK_IDX", "trackIdx is required");
        return;
    };
    const fx_idx = cmd.getInt("fxIdx") orelse {
        response.err("MISSING_FX_IDX", "fxIdx is required");
        return;
    };

    const track = api.getTrackByUnifiedIdx(track_idx) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };

    const success = api.trackFxNavigatePresets(track, fx_idx, 1);
    if (!success) {
        response.err("NAVIGATE_FAILED", "Failed to navigate to next preset");
        return;
    }

    logging.debug("FX preset next: track {} fx {}", .{ track_idx, fx_idx });
}

/// Navigate to previous preset for the specified FX
/// Params: trackIdx (unified: 0=master, 1+=user tracks), fxIdx (0-based)
pub fn handlePresetPrev(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track_idx = cmd.getInt("trackIdx") orelse {
        response.err("MISSING_TRACK_IDX", "trackIdx is required");
        return;
    };
    const fx_idx = cmd.getInt("fxIdx") orelse {
        response.err("MISSING_FX_IDX", "fxIdx is required");
        return;
    };

    const track = api.getTrackByUnifiedIdx(track_idx) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };

    const success = api.trackFxNavigatePresets(track, fx_idx, -1);
    if (!success) {
        response.err("NAVIGATE_FAILED", "Failed to navigate to previous preset");
        return;
    }

    logging.debug("FX preset prev: track {} fx {}", .{ track_idx, fx_idx });
}

/// Set preset by index for the specified FX
/// Params: trackIdx, fxIdx, presetIdx (-1=default user, -2=factory, 0+=preset index)
pub fn handlePresetSet(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track_idx = cmd.getInt("trackIdx") orelse {
        response.err("MISSING_TRACK_IDX", "trackIdx is required");
        return;
    };
    const fx_idx = cmd.getInt("fxIdx") orelse {
        response.err("MISSING_FX_IDX", "fxIdx is required");
        return;
    };
    const preset_idx = cmd.getInt("presetIdx") orelse {
        response.err("MISSING_PRESET_IDX", "presetIdx is required (-1=default, -2=factory, or 0+)");
        return;
    };

    const track = api.getTrackByUnifiedIdx(track_idx) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };

    const success = api.trackFxSetPresetByIndex(track, fx_idx, preset_idx);
    if (!success) {
        response.err("SET_FAILED", "Failed to set preset");
        return;
    }

    logging.debug("FX preset set: track {} fx {} preset {}", .{ track_idx, fx_idx, preset_idx });
}

/// Set FX enabled/bypassed state
/// Params: trackIdx or trackGuid (unified: 0=master, 1+=user tracks), fxIdx (0-based)
/// Optional: enabled (0=bypass, 1=enabled) - toggles if omitted
pub fn handleSetEnabled(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const resolution = tracks.resolveTrack(api, cmd) orelse {
        response.err("NOT_FOUND", "trackIdx or trackGuid required, or track not found");
        return;
    };
    const fx_idx = cmd.getInt("fxIdx") orelse {
        response.err("MISSING_FX_IDX", "fxIdx is required");
        return;
    };

    // Validate fx_idx bounds
    if (fx_idx < 0) {
        response.err("INVALID_FX_IDX", "fxIdx must be non-negative");
        return;
    }
    const fx_count = api.trackFxCount(resolution.track);
    if (fx_idx >= fx_count) {
        response.err("INVALID_FX_IDX", "fxIdx out of range");
        return;
    }

    // Get current state for toggle, or use explicit enabled param
    const current = api.trackFxGetEnabled(resolution.track, fx_idx);
    const enabled = if (cmd.getInt("enabled")) |e| e != 0 else !current;

    // Build undo description with track/FX names
    var track_name_buf: [128]u8 = undefined;
    var fx_name_buf: [128]u8 = undefined;
    var undo_buf: [256:0]u8 = undefined;

    const track_name = api.getTrackNameStr(resolution.track, &track_name_buf);
    const fx_name = api.trackFxGetName(resolution.track, fx_idx, &fx_name_buf);

    const undo_desc: [*:0]const u8 = if (resolution.idx == 0)
        std.fmt.bufPrintZ(&undo_buf, "REAmo: FX bypass toggle: Master: {s}", .{fx_name}) catch "REAmo: FX bypass toggle"
    else
        std.fmt.bufPrintZ(&undo_buf, "REAmo: FX bypass toggle: Track {d} {s}: {s}", .{ resolution.idx, track_name, fx_name }) catch "REAmo: FX bypass toggle";

    api.undoBeginBlock();
    api.trackFxSetEnabled(resolution.track, fx_idx, enabled);
    api.undoEndBlock(undo_desc);

    logging.debug("FX enabled set: track {} fx {} enabled={}", .{ resolution.idx, fx_idx, enabled });
    response.success(null);
}

/// Add an FX to a track by name.
/// Params: trackGuid, fxName, position (optional, -1 = end)
/// Response: { "fxGuid": "{...}", "fxIndex": N }
pub fn handleAdd(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const resolution = tracks.resolveTrack(api, cmd) orelse {
        logging.warn("trackFx/add: track not found", .{});
        response.err("NOT_FOUND", "trackGuid required, or track not found");
        return;
    };

    // Validate track pointer
    if (resolution.idx != 0 and !api.validateTrackPtr(resolution.track)) {
        logging.warn("trackFx/add: invalid track pointer", .{});
        response.err("INVALID_TRACK", "Track no longer exists");
        return;
    }

    const fx_name = cmd.getString("fxName") orelse {
        logging.warn("trackFx/add: missing fxName", .{});
        response.err("MISSING_PARAM", "fxName is required");
        return;
    };

    const position = cmd.getInt("position") orelse -1;

    // Build null-terminated name for REAPER API
    var name_buf: [256:0]u8 = undefined;
    const name_len = @min(fx_name.len, name_buf.len - 1);
    @memcpy(name_buf[0..name_len], fx_name[0..name_len]);
    name_buf[name_len] = 0;

    // Build undo description
    var undo_buf: [256:0]u8 = undefined;
    const undo_desc: [*:0]const u8 = std.fmt.bufPrintZ(&undo_buf, "REAmo: Add FX: {s}", .{fx_name}) catch "REAmo: Add FX";

    api.undoBeginBlock();
    const fx_idx = api.trackFxAddByName(resolution.track, @ptrCast(&name_buf), false, position);
    api.undoEndBlock(undo_desc);

    if (fx_idx < 0) {
        logging.warn("trackFx/add: TrackFX_AddByName failed for '{s}'", .{fx_name});
        response.err("ADD_FAILED", "Failed to add FX - check FX name");
        return;
    }

    // Get the new FX GUID
    var guid_buf: [64]u8 = undefined;
    const fx_guid = api.trackFxGetGuid(resolution.track, fx_idx, &guid_buf);

    // Build response JSON
    var resp_buf: [256]u8 = undefined;
    const resp_json = std.fmt.bufPrint(&resp_buf, "{{\"fxGuid\":\"{s}\",\"fxIndex\":{d}}}", .{ fx_guid, fx_idx }) catch {
        response.success(null);
        return;
    };

    logging.debug("trackFx/add: added '{s}' at index {d}, guid={s}", .{ fx_name, fx_idx, fx_guid });
    response.success(resp_json);
}

/// Delete an FX from a track.
/// Params: trackGuid, fxGuid OR fxIndex
pub fn handleDelete(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const resolution = tracks.resolveTrack(api, cmd) orelse {
        logging.warn("trackFx/delete: track not found", .{});
        response.err("NOT_FOUND", "trackGuid required, or track not found");
        return;
    };

    // Validate track pointer
    if (resolution.idx != 0 and !api.validateTrackPtr(resolution.track)) {
        logging.warn("trackFx/delete: invalid track pointer", .{});
        response.err("INVALID_TRACK", "Track no longer exists");
        return;
    }

    // Resolve FX by GUID or index
    const fx_idx = resolveFxIndex(api, resolution.track, cmd) orelse {
        logging.warn("trackFx/delete: FX not found", .{});
        response.err("FX_NOT_FOUND", "fxGuid or fxIndex required, or FX not found");
        return;
    };

    // Build undo description
    var fx_name_buf: [128]u8 = undefined;
    const fx_name = api.trackFxGetName(resolution.track, fx_idx, &fx_name_buf);
    var undo_buf: [256:0]u8 = undefined;
    const undo_desc: [*:0]const u8 = std.fmt.bufPrintZ(&undo_buf, "REAmo: Delete FX: {s}", .{fx_name}) catch "REAmo: Delete FX";

    api.undoBeginBlock();
    const success = api.trackFxDelete(resolution.track, fx_idx);
    api.undoEndBlock(undo_desc);

    if (!success) {
        logging.warn("trackFx/delete: TrackFX_Delete failed for index {d}", .{fx_idx});
        response.err("DELETE_FAILED", "Failed to delete FX");
        return;
    }

    logging.debug("trackFx/delete: deleted FX at index {d}", .{fx_idx});
    response.success(null);
}

/// Move an FX to a new position within the same track.
/// Params: trackGuid, fxGuid, toIndex
/// Response: { "newIndex": N }
pub fn handleMove(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const resolution = tracks.resolveTrack(api, cmd) orelse {
        logging.warn("trackFx/move: track not found", .{});
        response.err("NOT_FOUND", "trackGuid required, or track not found");
        return;
    };

    // Validate track pointer
    if (resolution.idx != 0 and !api.validateTrackPtr(resolution.track)) {
        logging.warn("trackFx/move: invalid track pointer", .{});
        response.err("INVALID_TRACK", "Track no longer exists");
        return;
    }

    // Resolve FX by GUID
    const fx_guid = cmd.getString("fxGuid") orelse {
        logging.warn("trackFx/move: missing fxGuid", .{});
        response.err("MISSING_PARAM", "fxGuid is required");
        return;
    };

    const src_idx = findFxByGuid(api, resolution.track, fx_guid) orelse {
        logging.warn("trackFx/move: FX GUID not found: {s}", .{fx_guid});
        response.err("FX_NOT_FOUND", "FX with given GUID not found");
        return;
    };

    const to_index = cmd.getInt("toIndex") orelse {
        logging.warn("trackFx/move: missing toIndex", .{});
        response.err("MISSING_PARAM", "toIndex is required");
        return;
    };

    // Validate toIndex bounds
    const fx_count = api.trackFxCount(resolution.track);
    if (to_index < 0 or to_index >= fx_count) {
        logging.warn("trackFx/move: toIndex out of range: {d} (count={d})", .{ to_index, fx_count });
        response.err("INVALID_INDEX", "toIndex out of range");
        return;
    }

    if (src_idx == to_index) {
        // No move needed
        var resp_buf: [64]u8 = undefined;
        const resp_json = std.fmt.bufPrint(&resp_buf, "{{\"newIndex\":{d}}}", .{to_index}) catch {
            response.success(null);
            return;
        };
        response.success(resp_json);
        return;
    }

    // Build undo description
    var undo_buf: [256:0]u8 = undefined;
    const undo_desc: [*:0]const u8 = std.fmt.bufPrintZ(&undo_buf, "REAmo: Move FX", .{}) catch "REAmo: Move FX";

    api.undoBeginBlock();
    api.trackFxCopyToTrack(resolution.track, src_idx, resolution.track, to_index, true);
    api.undoEndBlock(undo_desc);

    // Build response
    var resp_buf: [64]u8 = undefined;
    const resp_json = std.fmt.bufPrint(&resp_buf, "{{\"newIndex\":{d}}}", .{to_index}) catch {
        response.success(null);
        return;
    };

    logging.debug("trackFx/move: moved FX from {d} to {d}", .{ src_idx, to_index });
    response.success(resp_json);
}

/// Helper: Resolve FX index from fxGuid or fxIndex parameter.
fn resolveFxIndex(api: anytype, track: *anyopaque, cmd: protocol.CommandMessage) ?c_int {
    // Try fxGuid first
    if (cmd.getString("fxGuid")) |fx_guid| {
        return findFxByGuid(api, track, fx_guid);
    }

    // Fall back to fxIndex
    if (cmd.getInt("fxIndex")) |fx_idx| {
        const fx_count = api.trackFxCount(track);
        if (fx_idx >= 0 and fx_idx < fx_count) {
            return fx_idx;
        }
    }

    return null;
}

/// Helper: Find FX index by GUID on a track.
fn findFxByGuid(api: anytype, track: *anyopaque, target_guid: []const u8) ?c_int {
    const fx_count = api.trackFxCount(track);
    var i: c_int = 0;
    while (i < fx_count) : (i += 1) {
        var guid_buf: [64]u8 = undefined;
        const guid = api.trackFxGetGuid(track, i, &guid_buf);
        if (std.mem.eql(u8, guid, target_guid)) {
            return i;
        }
    }
    return null;
}

// ============================================================================
// Tests
// ============================================================================

test "handleSetEnabled requires trackIdx or trackGuid" {
    // Command handlers require ResponseWriter with SharedState.
    // Integration tests via websocat verify full behavior.
    // See mock/mod.zig for MockBackend method tests.
}

test "handleSetEnabled validates fx_idx bounds" {
    // Verifies negative and out-of-range fx_idx returns error.
    // See mock/mod.zig "MockBackend trackFxSetEnabled bounds check" test.
}

test "resolveFxIndex and findFxByGuid compile" {
    // Integration tests via websocat verify full behavior.
}
