/// Peaks subscription command handlers.
///
/// Commands:
/// - peaks/subscribe: Subscribe to peaks for tracks (by range or GUID list)
/// - peaks/unsubscribe: Clear peaks subscription for this client
const std = @import("std");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");
const peaks_subscriptions = @import("../peaks_subscriptions.zig");

/// Subscribe to peaks updates. Supports two mutually exclusive modes:
///
/// Range mode - subscribe to unified indices [start, end]:
/// { "command": "peaks/subscribe", "range": {"start": 0, "end": 7}, "sampleCount": 30, "id": "1" }
///
/// GUID mode - subscribe to specific tracks by GUID:
/// { "command": "peaks/subscribe", "guids": ["{AAA...}", "{BBB...}"], "sampleCount": 30, "id": "2" }
///
/// Parameters:
/// - range: Object with start/end unified indices (mutually exclusive with guids)
/// - guids: Array of track GUIDs (mutually exclusive with range)
/// - sampleCount: Number of peak samples per item (optional, default 30)
///
/// Response:
/// { "type": "response", "id": "1", "success": true, "payload": {"subscribedCount": 8} }
///
/// After subscribing, the client receives "peaks" events with data for all items
/// on the subscribed tracks.
pub fn handleSubscribe(_: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const subs = mod.g_ctx.peaks_subs orelse {
        response.err("NOT_INITIALIZED", "Peaks subscriptions not initialized");
        return;
    };

    // Parse sampleCount (optional, default 30)
    const sample_count: u32 = if (cmd.getInt("sampleCount")) |sc|
        if (sc > 0 and sc <= 200) @intCast(sc) else 30
    else
        30;

    // Try range mode first
    const start = protocol.jsonGetIntFromObject(cmd.raw, "range", "start");
    const end = protocol.jsonGetIntFromObject(cmd.raw, "range", "end");

    if (start != null and end != null) {
        // Range mode
        const count = subs.subscribeRange(response.client_id, start.?, end.?, sample_count) catch |err| {
            switch (err) {
                error.TooManyClients => response.err("TOO_MANY_CLIENTS", "Maximum client limit reached"),
            }
            return;
        };

        var payload_buf: [64]u8 = undefined;
        const payload = std.fmt.bufPrint(&payload_buf, "{{\"subscribedCount\":{d}}}", .{count}) catch {
            response.err("JSON_ERROR", "Failed to format response");
            return;
        };
        response.success(payload);
        return;
    }

    // Try GUID mode
    var guid_bufs: [peaks_subscriptions.MAX_GUIDS_PER_CLIENT][peaks_subscriptions.GUID_LEN]u8 = undefined;
    var guid_lens: [peaks_subscriptions.MAX_GUIDS_PER_CLIENT]usize = undefined;

    const guid_count = protocol.jsonGetStringArray(
        cmd.raw,
        "guids",
        peaks_subscriptions.MAX_GUIDS_PER_CLIENT,
        peaks_subscriptions.GUID_LEN,
        &guid_bufs,
        &guid_lens,
    );

    if (guid_count) |count| {
        // Build slice array for subscribeGuids
        var guid_slices: [peaks_subscriptions.MAX_GUIDS_PER_CLIENT][]const u8 = undefined;
        for (0..count) |i| {
            guid_slices[i] = guid_bufs[i][0..guid_lens[i]];
        }

        const subscribed = subs.subscribeGuids(response.client_id, guid_slices[0..count], sample_count) catch |err| {
            switch (err) {
                error.TooManyClients => response.err("TOO_MANY_CLIENTS", "Maximum client limit reached"),
            }
            return;
        };

        var payload_buf: [64]u8 = undefined;
        const payload = std.fmt.bufPrint(&payload_buf, "{{\"subscribedCount\":{d}}}", .{subscribed}) catch {
            response.err("JSON_ERROR", "Failed to format response");
            return;
        };
        response.success(payload);
        return;
    }

    // Neither mode specified
    response.err("INVALID_PARAMS", "Either range or guids parameter is required");
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
