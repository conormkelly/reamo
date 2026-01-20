/// Tile-Based LOD Peaks Cache
///
/// Provides fixed time-window tiles at each LOD level for efficient caching
/// across zoom/pan operations. Tiles enable cache reuse when panning and
/// efficient prefetching.
///
/// LOD Levels (matching REAPER's mipmap tiers):
///   - LOD 0: 64s tiles, 1 peak/sec (~64 peaks/tile) - Overview
///   - LOD 1: 8s tiles, 10 peaks/sec (~80 peaks/tile) - Normal editing
///   - LOD 2: 0.5s tiles, 400 peaks/sec (~200 peaks/tile) - Precision editing
///
/// Cache Key Format:
///   TileCacheKey { take_guid, epoch, lod_level, tile_index }
///
/// Usage:
///   var cache = TileCache.init(allocator);
///   defer cache.deinit();
///
///   const key = TileCacheKey.create(take_guid, epoch, lod, tile_idx);
///   if (cache.get(key)) |tile| { ... }
///   cache.put(key, tile_data);
const std = @import("std");
const logging = @import("logging.zig");
const ffi = @import("ffi.zig");

const Allocator = std.mem.Allocator;

// =============================================================================
// Tile Configuration
// =============================================================================

/// Configuration for each LOD level
pub const TileConfig = struct {
    duration: f64, // Tile duration in seconds
    peakrate: f64, // Peaks per second
    peaks_per_tile: usize, // Expected peaks per tile
};

/// LOD level configurations (indices 0, 1, 2)
pub const TILE_CONFIGS = [3]TileConfig{
    .{ .duration = 64.0, .peakrate = 1.0, .peaks_per_tile = 64 }, // LOD 0: Coarse
    .{ .duration = 8.0, .peakrate = 10.0, .peaks_per_tile = 80 }, // LOD 1: Medium
    .{ .duration = 0.5, .peakrate = 400.0, .peaks_per_tile = 200 }, // LOD 2: Fine
};

/// Maximum peaks per tile (matches LOD 2)
pub const MAX_PEAKS_PER_TILE = 200;

/// Maximum cache entries before LRU eviction
pub const MAX_CACHE_ENTRIES = 500;

/// GUID length for keys
pub const GUID_LEN = 40;

// =============================================================================
// Tile Cache Key
// =============================================================================

/// Cache key for a single tile.
/// Uniquely identifies a tile by take, version (epoch), LOD level, and position.
pub const TileCacheKey = struct {
    /// Take GUID (identifies the audio source)
    take_guid: [GUID_LEN]u8,
    take_guid_len: u8,

    /// Epoch: version counter from hashing PCM_source properties.
    /// Increments when source audio is edited, invalidating cached tiles.
    epoch: u32,

    /// LOD level (0-2)
    lod_level: u2,

    /// Tile index: floor(startTime / tileDuration)
    tile_index: u32,

    /// Create a cache key
    pub fn create(
        take_guid: []const u8,
        epoch: u32,
        lod_level: u2,
        tile_index: u32,
    ) TileCacheKey {
        var key = TileCacheKey{
            .take_guid = undefined,
            .take_guid_len = 0,
            .epoch = epoch,
            .lod_level = lod_level,
            .tile_index = tile_index,
        };

        const len: u8 = @intCast(@min(take_guid.len, GUID_LEN));
        @memcpy(key.take_guid[0..len], take_guid[0..len]);
        key.take_guid_len = len;

        return key;
    }

    /// Hash for HashMap
    pub fn hash(self: TileCacheKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(self.take_guid[0..self.take_guid_len]);
        hasher.update(std.mem.asBytes(&self.epoch));
        hasher.update(std.mem.asBytes(&self.lod_level));
        hasher.update(std.mem.asBytes(&self.tile_index));
        return hasher.final();
    }

    /// Equality check for HashMap
    pub fn eql(a: TileCacheKey, b: TileCacheKey) bool {
        if (a.take_guid_len != b.take_guid_len) return false;
        if (a.epoch != b.epoch) return false;
        if (a.lod_level != b.lod_level) return false;
        if (a.tile_index != b.tile_index) return false;
        return std.mem.eql(u8, a.take_guid[0..a.take_guid_len], b.take_guid[0..b.take_guid_len]);
    }

    /// Get the start time of this tile in seconds (relative to item start)
    pub fn startTime(self: TileCacheKey) f64 {
        const config = TILE_CONFIGS[self.lod_level];
        return @as(f64, @floatFromInt(self.tile_index)) * config.duration;
    }

    /// Get the end time of this tile in seconds (relative to item start)
    pub fn endTime(self: TileCacheKey) f64 {
        const config = TILE_CONFIGS[self.lod_level];
        return @as(f64, @floatFromInt(self.tile_index + 1)) * config.duration;
    }
};

// =============================================================================
// Cached Tile Data
// =============================================================================

/// Cached peak data for a single tile.
pub const CachedTile = struct {
    /// Peak min values (interleaved for stereo: [L0, R0, L1, R1, ...])
    peak_min: [MAX_PEAKS_PER_TILE * 2]f64,

    /// Peak max values (interleaved for stereo: [L0, R0, L1, R1, ...])
    peak_max: [MAX_PEAKS_PER_TILE * 2]f64,

    /// Number of peaks stored
    num_peaks: u16,

    /// 1 for mono, 2 for stereo
    channels: u8,

    /// Last access time for LRU eviction (frame counter)
    last_used: u64,

    /// Create an empty tile
    pub fn empty() CachedTile {
        return .{
            .peak_min = [_]f64{0} ** (MAX_PEAKS_PER_TILE * 2),
            .peak_max = [_]f64{0} ** (MAX_PEAKS_PER_TILE * 2),
            .num_peaks = 0,
            .channels = 1,
            .last_used = 0,
        };
    }
};

// =============================================================================
// HashMap Context
// =============================================================================

/// HashMap context for TileCacheKey
const KeyContext = struct {
    pub fn hash(_: KeyContext, key: TileCacheKey) u64 {
        return key.hash();
    }

    pub fn eql(_: KeyContext, a: TileCacheKey, b: TileCacheKey) bool {
        return a.eql(b);
    }
};

// =============================================================================
// Tile Cache
// =============================================================================

/// LRU cache for tile peak data.
pub const TileCache = struct {
    allocator: Allocator,

    /// Cache storage
    map: std.HashMap(TileCacheKey, CachedTile, KeyContext, std.hash_map.default_max_load_percentage),

    /// Frame counter for LRU tracking
    frame_counter: u64,

    /// Epoch tracker for cache invalidation
    epochs: EpochTracker,

    /// Per-track item hash for structural change detection
    /// Key: track GUID (owned string), Value: hash of item properties
    track_hashes: std.StringHashMap(u64),

    pub fn init(allocator: Allocator) TileCache {
        return .{
            .allocator = allocator,
            .map = std.HashMap(TileCacheKey, CachedTile, KeyContext, std.hash_map.default_max_load_percentage).init(allocator),
            .frame_counter = 0,
            .epochs = EpochTracker.init(allocator),
            .track_hashes = std.StringHashMap(u64).init(allocator),
        };
    }

    pub fn deinit(self: *TileCache) void {
        // Free owned track GUID keys
        var key_iter = self.track_hashes.keyIterator();
        while (key_iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.track_hashes.deinit();
        self.epochs.deinit();
        self.map.deinit();
    }

    /// Get cached tile if available. Updates last_used on hit.
    pub fn get(self: *TileCache, key: TileCacheKey) ?*CachedTile {
        if (self.map.getPtr(key)) |entry| {
            entry.last_used = self.frame_counter;
            return entry;
        }
        return null;
    }

    /// Store tile in cache, evicting oldest if full.
    pub fn put(
        self: *TileCache,
        key: TileCacheKey,
        peak_min: []const f64,
        peak_max: []const f64,
        num_peaks: usize,
        channels: usize,
    ) void {
        // Evict if at capacity
        if (self.map.count() >= MAX_CACHE_ENTRIES) {
            self.evictOldest();
        }

        var entry = CachedTile{
            .peak_min = undefined,
            .peak_max = undefined,
            .num_peaks = @intCast(@min(num_peaks, MAX_PEAKS_PER_TILE)),
            .channels = @intCast(@min(channels, 2)),
            .last_used = self.frame_counter,
        };

        // Initialize arrays to zero first
        entry.peak_min = [_]f64{0} ** (MAX_PEAKS_PER_TILE * 2);
        entry.peak_max = [_]f64{0} ** (MAX_PEAKS_PER_TILE * 2);

        // Copy peak data
        const copy_len = @min(num_peaks * channels, MAX_PEAKS_PER_TILE * 2);
        if (copy_len > 0) {
            @memcpy(entry.peak_min[0..copy_len], peak_min[0..copy_len]);
            @memcpy(entry.peak_max[0..copy_len], peak_max[0..copy_len]);
        }

        self.map.put(key, entry) catch {
            logging.warn("peaks_tile: failed to store cache entry", .{});
        };
    }

    /// Evict the least recently used entry.
    fn evictOldest(self: *TileCache) void {
        var oldest_key: ?TileCacheKey = null;
        var oldest_time: u64 = std.math.maxInt(u64);

        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.last_used < oldest_time) {
                oldest_time = entry.value_ptr.last_used;
                oldest_key = entry.key_ptr.*;
            }
        }

        if (oldest_key) |key| {
            _ = self.map.remove(key);
        }
    }

    /// Increment frame counter (call once per broadcast tick).
    pub fn tick(self: *TileCache) void {
        self.frame_counter +%= 1;
    }

    /// Get current epoch for a take, computing if needed.
    pub fn getEpoch(self: *TileCache, take_guid: []const u8, api: anytype, take: *anyopaque) u32 {
        return self.epochs.getOrCompute(take_guid, api, take);
    }

    /// Invalidate all tiles for a take (call when source audio changes).
    /// Also invalidates the cached epoch so it will be recomputed.
    pub fn invalidateTake(self: *TileCache, take_guid: []const u8) void {
        self.epochs.invalidate(take_guid);
        self.removeTilesForTake(take_guid);
    }

    /// Remove all cached tiles for a take (without invalidating epoch).
    /// Use this when epoch has already been updated via checkAndUpdate().
    fn removeTilesForTake(self: *TileCache, take_guid: []const u8) void {
        var keys_to_remove: [MAX_CACHE_ENTRIES]TileCacheKey = undefined;
        var remove_count: usize = 0;

        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.eql(u8, key.take_guid[0..key.take_guid_len], take_guid)) {
                if (remove_count < MAX_CACHE_ENTRIES) {
                    keys_to_remove[remove_count] = key;
                    remove_count += 1;
                }
            }
        }

        for (keys_to_remove[0..remove_count]) |key| {
            _ = self.map.remove(key);
        }
    }

    /// Get cache statistics for debugging.
    pub fn stats(self: *const TileCache) struct { entries: usize, takes: usize } {
        return .{
            .entries = self.map.count(),
            .takes = self.epochs.count(),
        };
    }

    /// Check if track items have changed since last check.
    /// Checks both:
    /// 1. Item property hash (position, length, playrate, etc.) - detects move/trim/stretch
    /// 2. Source epochs for each take - detects audio edits (render, normalize, etc.)
    /// Returns true if anything changed (or first time checking this track).
    pub fn trackChanged(
        self: *TileCache,
        track_guid: []const u8,
        api: anytype,
        track: *anyopaque,
    ) bool {
        var changed = false;

        // Check 1: Item property hash (structural changes)
        const current_hash = computeTrackItemsHash(api, track);
        if (self.track_hashes.get(track_guid)) |prev_hash| {
            if (prev_hash != current_hash) {
                changed = true;
            }
        } else {
            // First time seeing this track
            changed = true;
        }

        // Store/update hash
        if (!self.track_hashes.contains(track_guid)) {
            const owned_guid = self.allocator.dupe(u8, track_guid) catch {
                logging.warn("peaks_tile: failed to store track hash key", .{});
                return true; // Assume changed on error
            };
            self.track_hashes.put(owned_guid, current_hash) catch {
                self.allocator.free(owned_guid);
                return true;
            };
        } else {
            self.track_hashes.put(track_guid, current_hash) catch {};
        }

        // Check 2: Source epochs for each take (audio content changes)
        // This detects when source audio is edited (render, normalize, etc.)
        const item_count = api.trackItemCount(track);
        var i: c_int = 0;
        while (i < item_count) : (i += 1) {
            const item = api.getItemByIdx(track, i) orelse continue;
            const take = api.getItemActiveTake(item) orelse continue;

            // Skip MIDI
            if (api.isTakeMIDI(take)) continue;

            var take_guid_buf: [64]u8 = undefined;
            const take_guid = api.getTakeGUID(take, &take_guid_buf);

            // Check if epoch changed (source audio was edited)
            if (self.epochs.checkAndUpdate(take_guid, api, take)) |new_epoch| {
                // Epoch changed - remove cached tiles for this take
                // Note: checkAndUpdate already stored the new epoch, so just remove tiles
                logging.info("peaks_tile: epoch changed for take {s} (new epoch: {}), removing tiles", .{ take_guid, new_epoch });
                self.removeTilesForTake(take_guid);
                changed = true;
            }
        }

        return changed;
    }

    /// Clear hash for a track (call when track is deleted or subscription removed).
    pub fn clearTrackHash(self: *TileCache, track_guid: []const u8) void {
        if (self.track_hashes.fetchRemove(track_guid)) |kv| {
            self.allocator.free(kv.key);
        }
    }
};

// =============================================================================
// Epoch Tracker
// =============================================================================

/// Tracks PCM_source versions for cache invalidation.
/// Epoch is computed by hashing source pointer and properties.
/// When source audio is edited, the epoch changes, invalidating cached tiles.
pub const EpochTracker = struct {
    allocator: Allocator,

    /// Map from take GUID -> current epoch
    epochs: std.StringHashMap(u32),

    pub fn init(allocator: Allocator) EpochTracker {
        return .{
            .allocator = allocator,
            .epochs = std.StringHashMap(u32).init(allocator),
        };
    }

    pub fn deinit(self: *EpochTracker) void {
        // Free owned keys
        var key_iter = self.epochs.keyIterator();
        while (key_iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.epochs.deinit();
    }

    /// Get epoch for a take, computing from source properties if not cached.
    pub fn getOrCompute(self: *EpochTracker, take_guid: []const u8, api: anytype, take: *anyopaque) u32 {
        // Check if we have a cached epoch
        if (self.epochs.get(take_guid)) |epoch| {
            return epoch;
        }

        // Compute epoch from source properties
        const epoch = computeEpoch(api, take);

        // Store it (need to dupe key)
        const owned_guid = self.allocator.dupe(u8, take_guid) catch {
            logging.warn("peaks_tile: failed to store epoch key", .{});
            return epoch;
        };
        self.epochs.put(owned_guid, epoch) catch {
            self.allocator.free(owned_guid);
            logging.warn("peaks_tile: failed to store epoch", .{});
        };

        return epoch;
    }

    /// Check if epoch has changed (source was edited).
    /// Returns new epoch if changed, null if unchanged.
    pub fn checkAndUpdate(self: *EpochTracker, take_guid: []const u8, api: anytype, take: *anyopaque) ?u32 {
        const new_epoch = computeEpoch(api, take);

        if (self.epochs.get(take_guid)) |old_epoch| {
            if (old_epoch == new_epoch) {
                return null; // Unchanged
            }
            // Update epoch
            self.epochs.put(take_guid, new_epoch) catch {};
            return new_epoch;
        }

        // First time seeing this take
        const owned_guid = self.allocator.dupe(u8, take_guid) catch {
            return new_epoch;
        };
        self.epochs.put(owned_guid, new_epoch) catch {
            self.allocator.free(owned_guid);
        };

        return new_epoch;
    }

    /// Invalidate epoch for a take (force recomputation on next access).
    pub fn invalidate(self: *EpochTracker, take_guid: []const u8) void {
        if (self.epochs.fetchRemove(take_guid)) |kv| {
            self.allocator.free(kv.key);
        }
    }

    /// Get count of tracked takes.
    pub fn count(self: *const EpochTracker) usize {
        return self.epochs.count();
    }
};

/// Compute epoch from take's PCM_source properties.
/// Hash: source_ptr ^ num_channels
/// This changes when the source is replaced or re-rendered.
fn computeEpoch(api: anytype, take: *anyopaque) u32 {
    const source = api.getTakeSource(take) orelse {
        return 0; // No source
    };

    var hasher = std.hash.Wyhash.init(0);

    // Hash source pointer (changes if source replaced)
    hasher.update(std.mem.asBytes(&@intFromPtr(source)));

    // Hash channel count (changes if source re-rendered with different settings)
    const channels = api.getMediaSourceChannels(source);
    hasher.update(std.mem.asBytes(&channels));

    // Truncate to u32
    return @truncate(hasher.final());
}

/// Compute hash of all item properties that affect peaks on a track.
fn computeTrackItemsHash(api: anytype, track: *anyopaque) u64 {
    var hasher = std.hash.Wyhash.init(0);

    const item_count = api.trackItemCount(track);
    hasher.update(std.mem.asBytes(&item_count));

    var i: c_int = 0;
    while (i < item_count) : (i += 1) {
        const item = api.getItemByIdx(track, i) orelse continue;

        // Get active take
        const take = api.getItemActiveTake(item) orelse continue;

        // Skip MIDI (doesn't affect peaks)
        if (api.isTakeMIDI(take)) continue;

        // Hash take GUID
        var take_guid_buf: [64]u8 = undefined;
        const take_guid = api.getTakeGUID(take, &take_guid_buf);
        hasher.update(take_guid);

        // Hash properties that affect peaks
        const start_offset = api.getTakeStartOffset(take);
        const playrate = api.getTakePlayrate(take);
        const length = api.getItemLength(item);
        const position = api.getItemPosition(item);

        hasher.update(std.mem.asBytes(&start_offset));
        hasher.update(std.mem.asBytes(&playrate));
        hasher.update(std.mem.asBytes(&length));
        hasher.update(std.mem.asBytes(&position));

        // Hash active take index (take switching)
        const take_idx = api.getItemActiveTakeIdx(item) catch 0;
        hasher.update(std.mem.asBytes(&take_idx));
    }

    return hasher.final();
}

// =============================================================================
// Tile Range Calculation
// =============================================================================

/// Range of tiles needed for a viewport
pub const TileRange = struct {
    lod: u2,
    start_tile: u32,
    end_tile: u32, // Inclusive

    /// Number of tiles in range
    pub fn count(self: TileRange) u32 {
        return self.end_tile - self.start_tile + 1;
    }
};

/// Calculate which tiles are needed for a viewport.
/// Includes buffer tiles (50% viewport each side by default).
pub fn tilesForViewport(
    viewport_start: f64,
    viewport_end: f64,
    viewport_width_px: u32,
    buffer_ratio: f64,
) ?TileRange {
    // Validate inputs
    const duration = viewport_end - viewport_start;
    if (duration <= 0) {
        logging.warn("peaks_tile: invalid viewport duration {d}", .{duration});
        return null;
    }

    if (viewport_width_px == 0) {
        logging.warn("peaks_tile: viewport width is zero", .{});
        return null;
    }

    // Calculate LOD based on pixels per second
    const pixels_per_second = @as(f64, @floatFromInt(viewport_width_px)) / duration;
    const lod: u2 = if (pixels_per_second > 200.0)
        2 // Fine
    else if (pixels_per_second > 5.0)
        1 // Medium
    else
        0; // Coarse

    const config = TILE_CONFIGS[lod];

    // Calculate buffered range
    const buffer = duration * buffer_ratio;
    const buffered_start = @max(0.0, viewport_start - buffer);
    const buffered_end = viewport_end + buffer;

    // Calculate tile indices
    const start_tile: u32 = @intFromFloat(@floor(buffered_start / config.duration));
    const end_tile: u32 = @intFromFloat(@ceil(buffered_end / config.duration));

    return TileRange{
        .lod = lod,
        .start_tile = start_tile,
        .end_tile = if (end_tile > 0) end_tile - 1 else 0, // ceil gives exclusive, we want inclusive
    };
}

/// Get LOD level from pixels per second.
pub fn lodFromPixelsPerSecond(pixels_per_second: f64) u2 {
    if (pixels_per_second > 200.0) return 2; // Fine
    if (pixels_per_second > 5.0) return 1; // Medium
    return 0; // Coarse
}

// =============================================================================
// Tests
// =============================================================================

test "TileCacheKey hash and equality" {
    const key1 = TileCacheKey.create("{test-guid-1}", 1, 2, 5);
    const key2 = TileCacheKey.create("{test-guid-1}", 1, 2, 5);
    const key3 = TileCacheKey.create("{test-guid-2}", 1, 2, 5);
    const key4 = TileCacheKey.create("{test-guid-1}", 2, 2, 5); // Different epoch

    try std.testing.expect(key1.eql(key2));
    try std.testing.expect(!key1.eql(key3));
    try std.testing.expect(!key1.eql(key4));
    try std.testing.expectEqual(key1.hash(), key2.hash());
    try std.testing.expect(key1.hash() != key3.hash());
    try std.testing.expect(key1.hash() != key4.hash());
}

test "TileCacheKey time calculations" {
    // LOD 0: 64s tiles
    const key0 = TileCacheKey.create("{guid}", 1, 0, 2);
    try std.testing.expectApproxEqAbs(@as(f64, 128.0), key0.startTime(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 192.0), key0.endTime(), 0.001);

    // LOD 1: 8s tiles
    const key1 = TileCacheKey.create("{guid}", 1, 1, 5);
    try std.testing.expectApproxEqAbs(@as(f64, 40.0), key1.startTime(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 48.0), key1.endTime(), 0.001);

    // LOD 2: 0.5s tiles
    const key2 = TileCacheKey.create("{guid}", 1, 2, 10);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), key2.startTime(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 5.5), key2.endTime(), 0.001);
}

test "TileCache basic operations" {
    const allocator = std.testing.allocator;
    var cache = TileCache.init(allocator);
    defer cache.deinit();

    const key = TileCacheKey.create("{test-guid}", 1, 2, 0);

    // Initially empty
    try std.testing.expect(cache.get(key) == null);

    // Put some data
    var peak_min: [60]f64 = undefined;
    var peak_max: [60]f64 = undefined;
    for (0..60) |i| {
        peak_min[i] = -0.5;
        peak_max[i] = 0.5;
    }

    cache.put(key, &peak_min, &peak_max, 30, 2);

    // Now should be found
    const entry = cache.get(key);
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(@as(u16, 30), entry.?.num_peaks);
    try std.testing.expectEqual(@as(u8, 2), entry.?.channels);
}

test "TileCache LRU eviction" {
    const allocator = std.testing.allocator;
    var cache = TileCache.init(allocator);
    defer cache.deinit();

    var peak_min: [60]f64 = [_]f64{0} ** 60;
    var peak_max: [60]f64 = [_]f64{0} ** 60;

    // Fill cache to capacity + 1
    for (0..MAX_CACHE_ENTRIES + 1) |i| {
        const key = TileCacheKey.create("{guid}", 1, 2, @intCast(i));
        cache.put(key, &peak_min, &peak_max, 30, 1);
        cache.tick(); // Advance frame counter
    }

    // Should have evicted oldest
    try std.testing.expectEqual(@as(usize, MAX_CACHE_ENTRIES), cache.map.count());
}

test "tilesForViewport LOD selection" {
    // Fine LOD: > 200 px/sec
    const fine = tilesForViewport(0.0, 1.0, 400, 0.0);
    try std.testing.expect(fine != null);
    try std.testing.expectEqual(@as(u2, 2), fine.?.lod);

    // Medium LOD: 5-200 px/sec
    const medium = tilesForViewport(0.0, 30.0, 400, 0.0);
    try std.testing.expect(medium != null);
    try std.testing.expectEqual(@as(u2, 1), medium.?.lod);

    // Coarse LOD: < 5 px/sec
    const coarse = tilesForViewport(0.0, 300.0, 400, 0.0);
    try std.testing.expect(coarse != null);
    try std.testing.expectEqual(@as(u2, 0), coarse.?.lod);
}

test "tilesForViewport with buffer" {
    // 10 second viewport at position 50-60, LOD 1 (8s tiles), 50% buffer
    const range = tilesForViewport(50.0, 60.0, 100, 0.5);
    try std.testing.expect(range != null);
    try std.testing.expectEqual(@as(u2, 1), range.?.lod); // Medium LOD

    // Buffer: 5s each side, so 45-65 seconds
    // LOD 1 tiles are 8s, so:
    // start_tile = floor(45/8) = 5
    // end_tile = ceil(65/8) - 1 = 9 - 1 = 8
    try std.testing.expectEqual(@as(u32, 5), range.?.start_tile);
    try std.testing.expectEqual(@as(u32, 8), range.?.end_tile);
}

test "tilesForViewport invalid inputs" {
    // Zero duration
    const zero_dur = tilesForViewport(10.0, 10.0, 400, 0.0);
    try std.testing.expect(zero_dur == null);

    // Negative duration
    const neg_dur = tilesForViewport(20.0, 10.0, 400, 0.0);
    try std.testing.expect(neg_dur == null);

    // Zero width
    const zero_width = tilesForViewport(0.0, 10.0, 0, 0.0);
    try std.testing.expect(zero_width == null);
}
