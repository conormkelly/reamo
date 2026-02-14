/// QR Code rendering to BGRA pixel buffer.
///
/// Uses qrcodegen library to encode text, then scales and renders
/// to a fixed-size BGRA buffer suitable for StretchBltFromMem.
///
/// Pixel format: 0xAARRGGBB (BGRA little-endian)
/// - Black module: 0xFF000000
/// - White module: 0xFFFFFFFF

const std = @import("std");

const qr = @cImport({
    @cInclude("qrcodegen.h");
});

/// Errors that can occur during QR code rendering
pub const RenderError = error{
    /// The input text was too long to encode
    TextTooLong,
    /// The buffer size is invalid (must be > 0)
    InvalidBufferSize,
};

/// BGRA pixel colors
const COLOR_BLACK: u32 = 0xFF000000; // Opaque black (QR module)
const COLOR_WHITE: u32 = 0xFFFFFFFF; // Opaque white (background)

/// Quiet zone size in modules (QR spec recommends 4)
const QUIET_ZONE: usize = 4;

/// Render a QR code for the given text into a BGRA pixel buffer.
///
/// The QR code is centered in the buffer with a quiet zone (white border).
/// Each QR module is scaled to fill the available space.
///
/// Arguments:
///   text: Null-terminated UTF-8 text to encode
///   buffer: Output buffer for BGRA pixels (size * size elements)
///   size: Width/height of the square output buffer in pixels
///
/// Returns: The QR code size in modules (for debugging), or error
pub fn renderToBGRA(text: [*:0]const u8, buffer: []u32, size: usize) RenderError!usize {
    if (size == 0) return RenderError.InvalidBufferSize;

    // Buffers for qrcodegen (stack allocated, max ~4KB each)
    var temp_buffer: [qr.qrcodegen_BUFFER_LEN_MAX]u8 = undefined;
    var qrcode: [qr.qrcodegen_BUFFER_LEN_MAX]u8 = undefined;

    // Encode text to QR code
    // Use MEDIUM error correction (15% recovery) - good balance for phone scanning
    const ok = qr.qrcodegen_encodeText(
        text,
        &temp_buffer,
        &qrcode,
        qr.qrcodegen_Ecc_MEDIUM,
        qr.qrcodegen_VERSION_MIN,
        qr.qrcodegen_VERSION_MAX,
        qr.qrcodegen_Mask_AUTO,
        true, // boostEcl - upgrade ECC if it doesn't increase version
    );

    if (!ok) return RenderError.TextTooLong;

    // Get QR code dimensions
    const qr_size: usize = @intCast(qr.qrcodegen_getSize(&qrcode));

    // Calculate scaling: fit QR + quiet zone into output buffer
    const total_modules = qr_size + (QUIET_ZONE * 2);
    const scale = size / total_modules;
    if (scale == 0) {
        // Output too small to render - fill with white
        @memset(buffer[0..@min(buffer.len, size * size)], COLOR_WHITE);
        return qr_size;
    }

    // Calculate offset to center the QR code
    const rendered_size = total_modules * scale;
    const offset = (size - rendered_size) / 2;

    // Fill entire buffer with white (background + quiet zone)
    @memset(buffer[0..@min(buffer.len, size * size)], COLOR_WHITE);

    // Render QR modules
    for (0..qr_size) |qr_y| {
        for (0..qr_size) |qr_x| {
            const is_dark = qr.qrcodegen_getModule(
                &qrcode,
                @intCast(qr_x),
                @intCast(qr_y),
            );

            if (is_dark) {
                // Calculate pixel position (with quiet zone and centering offset)
                const px_x = offset + (QUIET_ZONE + qr_x) * scale;
                const px_y = offset + (QUIET_ZONE + qr_y) * scale;

                // Fill the scaled module rectangle
                for (0..scale) |dy| {
                    for (0..scale) |dx| {
                        const x = px_x + dx;
                        const y = px_y + dy;
                        if (x < size and y < size) {
                            buffer[y * size + x] = COLOR_BLACK;
                        }
                    }
                }
            }
        }
    }

    return qr_size;
}

/// Convenience wrapper that takes a Zig slice instead of C pointer
pub fn renderSliceToBGRA(text: [:0]const u8, buffer: []u32, size: usize) RenderError!usize {
    return renderToBGRA(text.ptr, buffer, size);
}

// =============================================================================
// Tests
// =============================================================================

test "render simple URL" {
    var buffer: [100 * 100]u32 = undefined;
    const qr_size = try renderSliceToBGRA("http://192.168.1.50:9224/", &buffer, 100);

    // URL of this length should produce a version 3-4 QR code (29-33 modules)
    try std.testing.expect(qr_size >= 21 and qr_size <= 41);

    // Check corners are white (quiet zone)
    try std.testing.expectEqual(COLOR_WHITE, buffer[0]); // top-left
    try std.testing.expectEqual(COLOR_WHITE, buffer[99]); // top-right
    try std.testing.expectEqual(COLOR_WHITE, buffer[99 * 100]); // bottom-left
    try std.testing.expectEqual(COLOR_WHITE, buffer[99 * 100 + 99]); // bottom-right
}

test "render empty text fails" {
    var buffer: [100 * 100]u32 = undefined;
    // Empty string should still work (produces minimal QR code)
    const qr_size = try renderSliceToBGRA("", &buffer, 100);
    try std.testing.expect(qr_size >= 21); // Version 1 minimum
}

test "invalid buffer size" {
    var buffer: [0]u32 = undefined;
    const result = renderSliceToBGRA("test", &buffer, 0);
    try std.testing.expectError(RenderError.InvalidBufferSize, result);
}

test "very long text fails" {
    var buffer: [100 * 100]u32 = undefined;
    // Create a string that's too long for any QR version
    var long_text: [8000:0]u8 = undefined;
    @memset(&long_text, 'A');
    long_text[7999] = 0;

    const result = renderToBGRA(&long_text, &buffer, 100);
    try std.testing.expectError(RenderError.TextTooLong, result);
}
