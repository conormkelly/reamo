const std = @import("std");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");
const gesture_state = @import("../gesture_state.zig");
const logging = @import("../logging.zig");

/// Set HW output volume for the specified hardware output
/// Params: trackIdx (unified: 0=master, 1+=user tracks), hwIdx (0-based), volume (linear, 1.0 = 0dB)
pub fn handleSetVolume(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track_idx = cmd.getInt("trackIdx") orelse {
        response.err("MISSING_TRACK_IDX", "trackIdx is required");
        return;
    };
    const hw_idx = cmd.getInt("hwIdx") orelse {
        response.err("MISSING_HW_IDX", "hwIdx is required");
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

    // No undo block here - continuous control uses gesture-based undo coalescing
    // (undoBeginBlock on gesture/start, undoEndBlock on gesture/end)
    const success = api.trackHwOutputSetVolume(track, hw_idx, volume);
    if (!success) {
        response.err("SET_FAILED", "Failed to set HW output volume");
        return;
    }

    // Record activity for gesture timeout tracking
    if (response.gestures) |gestures| {
        gestures.recordActivity(gesture_state.ControlId.hwOutputVolume(track_idx, hw_idx));
    }

    logging.debug("HW output volume set: track {} hw {} volume {d:.3}", .{ track_idx, hw_idx, volume });
    response.success(null);
}

/// Set HW output mute state for the specified hardware output
/// Params: trackIdx, hwIdx, muted (boolean)
pub fn handleSetMute(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track_idx = cmd.getInt("trackIdx") orelse {
        response.err("MISSING_TRACK_IDX", "trackIdx is required");
        return;
    };
    const hw_idx = cmd.getInt("hwIdx") orelse {
        response.err("MISSING_HW_IDX", "hwIdx is required");
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

    api.undoBeginBlock();
    const success = api.trackHwOutputSetMute(track, hw_idx, muted);
    api.undoEndBlock("REAmo: Adjust audio hardware output mute");

    if (!success) {
        response.err("SET_FAILED", "Failed to set HW output mute state");
        return;
    }

    logging.debug("HW output mute set: track {} hw {} muted {}", .{ track_idx, hw_idx, muted });
    response.success(null);
}

/// Set HW output pan for the specified hardware output
/// Params: trackIdx, hwIdx, pan (-1.0 to 1.0)
pub fn handleSetPan(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track_idx = cmd.getInt("trackIdx") orelse {
        response.err("MISSING_TRACK_IDX", "trackIdx is required");
        return;
    };
    const hw_idx = cmd.getInt("hwIdx") orelse {
        response.err("MISSING_HW_IDX", "hwIdx is required");
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

    // No undo block here - continuous control uses gesture-based undo coalescing
    // (undoBeginBlock on gesture/start, undoEndBlock on gesture/end)
    const success = api.trackHwOutputSetPan(track, hw_idx, clamped);
    if (!success) {
        response.err("SET_FAILED", "Failed to set HW output pan");
        return;
    }

    // Record activity for gesture timeout tracking
    if (response.gestures) |gestures| {
        gestures.recordActivity(gesture_state.ControlId.hwOutputPan(track_idx, hw_idx));
    }

    logging.debug("HW output pan set: track {} hw {} pan {d:.3}", .{ track_idx, hw_idx, clamped });
    response.success(null);
}

/// Set HW output mode for the specified hardware output
/// Params: trackIdx, hwIdx, mode (0=post-fader, 1=pre-FX, 3=post-FX)
pub fn handleSetMode(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track_idx = cmd.getInt("trackIdx") orelse {
        response.err("MISSING_TRACK_IDX", "trackIdx is required");
        return;
    };
    const hw_idx = cmd.getInt("hwIdx") orelse {
        response.err("MISSING_HW_IDX", "hwIdx is required");
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

    api.undoBeginBlock();
    const success = api.trackHwOutputSetMode(track, hw_idx, mode);
    api.undoEndBlock("REAmo: Adjust audio hardware output mode");

    if (!success) {
        response.err("SET_FAILED", "Failed to set HW output mode");
        return;
    }

    logging.debug("HW output mode set: track {} hw {} mode {}", .{ track_idx, hw_idx, mode });
    response.success(null);
}
