/// Track subscription command handlers for viewport-driven polling.
///
/// Commands:
/// - track/subscribe: Subscribe to track updates (by range or GUID list)
/// - track/unsubscribe: Clear track subscription for this client
const std = @import("std");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");
const track_subscriptions = @import("../track_subscriptions.zig");

/// Subscribe to track updates. Supports two mutually exclusive modes:
///
/// Range mode - subscribe to unified indices [start, end]:
/// { "command": "track/subscribe", "range": {"start": 0, "end": 31}, "id": "1" }
///
/// Range mode with extra GUIDs (hybrid) - subscribe to range + specific tracks outside range:
/// { "command": "track/subscribe", "range": {"start": 0, "end": 7}, "extraGuids": ["{GUID}"], "id": "1" }
///
/// GUID mode - subscribe to specific tracks by GUID:
/// { "command": "track/subscribe", "guids": ["master", "{AAA...}"], "id": "2" }
///
/// Optional includeMaster (default false) - always include master track:
/// { "command": "track/subscribe", "range": {"start": 5, "end": 10}, "includeMaster": true, "id": "3" }
///
/// Response:
/// { "type": "response", "id": "1", "success": true, "payload": {"subscribedCount": 32} }
pub fn handleSubscribe(_: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const subs = mod.g_ctx.track_subs orelse {
        response.err("NOT_INITIALIZED", "Track subscriptions not initialized");
        return;
    };

    // Parse optional includeMaster flag (defaults to false)
    const include_master = protocol.jsonGetBool(cmd.raw, "includeMaster") orelse false;

    // Try range mode first
    const start = protocol.jsonGetIntFromObject(cmd.raw, "range", "start");
    const end = protocol.jsonGetIntFromObject(cmd.raw, "range", "end");

    if (start != null and end != null) {
        // Range mode - also check for optional extraGuids
        var extra_guid_bufs: [track_subscriptions.MAX_EXTRA_GUIDS][40]u8 = undefined;
        var extra_guid_lens: [track_subscriptions.MAX_EXTRA_GUIDS]usize = undefined;

        const extra_guid_count = protocol.jsonGetStringArray(
            cmd.raw,
            "extraGuids",
            track_subscriptions.MAX_EXTRA_GUIDS,
            40,
            &extra_guid_bufs,
            &extra_guid_lens,
        );

        // Build slice array for extra GUIDs if present
        var extra_guid_slices: [track_subscriptions.MAX_EXTRA_GUIDS][]const u8 = undefined;
        var extra_guids_param: ?[]const []const u8 = null;

        if (extra_guid_count) |egc| {
            for (0..egc) |i| {
                extra_guid_slices[i] = extra_guid_bufs[i][0..extra_guid_lens[i]];
            }
            extra_guids_param = extra_guid_slices[0..egc];
        }

        const count = subs.subscribeRangeWithExtras(response.client_id, start.?, end.?, include_master, extra_guids_param) catch |err| {
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
    var guid_bufs: [track_subscriptions.MAX_GUIDS_PER_CLIENT][40]u8 = undefined;
    var guid_lens: [track_subscriptions.MAX_GUIDS_PER_CLIENT]usize = undefined;

    const guid_count = protocol.jsonGetStringArray(
        cmd.raw,
        "guids",
        track_subscriptions.MAX_GUIDS_PER_CLIENT,
        40,
        &guid_bufs,
        &guid_lens,
    );

    if (guid_count) |count| {
        // Build slice array for subscribeGuids
        var guid_slices: [track_subscriptions.MAX_GUIDS_PER_CLIENT][]const u8 = undefined;
        var total_count = count;

        for (0..count) |i| {
            guid_slices[i] = guid_bufs[i][0..guid_lens[i]];
        }

        // Also check for extraGuids and merge them into the list
        var extra_guid_bufs: [track_subscriptions.MAX_EXTRA_GUIDS][40]u8 = undefined;
        var extra_guid_lens: [track_subscriptions.MAX_EXTRA_GUIDS]usize = undefined;

        const extra_guid_count = protocol.jsonGetStringArray(
            cmd.raw,
            "extraGuids",
            track_subscriptions.MAX_EXTRA_GUIDS,
            40,
            &extra_guid_bufs,
            &extra_guid_lens,
        );

        if (extra_guid_count) |egc| {
            // Append extra GUIDs to the main list (up to MAX_GUIDS_PER_CLIENT)
            for (0..egc) |i| {
                if (total_count >= track_subscriptions.MAX_GUIDS_PER_CLIENT) break;
                // Copy extra GUID to main buffers
                const len = extra_guid_lens[i];
                @memcpy(guid_bufs[total_count][0..len], extra_guid_bufs[i][0..len]);
                guid_lens[total_count] = len;
                guid_slices[total_count] = guid_bufs[total_count][0..len];
                total_count += 1;
            }
        }

        const subscribed = subs.subscribeGuids(response.client_id, guid_slices[0..total_count], include_master) catch |err| {
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

/// Unsubscribe from track updates.
///
/// Command format:
/// { "command": "track/unsubscribe", "id": "1" }
///
/// Response:
/// { "type": "response", "id": "1", "success": true }
pub fn handleUnsubscribe(_: anytype, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const subs = mod.g_ctx.track_subs orelse {
        response.err("NOT_INITIALIZED", "Track subscriptions not initialized");
        return;
    };

    subs.unsubscribe(response.client_id);
    response.success(null);
}

// Tests
test "handleSubscribe range mode" {
    // This would need a mock ResponseWriter to test properly
    // For now, just verify the module compiles
}

test "handleSubscribe guid mode" {
    // This would need a mock ResponseWriter to test properly
}
