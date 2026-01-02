const std = @import("std");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");
const gesture_state = @import("../gesture_state.zig");
const logging = @import("../logging.zig");

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
}
