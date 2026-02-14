/// Extensions menu registration and hook handling.
///
/// Registers a "REAmo" submenu under REAPER's Extensions menu bar.
/// Menu items are defined declaratively in menu_items.zig.
/// Command dispatch routes menu clicks to handler functions.

const std = @import("std");
const menu_items = @import("menu_items.zig");
const swell = @import("swell.zig");
const logging = @import("../core/logging.zig");
const network_action = @import("network_action.zig");

const HMENU = swell.HMENU;

/// Function type for REAPER's plugin_register
pub const PluginRegisterFn = *const fn ([*:0]const u8, ?*anyopaque) callconv(.c) c_int;

/// Function type for AddExtensionsMainMenu
pub const AddExtMenuFn = *const fn () callconv(.c) bool;

// REAPER's custom_action_register_t structure.
// Strings are NOT copied by REAPER — must be static/comptime.
const CustomActionRegister = extern struct {
    uniqueSectionId: c_int, // 0 = Main section
    idStr: [*:0]const u8, // Unique identifier across ALL extensions
    name: [*:0]const u8, // Display name in Actions list
    extra: ?*anyopaque, // Reserved, set to null
};

/// Resolved command IDs for each menu item (populated during register).
/// Index matches menu_items.items.
var g_cmd_ids: [menu_items.items.len]c_int = [_]c_int{0} ** menu_items.items.len;

var g_plugin_register: ?PluginRegisterFn = null;
var g_submenu: swell.HMENU = null;

/// Register the Extensions menu and hook callback.
/// Called from main.zig during doInitialization().
///
/// Registration order (per REAPER SDK / SWS convention):
/// 1. Register custom_action for each menu item → get command IDs
/// 2. Register hookcommand2 for dispatching
/// 3. Register hookcustommenu for building the menu
/// 4. Call AddExtensionsMainMenu() to create the Extensions entry
pub fn register(plugin_register: PluginRegisterFn, add_ext_menu: AddExtMenuFn) bool {
    g_plugin_register = plugin_register;

    // 1. Register each menu item as a custom_action to get command IDs
    for (&menu_items.items, 0..) |*item, i| {
        var action = CustomActionRegister{
            .uniqueSectionId = 0,
            .idStr = item.action_id,
            .name = item.label,
            .extra = null,
        };
        g_cmd_ids[i] = plugin_register("custom_action", @ptrCast(&action));
        if (g_cmd_ids[i] == 0) {
            logging.warn("menu: failed to register action {s}", .{item.action_id});
        }
    }

    // 2. Register hookcommand2 for dispatching menu actions
    if (plugin_register("hookcommand2", @constCast(@ptrCast(&onCommand))) == 0) {
        logging.err("menu: failed to register hookcommand2", .{});
        return false;
    }

    // 3. Register the hookcustommenu callback
    if (plugin_register("hookcustommenu", @constCast(@ptrCast(&menuHook))) == 0) {
        logging.err("menu: failed to register hookcustommenu", .{});
        return false;
    }

    // 4. Create the Extensions menu (idempotent — safe if SWS already created it)
    _ = add_ext_menu();

    logging.info("menu: registered {d} items", .{menu_items.items.len});
    return true;
}

/// Unregister hooks on plugin shutdown.
pub fn unregister() void {
    if (g_plugin_register) |plugin_register| {
        _ = plugin_register("-hookcustommenu", @constCast(@ptrCast(&menuHook)));
        _ = plugin_register("-hookcommand2", @constCast(@ptrCast(&onCommand)));
        logging.info("menu: unregistered", .{});
    }
}

/// Look up the command ID for a given action ID string.
/// Returns 0 if not found. Used by other modules to find registered command IDs.
pub fn getCommandId(action_id: [*:0]const u8) c_int {
    const needle = std.mem.span(action_id);
    for (&menu_items.items, 0..) |*item, i| {
        if (std.mem.eql(u8, std.mem.span(item.action_id), needle)) {
            return g_cmd_ids[i];
        }
    }
    return 0;
}

// =============================================================================
// Hook callbacks (called by REAPER)
// =============================================================================

/// hookcustommenu callback — called by REAPER for all customizable menus.
/// Multiple extensions' hooks all fire — returns void so no blocking.
fn menuHook(menuidstr: [*:0]const u8, menu_handle: ?*anyopaque, flag: c_int) callconv(.c) void {
    // Only handle the "Main extensions" menu
    if (!std.mem.eql(u8, std.mem.span(menuidstr), "Main extensions")) return;

    if (flag == 0) {
        // INIT (once): Build default menu structure
        buildMenu(menu_handle);
    } else if (flag == 1) {
        // DISPLAY (every open): Update dynamic state (port in menu text, checkmarks)
        updateMenuState(menu_handle);
    }
}

/// hookcommand2 callback — dispatches menu item clicks to handlers.
/// Returns false for unrecognized commands to let other extensions handle them.
fn onCommand(
    section: ?*anyopaque,
    command: c_int,
    val: c_int,
    val2hw: c_int,
    relmode: c_int,
    hwnd: ?*anyopaque,
) callconv(.c) bool {
    _ = .{ section, val, val2hw, relmode, hwnd };
    for (0..menu_items.items.len) |i| {
        if (command == g_cmd_ids[i] and g_cmd_ids[i] != 0) {
            dispatchAction(i);
            return true;
        }
    }
    return false; // Not our command — let other hooks handle it
}

// =============================================================================
// Menu building (flag=0: called once at init)
// =============================================================================

/// Build the default menu structure.
/// Creates "REAmo" submenu with grouped items separated by dividers.
fn buildMenu(hMenu: HMENU) void {
    const submenu = swell.createPopupMenu() orelse return;

    var added_connection = false;
    var added_settings = false;
    var added_any_grouped = false;

    // First pass: grouped items in declaration order
    for (&menu_items.items, 0..) |*item, i| {
        const cmd_id = g_cmd_ids[i];
        if (cmd_id == 0) continue;
        if (item.group == null) continue;

        // Add separator between different groups
        if (item.group == .settings and !added_settings and added_connection) {
            swell.insertMenuSeparator(submenu, -1);
        }

        swell.insertMenuItem(submenu, -1, cmd_id, item.label);

        if (item.group == .connection) added_connection = true;
        if (item.group == .settings) added_settings = true;
        added_any_grouped = true;
    }

    // Second pass: ungrouped items (after separator)
    var has_ungrouped = false;
    for (&menu_items.items, 0..) |*item, i| {
        if (item.group != null) continue;
        const cmd_id = g_cmd_ids[i];
        if (cmd_id == 0) continue;

        if (!has_ungrouped and added_any_grouped) {
            swell.insertMenuSeparator(submenu, -1);
        }
        swell.insertMenuItem(submenu, -1, cmd_id, item.label);
        has_ungrouped = true;
    }

    // Add "REAmo" submenu to Extensions menu (pos=-1 = append)
    g_submenu = submenu;
    swell.insertSubMenu(hMenu, -1, submenu, "REAmo");
}

// =============================================================================
// Menu state update (flag=1: called every time menu opens)
// =============================================================================

/// Update dynamic menu item text and checked/enabled state.
/// Recurses through menu items. Updates "Change Server Port..." to show current port.
fn updateMenuState(hMenu: HMENU) void {
    const count = swell.getMenuItemCount(hMenu);
    var i: c_int = 0;
    while (i < count) : (i += 1) {
        const sub = swell.getSubMenu(hMenu, i);
        if (sub != null) {
            updateMenuState(sub); // Recurse into submenus
        } else {
            const wID = swell.getMenuItemID(hMenu, i);
            for (&menu_items.items, 0..) |*item, idx| {
                if (wID == g_cmd_ids[idx] and g_cmd_ids[idx] != 0) {
                    // Update "Change Server Port..." to show current port
                    if (std.mem.eql(u8, std.mem.span(item.action_id), "REAMO_CHANGE_PORT")) {
                        var text_buf: [64]u8 = undefined;
                        const port = network_action.getPort();
                        const text = std.fmt.bufPrintZ(&text_buf, "Change Server Port... ({d})", .{port}) catch break;
                        swell.setMenuItemTextByPos(hMenu, i, text);
                    }
                    if (item.is_toggle) {
                        // TODO: query toggle state and update checkmark
                        // swell.checkMenuItem(hMenu, i, queryToggleState(g_cmd_ids[idx]));
                    }
                    break;
                }
            }
        }
    }
}

// =============================================================================
// Action dispatch — routes command IDs to handler functions
// =============================================================================

/// Dispatch a menu action by its index in menu_items.items.
fn dispatchAction(index: usize) void {
    if (index >= menu_items.items.len) return;

    const action_id = std.mem.span(menu_items.items[index].action_id);

    if (std.mem.eql(u8, action_id, "REAMO_SHOW_QR_CODE")) {
        network_action.showQRCode();
    } else if (std.mem.eql(u8, action_id, "REAMO_SHOW_NETWORKS")) {
        network_action.showNetworkAddresses();
    } else if (std.mem.eql(u8, action_id, "REAMO_CHANGE_PORT")) {
        network_action.showChangePort();
    } else if (std.mem.eql(u8, action_id, "REAMO_ABOUT")) {
        network_action.showAbout();
    } else {
        logging.warn("menu: no handler for action {s}", .{action_id});
    }
}
