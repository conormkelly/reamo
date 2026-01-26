/// Item GUID Cache - O(1) GUID → item indices lookup for write commands.
///
/// Unlike track GuidCache (rebuilt on skeleton change), this is rebuilt every
/// poll cycle (5Hz) after items state polling. Iterating the polled items to
/// build the cache adds minimal overhead (items already in memory).
///
/// Design:
/// - StringHashMap with owned GUID keys (duped into allocator)
/// - Stores track and item indices (not pointers - those are fetched at use time)
/// - Cleared and rebuilt each poll cycle
///
/// Usage:
///   var cache = ItemGuidCache.init(allocator);
///   defer cache.deinit();
///   // After items poll:
///   cache.rebuildFromItems(polled_items);
///   // In command handlers:
///   const loc = cache.resolve("{XXXXXXXX-...}") orelse return error;
///   const track = api.getTrackByUnifiedIdx(loc.track_idx);
///   const item = api.getItemByIdx(track, loc.item_idx);
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const GUID_LEN: usize = 38; // {XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}

/// Location info for an item - indices to look up pointers at use time.
/// We store indices rather than pointers because:
/// 1. Items polling doesn't preserve pointers in the returned Item structs
/// 2. Indices are validated when fetching pointers (returns null if deleted)
pub const ItemLocation = struct {
    track_idx: c_int, // unified index (0 = master, 1+ = user tracks)
    item_idx: c_int, // index within track
};

/// GUID → item location cache for O(1) write command resolution.
pub const ItemGuidCache = struct {
    allocator: Allocator,

    /// StringHashMap with owned keys - each GUID string is duped into this allocator.
    /// Value is the ItemLocation struct with pointers and indices.
    map: std.StringHashMap(ItemLocation),

    /// Incremented on each rebuild - allows staleness detection if needed.
    generation: u32,

    pub fn init(allocator: Allocator) ItemGuidCache {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap(ItemLocation).init(allocator),
            .generation = 0,
        };
    }

    pub fn deinit(self: *ItemGuidCache) void {
        // Free all owned GUID strings
        var key_iter = self.map.keyIterator();
        while (key_iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.map.deinit();
    }

    /// Clear all entries. Called at start of each poll cycle.
    /// Frees owned GUID strings but retains map capacity.
    pub fn clear(self: *ItemGuidCache) void {
        var key_iter = self.map.keyIterator();
        while (key_iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.map.clearRetainingCapacity();
        self.generation +%= 1;
    }

    /// Add an item to the cache. Called during items poll for each item.
    /// Dupes the GUID string for owned storage.
    pub fn put(self: *ItemGuidCache, guid: []const u8, location: ItemLocation) !void {
        // Skip empty or invalid GUIDs
        if (guid.len == 0) return;

        // Dupe GUID string for owned storage
        const owned_guid = try self.allocator.dupe(u8, guid);
        errdefer self.allocator.free(owned_guid);

        // If key already exists, free old key first (shouldn't happen in normal operation)
        if (self.map.fetchRemove(owned_guid)) |old| {
            self.allocator.free(old.key);
        }

        try self.map.put(owned_guid, location);
    }

    /// Resolve GUID to item location.
    /// Returns null if GUID not found (item was deleted or cache stale).
    pub fn resolve(self: *const ItemGuidCache, guid: []const u8) ?ItemLocation {
        return self.map.get(guid);
    }

    /// Get current generation for staleness checks.
    pub fn getGeneration(self: *const ItemGuidCache) u32 {
        return self.generation;
    }

    /// Get count of cached items.
    pub fn count(self: *const ItemGuidCache) usize {
        return self.map.count();
    }

    /// Check if cache has any entries.
    pub fn hasEntries(self: *const ItemGuidCache) bool {
        return self.map.count() > 0;
    }

    /// Rebuild cache from polled items slice.
    /// Called after items.State.poll() returns.
    /// Items have internal track_idx (0-based), we convert to unified (1-based) for consistency.
    pub fn rebuildFromItems(self: *ItemGuidCache, items_mod: anytype, items: anytype) !void {
        // items_mod is the items module (for Item type), items is the slice
        _ = items_mod;

        self.clear();

        for (items) |item| {
            const guid = item.guid[0..item.guid_len];
            if (guid.len == 0) continue;

            // Convert internal track_idx (0-based) to unified (1-based, 0 = master)
            // This matches what JSON output does and what commands expect
            const unified_track_idx = item.track_idx + 1;

            try self.put(guid, .{
                .track_idx = unified_track_idx,
                .item_idx = item.item_idx,
            });
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

test "ItemGuidCache init and deinit" {
    var cache = ItemGuidCache.init(std.testing.allocator);
    defer cache.deinit();

    try std.testing.expectEqual(@as(usize, 0), cache.count());
    try std.testing.expectEqual(@as(u32, 0), cache.generation);
}

test "ItemGuidCache put and resolve" {
    var cache = ItemGuidCache.init(std.testing.allocator);
    defer cache.deinit();

    const guid = "{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}";
    try cache.put(guid, .{
        .track_idx = 1,
        .item_idx = 0,
    });

    try std.testing.expectEqual(@as(usize, 1), cache.count());

    const loc = cache.resolve(guid);
    try std.testing.expect(loc != null);
    try std.testing.expectEqual(@as(c_int, 1), loc.?.track_idx);
    try std.testing.expectEqual(@as(c_int, 0), loc.?.item_idx);
}

test "ItemGuidCache resolve returns null for unknown GUID" {
    var cache = ItemGuidCache.init(std.testing.allocator);
    defer cache.deinit();

    try std.testing.expect(cache.resolve("{unknown-guid}") == null);
}

test "ItemGuidCache clear frees keys and increments generation" {
    var cache = ItemGuidCache.init(std.testing.allocator);
    defer cache.deinit();

    try cache.put("{guid-1}", .{
        .track_idx = 1,
        .item_idx = 0,
    });
    try cache.put("{guid-2}", .{
        .track_idx = 1,
        .item_idx = 1,
    });

    try std.testing.expectEqual(@as(usize, 2), cache.count());
    try std.testing.expectEqual(@as(u32, 0), cache.generation);

    cache.clear();

    try std.testing.expectEqual(@as(usize, 0), cache.count());
    try std.testing.expectEqual(@as(u32, 1), cache.generation);

    // Old GUIDs should be gone
    try std.testing.expect(cache.resolve("{guid-1}") == null);
    try std.testing.expect(cache.resolve("{guid-2}") == null);
}

test "ItemGuidCache handles empty GUID gracefully" {
    var cache = ItemGuidCache.init(std.testing.allocator);
    defer cache.deinit();

    // Should not error, just skip
    try cache.put("", .{
        .track_idx = 1,
        .item_idx = 0,
    });

    try std.testing.expectEqual(@as(usize, 0), cache.count());
}

test "ItemGuidCache multiple items" {
    var cache = ItemGuidCache.init(std.testing.allocator);
    defer cache.deinit();

    // Add 10 items
    for (0..10) |i| {
        var guid_buf: [40]u8 = undefined;
        const guid = std.fmt.bufPrint(&guid_buf, "{{item-guid-{d:0>2}}}", .{i}) catch unreachable;
        try cache.put(guid, .{
            .track_idx = @intCast(i / 3 + 1), // unified index (1-based)
            .item_idx = @intCast(i % 3),
        });
    }

    try std.testing.expectEqual(@as(usize, 10), cache.count());

    // Verify a few
    const loc5 = cache.resolve("{item-guid-05}");
    try std.testing.expect(loc5 != null);
    try std.testing.expectEqual(@as(c_int, 2), loc5.?.track_idx); // 5 / 3 + 1 = 2 (unified)
    try std.testing.expectEqual(@as(c_int, 2), loc5.?.item_idx); // 5 % 3 = 2
}

test "ItemGuidCache rebuildFromItems" {
    const items_mod = @import("items.zig");

    var cache = ItemGuidCache.init(std.testing.allocator);
    defer cache.deinit();

    // Create some test items
    var test_items: [2]items_mod.Item = undefined;

    // Item 1
    const guid1 = "{11111111-2222-3333-4444-555555555555}";
    test_items[0] = .{
        .track_idx = 0, // internal 0-based
        .item_idx = 0,
        .position = 0.0,
        .length = 1.0,
    };
    @memcpy(test_items[0].guid[0..guid1.len], guid1);
    test_items[0].guid_len = guid1.len;

    // Item 2
    const guid2 = "{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}";
    test_items[1] = .{
        .track_idx = 1, // internal 0-based
        .item_idx = 2,
        .position = 5.0,
        .length = 2.0,
    };
    @memcpy(test_items[1].guid[0..guid2.len], guid2);
    test_items[1].guid_len = guid2.len;

    // Rebuild cache from items
    try cache.rebuildFromItems(items_mod, &test_items);

    try std.testing.expectEqual(@as(usize, 2), cache.count());

    // Verify item 1 - internal track_idx 0 becomes unified 1
    const loc1 = cache.resolve(guid1);
    try std.testing.expect(loc1 != null);
    try std.testing.expectEqual(@as(c_int, 1), loc1.?.track_idx);
    try std.testing.expectEqual(@as(c_int, 0), loc1.?.item_idx);

    // Verify item 2 - internal track_idx 1 becomes unified 2
    const loc2 = cache.resolve(guid2);
    try std.testing.expect(loc2 != null);
    try std.testing.expectEqual(@as(c_int, 2), loc2.?.track_idx);
    try std.testing.expectEqual(@as(c_int, 2), loc2.?.item_idx);
}
