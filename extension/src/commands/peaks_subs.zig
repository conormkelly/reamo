/// Peaks subscription command handlers.
///
/// Commands:
/// - peaks/subscribe: Subscribe to peaks for a track (by GUID)
/// - peaks/unsubscribe: Clear peaks subscription for this client
const std = @import("std");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");
const peaks_subscriptions = @import("../peaks_subscriptions.zig");

/// Subscribe to peaks for a track.
///
/// Command format:
/// { "command": "peaks/subscribe", "trackGuid": "{XXXXXXXX-...}", "sampleCount": 30, "id": "1" }
///
/// Parameters:
/// - trackGuid (required): GUID of the track to subscribe to
/// - sampleCount (optional, default 30): Number of peak samples per item
///
/// Response:
/// { "type": "response", "id": "1", "success": true }
///
/// After subscribing, the client receives "peaks" events whenever items on the track change.
pub fn handleSubscribe(_: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const subs = mod.g_ctx.peaks_subs orelse {
        response.err("NOT_INITIALIZED", "Peaks subscriptions not initialized");
        return;
    };

    // Parse trackGuid (required)
    const track_guid = cmd.getString("trackGuid") orelse {
        response.err("MISSING_TRACK_GUID", "trackGuid parameter is required");
        return;
    };

    if (track_guid.len == 0) {
        response.err("INVALID_TRACK_GUID", "trackGuid cannot be empty");
        return;
    }

    // Parse sampleCount (optional, default 30)
    const sample_count: u32 = if (cmd.getInt("sampleCount")) |sc|
        if (sc > 0 and sc <= 200) @intCast(sc) else 30
    else
        30;

    subs.subscribe(response.client_id, track_guid, sample_count) catch |err| {
        switch (err) {
            error.TooManyClients => response.err("TOO_MANY_CLIENTS", "Maximum client limit reached"),
        }
        return;
    };

    response.success(null);
}

/// Unsubscribe from peaks updates.
///
/// Command format:
/// { "command": "peaks/unsubscribe", "id": "1" }
///
/// Response:
/// { "type": "response", "id": "1", "success": true }
pub fn handleUnsubscribe(_: anytype, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const subs = mod.g_ctx.peaks_subs orelse {
        response.err("NOT_INITIALIZED", "Peaks subscriptions not initialized");
        return;
    };

    subs.unsubscribe(response.client_id);
    response.success(null);
}

// Tests
test "handleSubscribe and handleUnsubscribe compile" {
    // Just verify the module compiles - full tests need mock ResponseWriter
}
