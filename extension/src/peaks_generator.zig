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
/// Returns CachedTile on success, null on failure.
pub fn generateTileViaAccessor(
    allocator: Allocator,
    api: anytype,
    take: *anyopaque,
    tile_start_time: f64,
    tile_duration: f64,
    num_peaks: usize,
) ?peaks_tile.CachedTile {
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
/// Returns CachedTile on success, null on failure.
fn generateTileWithAccessor(
    allocator: Allocator,
    api: anytype,
    accessor: *anyopaque,
    tile_start_time: f64,
    tile_duration: f64,
    num_peaks: usize,
) ?peaks_tile.CachedTile {
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

    // Allocate sample buffer on heap (stereo interleaved)
    const sample_buf = allocator.alloc(f64, actual_samples * num_channels) catch {
        logging.warn("genTileAccessor: failed to allocate {d} bytes for samples", .{actual_samples * num_channels * 8});
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

    return tile;
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
    logging.info("peaks_generator: processing {d} tracks, lod={d}", .{ track_count, tile_range.lod });

    // Estimate buffer size for JSON
    // Each tile is ~2-6KB depending on peak count. Start with reasonable fixed size.
    // For a typical viewport with 10-50 tiles, 512KB is plenty.
    // The scratch arena is ~10MB so we have headroom.
    const initial_buf_size: usize = 512 * 1024; // 512KB
    const buf = allocator.alloc(u8, initial_buf_size) catch {
        logging.warn("peaks_generator: failed to allocate tile JSON buffer ({d} bytes)", .{initial_buf_size});
        return null;
    };
    errdefer allocator.free(buf);

    var stream = std.io.fixedBufferStream(buf);
    var w = stream.writer();

    // Write event envelope
    w.writeAll("{\"type\":\"event\",\"event\":\"peaks\",\"payload\":{\"tiles\":[") catch {
        logging.warn("peaks_generator: failed to write tile JSON header", .{});
        return null;
    };

    var tiles_written: usize = 0;
    const config = peaks_tile.TILE_CONFIGS[tile_range.lod];

    // Metrics for cache performance and timing
    var items_checked: usize = 0;
    var items_in_viewport: usize = 0;
    var cache_hits: usize = 0;
    var cache_misses: usize = 0;
    var tile_gen_failures: usize = 0;
    var gen_time_ns: u64 = 0; // Total time spent generating tiles

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

            items_checked += 1;

            // Check if item overlaps viewport (with buffer)
            const buffer = (sub.viewport_end - sub.viewport_start) * 0.5;
            const viewport_start_buffered = sub.viewport_start - buffer;
            const viewport_end_buffered = sub.viewport_end + buffer;

            if (item_position + item_length < viewport_start_buffered or
                item_position > viewport_end_buffered)
            {
                continue; // Item outside viewport
            }

            items_in_viewport += 1;
            logging.info("peaks_generator: item pos={d:.1} len={d:.1} in viewport [{d:.1},{d:.1}]", .{
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

            logging.info("peaks_generator: tile range [{d},{d}] for item, duration={d:.1}", .{
                item_start_tile, item_end_tile, config.duration,
            });

            // Create AudioAccessor ONCE for this take, reuse for all tiles.
            // This is a significant optimization - creating an accessor is expensive.
            // We create it lazily only if there are uncached tiles to generate.
            var accessor: ?*anyopaque = null;
            defer if (accessor) |acc| api.destroyTakeAccessor(acc);

            // Generate tiles for this item
            var tile_idx = item_start_tile;
            while (tile_idx <= item_end_tile and tile_idx < 10000) : (tile_idx += 1) {
                const key = peaks_tile.TileCacheKey.create(take_guid, epoch, tile_range.lod, tile_idx);

                // Try cache first
                var tile_ptr: ?*peaks_tile.CachedTile = tile_cache.get(key);

                if (tile_ptr != null) {
                    cache_hits += 1;
                } else {
                    // Generate if not cached
                    cache_misses += 1;

                    // Create accessor lazily on first cache miss
                    if (accessor == null) {
                        accessor = api.makeTakeAccessor(take);
                        if (accessor == null) {
                            logging.warn("peaks_generator: failed to create accessor for take", .{});
                            break; // Skip remaining tiles for this item
                        }
                    }

                    // Calculate tile time range (relative to item start)
                    const tile_start_relative = @as(f64, @floatFromInt(tile_idx)) * config.duration;

                    // Skip tiles that start past the item end (can happen due to ceil in tile range calc)
                    if (tile_start_relative >= item_length) {
                        tile_gen_failures += 1;
                        continue;
                    }

                    const tile_end_relative = tile_start_relative + config.duration;
                    const clamped_end = @min(tile_end_relative, item_length);
                    const tile_duration = clamped_end - tile_start_relative;

                    // Time the tile generation
                    const gen_start = std.time.nanoTimestamp();

                    // Use AudioAccessor for ALL LODs.
                    // GetMediaItemTake_Peaks via GetFunc() is broken on ARM64 macOS -
                    // even with low peakrate it returns 0 peaks. AudioAccessor works reliably.
                    const maybe_tile: ?peaks_tile.CachedTile = generateTileWithAccessor(
                        allocator,
                        api,
                        accessor.?,
                        tile_start_relative, // Relative to item/take start
                        tile_duration,
                        config.peaks_per_tile,
                    );

                    const gen_end = std.time.nanoTimestamp();
                    gen_time_ns += @intCast(@max(0, gen_end - gen_start));

                    if (maybe_tile) |tile| {
                        tile_cache.put(
                            key,
                            tile.peak_min[0 .. tile.num_peaks * tile.channels],
                            tile.peak_max[0 .. tile.num_peaks * tile.channels],
                            tile.num_peaks,
                            tile.channels,
                        );
                        tile_ptr = tile_cache.get(key);
                    } else {
                        tile_gen_failures += 1;
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
            }
        }
    }

    // Close JSON envelope
    w.writeAll("]}}") catch {
        logging.warn("peaks_generator: failed to close tile JSON", .{});
        return null;
    };

    if (tiles_written == 0) {
        logging.info("peaks_generator: tiles_written=0 (checked={d}, in_viewport={d}, hits={d}, misses={d}, failures={d})", .{
            items_checked, items_in_viewport, cache_hits, cache_misses, tile_gen_failures,
        });
        allocator.free(buf);
        return null;
    }

    // Log performance metrics
    const total_tiles = cache_hits + cache_misses;
    const hit_rate: f64 = if (total_tiles > 0) @as(f64, @floatFromInt(cache_hits)) / @as(f64, @floatFromInt(total_tiles)) * 100.0 else 0.0;
    const gen_time_ms = @as(f64, @floatFromInt(gen_time_ns)) / 1_000_000.0;
    const avg_gen_ms = if (cache_misses > 0) gen_time_ms / @as(f64, @floatFromInt(cache_misses)) else 0.0;

    logging.info("peaks_generator: LOD{d} tiles={d} hits={d} misses={d} ({d:.0}% hit rate) gen={d:.1}ms (avg {d:.2}ms/tile)", .{
        tile_range.lod,
        tiles_written,
        cache_hits,
        cache_misses,
        hit_rate,
        gen_time_ms,
        avg_gen_ms,
    });

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
