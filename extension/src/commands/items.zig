const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");

// Item command handlers
pub const handlers = [_]mod.Entry{
    .{ .name = "item/setActiveTake", .handler = handleItemSetActiveTake },
    .{ .name = "item/move", .handler = handleItemMove },
    .{ .name = "item/setColor", .handler = handleItemColor },
    .{ .name = "item/setLock", .handler = handleItemLock },
    .{ .name = "item/setNotes", .handler = handleItemNotes },
    .{ .name = "item/delete", .handler = handleItemDelete },
    .{ .name = "item/goto", .handler = handleItemGoto },
    .{ .name = "item/select", .handler = handleItemSelect },
    .{ .name = "item/selectInTimeSel", .handler = handleSelectInTimeSel },
    .{ .name = "item/unselectAll", .handler = handleUnselectAll },
};

// Helper to get item by track/item index
fn getItemFromCmd(api: *const reaper.Api, cmd: protocol.CommandMessage) ?struct { track: *anyopaque, item: *anyopaque } {
    const track_idx = cmd.getInt("trackIdx") orelse return null;
    const item_idx = cmd.getInt("itemIdx") orelse return null;

    const track = api.getTrackByIdx(track_idx) orelse return null;
    const item = api.getItemByIdx(track, item_idx) orelse return null;

    return .{ .track = track, .item = item };
}

fn handleItemSetActiveTake(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const item_info = getItemFromCmd(api, cmd) orelse {
        response.err("NOT_FOUND", "Item not found");
        return;
    };
    const take_idx = cmd.getInt("takeIdx") orelse {
        response.err("MISSING_TAKE_IDX", "Take index is required");
        return;
    };

    // Bounds check: verify take index is valid
    const num_takes = api.itemTakeCount(item_info.item);
    if (take_idx < 0 or take_idx >= num_takes) {
        api.log("Reamo: Invalid take index {d} (item has {d} takes)", .{ take_idx, num_takes });
        response.err("INVALID_TAKE_INDEX", "Take index out of range");
        return;
    }

    if (api.setItemActiveTake(item_info.item, take_idx)) {
        api.log("Reamo: Set active take to {d}", .{take_idx});
    }
}

fn handleItemMove(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const item_info = getItemFromCmd(api, cmd) orelse {
        response.err("NOT_FOUND", "Item not found");
        return;
    };
    const position = mod.validatePosition(cmd.getFloat("position")) orelse {
        response.err("INVALID_POSITION", "Position must be a non-negative number");
        return;
    };

    if (api.setItemPosition(item_info.item, position)) {
        api.log("Reamo: Moved item to {d:.2}", .{position});
    }
}

fn handleItemColor(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const item_info = getItemFromCmd(api, cmd) orelse {
        response.err("NOT_FOUND", "Item not found");
        return;
    };
    const color = cmd.getInt("color") orelse {
        response.err("MISSING_COLOR", "Color is required");
        return;
    };

    if (api.setItemColor(item_info.item, color)) {
        api.log("Reamo: Set item color to {d}", .{color});
    }
}

fn handleItemLock(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const item_info = getItemFromCmd(api, cmd) orelse {
        response.err("NOT_FOUND", "Item not found");
        return;
    };

    // Toggle lock state if no explicit value provided
    const locked = if (cmd.getInt("locked")) |v| v != 0 else !api.getItemLocked(item_info.item);

    if (api.setItemLocked(item_info.item, locked)) {
        api.log("Reamo: Set item locked to {}", .{locked});
    }
}

fn handleItemNotes(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const item_info = getItemFromCmd(api, cmd) orelse {
        response.err("NOT_FOUND", "Item not found");
        return;
    };
    const notes = cmd.getString("notes") orelse "";

    if (api.setItemNotes(item_info.item, notes)) {
        api.log("Reamo: Updated item notes", .{});
    }
}

fn handleItemDelete(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const item_info = getItemFromCmd(api, cmd) orelse {
        response.err("NOT_FOUND", "Item not found");
        return;
    };

    api.undoBeginBlock();
    if (api.deleteItem(item_info.track, item_info.item)) {
        api.log("Reamo: Deleted item", .{});
    }
    api.undoEndBlock("Delete item (API)");
}

fn handleItemGoto(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const item_info = getItemFromCmd(api, cmd) orelse {
        response.err("NOT_FOUND", "Item not found");
        return;
    };
    const position = api.getItemPosition(item_info.item);
    api.setCursorPos(position);
}

// Select a single item (deselects all others first)
fn handleItemSelect(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const item_info = getItemFromCmd(api, cmd) orelse {
        response.err("NOT_FOUND", "Item not found");
        return;
    };

    // Deselect all items first
    api.runCommand(reaper.Command.UNSELECT_ALL_ITEMS);

    // Select the specified item
    if (api.setItemSelected(item_info.item, true)) {
        api.log("Reamo: Selected item", .{});
    }
}

// Select all items within time selection (on selected tracks)
fn handleSelectInTimeSel(api: *const reaper.Api, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.SELECT_ALL_ITEMS_IN_TIME_SEL);
    api.log("Reamo: Selected items in time selection", .{});
}

// Deselect all items
fn handleUnselectAll(api: *const reaper.Api, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.UNSELECT_ALL_ITEMS);
    api.log("Reamo: Unselected all items", .{});
}
