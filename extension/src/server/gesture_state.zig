const std = @import("std");
const logging = @import("../core/logging.zig");

/// A gesture with no activity for this long is ended as if gesture/end had
/// arrived. It only recovers from a lost gesture/end (a disconnect ends a
/// client's gestures at once), so it is long enough that a finger resting
/// mid-drag doesn't split the drag into two undo steps.
pub const GESTURE_TIMEOUT_NS: i128 = 10 * std.time.ns_per_s;

/// A GUID-sized identity string: a track's GUID ("master" for the master
/// track, as in the track skeleton) or an FX's GUID. Fixed-size so ControlId
/// stays a plain value that hash maps can copy.
pub const GuidKey = struct {
    buf: [MAX_LEN]u8 = undefined,
    len: u8 = 0,

    /// REAPER GUID strings are 38 characters; longer input is not a GUID.
    pub const MAX_LEN = 40;

    /// Null for an empty string or one longer than MAX_LEN.
    pub fn from(s: []const u8) ?GuidKey {
        if (s.len == 0 or s.len > MAX_LEN) return null;
        var key = GuidKey{ .len = @intCast(s.len) };
        @memcpy(key.buf[0..s.len], s);
        return key;
    }

    pub fn slice(self: *const GuidKey) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn eql(a: *const GuidKey, b: *const GuidKey) bool {
        return std.mem.eql(u8, a.slice(), b.slice());
    }
};

/// The key a track's gestures are tracked under: its GUID, which stays with
/// the track when tracks are inserted, deleted or reordered (its index
/// doesn't, and a drag's start, value changes and end must all find the same
/// gesture). The master track is "master". Null if REAPER gives no GUID.
pub fn trackKey(api: anytype, track: *anyopaque) ?GuidKey {
    if (api.masterTrack()) |master| {
        if (track == master) return GuidKey.from("master");
    }
    var buf: [64]u8 = undefined;
    return GuidKey.from(api.formatTrackGuid(track, &buf));
}

/// Identifies a continuous control that can have an active gesture.
/// Send, receive and hardware-output controls are addressed by their index
/// on the track (sub_idx), as their commands address them.
pub const ControlId = struct {
    control_type: ControlType,
    /// The track, by trackKey.
    track: GuidKey,
    /// Secondary index for controls that need it (e.g., send_idx for send_volume)
    sub_idx: c_int = 0,
    /// For FX param gestures: the FX GUID (stable across reorder)
    fx: GuidKey = .{},
    /// For FX param gestures: the parameter index
    param_idx: c_int = 0,

    pub const ControlType = enum {
        volume,
        pan,
        send_volume,
        send_pan,
        receive_volume,
        receive_pan,
        hw_output_volume,
        hw_output_pan,
        fx_param,
    };

    pub fn volume(track: GuidKey) ControlId {
        return .{ .control_type = .volume, .track = track };
    }

    pub fn pan(track: GuidKey) ControlId {
        return .{ .control_type = .pan, .track = track };
    }

    pub fn sendVolume(track: GuidKey, send_idx: c_int) ControlId {
        return .{ .control_type = .send_volume, .track = track, .sub_idx = send_idx };
    }

    pub fn sendPan(track: GuidKey, send_idx: c_int) ControlId {
        return .{ .control_type = .send_pan, .track = track, .sub_idx = send_idx };
    }

    pub fn receiveVolume(track: GuidKey, recv_idx: c_int) ControlId {
        return .{ .control_type = .receive_volume, .track = track, .sub_idx = recv_idx };
    }

    pub fn receivePan(track: GuidKey, recv_idx: c_int) ControlId {
        return .{ .control_type = .receive_pan, .track = track, .sub_idx = recv_idx };
    }

    pub fn hwOutputVolume(track: GuidKey, hw_idx: c_int) ControlId {
        return .{ .control_type = .hw_output_volume, .track = track, .sub_idx = hw_idx };
    }

    pub fn hwOutputPan(track: GuidKey, hw_idx: c_int) ControlId {
        return .{ .control_type = .hw_output_pan, .track = track, .sub_idx = hw_idx };
    }

    pub fn fxParam(track: GuidKey, fx: GuidKey, param_idx_val: c_int) ControlId {
        return .{ .control_type = .fx_param, .track = track, .fx = fx, .param_idx = param_idx_val };
    }

    /// SAFETY: Custom eql() required because the GuidKey buffers are only
    /// meaningful up to their length; AutoHashMap's default equality would
    /// compare every byte, uninitialized ones included. Only the fields that
    /// identify a control of this control_type are compared.
    pub fn eql(a: ControlId, b: ControlId) bool {
        if (a.control_type != b.control_type) return false;
        if (!a.track.eql(&b.track)) return false;
        if (a.control_type == .fx_param) {
            return a.param_idx == b.param_idx and a.fx.eql(&b.fx);
        }
        return a.sub_idx == b.sub_idx;
    }

    /// SAFETY: Custom hash() required to match eql() behavior.
    /// Only hash fields that are compared in eql() to ensure hash consistency.
    pub fn hash(self: ControlId) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&self.control_type));
        h.update(self.track.slice());
        if (self.control_type == .fx_param) {
            h.update(std.mem.asBytes(&self.param_idx));
            h.update(self.fx.slice());
        } else {
            h.update(std.mem.asBytes(&self.sub_idx));
        }
        return h.final();
    }
};

/// Custom hash map context for ControlId using our eql/hash methods
pub const ControlIdContext = struct {
    pub fn hash(_: ControlIdContext, key: ControlId) u64 {
        return key.hash();
    }

    pub fn eql(_: ControlIdContext, a: ControlId, b: ControlId) bool {
        return a.eql(b);
    }
};

/// Control types whose drags CSurf_FlushUndo does not turn into an undo
/// point: hardware outputs and FX parameters have no CSurf call, and REAPER
/// registers no undo for CSurf_OnSendVolume/PanChange.
pub const ManualUndoControlType = enum(u8) {
    hw_output_volume = 0,
    hw_output_pan = 1,
    fx_param = 2,
    send = 3,
    receive = 4,
};

/// Undo for manual-undo drags. No REAPER undo block is held open across
/// timer ticks (anything the user did in REAPER meanwhile would join it, and
/// a block never closed leaves undo dead for the session): the changes are
/// applied as they come, and when the last such gesture ends, however it
/// ends, the caller records one undo point for all of them.
pub const ManualUndoState = struct {
    gesture_count: usize = 0,
    touched_types: u8 = 0, // bitfield of ManualUndoControlType

    /// A new manual-undo gesture started.
    pub fn begin(self: *ManualUndoState, control_type: ManualUndoControlType) void {
        self.gesture_count += 1;
        self.touched_types |= @as(u8, 1) << @intCast(@intFromEnum(control_type));
    }

    /// A manual-undo gesture ended. Returns true when it was the last one:
    /// record the undo point now (see takeUndoMessage).
    pub fn end(self: *ManualUndoState) bool {
        if (self.gesture_count == 0) {
            logging.warn("ManualUndoState.end with no gesture open", .{});
            return false;
        }
        self.gesture_count -= 1;
        return self.gesture_count == 0;
    }

    /// The undo description for everything touched since the last point;
    /// resets for the next one.
    pub fn takeUndoMessage(self: *ManualUndoState) [*:0]const u8 {
        const t = self.touched_types;
        self.touched_types = 0;
        const hw = (t & 0b11) != 0;
        const fx = (t & (1 << @intFromEnum(ManualUndoControlType.fx_param))) != 0;
        const send = (t & (1 << @intFromEnum(ManualUndoControlType.send))) != 0;
        const receive = (t & (1 << @intFromEnum(ManualUndoControlType.receive))) != 0;
        const kinds = @as(u8, @intFromBool(hw)) + @intFromBool(fx) + @intFromBool(send) + @intFromBool(receive);
        if (kinds == 1) {
            if (hw) return "REAmo: Adjust hardware outputs";
            if (fx) return "REAmo: Adjust FX parameters";
            if (send) return "REAmo: Adjust sends";
            return "REAmo: Adjust receives";
        }
        return "REAmo: Adjust parameters";
    }

    pub fn isOpen(self: *const ManualUndoState) bool {
        return self.gesture_count > 0;
    }
};

/// Tracks an active gesture on a control with refcounting for multiple clients
const ActiveGesture = struct {
    clients: std.AutoHashMap(usize, void),
    last_change_ns: i128,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) ActiveGesture {
        return .{
            .clients = std.AutoHashMap(usize, void).init(allocator),
            .last_change_ns = std.time.nanoTimestamp(),
            .allocator = allocator,
        };
    }

    fn deinit(self: *ActiveGesture) void {
        self.clients.deinit();
    }

    fn clientCount(self: *const ActiveGesture) usize {
        return self.clients.count();
    }
};

/// Manages gesture state for undo coalescing
/// Thread safety: All public methods must be called from the main thread only.
/// The WS thread communicates via the command queue, not by calling these directly.
pub const GestureState = struct {
    gestures: std.HashMap(ControlId, ActiveGesture, ControlIdContext, std.hash_map.default_max_load_percentage),
    last_any_activity_ns: i128,
    allocator: std.mem.Allocator,
    /// Pending undo for controls CSurf can't coalesce (see ManualUndoState).
    manual_undo: ManualUndoState,

    pub fn init(allocator: std.mem.Allocator) GestureState {
        return .{
            .gestures = std.HashMap(ControlId, ActiveGesture, ControlIdContext, std.hash_map.default_max_load_percentage).init(allocator),
            .last_any_activity_ns = 0,
            .allocator = allocator,
            .manual_undo = .{},
        };
    }

    pub fn deinit(self: *GestureState) void {
        var it = self.gestures.valueIterator();
        while (it.next()) |gesture| {
            gesture.deinit();
        }
        self.gestures.deinit();
    }

    /// Called when a client starts gesturing on a control
    /// Returns true if this is a NEW gesture (first client), false if joining existing
    pub fn beginGesture(self: *GestureState, control: ControlId, client_id: usize) bool {
        const now = std.time.nanoTimestamp();
        self.last_any_activity_ns = now;

        const entry = self.gestures.getOrPut(control) catch |e| {
            logging.warn("beginGesture failed for client {d}: {} - gesture coalescing may not work", .{ client_id, e });
            return false;
        };

        if (!entry.found_existing) {
            entry.value_ptr.* = ActiveGesture.init(self.allocator);
        }
        entry.value_ptr.clients.put(client_id, {}) catch |e| {
            logging.warn("beginGesture client tracking failed for client {d}: {}", .{ client_id, e });
        };
        entry.value_ptr.last_change_ns = now;

        return !entry.found_existing;
    }

    /// Called on each value change during a gesture to update timestamps
    pub fn recordActivity(self: *GestureState, control: ControlId) void {
        const now = std.time.nanoTimestamp();
        self.last_any_activity_ns = now;

        if (self.gestures.getPtr(control)) |gesture| {
            gesture.last_change_ns = now;
        }
    }

    /// Called when a client ends gesturing on a control
    /// Returns true if this was the LAST client (gesture should be flushed)
    pub fn endGesture(self: *GestureState, control: ControlId, client_id: usize) bool {
        const entry = self.gestures.getPtr(control) orelse return false;
        _ = entry.clients.remove(client_id);

        if (entry.clients.count() == 0) {
            entry.deinit();
            _ = self.gestures.remove(control);
            return true; // Last client - trigger flush
        }
        return false;
    }

    /// Remove a client from ALL active gestures (called on disconnect)
    /// Returns list of controls that should be flushed (where this was the last client)
    pub fn removeClientFromAll(self: *GestureState, client_id: usize, out_buf: []ControlId) usize {
        var flush_count: usize = 0;
        var to_remove: std.ArrayList(ControlId) = .empty;
        defer to_remove.deinit(self.allocator);

        var it = self.gestures.iterator();
        while (it.next()) |entry| {
            _ = entry.value_ptr.clients.remove(client_id);
            if (entry.value_ptr.clients.count() == 0) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch |e| {
                    logging.warn("removeClientFromAll cleanup failed: {} - stale gesture may remain", .{e});
                };
            }
        }

        // Remove empty gestures and record which ones need flushing
        for (to_remove.items) |control| {
            if (self.gestures.getPtr(control)) |gest| {
                gest.deinit();
            }
            _ = self.gestures.remove(control);
            if (flush_count < out_buf.len) {
                out_buf[flush_count] = control;
                flush_count += 1;
            }
        }

        return flush_count;
    }

    /// Check for timed-out gestures (hybrid: per-control + global activity)
    /// Returns list of controls that have timed out and should be flushed
    pub fn checkTimeouts(self: *GestureState, out_buf: []ControlId) usize {
        const now = std.time.nanoTimestamp();
        var expired_count: usize = 0;
        var to_remove: std.ArrayList(ControlId) = .empty;
        defer to_remove.deinit(self.allocator);

        // Only check if global activity has also been idle
        const global_idle = (now - self.last_any_activity_ns) > GESTURE_TIMEOUT_NS;
        if (!global_idle) return 0;

        var it = self.gestures.iterator();
        while (it.next()) |entry| {
            const control_idle = (now - entry.value_ptr.last_change_ns) > GESTURE_TIMEOUT_NS;
            if (control_idle) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch |e| {
                    logging.warn("checkTimeouts cleanup failed: {} - stale gesture may remain", .{e});
                };
            }
        }

        // Remove timed out gestures
        for (to_remove.items) |control| {
            if (self.gestures.getPtr(control)) |gest| {
                gest.deinit();
            }
            _ = self.gestures.remove(control);
            if (expired_count < out_buf.len) {
                out_buf[expired_count] = control;
                expired_count += 1;
            }
        }

        return expired_count;
    }

    /// Whether some client is mid-drag on this control.
    pub fn isActive(self: *const GestureState, control: ControlId) bool {
        return self.gestures.contains(control);
    }

    /// Check if there are any active gestures
    pub fn hasActiveGestures(self: *const GestureState) bool {
        return self.gestures.count() > 0;
    }

    /// Check if a control type's drag is recorded as one manual undo point
    /// when it ends (see ManualUndoState).
    pub fn needsManualUndo(control_type: ControlId.ControlType) bool {
        return getManualUndoType(control_type) != null;
    }

    pub fn getManualUndoType(control_type: ControlId.ControlType) ?ManualUndoControlType {
        return switch (control_type) {
            .hw_output_volume => .hw_output_volume,
            .hw_output_pan => .hw_output_pan,
            .fx_param => .fx_param,
            .send_volume, .send_pan => .send,
            .receive_volume, .receive_pan => .receive,
            .volume, .pan => null,
        };
    }

    /// A new gesture on a manual-undo control started.
    pub fn beginManualUndo(self: *GestureState, control_type: ControlId.ControlType) void {
        const undo_type = getManualUndoType(control_type) orelse return;
        self.manual_undo.begin(undo_type);
    }

    /// The last client's gesture on a manual-undo control ended (gesture/end,
    /// timeout or disconnect). Returns the undo description to record now,
    /// or null while other manual-undo gestures are still open.
    pub fn endManualUndo(self: *GestureState, control_type: ControlId.ControlType) ?[*:0]const u8 {
        if (getManualUndoType(control_type) == null) return null;
        if (!self.manual_undo.end()) return null;
        return self.manual_undo.takeUndoMessage();
    }
};

// Tests
test "manual-undo gestures record one point when the last one ends" {
    var state = GestureState.init(std.testing.allocator);
    defer state.deinit();

    state.beginManualUndo(.fx_param);
    state.beginManualUndo(.send_volume);
    try std.testing.expect(state.endManualUndo(.fx_param) == null); // the send drag is still open
    const msg = state.endManualUndo(.send_volume).?;
    try std.testing.expectEqualStrings("REAmo: Adjust parameters", std.mem.sliceTo(msg, 0));

    // The next drag starts a fresh description and nothing is left open.
    try std.testing.expect(!state.manual_undo.isOpen());
    state.beginManualUndo(.fx_param);
    try std.testing.expectEqualStrings("REAmo: Adjust FX parameters", std.mem.sliceTo(state.endManualUndo(.fx_param).?, 0));
}

test "track volume and pan are not manual-undo controls" {
    try std.testing.expect(!GestureState.needsManualUndo(.volume));
    try std.testing.expect(!GestureState.needsManualUndo(.pan));
    try std.testing.expect(GestureState.needsManualUndo(.send_pan));
    try std.testing.expect(GestureState.needsManualUndo(.receive_volume));
}

test "gesture lifecycle" {
    var state = GestureState.init(std.testing.allocator);
    defer state.deinit();

    const vol1 = ControlId.volume(GuidKey.from("{A}").?);

    // First client starts gesture
    try std.testing.expect(state.beginGesture(vol1, 100) == true); // new gesture
    try std.testing.expect(state.hasActiveGestures() == true);

    // Second client joins
    try std.testing.expect(state.beginGesture(vol1, 200) == false); // joining existing

    // First client ends - not last
    try std.testing.expect(state.endGesture(vol1, 100) == false);
    try std.testing.expect(state.hasActiveGestures() == true);

    // Second client ends - last client
    try std.testing.expect(state.endGesture(vol1, 200) == true);
    try std.testing.expect(state.hasActiveGestures() == false);
}

test "remove client from all" {
    var state = GestureState.init(std.testing.allocator);
    defer state.deinit();

    const guid = GuidKey.from("{A}").?;
    const vol1 = ControlId.volume(guid);
    const pan1 = ControlId.pan(guid);

    // Client 100 gesturing on both volume and pan
    _ = state.beginGesture(vol1, 100);
    _ = state.beginGesture(pan1, 100);

    // Client 200 also on volume
    _ = state.beginGesture(vol1, 200);

    // Remove client 100 from all
    var buf: [8]ControlId = undefined;
    const flush_count = state.removeClientFromAll(100, &buf);

    // Only pan1 should need flushing (client 100 was the only one)
    try std.testing.expect(flush_count == 1);
    try std.testing.expect(buf[0].control_type == .pan);

    // vol1 still has client 200
    try std.testing.expect(state.hasActiveGestures() == true);
}

test "controls are equal only for the same track, control and sub-address" {
    const a = GuidKey.from("{00000000-0000-0000-0000-000000000001}").?;
    const b = GuidKey.from("{00000000-0000-0000-0000-000000000002}").?;
    const fx1 = GuidKey.from("{FX1}").?;
    const fx2 = GuidKey.from("{FX2}").?;

    try std.testing.expect(ControlId.volume(a).eql(ControlId.volume(GuidKey.from("{00000000-0000-0000-0000-000000000001}").?)));
    try std.testing.expect(!ControlId.volume(a).eql(ControlId.volume(b)));
    try std.testing.expect(!ControlId.volume(a).eql(ControlId.pan(a)));
    try std.testing.expect(!ControlId.sendVolume(a, 0).eql(ControlId.sendVolume(a, 1)));
    try std.testing.expect(ControlId.fxParam(a, fx1, 3).eql(ControlId.fxParam(a, fx1, 3)));
    try std.testing.expect(!ControlId.fxParam(a, fx1, 3).eql(ControlId.fxParam(a, fx2, 3)));
    try std.testing.expect(!ControlId.fxParam(a, fx1, 3).eql(ControlId.fxParam(a, fx1, 4)));
    try std.testing.expectEqual(ControlId.fxParam(a, fx1, 3).hash(), ControlId.fxParam(a, fx1, 3).hash());
}

test "a GUID key refuses what cannot be a GUID" {
    try std.testing.expect(GuidKey.from("") == null);
    try std.testing.expect(GuidKey.from("x" ** (GuidKey.MAX_LEN + 1)) == null);
    try std.testing.expectEqualStrings("master", GuidKey.from("master").?.slice());
}
