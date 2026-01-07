const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");
const logging = @import("../logging.zig");

// REAPER action: Master track: Toggle stereo/mono (L+R)
const MASTER_MONO_ACTION: c_int = 40917;

// Toggle master track mono/stereo mode
pub fn handleToggleMono(api: anytype, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    api.runCommand(MASTER_MONO_ACTION);

    // Return the new state (1 = mono, 0 = stereo)
    const state = api.getCommandState(MASTER_MONO_ACTION);
    const stereo_enabled = state != 1;

    var buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"stereoEnabled\":{s}}}", .{if (stereo_enabled) "true" else "false"}) catch {
        response.err("INTERNAL", "Buffer overflow");
        return;
    };

    logging.debug("Toggled master mono, stereoEnabled={s}", .{if (stereo_enabled) "true" else "false"});
    response.success(json);
}
