const std = @import("std");

// Protocol version - increment when breaking changes are made
pub const PROTOCOL_VERSION: u32 = 1;
pub const EXTENSION_VERSION = "0.6.0";

// Incoming message types
pub const MessageType = enum {
    command,
    hello,
    unknown,

    pub fn parse(data: []const u8) MessageType {
        if (jsonGetString(data, "type")) |t| {
            if (std.mem.eql(u8, t, "command")) return .command;
            if (std.mem.eql(u8, t, "hello")) return .hello;
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

    // Get a string parameter from the message
    pub fn getString(self: CommandMessage, key: []const u8) ?[]const u8 {
        return jsonGetString(self.raw, key);
    }

    // Get an integer parameter from the message
    pub fn getInt(self: CommandMessage, key: []const u8) ?c_int {
        return jsonGetInt(self.raw, key);
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

    // Find closing quote
    const quote2 = std.mem.indexOfPos(u8, data, quote1 + 1, "\"") orelse return null;

    return data[quote1 + 1 .. quote2];
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

// Helper to escape JSON strings - used by state modules for serialization
pub fn writeJsonString(writer: anytype, s: []const u8) !void {
    for (s) |c| {
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
pub fn buildHelloResponse(buf: []u8) []const u8 {
    var w = JsonWriter.init(buf);
    w.beginObject();
    w.field("type");
    w.string("hello");
    w.field("extensionVersion");
    w.string(EXTENSION_VERSION);
    w.field("protocolVersion");
    w.int(PROTOCOL_VERSION);
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

test "MessageType.parse recognizes hello" {
    const hello_data = "{\"type\":\"hello\",\"clientVersion\":\"1.0.0\"}";
    try std.testing.expectEqual(MessageType.hello, MessageType.parse(hello_data));
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
    const json = buildHelloResponse(&buf);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"extensionVersion\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"protocolVersion\"") != null);
}
