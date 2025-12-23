const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");

// Undo command handlers
pub const handlers = [_]mod.Entry{
    .{ .name = "undo/add", .handler = handleAdd },
    .{ .name = "undo/begin", .handler = handleBegin },
    .{ .name = "undo/end", .handler = handleEnd },
};

// Add a simple undo point with description
fn handleAdd(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
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
    api.log("Reamo: Added undo point: {s}", .{description});
    response.success(null);
}

// Begin an undo block (for grouping multiple operations)
fn handleBegin(api: *const reaper.Api, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    api.undoBeginBlock();
    api.log("Reamo: Undo block started", .{});
    response.success(null);
}

// End an undo block with description
fn handleEnd(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
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
    api.log("Reamo: Undo block ended: {s}", .{description});
    response.success(null);
}
