const std = @import("std");

/// Timeout for gesture inactivity (500ms)
pub const GESTURE_TIMEOUT_NS: i128 = 500 * std.time.ns_per_ms;

/// Identifies a continuous control that can have an active gesture
pub const ControlId = struct {
    control_type: ControlType,
    track_idx: c_int,

    pub const ControlType = enum {
        volume,
        pan,
    };

    pub fn volume(track_idx: c_int) ControlId {
        return .{ .control_type = .volume, .track_idx = track_idx };
    }

    pub fn pan(track_idx: c_int) ControlId {
        return .{ .control_type = .pan, .track_idx = track_idx };
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
    gestures: std.AutoHashMap(ControlId, ActiveGesture),
    last_any_activity_ns: i128,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) GestureState {
        return .{
            .gestures = std.AutoHashMap(ControlId, ActiveGesture).init(allocator),
            .last_any_activity_ns = 0,
            .allocator = allocator,
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

        const entry = self.gestures.getOrPut(control) catch return false;

        if (!entry.found_existing) {
            entry.value_ptr.* = ActiveGesture.init(self.allocator);
        }
        entry.value_ptr.clients.put(client_id, {}) catch {};
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
                to_remove.append(self.allocator, entry.key_ptr.*) catch {};
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
                to_remove.append(self.allocator, entry.key_ptr.*) catch {};
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
