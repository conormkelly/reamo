//! Reads a WAV file's samples, for running the tuner's analyser over
//! recordings offline (wav_tool.zig).
//!
//! RIFF/WAVE with PCM integer samples of 8, 16, 24 or 32 bits, or IEEE
//! float of 32 or 64 bits, plain or WAVE_FORMAT_EXTENSIBLE, any number of
//! channels. Other chunks are skipped. Pure: it reads from the bytes it is
//! given and allocates nothing.
const std = @import("std");

pub const Error = error{ NotWave, NoFormat, NoData, Unsupported, Truncated };

pub const Encoding = enum { int, float };

pub const Wav = struct {
    sample_rate: u32,
    channels: u16,
    bits: u16,
    encoding: Encoding,
    /// The interleaved sample bytes.
    data: []const u8,

    pub fn frames(self: Wav) usize {
        return self.data.len / self.frameBytes();
    }

    fn frameBytes(self: Wav) usize {
        return @as(usize, self.channels) * (self.bits / 8);
    }

    /// Sample `channel` of frame `frame`, scaled to -1 .. 1.
    pub fn sample(self: Wav, frame: usize, channel: usize) f32 {
        const width = self.bits / 8;
        const at = frame * self.frameBytes() + channel * width;
        const b = self.data[at .. at + width];
        return switch (self.encoding) {
            .float => if (self.bits == 32)
                @bitCast(std.mem.readInt(u32, b[0..4], .little))
            else
                @floatCast(@as(f64, @bitCast(std.mem.readInt(u64, b[0..8], .little)))),
            .int => switch (self.bits) {
                8 => (@as(f32, @floatFromInt(b[0])) - 128) / 128,
                16 => @as(f32, @floatFromInt(std.mem.readInt(i16, b[0..2], .little))) / 32768,
                24 => @as(f32, @floatFromInt(std.mem.readInt(i24, b[0..3], .little))) / 8388608,
                32 => @floatCast(@as(f64, @floatFromInt(std.mem.readInt(i32, b[0..4], .little))) / 2147483648),
                else => unreachable,
            },
        };
    }

    /// Frame `frame` as one mono sample: channel `channel`, or the mean of
    /// every channel when null.
    pub fn mono(self: Wav, frame: usize, channel: ?usize) f32 {
        if (channel) |c| return self.sample(frame, c);
        var sum: f32 = 0;
        for (0..self.channels) |c| sum += self.sample(frame, c);
        return sum / @as(f32, @floatFromInt(self.channels));
    }
};

const format_pcm = 1;
const format_float = 3;
const format_extensible = 0xFFFE;

pub fn parse(bytes: []const u8) Error!Wav {
    if (bytes.len < 12 or !std.mem.eql(u8, bytes[0..4], "RIFF") or !std.mem.eql(u8, bytes[8..12], "WAVE")) return error.NotWave;
    var at: usize = 12;
    var fmt: ?struct { tag: u16, channels: u16, rate: u32, bits: u16 } = null;
    var data: ?[]const u8 = null;
    while (at + 8 <= bytes.len) {
        const id = bytes[at .. at + 4];
        const size: usize = std.mem.readInt(u32, bytes[at + 4 ..][0..4], .little);
        const body_at = at + 8;
        // A data chunk may claim more than the file holds (a recorder that
        // stopped early); take what is there.
        const body = bytes[body_at..@min(bytes.len, body_at + size)];
        if (std.mem.eql(u8, id, "fmt ")) {
            if (body.len < 16) return error.Truncated;
            var tag = std.mem.readInt(u16, body[0..2], .little);
            if (tag == format_extensible) {
                if (body.len < 26) return error.Truncated;
                // The sub-format GUID starts with the format tag.
                tag = std.mem.readInt(u16, body[24..26], .little);
            }
            fmt = .{
                .tag = tag,
                .channels = std.mem.readInt(u16, body[2..4], .little),
                .rate = std.mem.readInt(u32, body[4..8], .little),
                .bits = std.mem.readInt(u16, body[14..16], .little),
            };
        } else if (std.mem.eql(u8, id, "data")) {
            data = body;
        }
        // Chunks are padded to an even length.
        at = body_at + size + (size & 1);
    }
    const f = fmt orelse return error.NoFormat;
    const d = data orelse return error.NoData;
    if (f.channels == 0 or f.rate == 0) return error.Unsupported;
    const encoding: Encoding = switch (f.tag) {
        format_pcm => blk: {
            if (f.bits != 8 and f.bits != 16 and f.bits != 24 and f.bits != 32) return error.Unsupported;
            break :blk .int;
        },
        format_float => blk: {
            if (f.bits != 32 and f.bits != 64) return error.Unsupported;
            break :blk .float;
        },
        else => return error.Unsupported,
    };
    return .{ .sample_rate = f.rate, .channels = f.channels, .bits = f.bits, .encoding = encoding, .data = d };
}

// =============================================================================
// Tests

const testing = std.testing;

/// A WAV file in `buf`: the header for the format, then `payload`.
fn build(buf: []u8, tag: u16, channels: u16, rate: u32, bits: u16, payload: []const u8, extensible: bool) []u8 {
    var w: std.Io.Writer = .fixed(buf);
    const fmt_size: u32 = if (extensible) 40 else 16;
    w.writeAll("RIFF") catch unreachable;
    w.writeInt(u32, @intCast(4 + 8 + fmt_size + 8 + 8 + payload.len), .little) catch unreachable;
    w.writeAll("WAVE") catch unreachable;
    // A chunk to skip, of odd length.
    w.writeAll("LIST") catch unreachable;
    w.writeInt(u32, 3, .little) catch unreachable;
    w.writeAll("abc\x00") catch unreachable;
    w.writeAll("fmt ") catch unreachable;
    w.writeInt(u32, fmt_size, .little) catch unreachable;
    w.writeInt(u16, if (extensible) format_extensible else tag, .little) catch unreachable;
    w.writeInt(u16, channels, .little) catch unreachable;
    w.writeInt(u32, rate, .little) catch unreachable;
    w.writeInt(u32, rate * channels * (bits / 8), .little) catch unreachable;
    w.writeInt(u16, channels * (bits / 8), .little) catch unreachable;
    w.writeInt(u16, bits, .little) catch unreachable;
    if (extensible) {
        w.writeInt(u16, 22, .little) catch unreachable;
        w.writeInt(u16, bits, .little) catch unreachable;
        w.writeInt(u32, 0, .little) catch unreachable;
        w.writeInt(u16, tag, .little) catch unreachable;
        w.writeAll("\x00\x00\x00\x00\x10\x00\x80\x00\x00\xaa\x00\x38\x9b\x71") catch unreachable;
    }
    w.writeAll("data") catch unreachable;
    w.writeInt(u32, @intCast(payload.len), .little) catch unreachable;
    w.writeAll(payload) catch unreachable;
    return w.buffered();
}

test "reads 16-bit stereo PCM, by channel and as a mix" {
    var buf: [256]u8 = undefined;
    // Frames (16384, -16384) and (-32768, 32767).
    const payload = [_]u8{ 0x00, 0x40, 0x00, 0xC0, 0x00, 0x80, 0xFF, 0x7F };
    const wav = try parse(build(&buf, format_pcm, 2, 44100, 16, &payload, false));
    try testing.expectEqual(@as(u32, 44100), wav.sample_rate);
    try testing.expectEqual(@as(usize, 2), wav.frames());
    try testing.expectEqual(@as(f32, 0.5), wav.mono(0, 0));
    try testing.expectEqual(@as(f32, -0.5), wav.mono(0, 1));
    try testing.expectEqual(@as(f32, 0), wav.mono(0, null));
    try testing.expectEqual(@as(f32, -1), wav.sample(1, 0));
}

test "reads 24-bit PCM through WAVE_FORMAT_EXTENSIBLE" {
    var buf: [256]u8 = undefined;
    // 0x400000 = half scale, then -0x400000.
    const payload = [_]u8{ 0x00, 0x00, 0x40, 0x00, 0x00, 0xC0 };
    const wav = try parse(build(&buf, format_pcm, 1, 48000, 24, &payload, true));
    try testing.expectEqual(@as(usize, 2), wav.frames());
    try testing.expectEqual(@as(f32, 0.5), wav.mono(0, null));
    try testing.expectEqual(@as(f32, -0.5), wav.mono(1, null));
}

test "reads 32-bit float and 32-bit integer PCM" {
    var buf: [256]u8 = undefined;
    var payload: [8]u8 = undefined;
    std.mem.writeInt(u32, payload[0..4], @bitCast(@as(f32, 0.25)), .little);
    std.mem.writeInt(u32, payload[4..8], @bitCast(@as(f32, -0.75)), .little);
    const wav = try parse(build(&buf, format_float, 1, 96000, 32, &payload, false));
    try testing.expectEqual(@as(f32, 0.25), wav.mono(0, null));
    try testing.expectEqual(@as(f32, -0.75), wav.mono(1, null));
    std.mem.writeInt(i32, payload[0..4], -1073741824, .little);
    const int32 = try parse(build(&buf, format_pcm, 1, 96000, 32, payload[0..4], false));
    try testing.expectEqual(@as(f32, -0.5), int32.mono(0, null));
}

test "refuses what isn't a WAV it can read" {
    var buf: [256]u8 = undefined;
    try testing.expectError(error.NotWave, parse("RIFX\x00\x00\x00\x00WAVE"));
    try testing.expectError(error.Unsupported, parse(build(&buf, 2, 1, 44100, 16, &.{ 0, 0 }, false)));
    try testing.expectError(error.Unsupported, parse(build(&buf, format_pcm, 1, 44100, 12, &.{ 0, 0 }, false)));
    try testing.expectError(error.NoData, parse("RIFF\x00\x00\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00\x01\x00\x44\xac\x00\x00\x88\x58\x01\x00\x02\x00\x10\x00"));
}
