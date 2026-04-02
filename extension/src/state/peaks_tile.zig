/// Tile-Based LOD Peaks Cache
///
/// Provides fixed time-window tiles at each LOD level for efficient caching
/// across zoom/pan operations. Tiles enable cache reuse when panning and
/// efficient prefetching.
///
/// LOD Levels (7 levels with 4x ratio, optimized for 1s-4hr viewport range):
///   - LOD 0: 4096s tiles, 0.0625 peaks/sec (256 peaks/tile) - Multi-hour overview
///   - LOD 1: 1024s tiles, 0.25 peaks/sec (256 peaks/tile)   - Hour+ views
///   - LOD 2: 256s tiles,  1 peak/sec (256 peaks/tile)       - 20-80 min views
///   - LOD 3: 64s tiles,   4 peaks/sec (256 peaks/tile)      - 5-20 min views
///   - LOD 4: 16s tiles,   16 peaks/sec (256 peaks/tile)     - 75s-5min views
///   - LOD 5: 4s tiles,    64 peaks/sec (256 peaks/tile)     - 20-75s views
///   - LOD 6: 1s tiles,    256 peaks/sec (256 peaks/tile)    - <20s views (finest)
///
/// Note: 256 peaks/sec at finest LOD is within REAPER's .reapeaks cache (~400 peaks/sec),
/// enabling future optimization to read pre-computed peaks instead of AudioAccessor.
///
/// Design rationale (see docs/architecture/LOD_LEVELS.md):
///   - 4x ratio between adjacent LODs for smooth fallback rendering
///   - Target 2-4 peaks/pixel at 400px viewport width
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
const logging = @import("../core/logging.zig");
const ffi = @import("../core/ffi.zig");

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

/// LOD level configurations (indices 0-6, 4x ratio between adjacent levels)
/// See docs/architecture/LOD_LEVELS.md for full rationale.
pub const TILE_CONFIGS = [7]TileConfig{
    .{ .duration = 4096.0, .peakrate = 0.0625, .peaks_per_tile = 256 }, // LOD 0: Multi-hour overview
    .{ .duration = 1024.0, .peakrate = 0.25, .peaks_per_tile = 256 }, // LOD 1: Hour+ views
    .{ .duration = 256.0, .peakrate = 1.0, .peaks_per_tile = 256 }, // LOD 2: 20-80 min views
    .{ .duration = 64.0, .peakrate = 4.0, .peaks_per_tile = 256 }, // LOD 3: 5-20 min views
    .{ .duration = 16.0, .peakrate = 16.0, .peaks_per_tile = 256 }, // LOD 4: 75s-5min views
    .{ .duration = 4.0, .peakrate = 64.0, .peaks_per_tile = 256 }, // LOD 5: 20-75s views
    .{ .duration = 1.0, .peakrate = 256.0, .peaks_per_tile = 256 }, // LOD 6: <20s views (finest)
};

/// Number of LOD levels
pub const LOD_COUNT = 7;

/// Maximum peaks per tile
pub const MAX_PEAKS_PER_TILE = 256;

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

    /// LOD level (0-7)
    lod_level: u3,

    /// Tile index: floor(startTime / tileDuration)
    tile_index: u32,

    /// Create a cache key
    pub fn create(
        take_guid: []const u8,
        epoch: u32,
        lod_level: u3,
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

    /// Return the number of entries in the cache.
    pub fn count(self: *const TileCache) usize {
        return self.map.count();
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
/// Hash: source_ptr + channel count. This changes when the source is replaced
/// or channel count changes (e.g. mono -> stereo render).
fn computeEpoch(api: anytype, take: *anyopaque) u32 {
    const source = api.getTakeSource(take) orelse {
        return 0; // No source
    };

    var hasher = std.hash.Wyhash.init(0);

    // Hash source pointer (changes if source replaced)
    hasher.update(std.mem.asBytes(&@intFromPtr(source)));

    // Hash channel count (GetMediaSourceNumChannels is reliable on all platforms)
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
    lod: u3,
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

    // Select LOD based on viewport duration (thresholds from docs/architecture/LOD_LEVELS.md)
    const lod: u3 = lodFromViewportDuration(duration);

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

/// Select LOD level based on viewport duration.
/// Thresholds ensure >= 2 peaks/pixel at 400px viewport width.
/// See docs/architecture/LOD_LEVELS.md for derivation.
pub fn lodFromViewportDuration(duration: f64) u3 {
    if (duration < 20.0) return 6; // 256 peaks/sec, < 20s (finest)
    if (duration < 75.0) return 5; // 64 peaks/sec, 20-75s
    if (duration < 300.0) return 4; // 16 peaks/sec, 75s-5min
    if (duration < 1200.0) return 3; // 4 peaks/sec, 5-20min
    if (duration < 4800.0) return 2; // 1 peak/sec, 20-80min
    if (duration < 19200.0) return 1; // 0.25 peaks/sec, 80min-5hr
    return 0; // 0.0625 peaks/sec, > 5hr
}

/// Get LOD level from pixels per second.
/// Alternative to lodFromViewportDuration when viewport width varies.
/// See docs/architecture/LOD_LEVELS.md for threshold derivation.
pub fn lodFromPixelsPerSecond(pixels_per_second: f64) u3 {
    if (pixels_per_second > 40.0) return 6; // Fine detail (finest)
    if (pixels_per_second > 10.0) return 5;
    if (pixels_per_second > 2.5) return 4;
    if (pixels_per_second > 0.625) return 3;
    if (pixels_per_second > 0.156) return 2;
    if (pixels_per_second > 0.039) return 1;
    return 0; // Coarse overview
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
    // LOD 0: 4096s tiles (multi-hour overview)
    const key0 = TileCacheKey.create("{guid}", 1, 0, 2);
    try std.testing.expectApproxEqAbs(@as(f64, 8192.0), key0.startTime(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 12288.0), key0.endTime(), 0.001);

    // LOD 4: 16s tiles
    const key4 = TileCacheKey.create("{guid}", 1, 4, 5);
    try std.testing.expectApproxEqAbs(@as(f64, 80.0), key4.startTime(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 96.0), key4.endTime(), 0.001);

    // LOD 6: 1s tiles (finest)
    const key6 = TileCacheKey.create("{guid}", 1, 6, 10);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), key6.startTime(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 11.0), key6.endTime(), 0.001);
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
    // LOD 6: < 20s viewport (finest)
    const lod6 = tilesForViewport(0.0, 10.0, 400, 0.0);
    try std.testing.expect(lod6 != null);
    try std.testing.expectEqual(@as(u3, 6), lod6.?.lod);

    // LOD 6 also for very short viewports
    const lod6_short = tilesForViewport(0.0, 2.0, 400, 0.0);
    try std.testing.expect(lod6_short != null);
    try std.testing.expectEqual(@as(u3, 6), lod6_short.?.lod);

    // LOD 5: 20-75s viewport
    const lod5 = tilesForViewport(0.0, 30.0, 400, 0.0);
    try std.testing.expect(lod5 != null);
    try std.testing.expectEqual(@as(u3, 5), lod5.?.lod);

    // LOD 4: 75s-5min viewport
    const lod4 = tilesForViewport(0.0, 120.0, 400, 0.0);
    try std.testing.expect(lod4 != null);
    try std.testing.expectEqual(@as(u3, 4), lod4.?.lod);

    // LOD 3: 5-20min viewport
    const lod3 = tilesForViewport(0.0, 600.0, 400, 0.0);
    try std.testing.expect(lod3 != null);
    try std.testing.expectEqual(@as(u3, 3), lod3.?.lod);

    // LOD 2: 20-80min viewport
    const lod2 = tilesForViewport(0.0, 3000.0, 400, 0.0);
    try std.testing.expect(lod2 != null);
    try std.testing.expectEqual(@as(u3, 2), lod2.?.lod);

    // LOD 1: 80min-5hr viewport
    const lod1 = tilesForViewport(0.0, 10000.0, 400, 0.0);
    try std.testing.expect(lod1 != null);
    try std.testing.expectEqual(@as(u3, 1), lod1.?.lod);

    // LOD 0: > 5hr viewport
    const lod0 = tilesForViewport(0.0, 25000.0, 400, 0.0);
    try std.testing.expect(lod0 != null);
    try std.testing.expectEqual(@as(u3, 0), lod0.?.lod);
}

test "tilesForViewport with buffer" {
    // 10 second viewport at position 50-60 with 50% buffer
    // 10s duration -> LOD 6 (1s tiles)
    const range = tilesForViewport(50.0, 60.0, 400, 0.5);
    try std.testing.expect(range != null);
    try std.testing.expectEqual(@as(u3, 6), range.?.lod);

    // Buffer: 5s each side, so 45-65 seconds
    // LOD 6 tiles are 1s, so:
    // start_tile = floor(45/1) = 45
    // end_tile = ceil(65/1) - 1 = 65 - 1 = 64
    try std.testing.expectEqual(@as(u32, 45), range.?.start_tile);
    try std.testing.expectEqual(@as(u32, 64), range.?.end_tile);
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
