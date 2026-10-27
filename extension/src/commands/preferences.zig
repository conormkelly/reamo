const std = @import("std");
const protocol = @import("../core/protocol.zig");
const mod = @import("mod.zig");
const logging = @import("../core/logging.zig");

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
/// Params: enabled (0/1 or bool), measures (1-8), mode (0=measures, 1=marker); each optional.
/// These are REAPER's global preferences (saved in reaper.ini), so nothing is
/// written unless every value given is valid.
pub fn handleSetSeekSettings(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const enabled = cmd.getFlag("enabled");
    const measures = cmd.getInt("measures");
    const mode = cmd.getInt("mode");

    if (measures) |m| if (m < 1 or m > 8) {
        response.err("INVALID_MEASURES", "measures must be 1-8");
        return;
    };
    if (mode) |m| if (m != 0 and m != 1) {
        response.err("INVALID_MODE", "mode must be 0 (measures) or 1 (marker)");
        return;
    };

    if (enabled) |e| api.setSmoothSeekEnabled(e);
    if (measures) |m| api.setSmoothSeekMeasures(m);
    if (mode) |m| api.setSeekMode(m);

    response.success(null);
    logging.debug("Updated seek settings", .{});
}
