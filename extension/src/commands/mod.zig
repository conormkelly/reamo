const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../protocol.zig");
const ws_server = @import("../ws_server.zig");
const gesture_state = @import("../gesture_state.zig");
const playlist_mod = @import("../playlist.zig");
const errors = @import("../errors.zig");
const logging = @import("../logging.zig");

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
const master_cmds = @import("master.zig");
const extstate_cmds = @import("extstate.zig");
const undo_cmds = @import("undo.zig");
const action_cmds = @import("actions.zig");
const gesture_cmds = @import("gesture.zig");
pub const toggle_state_cmds = @import("toggle_state.zig");
const midi_cmds = @import("midi.zig");
pub const project_notes_cmds = @import("project_notes.zig");
const preferences_cmds = @import("preferences.zig");

// Command registry entry (used only for legacy test registry - dispatch uses comptime registry)
pub const Entry = struct {
    name: []const u8,
    handler: *const anyopaque, // Type-erased; actual dispatch uses comptime registry
};

// Legacy type alias for backwards compatibility with handler arrays
pub const Handler = *const anyopaque;

// Comptime tuple registry for anytype dispatch
const comptime_registry = @import("registry.zig");

// Re-export GestureState for convenience
pub const GestureState = gesture_state.GestureState;
pub const ControlId = gesture_state.ControlId;

// Re-export PlaylistState for convenience
pub const PlaylistState = playlist_mod.State;

// Response writer for sending responses to the requesting client only
pub const ResponseWriter = struct {
    client_id: usize,
    cmd_id: ?[]const u8,
    shared_state: *ws_server.SharedState,
    gestures: ?*GestureState,
    playlist: ?*PlaylistState = null,

    pub fn success(self: *ResponseWriter, payload: ?[]const u8) void {
        if (self.cmd_id == null) return; // No response expected if no id provided

        var buf: [512]u8 = undefined;
        const json = if (payload) |p|
            std.fmt.bufPrint(&buf, "{{\"type\":\"response\",\"id\":\"{s}\",\"success\":true,\"payload\":{s}}}", .{ self.cmd_id.?, p }) catch return
        else
            std.fmt.bufPrint(&buf, "{{\"type\":\"response\",\"id\":\"{s}\",\"success\":true}}", .{self.cmd_id.?}) catch return;

        self.shared_state.sendToClient(self.client_id, json);
    }

    /// Success response with an action string (for undo/redo commands)
    pub fn successWithAction(self: *ResponseWriter, action: []const u8) void {
        if (self.cmd_id == null) return;

        // Escape the action string for JSON
        var escaped: [512]u8 = undefined;
        var escaped_len: usize = 0;
        for (action) |c| {
            if (escaped_len + 2 > escaped.len) break;
            switch (c) {
                '"' => {
                    escaped[escaped_len] = '\\';
                    escaped[escaped_len + 1] = '"';
                    escaped_len += 2;
                },
                '\\' => {
                    escaped[escaped_len] = '\\';
                    escaped[escaped_len + 1] = '\\';
                    escaped_len += 2;
                },
                '\n' => {
                    escaped[escaped_len] = '\\';
                    escaped[escaped_len + 1] = 'n';
                    escaped_len += 2;
                },
                else => {
                    if (c >= 0x20) {
                        escaped[escaped_len] = c;
                        escaped_len += 1;
                    }
                },
            }
        }

        var buf: [768]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "{{\"type\":\"response\",\"id\":\"{s}\",\"success\":true,\"action\":\"{s}\"}}", .{ self.cmd_id.?, escaped[0..escaped_len] }) catch return;

        self.shared_state.sendToClient(self.client_id, json);
    }

    pub fn err(self: *ResponseWriter, code: []const u8, message: []const u8) void {
        if (self.cmd_id == null) return;

        var buf: [512]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "{{\"type\":\"response\",\"id\":\"{s}\",\"success\":false,\"error\":{{\"code\":\"{s}\",\"message\":\"{s}\"}}}}", .{ self.cmd_id.?, code, message }) catch return;

        self.shared_state.sendToClient(self.client_id, json);
    }

    /// Send a non-fatal warning to the client
    /// The command still succeeds, but the client is informed of an issue
    /// Format: {"type":"response","id":"...","success":true,"warning":{"code":"...","message":"..."}}
    pub fn warn(self: *ResponseWriter, code: []const u8, message: []const u8) void {
        if (self.cmd_id == null) return;

        var buf: [512]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "{{\"type\":\"response\",\"id\":\"{s}\",\"success\":true,\"warning\":{{\"code\":\"{s}\",\"message\":\"{s}\"}}}}", .{ self.cmd_id.?, code, message }) catch return;

        self.shared_state.sendToClient(self.client_id, json);
    }

    /// Broadcast an error event to ALL connected clients
    /// Used for system-level errors that affect all clients (not per-command errors)
    pub fn broadcastError(self: *ResponseWriter, event: errors.ErrorEvent) void {
        var buf: [512]u8 = undefined;
        if (event.toJson(&buf)) |json| {
            self.shared_state.broadcast(json);
        }
    }

    /// Broadcast an error event from a Zig error to ALL connected clients
    pub fn broadcastErrorFromErr(self: *ResponseWriter, zig_err: anyerror, detail: ?[]const u8) void {
        self.broadcastError(errors.ErrorEvent.fromError(zig_err, detail));
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
    master_cmds.handlers ++
    extstate_cmds.handlers ++
    undo_cmds.handlers ++
    action_cmds.handlers ++
    gesture_cmds.handlers ++
    toggle_state_cmds.handlers ++
    midi_cmds.handlers ++
    project_notes_cmds.handlers ++
    preferences_cmds.handlers;

/// Dispatch a command message to the appropriate handler.
/// Accepts any backend type (RealBackend, MockBackend) via anytype.
/// Uses inline for to unroll the comptime registry at compile time.
pub fn dispatch(api: anytype, client_id: usize, data: []const u8, shared_state: *ws_server.SharedState, gestures: ?*GestureState, playlist: ?*PlaylistState) void {
    const msg_type = protocol.MessageType.parse(data);

    switch (msg_type) {
        .command => {
            const cmd = protocol.CommandMessage.parse(data) orelse {
                logging.warn("Failed to parse command", .{});
                return;
            };

            var response = ResponseWriter{
                .client_id = client_id,
                .cmd_id = cmd.getId(),
                .shared_state = shared_state,
                .gestures = gestures,
                .playlist = playlist,
            };

            // Use inline for to unroll the comptime tuple registry.
            // Each handler is called directly with the concrete api type.
            inline for (comptime_registry.all) |entry| {
                if (std.mem.eql(u8, cmd.command, entry[0])) {
                    entry[1](api, cmd, &response);
                    return;
                }
            }

            logging.warn("Unknown command: {s}", .{cmd.command});
            response.err("UNKNOWN_COMMAND", "Command not found");
        },
        .hello => {
            // Hello messages are handled directly by ws_server.zig
            // They should not reach the dispatch function
            logging.warn("Unexpected hello message in dispatch", .{});
        },
        .clockSync => {
            // Clock sync messages are handled directly by ws_server.zig (bypass queue)
            // They should not reach the dispatch function
            logging.warn("Unexpected clockSync message in dispatch", .{});
        },
        .unknown => {
            logging.warn("Unknown message type", .{});
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
        "region/batch",
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
        "item/getPeaks",
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
        "tempo/snap",
        "tempo/getBarDuration",
        "tempo/timeToBeats",
        "tempo/barsToTime",
        // Time signature
        "timesig/set",
        // Metronome
        "metronome/toggle",
        // Master
        "master/toggleMono",
        // ExtState
        "extstate/get",
        "extstate/set",
        "extstate/projGet",
        "extstate/projSet",
        // Undo
        "undo/add",
        "undo/begin",
        "undo/end",
        "undo/do",
        "redo/do",
        // Actions
        "action/getState",
        "action/execute",
        // Gestures
        "gesture/start",
        "gesture/end",
        // Toggle state subscriptions
        "actionToggleState/subscribe",
        "actionToggleState/unsubscribe",
        // MIDI
        "midi/cc",
        "midi/pc",
        // Project Notes
        "projectNotes/subscribe",
        "projectNotes/unsubscribe",
        "projectNotes/get",
        "projectNotes/set",
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
    _ = master_cmds;
    _ = extstate_cmds;
    _ = undo_cmds;
    _ = action_cmds;
    _ = gesture_cmds;
    _ = toggle_state_cmds;
    _ = midi_cmds;
    _ = project_notes_cmds;
}
