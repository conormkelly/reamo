/// Peaks Subscriptions - Per-client subscription for track mini-peaks.
///
/// Each client can subscribe to peaks for one track at a time.
/// When subscribed, the backend pushes peak data for all items on that track.
///
/// Usage:
///   var subs = PeaksSubscriptions.init(allocator);
///   defer subs.deinit();
///   try subs.subscribe(client_id, "{track-guid}", 30);  // 30 peaks per item
///   // Later: check subs.getSubscription(client_id) to get track GUID
const std = @import("std");
const logging = @import("logging.zig");
const constants = @import("constants.zig");

const Allocator = std.mem.Allocator;

// Re-export shared constants
pub const MAX_CLIENTS = constants.MAX_SUBSCRIPTION_CLIENTS;
pub const GUID_LEN = 40;

/// Per-client subscription state.
pub const ClientSubscription = struct {
    /// Track GUID being subscribed to (38 chars + null + padding)
    track_guid: [GUID_LEN]u8 = undefined,
    track_guid_len: usize = 0,

    /// Number of peaks per item (typically 30 for timeline blobs)
    sample_count: u32 = 30,

    /// Whether this client has an active subscription
    active: bool = false,

    /// Get the track GUID as a slice
    pub fn getTrackGuid(self: *const ClientSubscription) ?[]const u8 {
        if (!self.active) return null;
        if (self.track_guid_len == 0) return null;
        return self.track_guid[0..self.track_guid_len];
    }

    /// Clear subscription state
    pub fn clear(self: *ClientSubscription) void {
        self.active = false;
        self.track_guid_len = 0;
        self.sample_count = 30;
    }
};

/// Manages peaks subscriptions across multiple clients.
pub const PeaksSubscriptions = struct {
    allocator: Allocator,

    /// Per-client subscription data (slot-based storage)
    clients: [MAX_CLIENTS]ClientSubscription,

    /// Map from client_id to slot index
    client_id_to_slot: std.AutoHashMap(usize, usize),

    /// Next available slot (for fresh allocation)
    next_slot: usize,

    /// Free list for recycling slots from disconnected clients
    free_slots: [MAX_CLIENTS]usize = undefined,
    free_count: usize = 0,

    /// Force broadcast flag - set when subscriptions change
    force_broadcast: bool = false,

    pub fn init(allocator: Allocator) PeaksSubscriptions {
        var subs = PeaksSubscriptions{
            .allocator = allocator,
            .clients = undefined,
            .client_id_to_slot = std.AutoHashMap(usize, usize).init(allocator),
            .next_slot = 0,
        };

        // Initialize all client slots
        for (&subs.clients) |*client| {
            client.* = ClientSubscription{};
        }

        return subs;
    }

    pub fn deinit(self: *PeaksSubscriptions) void {
        self.client_id_to_slot.deinit();
    }

    /// Get or create a slot for a client.
    fn getOrCreateSlot(self: *PeaksSubscriptions, client_id: usize) ?usize {
        if (self.client_id_to_slot.get(client_id)) |slot| {
            return slot;
        }

        // Try to reuse a freed slot first
        if (self.free_count > 0) {
            self.free_count -= 1;
            const slot = self.free_slots[self.free_count];
            self.client_id_to_slot.put(client_id, slot) catch |e| {
                logging.warn("peaks_subscriptions: slot reuse failed for client {d}: {}", .{ client_id, e });
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
            logging.warn("peaks_subscriptions: slot allocation failed for client {d}: {}", .{ client_id, e });
            return null;
        };
        return slot;
    }

    /// Subscribe to peaks for a track.
    /// Replaces any existing subscription for this client.
    pub fn subscribe(
        self: *PeaksSubscriptions,
        client_id: usize,
        track_guid: []const u8,
        sample_count: u32,
    ) !void {
        const slot = self.getOrCreateSlot(client_id) orelse return error.TooManyClients;
        const client = &self.clients[slot];

        // Store track GUID
        const len = @min(track_guid.len, GUID_LEN);
        @memcpy(client.track_guid[0..len], track_guid[0..len]);
        client.track_guid_len = len;
        client.sample_count = sample_count;
        client.active = true;

        // Force broadcast to ensure new subscriber gets immediate data
        self.force_broadcast = true;

        logging.debug("peaks_subscriptions: client {d} subscribed to track {s} with {d} samples", .{
            client_id,
            track_guid,
            sample_count,
        });
    }

    /// Unsubscribe a client (clear their subscription).
    pub fn unsubscribe(self: *PeaksSubscriptions, client_id: usize) void {
        const slot = self.client_id_to_slot.get(client_id) orelse return;
        const client = &self.clients[slot];
        client.clear();
        logging.debug("peaks_subscriptions: client {d} unsubscribed", .{client_id});
    }

    /// Remove a client entirely (called on disconnect).
    pub fn removeClient(self: *PeaksSubscriptions, client_id: usize) void {
        const slot = self.client_id_to_slot.get(client_id) orelse return;
        const client = &self.clients[slot];

        client.clear();
        _ = self.client_id_to_slot.remove(client_id);

        // Add slot to free list for reuse
        self.free_slots[self.free_count] = slot;
        self.free_count += 1;

        logging.debug("peaks_subscriptions: client {d} removed", .{client_id});
    }

    /// Get subscription for a client.
    pub fn getSubscription(self: *const PeaksSubscriptions, client_id: usize) ?*const ClientSubscription {
        const slot = self.client_id_to_slot.get(client_id) orelse return null;
        const client = &self.clients[slot];
        if (!client.active) return null;
        return client;
    }

    /// Check and clear force_broadcast flag (atomic consume).
    pub fn consumeForceBroadcast(self: *PeaksSubscriptions) bool {
        if (self.force_broadcast) {
            self.force_broadcast = false;
            return true;
        }
        return false;
    }

    /// Check if there are any active subscriptions.
    pub fn hasSubscriptions(self: *const PeaksSubscriptions) bool {
        var iter = self.client_id_to_slot.valueIterator();
        while (iter.next()) |slot| {
            if (self.clients[slot.*].active) return true;
        }
        return false;
    }

    /// Get count of subscribed clients.
    pub fn clientCount(self: *const PeaksSubscriptions) usize {
        var count: usize = 0;
        var iter = self.client_id_to_slot.valueIterator();
        while (iter.next()) |slot| {
            if (self.clients[slot.*].active) count += 1;
        }
        return count;
    }

    /// Iterator for active subscriptions (for broadcasting).
    /// Returns (client_id, subscription) pairs.
    pub const SubscriptionIterator = struct {
        subs: *const PeaksSubscriptions,
        key_iter: std.AutoHashMap(usize, usize).KeyIterator,

        pub fn next(self: *SubscriptionIterator) ?struct { client_id: usize, sub: *const ClientSubscription } {
            while (self.key_iter.next()) |client_id| {
                const slot = self.subs.client_id_to_slot.get(client_id.*) orelse continue;
                const sub = &self.subs.clients[slot];
                if (sub.active) {
                    return .{ .client_id = client_id.*, .sub = sub };
                }
            }
            return null;
        }
    };

    /// Get an iterator over active subscriptions.
    pub fn activeSubscriptions(self: *const PeaksSubscriptions) SubscriptionIterator {
        return .{
            .subs = self,
            .key_iter = self.client_id_to_slot.keyIterator(),
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

test "PeaksSubscriptions init and deinit" {
    const allocator = std.testing.allocator;
    var subs = PeaksSubscriptions.init(allocator);
    defer subs.deinit();

    try std.testing.expect(!subs.hasSubscriptions());
    try std.testing.expectEqual(@as(usize, 0), subs.clientCount());
}

test "subscribe basic" {
    const allocator = std.testing.allocator;
    var subs = PeaksSubscriptions.init(allocator);
    defer subs.deinit();

    try subs.subscribe(1, "{test-guid}", 50);
    try std.testing.expect(subs.hasSubscriptions());
    try std.testing.expectEqual(@as(usize, 1), subs.clientCount());

    const sub = subs.getSubscription(1).?;
    try std.testing.expectEqualStrings("{test-guid}", sub.getTrackGuid().?);
    try std.testing.expectEqual(@as(u32, 50), sub.sample_count);
}

test "unsubscribe clears subscription" {
    const allocator = std.testing.allocator;
    var subs = PeaksSubscriptions.init(allocator);
    defer subs.deinit();

    try subs.subscribe(1, "{test-guid}", 30);
    try std.testing.expect(subs.hasSubscriptions());

    subs.unsubscribe(1);
    try std.testing.expect(!subs.hasSubscriptions());
}

test "removeClient recycles slot" {
    const allocator = std.testing.allocator;
    var subs = PeaksSubscriptions.init(allocator);
    defer subs.deinit();

    try subs.subscribe(1, "{test-guid}", 30);
    subs.removeClient(1);

    try std.testing.expect(!subs.hasSubscriptions());
    try std.testing.expect(subs.getSubscription(1) == null);
}

test "multiple clients" {
    const allocator = std.testing.allocator;
    var subs = PeaksSubscriptions.init(allocator);
    defer subs.deinit();

    try subs.subscribe(1, "{guid-1}", 30);
    try subs.subscribe(2, "{guid-2}", 40);
    try subs.subscribe(3, "{guid-3}", 50);

    try std.testing.expectEqual(@as(usize, 3), subs.clientCount());

    // Each client has its own subscription
    try std.testing.expectEqualStrings("{guid-1}", subs.getSubscription(1).?.getTrackGuid().?);
    try std.testing.expectEqualStrings("{guid-2}", subs.getSubscription(2).?.getTrackGuid().?);
    try std.testing.expectEqualStrings("{guid-3}", subs.getSubscription(3).?.getTrackGuid().?);
}

test "force_broadcast flag" {
    const allocator = std.testing.allocator;
    var subs = PeaksSubscriptions.init(allocator);
    defer subs.deinit();

    try std.testing.expect(!subs.consumeForceBroadcast());

    try subs.subscribe(1, "{test-guid}", 30);
    try std.testing.expect(subs.consumeForceBroadcast());
    try std.testing.expect(!subs.consumeForceBroadcast()); // Consumed
}

test "activeSubscriptions iterator" {
    const allocator = std.testing.allocator;
    var subs = PeaksSubscriptions.init(allocator);
    defer subs.deinit();

    try subs.subscribe(1, "{guid-1}", 30);
    try subs.subscribe(2, "{guid-2}", 40);
    subs.unsubscribe(1); // Inactive now

    var iter = subs.activeSubscriptions();
    var count: usize = 0;
    while (iter.next()) |entry| {
        try std.testing.expectEqual(@as(usize, 2), entry.client_id);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}
