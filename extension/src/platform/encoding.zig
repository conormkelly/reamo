/// Cross-platform string encoding.
///
/// REAPER's C API returns strings in the system's local code page on Windows
/// (e.g., Windows-1252 for Western European locales). macOS and Linux use UTF-8
/// natively, so no transcoding is needed there.
///
/// This module provides `toUtf8()` which transcodes from the active code page
/// to UTF-8 on Windows (via MultiByteToWideChar → WideCharToMultiByte), and
/// is a no-op passthrough on other platforms.

const std = @import("std");
const builtin = @import("builtin");

/// Transcode a string from the system's active code page to UTF-8.
///
/// On Windows: uses Win32 APIs to convert ACP → UTF-16 → UTF-8.
/// On other platforms: returns the input unchanged (already UTF-8).
///
/// Returns `null` if the transcoding fails (e.g., buffer too small).
/// Callers should fall back to the original string or use a replacement strategy.
pub fn toUtf8(input: []const u8, buf: []u8) ?[]const u8 {
    if (comptime builtin.os.tag != .windows) {
        return input;
    }

    if (input.len == 0) return input;

    // Quick check: if all bytes are ASCII (< 0x80), no transcoding needed.
    var needs_transcode = false;
    for (input) |b| {
        if (b >= 0x80) {
            needs_transcode = true;
            break;
        }
    }
    if (!needs_transcode) return input;

    // Step 1: ACP → UTF-16 (query required size first)
    const CP_ACP = 0;
    const CP_UTF8 = 65001;

    const input_len: c_int = if (input.len <= std.math.maxInt(c_int))
        @intCast(input.len)
    else
        return null;

    // Query UTF-16 buffer size needed
    const wide_len = win32.MultiByteToWideChar(CP_ACP, 0, input.ptr, input_len, null, 0);
    if (wide_len <= 0) return null;

    // Use stack buffer for the intermediate UTF-16 representation.
    // 256 wide chars = 512 bytes on stack — keeps total stack usage ≤1KB
    // (see ZIG_GUIDE §1: timer callbacks have deep call stacks).
    // Covers any realistic REAPER string (names are typically <256 bytes).
    var wide_buf: [256]u16 = undefined;
    if (wide_len > wide_buf.len) return null;

    const wide_written = win32.MultiByteToWideChar(
        CP_ACP,
        0,
        input.ptr,
        input_len,
        &wide_buf,
        @intCast(wide_buf.len),
    );
    if (wide_written <= 0) return null;

    // Step 2: UTF-16 → UTF-8
    if (buf.len == 0) return null;

    const buf_len: c_int = if (buf.len <= std.math.maxInt(c_int))
        @intCast(buf.len)
    else
        return null;

    const utf8_len = win32.WideCharToMultiByte(
        CP_UTF8,
        0,
        &wide_buf,
        wide_written,
        buf.ptr,
        buf_len,
        null,
        null,
    );
    if (utf8_len <= 0) return null;

    return buf[0..@intCast(utf8_len)];
}

const win32 = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn MultiByteToWideChar(
        CodePage: c_uint,
        dwFlags: u32,
        lpMultiByteStr: [*]const u8,
        cbMultiByte: c_int,
        lpWideCharStr: ?[*]u16,
        cchWideChar: c_int,
    ) callconv(.winapi) c_int;

    extern "kernel32" fn WideCharToMultiByte(
        CodePage: c_uint,
        dwFlags: u32,
        lpWideCharStr: [*]const u16,
        cchWideChar: c_int,
        lpMultiByteStr: ?[*]u8,
        cbMultiByte: c_int,
        lpDefaultChar: ?*const u8,
        lpUsedDefaultChar: ?*c_int,
    ) callconv(.winapi) c_int;
} else struct {};

// ============================================================================
// Tests
// ============================================================================

test "toUtf8 passes through empty string" {
    var buf: [64]u8 = undefined;
    const result = toUtf8("", &buf);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("", result.?);
}

test "toUtf8 passes through ASCII" {
    var buf: [64]u8 = undefined;
    const result = toUtf8("Hello World", &buf);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("Hello World", result.?);
}

test "toUtf8 passes through ASCII with special chars" {
    var buf: [64]u8 = undefined;
    const result = toUtf8("Track 1 (Main) - FX #2", &buf);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("Track 1 (Main) - FX #2", result.?);
}

test "toUtf8 returns null for buffer too small" {
    if (comptime builtin.os.tag != .windows) return;
    var buf: [0]u8 = undefined;
    const result = toUtf8(&[_]u8{0xE9}, &buf); // é in Windows-1252
    try std.testing.expect(result == null);
}

// ---------------------------------------------------------------------------
// Windows-only tests: demonstrate the actual code-page transcoding
// These prove that raw Windows-1252 bytes (what REAPER's C API returns) get
// converted to valid UTF-8 (what WebSocket text frames require).
// ---------------------------------------------------------------------------

fn isValidUtf8(bytes: []const u8) bool {
    var i: usize = 0;
    while (i < bytes.len) {
        const b = bytes[i];
        const seq_len: usize = if (b < 0x80) 1 else if (b < 0xC0) return false // unexpected continuation
        else if (b < 0xE0) 2 else if (b < 0xF0) 3 else if (b < 0xF8) 4 else return false;
        if (i + seq_len > bytes.len) return false;
        for (bytes[i + 1 .. i + seq_len]) |cont| {
            if (cont & 0xC0 != 0x80) return false;
        }
        i += seq_len;
    }
    return true;
}

test "BUG DEMO: raw Windows-1252 bytes are NOT valid UTF-8" {
    // This is what REAPER hands us on Windows for "Café" — the é is 0xE9,
    // a single byte that is valid in Windows-1252 but NOT a valid UTF-8 sequence.
    // Without the fix, this goes straight into a WebSocket text frame and the
    // browser kills the connection with "Could not decode a text frame as UTF-8".
    const raw_windows_1252 = "Caf\xe9";
    try std.testing.expect(!isValidUtf8(raw_windows_1252));

    // More examples from real REAPER sessions:
    const raw_umlaut = "Sm\xf6rg\xe5sbord"; // ö=0xF6, å=0xE5
    try std.testing.expect(!isValidUtf8(raw_umlaut));

    const raw_diaeresis = "\xeb"; // ë = 0xEB (the character from the issue)
    try std.testing.expect(!isValidUtf8(raw_diaeresis));
}

test "FIX: toUtf8 transcodes Windows-1252 bytes to valid UTF-8" {
    if (comptime builtin.os.tag != .windows) return;

    var buf: [64]u8 = undefined;

    // é: Windows-1252 0xE9 → UTF-8 0xC3 0xA9
    const cafe = toUtf8("Caf\xe9", &buf);
    try std.testing.expect(cafe != null);
    try std.testing.expect(isValidUtf8(cafe.?));
    try std.testing.expectEqualStrings("Caf\xc3\xa9", cafe.?); // UTF-8 for "Café"

    // ë: Windows-1252 0xEB → UTF-8 0xC3 0xAB (the character from issue #29)
    const diaeresis_e = toUtf8(&[_]u8{0xEB}, &buf);
    try std.testing.expect(diaeresis_e != null);
    try std.testing.expect(isValidUtf8(diaeresis_e.?));
    try std.testing.expectEqualStrings("\xc3\xab", diaeresis_e.?); // UTF-8 for ë

    // ö and å: Windows-1252 0xF6/0xE5 → UTF-8 multi-byte
    const smorgasbord = toUtf8("Sm\xf6rg\xe5sbord", &buf);
    try std.testing.expect(smorgasbord != null);
    try std.testing.expect(isValidUtf8(smorgasbord.?));
    try std.testing.expectEqualStrings("Sm\xc3\xb6rg\xc3\xa5sbord", smorgasbord.?); // UTF-8 for "Smörgåsbord"
}

test "FIX: toUtf8 handles mixed ASCII and non-ASCII" {
    if (comptime builtin.os.tag != .windows) return;

    var buf: [256]u8 = undefined;

    // Simulate a typical REAPER FX name with accented characters
    const fx_name = toUtf8("ReaComp (Caf\xe9 Preset) [stereo]", &buf);
    try std.testing.expect(fx_name != null);
    try std.testing.expect(isValidUtf8(fx_name.?));
    try std.testing.expectEqualStrings("ReaComp (Caf\xc3\xa9 Preset) [stereo]", fx_name.?); // UTF-8 for "Café"
}

test "FIX: toUtf8 handles Windows-1252 special range 0x80-0x9F" {
    if (comptime builtin.os.tag != .windows) return;

    var buf: [64]u8 = undefined;

    // Windows-1252 has characters in 0x80-0x9F that differ from Latin-1/ISO-8859-1.
    // 0x93 = left double quotation mark "
    // 0x94 = right double quotation mark "
    // 0x96 = en dash –
    const smart_quotes = toUtf8("\x93Hello\x94 \x96 World", &buf);
    try std.testing.expect(smart_quotes != null);
    try std.testing.expect(isValidUtf8(smart_quotes.?));
    // The exact UTF-8 output depends on the system code page, but it must be valid UTF-8.
}
