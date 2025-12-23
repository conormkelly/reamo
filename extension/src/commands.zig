const std = @import("std");
const reaper = @import("reaper.zig");
const protocol = @import("protocol.zig");

// Command handler function type
pub const Handler = *const fn (*const reaper.Api, protocol.CommandMessage) void;

// Command registry entry
const Entry = struct {
    name: []const u8,
    handler: Handler,
};

// Static command registry - add new commands here
const registry = [_]Entry{
    // Transport
    .{ .name = "transport/play", .handler = handlePlay },
    .{ .name = "transport/stop", .handler = handleStop },
    .{ .name = "transport/pause", .handler = handlePause },
    .{ .name = "transport/record", .handler = handleRecord },
    .{ .name = "transport/toggle", .handler = handleToggle },
    .{ .name = "transport/seek", .handler = handleSeek },
    // Markers
    .{ .name = "marker/add", .handler = handleMarkerAdd },
    .{ .name = "marker/update", .handler = handleMarkerUpdate },
    .{ .name = "marker/delete", .handler = handleMarkerDelete },
    .{ .name = "marker/goto", .handler = handleMarkerGoto },
    // Regions
    .{ .name = "region/add", .handler = handleRegionAdd },
    .{ .name = "region/update", .handler = handleRegionUpdate },
    .{ .name = "region/delete", .handler = handleRegionDelete },
    .{ .name = "region/goto", .handler = handleRegionGoto },
    // Items
    .{ .name = "item/setActiveTake", .handler = handleItemSetActiveTake },
    .{ .name = "item/move", .handler = handleItemMove },
    .{ .name = "item/color", .handler = handleItemColor },
    .{ .name = "item/lock", .handler = handleItemLock },
    .{ .name = "item/notes", .handler = handleItemNotes },
    .{ .name = "item/delete", .handler = handleItemDelete },
    .{ .name = "item/goto", .handler = handleItemGoto },
    // Takes
    .{ .name = "take/delete", .handler = handleTakeDelete },
    .{ .name = "take/cropToActive", .handler = handleTakeCropToActive },
};

// Dispatch a command message to the appropriate handler
pub fn dispatch(api: *const reaper.Api, data: []const u8) void {
    const msg_type = protocol.MessageType.parse(data);

    switch (msg_type) {
        .command => {
            const cmd = protocol.CommandMessage.parse(data) orelse {
                api.log("Reamo: Failed to parse command", .{});
                return;
            };

            for (registry) |entry| {
                if (std.mem.eql(u8, cmd.command, entry.name)) {
                    entry.handler(api, cmd);
                    return;
                }
            }

            api.log("Reamo: Unknown command: {s}", .{cmd.command});
        },
        .unknown => {
            api.log("Reamo: Unknown message type", .{});
        },
    }
}

// Transport command handlers

fn handlePlay(api: *const reaper.Api, _: protocol.CommandMessage) void {
    api.runCommand(reaper.Command.PLAY);
}

fn handleStop(api: *const reaper.Api, _: protocol.CommandMessage) void {
    api.runCommand(reaper.Command.STOP);
}

fn handlePause(api: *const reaper.Api, _: protocol.CommandMessage) void {
    api.runCommand(reaper.Command.PAUSE);
}

fn handleRecord(api: *const reaper.Api, _: protocol.CommandMessage) void {
    api.runCommand(reaper.Command.RECORD);
}

fn handleToggle(api: *const reaper.Api, _: protocol.CommandMessage) void {
    const state = api.playState();
    if (state & 1 != 0) {
        // Currently playing, pause
        api.runCommand(reaper.Command.PAUSE);
    } else {
        // Currently stopped/paused, play
        api.runCommand(reaper.Command.PLAY);
    }
}

fn handleSeek(api: *const reaper.Api, cmd: protocol.CommandMessage) void {
    if (cmd.getFloat("position")) |pos| {
        api.setCursorPos(pos);
    }
}

// Marker command handlers

fn handleMarkerAdd(api: *const reaper.Api, cmd: protocol.CommandMessage) void {
    const pos = cmd.getFloat("position") orelse return;
    const color = cmd.getInt("color") orelse 0;

    // Get name - need null-terminated string for REAPER API
    var name_buf: [65]u8 = undefined;
    const name: [*:0]const u8 = if (cmd.getString("name")) |n| blk: {
        const len = @min(n.len, 64);
        @memcpy(name_buf[0..len], n[0..len]);
        name_buf[len] = 0;
        break :blk @ptrCast(&name_buf);
    } else "";

    const id = api.addMarker(pos, name, color);
    if (id >= 0) {
        api.log("Reamo: Added marker {d} at {d:.2}", .{ id, pos });
    }
}

fn handleMarkerUpdate(api: *const reaper.Api, cmd: protocol.CommandMessage) void {
    const id = cmd.getInt("id") orelse return;
    const pos = cmd.getFloat("position") orelse 0;
    const color = cmd.getInt("color") orelse 0;

    var name_buf: [65]u8 = undefined;
    const name: [*:0]const u8 = if (cmd.getString("name")) |n| blk: {
        const len = @min(n.len, 64);
        @memcpy(name_buf[0..len], n[0..len]);
        name_buf[len] = 0;
        break :blk @ptrCast(&name_buf);
    } else "";

    if (api.updateMarker(id, pos, name, color)) {
        api.log("Reamo: Updated marker {d}", .{id});
    }
}

fn handleMarkerDelete(api: *const reaper.Api, cmd: protocol.CommandMessage) void {
    const id = cmd.getInt("id") orelse return;
    if (api.deleteMarker(id)) {
        api.log("Reamo: Deleted marker {d}", .{id});
    }
}

fn handleMarkerGoto(api: *const reaper.Api, cmd: protocol.CommandMessage) void {
    const id = cmd.getInt("id") orelse return;

    // Find the marker position by enumerating
    var idx: c_int = 0;
    while (api.enumMarker(idx)) |info| : (idx += 1) {
        if (!info.is_region and info.id == id) {
            api.setCursorPos(info.pos);
            return;
        }
    }
}

// Region command handlers

fn handleRegionAdd(api: *const reaper.Api, cmd: protocol.CommandMessage) void {
    const start = cmd.getFloat("start") orelse return;
    const end = cmd.getFloat("end") orelse return;
    const color = cmd.getInt("color") orelse 0;

    var name_buf: [65]u8 = undefined;
    const name: [*:0]const u8 = if (cmd.getString("name")) |n| blk: {
        const len = @min(n.len, 64);
        @memcpy(name_buf[0..len], n[0..len]);
        name_buf[len] = 0;
        break :blk @ptrCast(&name_buf);
    } else "";

    const id = api.addRegion(start, end, name, color);
    if (id >= 0) {
        api.log("Reamo: Added region {d} from {d:.2} to {d:.2}", .{ id, start, end });
    }
}

fn handleRegionUpdate(api: *const reaper.Api, cmd: protocol.CommandMessage) void {
    const id = cmd.getInt("id") orelse return;
    const start = cmd.getFloat("start") orelse 0;
    const end = cmd.getFloat("end") orelse 0;
    const color = cmd.getInt("color") orelse 0;

    var name_buf: [65]u8 = undefined;
    const name: [*:0]const u8 = if (cmd.getString("name")) |n| blk: {
        const len = @min(n.len, 64);
        @memcpy(name_buf[0..len], n[0..len]);
        name_buf[len] = 0;
        break :blk @ptrCast(&name_buf);
    } else "";

    if (api.updateRegion(id, start, end, name, color)) {
        api.log("Reamo: Updated region {d}", .{id});
    }
}

fn handleRegionDelete(api: *const reaper.Api, cmd: protocol.CommandMessage) void {
    const id = cmd.getInt("id") orelse return;
    if (api.deleteRegion(id)) {
        api.log("Reamo: Deleted region {d}", .{id});
    }
}

fn handleRegionGoto(api: *const reaper.Api, cmd: protocol.CommandMessage) void {
    const id = cmd.getInt("id") orelse return;

    // Find the region start position by enumerating
    var idx: c_int = 0;
    while (api.enumMarker(idx)) |info| : (idx += 1) {
        if (info.is_region and info.id == id) {
            api.setCursorPos(info.pos);
            return;
        }
    }
}

// Item command handlers

// Helper to get item by track/item index
fn getItemFromCmd(api: *const reaper.Api, cmd: protocol.CommandMessage) ?struct { track: *anyopaque, item: *anyopaque } {
    const track_idx = cmd.getInt("trackIdx") orelse return null;
    const item_idx = cmd.getInt("itemIdx") orelse return null;

    const track = api.getTrackByIdx(track_idx) orelse return null;
    const item = api.getItemByIdx(track, item_idx) orelse return null;

    return .{ .track = track, .item = item };
}

fn handleItemSetActiveTake(api: *const reaper.Api, cmd: protocol.CommandMessage) void {
    const item_info = getItemFromCmd(api, cmd) orelse return;
    const take_idx = cmd.getInt("takeIdx") orelse return;

    if (api.setItemActiveTake(item_info.item, take_idx)) {
        api.log("Reamo: Set active take to {d}", .{take_idx});
    }
}

fn handleItemMove(api: *const reaper.Api, cmd: protocol.CommandMessage) void {
    const item_info = getItemFromCmd(api, cmd) orelse return;
    const position = cmd.getFloat("position") orelse return;

    if (api.setItemPosition(item_info.item, position)) {
        api.log("Reamo: Moved item to {d:.2}", .{position});
    }
}

fn handleItemColor(api: *const reaper.Api, cmd: protocol.CommandMessage) void {
    const item_info = getItemFromCmd(api, cmd) orelse return;
    const color = cmd.getInt("color") orelse return;

    if (api.setItemColor(item_info.item, color)) {
        api.log("Reamo: Set item color to {d}", .{color});
    }
}

fn handleItemLock(api: *const reaper.Api, cmd: protocol.CommandMessage) void {
    const item_info = getItemFromCmd(api, cmd) orelse return;

    // Toggle lock state if no explicit value provided
    const locked = if (cmd.getInt("locked")) |v| v != 0 else !api.getItemLocked(item_info.item);

    if (api.setItemLocked(item_info.item, locked)) {
        api.log("Reamo: Set item locked to {}", .{locked});
    }
}

fn handleItemNotes(api: *const reaper.Api, cmd: protocol.CommandMessage) void {
    const item_info = getItemFromCmd(api, cmd) orelse return;
    const notes = cmd.getString("notes") orelse "";

    if (api.setItemNotes(item_info.item, notes)) {
        api.log("Reamo: Updated item notes", .{});
    }
}

fn handleItemDelete(api: *const reaper.Api, cmd: protocol.CommandMessage) void {
    const item_info = getItemFromCmd(api, cmd) orelse return;

    if (api.deleteItem(item_info.track, item_info.item)) {
        api.log("Reamo: Deleted item", .{});
    }
}

fn handleItemGoto(api: *const reaper.Api, cmd: protocol.CommandMessage) void {
    const item_info = getItemFromCmd(api, cmd) orelse return;
    const position = api.getItemPosition(item_info.item);
    api.setCursorPos(position);
}

// Take command handlers

fn handleTakeDelete(api: *const reaper.Api, _: protocol.CommandMessage) void {
    // Operates on selected items - uses REAPER's built-in command
    api.runCommand(reaper.Command.DELETE_ACTIVE_TAKE);
    api.log("Reamo: Deleted active take", .{});
}

fn handleTakeCropToActive(api: *const reaper.Api, _: protocol.CommandMessage) void {
    // Operates on selected items - uses REAPER's built-in command
    api.runCommand(reaper.Command.CROP_TO_ACTIVE_TAKE);
    api.log("Reamo: Cropped to active take", .{});
}

// Tests
test "dispatch handles unknown commands gracefully" {
    // This test verifies the code doesn't crash on unknown commands
    // We can't easily test REAPER integration, but we can test parsing
    const data = "{\"type\":\"command\",\"command\":\"unknown/command\"}";
    const cmd = protocol.CommandMessage.parse(data);
    try std.testing.expect(cmd != null);
    try std.testing.expectEqualStrings("unknown/command", cmd.?.command);
}

test "registry contains expected commands" {
    const expected = [_][]const u8{
        "transport/play",
        "transport/stop",
        "transport/pause",
        "transport/record",
        "transport/toggle",
        "transport/seek",
        "marker/add",
        "marker/update",
        "marker/delete",
        "marker/goto",
        "region/add",
        "region/update",
        "region/delete",
        "region/goto",
        "item/setActiveTake",
        "item/move",
        "item/color",
        "item/lock",
        "item/notes",
        "item/delete",
        "item/goto",
        "take/delete",
        "take/cropToActive",
    };

    for (expected) |name| {
        var found = false;
        for (registry) |entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}
