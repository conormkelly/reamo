/// Peaks Generator - Generate waveform peaks for all items in a subscription.
///
/// Used by the peaks subscription system to push peak data to subscribed clients.
/// Uses AudioAccessor for reliable peak extraction on all platforms.
///
/// Primary APIs:
/// - generatePeaksForSubscription: Legacy full-item peaks (no viewport)
/// - generateTilesForSubscription: Tile-based LOD peaks (with viewport)
/// - generateTileViaAccessor: Single tile generation using AudioAccessor
const std = @import("std");
const logging = @import("logging.zig");
const ffi = @import("ffi.zig");
const guid_cache_mod = @import("guid_cache.zig");
const peaks_cache = @import("peaks_cache.zig");
const peaks_tile = @import("peaks_tile.zig");

const Allocator = std.mem.Allocator;

// ============================================================================
// Lua Bridge Interface (set by main.zig during init)
// ============================================================================
// Peak fetching is done via Lua bridge for reliable results across platforms.

/// Function pointer type for Lua bridge peak fetching.
/// Returns slice of peak data on success, null on failure.
/// Buffer format: [max0, max1, ..., min0, min1, ...] for each channel interleaved
/// The returned slice is valid until the next call (static buffer).
pub const LuaBridgeFetchFn = *const fn (
    track_idx: i32, // 0-based regular track index (NOT unified)
    item_idx: i32,
    start_time: f64,
    end_time: f64,
    peakrate: f64,
) ?[]const f64;

/// Global Lua bridge function (set by main.zig)
var g_lua_bridge_fn: ?LuaBridgeFetchFn = null;

/// Set the Lua bridge function. Called by main.zig during initialization.
pub fn setLuaBridgeFn(f: ?LuaBridgeFetchFn) void {
    g_lua_bridge_fn = f;
    if (f != null) {
        logging.info("peaks_generator: Lua bridge function registered", .{});
    }
}

/// Check if Lua bridge is available
pub fn isLuaBridgeAvailable() bool {
    return g_lua_bridge_fn != null;
}

// Peak extraction constants
const MAX_PEAKS_PER_ITEM = 200;

/// Maximum items to process per track (safety limit)
const MAX_ITEMS_PER_TRACK = 500;

/// Item peak data for a single item
const ItemPeaks = struct {
    item_guid: [40]u8,
    item_guid_len: usize,
    track_idx: c_int,
    item_idx: c_int,
    position: f64,
    length: f64,
    // Peak data stored as interleaved min/max
    // Mono: [min0, max0, min1, max1, ...]
    // Stereo: [Lmin0, Lmax0, Rmin0, Rmax0, Lmin1, Lmax1, ...]
    peak_min: [MAX_PEAKS_PER_ITEM * 2]f64,
    peak_max: [MAX_PEAKS_PER_ITEM * 2]f64,
    num_peaks: usize,
    channels: usize, // 1 for mono, 2 for stereo
};

/// Maximum tracks in a single subscription broadcast.
const MAX_TRACKS_PER_BROADCAST = 32;

/// Maximum items per track in multi-track mode (smaller than single-track to limit stack usage).
const MAX_ITEMS_PER_TRACK_MULTITRACK = 64;

/// Generate peaks for all tracks in a client's subscription.
/// Returns a track-keyed map JSON event format for efficient frontend lookup.
///
/// IMPORTANT: This function uses streaming JSON output to avoid stack overflow.
/// We process one track at a time, writing JSON directly to the output buffer.
/// This keeps stack usage bounded to ~500KB (one track's worth of items).
///
/// Event format:
/// {
///   "type": "event",
///   "event": "peaks",
///   "payload": {
///     "tracks": {
///       "1": { "guid": "{...}", "items": [...] },
///       "5": { "guid": "{...}", "items": [...] }
///     }
///   }
/// }
pub fn generatePeaksForSubscription(
    allocator: Allocator,
    api: anytype,
    guid_cache: *const guid_cache_mod.GuidCache,
    cache: ?*peaks_cache.PeaksCache,
    sub: *const @import("peaks_subscriptions.zig").ClientSubscription,
    sample_count: u32,
) ?[]const u8 {
    // Collect track indices from subscription
    var track_indices_buf: [MAX_TRACKS_PER_BROADCAST]c_int = undefined;
    var track_count: usize = 0;

    switch (sub.mode) {
        .none => return null,
        .range => {
            // Range mode: indices from range_start to range_end
            const total_tracks = api.trackCount();
            var idx = sub.range_start;
            const end = @min(sub.range_end, total_tracks);
            while (idx <= end and track_count < MAX_TRACKS_PER_BROADCAST) : (idx += 1) {
                track_indices_buf[track_count] = idx;
                track_count += 1;
            }
        },
        .guids => {
            // GUID mode: resolve each GUID to track index
            for (0..sub.guid_count) |i| {
                if (track_count >= MAX_TRACKS_PER_BROADCAST) break;
                const guid = sub.getGuid(i) orelse continue;
                const track = guid_cache.resolve(guid) orelse continue;
                const idx = api.getTrackIdx(track);
                if (idx >= 0) {
                    track_indices_buf[track_count] = idx;
                    track_count += 1;
                }
            }
        },
    }

    if (track_count == 0) {
        logging.debug("peaks_generator: no tracks resolved from subscription", .{});
        return null;
    }

    // Viewport-aware peak generation:
    // - With viewport: peakrate based on zoom level, num_peaks varies per item
    // - Without viewport: fixed sample_count per item (legacy mode)
    const use_viewport = sub.hasViewport();
    const viewport_peakrate = if (use_viewport) sub.viewportPeakrate() else 0;
    const fixed_num_peaks: usize = @min(@as(usize, sample_count), MAX_PEAKS_PER_ITEM);

    // Allocate output buffer for streaming JSON
    // Estimate: ~800 bytes per item, ~100 bytes overhead per track, max 64 items per track
    const estimated_size = 256 + track_count * (100 + MAX_ITEMS_PER_TRACK_MULTITRACK * 800);
    const buf = allocator.alloc(u8, estimated_size) catch {
        logging.warn("peaks_generator: failed to allocate {d} bytes for JSON", .{estimated_size});
        return null;
    };
    errdefer allocator.free(buf);

    // CRITICAL: Allocate items array on HEAP, not stack!
    // Each ItemPeaks is ~6.5KB, 64 items = ~420KB - way over the 1KB stack limit for timer callbacks.
    // See DEVELOPMENT.md "Memory Management" section.
    const items_peaks = allocator.alloc(ItemPeaks, MAX_ITEMS_PER_TRACK_MULTITRACK) catch {
        logging.warn("peaks_generator: failed to allocate items buffer", .{});
        allocator.free(buf);
        return null;
    };
    defer allocator.free(items_peaks);

    var stream = std.io.fixedBufferStream(buf);
    var w = stream.writer();

    // Write event envelope opening
    w.writeAll("{\"type\":\"event\",\"event\":\"peaks\",\"payload\":{\"tracks\":{") catch return null;

    var tracks_written: usize = 0;

    // Process each track, streaming JSON directly
    // NOTE: track_idx is a UNIFIED index (0=master, 1+=user tracks) matching the items event
    for (track_indices_buf[0..track_count]) |track_idx| {
        const track = api.getTrackByUnifiedIdx(track_idx) orelse continue;

        // Get track GUID
        var guid_buf: [64]u8 = undefined;
        const track_guid = api.formatTrackGuid(track, &guid_buf);

        // Count items on track
        const item_count_raw = api.trackItemCount(track);
        if (item_count_raw <= 0) continue;

        // Cap items for safety
        const max_items: c_int = @min(item_count_raw, MAX_ITEMS_PER_TRACK_MULTITRACK);

        // Reset valid item count for this track (reuse heap buffer)
        var valid_item_count: usize = 0;

        var i: c_int = 0;
        while (i < max_items) : (i += 1) {
            const item = api.getItemByIdx(track, i) orelse continue;
            const take = api.getItemActiveTake(item) orelse continue;

            // Skip MIDI items
            if (api.isTakeMIDI(take)) continue;

            // Initialize item peaks (num_peaks calculated after getting item length)
            var item_peaks = ItemPeaks{
                .item_guid = undefined,
                .item_guid_len = 0,
                .track_idx = track_idx,
                .item_idx = i,
                .position = 0,
                .length = 0,
                .peak_min = [_]f64{1.0} ** (MAX_PEAKS_PER_ITEM * 2),
                .peak_max = [_]f64{-1.0} ** (MAX_PEAKS_PER_ITEM * 2),
                .num_peaks = 0, // Set after calculating item length
                .channels = 1,
            };

            // Get item properties
            item_peaks.position = api.getItemPosition(item);
            item_peaks.length = api.getItemLength(item);

            // Validate length
            if (!ffi.isFinite(item_peaks.length) or item_peaks.length <= 0) continue;

            // Calculate num_peaks for this item
            // With viewport: based on item length and viewport peakrate (adaptive)
            // Without viewport: fixed sample_count (legacy)
            const num_peaks: usize = if (use_viewport)
                @min(@as(usize, @intFromFloat(@ceil(item_peaks.length * viewport_peakrate))), MAX_PEAKS_PER_ITEM)
            else
                fixed_num_peaks;

            // Update item_peaks with calculated num_peaks
            item_peaks.num_peaks = num_peaks;

            // Get item GUID
            var item_guid_buf: [64]u8 = undefined;
            const item_guid = api.getItemGUID(item, &item_guid_buf);
            const item_guid_len = @min(item_guid.len, 40);
            @memcpy(item_peaks.item_guid[0..item_guid_len], item_guid[0..item_guid_len]);
            item_peaks.item_guid_len = item_guid_len;

            // Try cache lookup or generate peaks
            if (cache) |c| {
                var take_guid_buf: [64]u8 = undefined;
                const take_guid = api.getTakeGUID(take, &take_guid_buf);
                const start_offset = api.getTakeStartOffset(take);
                const playrate = api.getTakePlayrate(take);

                // CRITICAL: Use num_peaks (viewport-aware) for cache key, not sample_count (fixed).
                // Each LOD level produces different num_peaks, and cache must key by that.
                const key = peaks_cache.PeaksCacheKey.create(
                    take_guid,
                    start_offset,
                    playrate,
                    item_peaks.length,
                    @intCast(num_peaks),
                );

                if (c.get(key)) |cached| {
                    const copy_len = @min(@as(usize, cached.num_peaks) * @as(usize, cached.channels), MAX_PEAKS_PER_ITEM * 2);
                    @memcpy(item_peaks.peak_min[0..copy_len], cached.peak_min[0..copy_len]);
                    @memcpy(item_peaks.peak_max[0..copy_len], cached.peak_max[0..copy_len]);
                    item_peaks.num_peaks = cached.num_peaks;
                    item_peaks.channels = cached.channels;
                } else {
                    if (generatePeaksForItem(allocator, api, take, item_peaks.length, num_peaks, &item_peaks)) {
                        c.put(
                            key,
                            item_peaks.peak_min[0 .. item_peaks.num_peaks * item_peaks.channels],
                            item_peaks.peak_max[0 .. item_peaks.num_peaks * item_peaks.channels],
                            item_peaks.num_peaks,
                            item_peaks.channels,
                        );
                    } else {
                        continue;
                    }
                }
            } else {
                if (!generatePeaksForItem(allocator, api, take, item_peaks.length, num_peaks, &item_peaks)) {
                    continue;
                }
            }

            items_peaks[valid_item_count] = item_peaks;
            valid_item_count += 1;
        }

        // Skip tracks with no valid items
        if (valid_item_count == 0) continue;

        // Write track JSON
        if (tracks_written > 0) w.writeByte(',') catch return null;
        tracks_written += 1;

        // Track key is the index (as string)
        w.print("\"{d}\":{{\"guid\":\"", .{track_idx}) catch return null;
        w.writeAll(track_guid) catch return null;
        w.writeAll("\",\"items\":[") catch return null;

        for (items_peaks[0..valid_item_count], 0..) |item, item_i| {
            if (item_i > 0) w.writeByte(',') catch return null;

            // Write item object
            w.writeAll("{\"itemGuid\":\"") catch return null;
            w.writeAll(item.item_guid[0..item.item_guid_len]) catch return null;
            w.print("\",\"trackIdx\":{d},\"itemIdx\":{d}", .{ item.track_idx, item.item_idx }) catch return null;
            w.print(",\"position\":{d:.6},\"length\":{d:.6}", .{ item.position, item.length }) catch return null;
            w.print(",\"channels\":{d},\"peaks\":[", .{item.channels}) catch return null;

            // Write peaks array
            for (0..item.num_peaks) |p| {
                if (p > 0) w.writeByte(',') catch return null;

                if (item.channels == 2) {
                    const max_l = item.peak_max[p * 2];
                    const max_r = item.peak_max[p * 2 + 1];
                    const min_l = item.peak_min[p * 2];
                    const min_r = item.peak_min[p * 2 + 1];
                    w.print("{{\"l\":[{d:.4},{d:.4}],\"r\":[{d:.4},{d:.4}]}}", .{
                        min_l, max_l, min_r, max_r,
                    }) catch return null;
                } else {
                    const max_val = item.peak_max[p];
                    const min_val = item.peak_min[p];
                    w.print("[{d:.4},{d:.4}]", .{ min_val, max_val }) catch return null;
                }
            }

            w.writeAll("]}") catch return null;
        }

        w.writeAll("]}") catch return null;
    }

    // Close JSON envelope
    w.writeAll("}}}") catch return null;

    if (tracks_written == 0) {
        logging.debug("peaks_generator: no tracks with audio items", .{});
        allocator.free(buf);
        return null;
    }

    // Shrink to actual size
    const written = stream.getWritten();
    const result = allocator.realloc(buf, written.len) catch buf;
    return result[0..written.len];
}

// =============================================================================
// Tile-Based Peak Generation
// =============================================================================

/// Minimum samples per peak for accurate min/max detection.
/// 10 samples per peak provides good resolution without excessive data.
const SAMPLES_PER_PEAK: usize = 10;

/// Maximum sample rate for AudioAccessor (caps memory for short tiles).
/// 4000 Hz is sufficient for peak detection and 11x faster than 44100 Hz.
const MAX_ACCESSOR_SAMPLE_RATE: f64 = 4000.0;

/// Minimum sample rate to ensure reasonable audio resolution.
const MIN_ACCESSOR_SAMPLE_RATE: f64 = 1.0;

// =============================================================================
// Detailed Metrics for Performance Analysis
// =============================================================================

/// Metrics for a single tile generation operation.
pub const TileMetrics = struct {
    tile_index: u32,
    lod: u8,
    duration_ns: u64, // Time to generate this tile
    sample_rate: f64, // Effective sample rate used
    samples_read: usize, // Actual samples read from accessor
    peaks_computed: usize, // Number of peaks computed
    buffer_bytes: usize, // Memory allocated for sample buffer
    is_cache_hit: bool, // Was this tile already cached?

    pub fn format(self: TileMetrics, writer: anytype) !void {
        if (self.is_cache_hit) {
            try writer.print("tile[{d}] LOD{d} CACHE_HIT", .{ self.tile_index, self.lod });
        } else {
            const duration_us = @as(f64, @floatFromInt(self.duration_ns)) / 1000.0;
            try writer.print("tile[{d}] LOD{d} {d:.1}us sr={d:.0}Hz samples={d} peaks={d} mem={d}B", .{
                self.tile_index,
                self.lod,
                duration_us,
                self.sample_rate,
                self.samples_read,
                self.peaks_computed,
                self.buffer_bytes,
            });
        }
    }
};

/// Metrics for generating all tiles for a single item.
pub const ItemTileMetrics = struct {
    take_guid: [40]u8,
    take_guid_len: usize,
    item_position: f64,
    item_length: f64,
    tiles_total: usize,
    tiles_cached: usize,
    tiles_generated: usize,
    tiles_failed: usize,
    accessor_create_ns: u64, // Time to create AudioAccessor (0 if all cached)
    total_gen_ns: u64, // Total time generating tiles (excludes accessor creation)
    total_samples_read: usize,
    total_buffer_bytes: usize, // Peak memory for sample buffer (not cumulative)

    pub fn logSummary(self: ItemTileMetrics) void {
        const accessor_us = @as(f64, @floatFromInt(self.accessor_create_ns)) / 1000.0;
        const gen_us = @as(f64, @floatFromInt(self.total_gen_ns)) / 1000.0;
        const total_us = accessor_us + gen_us;
        const avg_us = if (self.tiles_generated > 0) gen_us / @as(f64, @floatFromInt(self.tiles_generated)) else 0.0;

        logging.info("  item[{s}] pos={d:.1}s len={d:.1}s tiles={d} (cached={d} gen={d} fail={d})", .{
            self.take_guid[0..self.take_guid_len],
            self.item_position,
            self.item_length,
            self.tiles_total,
            self.tiles_cached,
            self.tiles_generated,
            self.tiles_failed,
        });
        logging.info("    timing: accessor={d:.0}us gen={d:.0}us total={d:.0}us avg={d:.1}us/tile", .{
            accessor_us, gen_us, total_us, avg_us,
        });
        if (self.tiles_generated > 0) {
            logging.info("    io: samples_read={d} buffer_bytes={d}", .{
                self.total_samples_read, self.total_buffer_bytes,
            });
        }
    }
};

/// Aggregate metrics for an entire subscription generation run.
pub const SubscriptionMetrics = struct {
    lod: u8,
    viewport_start: f64,
    viewport_end: f64,
    viewport_width_px: u32,

    // Track counts
    tracks_processed: usize,
    items_checked: usize,
    items_in_viewport: usize,

    // Tile counts
    tiles_total: usize,
    tiles_cached: usize,
    tiles_generated: usize,
    tiles_failed: usize,

    // Timing (nanoseconds)
    total_time_ns: u64, // Entire function
    accessor_time_ns: u64, // Total time creating accessors
    gen_time_ns: u64, // Total time generating tiles (excluding accessor)
    json_time_ns: u64, // Time spent writing JSON
    min_tile_gen_ns: u64, // Fastest single tile generation
    max_tile_gen_ns: u64, // Slowest single tile generation

    // Memory
    peak_buffer_bytes: usize, // Largest single sample buffer allocated
    json_buffer_bytes: usize, // JSON output buffer size
    total_samples_read: usize, // Sum of all samples read

    // Cache state
    cache_size_before: usize,
    cache_size_after: usize,

    const Self = @This();

    pub fn init(lod: u8, viewport_start: f64, viewport_end: f64, viewport_width_px: u32) Self {
        return Self{
            .lod = lod,
            .viewport_start = viewport_start,
            .viewport_end = viewport_end,
            .viewport_width_px = viewport_width_px,
            .tracks_processed = 0,
            .items_checked = 0,
            .items_in_viewport = 0,
            .tiles_total = 0,
            .tiles_cached = 0,
            .tiles_generated = 0,
            .tiles_failed = 0,
            .total_time_ns = 0,
            .accessor_time_ns = 0,
            .gen_time_ns = 0,
            .json_time_ns = 0,
            .min_tile_gen_ns = std.math.maxInt(u64),
            .max_tile_gen_ns = 0,
            .peak_buffer_bytes = 0,
            .json_buffer_bytes = 0,
            .total_samples_read = 0,
            .cache_size_before = 0,
            .cache_size_after = 0,
        };
    }

    pub fn hitRate(self: Self) f64 {
        const total = self.tiles_cached + self.tiles_generated;
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.tiles_cached)) / @as(f64, @floatFromInt(total)) * 100.0;
    }

    pub fn logSummary(self: Self) void {
        const total_ms = @as(f64, @floatFromInt(self.total_time_ns)) / 1_000_000.0;
        const accessor_ms = @as(f64, @floatFromInt(self.accessor_time_ns)) / 1_000_000.0;
        const gen_ms = @as(f64, @floatFromInt(self.gen_time_ns)) / 1_000_000.0;
        const json_ms = @as(f64, @floatFromInt(self.json_time_ns)) / 1_000_000.0;
        const avg_gen_ms = if (self.tiles_generated > 0) gen_ms / @as(f64, @floatFromInt(self.tiles_generated)) else 0.0;
        const min_gen_ms = if (self.min_tile_gen_ns < std.math.maxInt(u64))
            @as(f64, @floatFromInt(self.min_tile_gen_ns)) / 1_000_000.0
        else
            0.0;
        const max_gen_ms = @as(f64, @floatFromInt(self.max_tile_gen_ns)) / 1_000_000.0;

        logging.info("═══════════════════════════════════════════════════════════════", .{});
        logging.info("TILE GENERATION METRICS - LOD {d}", .{self.lod});
        logging.info("═══════════════════════════════════════════════════════════════", .{});
        logging.info("Viewport: {d:.2}s - {d:.2}s ({d}px)", .{
            self.viewport_start, self.viewport_end, self.viewport_width_px,
        });
        logging.info("Scope: {d} tracks, {d} items checked, {d} in viewport", .{
            self.tracks_processed, self.items_checked, self.items_in_viewport,
        });
        logging.info("───────────────────────────────────────────────────────────────", .{});
        logging.info("TILES: {d} total | {d} cached ({d:.0}%) | {d} generated | {d} failed", .{
            self.tiles_total, self.tiles_cached, self.hitRate(), self.tiles_generated, self.tiles_failed,
        });
        logging.info("───────────────────────────────────────────────────────────────", .{});
        logging.info("TIMING:", .{});
        logging.info("  Total:     {d:.2}ms", .{total_ms});
        logging.info("  Accessor:  {d:.2}ms ({d:.0}%)", .{ accessor_ms, if (total_ms > 0) accessor_ms / total_ms * 100 else 0 });
        logging.info("  Generate:  {d:.2}ms ({d:.0}%) - avg {d:.2}ms/tile", .{ gen_ms, if (total_ms > 0) gen_ms / total_ms * 100 else 0, avg_gen_ms });
        if (self.tiles_generated > 0) {
            logging.info("    min: {d:.3}ms  max: {d:.3}ms", .{ min_gen_ms, max_gen_ms });
        }
        logging.info("  JSON:      {d:.2}ms ({d:.0}%)", .{ json_ms, if (total_ms > 0) json_ms / total_ms * 100 else 0 });
        logging.info("───────────────────────────────────────────────────────────────", .{});
        logging.info("MEMORY:", .{});
        logging.info("  Peak sample buffer: {d} bytes", .{self.peak_buffer_bytes});
        logging.info("  JSON output buffer: {d} bytes", .{self.json_buffer_bytes});
        logging.info("  Total samples read: {d}", .{self.total_samples_read});
        logging.info("───────────────────────────────────────────────────────────────", .{});
        logging.info("CACHE: {d} -> {d} entries", .{ self.cache_size_before, self.cache_size_after });
        logging.info("═══════════════════════════════════════════════════════════════", .{});
    }
};

/// Result from generating a single tile, including metrics.
pub const TileGenerationResult = struct {
    tile: peaks_tile.CachedTile,
    sample_rate: f64, // Effective sample rate used
    samples_read: usize, // Actual samples read from accessor
    buffer_bytes: usize, // Memory allocated for sample buffer
};

// =============================================================================
// GetMediaItemTake_Peaks Based Tile Generation
// =============================================================================
// Uses REAPER's pre-computed .reapeaks mipmaps for fast peak retrieval.
// Fetches peaks for the FULL item, then slices into tiles locally.
// This is faster than AudioAccessor because it reads pre-computed data.

/// Result from fetching full item peaks via GetMediaItemTake_Peaks
const ItemPeaksResult = struct {
    /// Interleaved peak data: peak_max then peak_min blocks
    /// Layout: [ch0_max_0, ch1_max_0, ...][ch0_min_0, ch1_min_0, ...]
    peak_min: []f64,
    peak_max: []f64,
    num_peaks: usize,
    channels: usize,
    /// The allocator used - caller must free peak_min and peak_max
    allocator: Allocator,

    pub fn deinit(self: *ItemPeaksResult) void {
        self.allocator.free(self.peak_min);
        self.allocator.free(self.peak_max);
    }
};

/// Fetch peaks for an entire item using REAPER's GetMediaItemTake_Peaks API.
/// This reads from pre-computed .reapeaks mipmaps, which is fast.
///
/// Parameters:
/// - allocator: For peak data buffers (caller must call result.deinit())
/// - api: Reaper backend
/// - take: Take pointer
/// - item_position: Item's project timeline position (for starttime param)
/// - item_length: Item duration in seconds
/// - peakrate: Desired peaks per second (from LOD config)
///
/// Returns ItemPeaksResult on success, null on failure.
fn fetchItemPeaksViaTakePeaksAPI(
    allocator: Allocator,
    api: anytype,
    take: *anyopaque,
    item_position: f64,
    item_length: f64,
    peakrate: f64,
) ?ItemPeaksResult {
    // Get source to determine channel count
    const source = api.getTakeSource(take) orelse {
        logging.warn("fetchItemPeaks: failed to get take source", .{});
        return null;
    };

    // Get actual channel count from source (1=mono, 2=stereo, etc.)
    const source_channels = api.getMediaSourceChannels(source);
    if (source_channels <= 0) {
        logging.debug("fetchItemPeaks: invalid channel count {d}", .{source_channels});
        return null;
    }

    // Request up to 2 channels (we don't support more than stereo in the output)
    const num_channels: usize = @min(@as(usize, @intCast(source_channels)), 2);

    // Calculate number of peaks for the full item at this peakrate
    const num_peaks: usize = @intFromFloat(@ceil(item_length * peakrate));
    if (num_peaks == 0) {
        logging.debug("fetchItemPeaks: num_peaks is 0 for length={d:.2} peakrate={d:.2}", .{ item_length, peakrate });
        return null;
    }

    // Buffer for REAPER's output (channel-interleaved within max/min blocks)
    // Size = num_channels * num_peaks * 2 (max block + min block)
    const buf_size = num_channels * num_peaks * 2;
    const reaper_buf = allocator.alloc(f64, buf_size) catch {
        logging.warn("fetchItemPeaks: failed to allocate {d} bytes for peak buffer", .{buf_size * 8});
        return null;
    };
    errdefer allocator.free(reaper_buf);

    // Call REAPER's GetMediaItemTake_Peaks
    // starttime is in PROJECT time (timeline position)
    // peakrate = peaks per second
    const result = api.getMediaItemTakePeaks(
        take,
        peakrate,
        item_position, // Project timeline position
        @intCast(num_channels),
        @intCast(num_peaks),
        reaper_buf,
    );

    // Parse return value: sample_count in low 20 bits, mode in bits 20-23
    const actual_peaks: usize = @intCast(result & 0xFFFFF);
    // NOTE: mode=0 is VALID (interpolated data from coarser mipmap), NOT an error!
    // mode=1+ means native resolution. Only check actual_peaks for failure.
    const mode = @as(u4, @intCast((result >> 20) & 0xF));
    _ = mode; // Unused - both 0 and 1 are valid

    if (actual_peaks == 0) {
        logging.debug("fetchItemPeaks: no peaks returned from REAPER (result={d})", .{result});
        allocator.free(reaper_buf);
        return null;
    }

    logging.debug("fetchItemPeaks: requested {d} peaks at {d:.2}/sec, got {d} for {d:.2}s item", .{
        num_peaks,
        peakrate,
        actual_peaks,
        item_length,
    });

    // Parse REAPER's buffer into separate min/max arrays
    // REAPER format (channel-interleaved within blocks):
    //   Block 1 (Maximums): [L_max_0, R_max_0, L_max_1, R_max_1, ...]
    //   Block 2 (Minimums): [L_min_0, R_min_0, L_min_1, R_min_1, ...]
    const peaks_to_use = @min(actual_peaks, num_peaks);
    const data_size = peaks_to_use * num_channels;

    const peak_min = allocator.alloc(f64, data_size) catch {
        allocator.free(reaper_buf);
        return null;
    };
    errdefer allocator.free(peak_min);

    const peak_max = allocator.alloc(f64, data_size) catch {
        allocator.free(reaper_buf);
        allocator.free(peak_min);
        return null;
    };

    // Copy from REAPER buffer to our format
    // REAPER: [maxes...][mins...] -> Our: separate peak_max[], peak_min[]
    const block_size = num_peaks * num_channels;
    for (0..peaks_to_use) |p| {
        for (0..num_channels) |ch| {
            const idx = p * num_channels + ch;
            const max_offset = p * num_channels + ch;
            const min_offset = block_size + p * num_channels + ch;
            peak_max[idx] = reaper_buf[max_offset];
            peak_min[idx] = reaper_buf[min_offset];
        }
    }

    allocator.free(reaper_buf);

    return ItemPeaksResult{
        .peak_min = peak_min,
        .peak_max = peak_max,
        .num_peaks = peaks_to_use,
        .channels = num_channels,
        .allocator = allocator,
    };
}

/// Fetch peaks for an item using the Lua bridge.
/// Lua fetches the peaks and transfers them via binary-packed strings.
///
/// Parameters:
/// - allocator: For peak data buffers (caller must call result.deinit())
/// - track_idx: 0-based regular track index (NOT unified index)
/// - item_idx: Item index on the track
/// - item_position: Item's project timeline position
/// - item_length: Item duration in seconds
/// - peakrate: Desired peaks per second
///
/// Returns ItemPeaksResult on success, null on failure.
fn fetchItemPeaksViaLuaBridge(
    allocator: Allocator,
    track_idx: c_int,
    item_idx: c_int,
    item_position: f64,
    item_length: f64,
    peakrate: f64,
) ?ItemPeaksResult {
    const bridge_fn = g_lua_bridge_fn orelse return null;

    // Calculate expected peaks
    const end_time = item_position + item_length;
    const expected_peaks: usize = @intFromFloat(@ceil(item_length * peakrate));
    if (expected_peaks == 0) return null;

    // Call Lua bridge
    const raw_data = bridge_fn(
        @intCast(track_idx),
        @intCast(item_idx),
        item_position,
        end_time,
        peakrate,
    ) orelse {
        logging.debug("fetchItemPeaksViaLuaBridge: Lua bridge returned null", .{});
        return null;
    };

    // The Lua bridge returns data in REAPER's format:
    // [max block][min block], each block is channel-interleaved
    // We need to determine channels from the data size
    // For N peaks and C channels: size = N * C * 2 (max + min)
    const data_len = raw_data.len;
    if (data_len == 0) {
        logging.debug("fetchItemPeaksViaLuaBridge: empty data", .{});
        return null;
    }

    // Determine channels: try stereo first, then mono
    // Size should be num_peaks * channels * 2
    var num_channels: usize = 2;
    var num_peaks: usize = data_len / (num_channels * 2);

    // If stereo doesn't divide evenly, try mono
    if (num_peaks * num_channels * 2 != data_len) {
        num_channels = 1;
        num_peaks = data_len / 2;
        if (num_peaks * 2 != data_len) {
            logging.warn("fetchItemPeaksViaLuaBridge: unexpected data size {d}", .{data_len});
            return null;
        }
    }

    logging.debug("fetchItemPeaksViaLuaBridge: got {d} peaks, {d} channels", .{ num_peaks, num_channels });

    // Allocate our buffers
    const data_size = num_peaks * num_channels;
    const peak_min = allocator.alloc(f64, data_size) catch return null;
    errdefer allocator.free(peak_min);

    const peak_max = allocator.alloc(f64, data_size) catch {
        allocator.free(peak_min);
        return null;
    };

    // Copy from Lua buffer to our format
    // Lua sends: [maxes...][mins...] -> Our: separate peak_max[], peak_min[]
    const block_size = num_peaks * num_channels;
    for (0..num_peaks) |p| {
        for (0..num_channels) |ch| {
            const idx = p * num_channels + ch;
            const max_offset = p * num_channels + ch;
            const min_offset = block_size + p * num_channels + ch;
            if (max_offset < data_len and min_offset < data_len) {
                peak_max[idx] = raw_data[max_offset];
                peak_min[idx] = raw_data[min_offset];
            }
        }
    }

    return ItemPeaksResult{
        .peak_min = peak_min,
        .peak_max = peak_max,
        .num_peaks = num_peaks,
        .channels = num_channels,
        .allocator = allocator,
    };
}

/// Extract a single tile's worth of peaks from full item peaks.
/// The item peaks should be at the same peakrate as the tile LOD.
///
/// Parameters:
/// - item_peaks: Full item peaks from fetchItemPeaksViaTakePeaksAPI
/// - tile_index: Which tile to extract (0-based from item start)
/// - peaks_per_tile: Number of peaks per tile (from LOD config)
///
/// Returns a CachedTile with the extracted peaks.
fn sliceTileFromItemPeaks(
    item_peaks: *const ItemPeaksResult,
    tile_index: u32,
    peaks_per_tile: usize,
) peaks_tile.CachedTile {
    var tile = peaks_tile.CachedTile.empty();

    const start_peak = @as(usize, tile_index) * peaks_per_tile;
    const end_peak = @min(start_peak + peaks_per_tile, item_peaks.num_peaks);

    if (start_peak >= item_peaks.num_peaks) {
        // Tile is past end of item - return empty tile
        return tile;
    }

    const num_peaks = end_peak - start_peak;
    const channels = item_peaks.channels;

    // Copy peaks for this tile
    for (0..num_peaks) |p| {
        for (0..channels) |ch| {
            const src_idx = (start_peak + p) * channels + ch;
            const dst_idx = p * channels + ch;
            tile.peak_max[dst_idx] = item_peaks.peak_max[src_idx];
            tile.peak_min[dst_idx] = item_peaks.peak_min[src_idx];
        }
    }

    // Zero out remaining peaks if we got fewer than peaks_per_tile
    for (num_peaks..peaks_per_tile) |p| {
        for (0..channels) |ch| {
            const dst_idx = p * channels + ch;
            tile.peak_max[dst_idx] = 0;
            tile.peak_min[dst_idx] = 0;
        }
    }

    // Detect mono vs stereo by comparing L/R peaks
    const detected_channels: u8 = blk: {
        if (channels == 1) break :blk 1;
        const epsilon = 0.0001;
        for (0..num_peaks) |p| {
            const max_l = tile.peak_max[p * 2];
            const max_r = tile.peak_max[p * 2 + 1];
            const min_l = tile.peak_min[p * 2];
            const min_r = tile.peak_min[p * 2 + 1];
            if (@abs(max_l - max_r) > epsilon or @abs(min_l - min_r) > epsilon) {
                break :blk 2; // Different L/R = true stereo
            }
        }
        break :blk 1; // All L/R identical = mono
    };

    tile.num_peaks = @intCast(num_peaks);
    tile.channels = detected_channels;

    return tile;
}

/// Generate a single tile using AudioAccessor (for LOD 2).
/// This bypasses GetMediaItemTake_Peaks which fails on ARM64 macOS with high peakrate.
/// See docs/architecture/PEAK_GENERATION.md for details on the ARM64 ABI issue.
///
/// Parameters:
/// - allocator: For temporary sample buffer
/// - api: Reaper backend
/// - take: Take pointer
/// - tile_start_time: Start time relative to ITEM start (not project time)
/// - tile_duration: Duration of the tile in seconds
/// - num_peaks: Number of peaks to compute for this tile
///
/// Returns TileGenerationResult on success, null on failure.
pub fn generateTileViaAccessor(
    allocator: Allocator,
    api: anytype,
    take: *anyopaque,
    tile_start_time: f64,
    tile_duration: f64,
    num_peaks: usize,
) ?TileGenerationResult {
    // Create audio accessor for this take
    const accessor = api.makeTakeAccessor(take) orelse {
        logging.warn("genTileAccessor: failed to create accessor", .{});
        return null;
    };
    defer api.destroyTakeAccessor(accessor);

    return generateTileWithAccessor(allocator, api, accessor, tile_start_time, tile_duration, num_peaks);
}

/// Generate a single tile using a pre-existing AudioAccessor.
/// Use this when generating multiple tiles for the same take to avoid
/// creating/destroying the accessor for each tile.
///
/// Parameters:
/// - allocator: For temporary sample buffer
/// - api: Reaper backend
/// - accessor: Pre-created AudioAccessor (caller manages lifetime)
/// - tile_start_time: Start time relative to ITEM start (not project time)
/// - tile_duration: Duration of the tile in seconds
/// - num_peaks: Number of peaks to compute for this tile
///
/// Returns TileGenerationResult on success (includes tile and metrics), null on failure.
fn generateTileWithAccessor(
    allocator: Allocator,
    api: anytype,
    accessor: *anyopaque,
    tile_start_time: f64,
    tile_duration: f64,
    num_peaks: usize,
) ?TileGenerationResult {
    if (num_peaks == 0 or num_peaks > peaks_tile.MAX_PEAKS_PER_TILE) {
        logging.warn("genTileAccessor: invalid num_peaks {d}", .{num_peaks});
        return null;
    }

    // Check for invalid tile duration (can happen when tile extends past item end)
    if (tile_duration <= 0) {
        logging.info("genTileAccessor: skipping tile with invalid duration {d:.2}s at start {d:.2}s", .{ tile_duration, tile_start_time });
        return null;
    }

    // Calculate samples needed dynamically based on tile duration.
    // For long tiles (e.g., 256s at LOD 2), we don't need 4000 Hz - just enough
    // samples to compute the requested peaks with good resolution.
    // This keeps memory bounded: 512 peaks × 10 samples × 2 channels × 8 bytes = 80KB max
    const samples_needed: usize = num_peaks * SAMPLES_PER_PEAK;

    // Calculate the effective sample rate for this tile
    const effective_sample_rate = @min(
        MAX_ACCESSOR_SAMPLE_RATE,
        @max(MIN_ACCESSOR_SAMPLE_RATE, @as(f64, @floatFromInt(samples_needed)) / tile_duration),
    );

    // Recalculate actual samples based on clamped rate (for short tiles, may exceed samples_needed)
    const actual_samples: usize = @intFromFloat(@ceil(tile_duration * effective_sample_rate));
    if (actual_samples == 0) {
        logging.warn("genTileAccessor: actual_samples is 0", .{});
        return null;
    }

    const samples_per_peak = @max(actual_samples / num_peaks, 1);

    // Always request stereo (2 channels) - detect mono by comparing L/R later
    const num_channels: usize = 2;

    // Calculate buffer size for metrics
    const buffer_bytes = actual_samples * num_channels * @sizeOf(f64);

    // Allocate sample buffer on heap (stereo interleaved)
    const sample_buf = allocator.alloc(f64, actual_samples * num_channels) catch {
        logging.warn("genTileAccessor: failed to allocate {d} bytes for samples", .{buffer_bytes});
        return null;
    };
    defer allocator.free(sample_buf);

    // Read samples from accessor
    // Note: AudioAccessor uses time relative to the TAKE start (handles trim/playrate internally)
    const sample_rate_int: c_int = @intFromFloat(effective_sample_rate);
    const rv = api.readAccessorSamples(
        accessor,
        sample_rate_int,
        @intCast(num_channels),
        tile_start_time, // Relative to take start
        @intCast(actual_samples),
        sample_buf,
    );

    // rv is a status indicator: <0 = error, 0 = no audio at position, >0 = has audio
    // We iterate over samples_needed regardless of rv (the buffer is filled)
    if (rv < 0) {
        logging.warn("genTileAccessor: readAccessorSamples error {d} at time {d:.2}", .{ rv, tile_start_time });
        return null;
    }
    if (rv == 0) {
        // No audio at this position - return empty tile
        logging.info("genTileAccessor: no audio at time {d:.2}", .{tile_start_time});
        return null;
    }

    // Compute peaks from samples
    var tile = peaks_tile.CachedTile.empty();

    // Initialize min/max for accumulation
    var peak_min: [peaks_tile.MAX_PEAKS_PER_TILE * 2]f64 = [_]f64{1.0} ** (peaks_tile.MAX_PEAKS_PER_TILE * 2);
    var peak_max: [peaks_tile.MAX_PEAKS_PER_TILE * 2]f64 = [_]f64{-1.0} ** (peaks_tile.MAX_PEAKS_PER_TILE * 2);

    // Process samples into peaks (iterate over actual_samples read from accessor)
    for (0..actual_samples) |s| {
        const peak_idx = @min(s / samples_per_peak, num_peaks - 1);

        for (0..num_channels) |ch| {
            const sample = sample_buf[s * num_channels + ch];
            const idx = peak_idx * num_channels + ch;
            peak_max[idx] = @max(peak_max[idx], sample);
            peak_min[idx] = @min(peak_min[idx], sample);
        }
    }

    // Fix any peaks that weren't touched (still at init values)
    for (0..num_peaks * num_channels) |i| {
        if (peak_max[i] < peak_min[i]) {
            peak_max[i] = 0;
            peak_min[i] = 0;
        }
    }

    // Detect mono vs stereo by comparing L/R peaks
    const detected_channels: u8 = blk: {
        const epsilon = 0.0001;
        for (0..num_peaks) |p| {
            const max_l = peak_max[p * 2];
            const max_r = peak_max[p * 2 + 1];
            const min_l = peak_min[p * 2];
            const min_r = peak_min[p * 2 + 1];
            if (@abs(max_l - max_r) > epsilon or @abs(min_l - min_r) > epsilon) {
                break :blk 2; // Different L/R = true stereo
            }
        }
        break :blk 1; // All L/R identical = mono
    };

    // Copy to tile
    const copy_len = num_peaks * num_channels;
    @memcpy(tile.peak_min[0..copy_len], peak_min[0..copy_len]);
    @memcpy(tile.peak_max[0..copy_len], peak_max[0..copy_len]);
    tile.num_peaks = @intCast(num_peaks);
    tile.channels = detected_channels;

    return TileGenerationResult{
        .tile = tile,
        .sample_rate = effective_sample_rate,
        .samples_read = actual_samples,
        .buffer_bytes = buffer_bytes,
    };
}

/// Generate tiles for all items in a subscription's viewport.
/// Returns a JSON event string with tile-based format.
///
/// Event format:
/// {
///   "type": "event",
///   "event": "peaks",
///   "payload": {
///     "tiles": [
///       { "takeGuid": "...", "epoch": 1, "lod": 2, "tileIndex": 5, ... }
///     ]
///   }
/// }
pub fn generateTilesForSubscription(
    allocator: Allocator,
    api: anytype,
    guid_cache: *const guid_cache_mod.GuidCache,
    tile_cache: *peaks_tile.TileCache,
    sub: *const @import("peaks_subscriptions.zig").ClientSubscription,
) ?[]const u8 {
    // Must have viewport for tile-based generation
    if (!sub.hasViewport()) {
        logging.info("peaks_generator: no viewport for tile generation (start={d:.2}, end={d:.2}, width={d})", .{
            sub.viewport_start,
            sub.viewport_end,
            sub.viewport_width_px,
        });
        return null;
    }

    // Calculate tile range from viewport
    const tile_range = peaks_tile.tilesForViewport(
        sub.viewport_start,
        sub.viewport_end,
        sub.viewport_width_px,
        0.5, // 50% buffer each side
    ) orelse {
        logging.warn("peaks_generator: invalid viewport for tiles", .{});
        return null;
    };

    // Collect track indices from subscription
    var track_indices_buf: [MAX_TRACKS_PER_BROADCAST]c_int = undefined;
    var track_count: usize = 0;

    switch (sub.mode) {
        .none => return null,
        .range => {
            const total_tracks = api.trackCount();
            var idx = sub.range_start;
            const end = @min(sub.range_end, total_tracks);
            while (idx <= end and track_count < MAX_TRACKS_PER_BROADCAST) : (idx += 1) {
                track_indices_buf[track_count] = idx;
                track_count += 1;
            }
        },
        .guids => {
            for (0..sub.guid_count) |i| {
                if (track_count >= MAX_TRACKS_PER_BROADCAST) break;
                const guid = sub.getGuid(i) orelse continue;
                const track = guid_cache.resolve(guid) orelse continue;
                const idx = api.getTrackIdx(track);
                if (idx >= 0) {
                    track_indices_buf[track_count] = idx;
                    track_count += 1;
                }
            }
        },
    }

    if (track_count == 0) {
        logging.info("peaks_generator: track_count is 0", .{});
        return null;
    }

    // Start timing the entire operation
    const func_start_ns = std.time.nanoTimestamp();

    // Initialize comprehensive metrics
    var metrics = SubscriptionMetrics.init(
        tile_range.lod,
        sub.viewport_start,
        sub.viewport_end,
        sub.viewport_width_px,
    );
    metrics.tracks_processed = track_count;
    metrics.cache_size_before = tile_cache.count();

    logging.info("peaks_generator: processing {d} tracks, lod={d}", .{ track_count, tile_range.lod });

    // Estimate buffer size for JSON
    // Each tile is ~2-6KB depending on peak count. Start with reasonable fixed size.
    // For a typical viewport with 10-50 tiles, 512KB is plenty.
    // The scratch arena is ~10MB so we have headroom.
    const initial_buf_size: usize = 512 * 1024; // 512KB
    metrics.json_buffer_bytes = initial_buf_size;
    const buf = allocator.alloc(u8, initial_buf_size) catch {
        logging.warn("peaks_generator: failed to allocate tile JSON buffer ({d} bytes)", .{initial_buf_size});
        return null;
    };
    errdefer allocator.free(buf);

    var stream = std.io.fixedBufferStream(buf);
    var w = stream.writer();

    // Write event envelope
    const json_start_ns = std.time.nanoTimestamp();
    w.writeAll("{\"type\":\"event\",\"event\":\"peaks\",\"payload\":{\"tiles\":[") catch {
        logging.warn("peaks_generator: failed to write tile JSON header", .{});
        return null;
    };

    var tiles_written: usize = 0;
    const config = peaks_tile.TILE_CONFIGS[tile_range.lod];

    for (track_indices_buf[0..track_count]) |track_idx| {
        const track = api.getTrackByUnifiedIdx(track_idx) orelse {
            logging.info("peaks_generator: track {} not found via getTrackByUnifiedIdx", .{track_idx});
            continue;
        };

        const item_count_raw = api.trackItemCount(track);
        if (item_count_raw <= 0) {
            logging.info("peaks_generator: track {} has no items", .{track_idx});
            continue;
        }

        const max_items: c_int = @min(item_count_raw, MAX_ITEMS_PER_TRACK_MULTITRACK);

        // Process each item
        var i: c_int = 0;
        while (i < max_items) : (i += 1) {
            const item = api.getItemByIdx(track, i) orelse continue;
            const take = api.getItemActiveTake(item) orelse continue;

            if (api.isTakeMIDI(take)) continue;

            const item_position = api.getItemPosition(item);
            const item_length = api.getItemLength(item);

            if (!ffi.isFinite(item_length) or item_length <= 0) continue;

            metrics.items_checked += 1;

            // Check if item overlaps viewport (with buffer)
            const buffer = (sub.viewport_end - sub.viewport_start) * 0.5;
            const viewport_start_buffered = sub.viewport_start - buffer;
            const viewport_end_buffered = sub.viewport_end + buffer;

            if (item_position + item_length < viewport_start_buffered or
                item_position > viewport_end_buffered)
            {
                continue; // Item outside viewport
            }

            metrics.items_in_viewport += 1;
            logging.debug("peaks_generator: item pos={d:.1} len={d:.1} in viewport [{d:.1},{d:.1}]", .{
                item_position, item_length, viewport_start_buffered, viewport_end_buffered,
            });

            // Get take GUID for cache key
            var take_guid_buf: [64]u8 = undefined;
            const take_guid = api.getTakeGUID(take, &take_guid_buf);

            // Get epoch for this take
            const epoch = tile_cache.getEpoch(take_guid, api, take);

            // Calculate which tiles cover this item within the viewport range
            const item_start_tile: u32 = blk: {
                if (item_position <= 0) break :blk 0;
                const relative_start = @max(0.0, viewport_start_buffered - item_position);
                break :blk @intFromFloat(@floor(relative_start / config.duration));
            };

            const item_end_tile: u32 = blk: {
                const relative_end = @min(item_length, viewport_end_buffered - item_position);
                if (relative_end <= 0) break :blk 0;
                break :blk @intFromFloat(@ceil(relative_end / config.duration));
            };

            logging.debug("peaks_generator: tile range [{d},{d}] for item, duration={d:.1}", .{
                item_start_tile, item_end_tile, config.duration,
            });

            // Per-item metrics for detailed logging
            var item_tiles_cached: usize = 0;
            var item_tiles_generated: usize = 0;
            var item_tiles_failed: usize = 0;
            var item_gen_time_ns: u64 = 0;
            var item_fetch_time_ns: u64 = 0; // Time to fetch viewport peaks via API
            var item_peak_buffer_bytes: usize = 0;

            // Fetch viewport portion of item peaks lazily on first cache miss.
            // Uses GetMediaItemTake_Peaks API which reads from pre-computed .reapeaks mipmaps.
            // We only fetch the tiles needed for current viewport, not the entire item.
            var item_peaks_result: ?ItemPeaksResult = null;
            defer if (item_peaks_result) |*ipr| ipr.deinit();
            var first_fetched_tile: u32 = 0; // Track tile offset for slicing

            // Generate tiles for this item
            var tile_idx = item_start_tile;
            while (tile_idx <= item_end_tile and tile_idx < 10000) : (tile_idx += 1) {
                const key = peaks_tile.TileCacheKey.create(take_guid, epoch, tile_range.lod, tile_idx);

                // Try cache first
                var tile_ptr: ?*peaks_tile.CachedTile = tile_cache.get(key);

                if (tile_ptr != null) {
                    metrics.tiles_cached += 1;
                    item_tiles_cached += 1;
                } else {
                    // Generate if not cached
                    metrics.tiles_generated += 1;
                    item_tiles_generated += 1;

                    // Fetch viewport portion of item peaks lazily on first cache miss
                    if (item_peaks_result == null) {
                        const fetch_start = std.time.nanoTimestamp();

                        // Calculate fetch bounds: only tiles in viewport, not entire item
                        // This is critical for high LODs where entire item would be millions of peaks
                        const fetch_start_time = item_position + @as(f64, @floatFromInt(item_start_tile)) * config.duration;
                        const fetch_end_time = @min(
                            item_position + item_length,
                            item_position + @as(f64, @floatFromInt(item_end_tile + 1)) * config.duration,
                        );
                        const fetch_duration = fetch_end_time - fetch_start_time;
                        first_fetched_tile = item_start_tile;

                        // Convert unified track index (0=master, 1+=regular) to 0-based regular track index
                        if (g_lua_bridge_fn != null and track_idx > 0) {
                            const lua_track_idx: c_int = track_idx - 1; // Convert to 0-based
                            item_peaks_result = fetchItemPeaksViaLuaBridge(
                                allocator,
                                lua_track_idx,
                                i,
                                fetch_start_time,
                                fetch_duration,
                                config.peakrate,
                            );
                        }

                        const fetch_end = std.time.nanoTimestamp();
                        const fetch_ns: u64 = @intCast(@max(0, fetch_end - fetch_start));
                        item_fetch_time_ns = fetch_ns;
                        metrics.accessor_time_ns += fetch_ns;

                        if (item_peaks_result == null) {
                            logging.warn("peaks_generator: failed to fetch peaks via Lua bridge", .{});
                            break; // Skip remaining tiles for this item
                        }

                        // Track buffer size for metrics
                        item_peak_buffer_bytes = item_peaks_result.?.num_peaks * item_peaks_result.?.channels * @sizeOf(f64) * 2;
                        metrics.peak_buffer_bytes = @max(metrics.peak_buffer_bytes, item_peak_buffer_bytes);
                    }

                    // Time the tile slicing
                    const gen_start = std.time.nanoTimestamp();

                    // Slice tile from fetched peaks (adjust index since we only fetched viewport portion)
                    const relative_tile_idx = tile_idx - first_fetched_tile;
                    const tile = sliceTileFromItemPeaks(&item_peaks_result.?, relative_tile_idx, config.peaks_per_tile);

                    const gen_end = std.time.nanoTimestamp();
                    const this_tile_ns: u64 = @intCast(@max(0, gen_end - gen_start));
                    metrics.gen_time_ns += this_tile_ns;
                    item_gen_time_ns += this_tile_ns;

                    // Track min/max tile generation time
                    if (this_tile_ns < metrics.min_tile_gen_ns) metrics.min_tile_gen_ns = this_tile_ns;
                    if (this_tile_ns > metrics.max_tile_gen_ns) metrics.max_tile_gen_ns = this_tile_ns;

                    if (tile.num_peaks > 0) {
                        tile_cache.put(
                            key,
                            tile.peak_min[0 .. tile.num_peaks * tile.channels],
                            tile.peak_max[0 .. tile.num_peaks * tile.channels],
                            tile.num_peaks,
                            tile.channels,
                        );
                        tile_ptr = tile_cache.get(key);
                    } else {
                        metrics.tiles_failed += 1;
                        item_tiles_failed += 1;
                        // Undo the tiles_generated increment since tile was empty
                        if (metrics.tiles_generated > 0) metrics.tiles_generated -= 1;
                        if (item_tiles_generated > 0) item_tiles_generated -= 1;
                    }
                }

                const tile = tile_ptr orelse continue;

                // Write tile JSON
                if (tiles_written > 0) w.writeByte(',') catch {
                    logging.warn("peaks_generator: failed to write tile separator", .{});
                    return null;
                };

                const tile_start = @as(f64, @floatFromInt(tile_idx)) * config.duration;
                const tile_end = tile_start + config.duration;

                w.print("{{\"takeGuid\":\"{s}\",\"epoch\":{d},\"lod\":{d},\"tileIndex\":{d}", .{
                    take_guid,
                    epoch,
                    tile_range.lod,
                    tile_idx,
                }) catch {
                    logging.warn("peaks_generator: failed to write tile header", .{});
                    return null;
                };

                w.print(",\"itemPosition\":{d:.6},\"startTime\":{d:.6},\"endTime\":{d:.6}", .{
                    item_position,
                    tile_start,
                    tile_end,
                }) catch {
                    logging.warn("peaks_generator: failed to write tile times", .{});
                    return null;
                };

                w.print(",\"channels\":{d},\"peaks\":[", .{tile.channels}) catch {
                    logging.warn("peaks_generator: failed to write tile channels", .{});
                    return null;
                };

                // Write peaks array
                for (0..tile.num_peaks) |p| {
                    if (p > 0) w.writeByte(',') catch return null;

                    if (tile.channels == 2) {
                        const min_l = tile.peak_min[p * 2];
                        const max_l = tile.peak_max[p * 2];
                        const min_r = tile.peak_min[p * 2 + 1];
                        const max_r = tile.peak_max[p * 2 + 1];
                        w.print("{{\"l\":[{d:.4},{d:.4}],\"r\":[{d:.4},{d:.4}]}}", .{
                            min_l, max_l, min_r, max_r,
                        }) catch return null;
                    } else {
                        const min_val = tile.peak_min[p];
                        const max_val = tile.peak_max[p];
                        w.print("[{d:.4},{d:.4}]", .{ min_val, max_val }) catch return null;
                    }
                }

                w.writeAll("]}") catch return null;
                tiles_written += 1;
                metrics.tiles_total += 1;
            }

            // Log per-item metrics if any tiles were processed
            const item_total_tiles = item_tiles_cached + item_tiles_generated;
            if (item_total_tiles > 0) {
                const item_fetch_us = @as(f64, @floatFromInt(item_fetch_time_ns)) / 1000.0;
                const item_gen_us = @as(f64, @floatFromInt(item_gen_time_ns)) / 1000.0;
                const item_avg_us = if (item_tiles_generated > 0) item_gen_us / @as(f64, @floatFromInt(item_tiles_generated)) else 0.0;

                logging.debug("  item: tiles={d} (cached={d} gen={d} fail={d}) fetch={d:.0}us gen={d:.0}us avg={d:.1}us/tile buf={d}B", .{
                    item_total_tiles,
                    item_tiles_cached,
                    item_tiles_generated,
                    item_tiles_failed,
                    item_fetch_us,
                    item_gen_us,
                    item_avg_us,
                    item_peak_buffer_bytes,
                });
            }
        }
    }

    // Close JSON envelope and track JSON time
    w.writeAll("]}}") catch {
        logging.warn("peaks_generator: failed to close tile JSON", .{});
        return null;
    };
    const json_end_ns = std.time.nanoTimestamp();
    metrics.json_time_ns = @intCast(@max(0, json_end_ns - json_start_ns));

    // Finalize metrics
    const func_end_ns = std.time.nanoTimestamp();
    metrics.total_time_ns = @intCast(@max(0, func_end_ns - func_start_ns));
    metrics.cache_size_after = tile_cache.count();

    if (tiles_written == 0) {
        logging.info("peaks_generator: tiles_written=0 (checked={d}, in_viewport={d}, cached={d}, generated={d}, failed={d})", .{
            metrics.items_checked,
            metrics.items_in_viewport,
            metrics.tiles_cached,
            metrics.tiles_generated,
            metrics.tiles_failed,
        });
        allocator.free(buf);
        return null;
    }

    // Log comprehensive performance metrics
    metrics.logSummary();

    // Shrink to actual size
    const written = stream.getWritten();
    const result = allocator.realloc(buf, written.len) catch buf;
    return result[0..written.len];
}

/// Generate peaks for a single item using REAPER's GetMediaItemTake_Peaks API.
/// This uses REAPER's pre-computed .reapeaks mipmaps for faster peak retrieval.
/// REAPER automatically selects the appropriate mipmap tier based on peakrate:
///   - ~400 peaks/sec (finest)
///   - ~10 peaks/sec (medium)
///   - ~1 peak/sec (coarse)
/// We request exactly what we need and let REAPER handle LOD selection.
/// Populates peak_min, peak_max, and channels in item_peaks.
/// Returns true on success.
fn generatePeaksForItem(
    allocator: Allocator,
    api: anytype,
    take: *anyopaque,
    length: f64,
    num_peaks: usize,
    item_peaks: *ItemPeaks,
) bool {
    // Get source to determine channel count
    const source = api.getTakeSource(take) orelse {
        logging.warn("peaks_generator: failed to get take source", .{});
        return false;
    };

    // Get actual channel count from source (1=mono, 2=stereo, etc.)
    const source_channels = api.getMediaSourceChannels(source);
    if (source_channels <= 0) {
        logging.debug("peaks_generator: invalid channel count {d}", .{source_channels});
        return false;
    }

    // Request up to 2 channels (we don't support more than stereo in the output)
    const num_channels: usize = @min(@as(usize, @intCast(source_channels)), 2);

    // Calculate peakrate to get exactly num_peaks covering the full item length.
    // REAPER will automatically select the appropriate mipmap tier.
    const peakrate: f64 = @as(f64, @floatFromInt(num_peaks)) / length;

    // Buffer for REAPER's output (channel-interleaved within max/min blocks)
    // Size = num_channels * num_peaks * 2 (max block + min block)
    const buf_size = num_channels * num_peaks * 2;
    const reaper_buf = allocator.alloc(f64, buf_size) catch {
        logging.warn("peaks_generator: failed to allocate {d} bytes for peak buffer", .{buf_size * 8});
        return false;
    };
    defer allocator.free(reaper_buf);

    // GetMediaItemTake_Peaks expects starttime in PROJECT time (timeline position).
    const item_position = item_peaks.position;

    // Call REAPER's GetMediaItemTake_Peaks
    const result = api.getMediaItemTakePeaks(
        take,
        peakrate,
        item_position, // Project timeline position
        @intCast(num_channels),
        @intCast(num_peaks),
        reaper_buf,
    );

    // Parse return value: sample_count in low 20 bits, mode in bits 20-23
    const actual_peaks: usize = @intCast(result & 0xFFFFF);
    // NOTE: mode=0 is VALID (interpolated data from coarser mipmap), NOT an error!
    // mode=1+ means native resolution. Only check actual_peaks for failure.
    _ = @as(u4, @intCast((result >> 20) & 0xF)); // mode (unused - both 0 and 1 are valid)

    if (actual_peaks == 0) {
        logging.debug("peaks_generator: no peaks returned from REAPER", .{});
        return false;
    }

    // Debug: log request vs actual to verify coverage
    if (actual_peaks >= 3) {
        logging.debug("peaks_generator: requested {d} peaks at {d:.2}/sec, got {d}", .{
            num_peaks,
            peakrate,
            actual_peaks,
        });
    }

    // Parse REAPER's buffer directly - no downsampling needed
    // REAPER format (channel-interleaved within blocks):
    //   Block 1 (Maximums): [L_max_0, R_max_0, L_max_1, R_max_1, ...]
    //   Block 2 (Minimums): [L_min_0, R_min_0, L_min_1, R_min_1, ...]
    const peaks_to_use = @min(actual_peaks, num_peaks);
    parseReaperPeaks(reaper_buf, peaks_to_use, num_channels, item_peaks);

    // Zero out any remaining peaks if we got fewer than requested
    for (peaks_to_use..num_peaks) |p| {
        for (0..num_channels) |ch| {
            const idx = p * num_channels + ch;
            item_peaks.peak_max[idx] = 0;
            item_peaks.peak_min[idx] = 0;
        }
    }

    // Detect actual channel count by comparing L/R peaks (for mono detection)
    const detected_channels: usize = blk: {
        if (num_channels == 1) break :blk 1;
        const epsilon = 0.0001;
        for (0..num_peaks) |p| {
            const max_l = item_peaks.peak_max[p * 2];
            const max_r = item_peaks.peak_max[p * 2 + 1];
            const min_l = item_peaks.peak_min[p * 2];
            const min_r = item_peaks.peak_min[p * 2 + 1];
            if (@abs(max_l - max_r) > epsilon or @abs(min_l - min_r) > epsilon) {
                break :blk 2; // Different L/R = true stereo
            }
        }
        break :blk 1; // All L/R identical = mono
    };

    item_peaks.channels = detected_channels;
    item_peaks.num_peaks = num_peaks;
    return true;
}

/// Parse REAPER's peak buffer format into our ItemPeaks format.
/// REAPER format (per GETMEDIAITEM_TAKE_PEAKS_API.md):
///   Block 1 (Maximums): [ch0_max_0, ch1_max_0, ch0_max_1, ch1_max_1, ...] (channel-interleaved)
///   Block 2 (Minimums): [ch0_min_0, ch1_min_0, ch0_min_1, ch1_min_1, ...] (channel-interleaved)
/// Our format: peak_min[peak_idx * channels + ch], peak_max[peak_idx * channels + ch]
fn parseReaperPeaks(
    buf: []f64,
    num_peaks: usize,
    num_channels: usize,
    item_peaks: *ItemPeaks,
) void {
    const block_size = num_peaks * num_channels;
    for (0..num_peaks) |p| {
        for (0..num_channels) |ch| {
            const our_idx = p * num_channels + ch;
            // REAPER layout: channels interleaved within each block
            // Block 1 = maximums, Block 2 = minimums
            const max_offset = p * num_channels + ch;
            const min_offset = block_size + p * num_channels + ch;
            item_peaks.peak_max[our_idx] = buf[max_offset];
            item_peaks.peak_min[our_idx] = buf[min_offset];
        }
    }
}

// =============================================================================
// Tests
// =============================================================================

test "parseReaperPeaks mono" {
    // REAPER format for mono (1 channel), 3 peaks:
    // [max0, max1, max2, min0, min1, min2]
    var reaper_buf = [_]f64{
        0.8, 0.6, 0.4, // max values for channel 0
        -0.3, -0.5, -0.2, // min values for channel 0
    };

    var item_peaks = ItemPeaks{
        .item_guid = undefined,
        .item_guid_len = 0,
        .track_idx = 0,
        .item_idx = 0,
        .position = 0,
        .length = 1.0,
        .peak_min = [_]f64{1.0} ** (MAX_PEAKS_PER_ITEM * 2),
        .peak_max = [_]f64{-1.0} ** (MAX_PEAKS_PER_ITEM * 2),
        .num_peaks = 3,
        .channels = 1,
    };

    parseReaperPeaks(&reaper_buf, 3, 1, &item_peaks);

    // Our format: peak_max[peak_idx], peak_min[peak_idx]
    try std.testing.expectApproxEqAbs(item_peaks.peak_max[0], 0.8, 0.001);
    try std.testing.expectApproxEqAbs(item_peaks.peak_max[1], 0.6, 0.001);
    try std.testing.expectApproxEqAbs(item_peaks.peak_max[2], 0.4, 0.001);
    try std.testing.expectApproxEqAbs(item_peaks.peak_min[0], -0.3, 0.001);
    try std.testing.expectApproxEqAbs(item_peaks.peak_min[1], -0.5, 0.001);
    try std.testing.expectApproxEqAbs(item_peaks.peak_min[2], -0.2, 0.001);
}

test "parseReaperPeaks stereo" {
    // REAPER format for stereo (2 channels), 2 peaks (per GETMEDIAITEM_TAKE_PEAKS_API.md):
    // Block 1 (Maximums): [L_max0, R_max0, L_max1, R_max1] (channel-interleaved)
    // Block 2 (Minimums): [L_min0, R_min0, L_min1, R_min1] (channel-interleaved)
    var reaper_buf = [_]f64{
        0.7, 0.9, 0.5, 0.6, // max values interleaved: L0, R0, L1, R1
        -0.4, -0.8, -0.2, -0.5, // min values interleaved: L0, R0, L1, R1
    };

    var item_peaks = ItemPeaks{
        .item_guid = undefined,
        .item_guid_len = 0,
        .track_idx = 0,
        .item_idx = 0,
        .position = 0,
        .length = 1.0,
        .peak_min = [_]f64{1.0} ** (MAX_PEAKS_PER_ITEM * 2),
        .peak_max = [_]f64{-1.0} ** (MAX_PEAKS_PER_ITEM * 2),
        .num_peaks = 2,
        .channels = 2,
    };

    parseReaperPeaks(&reaper_buf, 2, 2, &item_peaks);

    // Our format: peak_max[peak_idx * 2 + ch], peak_min[peak_idx * 2 + ch]
    // Peak 0: L at [0], R at [1]
    // Peak 1: L at [2], R at [3]
    try std.testing.expectApproxEqAbs(item_peaks.peak_max[0], 0.7, 0.001); // Peak 0, L max
    try std.testing.expectApproxEqAbs(item_peaks.peak_max[1], 0.9, 0.001); // Peak 0, R max
    try std.testing.expectApproxEqAbs(item_peaks.peak_max[2], 0.5, 0.001); // Peak 1, L max
    try std.testing.expectApproxEqAbs(item_peaks.peak_max[3], 0.6, 0.001); // Peak 1, R max
    try std.testing.expectApproxEqAbs(item_peaks.peak_min[0], -0.4, 0.001); // Peak 0, L min
    try std.testing.expectApproxEqAbs(item_peaks.peak_min[1], -0.8, 0.001); // Peak 0, R min
    try std.testing.expectApproxEqAbs(item_peaks.peak_min[2], -0.2, 0.001); // Peak 1, L min
    try std.testing.expectApproxEqAbs(item_peaks.peak_min[3], -0.5, 0.001); // Peak 1, R min
}
