const std = @import("std");
const logging = @import("logging.zig");

/// Timeout for gesture inactivity (500ms)
pub const GESTURE_TIMEOUT_NS: i128 = 500 * std.time.ns_per_ms;

/// Identifies a continuous control that can have an active gesture
pub const ControlId = struct {
    control_type: ControlType,
    track_idx: c_int,
    /// Secondary index for controls that need it (e.g., send_idx for send_volume)
    sub_idx: c_int = 0,

    /// For FX param gestures: the FX GUID (stable across reorder)
    fx_guid: [40]u8 = undefined,
    fx_guid_len: u8 = 0,
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

    pub fn volume(track_idx: c_int) ControlId {
        return .{ .control_type = .volume, .track_idx = track_idx };
    }

    pub fn pan(track_idx: c_int) ControlId {
        return .{ .control_type = .pan, .track_idx = track_idx };
    }

    pub fn sendVolume(track_idx: c_int, send_idx: c_int) ControlId {
        return .{ .control_type = .send_volume, .track_idx = track_idx, .sub_idx = send_idx };
    }

    pub fn sendPan(track_idx: c_int, send_idx: c_int) ControlId {
        return .{ .control_type = .send_pan, .track_idx = track_idx, .sub_idx = send_idx };
    }

    pub fn receiveVolume(track_idx: c_int, recv_idx: c_int) ControlId {
        return .{ .control_type = .receive_volume, .track_idx = track_idx, .sub_idx = recv_idx };
    }

    pub fn receivePan(track_idx: c_int, recv_idx: c_int) ControlId {
        return .{ .control_type = .receive_pan, .track_idx = track_idx, .sub_idx = recv_idx };
    }

    pub fn hwOutputVolume(track_idx: c_int, hw_idx: c_int) ControlId {
        return .{ .control_type = .hw_output_volume, .track_idx = track_idx, .sub_idx = hw_idx };
    }

    pub fn hwOutputPan(track_idx: c_int, hw_idx: c_int) ControlId {
        return .{ .control_type = .hw_output_pan, .track_idx = track_idx, .sub_idx = hw_idx };
    }

    pub fn fxParam(track_idx: c_int, fx_guid: []const u8, param_idx_val: c_int) ControlId {
        var id = ControlId{
            .control_type = .fx_param,
            .track_idx = track_idx,
            .param_idx = param_idx_val,
        };
        const len: u8 = @intCast(@min(fx_guid.len, 40));
        @memcpy(id.fx_guid[0..len], fx_guid[0..len]);
        id.fx_guid_len = len;
        return id;
    }

    /// SAFETY: Custom eql() required because ControlId contains a fixed-size array (fx_guid).
    /// AutoHashMap's default equality compares ALL bytes, including uninitialized portions.
    /// This ensures only meaningful fields are compared based on control_type.
    pub fn eql(a: ControlId, b: ControlId) bool {
        if (a.control_type != b.control_type) return false;
        if (a.track_idx != b.track_idx) return false;

        // For fx_param, compare fx_guid and param_idx
        if (a.control_type == .fx_param) {
            if (a.fx_guid_len != b.fx_guid_len) return false;
            if (a.param_idx != b.param_idx) return false;
            if (a.fx_guid_len > 0) {
                const len = a.fx_guid_len;
                if (!std.mem.eql(u8, a.fx_guid[0..len], b.fx_guid[0..len])) return false;
            }
            return true;
        }

        // For other types, compare sub_idx
        return a.sub_idx == b.sub_idx;
    }

    /// SAFETY: Custom hash() required to match eql() behavior.
    /// Only hash fields that are compared in eql() to ensure hash consistency.
    pub fn hash(self: ControlId) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&self.control_type));
        h.update(std.mem.asBytes(&self.track_idx));

        if (self.control_type == .fx_param) {
            h.update(std.mem.asBytes(&self.param_idx));
            if (self.fx_guid_len > 0) {
                h.update(self.fx_guid[0..self.fx_guid_len]);
            }
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

/// Control types that require manual undo blocks (no CSurf support).
pub const ManualUndoControlType = enum(u8) {
    hw_output_volume = 0,
    hw_output_pan = 1,
    fx_param = 2,
};

/// Manages manual undo blocks for control types without CSurf support.
/// REAPER doesn't support nested undo blocks, so this uses a unified counter
/// with a bitfield to track which control types are active.
pub const ManualUndoState = struct {
    gesture_count: usize = 0,
    active_types: u8 = 0, // bitfield

    /// Called when a NEW gesture starts for a manual-undo control type.
    /// Returns true if caller should open an undo block (this is the first gesture).
    pub fn beginBlock(self: *ManualUndoState, control_type: ManualUndoControlType) bool {
        const was_zero = self.gesture_count == 0;
        self.gesture_count += 1;
        const shift: u3 = @intCast(@intFromEnum(control_type));
        self.active_types |= (@as(u8, 1) << shift);
        logging.debug("Manual undo block: begin type {} (count {} -> {})", .{
            control_type,
            self.gesture_count - 1,
            self.gesture_count,
        });
        return was_zero;
    }

    /// Called when a gesture ends for a manual-undo control type.
    /// Returns true if caller should close the undo block (this was the last gesture).
    pub fn endBlock(self: *ManualUndoState, control_type: ManualUndoControlType) bool {
        if (self.gesture_count == 0) {
            logging.warn("ManualUndoState.endBlock called but count already 0 for type {}", .{control_type});
            return false;
        }
        self.gesture_count -= 1;
        // Don't clear the bit - remember all types touched during this block
        logging.debug("Manual undo block: end type {} (count {} -> {})", .{
            control_type,
            self.gesture_count + 1,
            self.gesture_count,
        });

        if (self.gesture_count == 0) {
            // Don't clear active_types here - caller needs to read it via buildUndoMessage first
            return true;
        }
        return false;
    }

    /// Returns null-terminated string literal for REAPER's Undo_EndBlock2.
    /// Message reflects all control types touched during the block.
    /// Clears active_types after building the message (consumes the state).
    pub fn buildUndoMessage(self: *ManualUndoState) [*:0]const u8 {
        const hw_vol = (self.active_types & (1 << 0)) != 0;
        const hw_pan = (self.active_types & (1 << 1)) != 0;
        const fx_param = (self.active_types & (1 << 2)) != 0;

        // Reset for next block after reading bits
        self.active_types = 0;

        const hw = hw_vol or hw_pan;

        // Single category - specific message
        if (hw and !fx_param) return "REAmo: Adjust hardware outputs";
        if (fx_param and !hw) return "REAmo: Adjust FX parameters";

        // Mixed - combined message
        if (hw and fx_param) return "REAmo: Adjust parameters";

        return "REAmo: Adjust parameters";
    }

    /// Check if there's an active manual undo block
    pub fn hasActiveBlock(self: *const ManualUndoState) bool {
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
    /// Unified undo block state for controls without CSurf support (hw outputs, FX params).
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

    /// Check if there are any active gestures
    pub fn hasActiveGestures(self: *const GestureState) bool {
        return self.gestures.count() > 0;
    }

    /// Check if a control type is a hardware output type
    pub fn isHwOutputControl(control_type: ControlId.ControlType) bool {
        return control_type == .hw_output_volume or control_type == .hw_output_pan;
    }

    /// Check if a control type requires manual undo blocks (no CSurf support).
    pub fn needsManualUndo(control_type: ControlId.ControlType) bool {
        return switch (control_type) {
            .hw_output_volume, .hw_output_pan, .fx_param => true,
            else => false,
        };
    }

    /// Get the ManualUndoControlType for a ControlType (only valid for manual undo types).
    pub fn getManualUndoType(control_type: ControlId.ControlType) ?ManualUndoControlType {
        return switch (control_type) {
            .hw_output_volume => .hw_output_volume,
            .hw_output_pan => .hw_output_pan,
            .fx_param => .fx_param,
            else => null,
        };
    }

    /// Called when a NEW gesture starts for a manual-undo control (is_new=true from beginGesture).
    /// Returns true if caller should open an undo block.
    /// REAPER doesn't support nested undo blocks, so all manual-undo gestures share one block.
    pub fn beginManualUndoBlock(self: *GestureState, control_type: ControlId.ControlType) bool {
        const undo_type = getManualUndoType(control_type) orelse return false;
        return self.manual_undo.beginBlock(undo_type);
    }

    /// Called when a gesture ends for a manual-undo control (should_flush=true from endGesture).
    /// Returns true if caller should close the undo block.
    pub fn endManualUndoBlock(self: *GestureState, control_type: ControlId.ControlType) bool {
        const undo_type = getManualUndoType(control_type) orelse return false;
        return self.manual_undo.endBlock(undo_type);
    }

    /// Get the undo message for the current manual undo block.
    /// Consumes the active_types state (clears it after building message).
    pub fn getManualUndoMessage(self: *GestureState) [*:0]const u8 {
        return self.manual_undo.buildUndoMessage();
    }

    /// Check if there's an active manual undo block.
    pub fn hasManualUndoBlock(self: *const GestureState) bool {
        return self.manual_undo.hasActiveBlock();
    }

    // Backwards compatibility aliases for existing hw-specific code
    pub fn beginHwUndoBlock(self: *GestureState) bool {
        // Use hw_output_volume as default - both hw types trigger the same undo behavior
        return self.manual_undo.beginBlock(.hw_output_volume);
    }

    pub fn endHwUndoBlock(self: *GestureState) bool {
        return self.manual_undo.endBlock(.hw_output_volume);
    }

    pub fn hasHwUndoBlock(self: *const GestureState) bool {
        return self.manual_undo.hasActiveBlock();
    }
};

// Tests
test "gesture lifecycle" {
    var state = GestureState.init(std.testing.allocator);
    defer state.deinit();

    const vol1 = ControlId.volume(1);

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

    const vol1 = ControlId.volume(1);
    const pan1 = ControlId.pan(1);

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
