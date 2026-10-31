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
const compat = @import("compat.zig");

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

/// ShowMessageBox types and answers (reaper_plugin_functions.h). They are
/// Win32's MB_* and ID* values, which SWELL shares.
const MB_OK: c_int = 0;
const MB_YESNO: c_int = 4;
const IDOK: c_int = 1;
const IDCANCEL: c_int = 2;
const IDYES: c_int = 6;
const IDNO: c_int = 7;

/// Function type for ShowMessageBox
const ShowMessageBoxFn = *const fn ([*:0]const u8, [*:0]const u8, c_int) callconv(.c) c_int;

/// Function type for GetMainHwnd
const GetMainHwndFn = *const fn () callconv(.c) ?*anyopaque;

/// Function type for GetUserInputs
const GetUserInputsFn = *const fn ([*:0]const u8, c_int, [*:0]const u8, [*]u8, c_int) callconv(.c) bool;

/// Function type for SetExtState
const SetExtStateFn = *const fn ([*:0]const u8, [*:0]const u8, [*:0]const u8, c_int) callconv(.c) void;

/// Callback for requesting a server restart on a new port
/// Moves the server to a port; on error it is still serving on the old one.
const RestartServerFn = *const fn (u16) anyerror!void;

// Global state
var g_show_message_box: ?ShowMessageBoxFn = null;
var g_get_main_hwnd: ?GetMainHwndFn = null;
var g_get_user_inputs: ?GetUserInputsFn = null;
var g_set_ext_state: ?SetExtStateFn = null;
var g_restart_server: ?RestartServerFn = null;
var g_resource_path: ?[]const u8 = null;
var g_server_port: u16 = 9224; // Extension's HTTP server port
/// Lists the networks phones can reach, likeliest first. Tests stand it in.
var g_detect_networks: *const fn ([]network_detect.NetworkInfo) usize = network_detect.detectOrdered;

/// Update the server port (called from main.zig after server starts or port
/// changes). An open QR code window follows it.
pub fn setPort(port: u16) void {
    g_server_port = port;
    qr_window.setPort(port);
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
    const count = network_detect.detectOrdered(&networks);

    // Format the message
    var msg_buf: [4096]u8 = undefined;
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
    const count = network_detect.detectOrdered(&networks);

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

    // Get main window for parenting
    const main_hwnd: ?*anyopaque = if (g_get_main_hwnd) |f| f() else null;

    // Show QR window with all networks
    qr_window.show(networks[0..count], g_server_port, main_hwnd);

    logging.info("Network action: showing QR window with {d} networks", .{count});
}

/// Display the About REAmo dialog.
pub fn showAbout() void {
    const show_msg = g_show_message_box orelse {
        logging.err("Network action: ShowMessageBox not available", .{});
        return;
    };

    _ = show_msg(
        "Remote control for REAPER." ++
            "\nhttps://github.com/conormkelly/reamo",
        "REAmo v" ++ protocol.EXTENSION_VERSION,
        0, // OK button only
    );
}

/// Open the folder holding reamo.log in the system file browser. If that
/// can't be done, say where the folder is instead.
pub fn openLogFolder() void {
    const log_path = logging.getLogPath() orelse {
        showMessage("REAmo has no log file this session (REAPER's resource folder wasn't available).");
        return;
    };
    var dir_buf: [512]u8 = undefined;
    const dir = nativeSeparators(std.fs.path.dirname(log_path) orelse log_path, &dir_buf);
    const opener: []const u8 = switch (builtin.os.tag) {
        .macos => "open",
        .windows => "explorer.exe",
        else => "xdg-open",
    };
    // A failed exec only surfaces when the child is reaped, off the main
    // thread, so check first for the one opener a system may lack.
    const available = builtin.os.tag == .macos or builtin.os.tag == .windows or onPath(opener);
    if (!available) {
        logging.warn("Open Log Folder: couldn't run {s}: not installed", .{opener});
    }
    (if (available) spawnDetached(&.{ opener, dir }) else error.FileNotFound) catch |err| {
        if (available) logging.warn("Open Log Folder: couldn't run {s}: {s}", .{ opener, @errorName(err) });
        var buf: [600]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "REAmo's log is in:\n{s}", .{dir}) catch "REAmo's log is in REAPER's resource folder, under Logs.";
        showMessage(msg);
    };
}

/// `path` with Windows' separators on Windows, where REAPER's resource path
/// uses backslashes but REAmo appends "/Logs", and Explorer may open
/// somewhere else for a mixed path. Other platforms use it as is.
fn nativeSeparators(path: []const u8, buf: []u8) []const u8 {
    if (builtin.os.tag != .windows or path.len > buf.len) return path;
    for (path, 0..) |c, i| buf[i] = if (c == '/') '\\' else c;
    return buf[0..path.len];
}

/// Whether an executable named `name` is in a PATH directory.
fn onPath(name: []const u8) bool {
    const path = std.posix.getenv("PATH") orelse return false;
    var dirs = std.mem.tokenizeScalar(u8, path, ':');
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    while (dirs.next()) |d| {
        const candidate = std.fmt.bufPrint(&buf, "{s}/{s}", .{ d, name }) catch continue;
        std.fs.cwd().access(candidate, .{}) catch continue;
        return true;
    }
    return false;
}

/// Run a program without waiting for it; a thread reaps it so it never
/// lingers as a zombie, and REAPER's main thread never blocks on it.
fn spawnDetached(argv: []const []const u8) !void {
    const child = try std.heap.c_allocator.create(std.process.Child);
    errdefer std.heap.c_allocator.destroy(child);
    child.* = std.process.Child.init(argv, std.heap.c_allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    const reaper_thread = std.Thread.spawn(.{}, reapChild, .{child}) catch |err| {
        // Without the thread, reap here: the opener returns at once.
        reapChild(child);
        return err;
    };
    reaper_thread.detach();
}

/// Wait for `child` to exit and free it. On POSIX this calls waitpid
/// directly: std's wait treats ECHILD as unreachable, and REAPER or another
/// extension may already reap children (SIGCHLD ignored, or waitpid(-1)).
fn reapChild(child: *std.process.Child) void {
    defer std.heap.c_allocator.destroy(child);
    if (comptime builtin.os.tag == .windows) {
        _ = child.wait() catch |err| logging.warn("Open Log Folder: the file browser failed: {s}", .{@errorName(err)});
    } else {
        var status: c_int = 0;
        while (std.c.waitpid(child.id, &status, 0) == -1) {
            if (std.posix.errno(@as(c_int, -1)) != .INTR) break;
        }
        if (child.err_pipe) |fd| std.posix.close(fd);
    }
}

fn showMessage(msg: [*:0]const u8) void {
    const show_msg = g_show_message_box orelse return;
    _ = show_msg(msg, "REAmo", 0);
}

/// Why a port change failed, in words for the dialog.
fn errorText(err: anyerror) []const u8 {
    return switch (err) {
        error.AddressInUse => "another program is using it",
        error.AccessDenied => "permission denied",
        else => @errorName(err),
    };
}

/// Room for any port-change message; every one is well under it.
const port_msg_len = 512;

// The port-change messages break their own lines: SWELL's message box
// doesn't wrap, so a long line runs off the screen on Linux.

/// The question asked before moving the server from `old_port` to
/// `new_port`. A phone's address includes the port, so to the phone the
/// moved server is a new site: its saved settings and home-screen app
/// belong to the old address.
fn confirmPortChangeText(buf: *[port_msg_len]u8, old_port: u16, new_port: u16) [:0]const u8 {
    return std.fmt.bufPrintZ(buf,
        \\Move REAmo from port {d} to {d}?
        \\
        \\Phones will need the new address, and apps added
        \\to a home screen must be added again.
        \\
        \\Settings saved on phones (toolbars, layout,
        \\sync offset, view options) don't carry over:
        \\they're tied to the address.
    , .{ old_port, new_port }) catch unreachable;
}

/// What to tell the user once the server is on `port`: the address phones
/// open. `networks` is likeliest first, as the QR code window offers them,
/// so the first is the one given; Show Network Addresses lists the rest.
fn portChangedText(buf: *[port_msg_len]u8, port: u16, networks: []const network_detect.NetworkInfo) [:0]const u8 {
    if (networks.len == 0) {
        return std.fmt.bufPrintZ(buf,
            \\REAmo is now on port {d}.
            \\
            \\No network was found for phones to reach it.
            \\Once there is one, Extensions > REAmo >
            \\Show Network Addresses gives the address.
        , .{port}) catch unreachable;
    }
    var ip_buf: [16]u8 = undefined;
    const more: []const u8 = if (networks.len > 1)
        "\n\nFor other addresses: Extensions > REAmo >\nShow Network Addresses."
    else
        "";
    return std.fmt.bufPrintZ(buf,
        \\REAmo is now on port {d}.
        \\
        \\On phones, open:
        \\http://{s}:{d}/{s}
    , .{ port, networks[0].ipString(&ip_buf), port, more }) catch unreachable;
}

/// Show dialog to change the server port. The user confirms the move first;
/// the server moves, and the port is saved, only once the new port is
/// listening.
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

    const restart = g_restart_server orelse return;
    const show_msg = g_show_message_box orelse {
        logging.err("Network action: ShowMessageBox not available to confirm the port change", .{});
        return;
    };

    var msg_buf: [port_msg_len]u8 = undefined;
    // Anything but Yes moves nothing.
    if (show_msg(confirmPortChangeText(&msg_buf, g_server_port, new_port).ptr, "REAmo Port Change", MB_YESNO) != IDYES) {
        return;
    }

    const msg: [:0]const u8 = if (restart(new_port)) |_| blk: {
        // Saved only once the server is listening there, so a port that
        // failed is never the one REAmo tries at the next start.
        if (g_set_ext_state) |set_state| {
            var port_z: [8]u8 = undefined;
            const port_str = std.fmt.bufPrintZ(&port_z, "{d}", .{new_port}) catch unreachable;
            set_state("Reamo", "ServerPort", port_str.ptr, 1); // persist=true
        }
        var networks: [16]network_detect.NetworkInfo = undefined;
        const count = g_detect_networks(&networks);
        break :blk portChangedText(&msg_buf, new_port, networks[0..count]);
    } else |err| std.fmt.bufPrintZ(&msg_buf, "Couldn't start the server on port {d} ({s}).\nREAmo is still on port {d}.", .{ new_port, errorText(err), g_server_port }) catch unreachable;
    _ = show_msg(msg.ptr, "REAmo", MB_OK);
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

    // GetUserInputs writes result into this buffer
    var input_buf: [512]u8 = undefined;

    // Whole entries only, leaving room for the NUL: up to 16 hosts of 128
    // chars don't fit, and a host cut mid-name would be saved back on OK.
    var default_len: usize = 0;
    for (host_slices[0..count]) |host| {
        const sep: usize = if (default_len > 0) 1 else 0;
        if (default_len + sep + host.len > input_buf.len - 1) break;
        if (sep == 1) input_buf[default_len] = ',';
        @memcpy(input_buf[default_len + sep ..][0..host.len], host);
        default_len += sep + host.len;
    }
    input_buf[default_len] = 0;

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
        var hostname_buf: [compat.HOSTNAME_MAX]u8 = undefined;
        const hostname = compat.getHostname(&hostname_buf);
        if (hostname) |name| {
            _ = host_validation.addAllowedHost(name);
            var local_buf: [compat.HOSTNAME_MAX + 6]u8 = undefined;
            if (name.len + 6 <= local_buf.len) {
                @memcpy(local_buf[0..name.len], name);
                @memcpy(local_buf[name.len..][0..6], ".local");
                _ = host_validation.addAllowedHost(local_buf[0 .. name.len + 6]);
            }
        }
    }

    // Get auto-detected hostname once for filtering
    var auto_hostname_buf: [compat.HOSTNAME_MAX]u8 = undefined;
    const auto_hostname = compat.getHostname(&auto_hostname_buf);
    var auto_local_buf: [compat.HOSTNAME_MAX + 6]u8 = undefined;
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

        if (!host_validation.addAllowedHost(trimmed)) {
            logging.warn("An allowed host wasn't added ({d} characters): too long, or the list is full", .{trimmed.len});
            continue;
        }

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

// ============================================================================
// Tests
// ============================================================================

var test_dialog_default: [512]u8 = undefined;
var test_dialog_default_len: usize = 0;

/// GetUserInputs stand-in: records the default value it was handed, then cancels.
fn captureDefaultAndCancel(_: [*:0]const u8, _: c_int, _: [*:0]const u8, buf: [*]u8, buf_len: c_int) callconv(.c) bool {
    const len = std.mem.indexOfScalar(u8, buf[0..@intCast(buf_len)], 0) orelse @as(usize, @intCast(buf_len));
    @memcpy(test_dialog_default[0..len], buf[0..len]);
    test_dialog_default_len = len;
    return false;
}

test "showAllowedHosts hands the dialog a NUL-terminated default of whole hosts when the list exceeds its buffer" {
    host_validation.clearAllowedHosts();
    defer host_validation.clearAllowedHosts();
    defer init(null, null, null, null, null);

    // 15 hosts of 36 chars joined by commas is 554 bytes, more than the
    // dialog's 512-byte buffer; writing the terminator past it panicked.
    var names: [15][40]u8 = undefined;
    var hosts: [15][]const u8 = undefined;
    for (&names, &hosts, 0..) |*name, *host, i| {
        host.* = try std.fmt.bufPrint(name, "host-{d:0>3}-macbook-pro.tail1234.ts.net", .{i});
        try std.testing.expect(host_validation.addAllowedHost(host.*));
    }

    init(null, null, &captureDefaultAndCancel, null, null);
    showAllowedHosts();

    const default = test_dialog_default[0..test_dialog_default_len];
    try std.testing.expect(default.len < 512);
    var it = std.mem.splitScalar(u8, default, ',');
    var seen: usize = 0;
    while (it.next()) |entry| : (seen += 1) {
        try std.testing.expectEqualStrings(hosts[seen], entry);
    }
    try std.testing.expectEqual(@as(usize, 13), seen);
}

fn testNetwork(ip: [4]u8, network_type: network_detect.NetworkType) network_detect.NetworkInfo {
    var n = network_detect.NetworkInfo{ .ip = ip, .interface_name = undefined, .interface_name_len = 3, .network_type = network_type };
    @memcpy(n.interface_name[0..3], "en0");
    return n;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "the port-change confirm names both ports and says phones need the new address, home-screen apps re-adding, and saved settings stay behind" {
    var buf: [port_msg_len]u8 = undefined;
    const text = confirmPortChangeText(&buf, 9224, 9300);
    try std.testing.expect(contains(text, "9224"));
    try std.testing.expect(contains(text, "9300"));
    try std.testing.expect(contains(text, "new address"));
    try std.testing.expect(contains(text, "home screen"));
    try std.testing.expect(contains(text, "(toolbars, layout,\nsync offset, view options)"));
    try std.testing.expect(contains(text, "tied to the address"));
}

test "the port-changed message gives a lone network's full URL on the new port" {
    var buf: [port_msg_len]u8 = undefined;
    const networks = [_]network_detect.NetworkInfo{testNetwork(.{ 192, 168, 1, 5 }, .wifi_lan)};
    const text = portChangedText(&buf, 9300, &networks);
    try std.testing.expect(contains(text, "http://192.168.1.5:9300/"));
    try std.testing.expect(!contains(text, "Show Network Addresses"));
}

test "the port-changed message gives only the likeliest address and points to the full list when there are more" {
    var buf: [port_msg_len]u8 = undefined;
    const networks = [_]network_detect.NetworkInfo{
        testNetwork(.{ 172, 20, 10, 2 }, .ios_usb),
        testNetwork(.{ 192, 168, 1, 5 }, .wifi_lan),
    };
    const text = portChangedText(&buf, 9300, &networks);
    try std.testing.expect(contains(text, "http://172.20.10.2:9300/"));
    try std.testing.expect(!contains(text, "192.168.1.5"));
    try std.testing.expect(contains(text, "Show Network Addresses"));
}

test "the port-changed message with no network found gives the new port and where the address will be listed" {
    var buf: [port_msg_len]u8 = undefined;
    const text = portChangedText(&buf, 9300, &.{});
    try std.testing.expect(contains(text, "9300"));
    try std.testing.expect(!contains(text, "http://"));
    try std.testing.expect(contains(text, "Show Network Addresses"));
}

/// A scripted port change: stand-ins for REAPER's dialogs and the server
/// restart, recording what showChangePort did.
const PortChangeTest = struct {
    const Box = struct { text: [port_msg_len]u8, text_len: usize, kind: c_int };

    var entered: []const u8 = "";
    var confirm_answer: c_int = 0;
    var boxes: [4]Box = undefined;
    var box_count: usize = 0;
    var restarted_on: ?u16 = null;
    var saved_port: ?u16 = null;
    /// What the restart stand-in fails with; null when it succeeds.
    var restart_error: ?anyerror = null;
    var with_message_box = true;

    fn getUserInputs(_: [*:0]const u8, _: c_int, _: [*:0]const u8, buf: [*]u8, _: c_int) callconv(.c) bool {
        @memcpy(buf[0..entered.len], entered);
        buf[entered.len] = 0;
        return true;
    }

    fn showMessageBox(text: [*:0]const u8, _: [*:0]const u8, kind: c_int) callconv(.c) c_int {
        const b = &boxes[box_count];
        box_count += 1;
        const m = std.mem.span(text);
        @memcpy(b.text[0..m.len], m);
        b.text_len = m.len;
        b.kind = kind;
        return if (kind == MB_YESNO) confirm_answer else IDOK;
    }

    fn setExtState(_: [*:0]const u8, key: [*:0]const u8, value: [*:0]const u8, _: c_int) callconv(.c) void {
        if (std.mem.eql(u8, std.mem.span(key), "ServerPort")) {
            saved_port = std.fmt.parseInt(u16, std.mem.span(value), 10) catch null;
        }
    }

    fn restart(port: u16) anyerror!void {
        if (restart_error) |err| return err;
        restarted_on = port;
    }

    fn detect(buf: []network_detect.NetworkInfo) usize {
        buf[0] = testNetwork(.{ 192, 168, 1, 5 }, .wifi_lan);
        return 1;
    }

    fn boxText(i: usize) []const u8 {
        return boxes[i].text[0..boxes[i].text_len];
    }

    /// Change Server Port from 9224, entering `entered_port` and answering
    /// the confirm with `answer`.
    fn run(entered_port: []const u8, answer: c_int) void {
        entered = entered_port;
        confirm_answer = answer;
        box_count = 0;
        restarted_on = null;
        saved_port = null;
        init(if (with_message_box) &showMessageBox else null, null, &getUserInputs, &setExtState, null);
        setRestartCallback(&restart);
        g_detect_networks = &detect;
        setPort(9224);
        showChangePort();
    }

    fn restore() void {
        init(null, null, null, null, null);
        g_restart_server = null;
        g_detect_networks = network_detect.detectOrdered;
        restart_error = null;
        with_message_box = true;
        setPort(9224);
    }
};

test "a port change whose restart fails saves no port and says REAmo is still on the old one" {
    defer PortChangeTest.restore();
    PortChangeTest.restart_error = error.AddressInUse;
    PortChangeTest.run("9300", IDYES);
    try std.testing.expectEqual(@as(?u16, null), PortChangeTest.saved_port);
    try std.testing.expectEqual(@as(usize, 2), PortChangeTest.box_count);
    try std.testing.expect(contains(PortChangeTest.boxText(1), "REAmo is still on port 9224"));
    try std.testing.expectEqual(@as(u16, 9224), getPort());
}

test "without ShowMessageBox to ask the confirm, a port change moves nothing" {
    defer PortChangeTest.restore();
    PortChangeTest.with_message_box = false;
    PortChangeTest.run("9300", IDYES);
    try std.testing.expectEqual(@as(?u16, null), PortChangeTest.restarted_on);
    try std.testing.expectEqual(@as(?u16, null), PortChangeTest.saved_port);
}
test "answering No to the port-change confirm leaves the server and the saved port alone" {
    defer PortChangeTest.restore();
    PortChangeTest.run("9300", IDNO);
    try std.testing.expectEqual(@as(usize, 1), PortChangeTest.box_count);
    try std.testing.expectEqual(MB_YESNO, PortChangeTest.boxes[0].kind);
    try std.testing.expectEqual(@as(?u16, null), PortChangeTest.restarted_on);
    try std.testing.expectEqual(@as(?u16, null), PortChangeTest.saved_port);
    try std.testing.expectEqual(@as(u16, 9224), getPort());
}

test "closing the port-change confirm with an answer other than Yes or No moves nothing" {
    defer PortChangeTest.restore();
    PortChangeTest.run("9300", IDCANCEL);
    try std.testing.expectEqual(@as(usize, 1), PortChangeTest.box_count);
    try std.testing.expectEqual(@as(?u16, null), PortChangeTest.restarted_on);
    try std.testing.expectEqual(@as(?u16, null), PortChangeTest.saved_port);
}

test "answering Yes to the port-change confirm moves the server, saves the port, and gives the URL phones open" {
    defer PortChangeTest.restore();
    PortChangeTest.run("9300", IDYES);
    try std.testing.expectEqual(@as(usize, 2), PortChangeTest.box_count);
    try std.testing.expectEqual(MB_YESNO, PortChangeTest.boxes[0].kind);
    try std.testing.expectEqual(MB_OK, PortChangeTest.boxes[1].kind);
    try std.testing.expectEqual(@as(?u16, 9300), PortChangeTest.restarted_on);
    try std.testing.expectEqual(@as(?u16, 9300), PortChangeTest.saved_port);
    try std.testing.expect(contains(PortChangeTest.boxText(1), "http://192.168.1.5:9300/"));
}

test "an invalid or unchanged port asks no confirm and moves nothing" {
    defer PortChangeTest.restore();
    for ([_][]const u8{ "9224", "80", "abc" }) |entered| {
        PortChangeTest.run(entered, IDYES);
        for (PortChangeTest.boxes[0..PortChangeTest.box_count]) |b| try std.testing.expect(b.kind != MB_YESNO);
        try std.testing.expectEqual(@as(?u16, null), PortChangeTest.restarted_on);
    }
}
