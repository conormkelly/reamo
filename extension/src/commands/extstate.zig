const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../core/protocol.zig");
const mod = @import("mod.zig");
const logging = @import("../core/logging.zig");

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

/// The only project ExtState a client may touch: the mixer's custom banks.
/// Clients get no general ExtState access — other extensions and scripts keep
/// settings and secrets there, and some scripts execute what they load, so
/// a remote client must not read or write it. REAmo's own server config
/// (AllowedHosts, ServerPort) is global ExtState and has no command at all.
const PROJ_EXTNAME = "Reamo";

/// Largest value a client may store (API.md limits).
const MAX_PROJ_VALUE_LEN = 16384;
const PROJ_KEYS = [_][]const u8{"CustomBanks"};

fn isAllowedProjState(extname: []const u8, key: []const u8) bool {
    if (!std.mem.eql(u8, extname, PROJ_EXTNAME)) return false;
    for (PROJ_KEYS) |allowed| {
        if (std.mem.eql(u8, key, allowed)) return true;
    }
    return false;
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
    if (!isAllowedProjState(extname, key)) {
        response.err("FORBIDDEN", "extname/key is not accessible to clients");
        return;
    }

    // Convert to null-terminated strings
    var extname_buf: [65]u8 = undefined;
    var key_buf: [65]u8 = undefined;
    const extname_z = mod.toNullTerminated(&extname_buf, extname);
    const key_z = mod.toNullTerminated(&key_buf, key);

    // Scratch arena, not stack (§1): values reach 16 KB
    const tiered = mod.g_ctx.tiered orelse {
        response.err("NOT_INITIALIZED", "Tiered arenas not initialized");
        return;
    };
    const scratch = tiered.scratchAllocator();

    // One byte more than the largest value, which REAPER needs for the NUL.
    const value_buf = scratch.alloc(u8, MAX_PROJ_VALUE_LEN + 1) catch {
        response.err("ALLOC_FAILED", "Failed to allocate buffer");
        return;
    };
    const value = api.getProjExtStateValue(extname_z, key_z, value_buf);

    // Worst-case escaping is 6 bytes per byte (control characters as \u00XX).
    const payload_buf = scratch.alloc(u8, (if (value) |v| v.len else 0) * 6 + 64) catch {
        response.err("ALLOC_FAILED", "Failed to allocate buffer");
        return;
    };
    if (formatValueResponse(value, payload_buf)) |payload| {
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
    if (!isAllowedProjState(extname, key)) {
        response.err("FORBIDDEN", "extname/key is not accessible to clients");
        return;
    }
    // Stored as the client wrote it: unescaped and whole. A value cut short
    // (custom banks are JSON) would no longer parse and the UI would discard
    // it, so an oversized value is refused rather than truncated.
    const value = (cmd.getTextAlloc("value", std.heap.c_allocator) catch {
        response.err("ALLOC_FAILED", "Failed to read value");
        return;
    }) orelse {
        response.err("MISSING_VALUE", "value is required");
        return;
    };
    defer std.heap.c_allocator.free(value);
    if (value.len > MAX_PROJ_VALUE_LEN) {
        response.err("VALUE_TOO_LARGE", "value exceeds 16384 bytes");
        return;
    }

    // Convert to null-terminated strings
    var extname_buf: [65]u8 = undefined;
    var key_buf: [65]u8 = undefined;
    const extname_z = mod.toNullTerminated(&extname_buf, extname);
    const key_z = mod.toNullTerminated(&key_buf, key);

    api.setProjExtStateValue(extname_z, key_z, value);
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

test "project ExtState commands only reach REAmo's own CustomBanks key" {
    const mock = @import("../reaper/mock/mod.zig");
    var m = mock.MockBackend{};
    // Other extensions' and scripts' state, and REAmo's own server config.
    const forbidden = [_][]const u8{
        \\{"type":"command","command":"extstate/projSet","extname":"SWS","key":"config","value":"x"}
        ,
        \\{"type":"command","command":"extstate/projSet","extname":"Reamo","key":"AllowedHosts","value":"evil.example"}
        ,
        \\{"type":"command","command":"extstate/projSet","extname":"reamo","key":"CustomBanks","value":"[]"}
        ,
    };
    for (forbidden) |json| mod.testRunHandler(&m, handleProjSet, json);
    mod.testRunHandler(&m, handleProjGet,
        \\{"type":"command","command":"extstate/projGet","extname":"SomeScript","key":"api_key"}
    );
    try std.testing.expectEqual(@as(usize, 0), m.getCallCount(.setProjExtStateValue));
    try std.testing.expectEqual(@as(usize, 0), m.getCallCount(.getProjExtStateValue));

    try std.testing.expect(isAllowedProjState("Reamo", "CustomBanks"));
}
