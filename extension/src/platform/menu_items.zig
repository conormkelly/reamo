/// Declarative menu item definitions for the REAmo Extensions menu.
///
/// Menu items are defined as a comptime table. Order here = display order.
/// Adding a new menu item = adding one entry to this table + a handler.

/// A single menu item definition.
pub const MenuItem = struct {
    /// Unique REAPER action ID string (must be unique across ALL extensions)
    action_id: [*:0]const u8,
    /// Display text in the menu
    label: [*:0]const u8,
    /// Whether this item has a checkmark (toggle state)
    is_toggle: bool = false,
    /// Group for visual organization (null = top-level, after all groups)
    group: ?Group = null,
};

pub const Group = enum {
    /// Connection-related items (QR code, network addresses)
    connection,
    /// Settings and configuration items
    settings,
};

/// All menu items, evaluated at comptime.
/// Order within each group = display order in menu.
/// Groups are separated by menu separators.
pub const items = [_]MenuItem{
    // ── Connection ──
    .{ .action_id = "REAMO_SHOW_QR_CODE", .label = "Show Connection QR Code...", .group = .connection },
    .{ .action_id = "REAMO_SHOW_NETWORKS", .label = "Show Network Addresses...", .group = .connection },
    // ── Top-level (no group) ──
    .{ .action_id = "REAMO_ABOUT", .label = "About REAmo" },
};
