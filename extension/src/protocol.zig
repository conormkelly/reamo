const std = @import("std");

// Incoming message types
pub const MessageType = enum {
    command,
    unknown,

    pub fn parse(data: []const u8) MessageType {
        if (jsonGetString(data, "type")) |t| {
            if (std.mem.eql(u8, t, "command")) return .command;
        }
        return .unknown;
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
