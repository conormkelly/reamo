/// Peaks Generator - Generate waveform peaks for all items on a track.
///
/// Used by the peaks subscription system to push peak data to subscribed clients.
/// Reuses AudioAccessor-based peak extraction from items.zig.
/// Supports optional caching via PeaksCache for performance.
///
/// Usage without caching:
///   const json = try generatePeaksForTrack(allocator, api, guid_cache, track_guid, 30, null);
///   defer allocator.free(json);
///   shared_state.sendToClient(client_id, json);
///
/// Usage with caching:
///   const json = try generatePeaksForTrackCached(allocator, api, guid_cache, peaks_cache, track_guid, 30, null);
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

/// Generate peaks for all audio items on a track.
///
/// Returns a JSON event string suitable for WebSocket broadcast.
/// Caller must free the returned string with the same allocator.
///
/// Parameters:
/// - allocator: Used for the returned JSON string
/// - api: Reaper backend (anytype for mock/real abstraction)
/// - cache: GuidCache for track resolution
/// - track_guid: Track GUID to generate peaks for
/// - sample_count: Number of peaks per item (typically 30)
/// - track_idx_out: Output for the resolved track index (or null if not needed)
///
/// Returns null if:
/// - Track not found
/// - No audio items on track
/// - All items are MIDI
pub fn generatePeaksForTrack(
    allocator: Allocator,
    api: anytype,
    cache: *const guid_cache_mod.GuidCache,
    track_guid: []const u8,
    sample_count: u32,
    track_idx_out: ?*c_int,
) ?[]const u8 {
    // Resolve track GUID to pointer
    const track = cache.resolve(track_guid) orelse {
        logging.debug("peaks_generator: track not found for GUID {s}", .{track_guid});
        return null;
    };

    // Get track index for response
    const track_idx = api.getTrackIdx(track);
    if (track_idx_out) |out| {
        out.* = track_idx;
    }

    // Count items on track
    const item_count = api.trackItemCount(track);
    if (item_count <= 0) {
        logging.debug("peaks_generator: no items on track {s}", .{track_guid});
        return null;
    }

    // Cap items for safety
    const max_items: c_int = @min(item_count, MAX_ITEMS_PER_TRACK);
    const num_peaks: usize = @min(@as(usize, sample_count), MAX_PEAKS_PER_ITEM);

    // Collect peaks for all audio items
    var items_peaks: [MAX_ITEMS_PER_TRACK]ItemPeaks = undefined;
    var valid_count: usize = 0;

    var i: c_int = 0;
    while (i < max_items) : (i += 1) {
        const item = api.getItemByIdx(track, i) orelse continue;

        // Get active take
        const take = api.getItemActiveTake(item) orelse continue;

        // Skip MIDI items
        if (api.isTakeMIDI(take)) continue;

        // Generate peaks for this item
        var item_peaks = ItemPeaks{
            .item_guid = undefined,
            .item_guid_len = 0,
            .track_idx = track_idx,
            .item_idx = i,
            .position = 0,
            .length = 0,
            .peak_min = [_]f64{1.0} ** (MAX_PEAKS_PER_ITEM * 2),
            .peak_max = [_]f64{-1.0} ** (MAX_PEAKS_PER_ITEM * 2),
            .num_peaks = num_peaks,
            .channels = 1,
        };

        // Get item properties
        item_peaks.position = api.getItemPosition(item);
        item_peaks.length = api.getItemLength(item);

        // Validate length
        if (!ffi.isFinite(item_peaks.length) or item_peaks.length <= 0) continue;

        // Get item GUID
        var guid_buf: [64]u8 = undefined;
        const guid = api.getItemGUID(item, &guid_buf);
        const guid_len = @min(guid.len, 40);
        @memcpy(item_peaks.item_guid[0..guid_len], guid[0..guid_len]);
        item_peaks.item_guid_len = guid_len;

        // Generate peaks using AudioAccessor
        if (generatePeaksForItem(allocator, api, take, item_peaks.length, num_peaks, &item_peaks)) {
            items_peaks[valid_count] = item_peaks;
            valid_count += 1;
        }
    }

    if (valid_count == 0) {
        logging.debug("peaks_generator: no audio items with peaks on track {s}", .{track_guid});
        return null;
    }

    // Serialize to JSON event
    return serializePeaksEvent(allocator, track_guid, items_peaks[0..valid_count]);
}

/// Generate peaks for all audio items on a track with caching.
///
/// Same as generatePeaksForTrack but uses PeaksCache to avoid regenerating
/// unchanged items. Cache keys are content-addressed based on take properties.
///
/// Parameters:
/// - allocator: Used for the returned JSON string
/// - api: Reaper backend (anytype for mock/real abstraction)
/// - guid_cache: GuidCache for track resolution
/// - cache: PeaksCache for caching peaks (pass null to disable caching)
/// - track_guid: Track GUID to generate peaks for
/// - sample_count: Number of peaks per item (typically 30)
/// - track_idx_out: Output for the resolved track index (or null if not needed)
pub fn generatePeaksForTrackCached(
    allocator: Allocator,
    api: anytype,
    guid_cache: *const guid_cache_mod.GuidCache,
    cache: ?*peaks_cache.PeaksCache,
    track_guid: []const u8,
    sample_count: u32,
    track_idx_out: ?*c_int,
) ?[]const u8 {
    // Resolve track GUID to pointer
    const track = guid_cache.resolve(track_guid) orelse {
        logging.debug("peaks_generator: track not found for GUID {s}", .{track_guid});
        return null;
    };

    // Get track index for response
    const track_idx = api.getTrackIdx(track);
    if (track_idx_out) |out| {
        out.* = track_idx;
    }

    // Count items on track
    const item_count = api.trackItemCount(track);
    if (item_count <= 0) {
        logging.debug("peaks_generator: no items on track {s}", .{track_guid});
        return null;
    }

    // Cap items for safety
    const max_items: c_int = @min(item_count, MAX_ITEMS_PER_TRACK);
    const num_peaks: usize = @min(@as(usize, sample_count), MAX_PEAKS_PER_ITEM);

    // Collect peaks for all audio items
    var items_peaks: [MAX_ITEMS_PER_TRACK]ItemPeaks = undefined;
    var valid_count: usize = 0;
    var cache_hits: usize = 0;
    var cache_misses: usize = 0;

    var i: c_int = 0;
    while (i < max_items) : (i += 1) {
        const item = api.getItemByIdx(track, i) orelse continue;

        // Get active take
        const take = api.getItemActiveTake(item) orelse continue;

        // Skip MIDI items
        if (api.isTakeMIDI(take)) continue;

        // Initialize item peaks struct
        var item_peaks = ItemPeaks{
            .item_guid = undefined,
            .item_guid_len = 0,
            .track_idx = track_idx,
            .item_idx = i,
            .position = 0,
            .length = 0,
            .peak_min = [_]f64{1.0} ** (MAX_PEAKS_PER_ITEM * 2),
            .peak_max = [_]f64{-1.0} ** (MAX_PEAKS_PER_ITEM * 2),
            .num_peaks = num_peaks,
            .channels = 1,
        };

        // Get item properties
        item_peaks.position = api.getItemPosition(item);
        item_peaks.length = api.getItemLength(item);

        // Validate length
        if (!ffi.isFinite(item_peaks.length) or item_peaks.length <= 0) continue;

        // Get item GUID
        var item_guid_buf: [64]u8 = undefined;
        const item_guid = api.getItemGUID(item, &item_guid_buf);
        const item_guid_len = @min(item_guid.len, 40);
        @memcpy(item_peaks.item_guid[0..item_guid_len], item_guid[0..item_guid_len]);
        item_peaks.item_guid_len = item_guid_len;

        // Try cache lookup
        if (cache) |c| {
            // Get take properties for cache key
            var take_guid_buf: [64]u8 = undefined;
            const take_guid = api.getTakeGUID(take, &take_guid_buf);
            const start_offset = api.getTakeStartOffset(take);
            const playrate = api.getTakePlayrate(take);

            const key = peaks_cache.PeaksCacheKey.create(
                take_guid,
                start_offset,
                playrate,
                item_peaks.length,
                sample_count,
            );

            if (c.get(key)) |cached| {
                // Use cached peaks
                const copy_len = @min(@as(usize, cached.num_peaks) * @as(usize, cached.channels), MAX_PEAKS_PER_ITEM * 2);
                @memcpy(item_peaks.peak_min[0..copy_len], cached.peak_min[0..copy_len]);
                @memcpy(item_peaks.peak_max[0..copy_len], cached.peak_max[0..copy_len]);
                item_peaks.num_peaks = cached.num_peaks;
                item_peaks.channels = cached.channels;
                cache_hits += 1;
            } else {
                // Generate peaks and store in cache
                if (generatePeaksForItem(allocator, api, take, item_peaks.length, num_peaks, &item_peaks)) {
                    c.put(
                        key,
                        item_peaks.peak_min[0 .. item_peaks.num_peaks * item_peaks.channels],
                        item_peaks.peak_max[0 .. item_peaks.num_peaks * item_peaks.channels],
                        item_peaks.num_peaks,
                        item_peaks.channels,
                    );
                    cache_misses += 1;
                } else {
                    continue;
                }
            }
        } else {
            // No cache, generate directly
            if (!generatePeaksForItem(allocator, api, take, item_peaks.length, num_peaks, &item_peaks)) {
                continue;
            }
        }

        items_peaks[valid_count] = item_peaks;
        valid_count += 1;
    }

    if (cache != null) {
        logging.debug("peaks_generator: {d} items, {d} cache hits, {d} misses", .{
            valid_count,
            cache_hits,
            cache_misses,
        });
    }

    if (valid_count == 0) {
        logging.debug("peaks_generator: no audio items with peaks on track {s}", .{track_guid});
        return null;
    }

    // Serialize to JSON event
    return serializePeaksEvent(allocator, track_guid, items_peaks[0..valid_count]);
}

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

/// Sample rate for AudioAccessor-based peak computation.
/// 4000 Hz is sufficient for peak detection and 11x faster than 44100 Hz.
/// For a 0.5s tile at 200 peaks: 2000 samples, 10 samples per peak.
const ACCESSOR_SAMPLE_RATE: c_int = 4000;

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
    if (num_peaks == 0 or num_peaks > peaks_tile.MAX_PEAKS_PER_TILE) {
        logging.warn("genTileAccessor: invalid num_peaks {d}", .{num_peaks});
        return null;
    }

    // Create audio accessor for this take
    const accessor = api.makeTakeAccessor(take) orelse {
        logging.warn("genTileAccessor: failed to create accessor", .{});
        return null;
    };
    defer api.destroyTakeAccessor(accessor);

    // Calculate samples needed
    // At 4000 Hz, a 0.5s tile = 2000 samples, giving 10 samples per peak for 200 peaks
    const samples_needed: usize = @intFromFloat(@ceil(tile_duration * @as(f64, @floatFromInt(ACCESSOR_SAMPLE_RATE))));
    if (samples_needed == 0) {
        logging.warn("genTileAccessor: samples_needed is 0", .{});
        return null;
    }

    const samples_per_peak = @max(samples_needed / num_peaks, 1);

    // Always request stereo (2 channels) - detect mono by comparing L/R later
    const num_channels: usize = 2;

    // Allocate sample buffer on heap (stereo interleaved)
    const sample_buf = allocator.alloc(f64, samples_needed * num_channels) catch {
        logging.warn("genTileAccessor: failed to allocate {d} bytes for samples", .{samples_needed * num_channels * 8});
        return null;
    };
    defer allocator.free(sample_buf);

    // Read samples from accessor
    // Note: AudioAccessor uses time relative to the TAKE start (handles trim/playrate internally)
    const rv = api.readAccessorSamples(
        accessor,
        ACCESSOR_SAMPLE_RATE,
        @intCast(num_channels),
        tile_start_time, // Relative to take start
        @intCast(samples_needed),
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

    // Process samples into peaks (iterate over requested samples_needed, not rv)
    for (0..samples_needed) |s| {
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

/// Generate a single tile for a take at specified LOD and tile index.
/// Returns a CachedTile on success, null on failure.
///
/// Uses GetMediaItemTake_Peaks API per ADAPTIVE_WAVEFORM_ZOOM.md:
/// - REAPER auto-selects mipmap tier based on peakrate
/// - starttime is PROJECT TIME (item's D_POSITION + tile_offset)
/// - Buffer layout is channel-interleaved: [LR_max...][LR_min...]
pub fn generateTileForTake(
    allocator: Allocator,
    api: anytype,
    take: *anyopaque,
    item_position: f64, // Item's D_ON timeline (PROJECT TIME)
    item_length: f64, // Item's D_LENGTH
    lod_level: u2,
    tile_index: u32,
) ?peaks_tile.CachedTile {
    const config = peaks_tile.TILE_CONFIGS[lod_level];

    // DEBUG: Log entry with take pointer for tracing
    logging.info("genTile: ENTRY take=0x{x} pos={d:.2} len={d:.2} lod={d} tile={d}", .{
        @intFromPtr(take), item_position, item_length, lod_level, tile_index,
    });

    // DEBUG: Validate take pointer before using it (if the backend supports it)
    const is_valid = if (@hasDecl(@TypeOf(api.*), "validateTakePtr"))
        api.validateTakePtr(take)
    else
        true; // Mock backends don't have validateTakePtr

    logging.info("genTile: validateTakePtr={}", .{is_valid});
    if (!is_valid) {
        logging.warn("genTile: STALE take pointer - returning null", .{});
        return null;
    }

    // Calculate tile time range (relative to item start)
    const tile_start_relative = @as(f64, @floatFromInt(tile_index)) * config.duration;
    const tile_end_relative = tile_start_relative + config.duration;

    // Clamp to item bounds
    if (tile_start_relative >= item_length) {
        logging.info("genTile: tile_start {d:.1} >= item_length {d:.1}", .{ tile_start_relative, item_length });
        return null;
    }
    const clamped_end = @min(tile_end_relative, item_length);
    const tile_duration = clamped_end - tile_start_relative;

    if (tile_duration <= 0) {
        logging.warn("genTile: tile duration <= 0", .{});
        return null;
    }

    // Calculate number of peaks for this tile
    const num_peaks: usize = @intFromFloat(@ceil(tile_duration * config.peakrate));
    if (num_peaks == 0 or num_peaks > peaks_tile.MAX_PEAKS_PER_TILE) {
        logging.warn("genTile: invalid num_peaks {d} (duration={d:.1}, peakrate={d:.1})", .{ num_peaks, tile_duration, config.peakrate });
        return null;
    }

    // Use config.peakrate directly - this matches what Lua does successfully.
    // The recalculated peakrate was producing wrong values (using item_length instead of tile_duration).
    const peakrate: f64 = config.peakrate;

    // WORKAROUND: GetMediaSourceNumChannels via GetFunc returns wrong value on ARM64 (always 1).
    // Lua's API returns correct value (2 for stereo). Since we can't fix the API, always request
    // 2 channels and detect mono by comparing L/R peaks later.
    // See LATEST_FINDINGS.md for full investigation.
    const num_channels: usize = 2;

    // Allocate buffer: 2 blocks (max + min), each with interleaved channels
    const buf_size = num_channels * num_peaks * 2;
    const reaper_buf = allocator.alloc(f64, buf_size) catch {
        logging.warn("genTile: failed to allocate {d} bytes", .{buf_size * 8});
        return null;
    };
    defer allocator.free(reaper_buf);

    // starttime = PROJECT TIME (per ADAPTIVE_WAVEFORM_ZOOM.md lines 76-94):
    // "GetMediaItemTake_Peaks expects PROJECT time (absolute timeline position)"
    // "The API automatically handles D_STARTOFFS (trim) and D_PLAYRATE internally"
    // Don't manually add start_offset - REAPER does that for us!
    const project_time = item_position + tile_start_relative;

    // DEBUG: Log API call parameters
    logging.info("genTile: CALLING API peakrate={d:.4} project_time={d:.2} (item_pos={d:.2} + tile_rel={d:.2}) ch={d} numPeaks={d}", .{
        peakrate, project_time, item_position, tile_start_relative, num_channels, num_peaks,
    });

    // Call REAPER's GetMediaItemTake_Peaks
    // peakrate = num_peaks / tile_duration (let REAPER handle LOD selection)
    const result = api.getMediaItemTakePeaks(
        take,
        peakrate,
        project_time, // PROJECT TIME (item's timeline position + tile offset)
        @intCast(num_channels),
        @intCast(num_peaks),
        reaper_buf,
    );

    // Parse return value (per ADAPTIVE_WAVEFORM_ZOOM.md):
    // bits 0-19: actual sample count
    // bits 20-23: mode (0 = interpolated from coarser mipmap, 1+ = native)
    // NOTE: mode=0 is VALID DATA, not an error! Only check actual_peaks for failure.
    const actual_peaks: usize = @intCast(result & 0xFFFFF);
    const mode = (result >> 20) & 0xF;

    // DEBUG: Log result and first few buffer values
    logging.info("genTile: API RESULT result={d} actual={d} mode={d}", .{ result, actual_peaks, mode });
    if (reaper_buf.len >= 4) {
        logging.info("genTile: BUFFER first 4 values: [{d:.4}, {d:.4}, {d:.4}, {d:.4}]", .{
            reaper_buf[0], reaper_buf[1], reaper_buf[2], reaper_buf[3],
        });
    }

    if (actual_peaks == 0) {
        logging.warn("genTile: API returned 0 peaks for tile {d} at project_time={d:.2}", .{ tile_index, project_time });
        return null;
    }

    // Parse buffer with CORRECT layout (channel-interleaved within blocks)
    // Block 1 (max): [L_max_0, R_max_0, L_max_1, R_max_1, ...]
    // Block 2 (min): [L_min_0, R_min_0, L_min_1, R_min_1, ...]
    var tile = peaks_tile.CachedTile.empty();
    const peaks_to_use = @min(actual_peaks, num_peaks);
    const block_size = num_channels * peaks_to_use;

    for (0..peaks_to_use) |p| {
        for (0..num_channels) |ch| {
            const our_idx = p * num_channels + ch;
            // CORRECT indexing per ADAPTIVE_WAVEFORM_ZOOM.md:
            const max_offset = p * num_channels + ch; // Within first block
            const min_offset = block_size + p * num_channels + ch; // Within second block
            tile.peak_max[our_idx] = reaper_buf[max_offset];
            tile.peak_min[our_idx] = reaper_buf[min_offset];
        }
    }

    // Detect mono vs stereo by comparing L/R peaks
    const detected_channels: u8 = blk: {
        const epsilon = 0.0001;
        for (0..peaks_to_use) |p| {
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

    tile.num_peaks = @intCast(peaks_to_use);
    tile.channels = detected_channels;

    return tile;
}

/// Tile info for JSON serialization
pub const TileInfo = struct {
    take_guid: []const u8,
    epoch: u32,
    lod: u2,
    tile_index: u32,
    start_time: f64, // Relative to item start
    end_time: f64, // Relative to item start
    channels: u8,
    num_peaks: u16,
    peak_min: []const f64,
    peak_max: []const f64,
};

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

    // Process each track
    var items_checked: usize = 0;
    var items_in_viewport: usize = 0;
    var tile_gen_attempts: usize = 0;
    var tile_gen_failures: usize = 0;

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

            // Generate tiles for this item
            var tile_idx = item_start_tile;
            while (tile_idx <= item_end_tile and tile_idx < 10000) : (tile_idx += 1) {
                const key = peaks_tile.TileCacheKey.create(take_guid, epoch, tile_range.lod, tile_idx);

                // Try cache first
                var tile_ptr: ?*peaks_tile.CachedTile = tile_cache.get(key);

                // Generate if not cached
                if (tile_ptr == null) {
                    tile_gen_attempts += 1;

                    // Calculate tile time range (relative to item start)
                    const tile_start_relative = @as(f64, @floatFromInt(tile_idx)) * config.duration;
                    const tile_end_relative = tile_start_relative + config.duration;
                    const clamped_end = @min(tile_end_relative, item_length);
                    const tile_duration = clamped_end - tile_start_relative;

                    // Route based on LOD level:
                    // - LOD 0/1: Use GetMediaItemTake_Peaks (works with low peakrate)
                    // - LOD 2: Use AudioAccessor (GetMediaItemTake_Peaks fails on ARM64 with high peakrate)
                    // See docs/architecture/ADAPTIVE_WAVEFORM_ZOOM.md for details.
                    const maybe_tile: ?peaks_tile.CachedTile = if (tile_range.lod == 2)
                        generateTileViaAccessor(
                            allocator,
                            api,
                            take,
                            tile_start_relative, // Relative to item/take start
                            tile_duration,
                            config.peaks_per_tile,
                        )
                    else
                        generateTileForTake(
                            allocator,
                            api,
                            take,
                            item_position,
                            item_length,
                            tile_range.lod,
                            tile_idx,
                        );

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
        logging.info("peaks_generator: tiles_written=0 (checked={d}, in_viewport={d}, gen_attempts={d}, gen_failures={d})", .{
            items_checked, items_in_viewport, tile_gen_attempts, tile_gen_failures,
        });
        allocator.free(buf);
        return null;
    }

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

/// Serialize peaks event to JSON.
/// Returns allocated string or null on error.
fn serializePeaksEvent(
    allocator: Allocator,
    track_guid: []const u8,
    items: []const ItemPeaks,
) ?[]const u8 {
    // Estimate buffer size: ~500 bytes per item (with 30 peaks)
    const estimated_size = 256 + items.len * 800;
    const buf = allocator.alloc(u8, estimated_size) catch {
        logging.warn("peaks_generator: failed to allocate {d} bytes for JSON", .{estimated_size});
        return null;
    };
    errdefer allocator.free(buf);

    var stream = std.io.fixedBufferStream(buf);
    var w = stream.writer();

    // Write event envelope (must include type:"event" for frontend compatibility)
    w.writeAll("{\"type\":\"event\",\"event\":\"peaks\",\"payload\":{\"trackGuid\":\"") catch return null;
    w.writeAll(track_guid) catch return null;
    w.writeAll("\",\"items\":[") catch return null;

    for (items, 0..) |item, item_i| {
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
                // Stereo: {"l":[min,max],"r":[min,max]}
                const max_l = item.peak_max[p * 2];
                const max_r = item.peak_max[p * 2 + 1];
                const min_l = item.peak_min[p * 2];
                const min_r = item.peak_min[p * 2 + 1];
                w.print("{{\"l\":[{d:.4},{d:.4}],\"r\":[{d:.4},{d:.4}]}}", .{
                    min_l, max_l, min_r, max_r,
                }) catch return null;
            } else {
                // Mono: [min,max]
                const max_val = item.peak_max[p];
                const min_val = item.peak_min[p];
                w.print("[{d:.4},{d:.4}]", .{ min_val, max_val }) catch return null;
            }
        }

        w.writeAll("]}") catch return null;
    }

    w.writeAll("]}}") catch return null;

    // Shrink to actual size
    const written = stream.getWritten();
    const result = allocator.realloc(buf, written.len) catch buf;
    return result[0..written.len];
}

// =============================================================================
// Tests
// =============================================================================

test "serializePeaksEvent basic" {
    const allocator = std.testing.allocator;

    var items: [1]ItemPeaks = undefined;
    items[0] = ItemPeaks{
        .item_guid = undefined,
        .item_guid_len = 11,
        .track_idx = 0,
        .item_idx = 0,
        .position = 1.5,
        .length = 2.0,
        .peak_min = [_]f64{1.0} ** (MAX_PEAKS_PER_ITEM * 2),
        .peak_max = [_]f64{-1.0} ** (MAX_PEAKS_PER_ITEM * 2),
        .num_peaks = 2,
        .channels = 1,
    };
    @memcpy(items[0].item_guid[0..11], "{test-guid}");

    // Set up mono peaks: peak 0 = [-0.5, 0.8], peak 1 = [-0.3, 0.6]
    items[0].peak_min[0] = -0.5;
    items[0].peak_max[0] = 0.8;
    items[0].peak_min[1] = -0.3;
    items[0].peak_max[1] = 0.6;

    const json = serializePeaksEvent(allocator, "{track-guid}", &items);
    try std.testing.expect(json != null);
    defer allocator.free(json.?);

    // Verify structure
    try std.testing.expect(std.mem.indexOf(u8, json.?, "\"event\":\"peaks\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.?, "\"trackGuid\":\"{track-guid}\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.?, "\"itemGuid\":\"{test-guid}\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.?, "\"channels\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.?, "\"position\":1.5") != null);
}

test "serializePeaksEvent stereo" {
    const allocator = std.testing.allocator;

    var items: [1]ItemPeaks = undefined;
    items[0] = ItemPeaks{
        .item_guid = undefined,
        .item_guid_len = 11,
        .track_idx = 1,
        .item_idx = 2,
        .position = 0.0,
        .length = 1.0,
        .peak_min = [_]f64{1.0} ** (MAX_PEAKS_PER_ITEM * 2),
        .peak_max = [_]f64{-1.0} ** (MAX_PEAKS_PER_ITEM * 2),
        .num_peaks = 1,
        .channels = 2,
    };
    @memcpy(items[0].item_guid[0..11], "{item-guid}");

    // Set up stereo peak: L=[-0.5, 0.5], R=[-0.8, 0.8]
    items[0].peak_min[0] = -0.5; // L min
    items[0].peak_max[0] = 0.5; // L max
    items[0].peak_min[1] = -0.8; // R min
    items[0].peak_max[1] = 0.8; // R max

    const json = serializePeaksEvent(allocator, "{track-2}", &items);
    try std.testing.expect(json != null);
    defer allocator.free(json.?);

    // Verify stereo format
    try std.testing.expect(std.mem.indexOf(u8, json.?, "\"channels\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.?, "\"l\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.?, "\"r\":[") != null);
}

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
