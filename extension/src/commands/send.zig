const std = @import("std");
const protocol = @import("../core/protocol.zig");
const mod = @import("mod.zig");
const tracks = @import("tracks.zig");
const gesture_state = @import("../server/gesture_state.zig");
const logging = @import("../core/logging.zig");

/// Set send volume for the specified send
/// Params: trackIdx (unified: 0=master, 1+=user tracks), sendIdx (0-based), volume (linear, 1.0 = 0dB)
pub fn handleSetVolume(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track_idx = cmd.getInt("trackIdx") orelse {
        response.err("MISSING_TRACK_IDX", "trackIdx is required");
        return;
    };
    const send_idx = cmd.getInt("sendIdx") orelse {
        response.err("MISSING_SEND_IDX", "sendIdx is required");
        return;
    };
    const volume = cmd.getFloat("volume") orelse {
        response.err("MISSING_VOLUME", "volume is required (linear, 1.0 = 0dB)");
        return;
    };

    const track = api.getTrackByUnifiedIdx(track_idx) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };

    // Use CSurf for undo coalescing
    _ = api.trackSendSetVolume(track, send_idx, volume);

    // Record activity for gesture timeout tracking
    if (response.gestures) |gestures| {
        gestures.recordActivity(gesture_state.ControlId.sendVolume(track_idx, send_idx));
    }

    logging.debug("Send volume set: track {} send {} volume {d:.3}", .{ track_idx, send_idx, volume });
    response.success(null);
}

/// Set send mute state for the specified send
/// Params: trackIdx, sendIdx, muted (boolean)
pub fn handleSetMute(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track_idx = cmd.getInt("trackIdx") orelse {
        response.err("MISSING_TRACK_IDX", "trackIdx is required");
        return;
    };
    const send_idx = cmd.getInt("sendIdx") orelse {
        response.err("MISSING_SEND_IDX", "sendIdx is required");
        return;
    };
    const muted_int = cmd.getInt("muted") orelse {
        response.err("MISSING_MUTED", "muted is required (0 or 1)");
        return;
    };
    const muted = muted_int != 0;

    const track = api.getTrackByUnifiedIdx(track_idx) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };

    const success = api.trackSendSetMute(track, send_idx, muted);
    if (!success) {
        response.err("SET_FAILED", "Failed to set send mute state");
        return;
    }

    logging.debug("Send mute set: track {} send {} muted {}", .{ track_idx, send_idx, muted });
    response.success(null);
}

/// Set send pan for the specified send
/// Params: trackIdx, sendIdx, pan (-1.0 to 1.0)
pub fn handleSetPan(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track_idx = cmd.getInt("trackIdx") orelse {
        response.err("MISSING_TRACK_IDX", "trackIdx is required");
        return;
    };
    const send_idx = cmd.getInt("sendIdx") orelse {
        response.err("MISSING_SEND_IDX", "sendIdx is required");
        return;
    };
    const pan = cmd.getFloat("pan") orelse {
        response.err("MISSING_PAN", "pan is required (-1.0 to 1.0)");
        return;
    };

    const track = api.getTrackByUnifiedIdx(track_idx) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };

    // Clamp pan to valid range
    const clamped = @max(-1.0, @min(1.0, pan));

    // Use CSurf for undo coalescing
    _ = api.trackSendSetPan(track, send_idx, clamped);

    // Record activity for gesture timeout tracking
    if (response.gestures) |gestures| {
        gestures.recordActivity(gesture_state.ControlId.sendPan(track_idx, send_idx));
    }

    logging.debug("Send pan set: track {} send {} pan {d:.3}", .{ track_idx, send_idx, clamped });
    response.success(null);
}

/// Set send mode for the specified send
/// Params: trackIdx, sendIdx, mode (0=post-fader, 1=pre-FX, 3=post-FX)
pub fn handleSetMode(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track_idx = cmd.getInt("trackIdx") orelse {
        response.err("MISSING_TRACK_IDX", "trackIdx is required");
        return;
    };
    const send_idx = cmd.getInt("sendIdx") orelse {
        response.err("MISSING_SEND_IDX", "sendIdx is required");
        return;
    };
    const mode = cmd.getInt("mode") orelse {
        response.err("MISSING_MODE", "mode is required (0=post-fader, 1=pre-FX, 3=post-FX)");
        return;
    };

    // Validate mode (no mode 2 in REAPER)
    if (mode != 0 and mode != 1 and mode != 3) {
        response.err("INVALID_MODE", "mode must be 0, 1, or 3");
        return;
    }

    const track = api.getTrackByUnifiedIdx(track_idx) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };

    const success = api.trackSendSetMode(track, send_idx, mode);
    if (!success) {
        response.err("SET_FAILED", "Failed to set send mode");
        return;
    }

    logging.debug("Send mode set: track {} send {} mode {}", .{ track_idx, send_idx, mode });
    response.success(null);
}

/// Create a new send from source track to destination track.
/// Params: trackGuid (source), destTrackGuid (destination)
/// Response: { "sendIndex": N }
pub fn handleAdd(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const src_guid = cmd.getString("trackGuid") orelse {
        response.err("MISSING_PARAM", "trackGuid is required");
        return;
    };
    const dest_guid = cmd.getString("destTrackGuid") orelse {
        response.err("MISSING_PARAM", "destTrackGuid is required");
        return;
    };

    const cache = mod.g_ctx.guid_cache orelse {
        response.err("NOT_INITIALIZED", "GUID cache not initialized");
        return;
    };

    const src_track = cache.resolve(src_guid) orelse {
        response.err("NOT_FOUND", "Source track not found");
        return;
    };
    if (!api.validateTrackPtr(src_track)) {
        response.err("NOT_FOUND", "Source track no longer exists");
        return;
    }

    const dest_track = cache.resolve(dest_guid) orelse {
        response.err("NOT_FOUND", "Destination track not found");
        return;
    };
    if (!api.validateTrackPtr(dest_track)) {
        response.err("NOT_FOUND", "Destination track no longer exists");
        return;
    }

    if (src_track == dest_track) {
        response.err("INVALID_PARAM", "Cannot create send to self");
        return;
    }

    api.undoBeginBlock();
    const send_idx = api.createSend(src_track, dest_track);
    api.undoEndBlock("REAmo: Create send");

    if (send_idx < 0) {
        response.err("CREATE_FAILED", "Failed to create send");
        return;
    }

    var resp_buf: [64]u8 = undefined;
    const resp_json = std.fmt.bufPrint(&resp_buf, "{{\"sendIndex\":{d}}}", .{send_idx}) catch {
        logging.warn("send/add: response buffer overflow", .{});
        response.success(null);
        return;
    };
    logging.debug("Send created: idx {d}", .{send_idx});
    response.success(resp_json);
}

/// Remove a send by index.
/// Params: trackGuid (or trackIdx), sendIdx
pub fn handleRemove(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const resolution = tracks.resolveTrack(api, cmd) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };

    const send_idx = cmd.getInt("sendIdx") orelse {
        response.err("MISSING_PARAM", "sendIdx is required");
        return;
    };

    api.undoBeginBlock();
    const success = api.removeSend(resolution.track, 0, send_idx);
    api.undoEndBlock("REAmo: Remove send");

    if (!success) {
        response.err("REMOVE_FAILED", "Failed to remove send");
        return;
    }

    logging.debug("Send removed: track {} send {}", .{ resolution.idx, send_idx });
    response.success(null);
}

// ============================================================================
// Tests
// ============================================================================

test "send handlers compile" {
    // Command handlers require ResponseWriter with SharedState.
    // Integration tests via websocat verify full behavior.
}
