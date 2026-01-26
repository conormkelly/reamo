const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../core/protocol.zig");
const mod = @import("mod.zig");
const toggle_subscriptions = @import("../subscriptions/toggle_subscriptions.zig");
const ActionKey = toggle_subscriptions.ActionKey;

/// Subscribe to toggle states for a list of commandIds and/or named commands.
/// Accepts:
///   - actions (array of {c: commandId, s: sectionId}): Section-aware numeric command IDs
///   - namedActions (array of {n: name, s: sectionId}): Section-aware named commands
///   - commandIds (array of int): Legacy format, defaults to sectionId=0
///   - names (array of string): Legacy format, defaults to sectionId=0
/// At least one of the above must be provided.
/// Returns current state as array of {s: sectionId, c: commandId, v: state}.
pub fn handleSubscribe(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const subs = mod.g_ctx.toggle_subs orelse {
        response.err("NOT_INITIALIZED", "Toggle subscriptions not initialized");
        return;
    };

    // Collect all ActionKeys to subscribe to
    var all_keys: [512]ActionKey = undefined;
    var all_keys_len: usize = 0;

    // Track which keys came from names (for nameToId mapping in response)
    var name_to_key: [256]struct { name: []const u8, key: ActionKey } = undefined;
    var name_to_key_len: usize = 0;

    // Parse new format: actions array [{c: commandId, s: sectionId}, ...]
    const actions = parseActions(cmd);
    if (actions) |acts| {
        for (acts.slice()) |act| {
            if (all_keys_len < all_keys.len) {
                all_keys[all_keys_len] = act;
                all_keys_len += 1;
            }
        }
    }

    // Parse new format: namedActions array [{n: name, s: sectionId}, ...]
    const named_actions = parseNamedActions(cmd);
    if (named_actions) |acts| {
        for (acts.slice()) |act| {
            const resolved = api.namedCommandLookup(act.name);
            if (resolved == 0) continue; // Skip unknown names

            const key = ActionKey.init(act.section_id, @intCast(resolved));
            if (all_keys_len < all_keys.len) {
                all_keys[all_keys_len] = key;
                all_keys_len += 1;
            }
            if (name_to_key_len < name_to_key.len) {
                name_to_key[name_to_key_len] = .{ .name = act.name, .key = key };
                name_to_key_len += 1;
            }
        }
    }

    // Parse legacy format: commandIds array (defaults to section 0)
    const command_ids = parseCommandIds(cmd);
    defer if (command_ids) |ids| ids.deinit();
    if (command_ids) |ids| {
        for (ids.slice()) |id| {
            if (all_keys_len < all_keys.len) {
                all_keys[all_keys_len] = ActionKey.init(0, id);
                all_keys_len += 1;
            }
        }
    }

    // Parse legacy format: names array (defaults to section 0)
    const names = parseNames(cmd);
    defer if (names) |n| n.deinit();
    if (names) |n| {
        for (n.slice()) |name| {
            const resolved = api.namedCommandLookup(name);
            if (resolved == 0) continue; // Skip unknown names

            const key = ActionKey.init(0, @intCast(resolved));
            if (all_keys_len < all_keys.len) {
                all_keys[all_keys_len] = key;
                all_keys_len += 1;
            }
            if (name_to_key_len < name_to_key.len) {
                name_to_key[name_to_key_len] = .{ .name = name, .key = key };
                name_to_key_len += 1;
            }
        }
    }

    if (all_keys_len == 0) {
        response.err("MISSING_PARAMS", "actions, namedActions, commandIds, or names array is required");
        return;
    }

    // Subscribe and get current states
    var states = subs.subscribe(api, response.client_id, all_keys[0..all_keys_len]) catch |err| {
        switch (err) {
            error.TooManyClients => response.err("TOO_MANY_CLIENTS", "Maximum client limit reached"),
            error.TooManySubscriptions => response.err("TOO_MANY_SUBSCRIPTIONS", "Maximum 256 actions per client"),
            else => response.err("SUBSCRIBE_FAILED", "Failed to subscribe"),
        }
        return;
    };
    defer states.deinit();

    // Format states as JSON array [{s: sectionId, c: commandId, v: state}, ...]
    var states_buf: [16384]u8 = undefined;
    const states_json = toggle_subscriptions.ToggleSubscriptions.statesToJson(&states, &states_buf) orelse {
        response.err("JSON_ERROR", "Failed to format states");
        return;
    };

    // Build nameToId mapping if names were used (frontend needs this to translate change events)
    var mapping_buf: [8192]u8 = undefined;
    var mapping_json: []const u8 = "[]";

    if (name_to_key_len > 0) {
        var mapping_stream = std.io.fixedBufferStream(&mapping_buf);
        var mapping_writer = mapping_stream.writer();

        mapping_writer.writeAll("[") catch {
            response.err("JSON_ERROR", "Failed to format mapping");
            return;
        };

        var mapping_first = true;
        for (name_to_key[0..name_to_key_len]) |mapping| {
            if (!mapping_first) {
                mapping_writer.writeAll(",") catch {
                    response.err("JSON_ERROR", "Failed to format mapping: buffer overflow");
                    return;
                };
            }
            mapping_first = false;
            mapping_writer.print("{{\"n\":\"{s}\",\"s\":{d},\"c\":{d}}}", .{
                mapping.name,
                mapping.key.section_id,
                mapping.key.command_id,
            }) catch {
                response.err("JSON_ERROR", "Failed to format mapping entry");
                return;
            };
        }

        mapping_writer.writeAll("]") catch {
            response.err("JSON_ERROR", "Failed to close mapping array");
            return;
        };
        mapping_json = mapping_stream.getWritten();
    }

    // Build full response payload: {"states": [...], "nameToId": [...]}
    var payload_buf: [32000]u8 = undefined;
    const payload = std.fmt.bufPrint(&payload_buf, "{{\"states\":{s},\"nameToId\":{s}}}", .{ states_json, mapping_json }) catch {
        response.err("JSON_ERROR", "Failed to format response");
        return;
    };

    response.success(payload);
}

/// Unsubscribe from toggle states for a list of actions.
/// Accepts:
///   - actions (array of {c: commandId, s: sectionId}): Section-aware format
///   - commandIds (array of int): Legacy format, defaults to sectionId=0
pub fn handleUnsubscribe(_: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const subs = mod.g_ctx.toggle_subs orelse {
        response.err("NOT_INITIALIZED", "Toggle subscriptions not initialized");
        return;
    };

    // Collect all ActionKeys to unsubscribe from
    var all_keys: [512]ActionKey = undefined;
    var all_keys_len: usize = 0;

    // Parse new format: actions array [{c: commandId, s: sectionId}, ...]
    const actions = parseActions(cmd);
    if (actions) |acts| {
        for (acts.slice()) |act| {
            if (all_keys_len < all_keys.len) {
                all_keys[all_keys_len] = act;
                all_keys_len += 1;
            }
        }
    }

    // Parse legacy format: commandIds array (defaults to section 0)
    const command_ids = parseCommandIds(cmd);
    defer if (command_ids) |ids| ids.deinit();
    if (command_ids) |ids| {
        for (ids.slice()) |id| {
            if (all_keys_len < all_keys.len) {
                all_keys[all_keys_len] = ActionKey.init(0, id);
                all_keys_len += 1;
            }
        }
    }

    if (all_keys_len == 0) {
        response.err("MISSING_PARAMS", "actions or commandIds array is required");
        return;
    }

    // Unsubscribe
    subs.unsubscribe(response.client_id, all_keys[0..all_keys_len]);

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

/// Result of parsing actions array - section-aware (commandId, sectionId) pairs
const ParsedActions = struct {
    buf: [256]ActionKey,
    len: usize,

    pub fn slice(self: *const ParsedActions) []const ActionKey {
        return self.buf[0..self.len];
    }
};

/// Parse actions array from command JSON
/// Format: "actions":[{"c":40001,"s":0},{"c":12345,"s":32060},...]
fn parseActions(cmd: protocol.CommandMessage) ?ParsedActions {
    var result = ParsedActions{
        .buf = undefined,
        .len = 0,
    };

    // Find "actions" array in the raw JSON
    const key = "\"actions\":[";
    const key_idx = std.mem.indexOf(u8, cmd.raw, key) orelse {
        return null;
    };

    const array_start = key_idx + key.len;
    // Find matching ] - need to handle nested objects
    var depth: usize = 1;
    var array_end: usize = array_start;
    while (array_end < cmd.raw.len and depth > 0) : (array_end += 1) {
        if (cmd.raw[array_end] == '[') depth += 1;
        if (cmd.raw[array_end] == ']') depth -= 1;
    }
    if (depth != 0) return null;
    array_end -= 1; // Back up to the ]

    const array_content = cmd.raw[array_start..array_end];

    // Parse each object {c:...,s:...}
    var pos: usize = 0;
    while (pos < array_content.len) {
        // Find opening brace
        const obj_start = std.mem.indexOfPos(u8, array_content, pos, "{") orelse break;
        // Find closing brace
        const obj_end = std.mem.indexOfPos(u8, array_content, obj_start + 1, "}") orelse break;

        const obj_content = array_content[obj_start + 1 .. obj_end];

        // Parse c (commandId) and s (sectionId) from object
        var command_id: ?u32 = null;
        var section_id: i32 = 0; // Default to main section

        // Find "c": value
        if (std.mem.indexOf(u8, obj_content, "\"c\":")) |c_idx| {
            const val_start = c_idx + 4;
            var val_end = val_start;
            while (val_end < obj_content.len and (obj_content[val_end] >= '0' and obj_content[val_end] <= '9')) : (val_end += 1) {}
            if (val_end > val_start) {
                command_id = std.fmt.parseInt(u32, obj_content[val_start..val_end], 10) catch null;
            }
        }

        // Find "s": value
        if (std.mem.indexOf(u8, obj_content, "\"s\":")) |s_idx| {
            const val_start = s_idx + 4;
            var val_end = val_start;
            // Handle negative numbers
            if (val_end < obj_content.len and obj_content[val_end] == '-') val_end += 1;
            while (val_end < obj_content.len and (obj_content[val_end] >= '0' and obj_content[val_end] <= '9')) : (val_end += 1) {}
            if (val_end > val_start) {
                section_id = std.fmt.parseInt(i32, obj_content[val_start..val_end], 10) catch 0;
            }
        }

        if (command_id) |cid| {
            if (result.len < result.buf.len) {
                result.buf[result.len] = ActionKey.init(section_id, cid);
                result.len += 1;
            }
        }

        pos = obj_end + 1;
    }

    if (result.len == 0) return null;
    return result;
}

/// Named action entry for parsing
const NamedActionEntry = struct {
    name: []const u8,
    section_id: i32,
};

/// Result of parsing namedActions array - section-aware (name, sectionId) pairs
const ParsedNamedActions = struct {
    buf: [256]NamedActionEntry,
    len: usize,

    pub fn slice(self: *const ParsedNamedActions) []const NamedActionEntry {
        return self.buf[0..self.len];
    }
};

/// Parse namedActions array from command JSON
/// Format: "namedActions":[{"n":"_SWS_ABOUT","s":0},...]
fn parseNamedActions(cmd: protocol.CommandMessage) ?ParsedNamedActions {
    var result = ParsedNamedActions{
        .buf = undefined,
        .len = 0,
    };

    // Find "namedActions" array in the raw JSON
    const key = "\"namedActions\":[";
    const key_idx = std.mem.indexOf(u8, cmd.raw, key) orelse {
        return null;
    };

    const array_start = key_idx + key.len;
    // Find matching ]
    var depth: usize = 1;
    var array_end: usize = array_start;
    while (array_end < cmd.raw.len and depth > 0) : (array_end += 1) {
        if (cmd.raw[array_end] == '[') depth += 1;
        if (cmd.raw[array_end] == ']') depth -= 1;
    }
    if (depth != 0) return null;
    array_end -= 1;

    const array_content = cmd.raw[array_start..array_end];

    // Parse each object {n:...,s:...}
    var pos: usize = 0;
    while (pos < array_content.len) {
        const obj_start = std.mem.indexOfPos(u8, array_content, pos, "{") orelse break;
        const obj_end = std.mem.indexOfPos(u8, array_content, obj_start + 1, "}") orelse break;

        const obj_content = array_content[obj_start + 1 .. obj_end];

        var name: ?[]const u8 = null;
        var section_id: i32 = 0;

        // Find "n": "value"
        if (std.mem.indexOf(u8, obj_content, "\"n\":\"")) |n_idx| {
            const val_start = n_idx + 5;
            const val_end = std.mem.indexOfPos(u8, obj_content, val_start, "\"") orelse obj_content.len;
            if (val_end > val_start) {
                name = obj_content[val_start..val_end];
            }
        }

        // Find "s": value
        if (std.mem.indexOf(u8, obj_content, "\"s\":")) |s_idx| {
            const val_start = s_idx + 4;
            var val_end = val_start;
            if (val_end < obj_content.len and obj_content[val_end] == '-') val_end += 1;
            while (val_end < obj_content.len and (obj_content[val_end] >= '0' and obj_content[val_end] <= '9')) : (val_end += 1) {}
            if (val_end > val_start) {
                section_id = std.fmt.parseInt(i32, obj_content[val_start..val_end], 10) catch 0;
            }
        }

        if (name) |n| {
            if (result.len < result.buf.len) {
                result.buf[result.len] = .{ .name = n, .section_id = section_id };
                result.len += 1;
            }
        }

        pos = obj_end + 1;
    }

    if (result.len == 0) return null;
    return result;
}

// Tests
test "parseCommandIds parses array" {
    // We can't easily test this without mocking protocol.CommandMessage
    // The integration tests via websocat will verify this works
}
