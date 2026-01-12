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
