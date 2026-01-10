/// Timeline Subscriptions - Per-client time-range filtering for items.
///
/// Enables efficient item data delivery by filtering to each client's
/// subscribed time range. Markers and regions are broadcast to all clients.
///
/// Key design:
/// - Items only: Markers/regions are broadcast, not filtered
/// - Frontend specifies exact range (including any buffer it needs)
/// - Backend returns items within that range - no buffer calculation
/// - Per-client hash tracking for change detection
///
/// Usage:
///   var subs = TimelineSubscriptions.init(allocator);
///   defer subs.deinit();
///   try subs.subscribe(client_id, .{ .start = 0, .end = 30 });
///   var iter = subs.subscribedClientIterator();
///   while (iter.next()) |entry| {
///       // Send filtered items to entry.client_id for entry.range
///   }
const std = @import("std");
const logging = @import("logging.zig");
const constants = @import("constants.zig");

const Allocator = std.mem.Allocator;

pub const MAX_CLIENTS = constants.MAX_SUBSCRIPTION_CLIENTS;

/// Time range in seconds.
/// Frontend specifies exact range it wants (including any buffer it needs).
/// Backend does not calculate buffer - simple, testable, clear separation of concerns.
pub const TimeRange = struct {
    start: f64 = 0, // Start time in seconds (>= 0)
    end: f64 = 0, // End time in seconds (> start)
};

/// Per-client subscription state.
/// Only tracks items - markers/regions are broadcast to all clients.
pub const ClientSubscription = struct {
    range: TimeRange = .{},
    active: bool = false,
    force_broadcast: bool = false, // Set on subscribe/update, cleared after sending

    // Hash of last sent items for change detection (per-client)
    last_items_hash: u64 = 0,

    /// Clear subscription state.
    pub fn clear(self: *ClientSubscription) void {
        self.range = .{};
        self.active = false;
        self.force_broadcast = false;
        self.last_items_hash = 0;
    }
};

/// Entry returned by subscribedClientIterator.
pub const IteratorEntry = struct {
    client_id: usize,
    range: TimeRange,
};

/// Manages timeline subscriptions across multiple clients.
pub const TimelineSubscriptions = struct {
    allocator: Allocator,

    /// Per-client subscription data (fixed-size array).
    clients: [MAX_CLIENTS]ClientSubscription,

    /// Map from client_id to client slot index.
    client_id_to_slot: std.AutoHashMap(usize, usize),

    /// Next available slot (for fresh allocation).
    next_slot: usize,

    /// Free list for recycling slots from disconnected clients.
    free_slots: [MAX_CLIENTS]usize,
    free_count: usize,

    pub fn init(allocator: Allocator) TimelineSubscriptions {
        var subs = TimelineSubscriptions{
            .allocator = allocator,
            .clients = undefined,
            .client_id_to_slot = std.AutoHashMap(usize, usize).init(allocator),
            .next_slot = 0,
            .free_slots = undefined,
            .free_count = 0,
        };

        // Initialize all client slots
        for (&subs.clients) |*client| {
            client.* = ClientSubscription{};
        }

        return subs;
    }

    pub fn deinit(self: *TimelineSubscriptions) void {
        self.client_id_to_slot.deinit();
    }

    /// Get or create a slot for a client.
    fn getOrCreateSlot(self: *TimelineSubscriptions, client_id: usize) error{TooManyClients}!usize {
        if (self.client_id_to_slot.get(client_id)) |slot| {
            return slot;
        }

        // Try to reuse a freed slot first
        if (self.free_count > 0) {
            self.free_count -= 1;
            const slot = self.free_slots[self.free_count];
            self.client_id_to_slot.put(client_id, slot) catch |e| {
                logging.warn("timeline_subscriptions: slot reuse failed for client {d}: {}", .{ client_id, e });
                return error.TooManyClients;
            };
            return slot;
        }

        // Allocate a new slot if available
        if (self.next_slot >= MAX_CLIENTS) {
            return error.TooManyClients;
        }

        const slot = self.next_slot;
        self.next_slot += 1;
        self.client_id_to_slot.put(client_id, slot) catch |e| {
            logging.warn("timeline_subscriptions: slot allocation failed for client {d}: {}", .{ client_id, e });
            return error.TooManyClients;
        };
        return slot;
    }

    /// Subscribe to a time range. Replaces any existing subscription for this client.
    /// Sets force_broadcast to trigger immediate data delivery.
    pub fn subscribe(self: *TimelineSubscriptions, client_id: usize, range: TimeRange) error{TooManyClients}!void {
        const slot = try self.getOrCreateSlot(client_id);
        const client = &self.clients[slot];

        client.range = range;
        client.active = true;
        client.force_broadcast = true;
        // Clear hash to force re-send (new range means different data)
        client.last_items_hash = 0;
    }

    /// Unsubscribe a client (clear their subscription).
    pub fn unsubscribe(self: *TimelineSubscriptions, client_id: usize) void {
        const slot = self.client_id_to_slot.get(client_id) orelse return;
        const client = &self.clients[slot];
        client.active = false;
        client.force_broadcast = false;
    }

    /// Remove a client entirely (called on disconnect).
    pub fn removeClient(self: *TimelineSubscriptions, client_id: usize) void {
        const slot = self.client_id_to_slot.get(client_id) orelse return;
        const client = &self.clients[slot];

        client.clear();
        _ = self.client_id_to_slot.remove(client_id);

        // Add slot to free list for reuse
        self.free_slots[self.free_count] = slot;
        self.free_count += 1;
    }

    /// Get time range for a client, null if not subscribed.
    pub fn getClientRange(self: *const TimelineSubscriptions, client_id: usize) ?TimeRange {
        const slot = self.client_id_to_slot.get(client_id) orelse return null;
        const client = &self.clients[slot];
        if (!client.active) return null;
        return client.range;
    }

    /// Check if there are any active subscriptions.
    pub fn hasSubscriptions(self: *const TimelineSubscriptions) bool {
        var iter = self.client_id_to_slot.valueIterator();
        while (iter.next()) |slot| {
            if (self.clients[slot.*].active) return true;
        }
        return false;
    }

    /// Consume force_broadcast flag for a client.
    /// Returns true if flag was set, clears it in the process.
    pub fn consumeForceBroadcast(self: *TimelineSubscriptions, client_id: usize) bool {
        const slot = self.client_id_to_slot.get(client_id) orelse return false;
        const client = &self.clients[slot];
        if (client.force_broadcast) {
            client.force_broadcast = false;
            return true;
        }
        return false;
    }

    /// Check if items should be sent to this client (hash changed or force broadcast).
    /// Updates the stored hash if returning true.
    pub fn shouldSendItems(self: *TimelineSubscriptions, client_id: usize, new_hash: u64) bool {
        const slot = self.client_id_to_slot.get(client_id) orelse return false;
        const client = &self.clients[slot];
        if (!client.active) return false;
        if (client.force_broadcast or client.last_items_hash != new_hash) {
            client.last_items_hash = new_hash;
            return true;
        }
        return false;
    }

    /// Get count of subscribed (active) clients.
    pub fn clientCount(self: *const TimelineSubscriptions) usize {
        var count: usize = 0;
        var iter = self.client_id_to_slot.valueIterator();
        while (iter.next()) |slot| {
            if (self.clients[slot.*].active) count += 1;
        }
        return count;
    }

    /// Iterator for subscribed clients.
    pub const SubscribedClientIterator = struct {
        subs: *const TimelineSubscriptions,
        inner_iter: std.AutoHashMap(usize, usize).Iterator,

        pub fn next(self: *SubscribedClientIterator) ?IteratorEntry {
            while (self.inner_iter.next()) |entry| {
                const client_id = entry.key_ptr.*;
                const slot = entry.value_ptr.*;
                const client = &self.subs.clients[slot];
                if (client.active) {
                    return .{
                        .client_id = client_id,
                        .range = client.range,
                    };
                }
            }
            return null;
        }
    };

    /// Get iterator over all subscribed clients.
    pub fn subscribedClientIterator(self: *const TimelineSubscriptions) SubscribedClientIterator {
        return .{
            .subs = self,
            .inner_iter = self.client_id_to_slot.iterator(),
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

test "TimelineSubscriptions init and deinit" {
    const allocator = std.testing.allocator;
    var subs = TimelineSubscriptions.init(allocator);
    defer subs.deinit();

    try std.testing.expect(!subs.hasSubscriptions());
    try std.testing.expectEqual(@as(usize, 0), subs.clientCount());
}

test "subscribe basic" {
    const allocator = std.testing.allocator;
    var subs = TimelineSubscriptions.init(allocator);
    defer subs.deinit();

    try subs.subscribe(1, .{ .start = 0, .end = 30 });
    try std.testing.expect(subs.hasSubscriptions());
    try std.testing.expectEqual(@as(usize, 1), subs.clientCount());

    const range = subs.getClientRange(1).?;
    try std.testing.expectApproxEqAbs(@as(f64, 0), range.start, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 30), range.end, 0.001);
}

test "unsubscribe clears subscription" {
    const allocator = std.testing.allocator;
    var subs = TimelineSubscriptions.init(allocator);
    defer subs.deinit();

    try subs.subscribe(1, .{ .start = 0, .end = 30 });
    try std.testing.expect(subs.hasSubscriptions());

    subs.unsubscribe(1);
    try std.testing.expect(!subs.hasSubscriptions());
    try std.testing.expect(subs.getClientRange(1) == null);
}

test "removeClient recycles slot" {
    const allocator = std.testing.allocator;
    var subs = TimelineSubscriptions.init(allocator);
    defer subs.deinit();

    try subs.subscribe(1, .{ .start = 0, .end = 30 });
    try std.testing.expectEqual(@as(usize, 1), subs.clientCount());

    subs.removeClient(1);
    try std.testing.expectEqual(@as(usize, 0), subs.clientCount());
    try std.testing.expectEqual(@as(usize, 1), subs.free_count);
}

test "multiple clients with different ranges" {
    const allocator = std.testing.allocator;
    var subs = TimelineSubscriptions.init(allocator);
    defer subs.deinit();

    try subs.subscribe(1, .{ .start = 0, .end = 30 });
    try subs.subscribe(2, .{ .start = 60, .end = 120 });
    try subs.subscribe(3, .{ .start = 30, .end = 60 });

    try std.testing.expectEqual(@as(usize, 3), subs.clientCount());

    const r1 = subs.getClientRange(1).?;
    const r2 = subs.getClientRange(2).?;
    const r3 = subs.getClientRange(3).?;

    try std.testing.expectApproxEqAbs(@as(f64, 30), r1.end, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 60), r2.start, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 30), r3.start, 0.001);
}

test "force broadcast per-client" {
    const allocator = std.testing.allocator;
    var subs = TimelineSubscriptions.init(allocator);
    defer subs.deinit();

    try subs.subscribe(1, .{ .start = 0, .end = 30 });
    try subs.subscribe(2, .{ .start = 60, .end = 90 });

    // Both should have force_broadcast set
    try std.testing.expect(subs.consumeForceBroadcast(1));
    try std.testing.expect(subs.consumeForceBroadcast(2));

    // Now both should be cleared
    try std.testing.expect(!subs.consumeForceBroadcast(1));
    try std.testing.expect(!subs.consumeForceBroadcast(2));

    // Update client 1's subscription - only client 1 gets force_broadcast
    try subs.subscribe(1, .{ .start = 10, .end = 40 });
    try std.testing.expect(subs.consumeForceBroadcast(1));
    try std.testing.expect(!subs.consumeForceBroadcast(2));
}

test "hash change detection for items" {
    const allocator = std.testing.allocator;
    var subs = TimelineSubscriptions.init(allocator);
    defer subs.deinit();

    try subs.subscribe(1, .{ .start = 0, .end = 30 });
    // Consume force broadcast first
    _ = subs.consumeForceBroadcast(1);

    // First hash should trigger send
    try std.testing.expect(subs.shouldSendItems(1, 12345));

    // Same hash should not trigger
    try std.testing.expect(!subs.shouldSendItems(1, 12345));

    // Different hash should trigger
    try std.testing.expect(subs.shouldSendItems(1, 67890));
}

test "subscribedClientIterator" {
    const allocator = std.testing.allocator;
    var subs = TimelineSubscriptions.init(allocator);
    defer subs.deinit();

    try subs.subscribe(1, .{ .start = 0, .end = 30 });
    try subs.subscribe(2, .{ .start = 60, .end = 90 });
    try subs.subscribe(3, .{ .start = 30, .end = 60 });

    // Unsubscribe client 2
    subs.unsubscribe(2);

    var count: usize = 0;
    var iter = subs.subscribedClientIterator();
    while (iter.next()) |_| {
        count += 1;
    }

    try std.testing.expectEqual(@as(usize, 2), count);
}

test "slot recycling after client disconnect" {
    const allocator = std.testing.allocator;
    var subs = TimelineSubscriptions.init(allocator);
    defer subs.deinit();

    // Fill all slots
    for (0..MAX_CLIENTS) |i| {
        try subs.subscribe(i, .{ .start = 0, .end = 30 });
    }
    try std.testing.expectEqual(@as(usize, MAX_CLIENTS), subs.clientCount());

    // New client should fail
    const result = subs.subscribe(999, .{ .start = 0, .end = 30 });
    try std.testing.expectError(error.TooManyClients, result);

    // Disconnect client 5
    subs.removeClient(5);

    // New client should succeed (slot recycled)
    try subs.subscribe(100, .{ .start = 0, .end = 30 });
    try std.testing.expectEqual(@as(usize, MAX_CLIENTS), subs.clientCount());
}

test "resubscribe updates range" {
    const allocator = std.testing.allocator;
    var subs = TimelineSubscriptions.init(allocator);
    defer subs.deinit();

    try subs.subscribe(1, .{ .start = 0, .end = 30 });

    var range = subs.getClientRange(1).?;
    try std.testing.expectApproxEqAbs(@as(f64, 0), range.start, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 30), range.end, 0.001);

    // Resubscribe with different range
    try subs.subscribe(1, .{ .start = 60, .end = 120 });

    range = subs.getClientRange(1).?;
    try std.testing.expectApproxEqAbs(@as(f64, 60), range.start, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 120), range.end, 0.001);

    // Should still only have 1 client
    try std.testing.expectEqual(@as(usize, 1), subs.clientCount());
}
