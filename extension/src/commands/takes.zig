const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");
const logging = @import("../logging.zig");

pub fn handleTakeDelete(api: anytype, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    // Operates on selected items - uses REAPER's built-in command
    api.undoBeginBlock();
    api.runCommand(reaper.Command.DELETE_ACTIVE_TAKE);
    api.undoEndBlock("Reamo: Delete active take");
    logging.debug("Deleted active take", .{});
}

pub fn handleTakeCropToActive(api: anytype, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    // Operates on selected items - uses REAPER's built-in command
    api.undoBeginBlock();
    api.runCommand(reaper.Command.CROP_TO_ACTIVE_TAKE);
    api.undoEndBlock("Reamo: Crop to active take");
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
