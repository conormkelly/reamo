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

// Peak extraction constants (same as items.zig)
const MAX_PEAKS_PER_ITEM = 200;
const PEAK_SAMPLE_RATE: c_int = 4410;
const MAX_SAMPLE_BUF = 65536;

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
        if (generatePeaksForItem(api, take, item_peaks.length, num_peaks, &item_peaks)) {
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
                if (generatePeaksForItem(api, take, item_peaks.length, num_peaks, &item_peaks)) {
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
            if (!generatePeaksForItem(api, take, item_peaks.length, num_peaks, &item_peaks)) {
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

/// Generate peaks for a single item using AudioAccessor.
/// Populates peak_min, peak_max, and channels in item_peaks.
/// Returns true on success.
fn generatePeaksForItem(
    api: anytype,
    take: *anyopaque,
    length: f64,
    num_peaks: usize,
    item_peaks: *ItemPeaks,
) bool {
    // Create audio accessor
    const accessor = api.makeTakeAccessor(take) orelse {
        logging.debug("peaks_generator: failed to create accessor", .{});
        return false;
    };
    defer api.destroyTakeAccessor(accessor);

    // Always request stereo (mono detection done by comparing L/R)
    const num_channels: usize = 2;

    // Calculate samples needed
    const total_samples: usize = ffi.safeFloatToInt(usize, length * @as(f64, PEAK_SAMPLE_RATE)) catch {
        return false;
    };
    const samples_per_peak = @max(total_samples / num_peaks, 1);

    // Read samples and compute peaks
    var sample_buf: [MAX_SAMPLE_BUF]f64 = undefined;
    var sample_idx: usize = 0;
    var peak_idx: usize = 0;

    while (sample_idx < total_samples and peak_idx < num_peaks) {
        // Calculate how many samples to read this iteration
        const remaining = total_samples - sample_idx;
        const max_samples_per_chan = MAX_SAMPLE_BUF / num_channels;
        const samples_to_read: usize = @min(remaining, max_samples_per_chan);

        // Read samples
        const start_time = @as(f64, @floatFromInt(sample_idx)) / @as(f64, PEAK_SAMPLE_RATE);
        const rv = api.readAccessorSamples(
            accessor,
            PEAK_SAMPLE_RATE,
            @intCast(num_channels),
            start_time,
            @intCast(samples_to_read),
            sample_buf[0 .. samples_to_read * num_channels],
        );

        if (rv < 0) {
            logging.warn("peaks_generator: readAccessorSamples error at {d}s", .{start_time});
            break;
        }
        if (rv == 0) {
            // No audio at this position, advance
            sample_idx += samples_to_read;
            continue;
        }

        // Process samples into peaks
        for (0..samples_to_read) |j| {
            const current_peak = (sample_idx + j) / samples_per_peak;
            if (current_peak >= num_peaks) break;

            // Update min/max for each channel
            for (0..num_channels) |ch| {
                const sample = sample_buf[j * num_channels + ch];
                const idx = current_peak * num_channels + ch;
                item_peaks.peak_max[idx] = @max(item_peaks.peak_max[idx], sample);
                item_peaks.peak_min[idx] = @min(item_peaks.peak_min[idx], sample);
            }
        }

        sample_idx += samples_to_read;
        peak_idx = sample_idx / samples_per_peak;
    }

    // Fix any peaks that weren't touched (still at init values)
    for (0..num_peaks * num_channels) |idx| {
        if (item_peaks.peak_max[idx] < item_peaks.peak_min[idx]) {
            item_peaks.peak_max[idx] = 0;
            item_peaks.peak_min[idx] = 0;
        }
    }

    // Detect actual channel count by comparing L/R peaks
    const detected_channels: usize = blk: {
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
