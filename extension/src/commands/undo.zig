const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../core/protocol.zig");
const mod = @import("mod.zig");
const logging = @import("../core/logging.zig");

// Add a simple undo point with description, stored as the user typed it
pub fn handleAdd(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const description = (cmd.getTextAlloc("description", std.heap.c_allocator) catch {
        response.err("ALLOC_FAILED", "Failed to read description");
        return;
    }) orelse {
        response.err("MISSING_DESCRIPTION", "description is required");
        return;
    };
    defer std.heap.c_allocator.free(description);

    api.undoAddPoint(description.ptr);
    logging.info("Added undo point: {s}", .{description});
    response.success(null);
}

// NOTE: undo/begin and undo/end commands deliberately removed - they're dangerous with multiple
// clients as REAPER doesn't support nested undo blocks. See research/REAPER_UNDO_BLOCKS.md
// Use gesture-based undo coalescing instead (gesture/start, gesture/end).

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
