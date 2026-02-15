const std = @import("std");
const protocol = @import("../core/protocol.zig");
const mod = @import("mod.zig");
const tracks = @import("tracks.zig");
const gesture_state = @import("../server/gesture_state.zig");
const logging = @import("../core/logging.zig");

/// Set receive volume for the specified receive
/// Params: trackIdx (unified: 0=master, 1+=user tracks), recvIdx (0-based), volume (linear, 1.0 = 0dB)
pub fn handleSetVolume(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track_idx = cmd.getInt("trackIdx") orelse {
        response.err("MISSING_TRACK_IDX", "trackIdx is required");
        return;
    };
    const recv_idx = cmd.getInt("recvIdx") orelse {
        response.err("MISSING_RECV_IDX", "recvIdx is required");
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

    // Uses CSurf via source track's send for proper undo coalescing
    _ = api.trackReceiveSetVolume(track, recv_idx, volume);

    // Record activity for gesture timeout tracking
    if (response.gestures) |gestures| {
        gestures.recordActivity(gesture_state.ControlId.receiveVolume(track_idx, recv_idx));
    }

    logging.debug("Receive volume set: track {} recv {} volume {d:.3}", .{ track_idx, recv_idx, volume });
    response.success(null);
}

/// Set receive mute state for the specified receive
/// Params: trackIdx, recvIdx, muted (boolean)
pub fn handleSetMute(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track_idx = cmd.getInt("trackIdx") orelse {
        response.err("MISSING_TRACK_IDX", "trackIdx is required");
        return;
    };
    const recv_idx = cmd.getInt("recvIdx") orelse {
        response.err("MISSING_RECV_IDX", "recvIdx is required");
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

    const success = api.trackReceiveSetMute(track, recv_idx, muted);
    if (!success) {
        response.err("SET_FAILED", "Failed to set receive mute state");
        return;
    }

    logging.debug("Receive mute set: track {} recv {} muted {}", .{ track_idx, recv_idx, muted });
    response.success(null);
}

/// Set receive pan for the specified receive
/// Params: trackIdx, recvIdx, pan (-1.0 to 1.0)
pub fn handleSetPan(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track_idx = cmd.getInt("trackIdx") orelse {
        response.err("MISSING_TRACK_IDX", "trackIdx is required");
        return;
    };
    const recv_idx = cmd.getInt("recvIdx") orelse {
        response.err("MISSING_RECV_IDX", "recvIdx is required");
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

    // Uses CSurf via source track's send for proper undo coalescing
    _ = api.trackReceiveSetPan(track, recv_idx, clamped);

    // Record activity for gesture timeout tracking
    if (response.gestures) |gestures| {
        gestures.recordActivity(gesture_state.ControlId.receivePan(track_idx, recv_idx));
    }

    logging.debug("Receive pan set: track {} recv {} pan {d:.3}", .{ track_idx, recv_idx, clamped });
    response.success(null);
}

/// Set receive mode for the specified receive
/// Params: trackIdx, recvIdx, mode (0=post-fader, 1=pre-FX, 3=post-FX)
pub fn handleSetMode(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track_idx = cmd.getInt("trackIdx") orelse {
        response.err("MISSING_TRACK_IDX", "trackIdx is required");
        return;
    };
    const recv_idx = cmd.getInt("recvIdx") orelse {
        response.err("MISSING_RECV_IDX", "recvIdx is required");
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

    const success = api.trackReceiveSetMode(track, recv_idx, mode);
    if (!success) {
        response.err("SET_FAILED", "Failed to set receive mode");
        return;
    }

    logging.debug("Receive mode set: track {} recv {} mode {}", .{ track_idx, recv_idx, mode });
    response.success(null);
}

/// Create a new receive on this track from another track.
/// This creates a send FROM srcTrack TO this track (CreateTrackSend on the source).
/// Params: trackGuid (receiver), srcTrackGuid (sender)
/// Response: { "sendIndex": N } (index of the new send on the source track)
pub fn handleAdd(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const dest_guid = cmd.getString("trackGuid") orelse {
        response.err("MISSING_PARAM", "trackGuid is required");
        return;
    };
    const src_guid = cmd.getString("srcTrackGuid") orelse {
        response.err("MISSING_PARAM", "srcTrackGuid is required");
        return;
    };

    const cache = mod.g_ctx.guid_cache orelse {
        response.err("NOT_INITIALIZED", "GUID cache not initialized");
        return;
    };

    const dest_track = cache.resolve(dest_guid) orelse {
        response.err("NOT_FOUND", "Destination track not found");
        return;
    };
    if (!api.validateTrackPtr(dest_track)) {
        response.err("NOT_FOUND", "Destination track no longer exists");
        return;
    }

    const src_track = cache.resolve(src_guid) orelse {
        response.err("NOT_FOUND", "Source track not found");
        return;
    };
    if (!api.validateTrackPtr(src_track)) {
        response.err("NOT_FOUND", "Source track no longer exists");
        return;
    }

    if (src_track == dest_track) {
        response.err("INVALID_PARAM", "Cannot create receive from self");
        return;
    }

    // CreateTrackSend creates a send FROM src TO dest
    api.undoBeginBlock();
    const send_idx = api.createSend(src_track, dest_track);
    api.undoEndBlock("REAmo: Create receive");

    if (send_idx < 0) {
        response.err("CREATE_FAILED", "Failed to create receive");
        return;
    }

    var resp_buf: [64]u8 = undefined;
    const resp_json = std.fmt.bufPrint(&resp_buf, "{{\"sendIndex\":{d}}}", .{send_idx}) catch {
        logging.warn("receive/add: response buffer overflow", .{});
        response.success(null);
        return;
    };
    logging.debug("Receive created (send idx {d} on source)", .{send_idx});
    response.success(resp_json);
}

/// Remove a receive by index.
/// Params: trackGuid (or trackIdx), recvIdx
pub fn handleRemove(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const resolution = tracks.resolveTrack(api, cmd) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };

    const recv_idx = cmd.getInt("recvIdx") orelse {
        response.err("MISSING_PARAM", "recvIdx is required");
        return;
    };

    // category < 0 = receives
    api.undoBeginBlock();
    const success = api.removeSend(resolution.track, -1, recv_idx);
    api.undoEndBlock("REAmo: Remove receive");

    if (!success) {
        response.err("REMOVE_FAILED", "Failed to remove receive");
        return;
    }

    logging.debug("Receive removed: track {} recv {}", .{ resolution.idx, recv_idx });
    response.success(null);
}
