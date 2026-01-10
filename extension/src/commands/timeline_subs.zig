/// Timeline subscription command handlers for items polling.
///
/// Commands:
/// - timeline/subscribe: Subscribe to items updates for a time range
/// - timeline/unsubscribe: Clear items subscription for this client
///
/// Note: Markers and regions are broadcast to all clients (no subscription required).
/// This subscription is only for items, which are filtered per-client by time range.
const std = @import("std");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");
const timeline_subscriptions = @import("../timeline_subscriptions.zig");

/// Subscribe to items updates for a time range.
///
/// Command format:
/// { "command": "timeline/subscribe", "timeRange": {"start": 0.0, "end": 30.0}, "id": "1" }
///
/// Response:
/// { "type": "response", "id": "1", "success": true,
///   "payload": {"subscribedRange": {"start": 0.0, "end": 30.0}} }
///
/// Behavior:
/// - Frontend specifies exact range (including any buffer it needs)
/// - Items within range sent immediately, then on change at 5Hz (MEDIUM tier)
/// - Markers and regions are broadcast to all clients (no subscription needed)
pub fn handleSubscribe(_: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const subs = mod.g_ctx.timeline_subs orelse {
        response.err("NOT_INITIALIZED", "Timeline subscriptions not initialized");
        return;
    };

    // Parse timeRange object
    const start = protocol.jsonGetFloatFromObject(cmd.raw, "timeRange", "start") orelse {
        response.err("INVALID_PARAMS", "timeRange.start is required");
        return;
    };
    const end = protocol.jsonGetFloatFromObject(cmd.raw, "timeRange", "end") orelse {
        response.err("INVALID_PARAMS", "timeRange.end is required");
        return;
    };

    // Validate range
    if (start < 0 or end <= start or !std.math.isFinite(start) or !std.math.isFinite(end)) {
        response.err("INVALID_RANGE", "Invalid time range: start must be >= 0 and < end");
        return;
    }

    const range = timeline_subscriptions.TimeRange{ .start = start, .end = end };

    subs.subscribe(response.client_id, range) catch |err| {
        switch (err) {
            error.TooManyClients => response.err("TOO_MANY_CLIENTS", "Maximum client limit reached"),
        }
        return;
    };

    // Format response
    var payload_buf: [128]u8 = undefined;
    const payload = std.fmt.bufPrint(&payload_buf, "{{\"subscribedRange\":{{\"start\":{d:.3},\"end\":{d:.3}}}}}", .{ start, end }) catch {
        response.err("JSON_ERROR", "Failed to format response");
        return;
    };
    response.success(payload);
}

/// Unsubscribe from items updates.
///
/// Command format:
/// { "command": "timeline/unsubscribe", "id": "1" }
///
/// Response:
/// { "type": "response", "id": "1", "success": true }
///
/// Note: This only affects items. Markers and regions continue to broadcast.
pub fn handleUnsubscribe(_: anytype, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const subs = mod.g_ctx.timeline_subs orelse {
        response.err("NOT_INITIALIZED", "Timeline subscriptions not initialized");
        return;
    };

    subs.unsubscribe(response.client_id);
    response.success(null);
}

// Tests
test "handleSubscribe and handleUnsubscribe compile" {
    // Verify module compiles - full integration testing requires mock infrastructure
}
