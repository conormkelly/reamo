const std = @import("std");
const encoding = @import("../platform/encoding.zig");
const logging = @import("logging.zig");
const utf8 = @import("utf8.zig");

// Protocol version - increment when breaking changes are made
pub const PROTOCOL_VERSION: u32 = 1;
pub const EXTENSION_VERSION = "0.7.4-rc1";

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

    /// A text parameter (a name, notes, a stored value) as the user typed it:
    /// unescaped, whole, NUL-terminated, in a new allocation from `allocator`.
    /// null when the key is absent.
    pub fn getTextAlloc(self: CommandMessage, key: []const u8, allocator: std.mem.Allocator) !?[:0]u8 {
        return jsonGetTextAlloc(self.raw, key, allocator);
    }

    // Get a string parameter with JSON unescaping (for content that may contain \n, \t, etc.)
    pub fn getStringUnescaped(self: CommandMessage, key: []const u8, out_buf: []u8) ?[]const u8 {
        return jsonGetStringUnescaped(self.raw, key, out_buf);
    }

    /// An on/off parameter, sent as a JSON boolean or as 0/1 (the frontend
    /// uses both). null when absent.
    pub fn getFlag(self: CommandMessage, key: []const u8) ?bool {
        if (jsonGetBool(self.raw, key)) |b| return b;
        if (jsonGetInt(self.raw, key)) |v| return v != 0;
        return null;
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

    // The value must be a string: any other type is absent, not the next
    // quoted text further on (which may belong to another key).
    const quote1 = skipJsonWhitespace(data, colon + 1, data.len);
    if (quote1 >= data.len or data[quote1] != '"') return null;

    // Find closing quote (handling escaped quotes)
    var i = quote1 + 1;
    while (i < data.len) : (i += 1) {
        if (data[i] == '"') break;
        if (data[i] == '\\' and i + 1 < data.len) i += 1; // Skip escaped char
    }
    if (i >= data.len) return null;

    return data[quote1 + 1 .. i];
}

/// See CommandMessage.getTextAlloc. Unescaping never lengthens JSON text,
/// so a buffer the size of the escaped value always holds all of it.
pub fn jsonGetTextAlloc(data: []const u8, key: []const u8, allocator: std.mem.Allocator) !?[:0]u8 {
    const escaped = jsonGetString(data, key) orelse return null;
    const tmp = try allocator.alloc(u8, escaped.len);
    defer allocator.free(tmp);
    const text = jsonGetStringUnescaped(data, key, tmp) orelse return null;
    return try allocator.dupeZ(u8, text);
}

/// The 4-hex-digit code unit of a \\uXXXX escape starting at data[at], or null.
fn parseHex4(data: []const u8, at: usize) ?u16 {
    if (at + 4 > data.len) return null;
    return std.fmt.parseInt(u16, data[at .. at + 4], 16) catch null;
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

    // The value must be a string (see jsonGetString).
    const quote1 = skipJsonWhitespace(data, colon + 1, data.len);
    if (quote1 >= data.len or data[quote1] != '"') return null;

    // Parse and unescape the string content. Output stops at the last whole
    // character that fits: a name cut mid-character would be invalid UTF-8
    // in REAPER and in every event that later carries it.
    var out_idx: usize = 0;
    var i = quote1 + 1;
    while (i < data.len) {
        const c = data[i];
        if (c == '"') break; // End of string

        var enc: [4]u8 = undefined;
        var piece: []const u8 = undefined;
        if (c == '\\' and i + 1 < data.len) {
            const next = data[i + 1];
            i += 2;
            piece = switch (next) {
                'n' => "\n",
                'r' => "\r",
                't' => "\t",
                'b' => "\x08",
                'f' => "\x0C",
                '\\' => "\\",
                '"' => "\"",
                '/' => "/",
                'u' => blk: {
                    const unit = parseHex4(data, i) orelse break :blk "?";
                    i += 4;
                    var cp: u21 = unit;
                    if (unit >= 0xD800 and unit <= 0xDBFF) {
                        // A high surrogate must pair with a following \uDC00-\uDFFF.
                        const low = if (i + 1 < data.len and data[i] == '\\' and data[i + 1] == 'u') parseHex4(data, i + 2) else null;
                        if (low != null and low.? >= 0xDC00 and low.? <= 0xDFFF) {
                            cp = 0x10000 + ((@as(u21, unit) - 0xD800) << 10) + (low.? - 0xDC00);
                            i += 6;
                        } else break :blk utf8.replacement;
                    } else if (unit >= 0xDC00 and unit <= 0xDFFF) break :blk utf8.replacement;
                    const n = utf8.encode(cp, &enc) orelse break :blk utf8.replacement;
                    break :blk enc[0..n];
                },
                else => data[i - 1 .. i], // unknown escape: the character itself
            };
        } else {
            // Copy raw UTF-8 a whole character at a time.
            const n = std.unicode.utf8ByteSequenceLength(c) catch 1;
            piece = data[i..@min(i + n, data.len)];
            i += piece.len;
        }
        if (out_idx + piece.len > out_buf.len) break;
        @memcpy(out_buf[out_idx..][0..piece.len], piece);
        out_idx += piece.len;
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

    // A whole number ends at a delimiter: 1.5 or 1e30 is not an integer
    // parameter (read as 1, 1e30 ran action 1).
    const after = skipJsonWhitespace(data, num_end, data.len);
    if (after < data.len and data[after] != ',' and data[after] != '}' and data[after] != ']') return null;

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
/// Returns the number of integers parsed, or null if the key is not found or
/// the array holds anything other than integers.
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

    // Every iteration must consume a number or bail out: an element the
    // scanner cannot advance past would otherwise spin forever.
    while (count < max_items) {
        pos = skipJsonWhitespace(data, pos, close_bracket);
        if (pos >= close_bracket) break;

        // Find start of number (handles negative)
        const num_start = pos;
        if (data[pos] == '-') pos += 1;
        const digits_start = pos;

        // Find end of number
        while (pos < close_bracket and data[pos] >= '0' and data[pos] <= '9') {
            pos += 1;
        }
        if (pos == digits_start) return null;

        const value = std.fmt.parseInt(c_int, data[num_start..pos], 10) catch return null;
        out_values[count] = value;
        count += 1;

        // A number must be followed by a separator or the end of the array.
        pos = skipJsonWhitespace(data, pos, close_bracket);
        if (pos >= close_bracket) break;
        if (data[pos] != ',') return null;
        pos += 1;
    }

    return count;
}

/// Index of the first non-whitespace byte in data[pos..end], or `end`.
fn skipJsonWhitespace(data: []const u8, pos: usize, end: usize) usize {
    var i = pos;
    while (i < end and (data[i] == ' ' or data[i] == '\t' or data[i] == '\n' or data[i] == '\r')) i += 1;
    return i;
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
/// Serialize with `toJson(ctx, buf)` (which returns null when `buf` is too
/// small) into a buffer from `allocator`, starting at `initial_size` and
/// doubling until it fits. Entity JSON size depends on names and escaping, so
/// no per-entity estimate is safe; a too-small fixed buffer silently dropped
/// whole broadcasts for larger projects. Each failed attempt is freed before
/// the next, which a frame arena (FixedBufferAllocator) reclaims, so retries
/// don't consume scratch space. Logs if the allocator itself runs out. The
/// result is its own allocation, exactly the JSON's length, so any allocator
/// can free it.
pub fn serializeAlloc(
    allocator: std.mem.Allocator,
    initial_size: usize,
    ctx: anytype,
    comptime toJson: fn (@TypeOf(ctx), []u8) ?[]const u8,
) ![]const u8 {
    var size = @max(initial_size, 256);
    while (true) {
        const buf = allocator.alloc(u8, size) catch |err| {
            logging.warn("JSON serialization needs more than {d} bytes: {s}", .{ size, @errorName(err) });
            return err;
        };
        if (toJson(ctx, buf)) |json| {
            if (allocator.resize(buf, json.len)) return buf[0..json.len];
            const exact = allocator.dupe(u8, json) catch |err| {
                allocator.free(buf);
                return err;
            };
            allocator.free(buf);
            return exact;
        }
        allocator.free(buf);
        size = std.math.mul(usize, size, 2) catch return error.OutOfMemory;
    }
}

/// serializeAlloc for code that formats through a writer: `write(ctx, w)`
/// writes the whole message to `w`, a fixed-buffer writer that fails with
/// NoSpaceLeft when the buffer is too small, and the buffer doubles until the
/// message fits. `write` must fail only through the writer, or it retries
/// until the allocator runs out.
pub fn writeAlloc(allocator: std.mem.Allocator, initial_size: usize, ctx: anytype, comptime write: anytype) ![]const u8 {
    const Wrap = struct {
        fn toJson(c: @TypeOf(ctx), buf: []u8) ?[]const u8 {
            var stream = std.io.fixedBufferStream(buf);
            write(c, stream.writer()) catch return null;
            return stream.getWritten();
        }
    };
    return serializeAlloc(allocator, initial_size, ctx, Wrap.toJson);
}

pub fn writeJsonString(writer: anytype, s: []const u8) !void {
    // Transcode from system code page to UTF-8 (no-op on non-Windows / pure ASCII).
    // Keep buffer ≤1KB — this runs in timer callbacks with deep call stacks (see ZIG_GUIDE §1).
    // 512 bytes covers realistic REAPER names (action/FX/track names are typically <256 bytes;
    // UTF-8 expansion of Windows-1252 is at most 2x for the 0x80-0x9F range, 1.5x typical).
    var utf8_buf: [512]u8 = undefined;
    const str = encoding.toUtf8(s, &utf8_buf) orelse s;

    // Whatever is still not UTF-8 (a string cut mid-character, or one that
    // could not be transcoded) is replaced, never sent: one invalid byte
    // makes a browser drop the whole connection.
    var i: usize = 0;
    while (i < str.len) {
        const c = str[i];
        if (c >= 0x80) {
            const n = std.unicode.utf8ByteSequenceLength(c) catch 0;
            if (n == 0 or i + n > str.len or !isValidSequence(str[i .. i + n])) {
                try writer.writeAll(utf8.replacement);
                i += 1;
                continue;
            }
            try writer.writeAll(str[i .. i + n]);
            i += n;
            continue;
        }
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
        i += 1;
    }
}

/// A complete, well-formed sequence (no overlong forms, surrogates or
/// code points past U+10FFFF).
fn isValidSequence(seq: []const u8) bool {
    _ = std.unicode.utf8Decode(seq) catch return false;
    return true;
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
        // Elsewhere REAPER strings are UTF-8 already; an invalid byte is
        // replaced rather than sent, so the frame stays valid UTF-8.
        try std.testing.expectEqualStrings("Caf\u{FFFD}", output);
    }
}

test "writeJsonString never emits invalid UTF-8" {
    const inputs = [_][]const u8{
        "\u{E9}" ** 63 ++ "\xC3", // cut inside a character
        "tail \xF0\x9F", // cut inside an emoji
        "lone \x80 continuation",
        "bad lead \xFF here",
        "CESU-8 \xED\xA0\xBC\xED\xBE\xA4", // surrogates encoded as UTF-8
        "fine \u{1F3A4} \u{3042}",
    };
    for (inputs) |input| {
        var buf: [512]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        try writeJsonString(stream.writer(), input);
        try std.testing.expect(std.unicode.utf8ValidateSlice(stream.getWritten()));
    }
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeJsonString(stream.writer(), "ok \u{1F3A4}\"");
    try std.testing.expectEqualStrings("ok \u{1F3A4}\\\"", stream.getWritten());
}

test "jsonGetTextAlloc returns the whole name unescaped" {
    const long = "Estribillo \\\"final\\\" \\\\ versi\u{F3}n ac\u{FA}stica, guitarra y voz principal, \u{A1}\u{FA}ltima!";
    const json = "{\"name\":\"" ++ long ++ "\",\"color\":0}";
    const text = (try jsonGetTextAlloc(json, "name", std.testing.allocator)).?;
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("Estribillo \"final\" \\ versi\u{F3}n ac\u{FA}stica, guitarra y voz principal, \u{A1}\u{FA}ltima!", text);
    try std.testing.expect((try jsonGetTextAlloc(json, "missing", std.testing.allocator)) == null);
}

test "jsonGetStringUnescaped decodes surrogate pairs to one character" {
    var buf: [64]u8 = undefined;
    const r = jsonGetStringUnescaped("{\"name\":\"mic \\uD83C\\uDFA4\"}", "name", &buf).?;
    try std.testing.expectEqualStrings("mic \u{1F3A4}", r);
}

test "jsonGetStringUnescaped replaces lone surrogates" {
    var buf: [64]u8 = undefined;
    const r = jsonGetStringUnescaped("{\"name\":\"a\\uD83Cb\\uDFA4c\"}", "name", &buf).?;
    try std.testing.expectEqualStrings("a\u{FFFD}b\u{FFFD}c", r);
}

test "jsonGetStringUnescaped decodes backspace and form feed" {
    var buf: [64]u8 = undefined;
    const r = jsonGetStringUnescaped("{\"name\":\"A\\bB\\fC\"}", "name", &buf).?;
    try std.testing.expectEqualStrings("A\x08B\x0CC", r);
}

test "jsonGetStringUnescaped stops on a character boundary when the buffer is full" {
    var buf: [5]u8 = undefined;
    // Raw UTF-8, as browsers send it: "ab" + 3-byte char + "c" does not fit in 5.
    try std.testing.expectEqualStrings("ab\u{3042}", jsonGetStringUnescaped("{\"n\":\"ab\u{3042}\u{3042}\"}", "n", &buf).?);
    var small: [3]u8 = undefined;
    try std.testing.expectEqualStrings("ab", jsonGetStringUnescaped("{\"n\":\"ab\u{3042}\"}", "n", &small).?);
    // An escape whose encoding does not fit is dropped, not split.
    try std.testing.expectEqualStrings("ab", jsonGetStringUnescaped("{\"n\":\"ab\\u3042\"}", "n", &small).?);
    var four: [4]u8 = undefined;
    try std.testing.expectEqualStrings("ab", jsonGetStringUnescaped("{\"n\":\"ab\\uD83C\\uDFA4\"}", "n", &four).?);
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

test "getFlag reads booleans and 0/1 alike" {
    const msg = CommandMessage{ .command = "track/setInput", .raw = "{\"stereo\":true,\"multi\":0,\"rearoute\":1,\"wrap\":false}" };
    try std.testing.expectEqual(@as(?bool, true), msg.getFlag("stereo"));
    try std.testing.expectEqual(@as(?bool, false), msg.getFlag("multi"));
    try std.testing.expectEqual(@as(?bool, true), msg.getFlag("rearoute"));
    try std.testing.expectEqual(@as(?bool, false), msg.getFlag("wrap"));
    try std.testing.expectEqual(@as(?bool, null), msg.getFlag("missing"));
}

test "string parameters must be JSON strings" {
    // A value of another type is absent, never the next quoted text.
    try std.testing.expect(jsonGetString("{\"name\":[\"a\"]}", "name") == null);
    var buf: [16]u8 = undefined;
    try std.testing.expect(jsonGetStringUnescaped("{\"name\":[\"a\"]}", "name", &buf) == null);
    try std.testing.expect(jsonGetStringUnescaped("{\"name\":{\"x\":\"y\"}}", "name", &buf) == null);
    try std.testing.expect(jsonGetString("{\"name\":{\"x\":\"y\"}}", "name") == null);
    try std.testing.expect(jsonGetString("{\"name\":3,\"color\":\"red\"}", "name") == null);
    try std.testing.expectEqualStrings("Verse", jsonGetString("{\"name\": \"Verse\"}", "name").?);
    // A marker command fired without a request id: its numeric marker id is
    // not a request id.
    const marker_update = CommandMessage{ .command = "marker/update", .raw = "{\"type\":\"command\",\"command\":\"marker/update\",\"id\":3,\"name\":\"Verse\"}" };
    try std.testing.expect(marker_update.getId() == null);
    try std.testing.expectEqual(@as(?c_int, 3), marker_update.getInt("id"));
}

test "integer parameters must be whole numbers in range" {
    try std.testing.expect(jsonGetInt("{\"cc\":1.5}", "cc") == null);
    try std.testing.expect(jsonGetInt("{\"commandId\":1e30}", "commandId") == null);
    try std.testing.expect(jsonGetInt("{\"commandId\":99999999999}", "commandId") == null);
    try std.testing.expect(jsonGetInt("{\"cc\":\"7\"}", "cc") == null);
    try std.testing.expectEqual(@as(?c_int, -12), jsonGetInt("{\"bar\": -12 }", "bar"));
    try std.testing.expectEqual(@as(?c_int, 40364), jsonGetInt("{\"commandId\":40364,\"sectionId\":0}", "commandId"));
    try std.testing.expectEqual(@as(?c_int, 4), jsonGetInt("[{\"n\":4}]", "n"));
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

test "jsonGetIntArray returns null for non-integer elements instead of looping forever" {
    // Each of these once spun REAPER's main thread forever: the scanner never
    // advanced past a byte that was not whitespace, a comma, '-' or a digit.
    const malformed = [_][]const u8{
        "{\"indices\":[1,x]}",
        "{\"indices\":[1.5]}",
        "{\"indices\":[true]}",
        "{\"indices\":[null]}",
        "{\"indices\":[\"0\"]}",
        "{\"indices\":[-]}",
        "{\"indices\":[1 2]}",
    };
    var values: [10]c_int = undefined;
    for (malformed) |data| {
        try std.testing.expectEqual(@as(?usize, null), jsonGetIntArray(data, "indices", 10, &values));
    }
}

test "jsonGetIntArray accepts CRLF whitespace between elements" {
    const data = "{\"indices\":[\r\n1,\r\n2\r\n]}";
    var values: [10]c_int = undefined;
    const count = jsonGetIntArray(data, "indices", 10, &values).?;
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(c_int, 2), values[1]);
}

test "writeAlloc grows the buffer until the writer's output fits" {
    const write = struct {
        fn f(n: usize, w: anytype) !void {
            for (0..n) |_| try w.writeAll("0123456789");
        }
    }.f;
    const out = try writeAlloc(std.testing.allocator, 16, @as(usize, 5000), write);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, 50_000), out.len);
}

test "serializeAlloc grows past a too-small estimate and reclaims failed attempts" {
    const Payload = struct {
        len: usize,
        fn toJson(self: *const @This(), buf: []u8) ?[]const u8 {
            if (buf.len < self.len) return null;
            @memset(buf[0..self.len], 'x');
            return buf[0..self.len];
        }
    };
    var backing: [64 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    const payload = Payload{ .len = 10_000 };
    const out = try serializeAlloc(fba.allocator(), 1, &payload, Payload.toJson);
    try std.testing.expectEqual(@as(usize, 10_000), out.len);
    // 256 -> ... -> 16384, then shrunk to the JSON: nothing else stays allocated.
    try std.testing.expectEqual(@as(usize, 10_000), fba.end_index);

    // The result is an allocation of its own, freeable by a general allocator.
    const owned = try serializeAlloc(std.testing.allocator, 1, &payload, Payload.toJson);
    std.testing.allocator.free(owned);

    // An allocator that can't hold the payload is an error, not a silent drop.
    var small: [4096]u8 = undefined;
    var small_fba = std.heap.FixedBufferAllocator.init(&small);
    try std.testing.expectError(error.OutOfMemory, serializeAlloc(small_fba.allocator(), 1, &payload, Payload.toJson));
}
