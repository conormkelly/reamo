/// Track FX Parameter Subscriptions - Per-client subscription for FX parameter values.
///
/// Each client can subscribe to a single FX's parameters at a time (identified by track + FX GUID).
/// Subscriptions can be in range mode (param indices from start to end) or indices mode (specific indices).
/// When subscribed, the backend pushes parameter values at 30Hz (HIGH tier).
///
/// Usage:
///   var subs = TrackFxParamSubscriptions.init(allocator);
///   defer subs.deinit();
///   try subs.subscribeRange(client_id, "{track-guid}", "{fx-guid}", 0, 20);
///   subs.unsubscribe(client_id);
const std = @import("std");
const logging = @import("logging.zig");
const constants = @import("constants.zig");

const Allocator = std.mem.Allocator;

pub const MAX_CLIENTS = constants.MAX_SUBSCRIPTION_CLIENTS;
pub const GUID_LEN = 40;
pub const MAX_SUBSCRIBED_PARAMS = 100;

/// Subscription mode: range or specific indices.
pub const Mode = enum {
    range,
    indices,
};

/// Per-client subscription state.
pub const ClientSubscription = struct {
    active: bool = false,

    /// Track GUID (stable across reordering)
    track_guid: [GUID_LEN]u8 = undefined,
    track_guid_len: u8 = 0,

    /// FX GUID (stable across reordering)
    fx_guid: [GUID_LEN]u8 = undefined,
    fx_guid_len: u8 = 0,

    /// Subscription mode
    mode: Mode = .range,

    /// Range mode: param indices from start to end (inclusive)
    range_start: c_int = 0,
    range_end: c_int = 0,

    /// Indices mode: specific param indices
    indices: [MAX_SUBSCRIBED_PARAMS]c_int = undefined,
    indices_count: usize = 0,

    /// Auto-unsubscribe after consecutive failures (FX deleted)
    consecutive_failures: u8 = 0,

    /// Get stored track GUID.
    pub fn getTrackGuid(self: *const ClientSubscription) ?[]const u8 {
        if (!self.active or self.track_guid_len == 0) return null;
        return self.track_guid[0..self.track_guid_len];
    }

    /// Get stored FX GUID.
    pub fn getFxGuid(self: *const ClientSubscription) ?[]const u8 {
        if (!self.active or self.fx_guid_len == 0) return null;
        return self.fx_guid[0..self.fx_guid_len];
    }

    /// Clear subscription state.
    pub fn clear(self: *ClientSubscription) void {
        self.active = false;
        self.track_guid_len = 0;
        self.fx_guid_len = 0;
        self.mode = .range;
        self.range_start = 0;
        self.range_end = 0;
        self.indices_count = 0;
        self.consecutive_failures = 0;
    }

    /// Check if a param index is included in this subscription.
    pub fn includesParam(self: *const ClientSubscription, param_idx: c_int) bool {
        if (!self.active) return false;

        switch (self.mode) {
            .range => {
                return param_idx >= self.range_start and param_idx <= self.range_end;
            },
            .indices => {
                for (self.indices[0..self.indices_count]) |idx| {
                    if (idx == param_idx) return true;
                }
                return false;
            },
        }
    }
};

/// Manages FX parameter subscriptions across multiple clients.
pub const TrackFxParamSubscriptions = struct {
    allocator: Allocator,

    /// Per-client subscription data (slot-based storage)
    clients: [MAX_CLIENTS]ClientSubscription,

    /// Map from client_id to slot index
    client_id_to_slot: std.AutoHashMap(usize, usize),

    /// Next available slot
    next_slot: usize,

    /// Free list for recycling slots
    free_slots: [MAX_CLIENTS]usize = undefined,
    free_count: usize = 0,

    /// Force broadcast flag - set when subscriptions change
    force_broadcast_clients: [MAX_CLIENTS]bool = [_]bool{false} ** MAX_CLIENTS,

    /// Previous state hash per client (for change detection)
    /// Uses Wyhash of JSON payload to detect changes without storing full state
    prev_hash: [MAX_CLIENTS]u64,

    pub fn init(allocator: Allocator) TrackFxParamSubscriptions {
        var subs = TrackFxParamSubscriptions{
            .allocator = allocator,
            .clients = undefined,
            .client_id_to_slot = std.AutoHashMap(usize, usize).init(allocator),
            .next_slot = 0,
            .prev_hash = [_]u64{0} ** MAX_CLIENTS,
        };

        // Initialize all client slots
        for (&subs.clients) |*client| {
            client.* = ClientSubscription{};
        }

        return subs;
    }

    pub fn deinit(self: *TrackFxParamSubscriptions) void {
        self.client_id_to_slot.deinit();
    }

    /// Get or create a slot for a client.
    fn getOrCreateSlot(self: *TrackFxParamSubscriptions, client_id: usize) ?usize {
        if (self.client_id_to_slot.get(client_id)) |slot| {
            return slot;
        }

        // Try to reuse a freed slot first
        if (self.free_count > 0) {
            self.free_count -= 1;
            const slot = self.free_slots[self.free_count];
            self.client_id_to_slot.put(client_id, slot) catch |e| {
                logging.warn("trackfxparam_subscriptions: slot reuse failed for client {d}: {}", .{ client_id, e });
                return null;
            };
            return slot;
        }

        // Allocate a new slot if available
        if (self.next_slot >= MAX_CLIENTS) {
            return null;
        }

        const slot = self.next_slot;
        self.next_slot += 1;
        self.client_id_to_slot.put(client_id, slot) catch |e| {
            logging.warn("trackfxparam_subscriptions: slot allocation failed for client {d}: {}", .{ client_id, e });
            return null;
        };
        return slot;
    }

    /// Subscribe to an FX's parameters in range mode.
    pub fn subscribeRange(
        self: *TrackFxParamSubscriptions,
        client_id: usize,
        track_guid: []const u8,
        fx_guid: []const u8,
        range_start: c_int,
        range_end: c_int,
    ) !void {
        if (range_start > range_end) {
            return error.InvalidRange;
        }

        const slot = self.getOrCreateSlot(client_id) orelse return error.TooManyClients;
        const client = &self.clients[slot];

        // Clear previous state (auto-unsubscribe)
        client.clear();

        client.active = true;

        // Store track GUID
        const track_len: u8 = @intCast(@min(track_guid.len, GUID_LEN));
        @memcpy(client.track_guid[0..track_len], track_guid[0..track_len]);
        client.track_guid_len = track_len;

        // Store FX GUID
        const fx_len: u8 = @intCast(@min(fx_guid.len, GUID_LEN));
        @memcpy(client.fx_guid[0..fx_len], fx_guid[0..fx_len]);
        client.fx_guid_len = fx_len;

        client.mode = .range;
        client.range_start = range_start;
        client.range_end = range_end;

        // Force broadcast on new subscription
        self.force_broadcast_clients[slot] = true;

        // Clear previous hash to force full comparison
        self.prev_hash[slot] = 0;

        logging.debug("trackfxparam_subscriptions: client {d} subscribed to FX {s} params [{d}..{d}]", .{ client_id, fx_guid, range_start, range_end });
    }

    /// Subscribe to an FX's parameters in indices mode.
    pub fn subscribeIndices(
        self: *TrackFxParamSubscriptions,
        client_id: usize,
        track_guid: []const u8,
        fx_guid: []const u8,
        indices: []const c_int,
    ) !void {
        if (indices.len > MAX_SUBSCRIBED_PARAMS) {
            return error.TooManyParams;
        }

        const slot = self.getOrCreateSlot(client_id) orelse return error.TooManyClients;
        const client = &self.clients[slot];

        // Clear previous state (auto-unsubscribe)
        client.clear();

        client.active = true;

        // Store track GUID
        const track_len: u8 = @intCast(@min(track_guid.len, GUID_LEN));
        @memcpy(client.track_guid[0..track_len], track_guid[0..track_len]);
        client.track_guid_len = track_len;

        // Store FX GUID
        const fx_len: u8 = @intCast(@min(fx_guid.len, GUID_LEN));
        @memcpy(client.fx_guid[0..fx_len], fx_guid[0..fx_len]);
        client.fx_guid_len = fx_len;

        client.mode = .indices;
        @memcpy(client.indices[0..indices.len], indices);
        client.indices_count = indices.len;

        // Force broadcast on new subscription
        self.force_broadcast_clients[slot] = true;

        // Clear previous hash to force full comparison
        self.prev_hash[slot] = 0;

        logging.debug("trackfxparam_subscriptions: client {d} subscribed to FX {s} with {d} specific params", .{ client_id, fx_guid, indices.len });
    }

    /// Unsubscribe a client.
    pub fn unsubscribe(self: *TrackFxParamSubscriptions, client_id: usize) void {
        const slot = self.client_id_to_slot.get(client_id) orelse return;
        const client = &self.clients[slot];
        client.clear();

        // Clear previous hash
        self.prev_hash[slot] = 0;

        logging.debug("trackfxparam_subscriptions: client {d} unsubscribed", .{client_id});
    }

    /// Remove a client entirely (called on disconnect).
    pub fn removeClient(self: *TrackFxParamSubscriptions, client_id: usize) void {
        const slot = self.client_id_to_slot.get(client_id) orelse return;
        const client = &self.clients[slot];
        client.clear();

        // Clear previous hash
        self.prev_hash[slot] = 0;

        _ = self.client_id_to_slot.remove(client_id);

        // Add slot to free list for reuse
        self.free_slots[self.free_count] = slot;
        self.free_count += 1;

        logging.debug("trackfxparam_subscriptions: client {d} removed", .{client_id});
    }

    /// Check if there are any active subscriptions.
    pub fn hasSubscriptions(self: *const TrackFxParamSubscriptions) bool {
        var iter = self.client_id_to_slot.valueIterator();
        while (iter.next()) |slot| {
            if (self.clients[slot.*].active) return true;
        }
        return false;
    }

    /// Get client subscription by client_id.
    pub fn getClient(self: *TrackFxParamSubscriptions, client_id: usize) ?*ClientSubscription {
        const slot = self.client_id_to_slot.get(client_id) orelse return null;
        const client = &self.clients[slot];
        if (!client.active) return null;
        return client;
    }

    /// Get slot for a client.
    pub fn getSlot(self: *const TrackFxParamSubscriptions, client_id: usize) ?usize {
        return self.client_id_to_slot.get(client_id);
    }

    /// Increment consecutive failure count for a client.
    /// Returns true if auto-unsubscribe threshold reached (3 failures).
    pub fn recordFailure(self: *TrackFxParamSubscriptions, client_id: usize) bool {
        const slot = self.client_id_to_slot.get(client_id) orelse return false;
        const client = &self.clients[slot];
        if (!client.active) return false;

        client.consecutive_failures += 1;
        return client.consecutive_failures >= 3;
    }

    /// Reset failure count (called on successful resolution).
    pub fn resetFailures(self: *TrackFxParamSubscriptions, client_id: usize) void {
        const slot = self.client_id_to_slot.get(client_id) orelse return;
        const client = &self.clients[slot];
        client.consecutive_failures = 0;
    }

    /// Iterator for processing subscriptions.
    pub const SubscriptionIterator = struct {
        subs: *TrackFxParamSubscriptions,
        key_iter: std.AutoHashMap(usize, usize).KeyIterator,

        pub const Entry = struct {
            client_id: usize,
            slot: usize,
            track_guid: []const u8,
            fx_guid: []const u8,
            client: *ClientSubscription,
        };

        pub fn next(self_iter: *SubscriptionIterator) ?Entry {
            while (self_iter.key_iter.next()) |client_id| {
                const slot = self_iter.subs.client_id_to_slot.get(client_id.*) orelse continue;
                const client = &self_iter.subs.clients[slot];
                if (client.active) {
                    const track_guid = client.getTrackGuid() orelse continue;
                    const fx_guid = client.getFxGuid() orelse continue;
                    return Entry{
                        .client_id = client_id.*,
                        .slot = slot,
                        .track_guid = track_guid,
                        .fx_guid = fx_guid,
                        .client = client,
                    };
                }
            }
            return null;
        }
    };

    /// Get an iterator over active subscriptions.
    pub fn activeSubscriptions(self: *TrackFxParamSubscriptions) SubscriptionIterator {
        return .{
            .subs = self,
            .key_iter = self.client_id_to_slot.keyIterator(),
        };
    }

    /// Check if a slot needs force broadcast (and consume the flag).
    pub fn consumeForceBroadcast(self: *TrackFxParamSubscriptions, slot: usize) bool {
        if (slot >= MAX_CLIENTS) return false;
        if (self.force_broadcast_clients[slot]) {
            self.force_broadcast_clients[slot] = false;
            return true;
        }
        return false;
    }

    /// Check if data changed by comparing hash. Returns true if changed (or force broadcast).
    /// Updates stored hash if changed.
    pub fn checkChanged(self: *TrackFxParamSubscriptions, slot: usize, data_hash: u64) bool {
        if (slot >= MAX_CLIENTS) return false;

        // Force broadcast always triggers change
        if (self.force_broadcast_clients[slot]) {
            self.force_broadcast_clients[slot] = false;
            self.prev_hash[slot] = data_hash;
            return true;
        }

        // Compare with previous
        if (self.prev_hash[slot] != data_hash) {
            self.prev_hash[slot] = data_hash;
            return true;
        }

        return false;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "TrackFxParamSubscriptions init and deinit" {
    const allocator = std.testing.allocator;
    var subs = TrackFxParamSubscriptions.init(allocator);
    defer subs.deinit();

    try std.testing.expect(!subs.hasSubscriptions());
}

test "subscribeRange and unsubscribe" {
    const allocator = std.testing.allocator;
    var subs = TrackFxParamSubscriptions.init(allocator);
    defer subs.deinit();

    try subs.subscribeRange(1, "{track-guid}", "{fx-guid}", 0, 10);
    try std.testing.expect(subs.hasSubscriptions());

    const client = subs.getClient(1).?;
    try std.testing.expect(client.active);
    try std.testing.expectEqual(Mode.range, client.mode);
    try std.testing.expectEqual(@as(c_int, 0), client.range_start);
    try std.testing.expectEqual(@as(c_int, 10), client.range_end);

    subs.unsubscribe(1);

    // Client slot still exists but inactive
    const slot = subs.client_id_to_slot.get(1).?;
    try std.testing.expect(!subs.clients[slot].active);
}

test "subscribeIndices" {
    const allocator = std.testing.allocator;
    var subs = TrackFxParamSubscriptions.init(allocator);
    defer subs.deinit();

    const indices = [_]c_int{ 0, 5, 10, 15 };
    try subs.subscribeIndices(1, "{track-guid}", "{fx-guid}", &indices);

    const client = subs.getClient(1).?;
    try std.testing.expect(client.active);
    try std.testing.expectEqual(Mode.indices, client.mode);
    try std.testing.expectEqual(@as(usize, 4), client.indices_count);

    // Check includesParam
    try std.testing.expect(client.includesParam(0));
    try std.testing.expect(client.includesParam(5));
    try std.testing.expect(client.includesParam(10));
    try std.testing.expect(client.includesParam(15));
    try std.testing.expect(!client.includesParam(1));
    try std.testing.expect(!client.includesParam(20));
}

test "subscribeRange replaces previous subscription" {
    const allocator = std.testing.allocator;
    var subs = TrackFxParamSubscriptions.init(allocator);
    defer subs.deinit();

    // First subscription
    try subs.subscribeRange(1, "{track1}", "{fx1}", 0, 5);
    var client = subs.getClient(1).?;
    try std.testing.expectEqualStrings("{track1}", client.getTrackGuid().?);
    try std.testing.expectEqualStrings("{fx1}", client.getFxGuid().?);

    // Second subscription replaces first (same client)
    try subs.subscribeRange(1, "{track2}", "{fx2}", 10, 20);
    client = subs.getClient(1).?;
    try std.testing.expectEqualStrings("{track2}", client.getTrackGuid().?);
    try std.testing.expectEqualStrings("{fx2}", client.getFxGuid().?);
    try std.testing.expectEqual(@as(c_int, 10), client.range_start);
    try std.testing.expectEqual(@as(c_int, 20), client.range_end);
}

test "force_broadcast on subscribe" {
    const allocator = std.testing.allocator;
    var subs = TrackFxParamSubscriptions.init(allocator);
    defer subs.deinit();

    try subs.subscribeRange(1, "{track-guid}", "{fx-guid}", 0, 10);
    const slot = subs.client_id_to_slot.get(1).?;

    try std.testing.expect(subs.consumeForceBroadcast(slot));
    try std.testing.expect(!subs.consumeForceBroadcast(slot)); // Consumed
}

test "checkChanged detects changes" {
    const allocator = std.testing.allocator;
    var subs = TrackFxParamSubscriptions.init(allocator);
    defer subs.deinit();

    try subs.subscribeRange(1, "{track-guid}", "{fx-guid}", 0, 10);
    const slot = subs.client_id_to_slot.get(1).?;

    // First check - force broadcast triggers change
    try std.testing.expect(subs.checkChanged(slot, 12345));

    // Same hash - no change
    try std.testing.expect(!subs.checkChanged(slot, 12345));

    // Different hash - change
    try std.testing.expect(subs.checkChanged(slot, 67890));
}

test "consecutive failures and auto-unsubscribe threshold" {
    const allocator = std.testing.allocator;
    var subs = TrackFxParamSubscriptions.init(allocator);
    defer subs.deinit();

    try subs.subscribeRange(1, "{track-guid}", "{fx-guid}", 0, 10);

    // First two failures don't trigger threshold
    try std.testing.expect(!subs.recordFailure(1));
    try std.testing.expect(!subs.recordFailure(1));

    // Third failure triggers threshold
    try std.testing.expect(subs.recordFailure(1));

    // Reset and verify
    subs.resetFailures(1);
    const client = subs.getClient(1).?;
    try std.testing.expectEqual(@as(u8, 0), client.consecutive_failures);
}

test "activeSubscriptions iterator" {
    const allocator = std.testing.allocator;
    var subs = TrackFxParamSubscriptions.init(allocator);
    defer subs.deinit();

    try subs.subscribeRange(1, "{track1}", "{fx1}", 0, 5);
    try subs.subscribeRange(2, "{track2}", "{fx2}", 10, 20);
    subs.unsubscribe(1);

    var iter = subs.activeSubscriptions();
    var count: usize = 0;
    while (iter.next()) |entry| {
        try std.testing.expectEqual(@as(usize, 2), entry.client_id);
        try std.testing.expectEqualStrings("{track2}", entry.track_guid);
        try std.testing.expectEqualStrings("{fx2}", entry.fx_guid);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "removeClient recycles slot" {
    const allocator = std.testing.allocator;
    var subs = TrackFxParamSubscriptions.init(allocator);
    defer subs.deinit();

    try subs.subscribeRange(1, "{track1}", "{fx1}", 0, 5);
    const first_slot = subs.client_id_to_slot.get(1).?;

    subs.removeClient(1);
    try std.testing.expect(!subs.hasSubscriptions());

    // Subscribe new client - should reuse slot
    try subs.subscribeRange(2, "{track2}", "{fx2}", 0, 10);
    const second_slot = subs.client_id_to_slot.get(2).?;
    try std.testing.expectEqual(first_slot, second_slot);
}

test "invalid range returns error" {
    const allocator = std.testing.allocator;
    var subs = TrackFxParamSubscriptions.init(allocator);
    defer subs.deinit();

    // range_start > range_end should fail
    try std.testing.expectError(error.InvalidRange, subs.subscribeRange(1, "{track}", "{fx}", 10, 5));
}

test "includesParam for range mode" {
    const allocator = std.testing.allocator;
    var subs = TrackFxParamSubscriptions.init(allocator);
    defer subs.deinit();

    try subs.subscribeRange(1, "{track}", "{fx}", 5, 15);
    const client = subs.getClient(1).?;

    try std.testing.expect(!client.includesParam(4));
    try std.testing.expect(client.includesParam(5));
    try std.testing.expect(client.includesParam(10));
    try std.testing.expect(client.includesParam(15));
    try std.testing.expect(!client.includesParam(16));
}
