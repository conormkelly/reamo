const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../core/protocol.zig");
const mod = @import("mod.zig");
const gesture_state = @import("../server/gesture_state.zig");
const logging = @import("../core/logging.zig");
const tracks = @import("tracks.zig");

/// Parse control type from command params.
/// Accepts either trackIdx or trackGuid (using resolveTrack pattern); either
/// way the gesture is keyed by the track's GUID (see gesture_state.trackKey).
fn parseControlId(api: anytype, cmd: protocol.CommandMessage) ?gesture_state.ControlId {
    const control_type_str = cmd.getString("controlType") orelse return null;

    const resolution = tracks.resolveTrack(api, cmd) orelse return null;
    const track = gesture_state.trackKey(api, resolution.track) orelse return null;

    if (std.mem.eql(u8, control_type_str, "volume")) {
        return gesture_state.ControlId.volume(track);
    } else if (std.mem.eql(u8, control_type_str, "pan")) {
        return gesture_state.ControlId.pan(track);
    } else if (std.mem.eql(u8, control_type_str, "send")) {
        const send_idx = cmd.getInt("sendIdx") orelse return null;
        return gesture_state.ControlId.sendVolume(track, send_idx);
    } else if (std.mem.eql(u8, control_type_str, "sendPan")) {
        const send_idx = cmd.getInt("sendIdx") orelse return null;
        return gesture_state.ControlId.sendPan(track, send_idx);
    } else if (std.mem.eql(u8, control_type_str, "receive")) {
        const recv_idx = cmd.getInt("recvIdx") orelse return null;
        return gesture_state.ControlId.receiveVolume(track, recv_idx);
    } else if (std.mem.eql(u8, control_type_str, "receivePan")) {
        const recv_idx = cmd.getInt("recvIdx") orelse return null;
        return gesture_state.ControlId.receivePan(track, recv_idx);
    } else if (std.mem.eql(u8, control_type_str, "hwOutputVolume")) {
        const hw_idx = cmd.getInt("hwIdx") orelse return null;
        return gesture_state.ControlId.hwOutputVolume(track, hw_idx);
    } else if (std.mem.eql(u8, control_type_str, "hwOutputPan")) {
        const hw_idx = cmd.getInt("hwIdx") orelse return null;
        return gesture_state.ControlId.hwOutputPan(track, hw_idx);
    } else if (std.mem.eql(u8, control_type_str, "fxParam")) {
        const fx = gesture_state.GuidKey.from(cmd.getString("fxGuid") orelse return null) orelse return null;
        const param_idx = cmd.getInt("paramIdx") orelse return null;
        return gesture_state.ControlId.fxParam(track, fx, param_idx);
    }
    return null;
}

/// Handle gesture/start - called when a client begins dragging a fader
/// Params: { controlType: "volume"|"pan"|"send"|"sendPan"|"receive"|"receivePan"|"hwOutputVolume"|"hwOutputPan", trackIdx|trackGuid: number|string, sendIdx?/recvIdx?/hwIdx?: number }
pub fn handleStart(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const gestures = response.gestures orelse {
        logging.warn("gesture/start called but GestureState not available", .{});
        response.err("INTERNAL_ERROR", "Gesture tracking not initialized");
        return;
    };

    const control = parseControlId(api, cmd) orelse {
        response.err("INVALID_PARAMS", "Required: controlType, trackIdx/trackGuid, and sendIdx/recvIdx/hwIdx for send/receive/hw types");
        return;
    };

    const is_new = gestures.beginGesture(control, response.client_id);
    logging.debug("GESTURE START {s} track {s} (new={}, client={})", .{
        @tagName(control.control_type),
        control.track.slice(),
        is_new,
        response.client_id,
    });

    // Manual-undo controls get one undo point when their gesture ends.
    if (is_new) gestures.beginManualUndo(control.control_type);

    response.success(null);
}

/// Handle gesture/end - called when a client finishes dragging a fader
/// Params: { controlType: "volume"|"pan"|"send"|"sendPan"|"hwOutputVolume"|"hwOutputPan", trackIdx|trackGuid: number|string, sendIdx?/hwIdx?: number }
/// If this is the last client gesturing on the control, flushes the undo
pub fn handleEnd(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const gestures = response.gestures orelse {
        logging.warn("gesture/end called but GestureState not available", .{});
        response.err("INTERNAL_ERROR", "Gesture tracking not initialized");
        return;
    };

    const control = parseControlId(api, cmd) orelse {
        response.err("INVALID_PARAMS", "Required: controlType, trackIdx/trackGuid, and sendIdx/hwIdx for send/hw types");
        return;
    };

    const should_flush = gestures.endGesture(control, response.client_id);
    logging.debug("GESTURE END {s} track {s} (flush={}, client={})", .{
        @tagName(control.control_type),
        control.track.slice(),
        should_flush,
        response.client_id,
    });

    if (should_flush) {
        if (gesture_state.GestureState.needsManualUndo(control.control_type)) {
            if (gestures.endManualUndo(control.control_type)) |undo_msg| {
                logging.debug("Recording manual undo point: {s}", .{undo_msg});
                api.undoRecordChange(undo_msg);
            }
        } else {
            // For CSurf-based controls (track/send volume/pan), flush pending undo
            logging.debug("Calling CSurf_FlushUndo(true)", .{});
            api.csurfFlushUndo(true);
        }
    }

    response.success(null);
}

// =============================================================================
// Tests
// =============================================================================

const guid_cache = @import("../state/guid_cache.zig");
const hw_output = @import("hw_output.zig");
const send_cmds = @import("send.zig");
const receive_cmds = @import("receive.zig");

/// A project whose tracks can move: a track's pointer and GUID belong to the
/// track, not to its position. Every track has one send, one receive and one
/// hardware output, and remembers the last value written to each.
const MovableTracks = struct {
    /// order[i] is the id of the user track at unified index i + 1; id 0 is master.
    order: [8]u8 = .{ 1, 2, 0, 0, 0, 0, 0, 0 },
    count: c_int = 2,
    next_id: u8 = 3,
    csurf_flushes: usize = 0,
    undo_points: usize = 0,
    undo_blocks: usize = 0,
    /// route_values[kind][track id]: the last volume or pan written to the
    /// track's send (0), receive (1) or hardware output (2).
    route_values: [3][8]?f64 = .{.{null} ** 8} ** 3,

    fn ptr(id: u8) *anyopaque {
        return @ptrFromInt(0x1000 + @as(usize, id) * 16);
    }
    fn idOf(track: *anyopaque) u8 {
        return @intCast((@intFromPtr(track) - 0x1000) / 16);
    }

    /// The user inserts a track at the top of the project in REAPER.
    fn insertAtTop(self: *MovableTracks) void {
        var i: usize = @intCast(self.count);
        while (i > 0) : (i -= 1) self.order[i] = self.order[i - 1];
        self.order[0] = self.next_id;
        self.next_id += 1;
        self.count += 1;
    }

    pub fn masterTrack(_: *MovableTracks) ?*anyopaque {
        return ptr(0);
    }
    pub fn trackCount(self: *MovableTracks) c_int {
        return self.count;
    }
    pub fn getTrackByUnifiedIdx(self: *MovableTracks, idx: c_int) ?*anyopaque {
        if (idx == 0) return ptr(0);
        if (idx < 0 or idx > self.count) return null;
        return ptr(self.order[@intCast(idx - 1)]);
    }
    pub fn getTrackIdx(self: *MovableTracks, track: *anyopaque) c_int {
        const id = idOf(track);
        if (id == 0) return 0;
        for (self.order[0..@intCast(self.count)], 1..) |o, i| {
            if (o == id) return @intCast(i);
        }
        return -1;
    }
    pub fn validateTrackPtr(self: *MovableTracks, track: ?*anyopaque) bool {
        return self.getTrackIdx(track orelse return false) >= 0;
    }
    pub fn formatTrackGuid(_: *MovableTracks, track: *anyopaque, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{{00000000-0000-0000-0000-{d:0>12}}}", .{idOf(track)}) catch "";
    }
    pub fn csurfSetVolume(_: *MovableTracks, _: *anyopaque, vol: f64, _: bool) f64 {
        return vol;
    }
    pub fn csurfFlushUndo(self: *MovableTracks, _: bool) void {
        self.csurf_flushes += 1;
    }
    pub fn undoRecordChange(self: *MovableTracks, _: [*:0]const u8) void {
        self.undo_points += 1;
    }
    pub fn undoBeginBlock(_: *MovableTracks) void {}
    pub fn undoEndBlock(self: *MovableTracks, _: [*:0]const u8) void {
        self.undo_blocks += 1;
    }
    pub fn trackSendCount(_: *MovableTracks, _: *anyopaque) c_int {
        return 1;
    }
    pub fn trackReceiveCount(_: *MovableTracks, _: *anyopaque) c_int {
        return 1;
    }
    pub fn trackHwOutputCount(_: *MovableTracks, _: *anyopaque) c_int {
        return 1;
    }
    fn setRoute(self: *MovableTracks, kind: usize, track: *anyopaque, value: f64) bool {
        self.route_values[kind][idOf(track)] = value;
        return true;
    }
    pub fn trackSendSetVolume(self: *MovableTracks, track: *anyopaque, _: c_int, v: f64) bool {
        return self.setRoute(0, track, v);
    }
    pub fn trackSendSetPan(self: *MovableTracks, track: *anyopaque, _: c_int, v: f64) bool {
        return self.setRoute(0, track, v);
    }
    pub fn trackReceiveSetVolume(self: *MovableTracks, track: *anyopaque, _: c_int, v: f64) bool {
        return self.setRoute(1, track, v);
    }
    pub fn trackReceiveSetPan(self: *MovableTracks, track: *anyopaque, _: c_int, v: f64) bool {
        return self.setRoute(1, track, v);
    }
    pub fn trackHwOutputSetVolume(self: *MovableTracks, track: *anyopaque, _: c_int, v: f64) bool {
        return self.setRoute(2, track, v);
    }
    pub fn trackHwOutputSetPan(self: *MovableTracks, track: *anyopaque, _: c_int, v: f64) bool {
        return self.setRoute(2, track, v);
    }
};

/// Runs `handler` on `json` from client 1 with gesture tracking, as dispatch
/// would. GUIDs resolve through a cache built from `api`, as in REAPER.
fn runWithGestures(api: *MovableTracks, gestures: *gesture_state.GestureState, comptime handler: anytype, json: []const u8) void {
    var cache = guid_cache.GuidCache.init(std.testing.allocator);
    defer cache.deinit();
    cache.rebuild(api) catch unreachable;
    const saved = mod.g_ctx.guid_cache;
    mod.g_ctx.guid_cache = &cache;
    defer mod.g_ctx.guid_cache = saved;

    const cmd = protocol.CommandMessage.parse(json).?;
    std.debug.assert(cmd.getId() == null);
    var shared: @import("../server/ws_server.zig").SharedState = undefined;
    var response = mod.ResponseWriter{ .client_id = 1, .cmd_id = null, .shared_state = &shared, .gestures = gestures };
    handler(api, cmd, &response);
}

const GUITAR = "{00000000-0000-0000-0000-000000000002}";
const VOCALS_ID = 1;
const GUITAR_ID = 2;

/// Each routing control: its gesture controlType, the parameter naming the
/// route, the value parameter, which route it writes (as in
/// MovableTracks.route_values) and the handler of its value command.
const route_controls = .{
    .{ "send", "sendIdx", "volume", 0, send_cmds.handleSetVolume },
    .{ "sendPan", "sendIdx", "pan", 0, send_cmds.handleSetPan },
    .{ "receive", "recvIdx", "volume", 1, receive_cmds.handleSetVolume },
    .{ "receivePan", "recvIdx", "pan", 1, receive_cmds.handleSetPan },
    .{ "hwOutputVolume", "hwIdx", "volume", 2, hw_output.handleSetVolume },
    .{ "hwOutputPan", "hwIdx", "pan", 2, hw_output.handleSetPan },
};

/// A routing control's gesture/start or gesture/end, by Guitar's GUID.
fn routeGesture(buf: []u8, command: []const u8, control: []const u8, idx_key: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{{\"command\":\"{s}\",\"controlType\":\"{s}\",\"trackGuid\":\"{s}\",\"{s}\":0}}", .{ command, control, GUITAR, idx_key }) catch unreachable;
}

/// A routing value command addressed by `track` (a JSON member).
fn routeValue(buf: []u8, track: []const u8, idx_key: []const u8, value_key: []const u8, value: f64) []const u8 {
    return std.fmt.bufPrint(buf, "{{\"command\":\"set\",{s},\"{s}\":0,\"{s}\":{d}}}", .{ track, idx_key, value_key, value }) catch unreachable;
}

test "a volume drag ends at gesture/end when a track is inserted above it mid-drag" {
    var api = MovableTracks{};
    var gestures = gesture_state.GestureState.init(std.testing.allocator);
    defer gestures.deinit();

    runWithGestures(&api, &gestures, handleStart, "{\"command\":\"gesture/start\",\"controlType\":\"volume\",\"trackGuid\":\"" ++ GUITAR ++ "\"}");
    runWithGestures(&api, &gestures, tracks.handleSetVolume, "{\"command\":\"track/setVolume\",\"trackGuid\":\"" ++ GUITAR ++ "\",\"volume\":0.9}");
    api.insertAtTop(); // Guitar moves from index 2 to 3
    runWithGestures(&api, &gestures, tracks.handleSetVolume, "{\"command\":\"track/setVolume\",\"trackGuid\":\"" ++ GUITAR ++ "\",\"volume\":0.8}");
    runWithGestures(&api, &gestures, handleEnd, "{\"command\":\"gesture/end\",\"controlType\":\"volume\",\"trackGuid\":\"" ++ GUITAR ++ "\"}");

    try std.testing.expect(!gestures.hasActiveGestures());
    try std.testing.expectEqual(@as(usize, 1), api.csurf_flushes);
}

test "routing drags addressed by GUID stay on their track and end at gesture/end when a track is inserted above it" {
    inline for (route_controls) |c| {
        var api = MovableTracks{};
        var gestures = gesture_state.GestureState.init(std.testing.allocator);
        defer gestures.deinit();
        var buf: [256]u8 = undefined;
        const by_guid = "\"trackGuid\":\"" ++ GUITAR ++ "\"";

        // The routing faders send the gesture and every value by the GUID
        // captured at gesture start.
        runWithGestures(&api, &gestures, handleStart, routeGesture(&buf, "gesture/start", c[0], c[1]));
        runWithGestures(&api, &gestures, c[4], routeValue(&buf, by_guid, c[1], c[2], 0.25));
        api.insertAtTop(); // Guitar moves from index 2 to 3; Vocals from 1 to 2
        runWithGestures(&api, &gestures, c[4], routeValue(&buf, by_guid, c[1], c[2], 0.5));
        runWithGestures(&api, &gestures, handleEnd, routeGesture(&buf, "gesture/end", c[0], c[1]));

        errdefer std.debug.print("control {s}\n", .{c[0]});
        try std.testing.expectEqual(@as(?f64, 0.5), api.route_values[c[3]][GUITAR_ID]);
        try std.testing.expectEqual(@as(?f64, null), api.route_values[c[3]][VOCALS_ID]);
        try std.testing.expectEqual(@as(usize, 0), api.undo_blocks); // every change belongs to the drag
        try std.testing.expectEqual(@as(usize, 1), api.undo_points); // recorded at gesture/end
        try std.testing.expect(!gestures.hasActiveGestures());

        // A change on the track now at Guitar's old index is an undo step of its own.
        runWithGestures(&api, &gestures, c[4], routeValue(&buf, "\"trackIdx\":2", c[1], c[2], 0.75));
        try std.testing.expectEqual(@as(?f64, 0.75), api.route_values[c[3]][VOCALS_ID]);
        try std.testing.expectEqual(@as(usize, 1), api.undo_blocks);
    }
}

test "an index-addressed routing value sent after its track moved changes the track now at that index, outside the drag" {
    // A client that addresses values by the index it saw at mousedown.
    var api = MovableTracks{};
    var gestures = gesture_state.GestureState.init(std.testing.allocator);
    defer gestures.deinit();
    var buf: [256]u8 = undefined;

    runWithGestures(&api, &gestures, handleStart, routeGesture(&buf, "gesture/start", "hwOutputVolume", "hwIdx"));
    runWithGestures(&api, &gestures, hw_output.handleSetVolume, routeValue(&buf, "\"trackIdx\":2", "hwIdx", "volume", 0.25));
    api.insertAtTop(); // index 2 is now Vocals
    runWithGestures(&api, &gestures, hw_output.handleSetVolume, routeValue(&buf, "\"trackIdx\":2", "hwIdx", "volume", 0.5));
    runWithGestures(&api, &gestures, handleEnd, routeGesture(&buf, "gesture/end", "hwOutputVolume", "hwIdx"));

    try std.testing.expectEqual(@as(?f64, 0.25), api.route_values[2][GUITAR_ID]);
    try std.testing.expectEqual(@as(?f64, 0.5), api.route_values[2][VOCALS_ID]);
    try std.testing.expectEqual(@as(usize, 1), api.undo_blocks); // Vocals' change, outside the drag
    try std.testing.expectEqual(@as(usize, 1), api.undo_points); // the drag still ends at gesture/end
    try std.testing.expect(!gestures.hasActiveGestures());
}

test "trackIdx 0 and \"master\" name the same gesture" {
    var api = MovableTracks{};
    var gestures = gesture_state.GestureState.init(std.testing.allocator);
    defer gestures.deinit();

    runWithGestures(&api, &gestures, handleStart, "{\"command\":\"gesture/start\",\"controlType\":\"volume\",\"trackIdx\":0}");
    api.insertAtTop();
    runWithGestures(&api, &gestures, handleEnd, "{\"command\":\"gesture/end\",\"controlType\":\"volume\",\"trackGuid\":\"master\"}");

    try std.testing.expect(!gestures.hasActiveGestures());
    try std.testing.expectEqual(@as(usize, 1), api.csurf_flushes);
}
