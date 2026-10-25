/// bar.beat.ticks labels, matching REAPER's own measure display.
///
/// REAPER reports a position as (measure, beats_in_measure). Rounding the beat
/// to ticks (hundredths) can carry into the next bar: a position a hair before
/// a bar line (7.9999999 beats, routine at tempos like 140 BPM) must read as
/// the next bar's "N.1.00", never "beat 5.00" of a 4/4 bar. Negative
/// beats_in_measure (pre-roll before the project start) borrows from the
/// previous bar. Carry and borrow happen in integer ticks, after rounding.
const std = @import("std");
const ffi = @import("../core/ffi.zig");

pub const BarBeatTicks = struct {
    bar: c_int,
    beat: u32, // 1-based
    ticks: u32, // hundredths of a beat, 0..99
};

/// Round (measure, beats_in_measure) to a displayable bar.beat.ticks.
/// `beats_per_bar` is the time-signature numerator at the position.
/// Returns null for non-finite or absurd input (corrupt project data).
pub fn fromReaper(measure: c_int, beats_in_measure: f64, beats_per_bar: c_int) ?BarBeatTicks {
    const ticks_per_bar: i64 = @as(i64, @max(1, beats_per_bar)) * 100;
    const total: i64 = ffi.roundFloatToInt(i32, beats_in_measure * 100.0) catch return null;
    const bars_carried: i64 = @divFloor(total, ticks_per_bar);
    const in_bar: i64 = total - bars_carried * ticks_per_bar; // [0, ticks_per_bar)
    const bar = std.math.add(i64, measure, bars_carried) catch return null;
    return .{
        .bar = std.math.cast(c_int, bar) orelse return null,
        .beat = @intCast(@divFloor(in_bar, 100) + 1),
        .ticks = @intCast(@mod(in_bar, 100)),
    };
}

/// Write "bar.beat.ticks" (e.g. "12.3.45", "-4.1.00"), with `bar_offset`
/// (the project's start measure setting) applied to the bar.
pub fn write(w: anytype, measure: c_int, beats_in_measure: f64, beats_per_bar: c_int, bar_offset: c_int) !void {
    const bbt = fromReaper(measure, beats_in_measure, beats_per_bar) orelse return error.InvalidBeatValue;
    const display_bar = std.math.add(c_int, bbt.bar, bar_offset) catch return error.InvalidBeatValue;
    try w.print("{d}.{d}.{d:0>2}", .{ display_bar, bbt.beat, bbt.ticks });
}

// ============================================================================
// Tests
// ============================================================================

fn label(measure: c_int, beats_in_measure: f64, beats_per_bar: c_int, bar_offset: c_int) ![]const u8 {
    const S = struct {
        var buf: [32]u8 = undefined;
    };
    var stream = std.io.fixedBufferStream(&S.buf);
    try write(stream.writer(), measure, beats_in_measure, beats_per_bar, bar_offset);
    return stream.getWritten();
}

test "a position a hair before a bar line reads as the next bar, in any meter" {
    try std.testing.expectEqualStrings("3.1.00", try label(2, 3.9999999, 4, 0));
    try std.testing.expectEqualStrings("6.1.00", try label(5, 5.9999999, 6, 0));
    try std.testing.expectEqualStrings("13.1.00", try label(12, 6.9999999, 7, 0));
}

test "ordinary positions keep their beat and ticks" {
    try std.testing.expectEqualStrings("1.1.00", try label(1, 0.0, 4, 0));
    try std.testing.expectEqualStrings("1.3.50", try label(1, 2.5, 4, 0));
    try std.testing.expectEqualStrings("5.6.10", try label(5, 5.1, 6, 0));
    try std.testing.expectEqualStrings("1.4.99", try label(1, 3.994, 4, 0)); // rounds down, no carry
}

test "pre-roll (negative beats in measure) borrows from the previous bar" {
    try std.testing.expectEqualStrings("-2.4.50", try label(-1, -0.5, 4, 0));
    try std.testing.expectEqualStrings("0.1.00", try label(1, -4.0, 4, 0));
}

test "the project's start measure offset is applied to the bar" {
    try std.testing.expectEqualStrings("-4.1.00", try label(1, 0.0, 4, -5));
    try std.testing.expectEqualStrings("-2.1.00", try label(2, 3.9999999, 4, -5));
}

test "corrupt input is an error, not a trap" {
    try std.testing.expect(fromReaper(1, std.math.nan(f64), 4) == null);
    try std.testing.expect(fromReaper(1, std.math.inf(f64), 4) == null);
    try std.testing.expect(fromReaper(std.math.maxInt(c_int), 4.0, 4) == null);
    try std.testing.expectEqualStrings("1.1.00", try label(1, 0.0, 0, 0)); // invalid meter treated as 1 beat/bar
}
