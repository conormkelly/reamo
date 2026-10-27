const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../core/protocol.zig");
const mod = @import("mod.zig");
const logging = @import("../core/logging.zig");

/// Set repeat state explicitly
pub fn handleSet(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const enabled = cmd.getFlag("enabled") orelse {
        response.err("MISSING_ENABLED", "enabled (0 or 1) is required");
        return;
    };

    api.setRepeat(enabled);
    logging.debug("Set repeat to {}", .{enabled});
}

/// Toggle repeat state (uses REAPER's built-in command)
pub fn handleToggle(api: anytype, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.TOGGLE_REPEAT);
}
