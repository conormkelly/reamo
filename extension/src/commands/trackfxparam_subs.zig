/// Track FX Parameter subscription command handlers.
///
/// Commands:
/// - trackFxParams/subscribe: Subscribe to an FX's parameter values (range or indices mode)
/// - trackFxParams/unsubscribe: Clear parameter subscription for this client
///
/// Single FX per client - subscribing auto-unsubscribes from previous FX.
const std = @import("std");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");

/// Subscribe to FX parameter value updates.
///
/// Command formats:
///
/// Range mode (for scrollable views):
/// { "command": "trackFxParams/subscribe", "trackGuid": "{AAA}", "fxGuid": "{BBB}",
///   "rangeStart": 0, "rangeEnd": 20, "id": "1" }
///
/// Indices mode (for filtered/pinned params):
/// { "command": "trackFxParams/subscribe", "trackGuid": "{AAA}", "fxGuid": "{BBB}",
///   "indices": [0, 5, 10, 15], "id": "1" }
///
/// Response:
/// { "type": "response", "id": "1", "success": true }
///
/// After subscribing, the client receives "trackFxParams" events at 30Hz
/// containing parameter values for the subscribed range/indices.
pub fn handleSubscribe(_: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const subs = mod.g_ctx.trackfxparam_subs orelse {
        response.err("NOT_INITIALIZED", "Track FX parameter subscriptions not initialized");
        return;
    };

    // Get required parameters
    const track_guid = cmd.getString("trackGuid") orelse {
        response.err("MISSING_PARAM", "trackGuid is required");
        return;
    };

    const fx_guid = cmd.getString("fxGuid") orelse {
        response.err("MISSING_PARAM", "fxGuid is required");
        return;
    };

    // Determine mode: indices array takes precedence, else use range
    var indices_buf: [100]c_int = undefined;
    if (cmd.getIntArray("indices", 100, &indices_buf)) |indices| {
        // Indices mode
        subs.subscribeIndices(response.client_id, track_guid, fx_guid, indices) catch |err| {
            switch (err) {
                error.TooManyClients => response.err("TOO_MANY_CLIENTS", "Maximum client limit reached"),
                error.TooManyParams => response.err("TOO_MANY_PARAMS", "Maximum 100 param indices allowed"),
            }
            return;
        };
    } else {
        // Range mode (default to 0-20 if not specified)
        const range_start: c_int = if (cmd.getInt("rangeStart")) |v| @intCast(v) else 0;
        const range_end: c_int = if (cmd.getInt("rangeEnd")) |v| @intCast(v) else 20;

        subs.subscribeRange(response.client_id, track_guid, fx_guid, range_start, range_end) catch |err| {
            switch (err) {
                error.TooManyClients => response.err("TOO_MANY_CLIENTS", "Maximum client limit reached"),
                error.InvalidRange => response.err("INVALID_RANGE", "rangeStart must be <= rangeEnd"),
            }
            return;
        };
    }

    response.success(null);
}

/// Unsubscribe from FX parameter updates.
///
/// Command format:
/// { "command": "trackFxParams/unsubscribe", "id": "1" }
///
/// Response:
/// { "type": "response", "id": "1", "success": true }
pub fn handleUnsubscribe(_: anytype, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const subs = mod.g_ctx.trackfxparam_subs orelse {
        response.err("NOT_INITIALIZED", "Track FX parameter subscriptions not initialized");
        return;
    };

    subs.unsubscribe(response.client_id);
    response.success(null);
}

// Tests
test "handleSubscribe and handleUnsubscribe compile" {
    // Just verify the module compiles - full tests need mock ResponseWriter
}
