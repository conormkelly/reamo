const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");

// Action command handlers
pub const handlers = [_]mod.Entry{
    .{ .name = "action/getState", .handler = handleGetState },
    .{ .name = "action/execute", .handler = handleExecute },
};

// Get toggle state of an action (1=on, 0=off, -1=not a toggle action)
fn handleGetState(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const action_id = cmd.getInt("actionId") orelse {
        response.err("MISSING_ACTION_ID", "actionId is required");
        return;
    };

    const state = api.getCommandState(action_id);
    var payload_buf: [32]u8 = undefined;
    const payload = std.fmt.bufPrint(&payload_buf, "{{\"state\":{d}}}", .{state}) catch return;
    response.success(payload);
}

// Execute a REAPER action by command ID
fn handleExecute(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const action_id = cmd.getInt("actionId") orelse {
        response.err("MISSING_ACTION_ID", "actionId is required");
        return;
    };

    api.runCommand(action_id);
    api.log("Reamo: Executed action {d}", .{action_id});
    response.success(null);
}
