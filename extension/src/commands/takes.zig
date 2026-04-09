const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../core/protocol.zig");
const mod = @import("mod.zig");
const logging = @import("../core/logging.zig");

pub fn handleTakeDelete(api: anytype, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    // Operates on selected items - uses REAPER's built-in command
    api.undoBeginBlock();
    api.runCommand(reaper.Command.DELETE_ACTIVE_TAKE);
    api.undoEndBlock("REAmo: Delete active take");
    logging.debug("Deleted active take", .{});
}

pub fn handleTakeCropToActive(api: anytype, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    // Operates on selected items - uses REAPER's built-in command
    api.undoBeginBlock();
    api.runCommand(reaper.Command.CROP_TO_ACTIVE_TAKE);
    api.undoEndBlock("REAmo: Crop to active take");
    logging.debug("Cropped to active take", .{});
}

/// Activate next take in selected items
pub fn handleTakeNext(api: anytype, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.NEXT_TAKE);
    logging.debug("Activated next take", .{});
}

/// Activate previous take in selected items
pub fn handleTakePrev(api: anytype, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.PREV_TAKE);
    logging.debug("Activated previous take", .{});
}

/// Set a specific take's color.
/// Params: trackIdx, itemIdx, takeIdx, color (OS-native color|0x01000000 or 0 to reset)
pub fn handleSetColor(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    // Validate required params
    const track_idx = cmd.getInt("trackIdx") orelse {
        response.err("MISSING_TRACK_IDX", "Track index is required");
        return;
    };
    const item_idx = cmd.getInt("itemIdx") orelse {
        response.err("MISSING_ITEM_IDX", "Item index is required");
        return;
    };
    const take_idx = cmd.getInt("takeIdx") orelse {
        response.err("MISSING_TAKE_IDX", "Take index is required");
        return;
    };
    const color = cmd.getInt("color") orelse {
        response.err("MISSING_COLOR", "Color is required");
        return;
    };

    // Get track
    const track = api.getTrackByUnifiedIdx(track_idx) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };

    // Get item
    const item = api.getItemByIdx(track, item_idx) orelse {
        response.err("NOT_FOUND", "Item not found");
        return;
    };

    // Bounds check take index
    const num_takes = api.itemTakeCount(item);
    if (take_idx < 0 or take_idx >= num_takes) {
        logging.warn("Invalid take index {d} (item has {d} takes)", .{ take_idx, num_takes });
        response.err("INVALID_TAKE_INDEX", "Take index out of range");
        return;
    }

    // Get take
    const take = api.getTakeByIdx(item, take_idx) orelse {
        response.err("NOT_FOUND", "Take not found");
        return;
    };

    // Set color within undo block
    api.undoBeginBlock();
    if (api.setTakeColor(take, color)) {
        api.undoEndBlock("REAmo: Set take color");
        api.updateTimeline();
        logging.debug("Set take color to {d}", .{color});
        response.success(null);
    } else {
        api.undoEndBlock("REAmo: Set take color (failed)");
        logging.warn("Failed to set take color to {d}", .{color});
        response.err("SET_FAILED", "Failed to set take color");
    }
}
