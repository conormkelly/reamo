const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");
const toggle_subscriptions = @import("../toggle_subscriptions.zig");

/// Subscribe to toggle states for a list of commandIds and/or named commands.
/// Accepts:
///   - commandIds (array of int): Numeric command IDs for native REAPER actions
///   - names (array of string): Named command identifiers for SWS/scripts (e.g., "_SWS_SAVESEL")
/// At least one of commandIds or names must be provided.
/// Returns current state for all subscribed actions, keyed by the identifier used to subscribe.
pub fn handleSubscribe(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const subs = mod.g_ctx.toggle_subs orelse {
        response.err("NOT_INITIALIZED", "Toggle subscriptions not initialized");
        return;
    };

    // Parse commandIds array from JSON (optional)
    const command_ids = parseCommandIds(cmd);
    defer if (command_ids) |ids| ids.deinit();

    // Parse names array from JSON (optional)
    const names = parseNames(cmd);
    defer if (names) |n| n.deinit();

    // Need at least one of commandIds or names
    const has_command_ids = command_ids != null and command_ids.?.len > 0;
    const has_names = names != null and names.?.len > 0;

    if (!has_command_ids and !has_names) {
        response.err("MISSING_PARAMS", "commandIds or names array is required");
        return;
    }

    // Collect all numeric IDs to subscribe to
    var all_ids: [512]u32 = undefined;
    var all_ids_len: usize = 0;

    // Track which IDs came from names (for response formatting)
    var name_to_id: [256]struct { name: []const u8, id: u32 } = undefined;
    var name_to_id_len: usize = 0;

    // Add numeric commandIds
    if (command_ids) |ids| {
        for (ids.slice()) |id| {
            if (all_ids_len < all_ids.len) {
                all_ids[all_ids_len] = id;
                all_ids_len += 1;
            }
        }
    }

    // Resolve names to numeric IDs and add them
    if (names) |n| {
        for (n.slice()) |name| {
            const resolved = api.namedCommandLookup(name);
            if (resolved == 0) continue; // Skip unknown names

            const id: u32 = @intCast(resolved);
            if (all_ids_len < all_ids.len) {
                all_ids[all_ids_len] = id;
                all_ids_len += 1;
            }
            if (name_to_id_len < name_to_id.len) {
                name_to_id[name_to_id_len] = .{ .name = name, .id = id };
                name_to_id_len += 1;
            }
        }
    }

    if (all_ids_len == 0) {
        response.err("NO_VALID_IDS", "No valid commandIds or names provided");
        return;
    }

    // Subscribe and get current states
    var states = subs.subscribe(api, response.client_id, all_ids[0..all_ids_len]) catch |err| {
        switch (err) {
            error.TooManyClients => response.err("TOO_MANY_CLIENTS", "Maximum client limit reached"),
            error.TooManySubscriptions => response.err("TOO_MANY_SUBSCRIPTIONS", "Maximum 256 commandIds per client"),
            else => response.err("SUBSCRIBE_FAILED", "Failed to subscribe"),
        }
        return;
    };
    defer states.deinit();

    // Format states as JSON payload, including both numeric IDs and names
    var states_buf: [8192]u8 = undefined;
    var stream = std.io.fixedBufferStream(&states_buf);
    var writer = stream.writer();

    writer.writeAll("{") catch {
        response.err("JSON_ERROR", "Failed to format states");
        return;
    };

    var first = true;

    // Write numeric ID states
    var iter = states.iterator();
    while (iter.next()) |entry| {
        // Check if this ID came from a name - if so, use the name as key
        var found_name: ?[]const u8 = null;
        for (name_to_id[0..name_to_id_len]) |mapping| {
            if (mapping.id == entry.key_ptr.*) {
                found_name = mapping.name;
                break;
            }
        }

        if (!first) writer.writeAll(",") catch return;
        first = false;

        if (found_name) |name| {
            // Use name as key for named commands
            writer.print("\"{s}\":{d}", .{ name, entry.value_ptr.* }) catch return;
        } else {
            // Use numeric ID as key for native actions
            writer.print("\"{d}\":{d}", .{ entry.key_ptr.*, entry.value_ptr.* }) catch return;
        }
    }

    writer.writeAll("}") catch {
        response.err("JSON_ERROR", "Failed to format states");
        return;
    };

    const states_json = stream.getWritten();

    // Build nameToId mapping if names were used (frontend needs this to translate change events)
    var mapping_buf: [4096]u8 = undefined;
    var mapping_json: []const u8 = "{}";

    if (name_to_id_len > 0) {
        var mapping_stream = std.io.fixedBufferStream(&mapping_buf);
        var mapping_writer = mapping_stream.writer();

        mapping_writer.writeAll("{") catch {
            response.err("JSON_ERROR", "Failed to format mapping");
            return;
        };

        var mapping_first = true;
        for (name_to_id[0..name_to_id_len]) |mapping| {
            if (!mapping_first) mapping_writer.writeAll(",") catch return;
            mapping_first = false;
            mapping_writer.print("\"{s}\":{d}", .{ mapping.name, mapping.id }) catch return;
        }

        mapping_writer.writeAll("}") catch return;
        mapping_json = mapping_stream.getWritten();
    }

    // Build full response payload: {"states": {...}, "nameToId": {...}}
    var payload_buf: [16000]u8 = undefined;
    const payload = std.fmt.bufPrint(&payload_buf, "{{\"states\":{s},\"nameToId\":{s}}}", .{ states_json, mapping_json }) catch {
        response.err("JSON_ERROR", "Failed to format response");
        return;
    };

    response.success(payload);
}

/// Unsubscribe from toggle states for a list of commandIds.
pub fn handleUnsubscribe(_: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const subs = mod.g_ctx.toggle_subs orelse {
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

/// Result of parsing names - uses a simple fixed buffer
const ParsedNames = struct {
    // Store slices into the original raw JSON (no copies needed)
    buf: [256][]const u8,
    len: usize,

    /// Get the parsed names as a slice
    pub fn slice(self: *const ParsedNames) []const []const u8 {
        return self.buf[0..self.len];
    }

    pub fn deinit(self: *const ParsedNames) void {
        _ = self;
        // Nothing to free - slices point into original JSON
    }
};

/// Parse names array from command JSON
/// Format: "names":["_SWS_ABOUT","_RS123...",...]
fn parseNames(cmd: protocol.CommandMessage) ?ParsedNames {
    var result = ParsedNames{
        .buf = undefined,
        .len = 0,
    };

    // Find "names" array in the raw JSON
    const key = "\"names\":[";
    const key_idx = std.mem.indexOf(u8, cmd.raw, key) orelse {
        return null;
    };

    const array_start = key_idx + key.len;
    const array_end = std.mem.indexOfPos(u8, cmd.raw, array_start, "]") orelse {
        return null;
    };

    const array_content = cmd.raw[array_start..array_end];

    // Parse comma-separated quoted strings
    var pos: usize = 0;
    while (pos < array_content.len) {
        // Find opening quote
        const quote_start = std.mem.indexOfPos(u8, array_content, pos, "\"") orelse break;
        // Find closing quote
        const quote_end = std.mem.indexOfPos(u8, array_content, quote_start + 1, "\"") orelse break;

        const name = array_content[quote_start + 1 .. quote_end];
        if (name.len > 0 and result.len < result.buf.len) {
            result.buf[result.len] = name;
            result.len += 1;
        }

        pos = quote_end + 1;
    }

    if (result.len == 0) return null;
    return result;
}

// Tests
test "parseCommandIds parses array" {
    // We can't easily test this without mocking protocol.CommandMessage
    // The integration tests via websocat will verify this works
}
