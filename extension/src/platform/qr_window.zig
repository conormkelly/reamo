/// QR Code Window for USB connectivity feature.
///
/// Displays a floating window with a QR code that users can scan
/// to connect to the REAPER remote interface without typing URLs.
/// Supports multiple network interfaces with < > navigation.
///
/// Uses SWELL on macOS/Linux, native Win32 on Windows.

const std = @import("std");
const swell = @import("swell.zig");
const qr_render = @import("qr_render.zig");
const network_detect = @import("network_detect.zig");

/// QR code size in pixels (square)
const QR_SIZE: usize = 200;

/// Window margin around QR code
const MARGIN: c_int = 20;

/// Navigation arrow area height
const NAV_HEIGHT: c_int = 40;

/// Total window size
const WINDOW_WIDTH: c_int = 240; // 200 + 20 + 20
const WINDOW_HEIGHT: c_int = 320; // QR + margins + nav area + title bar

/// Static buffer for QR rendering (reused across window instances)
var g_qr_buffer: [QR_SIZE * QR_SIZE]u32 = [_]u32{0xFFFFFFFF} ** (QR_SIZE * QR_SIZE);

/// Current window handle (null if no window open)
var g_hwnd: swell.HWND = null;

/// Network list and current selection
var g_networks: [16]network_detect.NetworkInfo = undefined;
var g_network_count: usize = 0;
var g_current_index: usize = 0;
var g_http_port: u16 = 8080;

/// Saved parent handle for centering in WM_INITDIALOG
var g_parent: swell.HWND = null;

/// Calculate window position centered on the parent window.
/// Falls back to (100, 100) if parent rect can't be obtained.
fn centerOnParent(parent: swell.HWND) [2]c_int {
    if (parent != null) {
        var rect: [4]c_int = undefined;
        if (swell.getWindowRect(parent, &rect)) {
            const parent_cx = @divTrunc(rect[0] + rect[2], 2);
            const parent_cy = @divTrunc(rect[1] + rect[3], 2);
            return .{
                parent_cx - @divTrunc(WINDOW_WIDTH, 2),
                parent_cy - @divTrunc(WINDOW_HEIGHT, 2),
            };
        }
    }
    return .{ 100, 100 };
}

/// Show a QR code window for detected networks.
/// If a window is already open, it will be destroyed and recreated.
pub fn show(networks: []const network_detect.NetworkInfo, http_port: u16, parent: swell.HWND) void {
    // Close existing window if any
    if (g_hwnd != null) {
        hide();
    }

    if (networks.len == 0) return;

    // Initialize SWELL if not already done
    if (!swell.init()) {
        std.log.err("qr_window: failed to initialize SWELL", .{});
        return;
    }

    // Save parent for centering
    g_parent = parent;

    // Copy networks to our static buffer
    g_network_count = @min(networks.len, g_networks.len);
    for (networks[0..g_network_count], 0..) |net, i| {
        g_networks[i] = net;
    }
    g_http_port = http_port;
    g_current_index = 0;

    // Render initial QR code
    renderCurrentNetwork();

    // Create floating window
    g_hwnd = swell.createFloatingWindow(parent, &dlgProc);
    if (g_hwnd == null) {
        std.log.err("qr_window: failed to create window", .{});
        return;
    }

    // Set window title and size, centered on parent window
    updateWindowTitle();
    const pos = centerOnParent(parent);
    swell.setWindowPos(g_hwnd, null, pos[0], pos[1], WINDOW_WIDTH, WINDOW_HEIGHT, 0);

    // Make window float above others on macOS
    if (comptime swell.is_swell_platform) {
        if (swell.isMacOS()) {
            swell.setWindowLevel(g_hwnd, swell.NSFloatingWindowLevel);
        }
    }

    swell.showWindow(g_hwnd, swell.SW_SHOW);
    swell.invalidateRect(g_hwnd, null, true);
}

/// Hide and destroy the QR code window if open.
pub fn hide() void {
    if (g_hwnd) |hwnd| {
        swell.destroyWindow(hwnd);
        g_hwnd = null;
    }
}

/// Check if the QR window is currently visible.
pub fn isVisible() bool {
    return g_hwnd != null;
}

/// Navigate to the previous network.
pub fn prevNetwork() void {
    if (g_network_count <= 1) return;
    if (g_current_index == 0) {
        g_current_index = g_network_count - 1;
    } else {
        g_current_index -= 1;
    }
    renderCurrentNetwork();
    updateWindowTitle();
    if (g_hwnd != null) {
        swell.invalidateRect(g_hwnd, null, true);
    }
}

/// Navigate to the next network.
pub fn nextNetwork() void {
    if (g_network_count <= 1) return;
    g_current_index = (g_current_index + 1) % g_network_count;
    renderCurrentNetwork();
    updateWindowTitle();
    if (g_hwnd != null) {
        swell.invalidateRect(g_hwnd, null, true);
    }
}

/// Render the QR code for the current network.
fn renderCurrentNetwork() void {
    if (g_current_index >= g_network_count) return;

    const net = &g_networks[g_current_index];
    var ip_buf: [16]u8 = undefined;
    const ip_str = net.ipString(&ip_buf);

    var url_buf: [128:0]u8 = undefined;
    const url = std.fmt.bufPrintZ(&url_buf, "http://{s}:{d}/reamo.html", .{ ip_str, g_http_port }) catch {
        std.log.err("qr_window: URL too long", .{});
        return;
    };

    _ = qr_render.renderSliceToBGRA(url, &g_qr_buffer, QR_SIZE) catch |err| {
        std.log.err("qr_window: failed to render QR: {}", .{err});
        @memset(&g_qr_buffer, 0xFFFFFFFF);
    };
}

/// Update the window title to show current network info.
fn updateWindowTitle() void {
    if (g_hwnd == null or g_current_index >= g_network_count) return;

    const net = &g_networks[g_current_index];
    var ip_buf: [16]u8 = undefined;
    const ip_str = net.ipString(&ip_buf);

    // Format: "WiFi: 192.168.1.50 (1/3)" or just "USB: 172.20.10.2"
    var title_buf: [64:0]u8 = undefined;
    const type_name = net.network_type.label();

    if (g_network_count > 1) {
        const title = std.fmt.bufPrintZ(&title_buf, "{s}: {s} ({d}/{d})", .{
            type_name,
            ip_str,
            g_current_index + 1,
            g_network_count,
        }) catch "Scan to Connect";
        swell.setWindowText(g_hwnd, title);
    } else {
        const title = std.fmt.bufPrintZ(&title_buf, "{s}: {s}", .{
            type_name,
            ip_str,
        }) catch "Scan to Connect";
        swell.setWindowText(g_hwnd, title);
    }
}

/// Draw a filled triangle (arrow) using horizontal lines.
/// For right-pointing: tip at (cx+size, cy), base vertical line at x=cx
/// For left-pointing: tip at (cx-size, cy), base vertical line at x=cx
fn drawTriangle(hdc: swell.HDC, cx: c_int, cy: c_int, size: c_int, pointing_right: bool, brush: ?*anyopaque) void {
    var y: c_int = -size;
    while (y <= size) : (y += 1) {
        const abs_y = @as(c_int, @intCast(@abs(y)));
        var rect: [4]c_int = undefined;
        if (pointing_right) {
            // Tip on right: line from cx to (cx + size - |y|)
            const right_edge = cx + size - abs_y;
            rect = .{ cx, cy + y, right_edge, cy + y + 1 };
        } else {
            // Tip on left: line from (cx - size + |y|) to cx
            const left_edge = cx - size + abs_y;
            rect = .{ left_edge, cy + y, cx, cy + y + 1 };
        }
        _ = swell.fillRect(hdc, &rect, brush);
    }
}

/// Draw navigation arrows and network info.
fn drawNavigation(hdc: swell.HDC) void {
    if (g_network_count <= 1) return; // No navigation needed for single network

    const arrow_y = MARGIN + @as(c_int, QR_SIZE) + 20; // Below QR code
    const arrow_size: c_int = 12;

    // Create gray brush for arrows
    const gray_brush = swell.createSolidBrush(0x00808080); // BGR: gray
    defer if (gray_brush != null) swell.deleteObject(gray_brush);

    if (gray_brush) |brush| {
        // Left arrow at x=30
        drawTriangle(hdc, 30, arrow_y, arrow_size, false, brush);
        // Right arrow at x=210
        drawTriangle(hdc, 210, arrow_y, arrow_size, true, brush);
    }
}

/// Dialog procedure handling window messages.
fn dlgProc(hwnd: swell.HWND, msg: c_uint, wParam: usize, lParam: isize) callconv(.c) isize {
    switch (msg) {
        swell.WM_INITDIALOG => {
            updateWindowTitle();
            const pos = centerOnParent(g_parent);
            swell.setWindowPos(hwnd, null, pos[0], pos[1], WINDOW_WIDTH, WINDOW_HEIGHT, swell.SWP_NOZORDER);

            if (comptime swell.is_swell_platform) {
                if (swell.isMacOS()) {
                    swell.setWindowLevel(hwnd, swell.NSFloatingWindowLevel);
                }
            }
            return 1;
        },

        swell.WM_PAINT => {
            var ps: swell.PAINTSTRUCT = undefined;
            const hdc = swell.beginPaint(hwnd, &ps);

            if (hdc != null) {
                // Fill background with white
                const white_brush = swell.createSolidBrush(0x00FFFFFF);
                if (white_brush != null) {
                    var bg_rect = [4]c_int{ 0, 0, WINDOW_WIDTH, WINDOW_HEIGHT };
                    _ = swell.fillRect(hdc, &bg_rect, white_brush);
                    swell.deleteObject(white_brush);
                }

                // Blit QR code using memory DC
                const mem_dc = swell.createMemContext(hdc, @as(c_int, QR_SIZE), @as(c_int, QR_SIZE));
                if (mem_dc != null) {
                    if (swell.getCtxFrameBuffer(mem_dc)) |frame_buffer| {
                        @memcpy(frame_buffer[0 .. QR_SIZE * QR_SIZE], &g_qr_buffer);
                        swell.bitBlt(hdc, MARGIN, MARGIN, @as(c_int, QR_SIZE), @as(c_int, QR_SIZE), mem_dc, 0, 0, swell.SRCCOPY);
                    }
                    swell.deleteGfxContext(mem_dc);
                }

                // Draw navigation arrows
                drawNavigation(hdc);
            }

            swell.endPaint(hwnd, &ps);
            return 0;
        },

        swell.WM_LBUTTONDOWN => {
            // Handle mouse clicks for navigation
            const x: c_int = @truncate(@as(isize, @bitCast(lParam & 0xFFFF)));
            const y: c_int = @truncate(@as(isize, @bitCast((lParam >> 16) & 0xFFFF)));

            const arrow_y = MARGIN + @as(c_int, QR_SIZE) + 20;
            const click_zone: c_int = 30; // Click zone around arrow center

            // Check if click is in arrow row (vertically)
            if (y >= arrow_y - click_zone and y <= arrow_y + click_zone) {
                // Left arrow zone (x < 60)
                if (x < 60) {
                    prevNetwork();
                    return 0;
                }
                // Right arrow zone (x > 180)
                if (x > 180) {
                    nextNetwork();
                    return 0;
                }
            }
            return swell.defWindowProc(hwnd, msg, wParam, lParam);
        },

        swell.WM_KEYDOWN => {
            // Handle keyboard navigation
            const vk = wParam;
            if (vk == 0x25) { // VK_LEFT
                prevNetwork();
                return 0;
            } else if (vk == 0x27) { // VK_RIGHT
                nextNetwork();
                return 0;
            }
            return swell.defWindowProc(hwnd, msg, wParam, lParam);
        },

        swell.WM_CLOSE => {
            swell.destroyWindow(hwnd);
            g_hwnd = null;
            return 0;
        },

        swell.WM_DESTROY => {
            g_hwnd = null;
            return 0;
        },

        else => {
            return swell.defWindowProc(hwnd, msg, wParam, lParam);
        },
    }
}
