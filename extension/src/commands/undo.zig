const std = @import("std");
const utf8 = @import("../core/utf8.zig");
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
    logging.debug("Added undo point ({d}-byte description)", .{description.len});
    response.success(null);
}

// NOTE: undo/begin and undo/end commands deliberately removed - they're dangerous with multiple
// clients as REAPER doesn't support nested undo blocks. See research/REAPER_UNDO_BLOCKS.md
// Use gesture-based undo coalescing instead (gesture/start, gesture/end).

/// REAPER's description of the step, copied (at a character boundary, as
/// much as the response sends). REAPER owns the string, and undoing or
/// redoing rearranges the history it lives in, so it can't be read after.
fn copyDescription(desc: []const u8, buf: *[256]u8) []const u8 {
    return buf[0..utf8.copyPrefix(buf, desc)];
}

// Perform undo
pub fn handleUndo(api: anytype, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    // Get the description of what will be undone BEFORE doing it
    var desc_buf: [256]u8 = undefined;
    const action_desc = if (api.canUndo()) |desc| copyDescription(desc, &desc_buf) else null;

    if (action_desc == null) {
        response.err("NOTHING_TO_UNDO", "No undo action available");
        return;
    }

    if (!api.doUndo()) {
        response.err("UNDO_FAILED", "Undo operation failed");
        return;
    }

    logging.debug("Undo performed: {s}", .{action_desc.?});

    // Return success with the action that was undone
    response.successWithAction(action_desc.?);
}

// Perform redo
pub fn handleRedo(api: anytype, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    // Get the description of what will be redone BEFORE doing it
    var desc_buf: [256]u8 = undefined;
    const action_desc = if (api.canRedo()) |desc| copyDescription(desc, &desc_buf) else null;

    if (action_desc == null) {
        response.err("NOTHING_TO_REDO", "No redo action available");
        return;
    }

    if (!api.doRedo()) {
        response.err("REDO_FAILED", "Redo operation failed");
        return;
    }

    logging.debug("Redo performed: {s}", .{action_desc.?});

    // Return success with the action that was redone
    response.successWithAction(action_desc.?);
}
