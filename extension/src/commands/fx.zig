const std = @import("std");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");
const logging = @import("../logging.zig");

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
