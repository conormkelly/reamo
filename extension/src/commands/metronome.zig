const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");

// Metronome command handlers
pub const handlers = [_]mod.Entry{
    .{ .name = "metronome/toggle", .handler = handleToggle },
};

// Toggle metronome (uses REAPER's built-in command)
fn handleToggle(api: *const reaper.Api, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.METRONOME_TOGGLE);
}
