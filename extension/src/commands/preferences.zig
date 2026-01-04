const std = @import("std");
const protocol = @import("../protocol.zig");
const mod = @import("mod.zig");
const logging = @import("../logging.zig");

// Preferences command handlers
pub const handlers = [_]mod.Entry{
    .{ .name = "preferences/getSeekSettings", .handler = handleGetSeekSettings },
    .{ .name = "preferences/setSeekSettings", .handler = handleSetSeekSettings },
};

/// Get all seek-related settings
/// Returns: {"enabled": true/false, "measures": N, "mode": "measures"|"marker"}
pub fn handleGetSeekSettings(api: anytype, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const enabled = api.getSmoothSeekEnabled();
    const measures = api.getSmoothSeekMeasures();
    const mode = api.getSeekMode();
    const mode_str = if (mode == 0) "measures" else "marker";

    var buf: [128]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"enabled\":{s},\"measures\":{d},\"mode\":\"{s}\"}}", .{
        if (enabled) "true" else "false",
        measures,
        mode_str,
    }) catch {
        response.err("INTERNAL", "Buffer overflow");
        return;
    };
    response.success(json);
}

/// Set seek-related settings
/// Params: enabled (int, 0 or 1), measures (int, optional), mode (int, 0=measures 1=marker, optional)
pub fn handleSetSeekSettings(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    // enabled is optional - only set if provided
    if (cmd.getInt("enabled")) |enabled_int| {
        api.setSmoothSeekEnabled(enabled_int != 0);
    }

    // measures is optional - only set if provided
    if (cmd.getInt("measures")) |measures| {
        api.setSmoothSeekMeasures(measures);
    }

    // mode is optional - only set if provided
    if (cmd.getInt("mode")) |mode| {
        api.setSeekMode(mode);
    }

    response.success(null);
    logging.debug("Updated seek settings", .{});
}
