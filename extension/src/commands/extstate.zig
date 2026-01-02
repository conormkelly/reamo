const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");
const logging = @import("../logging.zig");

// ExtState command handlers
pub const handlers = [_]mod.Entry{
    .{ .name = "extstate/get", .handler = handleGet },
    .{ .name = "extstate/set", .handler = handleSet },
    .{ .name = "extstate/projGet", .handler = handleProjGet },
    .{ .name = "extstate/projSet", .handler = handleProjSet },
};

/// Build JSON response for ExtState value with proper escaping.
/// Returns the JSON payload slice, or null if buffer too small.
/// Format: {"value":"escaped_value"} or {"value":null}
pub fn formatValueResponse(value: ?[]const u8, buf: []u8) ?[]const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    if (value) |v| {
        writer.writeAll("{\"value\":\"") catch return null;
        protocol.writeJsonString(writer, v) catch return null;
        writer.writeAll("\"}") catch return null;
    } else {
        writer.writeAll("{\"value\":null}") catch return null;
    }

    return stream.getWritten();
}

// Get global extended state value
pub fn handleGet(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const section = cmd.getString("section") orelse {
        response.err("MISSING_SECTION", "section is required");
        return;
    };
    const key = cmd.getString("key") orelse {
        response.err("MISSING_KEY", "key is required");
        return;
    };

    // Convert to null-terminated strings
    var section_buf: [65]u8 = undefined;
    var key_buf: [65]u8 = undefined;
    const section_z = mod.toNullTerminated(&section_buf, section);
    const key_z = mod.toNullTerminated(&key_buf, key);

    const value = api.getExtStateValue(section_z, key_z);

    // Buffer: 2x max value (1024) for worst-case escaping + JSON overhead
    var payload_buf: [2200]u8 = undefined;
    if (formatValueResponse(value, &payload_buf)) |payload| {
        response.success(payload);
    } else {
        response.err("VALUE_TOO_LONG", "Value exceeds buffer size");
    }
}

// Set global extended state value
pub fn handleSet(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const section = cmd.getString("section") orelse {
        response.err("MISSING_SECTION", "section is required");
        return;
    };
    const key = cmd.getString("key") orelse {
        response.err("MISSING_KEY", "key is required");
        return;
    };
    const value = cmd.getString("value") orelse {
        response.err("MISSING_VALUE", "value is required");
        return;
    };

    // persist defaults to false
    const persist = if (cmd.getInt("persist")) |p| p != 0 else false;

    // Convert to null-terminated strings
    var section_buf: [65]u8 = undefined;
    var key_buf: [65]u8 = undefined;
    var value_buf: [1025]u8 = undefined;
    const section_z = mod.toNullTerminated(&section_buf, section);
    const key_z = mod.toNullTerminated(&key_buf, key);

    // Value can be longer
    const value_len = @min(value.len, 1024);
    @memcpy(value_buf[0..value_len], value[0..value_len]);
    value_buf[value_len] = 0;
    const value_z: [*:0]const u8 = @ptrCast(&value_buf);

    api.setExtStateValue(section_z, key_z, value_z, persist);
    logging.debug("Set extstate {s}/{s} (persist={any})", .{ section, key, persist });
    response.success(null);
}

// Get project-specific extended state value
pub fn handleProjGet(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const extname = cmd.getString("extname") orelse {
        response.err("MISSING_EXTNAME", "extname is required");
        return;
    };
    const key = cmd.getString("key") orelse {
        response.err("MISSING_KEY", "key is required");
        return;
    };

    // Convert to null-terminated strings
    var extname_buf: [65]u8 = undefined;
    var key_buf: [65]u8 = undefined;
    const extname_z = mod.toNullTerminated(&extname_buf, extname);
    const key_z = mod.toNullTerminated(&key_buf, key);

    var value_buf: [16384]u8 = undefined;
    const value = api.getProjExtStateValue(extname_z, key_z, &value_buf);

    // Buffer: 2x max value (16384) for worst-case escaping + JSON overhead
    var payload_buf: [33000]u8 = undefined;
    if (formatValueResponse(value, &payload_buf)) |payload| {
        response.success(payload);
    } else {
        response.err("VALUE_TOO_LONG", "Value exceeds buffer size");
    }
}

// Set project-specific extended state value
pub fn handleProjSet(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const extname = cmd.getString("extname") orelse {
        response.err("MISSING_EXTNAME", "extname is required");
        return;
    };
    const key = cmd.getString("key") orelse {
        response.err("MISSING_KEY", "key is required");
        return;
    };
    const value = cmd.getString("value") orelse {
        response.err("MISSING_VALUE", "value is required");
        return;
    };

    // Convert to null-terminated strings
    var extname_buf: [65]u8 = undefined;
    var key_buf: [65]u8 = undefined;
    var value_buf: [16385]u8 = undefined;
    const extname_z = mod.toNullTerminated(&extname_buf, extname);
    const key_z = mod.toNullTerminated(&key_buf, key);

    // Value can be longer for project state
    const value_len = @min(value.len, 16384);
    @memcpy(value_buf[0..value_len], value[0..value_len]);
    value_buf[value_len] = 0;
    const value_z: [*:0]const u8 = @ptrCast(&value_buf);

    api.setProjExtStateValue(extname_z, key_z, value_z);
    logging.debug("Set proj extstate {s}/{s}", .{ extname, key });
    response.success(null);
}

// =============================================================================
// Tests
// =============================================================================

test "formatValueResponse with simple value" {
    var buf: [64]u8 = undefined;
    const result = formatValueResponse("hello", &buf).?;
    try std.testing.expectEqualStrings("{\"value\":\"hello\"}", result);
}

test "formatValueResponse with null value" {
    var buf: [64]u8 = undefined;
    const result = formatValueResponse(null, &buf).?;
    try std.testing.expectEqualStrings("{\"value\":null}", result);
}

test "formatValueResponse escapes quotes" {
    var buf: [64]u8 = undefined;
    const result = formatValueResponse("say \"hello\"", &buf).?;
    try std.testing.expectEqualStrings("{\"value\":\"say \\\"hello\\\"\"}", result);
}

test "formatValueResponse escapes backslashes" {
    var buf: [64]u8 = undefined;
    const result = formatValueResponse("path\\to\\file", &buf).?;
    try std.testing.expectEqualStrings("{\"value\":\"path\\\\to\\\\file\"}", result);
}

test "formatValueResponse escapes newlines and tabs" {
    var buf: [64]u8 = undefined;
    const result = formatValueResponse("line1\nline2\ttab", &buf).?;
    try std.testing.expectEqualStrings("{\"value\":\"line1\\nline2\\ttab\"}", result);
}

test "formatValueResponse escapes control characters" {
    var buf: [64]u8 = undefined;
    const result = formatValueResponse("before\x01after", &buf).?;
    try std.testing.expectEqualStrings("{\"value\":\"before\\u0001after\"}", result);
}

test "formatValueResponse handles empty string" {
    var buf: [64]u8 = undefined;
    const result = formatValueResponse("", &buf).?;
    try std.testing.expectEqualStrings("{\"value\":\"\"}", result);
}

test "formatValueResponse returns null on buffer overflow" {
    var buf: [10]u8 = undefined; // Too small
    const result = formatValueResponse("this is a long value", &buf);
    try std.testing.expect(result == null);
}
