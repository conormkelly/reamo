const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");

// Repeat command handlers
pub const handlers = [_]mod.Entry{
    .{ .name = "repeat/set", .handler = handleSet },
    .{ .name = "repeat/toggle", .handler = handleToggle },
};

// Set repeat state explicitly
fn handleSet(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const enabled = cmd.getInt("enabled") orelse {
        response.err("MISSING_ENABLED", "enabled (0 or 1) is required");
        return;
    };

    api.setRepeat(enabled != 0);
    api.log("Reamo: Set repeat to {}", .{enabled != 0});
}

// Toggle repeat state (uses REAPER's built-in command)
fn handleToggle(api: *const reaper.Api, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.TOGGLE_REPEAT);
}
