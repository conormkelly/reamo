/// REAPER actions for network connectivity.
///
/// Provides two actions:
/// - "REAmo: Show Network Addresses" - Lists all network interfaces with URLs
/// - "REAmo: Show Connection QR Code" - Displays QR code for phone scanning
///
/// Users run these actions to discover the URL for connecting their phone
/// via WiFi or USB tethering.

const std = @import("std");
const builtin = @import("builtin");
const network_detect = @import("network_detect.zig");
const logging = @import("logging.zig");
const qr_window = @import("qr_window.zig");

/// Host operating system for platform-specific troubleshooting messages
const HostOS = enum {
    windows,
    macos,
    linux,

    fn detect() HostOS {
        return switch (builtin.os.tag) {
            .windows => .windows,
            .macos => .macos,
            .linux => .linux,
            else => .linux, // Fallback for other Unix-like
        };
    }
};

// =============================================================================
// OS-specific troubleshooting messages
// =============================================================================

const msg_macos_ios =
    \\No iOS USB network found.
    \\
    \\To use iPhone USB tethering:
    \\1. Connect iPhone via USB cable
    \\2. On iPhone: Settings > Personal Hotspot > Allow Others to Join
    \\3. If prompted on iPhone, tap "Trust" this computer
    \\4. Click Retry to scan again
    \\
;

const msg_macos_android =
    \\No Android USB network found.
    \\
    \\Note: Android USB tethering requires additional drivers on macOS.
    \\
    \\Recommended alternatives:
    \\  * Use your Android as a WiFi hotspot instead
    \\  * Connect both devices to the same WiFi network
    \\
    \\For advanced users: HoRNDIS driver (Intel Macs only, requires
    \\disabling SIP on Apple Silicon - not recommended)
    \\
;

const msg_windows_ios =
    \\No iOS USB network found.
    \\
    \\To use iPhone USB tethering:
    \\1. Install iTunes (or "Apple Devices" from Microsoft Store)
    \\   - This installs required Apple Mobile Device drivers
    \\2. Connect iPhone via USB cable
    \\3. On iPhone: Settings > Personal Hotspot > Allow Others to Join
    \\4. Click Retry to scan again
    \\
;

const msg_windows_android =
    \\No Android USB network found.
    \\
    \\To use Android USB tethering:
    \\1. Connect Android phone via USB cable
    \\2. On Android: Settings > Network > Hotspot & tethering > USB tethering
    \\3. Windows may take a few seconds to recognize the device
    \\4. Click Retry to scan again
    \\
;

const msg_linux_usb =
    \\No USB network found.
    \\
    \\For iPhone:
    \\  * Ensure 'usbmuxd' service is running: systemctl status usbmuxd
    \\  * Connect iPhone and enable Personal Hotspot
    \\
    \\For Android:
    \\  * Connect Android and enable USB Tethering in settings
    \\  * Interface should appear as usb0 or enp*s*u*
    \\
    \\Click Retry to scan again.
    \\
;

const msg_generic =
    \\No USB network detected.
    \\
    \\For iOS: Enable Personal Hotspot, then connect USB cable
    \\For Android: Connect USB cable, then enable USB Tethering
    \\
;

/// Get platform-specific troubleshooting message when USB network is missing
fn getUsbTroubleshootingMessage(host_os: HostOS, has_ios: bool, has_android: bool) []const u8 {
    // If we have one type, show help for the missing type
    if (has_ios and !has_android) {
        return switch (host_os) {
            .macos => msg_macos_android,
            .windows => msg_windows_android,
            .linux => msg_linux_usb,
        };
    }
    if (has_android and !has_ios) {
        return switch (host_os) {
            .macos => msg_macos_ios,
            .windows => msg_windows_ios,
            .linux => msg_linux_usb,
        };
    }

    // No USB at all - show general help for the platform
    return switch (host_os) {
        .macos => msg_macos_ios, // iOS more likely to work on Mac
        .windows => msg_windows_android, // Android more common on Windows
        .linux => msg_linux_usb,
    };
}

/// Function type for REAPER's plugin_register
pub const PluginRegisterFn = *const fn ([*:0]const u8, ?*anyopaque) callconv(.c) c_int;

/// Function type for ShowMessageBox
const ShowMessageBoxFn = *const fn ([*:0]const u8, [*:0]const u8, c_int) callconv(.c) c_int;

/// Function type for GetMainHwnd
const GetMainHwndFn = *const fn () callconv(.c) ?*anyopaque;

// REAPER's custom_action_register_t structure
// Strings are NOT copied - must be static/comptime
const CustomActionRegister = extern struct {
    uniqueSectionId: c_int, // 0 = Main section
    idStr: [*:0]const u8, // Unique identifier across ALL extensions
    name: [*:0]const u8, // Display name in Actions list
    extra: ?*anyopaque, // Reserved, set to null
};

// Static strings - must remain valid for plugin lifetime
const ACTION_ID: [*:0]const u8 = "REAMO_SHOW_NETWORKS";
const ACTION_NAME: [*:0]const u8 = "REAmo: Show Network Addresses";
const QR_ACTION_ID: [*:0]const u8 = "REAMO_SHOW_QR_CODE";
const QR_ACTION_NAME: [*:0]const u8 = "REAmo: Show Connection QR Code";

// Global state
var g_cmd_show_networks: c_int = 0;
var g_cmd_show_qr: c_int = 0;
var g_plugin_register: ?PluginRegisterFn = null;
var g_show_message_box: ?ShowMessageBoxFn = null;
var g_get_main_hwnd: ?GetMainHwndFn = null;
var g_resource_path: ?[]const u8 = null;
var g_http_port: u16 = 8080; // Default, updated from reaper.ini

/// Register the network addresses action with REAPER.
/// Call during plugin initialization.
pub fn register(
    plugin_register: PluginRegisterFn,
    show_message_box: ?ShowMessageBoxFn,
    get_main_hwnd: ?GetMainHwndFn,
    resource_path: ?[]const u8,
) bool {
    g_plugin_register = plugin_register;
    g_show_message_box = show_message_box;
    g_get_main_hwnd = get_main_hwnd;
    g_resource_path = resource_path;

    // Try to read HTTP port from reaper.ini
    if (resource_path) |res_path| {
        g_http_port = getWebInterfacePort(res_path) orelse 8080;
        logging.info("Network action: HTTP port = {d}", .{g_http_port});
    }

    // Register the "Show Network Addresses" action
    var action = CustomActionRegister{
        .uniqueSectionId = 0, // Main section
        .idStr = ACTION_ID,
        .name = ACTION_NAME,
        .extra = null,
    };

    g_cmd_show_networks = plugin_register("custom_action", @ptrCast(&action));
    if (g_cmd_show_networks == 0) {
        logging.err("Network action: failed to register custom action", .{});
        return false;
    }

    // Register the "Show QR Code" action
    var qr_action = CustomActionRegister{
        .uniqueSectionId = 0,
        .idStr = QR_ACTION_ID,
        .name = QR_ACTION_NAME,
        .extra = null,
    };

    g_cmd_show_qr = plugin_register("custom_action", @ptrCast(&qr_action));
    if (g_cmd_show_qr == 0) {
        logging.warn("Network action: failed to register QR action", .{});
        // Continue anyway - the main action still works
    } else {
        logging.info("Network action: registered QR command ID {d}", .{g_cmd_show_qr});
    }

    // Register command handler
    const result = plugin_register("hookcommand2", @constCast(@ptrCast(&onAction)));
    if (result == 0) {
        logging.err("Network action: failed to register hookcommand2", .{});
        return false;
    }

    logging.info("Network action: registered command ID {d}", .{g_cmd_show_networks});
    return true;
}

/// Unregister the action on plugin unload.
pub fn unregister() void {
    if (g_plugin_register) |plugin_register| {
        _ = plugin_register("-hookcommand2", @constCast(@ptrCast(&onAction)));
        logging.info("Network action: unregistered", .{});
    }
}

/// Command handler callback - receives ALL action triggers
fn onAction(
    section: ?*anyopaque,
    command: c_int,
    val: c_int,
    val2hw: c_int,
    relmode: c_int,
    hwnd: ?*anyopaque,
) callconv(.c) bool {
    _ = .{ section, val, val2hw, relmode, hwnd };

    if (command == g_cmd_show_networks) {
        showNetworkAddresses();
        return true; // We handled it
    }
    if (command == g_cmd_show_qr and g_cmd_show_qr != 0) {
        showQRCode();
        return true;
    }
    return false; // Not our command
}

/// Display the network addresses dialog
fn showNetworkAddresses() void {
    const show_msg = g_show_message_box orelse {
        logging.err("Network action: ShowMessageBox not available", .{});
        return;
    };

    // Detect networks
    var networks: [16]network_detect.NetworkInfo = undefined;
    const count = network_detect.detectNetworks(&networks);

    // Format the message
    var msg_buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&msg_buf);
    const writer = fbs.writer();

    // Count USB networks by type
    var has_ios_usb = false;
    var has_android_usb = false;
    for (networks[0..count]) |n| {
        if (n.network_type == .ios_usb) has_ios_usb = true;
        if (n.network_type == .android_usb) has_android_usb = true;
    }

    // Show OS-specific troubleshooting if no USB network found
    if (!has_ios_usb and !has_android_usb and count > 0) {
        const host_os = HostOS.detect();
        const help_msg = getUsbTroubleshootingMessage(host_os, has_ios_usb, has_android_usb);
        writer.print("{s}\n", .{help_msg}) catch {};
    }

    // List all networks
    var ip_buf: [16]u8 = undefined;
    for (networks[0..count]) |n| {
        const ip_str = n.ipString(&ip_buf);
        const iface_name = n.interfaceName();
        const type_label = n.network_type.label();

        writer.print("{s} ({s}):\n", .{ type_label, iface_name }) catch {};
        writer.print("http://{s}:{d}/reamo.html\n\n", .{ ip_str, g_http_port }) catch {};
    }

    if (count == 0) {
        writer.print("No network interfaces found.\n\n", .{}) catch {};
        writer.print("Check that REAPER's web interface is enabled\n", .{}) catch {};
        writer.print("in Preferences > Control/OSC/Web.\n", .{}) catch {};
    }

    // Null-terminate
    const written = fbs.getWritten();
    if (written.len < msg_buf.len) {
        msg_buf[written.len] = 0;
    } else {
        msg_buf[msg_buf.len - 1] = 0;
    }

    // Show dialog with Retry/Cancel (type 5)
    // Returns: 1=OK, 2=Cancel, 4=Retry, 6=Yes, 7=No
    const result = show_msg(@ptrCast(&msg_buf), "REAmo Network Addresses", 5);

    if (result == 4) {
        // Retry clicked - rescan
        // Re-read port in case user changed settings
        if (g_resource_path) |res_path| {
            g_http_port = getWebInterfacePort(res_path) orelse g_http_port;
        }
        showNetworkAddresses();
    }
}

/// Display a QR code window with all available networks.
/// User can navigate between networks using < > arrows.
fn showQRCode() void {
    // Re-read port in case user changed settings
    if (g_resource_path) |res_path| {
        g_http_port = getWebInterfacePort(res_path) orelse g_http_port;
    }

    // Detect networks
    var networks: [16]network_detect.NetworkInfo = undefined;
    const count = network_detect.detectNetworks(&networks);

    if (count == 0) {
        // No networks - show error via message box
        if (g_show_message_box) |show_msg| {
            _ = show_msg(
                "No network interfaces found.\n\nCheck that your network connection is active.",
                "REAmo QR Code",
                0, // OK button only
            );
        }
        return;
    }

    // Sort networks: USB first (preferred for venue use), then LAN
    var sorted: [16]network_detect.NetworkInfo = undefined;
    var sorted_count: usize = 0;

    // First pass: USB networks
    for (networks[0..count]) |n| {
        if (n.network_type == .ios_usb or n.network_type == .android_usb) {
            sorted[sorted_count] = n;
            sorted_count += 1;
        }
    }
    // Second pass: LAN networks
    for (networks[0..count]) |n| {
        if (n.network_type == .wifi_lan) {
            sorted[sorted_count] = n;
            sorted_count += 1;
        }
    }

    // Get main window for parenting
    const main_hwnd: ?*anyopaque = if (g_get_main_hwnd) |f| f() else null;

    // Show QR window with all networks
    qr_window.show(sorted[0..sorted_count], g_http_port, main_hwnd);

    logging.info("Network action: showing QR window with {d} networks", .{sorted_count});
}

/// Parse reaper.ini to find the HTTP web interface port.
/// Format: csurf_N=HTTP 0 {port} '{username}' '{default_page}' {flags} '{password}'
fn getWebInterfacePort(resource_path: []const u8) ?u16 {
    // Build path to reaper.ini
    var path_buf: [512]u8 = undefined;
    const ini_path = std.fmt.bufPrint(&path_buf, "{s}/reaper.ini", .{resource_path}) catch return null;

    // Read the file
    const file = std.fs.cwd().openFile(ini_path, .{}) catch return null;
    defer file.close();

    var buf: [64 * 1024]u8 = undefined;
    const bytes_read = file.readAll(&buf) catch return null;
    const content = buf[0..bytes_read];

    // Find [reaper] section and csurf entries
    var in_reaper_section = false;
    var lines = std.mem.splitScalar(u8, content, '\n');

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Check for section headers
        if (trimmed.len >= 2 and trimmed[0] == '[') {
            in_reaper_section = std.mem.eql(u8, trimmed, "[reaper]");
            continue;
        }

        if (!in_reaper_section) continue;

        // Look for csurf_N=HTTP ...
        if (std.mem.startsWith(u8, trimmed, "csurf_")) {
            if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                const value = trimmed[eq_pos + 1 ..];
                if (std.mem.startsWith(u8, value, "HTTP ")) {
                    // Parse: HTTP 0 {port} ...
                    var parts = std.mem.splitScalar(u8, value, ' ');
                    _ = parts.next(); // "HTTP"
                    _ = parts.next(); // "0"
                    if (parts.next()) |port_str| {
                        return std.fmt.parseInt(u16, port_str, 10) catch null;
                    }
                }
            }
        }
    }

    return null;
}

// Tests
test "getWebInterfacePort parses HTTP entry" {
    // This test would need a mock file - skip for now
}
