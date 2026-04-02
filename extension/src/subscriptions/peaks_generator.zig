/// Peaks Generator - Generate binary tile-based waveform peaks for subscribed clients.
///
/// Uses REAPER's GetMediaItemTake_Peaks API to fetch pre-computed .reapeaks mipmap data,
/// slices into tiles, caches in TileCache, and serializes as binary int8 quantized format.
///
/// Primary API:
/// - generateTilesForSubscriptionBinary: Binary tile generation (with viewport)
const std = @import("std");
const logging = @import("../core/logging.zig");
const ffi = @import("../core/ffi.zig");
const guid_cache_mod = @import("../state/guid_cache.zig");
const peaks_tile = @import("../state/peaks_tile.zig");
const binary_protocol = @import("../core/binary_protocol.zig");

const Allocator = std.mem.Allocator;

/// Maximum tracks in a single subscription broadcast.
const MAX_TRACKS_PER_BROADCAST = 32;

/// Maximum items per track in multi-track mode (smaller than single-track to limit stack usage).
const MAX_ITEMS_PER_TRACK_MULTITRACK = 64;

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
        logging.warn("peaks_generator: failed to get take source", .{});
        return null;
    };

    const source_channels = api.getMediaSourceChannels(source);
    if (source_channels <= 0) {
        logging.debug("peaks_generator: invalid channel count {d}", .{source_channels});
        return null;
    }

    // Request up to 2 channels (we don't support more than stereo in the output)
    const actual_channels: usize = @min(@as(usize, @intCast(source_channels)), 2);
    // Always request 2 channels from REAPER (it always writes 2 even for mono sources on some platforms)
    const request_channels: usize = 2;

    // Calculate number of peaks
    const num_peaks: usize = @intFromFloat(@ceil(item_length * peakrate));
    if (num_peaks == 0) return null;
    if (num_peaks > peaks_tile.MAX_PEAKS_PER_TILE * 100) {
        logging.warn("peaks_generator: too many peaks requested: {d}", .{num_peaks});
        return null;
    }

    // Buffer for REAPER's output
    const buf_size = request_channels * num_peaks * 2; // max block + min block
    const reaper_buf = allocator.alloc(f64, buf_size) catch {
        logging.warn("peaks_generator: failed to allocate peak buffer ({d} bytes)", .{buf_size * 8});
        return null;
    };
    defer allocator.free(reaper_buf);

    // GetMediaItemTake_Peaks
    const result = api.getMediaItemTakePeaks(
        take,
        peakrate,
        item_position,
        @intCast(request_channels),
        @intCast(num_peaks),
        reaper_buf,
    );

    const actual_peaks: usize = @intCast(result & 0xFFFFF);
    _ = @as(u4, @intCast((result >> 20) & 0xF)); // mode (unused - both 0 and 1 are valid)

    if (actual_peaks == 0) {
        logging.debug("peaks_generator: no peaks returned from REAPER", .{});
        return null;
    }

    const peaks_to_use = @min(actual_peaks, num_peaks);

    // Allocate output buffers
    const data_size = peaks_to_use * actual_channels;
    const peak_min = allocator.alloc(f64, data_size) catch return null;
    errdefer allocator.free(peak_min);

    const peak_max = allocator.alloc(f64, data_size) catch {
        allocator.free(peak_min);
        return null;
    };

    const num_channels = actual_channels;

    // Copy from REAPER buffer to our format
    // REAPER writes request_channels (always 2), we extract actual_channels (1 or 2)
    // Use actual_peaks (not num_peaks) for min block offset — REAPER only writes
    // actual_peaks worth of data, so the min block starts at actual_peaks * request_channels.
    const reaper_block_size = actual_peaks * request_channels;
    for (0..peaks_to_use) |p| {
        for (0..actual_channels) |ch| {
            const dst_idx = p * actual_channels + ch;
            const src_idx = p * request_channels + ch;
            const max_offset = src_idx;
            const min_offset = reaper_block_size + src_idx;
            peak_max[dst_idx] = reaper_buf[max_offset];
            peak_min[dst_idx] = reaper_buf[min_offset];
        }
    }

    return ItemPeaksResult{
        .peak_min = peak_min,
        .peak_max = peak_max,
        .num_peaks = peaks_to_use,
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

    // Use source channel count directly — don't collapse stereo silence to mono.
    // Per-tile L/R comparison caused visual glitches: stereo tracks showed centered
    // single-lane rendering in silence regions instead of proper stereo two-lane layout.
    tile.num_peaks = @intCast(num_peaks);
    tile.channels = @intCast(channels);

    return tile;
}

// =============================================================================
// Binary Tile Serialization
// =============================================================================

/// Generate tiles for all items in a subscription's viewport.
/// Serializes to binary int8 quantized format (~12x smaller than JSON).
/// Payload is ~1KB per stereo tile vs ~13KB JSON.
pub fn generateTilesForSubscriptionBinary(
    allocator: Allocator,
    api: anytype,
    guid_cache: *const guid_cache_mod.GuidCache,
    tile_cache: *peaks_tile.TileCache,
    sub: *const @import("peaks_subscriptions.zig").ClientSubscription,
) ?[]const u8 {
    if (!sub.hasViewport()) return null;

    const tile_range = peaks_tile.tilesForViewport(
        sub.viewport_start,
        sub.viewport_end,
        sub.viewport_width_px,
        0.5,
    ) orelse return null;

    // Collect track indices
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

    if (track_count == 0) return null;

    const config = peaks_tile.TILE_CONFIGS[tile_range.lod];
    const tiles_per_item = (tile_range.end_tile - tile_range.start_tile) + 1;
    const estimated_tiles = tiles_per_item * track_count;

    // Binary buffer: much smaller than JSON (~1KB per stereo tile vs ~13KB)
    const buf_size = binary_protocol.batchBufferSize(estimated_tiles, peaks_tile.MAX_PEAKS_PER_TILE, 2);
    const buf = allocator.alloc(u8, buf_size) catch {
        logging.warn("peaks_generator: failed to allocate binary tile buffer ({d} bytes)", .{buf_size});
        return null;
    };

    // Write envelope placeholder (tile_count filled in at end)
    var offset: usize = binary_protocol.BATCH_ENVELOPE_SIZE;
    var tiles_written: u16 = 0;

    for (track_indices_buf[0..track_count]) |track_idx| {
        const track = api.getTrackByUnifiedIdx(track_idx) orelse continue;
        const item_count_raw = api.trackItemCount(track);
        if (item_count_raw <= 0) continue;

        const max_items: c_int = @min(item_count_raw, MAX_ITEMS_PER_TRACK_MULTITRACK);

        var i: c_int = 0;
        while (i < max_items) : (i += 1) {
            const item = api.getItemByIdx(track, i) orelse continue;
            const take = api.getItemActiveTake(item) orelse continue;
            if (api.isTakeMIDI(take)) continue;

            const item_position = api.getItemPosition(item);
            const item_length = api.getItemLength(item);
            if (!ffi.isFinite(item_length) or item_length <= 0) continue;

            // Check viewport overlap
            const buffer_pct = (sub.viewport_end - sub.viewport_start) * 0.5;
            const vp_start = sub.viewport_start - buffer_pct;
            const vp_end = sub.viewport_end + buffer_pct;
            if (item_position + item_length < vp_start or item_position > vp_end) continue;

            var take_guid_buf: [64]u8 = undefined;
            const take_guid = api.getTakeGUID(take, &take_guid_buf);
            const epoch = tile_cache.getEpoch(take_guid, api, take);

            const item_start_tile: u32 = blk: {
                const rel = @max(0.0, vp_start - item_position);
                if (rel <= 0) break :blk 0;
                break :blk @intFromFloat(@floor(rel / config.duration));
            };
            const item_end_tile: u32 = blk: {
                const rel = @min(item_length, vp_end - item_position);
                if (rel <= 0) break :blk 0;
                break :blk @intFromFloat(@ceil(rel / config.duration));
            };

            // Lazy fetch for cache misses
            var item_peaks_result: ?ItemPeaksResult = null;
            defer if (item_peaks_result) |*ipr| ipr.deinit();
            var first_fetched_tile: u32 = 0;

            var tile_idx = item_start_tile;
            while (tile_idx <= item_end_tile and tile_idx < 10000) : (tile_idx += 1) {
                const key = peaks_tile.TileCacheKey.create(take_guid, epoch, tile_range.lod, tile_idx);
                var tile_ptr: ?*peaks_tile.CachedTile = tile_cache.get(key);

                if (tile_ptr == null) {
                    // Fetch and generate
                    if (item_peaks_result == null) {
                        const fetch_start_time = item_position + @as(f64, @floatFromInt(item_start_tile)) * config.duration;
                        const fetch_end_time = @min(
                            item_position + item_length,
                            item_position + @as(f64, @floatFromInt(item_end_tile + 1)) * config.duration,
                        );
                        first_fetched_tile = item_start_tile;

                        item_peaks_result = fetchItemPeaksViaTakePeaksAPI(
                            allocator, api, take,
                            fetch_start_time, fetch_end_time - fetch_start_time, config.peakrate,
                        );
                        if (item_peaks_result == null) break;
                    }

                    const relative_tile_idx = tile_idx - first_fetched_tile;
                    const tile = sliceTileFromItemPeaks(&item_peaks_result.?, relative_tile_idx, config.peaks_per_tile);

                    if (tile.num_peaks > 0) {
                        tile_cache.put(
                            key,
                            tile.peak_min[0 .. tile.num_peaks * tile.channels],
                            tile.peak_max[0 .. tile.num_peaks * tile.channels],
                            tile.num_peaks,
                            tile.channels,
                        );
                        tile_ptr = tile_cache.get(key);
                    }
                }

                const tile = tile_ptr orelse continue;

                // Check buffer space
                const peak_data_size = tile.num_peaks * tile.channels * 2;
                const tile_total = binary_protocol.TILE_FIXED_SIZE + peak_data_size;
                if (offset + tile_total > buf.len) {
                    logging.warn("peaks_generator: binary buffer overflow at tile {d} (need {d}, have {d})", .{
                        tiles_written, offset + tile_total, buf.len,
                    });
                    break;
                }

                // Write tile header
                const tile_start = @as(f64, @floatFromInt(tile_idx)) * config.duration;
                offset += binary_protocol.writeTileHeader(buf[offset..], .{
                    .lod_level = @intCast(tile_range.lod),
                    .channels = tile.channels,
                    .tile_index = @intCast(tile_idx),
                    .num_peaks = tile.num_peaks,
                    .epoch = epoch,
                    .start_time = @floatCast(tile_start),
                    .item_position = @floatCast(item_position),
                });

                // Write GUID
                offset += binary_protocol.writeGuid(buf[offset..], take_guid);

                // Write quantized peak data: i8 min, i8 max per channel per peak
                for (0..tile.num_peaks) |p| {
                    for (0..tile.channels) |ch| {
                        const idx = p * tile.channels + ch;
                        buf[offset] = @bitCast(binary_protocol.quantize(tile.peak_min[idx]));
                        offset += 1;
                        buf[offset] = @bitCast(binary_protocol.quantize(tile.peak_max[idx]));
                        offset += 1;
                    }
                }

                tiles_written += 1;
            }
        }
    }

    if (tiles_written == 0) {
        allocator.free(buf);
        return null;
    }

    // Write envelope at the start now that we know tile_count
    _ = binary_protocol.writeBatchEnvelope(buf, tiles_written);

    logging.info("peaks_generator: binary success tiles={d} size={d}KB (estimated={d}KB)", .{
        tiles_written,
        offset / 1024,
        buf_size / 1024,
    });

    // Shrink to actual size
    const result = allocator.realloc(buf, offset) catch buf;
    return result[0..offset];
}
