/// GUID Cache - O(1) GUID → track pointer lookup for write commands.
///
/// Rebuilt atomically when skeleton changes (detected in LOW tier at 1Hz).
/// Used by GUID-based write commands (e.g., track/setVolume with trackGuid parameter).
///
/// Design:
/// - StringHashMap with owned GUID keys (duped into allocator)
/// - Master track uses "master" literal, not REAPER's unreliable GUID
/// - Generation counter for staleness detection if needed
///
/// Usage:
///   var cache = GuidCache.init(allocator);
///   defer cache.deinit();
///   try cache.rebuild(&backend);
///   const track = cache.resolve("{XXXXXXXX-...}");
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const GUID_LEN: usize = 38; // {XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}

/// GUID → track pointer cache for O(1) write command resolution.
pub const GuidCache = struct {
    allocator: Allocator,

    /// StringHashMap with owned keys - each GUID string is duped into this allocator.
    /// Value is the opaque track pointer from REAPER.
    map: std.StringHashMap(*anyopaque),

    /// Incremented on each rebuild - allows staleness detection if needed.
    generation: u32,

    /// Master track pointer (cached separately since its GUID is unreliable).
    master_track: ?*anyopaque,

    pub fn init(allocator: Allocator) GuidCache {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap(*anyopaque).init(allocator),
            .generation = 0,
            .master_track = null,
        };
    }

    pub fn deinit(self: *GuidCache) void {
        // Free all owned GUID strings
        var key_iter = self.map.keyIterator();
        while (key_iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.map.deinit();
    }

    /// Rebuild entire cache from current REAPER state.
    /// Called when skeleton changes (LOW tier detects track add/delete/reorder).
    /// Uses anytype for backend abstraction (RealBackend or MockBackend).
    pub fn rebuild(self: *GuidCache, api: anytype) !void {
        // Clear existing entries (free owned strings)
        var key_iter = self.map.keyIterator();
        while (key_iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.map.clearRetainingCapacity();

        // Cache master track
        self.master_track = api.masterTrack();

        // Build cache from all user tracks (indices 1+)
        const track_count = api.trackCount();
        var idx: c_int = 1; // Start at 1, master handled via "master" literal
        while (idx <= track_count) : (idx += 1) {
            const track = api.getTrackByUnifiedIdx(idx) orelse continue;

            var guid_buf: [64]u8 = undefined;
            const guid = api.formatTrackGuid(track, &guid_buf);

            if (guid.len > 0) {
                // Dupe GUID string for owned storage
                const owned_guid = try self.allocator.dupe(u8, guid);
                try self.map.put(owned_guid, track);
            }
        }

        self.generation +%= 1;
    }

    /// Resolve GUID to track pointer.
    /// Returns null if GUID not found (track was deleted).
    /// "master" resolves to master track via special case.
    pub fn resolve(self: *const GuidCache, guid: []const u8) ?*anyopaque {
        // Special case: "master" → master track
        if (std.mem.eql(u8, guid, "master")) {
            return self.master_track;
        }
        return self.map.get(guid);
    }

    /// Get current generation for staleness checks.
    pub fn getGeneration(self: *const GuidCache) u32 {
        return self.generation;
    }

    /// Get count of cached tracks (excluding master).
    pub fn count(self: *const GuidCache) usize {
        return self.map.count();
    }

    /// Check if cache has any entries.
    pub fn hasEntries(self: *const GuidCache) bool {
        return self.master_track != null or self.map.count() > 0;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "GuidCache init and deinit" {
    var cache = GuidCache.init(std.testing.allocator);
    defer cache.deinit();

    try std.testing.expectEqual(@as(usize, 0), cache.count());
    try std.testing.expectEqual(@as(u32, 0), cache.generation);
    try std.testing.expect(cache.master_track == null);
}

test "GuidCache resolve returns null for unknown GUID" {
    var cache = GuidCache.init(std.testing.allocator);
    defer cache.deinit();

    try std.testing.expect(cache.resolve("{unknown-guid}") == null);
}

test "GuidCache resolve master special case" {
    var cache = GuidCache.init(std.testing.allocator);
    defer cache.deinit();

    // Manually set master track for test
    var dummy: u8 = 0;
    cache.master_track = &dummy;

    try std.testing.expect(cache.resolve("master") == &dummy);
}

test "GuidCache rebuild with mock backend" {
    const reaper = @import("reaper.zig");
    var mock = reaper.mock();
    mock.track_count = 2;

    var cache = GuidCache.init(std.testing.allocator);
    defer cache.deinit();

    try cache.rebuild(&mock);

    // Should have cached master and 2 user tracks
    try std.testing.expect(cache.master_track != null);
    try std.testing.expectEqual(@as(usize, 2), cache.count());
    try std.testing.expectEqual(@as(u32, 1), cache.generation);

    // Resolve by GUID (mock generates deterministic GUIDs)
    const track1 = cache.resolve("{00000000-0000-0000-0000-000000000001}");
    try std.testing.expect(track1 != null);

    const track2 = cache.resolve("{00000000-0000-0000-0000-000000000002}");
    try std.testing.expect(track2 != null);

    // Unknown GUID returns null
    try std.testing.expect(cache.resolve("{unknown}") == null);
}

test "GuidCache rebuild clears stale entries" {
    const reaper = @import("reaper.zig");
    var mock = reaper.mock();
    mock.track_count = 3;

    var cache = GuidCache.init(std.testing.allocator);
    defer cache.deinit();

    try cache.rebuild(&mock);
    try std.testing.expectEqual(@as(usize, 3), cache.count());
    try std.testing.expectEqual(@as(u32, 1), cache.generation);

    // Simulate track deletion
    mock.track_count = 1;
    try cache.rebuild(&mock);

    try std.testing.expectEqual(@as(usize, 1), cache.count());
    try std.testing.expectEqual(@as(u32, 2), cache.generation);

    // Old GUIDs should be gone
    try std.testing.expect(cache.resolve("{00000000-0000-0000-0000-000000000002}") == null);
    try std.testing.expect(cache.resolve("{00000000-0000-0000-0000-000000000003}") == null);
}
