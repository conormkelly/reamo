const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");

// Take command handlers
pub const handlers = [_]mod.Entry{
    .{ .name = "take/delete", .handler = handleTakeDelete },
    .{ .name = "take/cropToActive", .handler = handleTakeCropToActive },
    .{ .name = "take/next", .handler = handleTakeNext },
    .{ .name = "take/prev", .handler = handleTakePrev },
};

fn handleTakeDelete(api: *const reaper.Api, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    // Operates on selected items - uses REAPER's built-in command
    api.undoBeginBlock();
    api.runCommand(reaper.Command.DELETE_ACTIVE_TAKE);
    api.undoEndBlock("Delete active take (API)");
    api.log("Reamo: Deleted active take", .{});
}

fn handleTakeCropToActive(api: *const reaper.Api, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    // Operates on selected items - uses REAPER's built-in command
    api.undoBeginBlock();
    api.runCommand(reaper.Command.CROP_TO_ACTIVE_TAKE);
    api.undoEndBlock("Crop to active take (API)");
    api.log("Reamo: Cropped to active take", .{});
}

// Activate next take in selected items
fn handleTakeNext(api: *const reaper.Api, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.NEXT_TAKE);
    api.log("Reamo: Activated next take", .{});
}

// Activate previous take in selected items
fn handleTakePrev(api: *const reaper.Api, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.PREV_TAKE);
    api.log("Reamo: Activated previous take", .{});
}
