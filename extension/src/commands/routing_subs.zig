/// Routing subscription command handlers.
///
/// Commands:
/// - routing/subscribe: Subscribe to a single track's routing by GUID
/// - routing/unsubscribe: Clear routing subscription for this client
///
/// Unlike peaks/meters which may track multiple tracks, routing is always
/// single-track per client (you can only have one routing modal open).
const std = @import("std");
const protocol = @import("../core/protocol.zig");
const mod = @import("mod.zig");

/// Subscribe to routing updates for a track.
///
/// Command format:
/// { "command": "routing/subscribe", "trackGuid": "{AAA-BBB-CCC}", "id": "1" }
///
/// Response:
/// { "type": "response", "id": "1", "success": true }
///
/// After subscribing, the client receives "routing_state" events at 30Hz
/// containing sends, receives, and hw outputs for the subscribed track.
pub fn handleSubscribe(_: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const subs = mod.g_ctx.routing_subs orelse {
        response.err("NOT_INITIALIZED", "Routing subscriptions not initialized");
        return;
    };

    // Get trackGuid parameter
    const track_guid = cmd.getString("trackGuid") orelse {
        response.err("MISSING_PARAM", "trackGuid is required");
        return;
    };

    subs.subscribe(response.client_id, track_guid) catch |err| {
        switch (err) {
            error.TooManyClients => response.err("TOO_MANY_CLIENTS", "Maximum client limit reached"),
        }
        return;
    };

    response.success(null);
}

/// Unsubscribe from routing updates.
///
/// Command format:
/// { "command": "routing/unsubscribe", "id": "1" }
///
/// Response:
/// { "type": "response", "id": "1", "success": true }
pub fn handleUnsubscribe(_: anytype, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const subs = mod.g_ctx.routing_subs orelse {
        response.err("NOT_INITIALIZED", "Routing subscriptions not initialized");
        return;
    };

    subs.unsubscribe(response.client_id);
    response.success(null);
}

// Tests
test "handleSubscribe and handleUnsubscribe compile" {
    // Just verify the module compiles - full tests need mock ResponseWriter
}
