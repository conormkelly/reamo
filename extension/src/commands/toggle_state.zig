const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");
const toggle_subscriptions = @import("../toggle_subscriptions.zig");

// Toggle state command handlers
pub const handlers = [_]mod.Entry{
    .{ .name = "actionToggleState/subscribe", .handler = handleSubscribe },
    .{ .name = "actionToggleState/unsubscribe", .handler = handleUnsubscribe },
};

// Global toggle subscriptions state (initialized by main.zig)
pub var g_toggle_subs: ?*toggle_subscriptions.ToggleSubscriptions = null;

/// Subscribe to toggle states for a list of commandIds.
/// Returns current state for all subscribed commandIds.
fn handleSubscribe(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const subs = g_toggle_subs orelse {
        response.err("NOT_INITIALIZED", "Toggle subscriptions not initialized");
        return;
    };

    // Parse commandIds array from JSON
    const command_ids = parseCommandIds(cmd) orelse {
        response.err("MISSING_COMMAND_IDS", "commandIds array is required");
        return;
    };
    defer command_ids.deinit();

    if (command_ids.len == 0) {
        response.err("EMPTY_COMMAND_IDS", "commandIds array cannot be empty");
        return;
    }

    // Subscribe and get current states
    var states = subs.subscribe(api, response.client_id, command_ids.slice()) catch |err| {
        switch (err) {
            error.TooManyClients => response.err("TOO_MANY_CLIENTS", "Maximum client limit reached"),
            error.TooManySubscriptions => response.err("TOO_MANY_SUBSCRIPTIONS", "Maximum 256 commandIds per client"),
            else => response.err("SUBSCRIBE_FAILED", "Failed to subscribe"),
        }
        return;
    };
    defer states.deinit();

    // Format states as JSON payload
    var states_buf: [4096]u8 = undefined;
    const states_json = toggle_subscriptions.ToggleSubscriptions.statesToJson(&states, &states_buf) orelse {
        response.err("JSON_ERROR", "Failed to format states");
        return;
    };

    // Build full response payload: {"states": {...}}
    var payload_buf: [4200]u8 = undefined;
    const payload = std.fmt.bufPrint(&payload_buf, "{{\"states\":{s}}}", .{states_json}) catch {
        response.err("JSON_ERROR", "Failed to format response");
        return;
    };

    response.success(payload);
}

/// Unsubscribe from toggle states for a list of commandIds.
fn handleUnsubscribe(_: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const subs = g_toggle_subs orelse {
        response.err("NOT_INITIALIZED", "Toggle subscriptions not initialized");
        return;
    };

    // Parse commandIds array from JSON
    const command_ids = parseCommandIds(cmd) orelse {
        response.err("MISSING_COMMAND_IDS", "commandIds array is required");
        return;
    };
    defer command_ids.deinit();

    if (command_ids.len == 0) {
        response.err("EMPTY_COMMAND_IDS", "commandIds array cannot be empty");
        return;
    }

    // Unsubscribe
    subs.unsubscribe(response.client_id, command_ids.slice());

    response.success(null);
}

/// Result of parsing commandIds - uses a simple fixed buffer
const ParsedCommandIds = struct {
    buf: [256]u32,
    len: usize,

    /// Get the parsed command IDs as a slice
    pub fn slice(self: *const ParsedCommandIds) []const u32 {
        return self.buf[0..self.len];
    }

    pub fn deinit(self: *const ParsedCommandIds) void {
        _ = self;
        // Nothing to free - uses stack buffer
    }
};

/// Parse commandIds array from command JSON
fn parseCommandIds(cmd: protocol.CommandMessage) ?ParsedCommandIds {
    var result = ParsedCommandIds{
        .buf = undefined,
        .len = 0,
    };

    // Find "commandIds" array in the raw JSON
    // Format: "commandIds":[1234,5678,...]
    const key = "\"commandIds\":[";
    const key_idx = std.mem.indexOf(u8, cmd.raw, key) orelse {
        return null;
    };

    const array_start = key_idx + key.len;
    const array_end = std.mem.indexOfPos(u8, cmd.raw, array_start, "]") orelse {
        return null;
    };

    const array_content = cmd.raw[array_start..array_end];

    // Parse comma-separated integers
    var iter = std.mem.splitScalar(u8, array_content, ',');
    while (iter.next()) |num_str| {
        const trimmed = std.mem.trim(u8, num_str, " \t\r\n");
        if (trimmed.len == 0) continue;

        const num = std.fmt.parseInt(u32, trimmed, 10) catch continue;
        if (result.len >= result.buf.len) break; // Buffer full
        result.buf[result.len] = num;
        result.len += 1;
    }

    return result;
}

// Tests
test "parseCommandIds parses array" {
    // We can't easily test this without mocking protocol.CommandMessage
    // The integration tests via websocat will verify this works
}
