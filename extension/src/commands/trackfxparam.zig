/// Track FX Parameter command handlers.
///
/// Commands:
/// - trackFxParams/set: Set a single FX parameter value (normalized)
///
/// Uses gesture-based undo coalescing for continuous control.
const std = @import("std");
const protocol = @import("../core/protocol.zig");
const mod = @import("mod.zig");
const gesture_state = @import("../server/gesture_state.zig");
const logging = @import("../core/logging.zig");
const tracks = @import("tracks.zig");
const fx = @import("fx.zig");

/// Set an FX parameter value (normalized 0.0-1.0).
///
/// Command format:
/// { "command": "trackFxParams/set", "trackGuid": "{AAA}", "fxGuid": "{BBB}",
///   "paramIdx": 0, "value": 0.5, "id": "1" }
///
/// Response:
/// { "type": "response", "id": "1", "success": true }
///
/// Notes:
/// - Uses gesture-based undo coalescing. Caller should send gesture/start before
///   and gesture/end after a drag operation.
/// - Value is normalized (0.0-1.0), not formatted.
pub fn handleSetParam(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    // Resolve track
    const resolution = tracks.resolveTrack(api, cmd) orelse {
        response.err("NOT_FOUND", "trackGuid required, or track not found");
        return;
    };

    // Validate track pointer
    if (resolution.idx != 0 and !api.validateTrackPtr(resolution.track)) {
        response.err("INVALID_TRACK", "Track no longer exists");
        return;
    }

    // Get FX GUID and resolve to index
    const fx_guid = cmd.getString("fxGuid") orelse {
        response.err("MISSING_PARAM", "fxGuid is required");
        return;
    };

    const fx_idx = fx.findFxByGuid(api, resolution.track, fx_guid) orelse {
        response.err("FX_NOT_FOUND", "FX with specified GUID not found");
        return;
    };

    // Get parameter index and value
    const param_idx = cmd.getInt("paramIdx") orelse {
        response.err("MISSING_PARAM", "paramIdx is required");
        return;
    };

    const value = cmd.getFloat("value") orelse {
        response.err("MISSING_PARAM", "value is required (normalized 0.0-1.0)");
        return;
    };

    // Clamp value to valid range
    const clamped_value = @max(0.0, @min(1.0, value));

    // Set the parameter (no undo block - uses gesture-based coalescing)
    const success = api.trackFxSetParamNormalized(resolution.track, fx_idx, param_idx, clamped_value);
    if (!success) {
        response.err("SET_FAILED", "Failed to set FX parameter");
        return;
    }

    // Record activity for gesture timeout tracking
    if (response.gestures) |gestures| {
        gestures.recordActivity(gesture_state.ControlId.fxParam(resolution.idx, fx_guid, param_idx));
    }

    logging.debug("FX param set: track {} fx {} param {} value {d:.4}", .{ resolution.idx, fx_idx, param_idx, clamped_value });
    response.success(null);
}

// Tests
test "handleSetParam compiles" {
    // Just verify the module compiles - full tests need mock ResponseWriter
}
