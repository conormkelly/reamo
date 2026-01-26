/// Peaks Cache - LRU cache for waveform peak data.
///
/// Content-addressed caching based on take properties (GUID, offset, playrate, length).
/// Includes track change detection via hash comparison.
///
/// Usage:
///   var cache = PeaksCache.init(allocator);
///   defer cache.deinit();
///
///   // Check cache
///   if (cache.get(key)) |peaks| { ... }
///
///   // Store peaks
///   cache.put(key, peaks_data, channels);
///
///   // Check if track items changed
///   if (cache.trackChanged(track_guid, api, track)) { ... }
const std = @import("std");
const logging = @import("../core/logging.zig");

const Allocator = std.mem.Allocator;

/// Maximum cache entries before LRU eviction
pub const MAX_CACHE_ENTRIES = 2000;

/// Maximum peaks per cached item
pub const MAX_PEAKS_PER_ITEM = 200;

/// GUID length for keys
pub const GUID_LEN = 40;

/// Content-addressed cache key.
/// Based on properties that affect the audio waveform.
pub const PeaksCacheKey = struct {
    /// Take GUID (identifies the audio source)
    take_guid: [GUID_LEN]u8,
    take_guid_len: u8,

    /// Start offset in milliseconds (rounded)
    start_offset_ms: i32,

    /// Playrate × 1000 (1.0 = 1000)
    playrate_x1000: i32,

    /// Length in milliseconds (rounded)
    length_ms: i32,

    /// Number of peak samples
    sample_count: u16,

    /// Create a cache key from take/item properties
    pub fn create(
        take_guid: []const u8,
        start_offset: f64,
        playrate: f64,
        length: f64,
        sample_count: u32,
    ) PeaksCacheKey {
        var key = PeaksCacheKey{
            .take_guid = undefined,
            .take_guid_len = 0,
            .start_offset_ms = @intFromFloat(start_offset * 1000.0),
            .playrate_x1000 = @intFromFloat(playrate * 1000.0),
            .length_ms = @intFromFloat(length * 1000.0),
            .sample_count = @intCast(@min(sample_count, MAX_PEAKS_PER_ITEM)),
        };

        const len: u8 = @intCast(@min(take_guid.len, GUID_LEN));
        @memcpy(key.take_guid[0..len], take_guid[0..len]);
        key.take_guid_len = len;

        return key;
    }

    /// Hash for HashMap
    pub fn hash(self: PeaksCacheKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(self.take_guid[0..self.take_guid_len]);
        hasher.update(std.mem.asBytes(&self.start_offset_ms));
        hasher.update(std.mem.asBytes(&self.playrate_x1000));
        hasher.update(std.mem.asBytes(&self.length_ms));
        hasher.update(std.mem.asBytes(&self.sample_count));
        return hasher.final();
    }

    /// Equality check for HashMap
    pub fn eql(a: PeaksCacheKey, b: PeaksCacheKey) bool {
        if (a.take_guid_len != b.take_guid_len) return false;
        if (a.start_offset_ms != b.start_offset_ms) return false;
        if (a.playrate_x1000 != b.playrate_x1000) return false;
        if (a.length_ms != b.length_ms) return false;
        if (a.sample_count != b.sample_count) return false;
        return std.mem.eql(u8, a.take_guid[0..a.take_guid_len], b.take_guid[0..b.take_guid_len]);
    }
};

/// Cached peak data for a single item.
pub const CachedPeaks = struct {
    /// Peak min values (interleaved for stereo)
    peak_min: [MAX_PEAKS_PER_ITEM * 2]f64,

    /// Peak max values (interleaved for stereo)
    peak_max: [MAX_PEAKS_PER_ITEM * 2]f64,

    /// Number of peaks stored
    num_peaks: u16,

    /// 1 for mono, 2 for stereo
    channels: u8,

    /// Last access time for LRU eviction (frame counter)
    last_used: u64,
};

/// HashMap context for PeaksCacheKey
const KeyContext = struct {
    pub fn hash(_: KeyContext, key: PeaksCacheKey) u64 {
        return key.hash();
    }

    pub fn eql(_: KeyContext, a: PeaksCacheKey, b: PeaksCacheKey) bool {
        return a.eql(b);
    }
};

/// LRU cache for peak data.
pub const PeaksCache = struct {
    allocator: Allocator,

    /// Cache storage
    map: std.HashMap(PeaksCacheKey, CachedPeaks, KeyContext, std.hash_map.default_max_load_percentage),

    /// Frame counter for LRU tracking
    frame_counter: u64,

    /// Per-track item hash for change detection
    /// Key: track GUID (owned string), Value: hash of item properties
    track_hashes: std.StringHashMap(u64),

    pub fn init(allocator: Allocator) PeaksCache {
        return .{
            .allocator = allocator,
            .map = std.HashMap(PeaksCacheKey, CachedPeaks, KeyContext, std.hash_map.default_max_load_percentage).init(allocator),
            .frame_counter = 0,
            .track_hashes = std.StringHashMap(u64).init(allocator),
        };
    }

    pub fn deinit(self: *PeaksCache) void {
        // Free owned track GUID keys
        var key_iter = self.track_hashes.keyIterator();
        while (key_iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.track_hashes.deinit();
        self.map.deinit();
    }

    /// Get cached peaks if available. Updates last_used on hit.
    pub fn get(self: *PeaksCache, key: PeaksCacheKey) ?*CachedPeaks {
        if (self.map.getPtr(key)) |entry| {
            entry.last_used = self.frame_counter;
            return entry;
        }
        return null;
    }

    /// Store peaks in cache, evicting oldest if full.
    pub fn put(
        self: *PeaksCache,
        key: PeaksCacheKey,
        peak_min: []const f64,
        peak_max: []const f64,
        num_peaks: usize,
        channels: usize,
    ) void {
        // Evict if at capacity
        if (self.map.count() >= MAX_CACHE_ENTRIES) {
            self.evictOldest();
        }

        var entry = CachedPeaks{
            .peak_min = undefined,
            .peak_max = undefined,
            .num_peaks = @intCast(@min(num_peaks, MAX_PEAKS_PER_ITEM)),
            .channels = @intCast(@min(channels, 2)),
            .last_used = self.frame_counter,
        };

        // Copy peak data
        const copy_len = @min(num_peaks * channels, MAX_PEAKS_PER_ITEM * 2);
        @memcpy(entry.peak_min[0..copy_len], peak_min[0..copy_len]);
        @memcpy(entry.peak_max[0..copy_len], peak_max[0..copy_len]);

        self.map.put(key, entry) catch {
            logging.warn("peaks_cache: failed to store entry", .{});
        };
    }

    /// Evict the least recently used entry.
    fn evictOldest(self: *PeaksCache) void {
        var oldest_key: ?PeaksCacheKey = null;
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
    pub fn tick(self: *PeaksCache) void {
        self.frame_counter +%= 1;
    }

    /// Check if track items have changed since last check.
    /// Computes hash of all item properties that affect peaks.
    /// Returns true if changed (or first time checking this track).
    pub fn trackChanged(
        self: *PeaksCache,
        track_guid: []const u8,
        api: anytype,
        track: *anyopaque,
    ) bool {
        const current_hash = computeTrackItemsHash(api, track);

        if (self.track_hashes.get(track_guid)) |prev_hash| {
            if (prev_hash == current_hash) {
                return false; // No change
            }
        }

        // Store new hash (need to dupe key if new)
        if (!self.track_hashes.contains(track_guid)) {
            const owned_guid = self.allocator.dupe(u8, track_guid) catch {
                logging.warn("peaks_cache: failed to store track hash key", .{});
                return true; // Assume changed on error
            };
            self.track_hashes.put(owned_guid, current_hash) catch {
                self.allocator.free(owned_guid);
                return true;
            };
        } else {
            // Update existing entry
            self.track_hashes.put(track_guid, current_hash) catch {};
        }

        return true; // Changed
    }

    /// Clear hash for a track (call when track is deleted or subscription removed).
    pub fn clearTrackHash(self: *PeaksCache, track_guid: []const u8) void {
        if (self.track_hashes.fetchRemove(track_guid)) |kv| {
            self.allocator.free(kv.key);
        }
    }

    /// Get cache statistics for debugging.
    pub fn stats(self: *const PeaksCache) struct { entries: usize, tracks: usize } {
        return .{
            .entries = self.map.count(),
            .tracks = self.track_hashes.count(),
        };
    }
};

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
// Tests
// =============================================================================

test "PeaksCacheKey hash and equality" {
    const key1 = PeaksCacheKey.create("{test-guid-1}", 0.0, 1.0, 2.0, 30);
    const key2 = PeaksCacheKey.create("{test-guid-1}", 0.0, 1.0, 2.0, 30);
    const key3 = PeaksCacheKey.create("{test-guid-2}", 0.0, 1.0, 2.0, 30);

    try std.testing.expect(key1.eql(key2));
    try std.testing.expect(!key1.eql(key3));
    try std.testing.expectEqual(key1.hash(), key2.hash());
    try std.testing.expect(key1.hash() != key3.hash());
}

test "PeaksCache basic operations" {
    const allocator = std.testing.allocator;
    var cache = PeaksCache.init(allocator);
    defer cache.deinit();

    const key = PeaksCacheKey.create("{test-guid}", 0.0, 1.0, 2.0, 30);

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

test "PeaksCache LRU eviction" {
    const allocator = std.testing.allocator;
    var cache = PeaksCache.init(allocator);
    defer cache.deinit();

    var peak_min: [60]f64 = [_]f64{0} ** 60;
    var peak_max: [60]f64 = [_]f64{0} ** 60;

    // Fill cache to capacity + 1
    for (0..MAX_CACHE_ENTRIES + 1) |i| {
        var guid: [20]u8 = undefined;
        _ = std.fmt.bufPrint(&guid, "{{guid-{d:0>6}}}", .{i}) catch continue;

        const key = PeaksCacheKey.create(&guid, 0.0, 1.0, 2.0, 30);
        cache.put(key, &peak_min, &peak_max, 30, 1);
        cache.tick(); // Advance frame counter
    }

    // Should have evicted oldest
    try std.testing.expectEqual(@as(usize, MAX_CACHE_ENTRIES), cache.map.count());
}
