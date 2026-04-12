const std = @import("std");
const encoding = @import("../platform/encoding.zig");

// Protocol version - increment when breaking changes are made
pub const PROTOCOL_VERSION: u32 = 1;
pub const EXTENSION_VERSION = "0.7.3";

// Incoming message types
pub const MessageType = enum {
    command,
    hello,
    clockSync,
    ping,
    unknown,

    pub fn parse(data: []const u8) MessageType {
        if (jsonGetString(data, "type")) |t| {
            if (std.mem.eql(u8, t, "command")) return .command;
            if (std.mem.eql(u8, t, "hello")) return .hello;
            if (std.mem.eql(u8, t, "clockSync")) return .clockSync;
            if (std.mem.eql(u8, t, "ping")) return .ping;
        }
        return .unknown;
    }
};

// Hello message from client (for handshake)
pub const HelloMessage = struct {
    client_version: ?[]const u8,
    protocol_version: ?u32,
    token: ?[]const u8,

    pub fn parse(data: []const u8) HelloMessage {
        return .{
            .client_version = jsonGetString(data, "clientVersion"),
            .protocol_version = if (jsonGetInt(data, "protocolVersion")) |v| @intCast(@as(u32, @bitCast(v))) else null,
            .token = jsonGetString(data, "token"),
        };
    }
};

// Parsed command from client
pub const CommandMessage = struct {
    command: []const u8,
    raw: []const u8,

    pub fn parse(data: []const u8) ?CommandMessage {
        const command = jsonGetString(data, "command") orelse return null;
        return .{ .command = command, .raw = data };
    }

    // Get the correlation ID for response routing (optional)
    pub fn getId(self: CommandMessage) ?[]const u8 {
        return jsonGetString(self.raw, "id");
    }

    // Get a float parameter from the message
    pub fn getFloat(self: CommandMessage, key: []const u8) ?f64 {
        return jsonGetFloat(self.raw, key);
    }

    // Get a string parameter from the message (raw, no unescaping)
    pub fn getString(self: CommandMessage, key: []const u8) ?[]const u8 {
        return jsonGetString(self.raw, key);
    }

    // Get a string parameter with JSON unescaping (for content that may contain \n, \t, etc.)
    pub fn getStringUnescaped(self: CommandMessage, key: []const u8, out_buf: []u8) ?[]const u8 {
        return jsonGetStringUnescaped(self.raw, key, out_buf);
    }

    // Get an integer parameter from the message
    pub fn getInt(self: CommandMessage, key: []const u8) ?c_int {
        return jsonGetInt(self.raw, key);
    }

    // Get an integer array parameter from the message
    pub fn getIntArray(
        self: CommandMessage,
        key: []const u8,
        comptime max_items: usize,
        out_values: *[max_items]c_int,
    ) ?[]const c_int {
        const count = jsonGetIntArray(self.raw, key, max_items, out_values) orelse return null;
        if (count == 0) return null;
        return out_values[0..count];
    }
};

// Simple JSON field extraction (no allocations)
// Looks for "key": and extracts the value

pub fn jsonGetString(data: []const u8, key: []const u8) ?[]const u8 {
    // Build search pattern: "key"
    var pattern_buf: [64]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\"", .{key}) catch return null;

    const key_start = std.mem.indexOf(u8, data, pattern) orelse return null;
    const after_key = key_start + pattern.len;

    // Find the colon
    const colon = std.mem.indexOfPos(u8, data, after_key, ":") orelse return null;

    // Find opening quote
    const quote1 = std.mem.indexOfPos(u8, data, colon + 1, "\"") orelse return null;

    // Find closing quote (handling escaped quotes)
    var i = quote1 + 1;
    while (i < data.len) : (i += 1) {
        if (data[i] == '"') break;
        if (data[i] == '\\' and i + 1 < data.len) i += 1; // Skip escaped char
    }
    if (i >= data.len) return null;

    return data[quote1 + 1 .. i];
}

/// Get a JSON string value and unescape it into the provided buffer.
/// Handles \n, \r, \t, \\, \", and \uXXXX escape sequences.
pub fn jsonGetStringUnescaped(data: []const u8, key: []const u8, out_buf: []u8) ?[]const u8 {
    // Build search pattern: "key"
    var pattern_buf: [64]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\"", .{key}) catch return null;

    const key_start = std.mem.indexOf(u8, data, pattern) orelse return null;
    const after_key = key_start + pattern.len;

    // Find the colon
    const colon = std.mem.indexOfPos(u8, data, after_key, ":") orelse return null;

    // Find opening quote
    const quote1 = std.mem.indexOfPos(u8, data, colon + 1, "\"") orelse return null;

    // Parse and unescape the string content
    var out_idx: usize = 0;
    var i = quote1 + 1;
    while (i < data.len and out_idx < out_buf.len) {
        const c = data[i];
        if (c == '"') break; // End of string

        if (c == '\\' and i + 1 < data.len) {
            // Escape sequence
            const next = data[i + 1];
            switch (next) {
                'n' => {
                    out_buf[out_idx] = '\n';
                    out_idx += 1;
                    i += 2;
                },
                'r' => {
                    out_buf[out_idx] = '\r';
                    out_idx += 1;
                    i += 2;
                },
                't' => {
                    out_buf[out_idx] = '\t';
                    out_idx += 1;
                    i += 2;
                },
                '\\' => {
                    out_buf[out_idx] = '\\';
                    out_idx += 1;
                    i += 2;
                },
                '"' => {
                    out_buf[out_idx] = '"';
                    out_idx += 1;
                    i += 2;
                },
                '/' => {
                    out_buf[out_idx] = '/';
                    out_idx += 1;
                    i += 2;
                },
                'u' => {
                    // \uXXXX - decode to UTF-8
                    if (i + 5 < data.len) {
                        // Parse hex digits
                        const hex = data[i + 2 .. i + 6];
                        const codepoint = std.fmt.parseInt(u16, hex, 16) catch {
                            out_buf[out_idx] = '?';
                            out_idx += 1;
                            i += 6;
                            continue;
                        };
                        // Encode as UTF-8
                        if (codepoint < 0x80) {
                            // 1-byte UTF-8 (ASCII)
                            out_buf[out_idx] = @intCast(codepoint);
                            out_idx += 1;
                        } else if (codepoint < 0x800) {
                            // 2-byte UTF-8
                            if (out_idx + 2 > out_buf.len) break;
                            out_buf[out_idx] = @intCast(0xC0 | (codepoint >> 6));
                            out_buf[out_idx + 1] = @intCast(0x80 | (codepoint & 0x3F));
                            out_idx += 2;
                        } else {
                            // 3-byte UTF-8 (covers all of BMP: U+0800 to U+FFFF)
                            if (out_idx + 3 > out_buf.len) break;
                            out_buf[out_idx] = @intCast(0xE0 | (codepoint >> 12));
                            out_buf[out_idx + 1] = @intCast(0x80 | ((codepoint >> 6) & 0x3F));
                            out_buf[out_idx + 2] = @intCast(0x80 | (codepoint & 0x3F));
                            out_idx += 3;
                        }
                        i += 6;
                    } else {
                        i += 2;
                    }
                },
                else => {
                    // Unknown escape, just output the character after backslash
                    out_buf[out_idx] = next;
                    out_idx += 1;
                    i += 2;
                },
            }
        } else {
            // Regular character
            out_buf[out_idx] = c;
            out_idx += 1;
            i += 1;
        }
    }

    return out_buf[0..out_idx];
}

pub fn jsonGetFloat(data: []const u8, key: []const u8) ?f64 {
    // Build search pattern: "key"
    var pattern_buf: [64]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\"", .{key}) catch return null;

    const key_start = std.mem.indexOf(u8, data, pattern) orelse return null;
    const after_key = key_start + pattern.len;

    // Find the colon
    const colon = std.mem.indexOfPos(u8, data, after_key, ":") orelse return null;

    // Skip whitespace
    var num_start = colon + 1;
    while (num_start < data.len and (data[num_start] == ' ' or data[num_start] == '\t')) {
        num_start += 1;
    }

    // Find end of number
    var num_end = num_start;
    while (num_end < data.len) {
        const c = data[num_end];
        if (c == '.' or c == '-' or c == '+' or c == 'e' or c == 'E' or (c >= '0' and c <= '9')) {
            num_end += 1;
        } else {
            break;
        }
    }

    if (num_end > num_start) {
        return std.fmt.parseFloat(f64, data[num_start..num_end]) catch null;
    }
    return null;
}

pub fn jsonGetInt(data: []const u8, key: []const u8) ?c_int {
    // Build search pattern: "key"
    var pattern_buf: [64]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\"", .{key}) catch return null;

    const key_start = std.mem.indexOf(u8, data, pattern) orelse return null;
    const after_key = key_start + pattern.len;

    // Find the colon
    const colon = std.mem.indexOfPos(u8, data, after_key, ":") orelse return null;

    // Skip whitespace
    var num_start = colon + 1;
    while (num_start < data.len and (data[num_start] == ' ' or data[num_start] == '\t')) {
        num_start += 1;
    }

    // Find end of number (integers only - no decimal point)
    var num_end = num_start;
    while (num_end < data.len) {
        const c = data[num_end];
        if (c == '-' or c == '+' or (c >= '0' and c <= '9')) {
            num_end += 1;
        } else {
            break;
        }
    }

    if (num_end > num_start) {
        return std.fmt.parseInt(c_int, data[num_start..num_end], 10) catch null;
    }
    return null;
}

/// Get a boolean value by key.
/// Handles "key":true and "key":false (not quoted).
pub fn jsonGetBool(data: []const u8, key: []const u8) ?bool {
    var pattern_buf: [64]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\"", .{key}) catch return null;

    const key_start = std.mem.indexOf(u8, data, pattern) orelse return null;
    const after_key = key_start + pattern.len;

    // Find colon after key
    const colon = std.mem.indexOfPos(u8, data, after_key, ":") orelse return null;

    // Skip whitespace after colon
    var pos = colon + 1;
    while (pos < data.len and (data[pos] == ' ' or data[pos] == '\t')) {
        pos += 1;
    }

    if (pos >= data.len) return null;

    // Check for true/false
    if (pos + 4 <= data.len and std.mem.eql(u8, data[pos..][0..4], "true")) {
        return true;
    }
    if (pos + 5 <= data.len and std.mem.eql(u8, data[pos..][0..5], "false")) {
        return false;
    }

    return null;
}

// =============================================================================
// Nested JSON parsing helpers (for subscription commands)
// =============================================================================

/// Get an integer field from a nested object.
/// E.g., for {"range": {"start": 5}}, call jsonGetIntFromObject(data, "range", "start")
pub fn jsonGetIntFromObject(data: []const u8, obj_key: []const u8, field_key: []const u8) ?c_int {
    // Find the object key
    var pattern_buf: [64]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\"", .{obj_key}) catch return null;

    const key_start = std.mem.indexOf(u8, data, pattern) orelse return null;
    const after_key = key_start + pattern.len;

    // Find the colon after the key
    const colon = std.mem.indexOfPos(u8, data, after_key, ":") orelse return null;

    // Find opening brace of nested object
    const open_brace = std.mem.indexOfPos(u8, data, colon + 1, "{") orelse return null;

    // Find closing brace (simple matching, doesn't handle nested objects)
    const close_brace = std.mem.indexOfPos(u8, data, open_brace + 1, "}") orelse return null;

    // Extract the nested object content
    const nested = data[open_brace .. close_brace + 1];

    // Now parse the field from the nested object
    return jsonGetInt(nested, field_key);
}

/// Get a float field from a nested object.
/// E.g., for {"timeRange": {"start": 0.0, "end": 30.0}}, call jsonGetFloatFromObject(data, "timeRange", "start")
pub fn jsonGetFloatFromObject(data: []const u8, obj_key: []const u8, field_key: []const u8) ?f64 {
    // Find the object key
    var pattern_buf: [64]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\"", .{obj_key}) catch return null;

    const key_start = std.mem.indexOf(u8, data, pattern) orelse return null;
    const after_key = key_start + pattern.len;

    // Find the colon after the key
    const colon = std.mem.indexOfPos(u8, data, after_key, ":") orelse return null;

    // Find opening brace of nested object
    const open_brace = std.mem.indexOfPos(u8, data, colon + 1, "{") orelse return null;

    // Find closing brace (simple matching, doesn't handle nested objects)
    const close_brace = std.mem.indexOfPos(u8, data, open_brace + 1, "}") orelse return null;

    // Extract the nested object content
    const nested = data[open_brace .. close_brace + 1];

    // Now parse the field from the nested object
    return jsonGetFloat(nested, field_key);
}

/// Get a string array from JSON.
/// E.g., for {"guids": ["master", "{AAA...}"]}, call jsonGetStringArray(data, "guids", ...)
/// Returns the number of strings parsed, or null if the key is not found.
/// out_bufs and out_lens must be the same length and represent the output storage.
pub fn jsonGetStringArray(
    data: []const u8,
    key: []const u8,
    comptime max_items: usize,
    comptime max_str_len: usize,
    out_bufs: *[max_items][max_str_len]u8,
    out_lens: *[max_items]usize,
) ?usize {
    // Find the key
    var pattern_buf: [64]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\"", .{key}) catch return null;

    const key_start = std.mem.indexOf(u8, data, pattern) orelse return null;
    const after_key = key_start + pattern.len;

    // Find the colon
    const colon = std.mem.indexOfPos(u8, data, after_key, ":") orelse return null;

    // Find opening bracket
    const open_bracket = std.mem.indexOfPos(u8, data, colon + 1, "[") orelse return null;

    // Find closing bracket
    const close_bracket = std.mem.indexOfPos(u8, data, open_bracket + 1, "]") orelse return null;

    // Parse strings within brackets
    var count: usize = 0;
    var pos = open_bracket + 1;

    while (pos < close_bracket and count < max_items) {
        // Skip whitespace and commas
        while (pos < close_bracket and (data[pos] == ' ' or data[pos] == ',' or data[pos] == '\t' or data[pos] == '\n')) {
            pos += 1;
        }

        if (pos >= close_bracket) break;

        // Expect opening quote
        if (data[pos] != '"') {
            pos += 1;
            continue;
        }
        pos += 1;

        // Find closing quote (handling escapes)
        const str_start = pos;
        while (pos < close_bracket) {
            if (data[pos] == '"') break;
            if (data[pos] == '\\' and pos + 1 < close_bracket) {
                pos += 2; // Skip escaped char
            } else {
                pos += 1;
            }
        }

        if (pos >= close_bracket) break;

        // Copy string to output buffer
        const str_len = pos - str_start;
        const copy_len = @min(str_len, max_str_len);
        @memcpy(out_bufs[count][0..copy_len], data[str_start..][0..copy_len]);
        out_lens[count] = copy_len;
        count += 1;

        pos += 1; // Skip closing quote
    }

    return count;
}

/// Get an integer array from JSON.
/// E.g., for {"indices": [0, 5, 10]}, call jsonGetIntArray(data, "indices", ...)
/// Returns the number of integers parsed, or null if the key is not found.
pub fn jsonGetIntArray(
    data: []const u8,
    key: []const u8,
    comptime max_items: usize,
    out_values: *[max_items]c_int,
) ?usize {
    // Find the key
    var pattern_buf: [64]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\"", .{key}) catch return null;

    const key_start = std.mem.indexOf(u8, data, pattern) orelse return null;
    const after_key = key_start + pattern.len;

    // Find the colon
    const colon = std.mem.indexOfPos(u8, data, after_key, ":") orelse return null;

    // Find opening bracket
    const open_bracket = std.mem.indexOfPos(u8, data, colon + 1, "[") orelse return null;

    // Find closing bracket
    const close_bracket = std.mem.indexOfPos(u8, data, open_bracket + 1, "]") orelse return null;

    // Parse integers within brackets
    var count: usize = 0;
    var pos = open_bracket + 1;

    while (pos < close_bracket and count < max_items) {
        // Skip whitespace and commas
        while (pos < close_bracket and (data[pos] == ' ' or data[pos] == ',' or data[pos] == '\t' or data[pos] == '\n')) {
            pos += 1;
        }

        if (pos >= close_bracket) break;

        // Find start of number (handles negative)
        const num_start = pos;
        if (data[pos] == '-') pos += 1;

        // Find end of number
        while (pos < close_bracket and data[pos] >= '0' and data[pos] <= '9') {
            pos += 1;
        }

        if (pos > num_start) {
            const value = std.fmt.parseInt(c_int, data[num_start..pos], 10) catch continue;
            out_values[count] = value;
            count += 1;
        }
    }

    return count;
}

// JSON building helpers

pub const JsonWriter = struct {
    buf: []u8,
    pos: usize = 0,

    pub fn init(buf: []u8) JsonWriter {
        return .{ .buf = buf };
    }

    pub fn beginObject(self: *JsonWriter) void {
        self.write("{");
    }

    pub fn endObject(self: *JsonWriter) void {
        // Remove trailing comma if present
        if (self.pos > 0 and self.buf[self.pos - 1] == ',') {
            self.pos -= 1;
        }
        self.write("}");
    }

    pub fn field(self: *JsonWriter, key: []const u8) void {
        self.write("\"");
        self.write(key);
        self.write("\":");
    }

    pub fn string(self: *JsonWriter, value: []const u8) void {
        self.write("\"");
        self.write(value);
        self.write("\",");
    }

    pub fn int(self: *JsonWriter, value: anytype) void {
        const written = std.fmt.bufPrint(self.buf[self.pos..], "{d},", .{value}) catch return;
        self.pos += written.len;
    }

    pub fn float(self: *JsonWriter, value: f64, comptime precision: u8) void {
        const fmt = "{d:." ++ std.fmt.comptimePrint("{d}", .{precision}) ++ "},";
        const written = std.fmt.bufPrint(self.buf[self.pos..], fmt, .{value}) catch return;
        self.pos += written.len;
    }

    pub fn object(self: *JsonWriter) *JsonWriter {
        self.write("{");
        return self;
    }

    pub fn close(self: *JsonWriter) void {
        if (self.pos > 0 and self.buf[self.pos - 1] == ',') {
            self.pos -= 1;
        }
        self.write("},");
    }

    fn write(self: *JsonWriter, s: []const u8) void {
        if (self.pos + s.len <= self.buf.len) {
            @memcpy(self.buf[self.pos..][0..s.len], s);
            self.pos += s.len;
        }
    }

    pub fn slice(self: *JsonWriter) []const u8 {
        return self.buf[0..self.pos];
    }
};

// Build standard event message
pub fn buildEvent(buf: []u8, event_name: []const u8, payload_fn: fn (*JsonWriter) void) ?[]const u8 {
    var w = JsonWriter.init(buf);
    w.beginObject();
    w.field("type");
    w.string("event");
    w.field("event");
    w.string(event_name);
    w.field("payload");
    w.beginObject();
    payload_fn(&w);
    w.endObject();
    w.endObject();
    return w.slice();
}

// Helper to escape JSON strings - used by state modules for serialization.
// On Windows, transcodes from the system's active code page (e.g. Windows-1252)
// to UTF-8 before escaping — REAPER's C API returns strings in the local code
// page, not UTF-8, which would otherwise break WebSocket text frames.
pub fn writeJsonString(writer: anytype, s: []const u8) !void {
    // Transcode from system code page to UTF-8 (no-op on non-Windows / pure ASCII).
    // Keep buffer ≤1KB — this runs in timer callbacks with deep call stacks (see ZIG_GUIDE §1).
    // 512 bytes covers realistic REAPER names (action/FX/track names are typically <256 bytes;
    // UTF-8 expansion of Windows-1252 is at most 2x for the 0x80-0x9F range, 1.5x typical).
    var utf8_buf: [512]u8 = undefined;
    const str = encoding.toUtf8(s, &utf8_buf) orelse s;

    for (str) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
}

// Build error response
pub fn buildError(buf: []u8, code: []const u8, message: []const u8) []const u8 {
    var w = JsonWriter.init(buf);
    w.beginObject();
    w.field("type");
    w.string("error");
    w.field("error");
    w.beginObject();
    w.field("code");
    w.string(code);
    w.field("message");
    w.string(message);
    w.endObject();
    w.endObject();
    return w.slice();
}

// Build hello response (sent after successful handshake)
// Includes htmlMtime so clients can detect stale content on reconnect
pub fn buildHelloResponse(buf: []u8, html_mtime: i64) []const u8 {
    var w = JsonWriter.init(buf);
    w.beginObject();
    w.field("type");
    w.string("hello");
    w.field("extensionVersion");
    w.string(EXTENSION_VERSION);
    w.field("protocolVersion");
    w.int(PROTOCOL_VERSION);
    w.field("htmlMtime");
    w.int(@divTrunc(html_mtime, 1_000_000_000)); // Convert to seconds
    w.endObject();
    return w.slice();
}

// Tests
test "jsonGetString" {
    const data = "{\"type\":\"command\",\"command\":\"transport/play\"}";
    try std.testing.expectEqualStrings("command", jsonGetString(data, "type").?);
    try std.testing.expectEqualStrings("transport/play", jsonGetString(data, "command").?);
    try std.testing.expect(jsonGetString(data, "missing") == null);
}

test "jsonGetFloat" {
    const data = "{\"position\":123.456,\"speed\":-1.5}";
    try std.testing.expectApproxEqAbs(@as(f64, 123.456), jsonGetFloat(data, "position").?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, -1.5), jsonGetFloat(data, "speed").?, 0.001);
    try std.testing.expect(jsonGetFloat(data, "missing") == null);
}

test "CommandMessage.parse" {
    const data = "{\"type\":\"command\",\"command\":\"transport/seek\",\"position\":42.5}";
    const cmd = CommandMessage.parse(data).?;
    try std.testing.expectEqualStrings("transport/seek", cmd.command);
    try std.testing.expectApproxEqAbs(@as(f64, 42.5), cmd.getFloat("position").?, 0.001);
}

test "JsonWriter" {
    var buf: [256]u8 = undefined;
    var w = JsonWriter.init(&buf);
    w.beginObject();
    w.field("name");
    w.string("test");
    w.field("value");
    w.int(@as(i32, 42));
    w.endObject();
    try std.testing.expectEqualStrings("{\"name\":\"test\",\"value\":42}", w.slice());
}

test "writeJsonString escapes special characters" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const w = stream.writer();

    try writeJsonString(w, "quote\"here");
    try std.testing.expectEqualStrings("quote\\\"here", stream.getWritten());
}

test "writeJsonString escapes backslash" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const w = stream.writer();

    try writeJsonString(w, "path\\to\\file");
    try std.testing.expectEqualStrings("path\\\\to\\\\file", stream.getWritten());
}

test "writeJsonString escapes newlines and tabs" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const w = stream.writer();

    try writeJsonString(w, "line1\nline2\ttabbed");
    try std.testing.expectEqualStrings("line1\\nline2\\ttabbed", stream.getWritten());
}

test "writeJsonString escapes control characters" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const w = stream.writer();

    // Test a control character (ASCII 1 = SOH)
    try writeJsonString(w, "before\x01after");
    try std.testing.expectEqualStrings("before\\u0001after", stream.getWritten());
}

test "writeJsonString handles empty string" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const w = stream.writer();

    try writeJsonString(w, "");
    try std.testing.expectEqual(@as(usize, 0), stream.getWritten().len);
}

test "writeJsonString produces valid UTF-8 from Windows-1252 bytes" {
    // On Windows, REAPER's C API returns strings in the system code page.
    // Before the fix, 0xE9 (é in Windows-1252) was written as a raw byte — invalid UTF-8.
    // After the fix, writeJsonString transcodes to valid UTF-8 via Win32 APIs.
    // On non-Windows this is a passthrough (macOS/Linux already use UTF-8).
    const builtin = @import("builtin");

    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const w = stream.writer();

    try writeJsonString(w, "Caf\xe9");
    const output = stream.getWritten();

    if (comptime builtin.os.tag == .windows) {
        // On Windows: should be transcoded to valid UTF-8 "Café"
        try std.testing.expectEqualStrings("Caf\xc3\xa9", output);
    } else {
        // On non-Windows: passthrough (raw bytes unchanged)
        try std.testing.expectEqualStrings("Caf\xe9", output);
    }
}

test "MessageType.parse recognizes hello" {
    const hello_data = "{\"type\":\"hello\",\"clientVersion\":\"1.0.0\"}";
    try std.testing.expectEqual(MessageType.hello, MessageType.parse(hello_data));
}

test "MessageType.parse recognizes clockSync" {
    const sync_data = "{\"type\":\"clockSync\",\"t0\":1704067200000.123}";
    try std.testing.expectEqual(MessageType.clockSync, MessageType.parse(sync_data));
}

test "HelloMessage.parse extracts fields" {
    const data = "{\"type\":\"hello\",\"clientVersion\":\"1.0.0\",\"protocolVersion\":1,\"token\":\"abc123\"}";
    const msg = HelloMessage.parse(data);
    try std.testing.expectEqualStrings("1.0.0", msg.client_version.?);
    try std.testing.expectEqual(@as(u32, 1), msg.protocol_version.?);
    try std.testing.expectEqualStrings("abc123", msg.token.?);
}

test "buildHelloResponse" {
    var buf: [256]u8 = undefined;
    const json = buildHelloResponse(&buf, 1735000000_000_000_000); // Example mtime in nanoseconds
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"extensionVersion\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"protocolVersion\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"htmlMtime\":1735000000") != null);
}

test "jsonGetStringUnescaped handles newlines" {
    const data = "{\"notes\":\"line1\\nline2\\nline3\"}";
    var buf: [256]u8 = undefined;
    const result = jsonGetStringUnescaped(data, "notes", &buf);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("line1\nline2\nline3", result.?);
}

test "jsonGetStringUnescaped handles tabs and carriage returns" {
    const data = "{\"text\":\"col1\\tcol2\\r\\nrow2\"}";
    var buf: [256]u8 = undefined;
    const result = jsonGetStringUnescaped(data, "text", &buf);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("col1\tcol2\r\nrow2", result.?);
}

test "jsonGetStringUnescaped handles escaped quotes and backslashes" {
    const data = "{\"path\":\"C:\\\\Users\\\\test\\\"quoted\\\"\"}";
    var buf: [256]u8 = undefined;
    const result = jsonGetStringUnescaped(data, "path", &buf);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("C:\\Users\\test\"quoted\"", result.?);
}

test "jsonGetStringUnescaped handles plain text" {
    const data = "{\"simple\":\"hello world\"}";
    var buf: [256]u8 = undefined;
    const result = jsonGetStringUnescaped(data, "simple", &buf);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("hello world", result.?);
}

test "jsonGetStringUnescaped handles unicode escapes" {
    // Test ASCII range (1-byte UTF-8)
    {
        const data = "{\"text\":\"A\\u0041B\"}"; // \u0041 = 'A'
        var buf: [256]u8 = undefined;
        const result = jsonGetStringUnescaped(data, "text", &buf);
        try std.testing.expect(result != null);
        try std.testing.expectEqualStrings("AAB", result.?);
    }
    // Test 2-byte UTF-8 (U+0080 to U+07FF)
    {
        const data = "{\"text\":\"\\u00E9\"}"; // \u00E9 = 'é' (e with acute)
        var buf: [256]u8 = undefined;
        const result = jsonGetStringUnescaped(data, "text", &buf);
        try std.testing.expect(result != null);
        try std.testing.expectEqualStrings("é", result.?);
    }
    // Test 3-byte UTF-8 (U+0800 to U+FFFF)
    {
        const data = "{\"text\":\"\\u4E2D\"}"; // \u4E2D = '中' (Chinese character)
        var buf: [256]u8 = undefined;
        const result = jsonGetStringUnescaped(data, "text", &buf);
        try std.testing.expect(result != null);
        try std.testing.expectEqualStrings("中", result.?);
    }
    // Test mixed content
    {
        const data = "{\"text\":\"Hello \\u4E16\\u754C\"}"; // "Hello 世界" (Hello World in Chinese)
        var buf: [256]u8 = undefined;
        const result = jsonGetStringUnescaped(data, "text", &buf);
        try std.testing.expect(result != null);
        try std.testing.expectEqualStrings("Hello 世界", result.?);
    }
}

test "jsonGetString handles escaped quotes in string" {
    const data = "{\"text\":\"say \\\"hello\\\"\"}";
    const result = jsonGetString(data, "text");
    try std.testing.expect(result != null);
    // Raw result includes the escape sequences
    try std.testing.expectEqualStrings("say \\\"hello\\\"", result.?);
}

test "jsonGetBool true" {
    const data = "{\"includeMaster\":true}";
    try std.testing.expectEqual(true, jsonGetBool(data, "includeMaster").?);
}

test "jsonGetBool false" {
    const data = "{\"includeMaster\":false}";
    try std.testing.expectEqual(false, jsonGetBool(data, "includeMaster").?);
}

test "jsonGetBool missing key" {
    const data = "{\"other\":true}";
    try std.testing.expect(jsonGetBool(data, "includeMaster") == null);
}

test "jsonGetBool with whitespace" {
    const data = "{ \"includeMaster\" : true }";
    try std.testing.expectEqual(true, jsonGetBool(data, "includeMaster").?);
}

test "jsonGetIntFromObject basic" {
    const data = "{\"range\":{\"start\":5,\"end\":10}}";
    try std.testing.expectEqual(@as(c_int, 5), jsonGetIntFromObject(data, "range", "start").?);
    try std.testing.expectEqual(@as(c_int, 10), jsonGetIntFromObject(data, "range", "end").?);
}

test "jsonGetIntFromObject missing key" {
    const data = "{\"range\":{\"start\":5}}";
    try std.testing.expect(jsonGetIntFromObject(data, "range", "end") == null);
    try std.testing.expect(jsonGetIntFromObject(data, "missing", "start") == null);
}

test "jsonGetIntFromObject with whitespace" {
    const data = "{ \"range\" : { \"start\" : 0 , \"end\" : 31 } }";
    try std.testing.expectEqual(@as(c_int, 0), jsonGetIntFromObject(data, "range", "start").?);
    try std.testing.expectEqual(@as(c_int, 31), jsonGetIntFromObject(data, "range", "end").?);
}

test "jsonGetFloatFromObject basic" {
    const data = "{\"timeRange\":{\"start\":0.0,\"end\":30.5}}";
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), jsonGetFloatFromObject(data, "timeRange", "start").?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 30.5), jsonGetFloatFromObject(data, "timeRange", "end").?, 0.001);
}

test "jsonGetFloatFromObject missing key" {
    const data = "{\"timeRange\":{\"start\":0.0}}";
    try std.testing.expect(jsonGetFloatFromObject(data, "timeRange", "end") == null);
    try std.testing.expect(jsonGetFloatFromObject(data, "missing", "start") == null);
}

test "jsonGetFloatFromObject with whitespace" {
    const data = "{ \"timeRange\" : { \"start\" : 0.0 , \"end\" : 120.5 } }";
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), jsonGetFloatFromObject(data, "timeRange", "start").?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 120.5), jsonGetFloatFromObject(data, "timeRange", "end").?, 0.001);
}

test "jsonGetStringArray basic" {
    const data = "{\"guids\":[\"master\",\"{00000001}\"]}";
    var bufs: [4][64]u8 = undefined;
    var lens: [4]usize = undefined;
    const count = jsonGetStringArray(data, "guids", 4, 64, &bufs, &lens).?;
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("master", bufs[0][0..lens[0]]);
    try std.testing.expectEqualStrings("{00000001}", bufs[1][0..lens[1]]);
}

test "jsonGetStringArray empty array" {
    const data = "{\"guids\":[]}";
    var bufs: [4][64]u8 = undefined;
    var lens: [4]usize = undefined;
    const count = jsonGetStringArray(data, "guids", 4, 64, &bufs, &lens).?;
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "jsonGetStringArray missing key" {
    const data = "{\"other\":[\"a\"]}";
    var bufs: [4][64]u8 = undefined;
    var lens: [4]usize = undefined;
    try std.testing.expect(jsonGetStringArray(data, "guids", 4, 64, &bufs, &lens) == null);
}

test "jsonGetStringArray with whitespace" {
    const data = "{ \"guids\" : [ \"a\" , \"b\" , \"c\" ] }";
    var bufs: [4][64]u8 = undefined;
    var lens: [4]usize = undefined;
    const count = jsonGetStringArray(data, "guids", 4, 64, &bufs, &lens).?;
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqualStrings("a", bufs[0][0..lens[0]]);
    try std.testing.expectEqualStrings("b", bufs[1][0..lens[1]]);
    try std.testing.expectEqualStrings("c", bufs[2][0..lens[2]]);
}

test "jsonGetStringArray respects max_items" {
    const data = "{\"guids\":[\"a\",\"b\",\"c\",\"d\",\"e\"]}";
    var bufs: [2][64]u8 = undefined;
    var lens: [2]usize = undefined;
    const count = jsonGetStringArray(data, "guids", 2, 64, &bufs, &lens).?;
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "jsonGetIntArray basic" {
    const data = "{\"indices\":[0, 5, 10, 15]}";
    var values: [10]c_int = undefined;
    const count = jsonGetIntArray(data, "indices", 10, &values).?;
    try std.testing.expectEqual(@as(usize, 4), count);
    try std.testing.expectEqual(@as(c_int, 0), values[0]);
    try std.testing.expectEqual(@as(c_int, 5), values[1]);
    try std.testing.expectEqual(@as(c_int, 10), values[2]);
    try std.testing.expectEqual(@as(c_int, 15), values[3]);
}

test "jsonGetIntArray empty array" {
    const data = "{\"indices\":[]}";
    var values: [10]c_int = undefined;
    const count = jsonGetIntArray(data, "indices", 10, &values).?;
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "jsonGetIntArray missing key" {
    const data = "{\"other\":[1,2,3]}";
    var values: [10]c_int = undefined;
    try std.testing.expect(jsonGetIntArray(data, "indices", 10, &values) == null);
}

test "jsonGetIntArray with negative numbers" {
    const data = "{\"values\":[-5, 0, 10, -20]}";
    var values: [10]c_int = undefined;
    const count = jsonGetIntArray(data, "values", 10, &values).?;
    try std.testing.expectEqual(@as(usize, 4), count);
    try std.testing.expectEqual(@as(c_int, -5), values[0]);
    try std.testing.expectEqual(@as(c_int, 0), values[1]);
    try std.testing.expectEqual(@as(c_int, 10), values[2]);
    try std.testing.expectEqual(@as(c_int, -20), values[3]);
}

test "jsonGetIntArray respects max_items" {
    const data = "{\"values\":[1, 2, 3, 4, 5]}";
    var values: [2]c_int = undefined;
    const count = jsonGetIntArray(data, "values", 2, &values).?;
    try std.testing.expectEqual(@as(usize, 2), count);
}
