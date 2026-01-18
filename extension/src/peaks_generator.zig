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
