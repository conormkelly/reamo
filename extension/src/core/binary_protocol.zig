/// Binary WebSocket protocol definitions.
///
/// All binary WebSocket frames start with a 1-byte type discriminator:
///   0x01 = Audio PCM frame
///   0x02 = Peaks tile batch
///
/// This allows the client to route binary frames to the correct handler
/// without parsing the full payload.
const std = @import("std");

// ── Message Types ────────────────────────────────────────────────────

pub const BinaryMessageType = enum(u8) {
    audio = 0x01,
    peaks = 0x02,
};

// ── Peaks Tile Binary Format ─────────────────────────────────────────
//
// Batch envelope (4 bytes):
//   u8   message_type = 0x02 (peaks)
//   u8   reserved = 0
//   u16  tile_count (LE)
//
// Per-tile:
//   Header (20 bytes):
//     u8   lod_level (0-7)
//     u8   channels (1 or 2)
//     u16  tile_index (LE)
//     u16  num_peaks (LE, typically 256)
//     u16  reserved = 0
//     u32  epoch (LE)
//     f32  start_time (LE) — tile start in project time
//     f32  item_position (LE) — item start in project time
//
//   GUID (40 bytes):
//     [40]u8 take_guid (null-padded, fixed size)
//
//   Peak data (num_peaks * channels * 2 bytes):
//     Per peak per channel: i8 min, i8 max
//     Stereo: [L_min, L_max, R_min, R_max] per peak
//     Mono: [min, max] per peak

pub const BATCH_ENVELOPE_SIZE = 4;
pub const TILE_HEADER_SIZE = 20;
pub const GUID_SIZE = 40;
pub const TILE_FIXED_SIZE = TILE_HEADER_SIZE + GUID_SIZE; // 60 bytes before peak data
pub const MAX_PEAKS_PER_TILE = 256;

/// Batch envelope — prefixes every peaks binary message.
pub const BatchEnvelope = extern struct {
    message_type: u8 = @intFromEnum(BinaryMessageType.peaks),
    reserved: u8 = 0,
    tile_count: u16 align(1) = 0,
};

/// Per-tile header — follows batch envelope, one per tile.
pub const TileHeader = extern struct {
    lod_level: u8 = 0,
    channels: u8 = 0,
    tile_index: u16 align(1) = 0,
    num_peaks: u16 align(1) = 0,
    reserved: u16 align(1) = 0,
    epoch: u32 align(1) = 0,
    start_time: f32 align(1) = 0.0,
    item_position: f32 align(1) = 0.0,
};

comptime {
    // Verify struct sizes match the wire format
    std.debug.assert(@sizeOf(BatchEnvelope) == BATCH_ENVELOPE_SIZE);
    std.debug.assert(@sizeOf(TileHeader) == TILE_HEADER_SIZE);
}

// ── Quantization ─────────────────────────────────────────────────────

/// Quantize a normalized f64 peak value (-1.0 to 1.0) to i8 (-128 to 127).
/// 256 levels maps ~1:1 to pixel resolution on a 100-300px waveform display.
pub inline fn quantize(value: f64) i8 {
    const scaled = value * 127.0;
    const rounded = @round(scaled);
    const clamped = std.math.clamp(rounded, -128.0, 127.0);
    return @intFromFloat(clamped);
}

/// Write batch envelope to buffer. Returns bytes written (always 4).
pub fn writeBatchEnvelope(buf: []u8, tile_count: u16) usize {
    std.debug.assert(buf.len >= BATCH_ENVELOPE_SIZE);
    const envelope = BatchEnvelope{
        .tile_count = tile_count,
    };
    const bytes: *const [BATCH_ENVELOPE_SIZE]u8 = @ptrCast(&envelope);
    @memcpy(buf[0..BATCH_ENVELOPE_SIZE], bytes);
    return BATCH_ENVELOPE_SIZE;
}

/// Write tile header to buffer. Returns bytes written (always 20).
pub fn writeTileHeader(buf: []u8, header: TileHeader) usize {
    std.debug.assert(buf.len >= TILE_HEADER_SIZE);
    const bytes: *const [TILE_HEADER_SIZE]u8 = @ptrCast(&header);
    @memcpy(buf[0..TILE_HEADER_SIZE], bytes);
    return TILE_HEADER_SIZE;
}

/// Write null-padded GUID to buffer. Returns bytes written (always 40).
pub fn writeGuid(buf: []u8, guid: []const u8) usize {
    std.debug.assert(buf.len >= GUID_SIZE);
    const copy_len = @min(guid.len, GUID_SIZE);
    @memcpy(buf[0..copy_len], guid[0..copy_len]);
    // Zero-pad remainder
    if (copy_len < GUID_SIZE) {
        @memset(buf[copy_len..GUID_SIZE], 0);
    }
    return GUID_SIZE;
}

/// Calculate the total buffer size needed for a peaks batch.
pub fn batchBufferSize(tile_count: usize, peaks_per_tile: usize, max_channels: usize) usize {
    const peak_data_size = peaks_per_tile * max_channels * 2; // i8 min + i8 max per channel
    return BATCH_ENVELOPE_SIZE + tile_count * (TILE_FIXED_SIZE + peak_data_size);
}

// ── Tests ────────────────────────────────────────────────────────────

test "quantize" {
    const testing = std.testing;

    // Zero
    try testing.expectEqual(@as(i8, 0), quantize(0.0));

    // Full scale
    try testing.expectEqual(@as(i8, 127), quantize(1.0));
    try testing.expectEqual(@as(i8, -127), quantize(-1.0));

    // Clamp beyond range
    try testing.expectEqual(@as(i8, 127), quantize(1.5));
    try testing.expectEqual(@as(i8, -128), quantize(-1.5));

    // Mid-range
    try testing.expectEqual(@as(i8, 64), quantize(0.5039)); // round(0.5039 * 127) = round(64.0) = 64
    try testing.expectEqual(@as(i8, -64), quantize(-0.5039));
}

test "batch envelope encoding" {
    var buf: [4]u8 = undefined;
    _ = writeBatchEnvelope(&buf, 42);

    try std.testing.expectEqual(@as(u8, 0x02), buf[0]); // message_type
    try std.testing.expectEqual(@as(u8, 0), buf[1]); // reserved
    // tile_count = 42 in LE
    try std.testing.expectEqual(@as(u8, 42), buf[2]);
    try std.testing.expectEqual(@as(u8, 0), buf[3]);
}

test "tile header encoding" {
    var buf: [20]u8 = undefined;
    _ = writeTileHeader(&buf, .{
        .lod_level = 5,
        .channels = 2,
        .tile_index = 12,
        .num_peaks = 256,
        .epoch = 0xDEAD,
        .start_time = 48.0,
        .item_position = 0.0,
    });

    try std.testing.expectEqual(@as(u8, 5), buf[0]); // lod
    try std.testing.expectEqual(@as(u8, 2), buf[1]); // channels
    try std.testing.expectEqual(@as(u8, 12), buf[2]); // tile_index low byte
}

test "guid encoding" {
    var buf: [40]u8 = undefined;
    const guid = "{3FE16829-1D59-BC43-B24B-D41CA5ECF1AC}";
    _ = writeGuid(&buf, guid);

    try std.testing.expectEqualStrings(guid, buf[0..guid.len]);
    // Rest should be zero-padded
    try std.testing.expectEqual(@as(u8, 0), buf[guid.len]);
}
