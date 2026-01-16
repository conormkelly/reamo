/// Track Subscriptions - Per-client viewport tracking for selective polling.
///
/// Supports two mutually exclusive subscription modes:
/// - Range mode: Subscribe to unified indices [start, end] (e.g., visible viewport)
/// - GUID mode: Subscribe to specific tracks by GUID (for pinned/selected tracks)
///
/// Grace period prevents thrashing when scrolling (tracks stay subscribed briefly after leaving viewport).
///
/// Usage:
///   var subs = TrackSubscriptions.init(allocator);
///   defer subs.deinit();
///   try subs.subscribeRange(client_id, 0, 31);  // First 32 tracks
///   const indices = subs.getSubscribedIndices(&cache, &api, &buf);
const std = @import("std");
const logging = @import("logging.zig");
const GuidCache = @import("guid_cache.zig").GuidCache;
const constants = @import("constants.zig");

const Allocator = std.mem.Allocator;

// Re-export shared constants for backward compatibility
pub const MAX_TRACKS_PER_CLIENT = constants.MAX_TRACKS_PER_CLIENT;
pub const MAX_GUIDS_PER_CLIENT = constants.MAX_GUIDS_PER_CLIENT;
pub const MAX_CLIENTS = constants.MAX_SUBSCRIPTION_CLIENTS;

// Grace period: 500ms (tracks are expensive, but shorter than meter's 30s)
pub const GRACE_PERIOD_NS: i128 = 500 * std.time.ns_per_ms;

/// Subscription mode (mutually exclusive).
pub const SubscriptionMode = enum {
    none, // No subscription
    range, // Subscribe to unified indices [start, end]
    guids, // Subscribe to specific GUIDs
};

/// Maximum extra GUIDs per client (for hybrid range + specific tracks)
pub const MAX_EXTRA_GUIDS = 8;

/// Per-client subscription state.
pub const ClientSubscription = struct {
    mode: SubscriptionMode = .none,

    // Range mode fields
    range_start: c_int = 0,
    range_end: c_int = 0,

    // GUID mode fields (stored GUIDs)
    guids: [MAX_GUIDS_PER_CLIENT][40]u8 = undefined,
    guid_lens: [MAX_GUIDS_PER_CLIENT]usize = [_]usize{0} ** MAX_GUIDS_PER_CLIENT,
    guid_count: usize = 0,

    // Extra GUIDs for range mode (e.g., info-selected track outside visible bank)
    // These are resolved alongside the range, allowing hybrid subscriptions.
    extra_guids: [MAX_EXTRA_GUIDS][40]u8 = undefined,
    extra_guid_lens: [MAX_EXTRA_GUIDS]usize = [_]usize{0} ** MAX_EXTRA_GUIDS,
    extra_guid_count: usize = 0,

    // Always include master track (for pinned master meter display)
    include_master: bool = false,

    /// Clear subscription state.
    pub fn clear(self: *ClientSubscription) void {
        self.mode = .none;
        self.range_start = 0;
        self.range_end = 0;
        self.guid_count = 0;
        self.extra_guid_count = 0;
        self.include_master = false;
    }

    /// Get stored GUID at index.
    pub fn getGuid(self: *const ClientSubscription, idx: usize) ?[]const u8 {
        if (idx >= self.guid_count) return null;
        return self.guids[idx][0..self.guid_lens[idx]];
    }

    /// Get stored extra GUID at index.
    pub fn getExtraGuid(self: *const ClientSubscription, idx: usize) ?[]const u8 {
        if (idx >= self.extra_guid_count) return null;
        return self.extra_guids[idx][0..self.extra_guid_lens[idx]];
    }
};

/// Manages track subscriptions across multiple clients.
pub const TrackSubscriptions = struct {
    allocator: Allocator,

    /// Per-client subscription data.
    clients: [MAX_CLIENTS]ClientSubscription,

    /// Map from client_id to client slot index.
    client_id_to_slot: std.AutoHashMap(usize, usize),

    /// Grace period: track_idx → expiry timestamp.
    /// Tracks stay "subscribed" for grace period after leaving all viewports.
    grace_until: std.AutoHashMap(c_int, i128),

    /// Reference counts for GUID-based subscriptions.
    /// Key is track index (resolved from GUID at subscription time).
    ref_counts: std.AutoHashMap(c_int, u8),

    /// Next available slot (for fresh allocation).
    next_slot: usize,

    /// Free list for recycling slots from disconnected clients.
    free_slots: [MAX_CLIENTS]usize = undefined,
    free_count: usize = 0,

    /// Force broadcast flag - set when subscriptions change to ensure immediate data push.
    /// The poll loop checks this and broadcasts tracks unconditionally when true.
    force_broadcast: bool = false,

    pub fn init(allocator: Allocator) TrackSubscriptions {
        var subs = TrackSubscriptions{
            .allocator = allocator,
            .clients = undefined,
            .client_id_to_slot = std.AutoHashMap(usize, usize).init(allocator),
            .grace_until = std.AutoHashMap(c_int, i128).init(allocator),
            .ref_counts = std.AutoHashMap(c_int, u8).init(allocator),
            .next_slot = 0,
        };

        // Initialize all client slots
        for (&subs.clients) |*client| {
            client.* = ClientSubscription{};
        }

        return subs;
    }

    pub fn deinit(self: *TrackSubscriptions) void {
        self.client_id_to_slot.deinit();
        self.grace_until.deinit();
        self.ref_counts.deinit();
    }

    /// Get or create a slot for a client.
    fn getOrCreateSlot(self: *TrackSubscriptions, client_id: usize) ?usize {
        if (self.client_id_to_slot.get(client_id)) |slot| {
            return slot;
        }

        // Try to reuse a freed slot first
        if (self.free_count > 0) {
            self.free_count -= 1;
            const slot = self.free_slots[self.free_count];
            self.client_id_to_slot.put(client_id, slot) catch |e| {
                logging.warn("track_subscriptions: slot reuse failed for client {d}: {}", .{ client_id, e });
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
            logging.warn("track_subscriptions: slot allocation failed for client {d}: {}", .{ client_id, e });
            return null;
        };
        return slot;
    }

    /// Subscribe by range (unified indices). Replaces any existing subscription.
    /// Returns the number of tracks in the range (plus master if includeMaster and not in range).
    /// Optional extra_guids parameter allows subscribing to specific tracks outside the range
    /// (e.g., info-selected track that's been paged out of view).
    pub fn subscribeRange(
        self: *TrackSubscriptions,
        client_id: usize,
        start: c_int,
        end: c_int,
        include_master: bool,
    ) !usize {
        return self.subscribeRangeWithExtras(client_id, start, end, include_master, null);
    }

    /// Subscribe by range with optional extra GUIDs for hybrid subscriptions.
    pub fn subscribeRangeWithExtras(
        self: *TrackSubscriptions,
        client_id: usize,
        start: c_int,
        end: c_int,
        include_master: bool,
        extra_guids: ?[]const []const u8,
    ) !usize {
        const slot = self.getOrCreateSlot(client_id) orelse return error.TooManyClients;
        const client = &self.clients[slot];

        // Clear previous GUID subscriptions if switching modes
        if (client.mode == .guids) {
            self.clearGuidRefs(client);
        }

        client.mode = .range;
        client.range_start = @max(0, start);
        client.range_end = @max(client.range_start, end);
        client.include_master = include_master;

        // Store extra GUIDs if provided
        client.extra_guid_count = 0;
        if (extra_guids) |guids| {
            for (guids) |guid| {
                if (client.extra_guid_count >= MAX_EXTRA_GUIDS) break;

                const len = @min(guid.len, 40);
                @memcpy(client.extra_guids[client.extra_guid_count][0..len], guid[0..len]);
                client.extra_guid_lens[client.extra_guid_count] = len;
                client.extra_guid_count += 1;
            }
        }

        // Force broadcast to ensure new subscriber gets immediate data
        self.force_broadcast = true;

        var count: usize = @intCast(client.range_end - client.range_start + 1);
        // Add 1 for master if requested and not already in range
        if (include_master and client.range_start > 0) {
            count += 1;
        }
        // Add extra GUIDs count
        count += client.extra_guid_count;
        return count;
    }

    /// Subscribe by GUID list. Replaces any existing subscription.
    /// Returns the number of GUIDs stored plus master if includeMaster (may differ from resolved tracks).
    pub fn subscribeGuids(
        self: *TrackSubscriptions,
        client_id: usize,
        guids: []const []const u8,
        include_master: bool,
    ) !usize {
        const slot = self.getOrCreateSlot(client_id) orelse return error.TooManyClients;
        const client = &self.clients[slot];

        // Clear previous GUID subscriptions (ref counts)
        if (client.mode == .guids) {
            self.clearGuidRefs(client);
        }

        client.mode = .guids;
        client.guid_count = 0;
        client.include_master = include_master;

        // Check if master is already in the GUID list
        var has_master = false;

        // Store GUIDs (resolution happens at poll time)
        for (guids) |guid| {
            if (client.guid_count >= MAX_GUIDS_PER_CLIENT) break;

            if (std.mem.eql(u8, guid, "master")) {
                has_master = true;
            }

            const len = @min(guid.len, 40);
            @memcpy(client.guids[client.guid_count][0..len], guid[0..len]);
            client.guid_lens[client.guid_count] = len;
            client.guid_count += 1;
        }

        // Force broadcast to ensure new subscriber gets immediate data
        self.force_broadcast = true;

        var count = client.guid_count;
        // Add 1 for master if requested and not already in GUID list
        if (include_master and !has_master) {
            count += 1;
        }
        return count;
    }

    /// Clear ref counts for a client's GUID subscriptions.
    fn clearGuidRefs(self: *TrackSubscriptions, client: *ClientSubscription) void {
        _ = self;
        _ = client;
        // Note: For simplicity, we don't track ref counts per-client for GUIDs.
        // GUID mode subscriptions are resolved fresh each poll cycle.
        // This is simpler and avoids stale pointer issues when tracks are deleted.
    }

    /// Unsubscribe a client (clear their subscription).
    pub fn unsubscribe(self: *TrackSubscriptions, client_id: usize) void {
        const slot = self.client_id_to_slot.get(client_id) orelse return;
        const client = &self.clients[slot];
        client.clear();
    }

    /// Remove a client entirely (called on disconnect).
    pub fn removeClient(self: *TrackSubscriptions, client_id: usize) void {
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
    }

    /// Get all track indices that should be polled.
    /// Combines all client subscriptions (range + GUID resolved) plus grace period.
    pub fn getSubscribedIndices(
        self: *TrackSubscriptions,
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

            // Always include master if client requested it
            if (client.include_master) {
                seen.put(0, {}) catch {};
            }

            switch (client.mode) {
                .none => {},
                .range => {
                    // Add all indices in range (clamped to valid)
                    var idx = @max(0, client.range_start);
                    const end = @min(client.range_end, max_idx);
                    while (idx <= end) : (idx += 1) {
                        seen.put(idx, {}) catch {};
                    }

                    // Also resolve any extra GUIDs (hybrid subscription)
                    for (0..client.extra_guid_count) |i| {
                        const guid = client.getExtraGuid(i) orelse continue;
                        const track = cache.resolve(guid) orelse continue;

                        const extra_idx = api.getTrackIdx(track);
                        if (extra_idx >= 0 and extra_idx <= max_idx) {
                            seen.put(extra_idx, {}) catch {};
                        }
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
    pub fn expireGracePeriods(self: *TrackSubscriptions) void {
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

    /// Check if there are any active subscriptions.
    pub fn hasSubscriptions(self: *const TrackSubscriptions) bool {
        // Check if any client has a non-none subscription
        var iter = self.client_id_to_slot.valueIterator();
        while (iter.next()) |slot| {
            if (self.clients[slot.*].mode != .none) return true;
        }
        // Also check grace period
        return self.grace_until.count() > 0;
    }

    /// Check and clear force_broadcast flag (atomic consume).
    /// Returns true if flag was set, clears it in the process.
    pub fn consumeForceBroadcast(self: *TrackSubscriptions) bool {
        if (self.force_broadcast) {
            self.force_broadcast = false;
            return true;
        }
        return false;
    }

    /// Get count of subscribed clients.
    pub fn clientCount(self: *const TrackSubscriptions) usize {
        return self.client_id_to_slot.count();
    }
};

// =============================================================================
// Tests
// =============================================================================

test "TrackSubscriptions init and deinit" {
    const allocator = std.testing.allocator;
    var subs = TrackSubscriptions.init(allocator);
    defer subs.deinit();

    try std.testing.expect(!subs.hasSubscriptions());
    try std.testing.expectEqual(@as(usize, 0), subs.clientCount());
}

test "subscribeRange basic" {
    const allocator = std.testing.allocator;
    var subs = TrackSubscriptions.init(allocator);
    defer subs.deinit();

    const count = try subs.subscribeRange(1, 0, 9, false);
    try std.testing.expectEqual(@as(usize, 10), count);
    try std.testing.expect(subs.hasSubscriptions());
}

test "subscribeGuids basic" {
    const allocator = std.testing.allocator;
    var subs = TrackSubscriptions.init(allocator);
    defer subs.deinit();

    const guids = [_][]const u8{ "master", "{00000001}" };
    const count = try subs.subscribeGuids(1, &guids, false);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expect(subs.hasSubscriptions());
}

test "unsubscribe clears subscription" {
    const allocator = std.testing.allocator;
    var subs = TrackSubscriptions.init(allocator);
    defer subs.deinit();

    _ = try subs.subscribeRange(1, 0, 9, false);
    try std.testing.expect(subs.hasSubscriptions());

    subs.unsubscribe(1);

    // Grace period keeps hasSubscriptions true briefly, but client mode is none
    const slot = subs.client_id_to_slot.get(1).?;
    try std.testing.expectEqual(SubscriptionMode.none, subs.clients[slot].mode);
}

test "removeClient adds to grace period" {
    const allocator = std.testing.allocator;
    var subs = TrackSubscriptions.init(allocator);
    defer subs.deinit();

    _ = try subs.subscribeRange(1, 0, 2, false);
    subs.removeClient(1);

    // Should have 3 tracks in grace period (indices 0, 1, 2)
    try std.testing.expectEqual(@as(usize, 3), subs.grace_until.count());
}

test "getSubscribedIndices with range" {
    const allocator = std.testing.allocator;
    var subs = TrackSubscriptions.init(allocator);
    defer subs.deinit();

    const reaper = @import("reaper.zig");
    var mock = reaper.mock();
    mock.track_count = 10;

    var cache = GuidCache.init(allocator);
    defer cache.deinit();
    try cache.rebuild(&mock);

    _ = try subs.subscribeRange(1, 0, 4, false);

    var buf: [32]c_int = undefined;
    const indices = subs.getSubscribedIndices(&cache, &mock, &buf);

    try std.testing.expectEqual(@as(usize, 5), indices.len);
    // Should be sorted
    try std.testing.expectEqual(@as(c_int, 0), indices[0]);
    try std.testing.expectEqual(@as(c_int, 4), indices[4]);
}

test "getSubscribedIndices with GUIDs" {
    const allocator = std.testing.allocator;
    var subs = TrackSubscriptions.init(allocator);
    defer subs.deinit();

    const reaper = @import("reaper.zig");
    var mock = reaper.mock();
    mock.track_count = 5;

    var cache = GuidCache.init(allocator);
    defer cache.deinit();
    try cache.rebuild(&mock);

    // Subscribe to master and track 3 by GUID
    const guids = [_][]const u8{ "master", "{00000000-0000-0000-0000-000000000003}" };
    _ = try subs.subscribeGuids(1, &guids, false);

    var buf: [32]c_int = undefined;
    const indices = subs.getSubscribedIndices(&cache, &mock, &buf);

    try std.testing.expectEqual(@as(usize, 2), indices.len);
    // Sorted: master (0) then track 3
    try std.testing.expectEqual(@as(c_int, 0), indices[0]);
    try std.testing.expectEqual(@as(c_int, 3), indices[1]);
}

test "multiple clients combined" {
    const allocator = std.testing.allocator;
    var subs = TrackSubscriptions.init(allocator);
    defer subs.deinit();

    const reaper = @import("reaper.zig");
    var mock = reaper.mock();
    mock.track_count = 10;

    var cache = GuidCache.init(allocator);
    defer cache.deinit();
    try cache.rebuild(&mock);

    // Client 1: range 0-2
    _ = try subs.subscribeRange(1, 0, 2, false);
    // Client 2: range 2-4 (overlaps)
    _ = try subs.subscribeRange(2, 2, 4, false);

    var buf: [32]c_int = undefined;
    const indices = subs.getSubscribedIndices(&cache, &mock, &buf);

    // Should have 0,1,2,3,4 (deduped)
    try std.testing.expectEqual(@as(usize, 5), indices.len);
}

test "includeMaster adds master to range subscription" {
    const allocator = std.testing.allocator;
    var subs = TrackSubscriptions.init(allocator);
    defer subs.deinit();

    const reaper = @import("reaper.zig");
    var mock = reaper.mock();
    mock.track_count = 10;

    var cache = GuidCache.init(allocator);
    defer cache.deinit();
    try cache.rebuild(&mock);

    // Subscribe to range 5-7 with includeMaster
    const count = try subs.subscribeRange(1, 5, 7, true);
    try std.testing.expectEqual(@as(usize, 4), count); // 3 tracks + master

    var buf: [32]c_int = undefined;
    const indices = subs.getSubscribedIndices(&cache, &mock, &buf);

    try std.testing.expectEqual(@as(usize, 4), indices.len);
    // Should have master (0) plus 5,6,7
    try std.testing.expectEqual(@as(c_int, 0), indices[0]);
    try std.testing.expectEqual(@as(c_int, 5), indices[1]);
}

test "includeMaster with GUID subscription" {
    const allocator = std.testing.allocator;
    var subs = TrackSubscriptions.init(allocator);
    defer subs.deinit();

    const reaper = @import("reaper.zig");
    var mock = reaper.mock();
    mock.track_count = 5;

    var cache = GuidCache.init(allocator);
    defer cache.deinit();
    try cache.rebuild(&mock);

    // Subscribe to track 3 only, but with includeMaster
    const guids = [_][]const u8{"{00000000-0000-0000-0000-000000000003}"};
    const count = try subs.subscribeGuids(1, &guids, true);
    try std.testing.expectEqual(@as(usize, 2), count); // 1 GUID + master

    var buf: [32]c_int = undefined;
    const indices = subs.getSubscribedIndices(&cache, &mock, &buf);

    try std.testing.expectEqual(@as(usize, 2), indices.len);
    // Sorted: master (0), track 3
    try std.testing.expectEqual(@as(c_int, 0), indices[0]);
    try std.testing.expectEqual(@as(c_int, 3), indices[1]);
}

test "switching subscription modes" {
    const allocator = std.testing.allocator;
    var subs = TrackSubscriptions.init(allocator);
    defer subs.deinit();

    // Start with range
    _ = try subs.subscribeRange(1, 0, 9, false);
    const slot = subs.client_id_to_slot.get(1).?;
    try std.testing.expectEqual(SubscriptionMode.range, subs.clients[slot].mode);

    // Switch to GUIDs
    const guids = [_][]const u8{"master"};
    _ = try subs.subscribeGuids(1, &guids, false);
    try std.testing.expectEqual(SubscriptionMode.guids, subs.clients[slot].mode);

    // Switch back to range
    _ = try subs.subscribeRange(1, 5, 10, false);
    try std.testing.expectEqual(SubscriptionMode.range, subs.clients[slot].mode);
}

test "slot recycling after client disconnect" {
    const allocator = std.testing.allocator;
    var subs = TrackSubscriptions.init(allocator);
    defer subs.deinit();

    // Fill all 16 slots
    for (0..MAX_CLIENTS) |i| {
        _ = try subs.subscribeRange(i, 0, 5, false);
    }
    try std.testing.expectEqual(@as(usize, MAX_CLIENTS), subs.clientCount());

    // New client should fail (slots exhausted)
    const result = subs.subscribeRange(999, 0, 5, false);
    try std.testing.expectError(error.TooManyClients, result);

    // Disconnect client 5
    subs.removeClient(5);
    try std.testing.expectEqual(@as(usize, MAX_CLIENTS - 1), subs.clientCount());

    // New client should succeed (slot recycled)
    _ = try subs.subscribeRange(100, 0, 5, false);
    try std.testing.expectEqual(@as(usize, MAX_CLIENTS), subs.clientCount());

    // Another new client should fail again
    const result2 = subs.subscribeRange(101, 0, 5, false);
    try std.testing.expectError(error.TooManyClients, result2);

    // Disconnect multiple clients
    subs.removeClient(0);
    subs.removeClient(1);
    subs.removeClient(2);

    // Should be able to add 3 new clients
    _ = try subs.subscribeRange(200, 0, 5, false);
    _ = try subs.subscribeRange(201, 0, 5, false);
    _ = try subs.subscribeRange(202, 0, 5, false);
    try std.testing.expectEqual(@as(usize, MAX_CLIENTS), subs.clientCount());
}
