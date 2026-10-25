//! UTF-8 boundaries for strings that cross REAPER and the wire.
//!
//! Every name, note and description REAmo relays is UTF-8 (REAPER is UTF-8
//! on every platform), but buffers have fixed sizes. Cutting a string at an
//! arbitrary byte can split a multi-byte character, and one invalid byte in a
//! WebSocket text frame makes a browser close the connection (RFC 6455 8.1),
//! so every client would drop and reconnect for as long as that name exists.
//! These helpers truncate on character boundaries instead.

const std = @import("std");

/// Length of the sequence a lead byte starts, or null for a continuation or
/// invalid byte.
fn seqLen(lead: u8) ?usize {
    return std.unicode.utf8ByteSequenceLength(lead) catch null;
}

/// Drop an incomplete multi-byte sequence at the end of `s`, if any. Only the
/// tail is examined: invalid bytes elsewhere are left for the writer to
/// replace.
pub fn trimIncompleteTail(s: []const u8) []const u8 {
    // A sequence is at most 4 bytes, so its lead is within the last 4.
    var back: usize = 1;
    while (back <= 4 and back <= s.len) : (back += 1) {
        const b = s[s.len - back];
        if (b & 0xC0 == 0x80) continue; // continuation byte: keep looking for the lead
        const need = seqLen(b) orelse return s; // not a lead: nothing we can complete
        return if (need > back) s[0 .. s.len - back] else s;
    }
    return s;
}

/// The longest prefix of `s` that is at most `max_len` bytes and does not
/// end inside a character.
pub fn prefix(s: []const u8, max_len: usize) []const u8 {
    if (s.len <= max_len) return s;
    return trimIncompleteTail(s[0..max_len]);
}

/// `filled` is what REAPER wrote into a buffer of `cap` bytes (NUL included).
/// REAPER truncates byte-wise, so a string that filled the buffer may end
/// inside a character; drop that partial character.
pub fn trimTruncated(filled: []const u8, cap: usize) []const u8 {
    if (filled.len + 1 < cap) return filled;
    return trimIncompleteTail(filled);
}

/// Copy the longest boundary-safe prefix of `src` that fits in `dst`.
/// Returns the number of bytes copied.
pub fn copyPrefix(dst: []u8, src: []const u8) usize {
    const p = prefix(src, dst.len);
    @memcpy(dst[0..p.len], p);
    return p.len;
}

/// Encode `cp` as UTF-8 into `out`; returns the byte count, or null if it
/// does not fit or is not a scalar value (lone surrogate).
pub fn encode(cp: u21, out: []u8) ?usize {
    var tmp: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &tmp) catch return null;
    if (n > out.len) return null;
    @memcpy(out[0..n], tmp[0..n]);
    return n;
}

pub const replacement = "\u{FFFD}";

test "prefix never splits a character" {
    const s = "a\u{E9}\u{3042}\u{1F3A4}"; // 1 + 2 + 3 + 4 bytes
    try std.testing.expectEqualStrings("a", prefix(s, 1));
    try std.testing.expectEqualStrings("a", prefix(s, 2));
    try std.testing.expectEqualStrings("a\u{E9}", prefix(s, 3));
    try std.testing.expectEqualStrings("a\u{E9}", prefix(s, 5));
    try std.testing.expectEqualStrings("a\u{E9}\u{3042}", prefix(s, 6));
    try std.testing.expectEqualStrings("a\u{E9}\u{3042}", prefix(s, 9));
    try std.testing.expectEqualStrings(s, prefix(s, 10));
    try std.testing.expectEqualStrings(s, prefix(s, 100));
    for (0..s.len + 1) |n| try std.testing.expect(std.unicode.utf8ValidateSlice(prefix(s, n)));
}

test "trimTruncated only trims a buffer REAPER filled" {
    // "é" x 64 is 128 bytes; a 128-byte buffer holds 127 of them plus NUL.
    const full = "\u{E9}" ** 63 ++ "\xC3";
    try std.testing.expectEqual(@as(usize, 126), trimTruncated(full, 128).len);
    // A short string that happens to end in a lone lead byte is not ours to fix.
    try std.testing.expectEqualStrings("ab\xC3", trimTruncated("ab\xC3", 128));
}

test "trimIncompleteTail leaves complete and invalid tails alone" {
    try std.testing.expectEqualStrings("x\u{1F3A4}", trimIncompleteTail("x\u{1F3A4}"));
    try std.testing.expectEqualStrings("x", trimIncompleteTail("x\xF0\x9F\x8E"));
    try std.testing.expectEqualStrings("x", trimIncompleteTail("x\xF0"));
    try std.testing.expectEqualStrings("x\x80\x80\x80\x80", trimIncompleteTail("x\x80\x80\x80\x80"));
    try std.testing.expectEqualStrings("", trimIncompleteTail(""));
}

test "copyPrefix fits the destination on a boundary" {
    var dst: [5]u8 = undefined;
    const n = copyPrefix(&dst, "ab\u{3042}cd");
    try std.testing.expectEqualStrings("ab\u{3042}", dst[0..n]);
}
