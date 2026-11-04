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

/// A project whose tracks can move: a track's pointer and GUID belong to the
/// track, not to its position. Every track has one hardware output.
const MovableTracks = struct {
    /// order[i] is the id of the user track at unified index i + 1; id 0 is master.
    order: [8]u8 = .{ 1, 2, 0, 0, 0, 0, 0, 0 },
    count: c_int = 2,
    next_id: u8 = 3,
    csurf_flushes: usize = 0,
    undo_points: usize = 0,
    undo_blocks: usize = 0,

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
        return 0;
    }
    pub fn trackReceiveCount(_: *MovableTracks, _: *anyopaque) c_int {
        return 0;
    }
    pub fn trackHwOutputCount(_: *MovableTracks, _: *anyopaque) c_int {
        return 1;
    }
    pub fn trackHwOutputSetVolume(_: *MovableTracks, _: *anyopaque, _: c_int, _: f64) bool {
        return true;
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

test "a hardware-output drag on a track that moves mid-drag is one undo point, and frees the old index" {
    var api = MovableTracks{};
    var gestures = gesture_state.GestureState.init(std.testing.allocator);
    defer gestures.deinit();

    // HardwareTab sends gestures by GUID and values by the index it shows.
    runWithGestures(&api, &gestures, handleStart, "{\"command\":\"gesture/start\",\"controlType\":\"hwOutputVolume\",\"trackGuid\":\"" ++ GUITAR ++ "\",\"hwIdx\":0}");
    runWithGestures(&api, &gestures, hw_output.handleSetVolume, "{\"command\":\"hw/setVolume\",\"trackIdx\":2,\"hwIdx\":0,\"volume\":0.9}");
    api.insertAtTop(); // Guitar moves from index 2 to 3
    runWithGestures(&api, &gestures, hw_output.handleSetVolume, "{\"command\":\"hw/setVolume\",\"trackIdx\":3,\"hwIdx\":0,\"volume\":0.8}");
    try std.testing.expectEqual(@as(usize, 0), api.undo_blocks); // every change belongs to the drag
    runWithGestures(&api, &gestures, handleEnd, "{\"command\":\"gesture/end\",\"controlType\":\"hwOutputVolume\",\"trackGuid\":\"" ++ GUITAR ++ "\",\"hwIdx\":0}");

    try std.testing.expect(!gestures.hasActiveGestures());
    try std.testing.expectEqual(@as(usize, 1), api.undo_points);

    // A double-tap reset on the track now at Guitar's old index is its own undo step.
    runWithGestures(&api, &gestures, hw_output.handleSetVolume, "{\"command\":\"hw/setVolume\",\"trackIdx\":2,\"hwIdx\":0,\"volume\":1.0}");
    try std.testing.expectEqual(@as(usize, 1), api.undo_blocks);
}

test "a master drag is one gesture whether it is addressed by index or by \"master\"" {
    var api = MovableTracks{};
    var gestures = gesture_state.GestureState.init(std.testing.allocator);
    defer gestures.deinit();

    runWithGestures(&api, &gestures, handleStart, "{\"command\":\"gesture/start\",\"controlType\":\"volume\",\"trackIdx\":0}");
    api.insertAtTop();
    runWithGestures(&api, &gestures, handleEnd, "{\"command\":\"gesture/end\",\"controlType\":\"volume\",\"trackGuid\":\"master\"}");

    try std.testing.expect(!gestures.hasActiveGestures());
    try std.testing.expectEqual(@as(usize, 1), api.csurf_flushes);
}
