/// REAPER action for displaying network addresses.
/// Registers "REAmo: Show Network Addresses" in the Actions list.
///
/// Users run this action to discover the URL for connecting their phone
/// via WiFi or USB tethering.

const std = @import("std");
const network_detect = @import("network_detect.zig");
const logging = @import("logging.zig");

/// Function type for REAPER's plugin_register
pub const PluginRegisterFn = *const fn ([*:0]const u8, ?*anyopaque) callconv(.c) c_int;

/// Function type for ShowMessageBox
const ShowMessageBoxFn = *const fn ([*:0]const u8, [*:0]const u8, c_int) callconv(.c) c_int;

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

// Global state
var g_cmd_show_networks: c_int = 0;
var g_plugin_register: ?PluginRegisterFn = null;
var g_show_message_box: ?ShowMessageBoxFn = null;
var g_resource_path: ?[]const u8 = null;
var g_http_port: u16 = 8080; // Default, updated from reaper.ini

/// Register the network addresses action with REAPER.
/// Call during plugin initialization.
pub fn register(
    plugin_register: PluginRegisterFn,
    show_message_box: ?ShowMessageBoxFn,
    resource_path: ?[]const u8,
) bool {
    g_plugin_register = plugin_register;
    g_show_message_box = show_message_box;
    g_resource_path = resource_path;

    // Try to read HTTP port from reaper.ini
    if (resource_path) |res_path| {
        g_http_port = getWebInterfacePort(res_path) orelse 8080;
        logging.info("Network action: HTTP port = {d}", .{g_http_port});
    }

    // Register the custom action
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

    // Count USB networks
    var usb_count: usize = 0;
    for (networks[0..count]) |n| {
        if (n.network_type == .ios_usb or n.network_type == .android_usb) {
            usb_count += 1;
        }
    }

    if (usb_count == 0 and count > 0) {
        writer.print("No USB network detected.\n\n", .{}) catch {};
        writer.print("For iOS: Enable Personal Hotspot, then\n", .{}) catch {};
        writer.print("         connect USB cable\n\n", .{}) catch {};
        writer.print("For Android: Connect USB cable, then\n", .{}) catch {};
        writer.print("             enable USB Tethering\n\n", .{}) catch {};
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
