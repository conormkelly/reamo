const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");
const logging = @import("../logging.zig");

// Metronome command handlers
pub const handlers = [_]mod.Entry{
    .{ .name = "metronome/toggle", .handler = handleToggle },
    .{ .name = "metronome/getVolume", .handler = handleGetVolume },
    .{ .name = "metronome/setVolume", .handler = handleSetVolume },
};

// Toggle metronome (uses REAPER's built-in command)
pub fn handleToggle(api: anytype, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.METRONOME_TOGGLE);
}

// Get metronome volume (returns both linear and dB)
pub fn handleGetVolume(api: anytype, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const linear = api.getMetronomeVolume();
    const db = reaper.Api.linearToDb(linear);

    var buf: [128]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"volume\":{d:.6},\"volumeDb\":{d:.2}}}", .{ linear, db }) catch {
        response.err("INTERNAL", "Buffer overflow");
        return;
    };
    response.success(json);
}

// Set metronome volume (accepts volumeDb or volume)
pub fn handleSetVolume(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    // Accept either volumeDb (preferred) or volume (linear)
    var linear: f64 = undefined;

    if (cmd.getFloat("volumeDb")) |db| {
        linear = reaper.Api.dbToLinear(db);
    } else if (cmd.getFloat("volume")) |vol| {
        linear = vol;
    } else {
        response.err("INVALID_PARAMS", "volumeDb or volume required");
        return;
    }

    if (api.setMetronomeVolume(linear)) {
        logging.debug("Set metronome volume to {d:.3}", .{linear});
        response.success(null);
    } else {
        response.err("FAILED", "Could not set metronome volume");
    }
}
