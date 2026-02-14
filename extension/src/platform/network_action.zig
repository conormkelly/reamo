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
const logging = @import("../core/logging.zig");
const protocol = @import("../core/protocol.zig");
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

/// Function type for ShowMessageBox
const ShowMessageBoxFn = *const fn ([*:0]const u8, [*:0]const u8, c_int) callconv(.c) c_int;

/// Function type for GetMainHwnd
const GetMainHwndFn = *const fn () callconv(.c) ?*anyopaque;

/// Function type for GetUserInputs
const GetUserInputsFn = *const fn ([*:0]const u8, c_int, [*:0]const u8, [*]u8, c_int) callconv(.c) bool;

/// Function type for SetExtState
const SetExtStateFn = *const fn ([*:0]const u8, [*:0]const u8, [*:0]const u8, c_int) callconv(.c) void;

/// Callback for requesting a server restart on a new port
const RestartServerFn = *const fn (u16) void;

// Global state
var g_show_message_box: ?ShowMessageBoxFn = null;
var g_get_main_hwnd: ?GetMainHwndFn = null;
var g_get_user_inputs: ?GetUserInputsFn = null;
var g_set_ext_state: ?SetExtStateFn = null;
var g_restart_server: ?RestartServerFn = null;
var g_resource_path: ?[]const u8 = null;
var g_server_port: u16 = 9224; // Extension's HTTP server port

/// Update the server port (called from main.zig after server starts or port changes).
pub fn setPort(port: u16) void {
    g_server_port = port;
}

/// Get the current server port (used by menu.zig for dynamic title).
pub fn getPort() u16 {
    return g_server_port;
}

/// Set the callback for restarting the server on a new port.
pub fn setRestartCallback(cb: RestartServerFn) void {
    g_restart_server = cb;
}

/// Initialize network action state.
/// Called during plugin initialization. Action registration is handled by menu.zig.
pub fn init(
    show_message_box: ?ShowMessageBoxFn,
    get_main_hwnd: ?GetMainHwndFn,
    get_user_inputs: ?GetUserInputsFn,
    set_ext_state: ?SetExtStateFn,
    resource_path: ?[]const u8,
) void {
    g_show_message_box = show_message_box;
    g_get_main_hwnd = get_main_hwnd;
    g_get_user_inputs = get_user_inputs;
    g_set_ext_state = set_ext_state;
    g_resource_path = resource_path;
}

/// Display the network addresses dialog.
/// Called from menu.zig dispatch.
pub fn showNetworkAddresses() void {
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
        writer.print("http://{s}:{d}/\n\n", .{ ip_str, g_server_port }) catch {};
    }

    if (count == 0) {
        writer.print("No network interfaces found.\n\n", .{}) catch {};
        writer.print("Check that your network connection is active.\n", .{}) catch {};
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
        showNetworkAddresses();
    }
}

/// Display a QR code window with all available networks.
/// User can navigate between networks using < > arrows.
/// Called from menu.zig dispatch.
pub fn showQRCode() void {
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
    qr_window.show(sorted[0..sorted_count], g_server_port, main_hwnd);

    logging.info("Network action: showing QR window with {d} networks", .{sorted_count});
}

/// Display the About REAmo dialog.
pub fn showAbout() void {
    const show_msg = g_show_message_box orelse {
        logging.err("Network action: ShowMessageBox not available", .{});
        return;
    };

    _ = show_msg(
        "Remote control for REAPER." ++
            "\nhttps://www.reamo.com",
        "REAmo v" ++ protocol.EXTENSION_VERSION,
        0, // OK button only
    );
}

/// Show dialog to change the server port.
/// Persists new port in ExtState and restarts the server immediately.
pub fn showChangePort() void {
    const get_input = g_get_user_inputs orelse {
        logging.err("Network action: GetUserInputs not available", .{});
        return;
    };

    // Format current port as default value
    var default_buf: [8]u8 = undefined;
    const default_str = std.fmt.bufPrint(&default_buf, "{d}", .{g_server_port}) catch "9224";

    // GetUserInputs writes result into this buffer (null-terminated CSV)
    var input_buf: [32]u8 = undefined;
    @memcpy(input_buf[0..default_str.len], default_str);
    input_buf[default_str.len] = 0;

    if (!get_input("REAmo Server Port", 1, "Port (1024-65535):", &input_buf, input_buf.len)) {
        return; // User cancelled
    }

    // Parse the input
    const input_len = std.mem.indexOfScalar(u8, &input_buf, 0) orelse input_buf.len;
    const input_str = input_buf[0..input_len];
    const new_port = std.fmt.parseInt(u16, input_str, 10) catch {
        if (g_show_message_box) |show_msg| {
            _ = show_msg("Invalid port number.", "REAmo", 0);
        }
        return;
    };

    if (new_port < 1024) {
        if (g_show_message_box) |show_msg| {
            _ = show_msg("Port must be 1024 or higher.", "REAmo", 0);
        }
        return;
    }

    if (new_port == g_server_port) {
        return; // No change
    }

    // Persist the new port in ExtState
    if (g_set_ext_state) |set_state| {
        var port_z: [8]u8 = undefined;
        const port_str = std.fmt.bufPrint(&port_z, "{d}", .{new_port}) catch "9224";
        port_z[port_str.len] = 0;
        set_state("Reamo", "ServerPort", @ptrCast(&port_z), 1); // persist=true
    }

    // Restart the server on the new port
    if (g_restart_server) |restart| {
        restart(new_port);

        // Show confirmation
        if (g_show_message_box) |show_msg| {
            var msg_buf: [128]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&msg_buf);
            fbs.writer().print("Server restarted on port {d}.\nClients should reconnect.", .{new_port}) catch {};
            const written = fbs.getWritten();
            if (written.len < msg_buf.len) {
                msg_buf[written.len] = 0;
            }
            _ = show_msg(@ptrCast(&msg_buf), "REAmo", 0);
        }
    }
}
