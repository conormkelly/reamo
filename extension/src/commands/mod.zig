const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../protocol.zig");
const ws_server = @import("../ws_server.zig");

// Import domain-specific command modules
const transport_cmds = @import("transport.zig");
const marker_cmds = @import("markers.zig");
const region_cmds = @import("regions.zig");
const item_cmds = @import("items.zig");
const take_cmds = @import("takes.zig");
const time_sel_cmds = @import("time_sel.zig");
const repeat_cmds = @import("repeat.zig");
const track_cmds = @import("tracks.zig");
const tempo_cmds = @import("tempo.zig");
const timesig_cmds = @import("timesig.zig");
const metronome_cmds = @import("metronome.zig");
const extstate_cmds = @import("extstate.zig");
const undo_cmds = @import("undo.zig");
const action_cmds = @import("actions.zig");

// Command handler function type
pub const Handler = *const fn (*const reaper.Api, protocol.CommandMessage, *ResponseWriter) void;

// Command registry entry
pub const Entry = struct {
    name: []const u8,
    handler: Handler,
};

// Response writer for sending responses to the requesting client only
pub const ResponseWriter = struct {
    client_id: usize,
    cmd_id: ?[]const u8,
    shared_state: *ws_server.SharedState,

    pub fn success(self: *ResponseWriter, payload: ?[]const u8) void {
        if (self.cmd_id == null) return; // No response expected if no id provided

        var buf: [512]u8 = undefined;
        const json = if (payload) |p|
            std.fmt.bufPrint(&buf, "{{\"type\":\"response\",\"id\":\"{s}\",\"success\":true,\"payload\":{s}}}", .{ self.cmd_id.?, p }) catch return
        else
            std.fmt.bufPrint(&buf, "{{\"type\":\"response\",\"id\":\"{s}\",\"success\":true}}", .{self.cmd_id.?}) catch return;

        self.shared_state.sendToClient(self.client_id, json);
    }

    pub fn err(self: *ResponseWriter, code: []const u8, message: []const u8) void {
        if (self.cmd_id == null) return;

        var buf: [512]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "{{\"type\":\"response\",\"id\":\"{s}\",\"success\":false,\"error\":{{\"code\":\"{s}\",\"message\":\"{s}\"}}}}", .{ self.cmd_id.?, code, message }) catch return;

        self.shared_state.sendToClient(self.client_id, json);
    }
};

// Aggregated registry from all domain modules
pub const registry = transport_cmds.handlers ++
    marker_cmds.handlers ++
    region_cmds.handlers ++
    item_cmds.handlers ++
    take_cmds.handlers ++
    time_sel_cmds.handlers ++
    repeat_cmds.handlers ++
    track_cmds.handlers ++
    tempo_cmds.handlers ++
    timesig_cmds.handlers ++
    metronome_cmds.handlers ++
    extstate_cmds.handlers ++
    undo_cmds.handlers ++
    action_cmds.handlers;

// Dispatch a command message to the appropriate handler
pub fn dispatch(api: *const reaper.Api, client_id: usize, data: []const u8, shared_state: *ws_server.SharedState) void {
    const msg_type = protocol.MessageType.parse(data);

    switch (msg_type) {
        .command => {
            const cmd = protocol.CommandMessage.parse(data) orelse {
                api.log("Reamo: Failed to parse command", .{});
                return;
            };

            var response = ResponseWriter{
                .client_id = client_id,
                .cmd_id = cmd.getId(),
                .shared_state = shared_state,
            };

            for (registry) |entry| {
                if (std.mem.eql(u8, cmd.command, entry.name)) {
                    entry.handler(api, cmd, &response);
                    return;
                }
            }

            api.log("Reamo: Unknown command: {s}", .{cmd.command});
            response.err("UNKNOWN_COMMAND", "Command not found");
        },
        .hello => {
            // Hello messages are handled directly by ws_server.zig
            // They should not reach the dispatch function
            api.log("Reamo: Unexpected hello message in dispatch", .{});
        },
        .unknown => {
            api.log("Reamo: Unknown message type", .{});
        },
    }
}

// ============================================================================
// Shared helper functions used by multiple command modules
// ============================================================================

// Helper to create null-terminated string from optional slice
// Returns pointer to buffer (null-terminated) or empty string literal
pub fn toNullTerminated(buf: *[65]u8, str: ?[]const u8) [*:0]const u8 {
    const s = str orelse return "";
    const len = @min(s.len, 64);
    @memcpy(buf[0..len], s[0..len]);
    buf[len] = 0;
    return @ptrCast(buf);
}

// Validate position value - returns null if invalid (NaN, Inf, or negative)
pub fn validatePosition(pos: ?f64) ?f64 {
    const p = pos orelse return null;
    if (std.math.isNan(p) or std.math.isInf(p)) return null;
    if (p < 0) return null;
    return p;
}

// ============================================================================
// Tests
// ============================================================================

test "dispatch handles unknown commands gracefully" {
    const data = "{\"type\":\"command\",\"command\":\"unknown/command\"}";
    const cmd = protocol.CommandMessage.parse(data);
    try std.testing.expect(cmd != null);
    try std.testing.expectEqualStrings("unknown/command", cmd.?.command);
}

test "registry contains expected commands" {
    const expected = [_][]const u8{
        // Transport
        "transport/play",
        "transport/stop",
        "transport/pause",
        "transport/record",
        "transport/toggle",
        "transport/seek",
        "transport/abort",
        "transport/goStart",
        "transport/goEnd",
        "transport/seekBeats",
        // Markers
        "marker/add",
        "marker/update",
        "marker/delete",
        "marker/goto",
        "marker/prev",
        "marker/next",
        // Regions
        "region/add",
        "region/update",
        "region/delete",
        "region/goto",
        // Items
        "item/setActiveTake",
        "item/move",
        "item/color",
        "item/lock",
        "item/notes",
        "item/delete",
        "item/goto",
        "item/selectInTimeSel",
        "item/unselectAll",
        // Takes
        "take/delete",
        "take/cropToActive",
        "take/next",
        "take/prev",
        // Time selection
        "timeSelection/set",
        "timeSelection/setBars",
        "timeSelection/clear",
        "timeSelection/goStart",
        "timeSelection/goEnd",
        "timeSelection/setStart",
        "timeSelection/setEnd",
        // Repeat
        "repeat/set",
        "repeat/toggle",
        // Tracks
        "track/setVolume",
        "track/setPan",
        "track/setMute",
        "track/setSolo",
        "track/setRecArm",
        "track/setRecMon",
        "track/setFxEnabled",
        // Tempo
        "tempo/set",
        "tempo/tap",
        // Time signature
        "timesig/set",
        // Metronome
        "metronome/toggle",
        // ExtState
        "extstate/get",
        "extstate/set",
        "extstate/projGet",
        "extstate/projSet",
        // Undo
        "undo/add",
        "undo/begin",
        "undo/end",
        // Actions
        "action/getState",
        "action/execute",
    };

    for (expected) |name| {
        var found = false;
        for (registry) |entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "toNullTerminated with value" {
    var buf: [65]u8 = undefined;
    const result = toNullTerminated(&buf, "hello");
    try std.testing.expectEqualStrings("hello", std.mem.sliceTo(result, 0));
}

test "toNullTerminated with null returns empty string" {
    var buf: [65]u8 = undefined;
    const result = toNullTerminated(&buf, null);
    try std.testing.expectEqual(@as(usize, 0), std.mem.len(result));
}

test "toNullTerminated truncates long strings" {
    var buf: [65]u8 = undefined;
    const long_str = "a" ** 100;
    const result = toNullTerminated(&buf, long_str);
    try std.testing.expectEqual(@as(usize, 64), std.mem.len(result));
}

test "validatePosition accepts valid positions" {
    try std.testing.expectEqual(@as(?f64, 0.0), validatePosition(0.0));
    try std.testing.expectEqual(@as(?f64, 10.5), validatePosition(10.5));
    try std.testing.expectEqual(@as(?f64, 1000.0), validatePosition(1000.0));
}

test "validatePosition rejects invalid positions" {
    try std.testing.expect(validatePosition(null) == null);
    try std.testing.expect(validatePosition(-1.0) == null);
    try std.testing.expect(validatePosition(-0.001) == null);
    try std.testing.expect(validatePosition(std.math.nan(f64)) == null);
    try std.testing.expect(validatePosition(std.math.inf(f64)) == null);
    try std.testing.expect(validatePosition(-std.math.inf(f64)) == null);
}

// Re-export tests from submodules
test {
    _ = transport_cmds;
    _ = marker_cmds;
    _ = region_cmds;
    _ = item_cmds;
    _ = take_cmds;
    _ = time_sel_cmds;
    _ = repeat_cmds;
    _ = track_cmds;
    _ = tempo_cmds;
    _ = timesig_cmds;
    _ = metronome_cmds;
    _ = extstate_cmds;
    _ = undo_cmds;
    _ = action_cmds;
}
