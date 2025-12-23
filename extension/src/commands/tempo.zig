const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");

// Tempo command handlers
pub const handlers = [_]mod.Entry{
    .{ .name = "tempo/set", .handler = handleSet },
    .{ .name = "tempo/tap", .handler = handleTap },
};

// Set tempo (BPM)
fn handleSet(api: *const reaper.Api, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const bpm = cmd.getFloat("bpm") orelse {
        response.err("MISSING_BPM", "bpm is required");
        return;
    };

    // Validate range (REAPER supports 2-960 BPM)
    if (bpm < 2.0 or bpm > 960.0) {
        response.err("INVALID_BPM", "bpm must be between 2 and 960");
        return;
    }

    api.setTempo(bpm);
    api.log("Reamo: Set tempo to {d:.2} BPM", .{bpm});
}

// Tap tempo (uses REAPER's built-in command)
fn handleTap(api: *const reaper.Api, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.TAP_TEMPO);
}
