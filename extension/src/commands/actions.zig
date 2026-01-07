const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");
const logging = @import("../logging.zig");

// Get toggle state of an action (1=on, 0=off, -1=not a toggle action)
pub fn handleGetToggleState(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const command_id = cmd.getInt("commandId") orelse {
        response.err("MISSING_COMMAND_ID", "commandId is required");
        return;
    };

    const state = api.getCommandState(command_id);
    var payload_buf: [32]u8 = undefined;
    const payload = std.fmt.bufPrint(&payload_buf, "{{\"state\":{d}}}", .{state}) catch return;
    response.success(payload);
}

// Execute a REAPER action by command ID
pub fn handleExecuteCommand(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const command_id = cmd.getInt("commandId") orelse {
        response.err("MISSING_COMMAND_ID", "commandId is required");
        return;
    };

    api.runCommand(command_id);
    logging.debug("Executed command {d}", .{command_id});
    response.success(null);
}

// Execute a REAPER action by named command identifier (e.g., "_SWS_ABOUT")
pub fn handleExecuteByName(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const name = cmd.getString("name") orelse {
        response.err("MISSING_NAME", "name is required");
        return;
    };

    const command_id = api.namedCommandLookup(name);
    if (command_id == 0) {
        response.err("NOT_FOUND", "Named command not found");
        return;
    }

    api.runCommand(command_id);
    logging.debug("Executed named command {s}", .{name});
    response.success(null);
}
