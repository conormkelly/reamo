/// Tuner subscription command handlers.
///
/// Commands:
/// - tuner/subscribe: Subscribe to tuner on a track (inserts JSFX if first subscriber)
/// - tuner/unsubscribe: Unsubscribe from tuner (removes JSFX if last subscriber)
/// - tuner/setParam: Set tuner parameter (reference Hz or threshold dB)
///
/// Single track per client - subscribing auto-unsubscribes from previous track.
const std = @import("std");
const protocol = @import("../core/protocol.zig");
const mod = @import("mod.zig");
const tuner_subscriptions = @import("../subscriptions/tuner_subscriptions.zig");

/// Subscribe to tuner on a track.
///
/// Command format:
/// { "command": "tuner/subscribe", "trackGuid": "{AAA...}", "id": "1" }
///
/// Response:
/// { "type": "response", "id": "1", "success": true, "payload": {
///     "trackGuid": "{AAA...}",
///     "fxGuid": "{BBB...}",
///     "trackName": "Guitar",
///     "reference": 440.0,
///     "threshold": -60.0
/// }}
///
/// After subscribing, the client receives "tuner" events at 30Hz
/// containing pitch detection data.
pub fn handleSubscribe(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const subs = mod.g_ctx.tuner_subs orelse {
        response.err("NOT_INITIALIZED", "Tuner subscriptions not initialized");
        return;
    };

    const guid_cache = mod.g_ctx.guid_cache orelse {
        response.err("NOT_INITIALIZED", "GUID cache not initialized");
        return;
    };

    // Get required parameter
    const track_guid = cmd.getString("trackGuid") orelse {
        response.err("MISSING_PARAM", "trackGuid is required");
        return;
    };

    // Subscribe to tuner
    const result = subs.subscribe(response.client_id, track_guid, guid_cache, api) catch |err| {
        switch (err) {
            error.TooManyClients => response.err("TOO_MANY_CLIENTS", "Maximum client limit reached"),
            error.TrackNotFound => response.err("TRACK_NOT_FOUND", "Track GUID not found in cache"),
            error.FxInsertFailed => response.err("FX_INSERT_FAILED", "Failed to insert tuner JSFX (not installed?)"),
            error.TooManyTuners => response.err("TOO_MANY_TUNERS", "Maximum tuner track limit reached"),
        }
        return;
    };

    // Build success response with subscribe result
    var payload_buf: [512]u8 = undefined;
    const payload = std.fmt.bufPrint(&payload_buf, "{{\"trackGuid\":\"{s}\",\"fxGuid\":\"{s}\",\"trackName\":\"{s}\",\"reference\":{d:.1},\"threshold\":{d:.1}}}", .{
        result.track_guid,
        result.fx_guid,
        result.track_name,
        result.reference_hz,
        result.threshold_db,
    }) catch {
        response.err("INTERNAL_ERROR", "Failed to format response");
        return;
    };

    response.success(payload);
}

/// Unsubscribe from tuner.
///
/// Command format:
/// { "command": "tuner/unsubscribe", "id": "1" }
///
/// Response:
/// { "type": "response", "id": "1", "success": true }
pub fn handleUnsubscribe(api: anytype, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const subs = mod.g_ctx.tuner_subs orelse {
        response.err("NOT_INITIALIZED", "Tuner subscriptions not initialized");
        return;
    };

    subs.unsubscribe(response.client_id, api);
    response.success(null);
}

/// Set tuner parameter.
///
/// Command format:
/// { "command": "tuner/setParam", "trackGuid": "{AAA...}", "param": "reference", "value": 442.0, "id": "1" }
///
/// Parameters:
/// - param: "reference" (A4 Hz, 400-480) or "threshold" (silence dB, -96 to 0)
/// - value: float value for the parameter
///
/// Response:
/// { "type": "response", "id": "1", "success": true }
pub fn handleSetParam(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const subs = mod.g_ctx.tuner_subs orelse {
        response.err("NOT_INITIALIZED", "Tuner subscriptions not initialized");
        return;
    };

    const guid_cache = mod.g_ctx.guid_cache orelse {
        response.err("NOT_INITIALIZED", "GUID cache not initialized");
        return;
    };

    // Get required parameters
    const track_guid = cmd.getString("trackGuid") orelse {
        response.err("MISSING_PARAM", "trackGuid is required");
        return;
    };

    const param_name = cmd.getString("param") orelse {
        response.err("MISSING_PARAM", "param is required");
        return;
    };

    const value = cmd.getFloat("value") orelse {
        response.err("MISSING_PARAM", "value is required");
        return;
    };

    // Map param name to enum
    const param: tuner_subscriptions.TunerParam = if (std.mem.eql(u8, param_name, "reference"))
        .reference
    else if (std.mem.eql(u8, param_name, "threshold"))
        .threshold
    else {
        response.err("INVALID_PARAM", "param must be 'reference' or 'threshold'");
        return;
    };

    // Set the parameter
    subs.setParam(track_guid, param, @floatCast(value), guid_cache, api) catch |err| {
        switch (err) {
            error.NotSubscribed => response.err("NOT_SUBSCRIBED", "No active tuner for this track"),
            error.TrackNotFound => response.err("TRACK_NOT_FOUND", "Track GUID not found"),
            error.FxNotFound => response.err("FX_NOT_FOUND", "Tuner plugin not found in FX chain"),
            error.InvalidParam => response.err("INVALID_PARAM", "Invalid parameter"),
        }
        return;
    };

    response.success(null);
}

// =============================================================================
// Tests
// =============================================================================

test "handleSubscribe, handleUnsubscribe, handleSetParam compile" {
    // Just verify the module compiles - full tests need mock ResponseWriter
}
