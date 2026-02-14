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
const host_validation = @import("../server/host_validation.zig");
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

/// Show dialog to view/edit allowed hostnames for DNS rebinding protection.
/// Users with Tailscale, VPNs, or custom DNS can add their hostnames here.
/// Private IPs (127.x, 10.x, 192.168.x, etc.) and .local names are always allowed.
pub fn showAllowedHosts() void {
    const get_input = g_get_user_inputs orelse {
        logging.err("Network action: GetUserInputs not available", .{});
        return;
    };

    // Build current hosts as comma-separated default value
    var host_slices: [16][]const u8 = undefined;
    const count = host_validation.getAllowedHosts(&host_slices);

    var default_buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&default_buf);
    const writer = fbs.writer();
    for (0..count) |i| {
        if (i > 0) writer.writeAll(",") catch {};
        writer.writeAll(host_slices[i]) catch {};
    }
    const default_written = fbs.getWritten();

    // GetUserInputs writes result into this buffer
    var input_buf: [512]u8 = undefined;
    @memcpy(input_buf[0..default_written.len], default_written);
    input_buf[default_written.len] = 0;

    if (!get_input(
        "REAmo Allowed Hosts",
        1,
        "Hostnames (comma-separated):",
        &input_buf,
        input_buf.len,
    )) {
        return; // User cancelled
    }

    // Parse input
    const input_len = std.mem.indexOfScalar(u8, &input_buf, 0) orelse input_buf.len;
    const input_str = input_buf[0..input_len];

    // Clear and rebuild the allowed hosts list
    host_validation.clearAllowedHosts();

    // Re-add auto-detected hostname (always present)
    {
        var hostname_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        const hostname = std.posix.gethostname(&hostname_buf) catch null;
        if (hostname) |name| {
            _ = host_validation.addAllowedHost(name);
            var local_buf: [std.posix.HOST_NAME_MAX + 6]u8 = undefined;
            if (name.len + 6 <= local_buf.len) {
                @memcpy(local_buf[0..name.len], name);
                @memcpy(local_buf[name.len..][0..6], ".local");
                _ = host_validation.addAllowedHost(local_buf[0 .. name.len + 6]);
            }
        }
    }

    // Get auto-detected hostname once for filtering
    var auto_hostname_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const auto_hostname = std.posix.gethostname(&auto_hostname_buf) catch null;
    var auto_local_buf: [std.posix.HOST_NAME_MAX + 6]u8 = undefined;
    const auto_local: ?[]const u8 = if (auto_hostname) |name| blk: {
        if (name.len + 6 <= auto_local_buf.len) {
            @memcpy(auto_local_buf[0..name.len], name);
            @memcpy(auto_local_buf[name.len..][0..6], ".local");
            break :blk auto_local_buf[0 .. name.len + 6];
        }
        break :blk null;
    } else null;

    // Add user entries
    var user_hosts_buf: [512]u8 = undefined;
    var user_fbs = std.io.fixedBufferStream(&user_hosts_buf);
    const user_writer = user_fbs.writer();
    var user_count: usize = 0;

    var iter = std.mem.splitScalar(u8, input_str, ',');
    while (iter.next()) |entry| {
        const trimmed = std.mem.trim(u8, entry, " ");
        if (trimmed.len == 0) continue;

        // Skip auto-detected entries (already re-added above) for ExtState persistence
        const is_auto = if (auto_hostname) |name|
            std.mem.eql(u8, trimmed, name) or
                (if (auto_local) |local| std.mem.eql(u8, trimmed, local) else false)
        else
            false;

        _ = host_validation.addAllowedHost(trimmed);

        // Only persist non-auto entries to ExtState
        if (!is_auto) {
            if (user_count > 0) user_writer.writeAll(",") catch {};
            user_writer.writeAll(trimmed) catch {};
            user_count += 1;
        }
    }

    // Persist user-configured hosts (not auto-detected ones) to ExtState
    if (g_set_ext_state) |set_state| {
        const user_hosts = user_fbs.getWritten();
        var persist_buf: [512]u8 = undefined;
        if (user_hosts.len < persist_buf.len) {
            @memcpy(persist_buf[0..user_hosts.len], user_hosts);
            persist_buf[user_hosts.len] = 0;
            set_state("Reamo", "AllowedHosts", @ptrCast(&persist_buf), 1);
        }
    }

    // Show confirmation
    if (g_show_message_box) |show_msg| {
        var msg_buf: [256]u8 = undefined;
        var msg_fbs = std.io.fixedBufferStream(&msg_buf);
        msg_fbs.writer().print(
            "Allowed hosts updated ({d} total).\n\nPrivate IPs and .local names are always allowed.",
            .{host_validation.getAllowedHostCount()},
        ) catch {};
        const msg_written = msg_fbs.getWritten();
        if (msg_written.len < msg_buf.len) {
            msg_buf[msg_written.len] = 0;
        }
        _ = show_msg(@ptrCast(&msg_buf), "REAmo", 0);
    }
}
