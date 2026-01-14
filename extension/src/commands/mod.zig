const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../protocol.zig");
const ws_server = @import("../ws_server.zig");
const gesture_state = @import("../gesture_state.zig");
const playlist_mod = @import("../playlist.zig");
const errors = @import("../errors.zig");
const logging = @import("../logging.zig");
const toggle_subscriptions = @import("../toggle_subscriptions.zig");
const project_notes = @import("../project_notes.zig");
const guid_cache = @import("../guid_cache.zig");
const track_subscriptions = @import("../track_subscriptions.zig");
const peaks_subscriptions = @import("../peaks_subscriptions.zig");
const tiered_state = @import("../tiered_state.zig");

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
    track_subs: ?*track_subscriptions.TrackSubscriptions = null,
    peaks_subs: ?*peaks_subscriptions.PeaksSubscriptions = null,
    tiered: ?*tiered_state.TieredArenas = null,
};

/// Global command context - initialized by main.zig
pub var g_ctx: CommandContext = .{};

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
            std.fmt.bufPrint(&buf, "{{\"type\":\"response\",\"id\":\"{s}\",\"success\":true,\"payload\":{s}}}", .{ self.cmd_id.?, p }) catch {
                logging.warn("ResponseWriter.success: buffer overflow for cmd_id={s}, payload_len={d}", .{ self.cmd_id.?, p.len });
                return;
            }
        else
            std.fmt.bufPrint(&buf, "{{\"type\":\"response\",\"id\":\"{s}\",\"success\":true}}", .{self.cmd_id.?}) catch {
                logging.warn("ResponseWriter.success: buffer overflow for cmd_id={s}", .{self.cmd_id.?});
                return;
            };

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
        const json = std.fmt.bufPrint(&buf, "{{\"type\":\"response\",\"id\":\"{s}\",\"success\":true,\"action\":\"{s}\"}}", .{ self.cmd_id.?, escaped[0..escaped_len] }) catch {
            logging.warn("ResponseWriter.successWithAction: buffer overflow for cmd_id={s}", .{self.cmd_id.?});
            return;
        };

        self.shared_state.sendToClient(self.client_id, json);
    }

    /// Success response for commands with large payloads (e.g., project notes).
    /// Heap-allocates a 512KB buffer per call to avoid stack overflow and shared state issues.
    /// Safe for timer callbacks since they run on main thread (not audio thread).
    /// See DEVELOPMENT.md "Response Buffer Sizes" and research/ZIG_MEMORY_MANAGEMENT.md.
    pub fn successLargePayload(self: *ResponseWriter, payload: []const u8) void {
        if (self.cmd_id == null) return;

        // Heap allocation per call - safe on main thread, avoids shared state between commands
        // c_allocator is safe for timer callbacks (see ZIG_MEMORY_MANAGEMENT.md)
        // 2MB handles action list plus JSON wrapper overhead
        const allocator = std.heap.c_allocator;
        const buf = allocator.alloc(u8, 2 * 1024 * 1024) catch {
            self.err("ALLOC_FAILED", "Failed to allocate response buffer");
            return;
        };
        defer allocator.free(buf);

        const json = std.fmt.bufPrint(buf, "{{\"type\":\"response\",\"id\":\"{s}\",\"success\":true,\"payload\":{s}}}", .{ self.cmd_id.?, payload }) catch {
            // Payload too large even for this buffer - send error instead
            self.err("RESPONSE_TOO_LARGE", "Response payload exceeds maximum size");
            return;
        };

        self.shared_state.sendToClient(self.client_id, json);
    }

    pub fn err(self: *ResponseWriter, code: []const u8, message: []const u8) void {
        if (self.cmd_id == null) return;

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
    const len = @min(s.len, 64);
    @memcpy(buf[0..len], s[0..len]);
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

// ============================================================================
// Tests
// ============================================================================

test "dispatch handles unknown commands gracefully" {
    const data = "{\"type\":\"command\",\"command\":\"unknown/command\"}";
    const cmd = protocol.CommandMessage.parse(data);
    try std.testing.expect(cmd != null);
    try std.testing.expectEqualStrings("unknown/command", cmd.?.command);
}

test "comptime registry contains expected commands" {
    // Spot-check that key commands from each domain are registered
    const expected = [_][]const u8{
        "transport/play",
        "transport/playPause",
        "marker/add",
        "region/batch",
        "item/getPeaks",
        "track/setVolume",
        "tempo/set",
        "gesture/start",
        "playlist/play",
        "debug/memoryStats",
    };

    inline for (expected) |name| {
        var found = false;
        inline for (comptime_registry.all) |entry| {
            if (std.mem.eql(u8, name, entry[0])) {
                found = true;
            }
        }
        if (!found) {
            @compileError("Missing command in registry: " ++ name);
        }
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
    _ = debug_cmds;
}
