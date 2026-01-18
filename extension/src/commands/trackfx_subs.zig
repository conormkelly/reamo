/// Track FX subscription command handlers.
///
/// Commands:
/// - trackFx/subscribe: Subscribe to a single track's FX chain by GUID
/// - trackFx/unsubscribe: Clear FX chain subscription for this client
///
/// Similar to routing subscriptions - single track per client.
const std = @import("std");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");

/// Subscribe to FX chain updates for a track.
///
/// Command format:
/// { "command": "trackFx/subscribe", "trackGuid": "{AAA-BBB-CCC}", "id": "1" }
///
/// Response:
/// { "type": "response", "id": "1", "success": true }
///
/// After subscribing, the client receives "trackFxChain" events
/// containing all FX on the subscribed track.
pub fn handleSubscribe(_: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const subs = mod.g_ctx.trackfx_subs orelse {
        response.err("NOT_INITIALIZED", "Track FX subscriptions not initialized");
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

/// Unsubscribe from FX chain updates.
///
/// Command format:
/// { "command": "trackFx/unsubscribe", "id": "1" }
///
/// Response:
/// { "type": "response", "id": "1", "success": true }
pub fn handleUnsubscribe(_: anytype, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const subs = mod.g_ctx.trackfx_subs orelse {
        response.err("NOT_INITIALIZED", "Track FX subscriptions not initialized");
        return;
    };

    subs.unsubscribe(response.client_id);
    response.success(null);
}

// Tests
test "handleSubscribe and handleUnsubscribe compile" {
    // Just verify the module compiles - full tests need mock ResponseWriter
}
