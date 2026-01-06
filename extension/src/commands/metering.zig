const std = @import("std");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");
const meter_subscriptions = @import("../meter_subscriptions.zig");

// Meter subscription command handlers
pub const handlers = [_]mod.Entry{
    .{ .name = "meter/subscribe", .handler = handleSubscribe },
    .{ .name = "meter/unsubscribe", .handler = handleUnsubscribe },
};

// Global meter subscriptions state (initialized by main.zig)
pub var g_meter_subs: ?*meter_subscriptions.MeterSubscriptions = null;

/// Subscribe to meter updates for a list of track indices.
/// This replaces any previous subscription for this client.
///
/// Command format:
/// { "command": "meter/subscribe", "trackIndices": [0, 1, 2, 5, 6] }
///
/// Response:
/// { "type": "response", "id": "...", "success": true, "payload": { "subscribedCount": 5 } }
pub fn handleSubscribe(_: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const subs = g_meter_subs orelse {
        response.err("NOT_INITIALIZED", "Meter subscriptions not initialized");
        return;
    };

    // Parse trackIndices array from JSON
    const track_indices = parseTrackIndices(cmd) orelse {
        response.err("MISSING_TRACK_INDICES", "trackIndices array is required");
        return;
    };

    // Subscribe (empty array is valid - clears subscriptions)
    subs.subscribe(response.client_id, track_indices.slice()) catch |err| {
        switch (err) {
            error.TooManyClients => response.err("TOO_MANY_CLIENTS", "Maximum client limit reached"),
            else => response.err("SUBSCRIBE_FAILED", "Failed to subscribe"),
        }
        return;
    };

    // Format response
    var payload_buf: [64]u8 = undefined;
    const payload = std.fmt.bufPrint(&payload_buf, "{{\"subscribedCount\":{d}}}", .{track_indices.len}) catch {
        response.err("JSON_ERROR", "Failed to format response");
        return;
    };

    response.success(payload);
}

/// Unsubscribe from all meter updates for this client.
///
/// Command format:
/// { "command": "meter/unsubscribe" }
///
/// Response:
/// { "type": "response", "id": "...", "success": true }
pub fn handleUnsubscribe(_: anytype, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const subs = g_meter_subs orelse {
        response.err("NOT_INITIALIZED", "Meter subscriptions not initialized");
        return;
    };

    // Remove all subscriptions for this client
    subs.removeClient(response.client_id);

    response.success(null);
}

/// Result of parsing trackIndices - uses a simple fixed buffer
const ParsedTrackIndices = struct {
    buf: [meter_subscriptions.MAX_TRACKS_PER_CLIENT]c_int,
    len: usize,

    /// Get the parsed track indices as a slice
    pub fn slice(self: *const ParsedTrackIndices) []const c_int {
        return self.buf[0..self.len];
    }
};

/// Parse trackIndices array from command JSON
fn parseTrackIndices(cmd: protocol.CommandMessage) ?ParsedTrackIndices {
    var result = ParsedTrackIndices{
        .buf = undefined,
        .len = 0,
    };

    // Find "trackIndices" array in the raw JSON
    // Format: "trackIndices":[0,1,2,...]
    const key = "\"trackIndices\":[";
    const key_idx = std.mem.indexOf(u8, cmd.raw, key) orelse {
        return null;
    };

    const array_start = key_idx + key.len;
    const array_end = std.mem.indexOfPos(u8, cmd.raw, array_start, "]") orelse {
        return null;
    };

    const array_content = cmd.raw[array_start..array_end];

    // Empty array is valid
    if (std.mem.trim(u8, array_content, " \t\r\n").len == 0) {
        return result;
    }

    // Parse comma-separated integers
    var iter = std.mem.splitScalar(u8, array_content, ',');
    while (iter.next()) |num_str| {
        const trimmed = std.mem.trim(u8, num_str, " \t\r\n");
        if (trimmed.len == 0) continue;

        const num = std.fmt.parseInt(c_int, trimmed, 10) catch continue;
        if (result.len >= result.buf.len) break; // Buffer full
        result.buf[result.len] = num;
        result.len += 1;
    }

    return result;
}

// Tests
test "parseTrackIndices parses array" {
    // Mock CommandMessage with trackIndices
    const raw = "{\"command\":\"meter/subscribe\",\"trackIndices\":[0,1,5,10]}";
    const cmd = protocol.CommandMessage{
        .command = "meter/subscribe",
        .id = null,
        .raw = raw,
    };

    const result = parseTrackIndices(cmd).?;
    try std.testing.expectEqual(@as(usize, 4), result.len);
    try std.testing.expectEqual(@as(c_int, 0), result.buf[0]);
    try std.testing.expectEqual(@as(c_int, 1), result.buf[1]);
    try std.testing.expectEqual(@as(c_int, 5), result.buf[2]);
    try std.testing.expectEqual(@as(c_int, 10), result.buf[3]);
}

test "parseTrackIndices handles empty array" {
    const raw = "{\"command\":\"meter/subscribe\",\"trackIndices\":[]}";
    const cmd = protocol.CommandMessage{
        .command = "meter/subscribe",
        .id = null,
        .raw = raw,
    };

    const result = parseTrackIndices(cmd).?;
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "parseTrackIndices returns null for missing key" {
    const raw = "{\"command\":\"meter/subscribe\"}";
    const cmd = protocol.CommandMessage{
        .command = "meter/subscribe",
        .id = null,
        .raw = raw,
    };

    const result = parseTrackIndices(cmd);
    try std.testing.expect(result == null);
}
