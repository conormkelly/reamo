const std = @import("std");
const utf8 = @import("../core/utf8.zig");
const reaper = @import("../reaper.zig");
const protocol = @import("../core/protocol.zig");
const ws_server = @import("../server/ws_server.zig");
const gesture_state = @import("../server/gesture_state.zig");
const playlist_mod = @import("../state/playlist.zig");
const errors = @import("../core/errors.zig");
const logging = @import("../core/logging.zig");
const toggle_subscriptions = @import("../subscriptions/toggle_subscriptions.zig");
const project_notes = @import("../subscriptions/project_notes.zig");
const guid_cache = @import("../state/guid_cache.zig");
const item_guid_cache = @import("../state/item_guid_cache.zig");
const track_subscriptions = @import("../subscriptions/track_subscriptions.zig");
const peaks_subscriptions = @import("../subscriptions/peaks_subscriptions.zig");
const routing_subscriptions = @import("../subscriptions/routing_subscriptions.zig");
const trackfx_subscriptions = @import("../subscriptions/trackfx_subscriptions.zig");
const trackfxparam_subscriptions = @import("../subscriptions/trackfxparam_subscriptions.zig");
const tuner_subscriptions = @import("../subscriptions/tuner_subscriptions.zig");
const tiered_state = @import("../server/tiered_state.zig");
const audio_stream_mod = @import("../audio/stream.zig");

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
const count_in_cmds = @import("count_in.zig");
const master_cmds = @import("master.zig");
const extstate_cmds = @import("extstate.zig");
const undo_cmds = @import("undo.zig");
const action_cmds = @import("actions.zig");
const gesture_cmds = @import("gesture.zig");
pub const toggle_state_cmds = @import("toggle_state.zig");
const midi_cmds = @import("midi.zig");
pub const project_notes_cmds = @import("project_notes.zig");
const preferences_cmds = @import("preferences.zig");
pub const debug_cmds = @import("debug.zig");

// Comptime tuple registry for anytype dispatch
const comptime_registry = @import("registry.zig");

// Re-export GestureState for convenience
pub const GestureState = gesture_state.GestureState;
pub const ControlId = gesture_state.ControlId;

// Re-export PlaylistState for convenience
pub const PlaylistState = playlist_mod.State;

// =============================================================================
// Command Context - Consolidated global state for command handlers
// =============================================================================
// Initialized by main.zig during extension startup.
// Command handlers access via mod.g_ctx.

pub const CommandContext = struct {
    toggle_subs: ?*toggle_subscriptions.ToggleSubscriptions = null,
    notes_subs: ?*project_notes.NotesSubscriptions = null,
    guid_cache: ?*guid_cache.GuidCache = null,
    item_cache: ?*item_guid_cache.ItemGuidCache = null,
    track_subs: ?*track_subscriptions.TrackSubscriptions = null,
    peaks_subs: ?*peaks_subscriptions.PeaksSubscriptions = null,
    routing_subs: ?*routing_subscriptions.RoutingSubscriptions = null,
    trackfx_subs: ?*trackfx_subscriptions.TrackFxSubscriptions = null,
    trackfxparam_subs: ?*trackfxparam_subscriptions.TrackFxParamSubscriptions = null,
    tuner_subs: ?*tuner_subscriptions.TunerSubscriptions = null,
    tiered: ?*tiered_state.TieredArenas = null,
    audio_stream: ?*audio_stream_mod.AudioStreamManager = null,
};

/// Global command context - initialized by main.zig
pub var g_ctx: CommandContext = .{};

/// Time of a bar.beat as the user reads it on REAPER's ruler: `bar` as
/// displayed (the project start measure shifts it; 58% of real projects
/// start at -5 or similar) and `beat` 1-based in the meter's own beats
/// (eighths in 6/8), which is how TimeMap2_beatsToTime takes them. null if
/// the bar is out of range once the start measure is applied.
pub fn displayedBarBeatToTime(api: anytype, bar: c_int, beat: f64) ?f64 {
    const measure = std.math.cast(c_int, @as(i64, bar) - api.getBarOffset()) orelse return null;
    if (validateBar(measure) == null) return null;
    return api.barBeatToTime(measure, beat);
}

/// Whether a client is mid-drag on `control`. A change inside a drag is
/// covered by the undo point recorded when the drag ends; a change outside
/// one (a double-tap reset) needs an undo point of its own.
pub fn inGesture(response: *const ResponseWriter, control: gesture_state.ControlId) bool {
    const gestures = response.gestures orelse return false;
    return gestures.isActive(control);
}

/// The name a marker/region add or update should store, NUL-terminated and
/// whole: the client's text (unescaped) when it sent a non-empty one, else a
/// copy of `current` (REAPER's own string must not be passed back into the
/// setter that may free it). Free with c_allocator.
pub fn resolveNameZ(provided: ?[:0]u8, current: []const u8) ![:0]u8 {
    if (provided) |p| {
        if (p.len > 0) return std.heap.c_allocator.dupeZ(u8, p);
    }
    return std.heap.c_allocator.dupeZ(u8, current);
}

// Response writer for sending responses to the requesting client only
pub const ResponseWriter = struct {
    client_id: usize,
    cmd_id: ?[]const u8,
    shared_state: *ws_server.SharedState,
    gestures: ?*GestureState,
    playlist: ?*PlaylistState = null,
    /// Whether this command has been answered (see dispatch).
    responded: bool = false,

    /// Payload responses larger than this are refused rather than sent: one
    /// frame must fit the socket send buffer (see WsHandler.init).
    const MAX_RESPONSE_PAYLOAD = 2 * 1024 * 1024;

    pub fn success(self: *ResponseWriter, payload: ?[]const u8) void {
        if (self.cmd_id == null) return; // No response expected if no id provided
        self.responded = true;

        // Most responses fit on the stack; larger ones get an exact-size heap
        // buffer instead of being dropped (the client would wait forever).
        var buf: [512]u8 = undefined;
        if (payload) |p| {
            const fmt = "{{\"type\":\"response\",\"id\":\"{s}\",\"success\":true,\"payload\":{s}}}";
            const args = .{ self.cmd_id.?, p };
            if (std.fmt.bufPrint(&buf, fmt, args)) |json| {
                self.shared_state.sendToClient(self.client_id, json);
                return;
            } else |_| {}
            if (p.len > MAX_RESPONSE_PAYLOAD) {
                self.err("RESPONSE_TOO_LARGE", "Response payload exceeds maximum size");
                return;
            }
            const json = std.fmt.allocPrint(std.heap.c_allocator, fmt, args) catch {
                self.err("ALLOC_FAILED", "Failed to allocate response buffer");
                return;
            };
            defer std.heap.c_allocator.free(json);
            self.shared_state.sendToClient(self.client_id, json);
        } else {
            const json = std.fmt.bufPrint(&buf, "{{\"type\":\"response\",\"id\":\"{s}\",\"success\":true}}", .{self.cmd_id.?}) catch {
                logging.warn("ResponseWriter.success: id too long for cmd_id={s}", .{self.cmd_id.?});
                return;
            };
            self.shared_state.sendToClient(self.client_id, json);
        }
    }

    /// Success response with an action string (for undo/redo commands).
    /// The action is REAPER's undo description, which can quote user text
    /// (track names and the like), so it is escaped like any other string.
    pub fn successWithAction(self: *ResponseWriter, action: []const u8) void {
        if (self.cmd_id == null) return;
        self.responded = true;

        // REAPER's undo descriptions are short; 256 bytes escapes to at most
        // ~1.5 KB (control characters become \u00XX).
        var buf: [2048]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        const w = stream.writer();
        w.print("{{\"type\":\"response\",\"id\":\"{s}\",\"success\":true,\"action\":\"", .{self.cmd_id.?}) catch {
            logging.warn("ResponseWriter.successWithAction: id too long for cmd_id={s}", .{self.cmd_id.?});
            return;
        };
        protocol.writeJsonString(w, utf8.prefix(action, 256)) catch return;
        w.writeAll("\"}") catch return;
        self.shared_state.sendToClient(self.client_id, stream.getWritten());
    }

    /// Success response for commands whose payload is routinely large (action
    /// lists, FX/plugin lists, project notes). Same as `success`, which sizes
    /// its buffer to the payload.
    pub fn successLargePayload(self: *ResponseWriter, payload: []const u8) void {
        self.success(payload);
    }

    pub fn err(self: *ResponseWriter, code: []const u8, message: []const u8) void {
        if (self.cmd_id == null) return;
        self.responded = true;

        var buf: [512]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "{{\"type\":\"response\",\"id\":\"{s}\",\"success\":false,\"error\":{{\"code\":\"{s}\",\"message\":\"{s}\"}}}}", .{ self.cmd_id.?, code, message }) catch {
            logging.warn("ResponseWriter.err: buffer overflow for cmd_id={s}, code={s}", .{ self.cmd_id.?, code });
            return;
        };

        self.shared_state.sendToClient(self.client_id, json);
    }

    /// Send a non-fatal warning to the client
    /// The command still succeeds, but the client is informed of an issue
    /// Format: {"type":"response","id":"...","success":true,"warning":{"code":"...","message":"..."}}
    pub fn warn(self: *ResponseWriter, code: []const u8, message: []const u8) void {
        if (self.cmd_id == null) return;
        self.responded = true;

        var buf: [512]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "{{\"type\":\"response\",\"id\":\"{s}\",\"success\":true,\"warning\":{{\"code\":\"{s}\",\"message\":\"{s}\"}}}}", .{ self.cmd_id.?, code, message }) catch {
            logging.warn("ResponseWriter.warn: buffer overflow for cmd_id={s}, code={s}", .{ self.cmd_id.?, code });
            return;
        };

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
                    // A command sent with an id is always answered: many
                    // handlers report only failures, and a client awaiting
                    // one of them could not tell success from loss.
                    if (!response.responded) response.success(null);
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
        .ping => {
            // Ping messages are handled directly by ws_server.zig (bypass queue)
            // They should not reach the dispatch function
            logging.warn("Unexpected ping message in dispatch", .{});
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
    const len = utf8.copyPrefix(buf[0..64], s);
    buf[len] = 0;
    // SAFETY: @alignCast unnecessary - u8 has alignment 1, always valid
    return @ptrCast(buf);
}

// Validate position value - returns null if invalid (NaN, Inf, or negative)
pub fn validatePosition(pos: ?f64) ?f64 {
    const p = pos orelse return null;
    if (std.math.isNan(p) or std.math.isInf(p)) return null;
    if (p < 0) return null;
    return p;
}

/// Largest bar number magnitude accepted from clients. Bars may be negative
/// (project measure offset), but nothing real is a million bars from zero, and
/// the bound keeps `bar - 1` / `bar - offset` arithmetic inside c_int.
pub const MAX_BAR_MAGNITUDE: c_int = 1_000_000;

// Validate a client-supplied bar number - returns null if out of range
pub fn validateBar(bar: ?c_int) ?c_int {
    const b = bar orelse return null;
    if (b < -MAX_BAR_MAGNITUDE or b > MAX_BAR_MAGNITUDE) return null;
    return b;
}

/// Test helper: run a handler on a raw client message, as dispatch would.
/// The message must carry no "id", so the ResponseWriter never touches
/// shared_state and handlers can be exercised against MockBackend directly.
pub fn testRunHandler(api: anytype, comptime handler: anytype, json: []const u8) void {
    testRunPlaylistHandler(api, handler, json, null);
}

/// testRunHandler for handlers that read playlist state from the ResponseWriter.
pub fn testRunPlaylistHandler(api: anytype, comptime handler: anytype, json: []const u8, playlist: ?*PlaylistState) void {
    const cmd = protocol.CommandMessage.parse(json).?;
    std.debug.assert(cmd.getId() == null);
    var shared: ws_server.SharedState = undefined;
    var response = ResponseWriter{
        .client_id = 1,
        .cmd_id = null,
        .shared_state = &shared,
        .gestures = null,
        .playlist = playlist,
    };
    handler(api, cmd, &response);
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
    // Spot-check that key commands from each domain are registered
    // Uses runtime checks to avoid circular import issues during test compilation
    const expected = [_][]const u8{
        "transport/play",
        "transport/playPause",
        "marker/add",
        "region/batch",
        "track/setVolume",
        "tempo/set",
        "gesture/start",
        "playlist/play",
        "debug/memoryStats",
        "send/add",
        "receive/add",
        "hw/add",
    };

    for (expected) |name| {
        var found = false;
        inline for (comptime_registry.all) |entry| {
            if (std.mem.eql(u8, name, entry[0])) {
                found = true;
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
    _ = count_in_cmds;
    _ = master_cmds;
    _ = extstate_cmds;
    _ = undo_cmds;
    _ = action_cmds;
    _ = gesture_cmds;
    _ = toggle_state_cmds;
    _ = midi_cmds;
    _ = project_notes_cmds;
    _ = debug_cmds;
    _ = @import("send.zig");
    _ = @import("receive.zig");
    _ = @import("hw_output.zig");
}
