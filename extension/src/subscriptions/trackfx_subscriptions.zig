/// Track FX Subscriptions - Per-client subscription for track FX chain data.
///
/// Each client can subscribe to a single track's FX chain by GUID.
/// When subscribed, the backend pushes FX chain data (list of FX with presets, enabled state) at HIGH tier.
///
/// Usage:
///   var subs = TrackFxSubscriptions.init(allocator);
///   defer subs.deinit();
///   try subs.subscribe(client_id, "{track-guid}");
///   subs.unsubscribe(client_id);
const std = @import("std");
const logging = @import("../core/logging.zig");
const constants = @import("../core/constants.zig");

const Allocator = std.mem.Allocator;

pub const MAX_CLIENTS = constants.MAX_SUBSCRIPTION_CLIENTS;
pub const GUID_LEN = 40;

/// Per-client subscription state.
pub const ClientSubscription = struct {
    active: bool = false,
    /// Track GUID (stable across reordering)
    track_guid: [GUID_LEN]u8 = undefined,
    guid_len: usize = 0,

    /// Get stored GUID.
    pub fn getGuid(self: *const ClientSubscription) ?[]const u8 {
        if (!self.active or self.guid_len == 0) return null;
        return self.track_guid[0..self.guid_len];
    }

    /// Clear subscription state
    pub fn clear(self: *ClientSubscription) void {
        self.active = false;
        self.guid_len = 0;
    }
};

/// Manages track FX subscriptions across multiple clients.
pub const TrackFxSubscriptions = struct {
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
    /// Uses hash of JSON payload to detect changes without storing full state
    prev_hash: [MAX_CLIENTS]u64,

    pub fn init(allocator: Allocator) TrackFxSubscriptions {
        var subs = TrackFxSubscriptions{
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

    pub fn deinit(self: *TrackFxSubscriptions) void {
        self.client_id_to_slot.deinit();
    }

    /// Get or create a slot for a client.
    fn getOrCreateSlot(self: *TrackFxSubscriptions, client_id: usize) ?usize {
        if (self.client_id_to_slot.get(client_id)) |slot| {
            return slot;
        }

        // Try to reuse a freed slot first
        if (self.free_count > 0) {
            self.free_count -= 1;
            const slot = self.free_slots[self.free_count];
            self.client_id_to_slot.put(client_id, slot) catch |e| {
                logging.warn("trackfx_subscriptions: slot reuse failed for client {d}: {}", .{ client_id, e });
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
            logging.warn("trackfx_subscriptions: slot allocation failed for client {d}: {}", .{ client_id, e });
            return null;
        };
        return slot;
    }

    /// Subscribe to a track's FX chain by GUID.
    pub fn subscribe(self: *TrackFxSubscriptions, client_id: usize, track_guid: []const u8) !void {
        const slot = self.getOrCreateSlot(client_id) orelse return error.TooManyClients;
        const client = &self.clients[slot];

        client.active = true;
        const len = @min(track_guid.len, GUID_LEN);
        @memcpy(client.track_guid[0..len], track_guid[0..len]);
        client.guid_len = len;

        // Force broadcast on new subscription
        self.force_broadcast_clients[slot] = true;

        // Clear previous hash to force full comparison
        self.prev_hash[slot] = 0;

        logging.debug("trackfx_subscriptions: client {d} subscribed to track {s}", .{ client_id, track_guid });
    }

    /// Unsubscribe a client.
    pub fn unsubscribe(self: *TrackFxSubscriptions, client_id: usize) void {
        const slot = self.client_id_to_slot.get(client_id) orelse return;
        const client = &self.clients[slot];
        client.clear();

        // Clear previous hash
        self.prev_hash[slot] = 0;

        logging.debug("trackfx_subscriptions: client {d} unsubscribed", .{client_id});
    }

    /// Remove a client entirely (called on disconnect).
    pub fn removeClient(self: *TrackFxSubscriptions, client_id: usize) void {
        const slot = self.client_id_to_slot.get(client_id) orelse return;
        const client = &self.clients[slot];
        client.clear();

        // Clear previous hash
        self.prev_hash[slot] = 0;

        _ = self.client_id_to_slot.remove(client_id);

        // Add slot to free list for reuse
        self.free_slots[self.free_count] = slot;
        self.free_count += 1;

        logging.debug("trackfx_subscriptions: client {d} removed", .{client_id});
    }

    /// Check if there are any active subscriptions.
    pub fn hasSubscriptions(self: *const TrackFxSubscriptions) bool {
        var iter = self.client_id_to_slot.valueIterator();
        while (iter.next()) |slot| {
            if (self.clients[slot.*].active) return true;
        }
        return false;
    }

    /// Iterator for processing subscriptions.
    pub const SubscriptionIterator = struct {
        subs: *TrackFxSubscriptions,
        key_iter: std.AutoHashMap(usize, usize).KeyIterator,

        pub fn next(self_iter: *SubscriptionIterator) ?struct {
            client_id: usize,
            slot: usize,
            guid: []const u8,
        } {
            while (self_iter.key_iter.next()) |client_id| {
                const slot = self_iter.subs.client_id_to_slot.get(client_id.*) orelse continue;
                const client = &self_iter.subs.clients[slot];
                if (client.active) {
                    if (client.getGuid()) |guid| {
                        return .{ .client_id = client_id.*, .slot = slot, .guid = guid };
                    }
                }
            }
            return null;
        }
    };

    /// Get an iterator over active subscriptions.
    pub fn activeSubscriptions(self: *TrackFxSubscriptions) SubscriptionIterator {
        return .{
            .subs = self,
            .key_iter = self.client_id_to_slot.keyIterator(),
        };
    }

    /// Check if a slot needs force broadcast (and consume the flag).
    pub fn consumeForceBroadcast(self: *TrackFxSubscriptions, slot: usize) bool {
        if (slot >= MAX_CLIENTS) return false;
        if (self.force_broadcast_clients[slot]) {
            self.force_broadcast_clients[slot] = false;
            return true;
        }
        return false;
    }

    /// Check if data changed by comparing hash. Returns true if changed (or force broadcast).
    /// Updates stored hash if changed.
    pub fn checkChanged(self: *TrackFxSubscriptions, slot: usize, data_hash: u64) bool {
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

test "TrackFxSubscriptions init and deinit" {
    const allocator = std.testing.allocator;
    var subs = TrackFxSubscriptions.init(allocator);
    defer subs.deinit();

    try std.testing.expect(!subs.hasSubscriptions());
}

test "subscribe and unsubscribe" {
    const allocator = std.testing.allocator;
    var subs = TrackFxSubscriptions.init(allocator);
    defer subs.deinit();

    try subs.subscribe(1, "{test-guid}");
    try std.testing.expect(subs.hasSubscriptions());

    subs.unsubscribe(1);

    // Client slot still exists but inactive
    const slot = subs.client_id_to_slot.get(1).?;
    try std.testing.expect(!subs.clients[slot].active);
}

test "force_broadcast on subscribe" {
    const allocator = std.testing.allocator;
    var subs = TrackFxSubscriptions.init(allocator);
    defer subs.deinit();

    try subs.subscribe(1, "{test-guid}");
    const slot = subs.client_id_to_slot.get(1).?;

    try std.testing.expect(subs.consumeForceBroadcast(slot));
    try std.testing.expect(!subs.consumeForceBroadcast(slot)); // Consumed
}

test "checkChanged detects changes" {
    const allocator = std.testing.allocator;
    var subs = TrackFxSubscriptions.init(allocator);
    defer subs.deinit();

    try subs.subscribe(1, "{test-guid}");
    const slot = subs.client_id_to_slot.get(1).?;

    // First check - force broadcast triggers change
    try std.testing.expect(subs.checkChanged(slot, 12345));

    // Same hash - no change
    try std.testing.expect(!subs.checkChanged(slot, 12345));

    // Different hash - change
    try std.testing.expect(subs.checkChanged(slot, 67890));
}

test "activeSubscriptions iterator" {
    const allocator = std.testing.allocator;
    var subs = TrackFxSubscriptions.init(allocator);
    defer subs.deinit();

    try subs.subscribe(1, "{guid-1}");
    try subs.subscribe(2, "{guid-2}");
    subs.unsubscribe(1);

    var iter = subs.activeSubscriptions();
    var count: usize = 0;
    while (iter.next()) |entry| {
        try std.testing.expectEqual(@as(usize, 2), entry.client_id);
        try std.testing.expectEqualStrings("{guid-2}", entry.guid);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "removeClient recycles slot" {
    const allocator = std.testing.allocator;
    var subs = TrackFxSubscriptions.init(allocator);
    defer subs.deinit();

    try subs.subscribe(1, "{guid-1}");
    const first_slot = subs.client_id_to_slot.get(1).?;

    subs.removeClient(1);
    try std.testing.expect(!subs.hasSubscriptions());

    // Subscribe new client - should reuse slot
    try subs.subscribe(2, "{guid-2}");
    const second_slot = subs.client_id_to_slot.get(2).?;
    try std.testing.expectEqual(first_slot, second_slot);
}
