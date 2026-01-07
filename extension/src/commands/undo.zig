const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");
const logging = @import("../logging.zig");

// Add a simple undo point with description
pub fn handleAdd(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const description = cmd.getString("description") orelse {
        response.err("MISSING_DESCRIPTION", "description is required");
        return;
    };

    var desc_buf: [256]u8 = undefined;
    const len = @min(description.len, 255);
    @memcpy(desc_buf[0..len], description[0..len]);
    desc_buf[len] = 0;
    const desc_z: [*:0]const u8 = @ptrCast(&desc_buf);

    api.undoAddPoint(desc_z);
    logging.info("Added undo point: {s}", .{description});
    response.success(null);
}

// Begin an undo block (for grouping multiple operations)
pub fn handleBegin(api: anytype, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    api.undoBeginBlock();
    logging.info("Undo block started", .{});
    response.success(null);
}

// End an undo block with description
pub fn handleEnd(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const description = cmd.getString("description") orelse {
        response.err("MISSING_DESCRIPTION", "description is required");
        return;
    };

    var desc_buf: [256]u8 = undefined;
    const len = @min(description.len, 255);
    @memcpy(desc_buf[0..len], description[0..len]);
    desc_buf[len] = 0;
    const desc_z: [*:0]const u8 = @ptrCast(&desc_buf);

    api.undoEndBlock(desc_z);
    logging.info("Undo block ended: {s}", .{description});
    response.success(null);
}

// Perform undo
pub fn handleUndo(api: anytype, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    // Get the description of what will be undone BEFORE doing it
    const action_desc = api.canUndo();

    if (action_desc == null) {
        response.err("NOTHING_TO_UNDO", "No undo action available");
        return;
    }

    if (!api.doUndo()) {
        response.err("UNDO_FAILED", "Undo operation failed");
        return;
    }

    logging.info("Undo performed: {s}", .{action_desc.?});

    // Return success with the action that was undone
    response.successWithAction(action_desc.?);
}

// Perform redo
pub fn handleRedo(api: anytype, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    // Get the description of what will be redone BEFORE doing it
    const action_desc = api.canRedo();

    if (action_desc == null) {
        response.err("NOTHING_TO_REDO", "No redo action available");
        return;
    }

    if (!api.doRedo()) {
        response.err("REDO_FAILED", "Redo operation failed");
        return;
    }

    logging.info("Redo performed: {s}", .{action_desc.?});

    // Return success with the action that was redone
    response.successWithAction(action_desc.?);
}
