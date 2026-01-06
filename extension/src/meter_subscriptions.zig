const std = @import("std");
const logging = @import("logging.zig");

const Allocator = std.mem.Allocator;

// Limits
pub const MAX_TRACKS_PER_CLIENT: usize = 256;
pub const MAX_CLIENTS: usize = 16;

// Grace period before fully unsubscribing a track (30 seconds in nanoseconds)
pub const GRACE_PERIOD_NS: i128 = 30 * std.time.ns_per_s;

/// Manages meter subscriptions across multiple clients.
/// Uses reference counting so we only poll meters for tracks that someone is viewing.
/// Includes a 30-second grace period for tracks that leave the viewport (smoother scrolling UX).
pub const MeterSubscriptions = struct {
    allocator: Allocator,

    /// Reference count for each track index (number of clients subscribed)
    ref_counts: std.AutoHashMap(c_int, u8),

    /// Grace period timestamps: when a track's ref_count drops to 0, we record the time
    /// and keep polling for GRACE_PERIOD_NS before fully removing it
    grace_until: std.AutoHashMap(c_int, i128),

    /// Per-client subscription sets (for cleanup on disconnect)
    client_subscriptions: [MAX_CLIENTS]std.AutoHashMap(c_int, void),

    /// Map from client_id to client slot index
    client_id_to_slot: std.AutoHashMap(usize, usize),

    /// Next available slot
    next_slot: usize,

    pub fn init(allocator: Allocator) MeterSubscriptions {
        var subs = MeterSubscriptions{
            .allocator = allocator,
            .ref_counts = std.AutoHashMap(c_int, u8).init(allocator),
            .grace_until = std.AutoHashMap(c_int, i128).init(allocator),
            .client_subscriptions = undefined,
            .client_id_to_slot = std.AutoHashMap(usize, usize).init(allocator),
            .next_slot = 0,
        };

        // Initialize all client subscription maps
        for (&subs.client_subscriptions) |*map| {
            map.* = std.AutoHashMap(c_int, void).init(allocator);
        }

        return subs;
    }

    pub fn deinit(self: *MeterSubscriptions) void {
        self.ref_counts.deinit();
        self.grace_until.deinit();
        self.client_id_to_slot.deinit();

        for (&self.client_subscriptions) |*map| {
            map.deinit();
        }
    }

    /// Get or create a slot for a client
    fn getOrCreateSlot(self: *MeterSubscriptions, client_id: usize) ?usize {
        if (self.client_id_to_slot.get(client_id)) |slot| {
            return slot;
        }

        // Find an available slot
        if (self.next_slot >= MAX_CLIENTS) {
            // Try to find a reusable slot (client that disconnected)
            // For now, just fail - we'll clean up on disconnect
            return null;
        }

        const slot = self.next_slot;
        self.next_slot += 1;
        self.client_id_to_slot.put(client_id, slot) catch return null;
        return slot;
    }

    /// Subscribe a client to a list of track indices.
    /// This replaces the client's previous subscription set entirely.
    pub fn subscribe(
        self: *MeterSubscriptions,
        client_id: usize,
        track_indices: []const c_int,
    ) !void {
        const slot = self.getOrCreateSlot(client_id) orelse return error.TooManyClients;
        const client_subs = &self.client_subscriptions[slot];

        // Collect current subscriptions to compare
        var old_tracks_buf: [MAX_TRACKS_PER_CLIENT]c_int = undefined;
        var old_count: usize = 0;
        var old_iter = client_subs.keyIterator();
        while (old_iter.next()) |track_idx| {
            if (old_count < old_tracks_buf.len) {
                old_tracks_buf[old_count] = track_idx.*;
                old_count += 1;
            }
        }

        // Unsubscribe from tracks no longer in the list
        for (old_tracks_buf[0..old_count]) |old_track| {
            var found = false;
            for (track_indices) |new_track| {
                if (old_track == new_track) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                self.unsubscribeTrack(client_subs, old_track);
            }
        }

        // Subscribe to new tracks
        for (track_indices) |track_idx| {
            if (client_subs.contains(track_idx)) continue; // Already subscribed

            // Add to client's subscription set
            try client_subs.put(track_idx, {});

            // If this track is in grace period, cancel it
            _ = self.grace_until.remove(track_idx);

            // Increment ref count
            const current_count = self.ref_counts.get(track_idx) orelse 0;
            try self.ref_counts.put(track_idx, current_count + 1);
        }
    }

    /// Internal: unsubscribe a single track for a client
    fn unsubscribeTrack(self: *MeterSubscriptions, client_subs: *std.AutoHashMap(c_int, void), track_idx: c_int) void {
        if (!client_subs.contains(track_idx)) return;

        // Remove from client's subscription set
        _ = client_subs.remove(track_idx);

        // Decrement ref count
        if (self.ref_counts.get(track_idx)) |count| {
            if (count <= 1) {
                // No more active subscribers - start grace period
                _ = self.ref_counts.remove(track_idx);
                const now = std.time.nanoTimestamp();
                self.grace_until.put(track_idx, now + GRACE_PERIOD_NS) catch |e| {
                    logging.warn("meter unsubscribe grace_until update failed for track {d}: {}", .{ track_idx, e });
                };
            } else {
                self.ref_counts.put(track_idx, count - 1) catch |e| {
                    logging.warn("meter unsubscribe ref_count update failed for track {d}: {}", .{ track_idx, e });
                };
            }
        }
    }

    /// Remove all subscriptions for a client (called on disconnect).
    pub fn removeClient(self: *MeterSubscriptions, client_id: usize) void {
        const slot = self.client_id_to_slot.get(client_id) orelse return;
        const client_subs = &self.client_subscriptions[slot];

        // Collect all track indices to unsubscribe
        var track_ids_buf: [MAX_TRACKS_PER_CLIENT]c_int = undefined;
        var count: usize = 0;

        var iter = client_subs.keyIterator();
        while (iter.next()) |track_idx| {
            if (count < track_ids_buf.len) {
                track_ids_buf[count] = track_idx.*;
                count += 1;
            }
        }

        // Unsubscribe from all
        for (track_ids_buf[0..count]) |track_idx| {
            self.unsubscribeTrack(client_subs, track_idx);
        }

        // Clear client's subscription set
        client_subs.clearRetainingCapacity();

        // Remove client from slot mapping
        _ = self.client_id_to_slot.remove(client_id);
    }

    /// Get list of track indices that should be polled for meters.
    /// Includes both actively subscribed tracks and tracks in grace period.
    /// Returns a slice valid only until the next call to this function or expire.
    pub fn getSubscribedTracks(self: *MeterSubscriptions, out_buf: []c_int) []c_int {
        var count: usize = 0;
        const now = std.time.nanoTimestamp();

        // Add actively subscribed tracks
        var ref_iter = self.ref_counts.keyIterator();
        while (ref_iter.next()) |track_idx| {
            if (count < out_buf.len) {
                out_buf[count] = track_idx.*;
                count += 1;
            }
        }

        // Add tracks in grace period (not yet expired)
        var grace_iter = self.grace_until.iterator();
        while (grace_iter.next()) |entry| {
            if (entry.value_ptr.* > now) {
                // Still in grace period
                if (count < out_buf.len) {
                    out_buf[count] = entry.key_ptr.*;
                    count += 1;
                }
            }
        }

        return out_buf[0..count];
    }

    /// Clean up expired grace period entries. Call periodically (e.g., once per second).
    pub fn expireGracePeriods(self: *MeterSubscriptions) void {
        const now = std.time.nanoTimestamp();

        // Collect expired keys first (can't modify during iteration)
        var expired_buf: [MAX_TRACKS_PER_CLIENT]c_int = undefined;
        var expired_count: usize = 0;

        var iter = self.grace_until.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* <= now) {
                if (expired_count < expired_buf.len) {
                    expired_buf[expired_count] = entry.key_ptr.*;
                    expired_count += 1;
                }
            }
        }

        // Remove expired entries
        for (expired_buf[0..expired_count]) |track_idx| {
            _ = self.grace_until.remove(track_idx);
        }
    }

    /// Check if there are any active subscriptions (including grace period)
    pub fn hasSubscriptions(self: *const MeterSubscriptions) bool {
        return self.ref_counts.count() > 0 or self.grace_until.count() > 0;
    }

    /// Get count of actively subscribed tracks (excluding grace period)
    pub fn activeCount(self: *const MeterSubscriptions) usize {
        return self.ref_counts.count();
    }

    /// Get count of tracks in grace period
    pub fn graceCount(self: *const MeterSubscriptions) usize {
        return self.grace_until.count();
    }
};

// =============================================================================
// Tests
// =============================================================================

test "subscribe and unsubscribe" {
    const allocator = std.testing.allocator;
    var subs = MeterSubscriptions.init(allocator);
    defer subs.deinit();

    // Subscribe to tracks 0, 1, 2
    try subs.subscribe(1, &[_]c_int{ 0, 1, 2 });

    try std.testing.expect(subs.hasSubscriptions());
    try std.testing.expectEqual(@as(usize, 3), subs.activeCount());
    try std.testing.expectEqual(@as(usize, 0), subs.graceCount());

    // Update subscription to tracks 1, 2, 3 (removes 0, adds 3)
    try subs.subscribe(1, &[_]c_int{ 1, 2, 3 });

    // Track 0 should now be in grace period
    try std.testing.expectEqual(@as(usize, 3), subs.activeCount());
    try std.testing.expectEqual(@as(usize, 1), subs.graceCount());
}

test "multiple clients same track" {
    const allocator = std.testing.allocator;
    var subs = MeterSubscriptions.init(allocator);
    defer subs.deinit();

    // Two clients subscribe to track 0
    try subs.subscribe(1, &[_]c_int{0});
    try subs.subscribe(2, &[_]c_int{0});

    try std.testing.expectEqual(@as(usize, 1), subs.activeCount());
    try std.testing.expectEqual(@as(u8, 2), subs.ref_counts.get(0).?);

    // First client unsubscribes - should still be active
    try subs.subscribe(1, &[_]c_int{}); // Empty subscription
    try std.testing.expectEqual(@as(usize, 1), subs.activeCount());
    try std.testing.expectEqual(@as(u8, 1), subs.ref_counts.get(0).?);

    // Second client unsubscribes - should enter grace period
    try subs.subscribe(2, &[_]c_int{});
    try std.testing.expectEqual(@as(usize, 0), subs.activeCount());
    try std.testing.expectEqual(@as(usize, 1), subs.graceCount());
}

test "removeClient cleans up all subscriptions" {
    const allocator = std.testing.allocator;
    var subs = MeterSubscriptions.init(allocator);
    defer subs.deinit();

    try subs.subscribe(1, &[_]c_int{ 0, 1, 2 });
    try std.testing.expectEqual(@as(usize, 3), subs.activeCount());

    subs.removeClient(1);

    // All tracks should be in grace period
    try std.testing.expectEqual(@as(usize, 0), subs.activeCount());
    try std.testing.expectEqual(@as(usize, 3), subs.graceCount());
}

test "getSubscribedTracks includes both active and grace period" {
    const allocator = std.testing.allocator;
    var subs = MeterSubscriptions.init(allocator);
    defer subs.deinit();

    // Subscribe to tracks 0, 1
    try subs.subscribe(1, &[_]c_int{ 0, 1 });

    // Unsubscribe from track 0 (enters grace)
    try subs.subscribe(1, &[_]c_int{1});

    var buf: [16]c_int = undefined;
    const subscribed = subs.getSubscribedTracks(&buf);

    // Should have both track 1 (active) and track 0 (grace)
    try std.testing.expectEqual(@as(usize, 2), subscribed.len);
}

test "grace period reactivation" {
    const allocator = std.testing.allocator;
    var subs = MeterSubscriptions.init(allocator);
    defer subs.deinit();

    // Subscribe to track 0
    try subs.subscribe(1, &[_]c_int{0});

    // Unsubscribe (enters grace)
    try subs.subscribe(1, &[_]c_int{});
    try std.testing.expectEqual(@as(usize, 1), subs.graceCount());

    // Re-subscribe to track 0 (should cancel grace period)
    try subs.subscribe(1, &[_]c_int{0});
    try std.testing.expectEqual(@as(usize, 1), subs.activeCount());
    try std.testing.expectEqual(@as(usize, 0), subs.graceCount());
}
