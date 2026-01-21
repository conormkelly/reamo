/// Peaks Subscriptions - Per-client subscription for track mini-peaks.
///
/// Supports two mutually exclusive subscription modes (matching track_subscriptions.zig):
/// - Range mode: Subscribe to unified indices [start, end] (for sequential bank navigation)
/// - GUID mode: Subscribe to specific tracks by GUID (for filtered/custom bank views)
///
/// When subscribed, the backend pushes peak data for all items on the subscribed tracks.
/// The event format is a track-keyed map for efficient O(1) lookup.
///
/// TODO: Master track (idx 0) in peaks subscriptions?
///   - Currently: Range starts at 1 by convention (excludes master)
///   - Master track CAN have audio items if "Show master track in arrange" is enabled
///   - Options: A) Keep excluding master, B) Allow idx 0, document clearly
///   - Master rarely has items, so low priority. Revisit if users request.
///
/// Usage:
///   var subs = PeaksSubscriptions.init(allocator);
///   defer subs.deinit();
///   try subs.subscribeRange(client_id, 1, 8, 30);  // Tracks 1-8, 30 peaks per item
///   try subs.subscribeGuids(client_id, &guids, 30);  // Specific GUIDs
const std = @import("std");
const logging = @import("logging.zig");
const constants = @import("constants.zig");
const peaks_tile = @import("peaks_tile.zig");
const GuidCache = @import("guid_cache.zig").GuidCache;

const Allocator = std.mem.Allocator;

// Re-export shared constants
pub const MAX_CLIENTS = constants.MAX_SUBSCRIPTION_CLIENTS;
pub const MAX_GUIDS_PER_CLIENT = constants.MAX_GUIDS_PER_CLIENT;
pub const GUID_LEN = 40;

// Grace period: 500ms (matches track subscription behavior)
pub const GRACE_PERIOD_NS: i128 = 500 * std.time.ns_per_ms;

/// Subscription mode (mutually exclusive).
pub const SubscriptionMode = enum {
    none, // No subscription
    range, // Subscribe to unified indices [start, end]
    guids, // Subscribe to specific GUIDs
};

/// Per-client subscription state.
pub const ClientSubscription = struct {
    mode: SubscriptionMode = .none,

    // Range mode fields
    range_start: c_int = 0,
    range_end: c_int = 0,

    // GUID mode fields (stored GUIDs)
    guids: [MAX_GUIDS_PER_CLIENT][GUID_LEN]u8 = undefined,
    guid_lens: [MAX_GUIDS_PER_CLIENT]usize = [_]usize{0} ** MAX_GUIDS_PER_CLIENT,
    guid_count: usize = 0,

    /// Number of peaks per item (fallback when viewport not provided)
    sample_count: u32 = 30,

    /// Viewport-aware peak generation (Phase 2)
    /// When set, peakrate is calculated from viewport instead of fixed sample_count
    viewport_start: f64 = 0, // Project time in seconds
    viewport_end: f64 = 0, // Project time in seconds
    viewport_width_px: u32 = 0, // Viewport width for peakrate calculation

    /// Check if viewport is set (non-zero width)
    pub fn hasViewport(self: *const ClientSubscription) bool {
        return self.viewport_width_px > 0 and self.viewport_end > self.viewport_start;
    }

    /// Calculate peakrate from viewport (pixels per second)
    /// **QUANTIZED TO LOD LEVELS** to prevent cache thrashing on small viewport changes.
    /// This is critical - without quantization, every pan/zoom causes cache misses.
    ///
    /// LOD levels (from docs/architecture/LOD_LEVELS.md):
    /// - LOD 7: 1024 peaks/sec - viewport < 5s
    /// - LOD 6: 256 peaks/sec  - viewport 5-20s
    /// - LOD 5: 64 peaks/sec   - viewport 20-75s
    /// - LOD 4: 16 peaks/sec   - viewport 75s-5min
    /// - LOD 3: 4 peaks/sec    - viewport 5-20min
    /// - LOD 2: 1 peak/sec     - viewport 20-80min
    /// - LOD 1: 0.25 peaks/sec - viewport 80min-5hr
    /// - LOD 0: 0.0625 peaks/sec - viewport > 5hr
    pub fn viewportPeakrate(self: *const ClientSubscription) f64 {
        if (!self.hasViewport()) return 64.0; // Fallback to LOD 5
        const duration = self.viewport_end - self.viewport_start;
        if (duration <= 0) return 64.0;

        // Select LOD based on viewport duration and return corresponding peakrate
        const lod = peaks_tile.lodFromViewportDuration(duration);
        return peaks_tile.TILE_CONFIGS[lod].peakrate;
    }

    /// Get current LOD level (0-7) for cache keying
    pub fn viewportLOD(self: *const ClientSubscription) u8 {
        if (!self.hasViewport()) return 5; // Default LOD 5
        const duration = self.viewport_end - self.viewport_start;
        if (duration <= 0) return 5;

        return peaks_tile.lodFromViewportDuration(duration);
    }

    /// Get stored GUID at index.
    pub fn getGuid(self: *const ClientSubscription, idx: usize) ?[]const u8 {
        if (idx >= self.guid_count) return null;
        return self.guids[idx][0..self.guid_lens[idx]];
    }

    /// Clear subscription state
    pub fn clear(self: *ClientSubscription) void {
        self.mode = .none;
        self.range_start = 0;
        self.range_end = 0;
        self.guid_count = 0;
        self.sample_count = 30;
        self.viewport_start = 0;
        self.viewport_end = 0;
        self.viewport_width_px = 0;
    }

    /// Check if subscription is active
    pub fn isActive(self: *const ClientSubscription) bool {
        return self.mode != .none;
    }
};

/// Manages peaks subscriptions across multiple clients.
pub const PeaksSubscriptions = struct {
    allocator: Allocator,

    /// Per-client subscription data (slot-based storage)
    clients: [MAX_CLIENTS]ClientSubscription,

    /// Map from client_id to slot index
    client_id_to_slot: std.AutoHashMap(usize, usize),

    /// Grace period: track_idx -> expiry timestamp.
    /// Tracks stay "subscribed" for grace period after leaving all viewports.
    grace_until: std.AutoHashMap(c_int, i128),

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
            .grace_until = std.AutoHashMap(c_int, i128).init(allocator),
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
        self.grace_until.deinit();
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

    /// Viewport parameters for adaptive peak resolution
    pub const ViewportParams = struct {
        start: f64 = 0,
        end: f64 = 0,
        width_px: u32 = 0,
    };

    /// Subscribe by range (unified indices). Replaces any existing subscription.
    /// Returns the number of tracks in the range.
    pub fn subscribeRange(
        self: *PeaksSubscriptions,
        client_id: usize,
        start: c_int,
        end: c_int,
        sample_count: u32,
    ) !usize {
        return self.subscribeRangeWithViewport(client_id, start, end, sample_count, null);
    }

    /// Subscribe by range with optional viewport for adaptive resolution.
    pub fn subscribeRangeWithViewport(
        self: *PeaksSubscriptions,
        client_id: usize,
        start: c_int,
        end: c_int,
        sample_count: u32,
        viewport: ?ViewportParams,
    ) !usize {
        const slot = self.getOrCreateSlot(client_id) orelse return error.TooManyClients;
        const client = &self.clients[slot];

        client.mode = .range;
        client.range_start = @max(0, start);
        client.range_end = @max(client.range_start, end);
        client.sample_count = sample_count;

        // Set viewport if provided
        if (viewport) |vp| {
            client.viewport_start = vp.start;
            client.viewport_end = vp.end;
            client.viewport_width_px = vp.width_px;
        }

        // Force broadcast to ensure new subscriber gets immediate data
        self.force_broadcast = true;

        const count: usize = @intCast(client.range_end - client.range_start + 1);

        logging.debug("peaks_subscriptions: client {d} subscribed to range [{d}, {d}] with {d} samples", .{
            client_id,
            client.range_start,
            client.range_end,
            sample_count,
        });

        return count;
    }

    /// Subscribe by GUID list. Replaces any existing subscription.
    /// Returns the number of GUIDs stored.
    pub fn subscribeGuids(
        self: *PeaksSubscriptions,
        client_id: usize,
        guids: []const []const u8,
        sample_count: u32,
    ) !usize {
        return self.subscribeGuidsWithViewport(client_id, guids, sample_count, null);
    }

    /// Subscribe by GUID list with optional viewport for adaptive resolution.
    pub fn subscribeGuidsWithViewport(
        self: *PeaksSubscriptions,
        client_id: usize,
        guids: []const []const u8,
        sample_count: u32,
        viewport: ?ViewportParams,
    ) !usize {
        const slot = self.getOrCreateSlot(client_id) orelse return error.TooManyClients;
        const client = &self.clients[slot];

        client.mode = .guids;
        client.guid_count = 0;
        client.sample_count = sample_count;

        // Set viewport if provided
        if (viewport) |vp| {
            client.viewport_start = vp.start;
            client.viewport_end = vp.end;
            client.viewport_width_px = vp.width_px;
        }

        // Store GUIDs (resolution happens at poll time)
        for (guids) |guid| {
            if (client.guid_count >= MAX_GUIDS_PER_CLIENT) break;

            const len = @min(guid.len, GUID_LEN);
            @memcpy(client.guids[client.guid_count][0..len], guid[0..len]);
            client.guid_lens[client.guid_count] = len;
            client.guid_count += 1;
        }

        // Force broadcast to ensure new subscriber gets immediate data
        self.force_broadcast = true;

        logging.debug("peaks_subscriptions: client {d} subscribed to {d} GUIDs with {d} samples", .{
            client_id,
            client.guid_count,
            sample_count,
        });

        return client.guid_count;
    }

    /// Update viewport for an existing subscription (for pan/zoom without re-subscribing).
    /// Returns true if client has an active subscription that was updated.
    pub fn updateViewport(
        self: *PeaksSubscriptions,
        client_id: usize,
        viewport: ViewportParams,
    ) bool {
        const slot = self.client_id_to_slot.get(client_id) orelse return false;
        const client = &self.clients[slot];

        if (client.mode == .none) return false;

        client.viewport_start = viewport.start;
        client.viewport_end = viewport.end;
        client.viewport_width_px = viewport.width_px;

        // NOTE: Do NOT set force_broadcast here!
        // Viewport updates rely on LOD-based cache hits/misses for efficiency.
        // Setting force_broadcast causes full regeneration = disco strobe effect.
        // Only initial subscription should force broadcast, not viewport updates.
        // The quantized LOD in viewportPeakrate() ensures cache stability.

        return true;
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

        // For range subscriptions, add indices to grace period
        if (client.mode == .range) {
            const now = std.time.nanoTimestamp();
            const expiry = now + GRACE_PERIOD_NS;
            var idx = client.range_start;
            while (idx <= client.range_end) : (idx += 1) {
                self.grace_until.put(idx, expiry) catch {};
            }
        }

        client.clear();
        _ = self.client_id_to_slot.remove(client_id);

        // Add slot to free list for reuse
        self.free_slots[self.free_count] = slot;
        self.free_count += 1;

        logging.debug("peaks_subscriptions: client {d} removed", .{client_id});
    }

    /// Get subscription for a client (for reading sample_count, mode, etc).
    pub fn getSubscription(self: *const PeaksSubscriptions, client_id: usize) ?*const ClientSubscription {
        const slot = self.client_id_to_slot.get(client_id) orelse return null;
        const client = &self.clients[slot];
        if (!client.isActive()) return null;
        return client;
    }

    /// Get all track indices that should be polled for peaks.
    /// Combines all client subscriptions (range + GUID resolved) plus grace period.
    pub fn getSubscribedIndices(
        self: *PeaksSubscriptions,
        cache: *const GuidCache,
        api: anytype,
        out_buf: []c_int,
    ) []c_int {
        // Use a hash set to dedupe indices
        var seen = std.AutoHashMap(c_int, void).init(self.allocator);
        defer seen.deinit();

        const track_count = api.trackCount();
        const max_idx = track_count; // Unified: 0=master, 1..track_count = user tracks

        // Process each client's subscription
        var slot_iter = self.client_id_to_slot.valueIterator();
        while (slot_iter.next()) |slot| {
            const client = &self.clients[slot.*];

            switch (client.mode) {
                .none => {},
                .range => {
                    // Add all indices in range (clamped to valid)
                    var idx = @max(0, client.range_start);
                    const end = @min(client.range_end, max_idx);
                    while (idx <= end) : (idx += 1) {
                        seen.put(idx, {}) catch {};
                    }
                },
                .guids => {
                    // Resolve each GUID to an index
                    for (0..client.guid_count) |i| {
                        const guid = client.getGuid(i) orelse continue;
                        const track = cache.resolve(guid) orelse continue;

                        // Get index from pointer
                        const idx = api.getTrackIdx(track);
                        if (idx >= 0 and idx <= max_idx) {
                            seen.put(idx, {}) catch {};
                        }
                    }
                },
            }
        }

        // Add grace period tracks
        const now = std.time.nanoTimestamp();
        var grace_iter = self.grace_until.iterator();
        while (grace_iter.next()) |entry| {
            if (entry.value_ptr.* > now and entry.key_ptr.* <= max_idx) {
                seen.put(entry.key_ptr.*, {}) catch {};
            }
        }

        // Copy to output buffer
        var count: usize = 0;
        var key_iter = seen.keyIterator();
        while (key_iter.next()) |key| {
            if (count >= out_buf.len) break;
            out_buf[count] = key.*;
            count += 1;
        }

        // Sort for consistent ordering
        std.mem.sort(c_int, out_buf[0..count], {}, std.sort.asc(c_int));

        return out_buf[0..count];
    }

    /// Clean up expired grace period entries. Call periodically (e.g., in LOW tier).
    pub fn expireGracePeriods(self: *PeaksSubscriptions) void {
        const now = std.time.nanoTimestamp();

        // Collect expired keys first
        var expired_buf: [256]c_int = undefined;
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
        // Check if any client has a non-none subscription
        var iter = self.client_id_to_slot.valueIterator();
        while (iter.next()) |slot| {
            if (self.clients[slot.*].mode != .none) return true;
        }
        // Also check grace period
        return self.grace_until.count() > 0;
    }

    /// Get count of subscribed clients.
    pub fn clientCount(self: *const PeaksSubscriptions) usize {
        return self.client_id_to_slot.count();
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
                if (sub.isActive()) {
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

test "subscribeRange basic" {
    const allocator = std.testing.allocator;
    var subs = PeaksSubscriptions.init(allocator);
    defer subs.deinit();

    const count = try subs.subscribeRange(1, 0, 9, 30);
    try std.testing.expectEqual(@as(usize, 10), count);
    try std.testing.expect(subs.hasSubscriptions());

    const sub = subs.getSubscription(1).?;
    try std.testing.expectEqual(SubscriptionMode.range, sub.mode);
    try std.testing.expectEqual(@as(c_int, 0), sub.range_start);
    try std.testing.expectEqual(@as(c_int, 9), sub.range_end);
    try std.testing.expectEqual(@as(u32, 30), sub.sample_count);
}

test "subscribeGuids basic" {
    const allocator = std.testing.allocator;
    var subs = PeaksSubscriptions.init(allocator);
    defer subs.deinit();

    const guids = [_][]const u8{ "{guid-1}", "{guid-2}" };
    const count = try subs.subscribeGuids(1, &guids, 50);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expect(subs.hasSubscriptions());

    const sub = subs.getSubscription(1).?;
    try std.testing.expectEqual(SubscriptionMode.guids, sub.mode);
    try std.testing.expectEqual(@as(usize, 2), sub.guid_count);
    try std.testing.expectEqual(@as(u32, 50), sub.sample_count);
    try std.testing.expectEqualStrings("{guid-1}", sub.getGuid(0).?);
    try std.testing.expectEqualStrings("{guid-2}", sub.getGuid(1).?);
}

test "unsubscribe clears subscription" {
    const allocator = std.testing.allocator;
    var subs = PeaksSubscriptions.init(allocator);
    defer subs.deinit();

    _ = try subs.subscribeRange(1, 0, 9, 30);
    try std.testing.expect(subs.hasSubscriptions());

    subs.unsubscribe(1);

    // Client mode should be none now
    const slot = subs.client_id_to_slot.get(1).?;
    try std.testing.expectEqual(SubscriptionMode.none, subs.clients[slot].mode);
}

test "removeClient adds to grace period" {
    const allocator = std.testing.allocator;
    var subs = PeaksSubscriptions.init(allocator);
    defer subs.deinit();

    _ = try subs.subscribeRange(1, 0, 2, 30);
    subs.removeClient(1);

    // Should have 3 tracks in grace period (indices 0, 1, 2)
    try std.testing.expectEqual(@as(usize, 3), subs.grace_until.count());
}

test "getSubscribedIndices with range" {
    const allocator = std.testing.allocator;
    var subs = PeaksSubscriptions.init(allocator);
    defer subs.deinit();

    const reaper = @import("reaper.zig");
    var mock = reaper.MockBackend{ .track_count = 10 };

    var cache = GuidCache.init(allocator);
    defer cache.deinit();
    try cache.rebuild(&mock);

    _ = try subs.subscribeRange(1, 0, 4, 30);

    var buf: [32]c_int = undefined;
    const indices = subs.getSubscribedIndices(&cache, &mock, &buf);

    try std.testing.expectEqual(@as(usize, 5), indices.len);
    // Should be sorted
    try std.testing.expectEqual(@as(c_int, 0), indices[0]);
    try std.testing.expectEqual(@as(c_int, 4), indices[4]);
}

test "getSubscribedIndices with GUIDs" {
    const allocator = std.testing.allocator;
    var subs = PeaksSubscriptions.init(allocator);
    defer subs.deinit();

    const reaper = @import("reaper.zig");
    var mock = reaper.MockBackend{ .track_count = 5 };

    var cache = GuidCache.init(allocator);
    defer cache.deinit();
    try cache.rebuild(&mock);

    // Subscribe to master and track 3 by GUID
    const guids = [_][]const u8{ "master", "{00000000-0000-0000-0000-000000000003}" };
    _ = try subs.subscribeGuids(1, &guids, 30);

    var buf: [32]c_int = undefined;
    const indices = subs.getSubscribedIndices(&cache, &mock, &buf);

    try std.testing.expectEqual(@as(usize, 2), indices.len);
    // Sorted: master (0) then track 3
    try std.testing.expectEqual(@as(c_int, 0), indices[0]);
    try std.testing.expectEqual(@as(c_int, 3), indices[1]);
}

test "multiple clients combined" {
    const allocator = std.testing.allocator;
    var subs = PeaksSubscriptions.init(allocator);
    defer subs.deinit();

    const reaper = @import("reaper.zig");
    var mock = reaper.MockBackend{ .track_count = 10 };

    var cache = GuidCache.init(allocator);
    defer cache.deinit();
    try cache.rebuild(&mock);

    // Client 1: range 0-2
    _ = try subs.subscribeRange(1, 0, 2, 30);
    // Client 2: range 2-4 (overlaps)
    _ = try subs.subscribeRange(2, 2, 4, 30);

    var buf: [32]c_int = undefined;
    const indices = subs.getSubscribedIndices(&cache, &mock, &buf);

    // Should have 0,1,2,3,4 (deduped)
    try std.testing.expectEqual(@as(usize, 5), indices.len);
}

test "force_broadcast flag" {
    const allocator = std.testing.allocator;
    var subs = PeaksSubscriptions.init(allocator);
    defer subs.deinit();

    try std.testing.expect(!subs.consumeForceBroadcast());

    _ = try subs.subscribeRange(1, 0, 5, 30);
    try std.testing.expect(subs.consumeForceBroadcast());
    try std.testing.expect(!subs.consumeForceBroadcast()); // Consumed
}

test "activeSubscriptions iterator" {
    const allocator = std.testing.allocator;
    var subs = PeaksSubscriptions.init(allocator);
    defer subs.deinit();

    _ = try subs.subscribeRange(1, 0, 5, 30);
    _ = try subs.subscribeRange(2, 5, 10, 40);
    subs.unsubscribe(1); // Inactive now

    var iter = subs.activeSubscriptions();
    var count: usize = 0;
    while (iter.next()) |entry| {
        try std.testing.expectEqual(@as(usize, 2), entry.client_id);
        try std.testing.expectEqual(@as(u32, 40), entry.sub.sample_count);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "switching subscription modes" {
    const allocator = std.testing.allocator;
    var subs = PeaksSubscriptions.init(allocator);
    defer subs.deinit();

    // Start with range
    _ = try subs.subscribeRange(1, 0, 9, 30);
    const slot = subs.client_id_to_slot.get(1).?;
    try std.testing.expectEqual(SubscriptionMode.range, subs.clients[slot].mode);

    // Switch to GUIDs
    const guids = [_][]const u8{"{guid-1}"};
    _ = try subs.subscribeGuids(1, &guids, 50);
    try std.testing.expectEqual(SubscriptionMode.guids, subs.clients[slot].mode);

    // Switch back to range
    _ = try subs.subscribeRange(1, 5, 10, 60);
    try std.testing.expectEqual(SubscriptionMode.range, subs.clients[slot].mode);
}

test "slot recycling after client disconnect" {
    const allocator = std.testing.allocator;
    var subs = PeaksSubscriptions.init(allocator);
    defer subs.deinit();

    // Fill all 16 slots
    for (0..MAX_CLIENTS) |i| {
        _ = try subs.subscribeRange(i, 0, 5, 30);
    }
    try std.testing.expectEqual(@as(usize, MAX_CLIENTS), subs.clientCount());

    // New client should fail (slots exhausted)
    const result = subs.subscribeRange(999, 0, 5, 30);
    try std.testing.expectError(error.TooManyClients, result);

    // Disconnect client 5
    subs.removeClient(5);
    try std.testing.expectEqual(@as(usize, MAX_CLIENTS - 1), subs.clientCount());

    // New client should succeed (slot recycled)
    _ = try subs.subscribeRange(100, 0, 5, 30);
    try std.testing.expectEqual(@as(usize, MAX_CLIENTS), subs.clientCount());
}
