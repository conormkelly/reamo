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

/// Most tracks of one client's subscription a send gives it tiles for.
pub const MAX_TRACKS_PER_BROADCAST = 32;

// =============================================================================
// GetMediaItemTake_Peaks Based Tile Generation
// =============================================================================
// Uses REAPER's pre-computed .reapeaks mipmaps for fast peak retrieval.
// Fetches peaks for the FULL item, then slices into tiles locally.
// This is faster than AudioAccessor because it reads pre-computed data.

/// Result from fetching full item peaks via GetMediaItemTake_Peaks
const ItemPeaksResult = struct {
    /// Peaks interleaved by channel: [ch0_p0, ch1_p0, ch0_p1, ch1_p1, ...]
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

/// How many waveforms REAPER draws for a take, capped at the two REAmo
/// sends. A mono channel mode draws one, whatever the source, though
/// GetMediaItemTake_Peaks returns it alike on both channels asked for; the
/// other modes draw the source's channels, or a stereo pair's two.
///
/// I_CHANMODE, measured on REAPER 7.83 and 6.0 on Linux (harness:
/// peaks-channel-modes-match-reaper): 0 normal, 1 reverse stereo, 2 mono
/// downmix, 3..66 mono channel 1..64 (3 left, 4 right), 67..130 stereo
/// channels 1/2..64/65. On 7.83 (6.0 gives no peaks past 64 channels):
/// 131..194 mono channel 65..128, 195..257 stereo pairs from 65/66, and 258
/// and above drawn like normal.
fn drawnChannels(source_channels: usize, channel_mode: c_int) usize {
    const mono_mode = (channel_mode >= 2 and channel_mode <= 66) or
        (channel_mode >= 131 and channel_mode <= 194);
    if (mono_mode) return 1;
    return @min(source_channels, 2);
}

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

    // The waveforms REAPER draws for the take, at most two (REAmo sends no more).
    const actual_channels = drawnChannels(@intCast(source_channels), api.getTakeChannelMode(take) catch 0);
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
    // REAPER leaves slots it has no peaks for unwritten; zeroed, they read as
    // silence rather than heap contents if anything ever reads one.
    @memset(reaper_buf, 0);

    // GetMediaItemTake_Peaks
    const result = api.getMediaItemTakePeaks(
        take,
        peakrate,
        item_position,
        @intCast(request_channels),
        @intCast(num_peaks),
        reaper_buf,
    );

    if (result < 0) return null;
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

    const peak_max = allocator.alloc(f64, data_size) catch {
        allocator.free(peak_min);
        return null;
    };

    const num_channels = actual_channels;

    // Copy from REAPER buffer to our format
    // REAPER writes request_channels (always 2), we extract actual_channels (1 or 2)
    // The min block starts at num_peaks * request_channels, the count asked for,
    // even when REAPER returns fewer peaks (an item past its audio, loop off);
    // the slots between the returned maxes and the min block stay unwritten.
    // Measured on REAPER 6.0 and 7.83 on Linux (harness: peaks-item-past-its-source-end-matches-reaper).
    const reaper_block_size = num_peaks * request_channels;
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

    // Every tile has the take's channel count (the waveforms REAPER draws for
    // it), never one judged per tile from its L/R peaks: a stereo take's
    // silent tiles collapsed to mono would show one centred lane between
    // two-lane tiles.
    tile.num_peaks = @intCast(num_peaks);
    tile.channels = @intCast(channels);

    return tile;
}

// =============================================================================
// Binary Tile Serialization
// =============================================================================

/// The tracks (unified indices) a send gives the client tiles for: its
/// subscription's first MAX_TRACKS_PER_BROADCAST tracks that exist.
pub fn sendTracks(
    api: anytype,
    guid_cache: *const guid_cache_mod.GuidCache,
    sub: *const @import("peaks_subscriptions.zig").ClientSubscription,
    out: *[MAX_TRACKS_PER_BROADCAST]c_int,
) []c_int {
    var n: usize = 0;
    switch (sub.mode) {
        .none => {},
        .range => {
            const total_tracks = api.trackCount();
            var idx = sub.range_start;
            const end = @min(sub.range_end, total_tracks);
            while (idx <= end and n < MAX_TRACKS_PER_BROADCAST) : (idx += 1) {
                out[n] = idx;
                n += 1;
            }
        },
        .guids => {
            for (0..sub.guid_count) |i| {
                if (n >= MAX_TRACKS_PER_BROADCAST) break;
                const guid = sub.getGuid(i) orelse continue;
                const track = guid_cache.resolve(api, guid) orelse continue;
                const idx = api.getTrackIdx(track);
                if (idx >= 0) {
                    out[n] = idx;
                    n += 1;
                }
            }
        },
    }
    return out[0..n];
}

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

    var track_indices_buf: [MAX_TRACKS_PER_BROADCAST]c_int = undefined;
    const send_tracks = sendTracks(api, guid_cache, sub, &track_indices_buf);
    const track_count = send_tracks.len;

    if (track_count == 0) return null;

    const config = peaks_tile.TILE_CONFIGS[tile_range.lod];
    const tiles_per_item = (tile_range.end_tile - tile_range.start_tile) + 1;
    // A first guess of one item's worth of tiles per track; every item in
    // view brings its own edge tiles, so the buffer grows when it fills.
    const estimated_tiles = tiles_per_item * track_count;

    // Binary buffer: much smaller than JSON (~1KB per stereo tile vs ~13KB)
    const buf_size = binary_protocol.batchBufferSize(estimated_tiles, peaks_tile.MAX_PEAKS_PER_TILE, 2);
    var buf = allocator.alloc(u8, buf_size) catch {
        logging.warn("peaks_generator: failed to allocate binary tile buffer ({d} bytes)", .{buf_size});
        return null;
    };

    // Write envelope placeholder (tile_count filled in at end)
    var offset: usize = binary_protocol.BATCH_ENVELOPE_SIZE;
    var tiles_written: u16 = 0;

    tracks: for (send_tracks) |track_idx| {
        const track = api.getTrackByUnifiedIdx(track_idx) orelse continue;
        const item_count_raw = api.trackItemCount(track);
        if (item_count_raw <= 0) continue;

        // Every item on the track; the viewport check below keeps the work
        // to what's in view, wherever on the track that is.
        var i: c_int = 0;
        while (i < item_count_raw) : (i += 1) {
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
            const epoch = tile_cache.sendEpoch(take_guid, api, take);

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
                if (tiles_written == std.math.maxInt(u16)) break :tracks; // the envelope's count
                if (offset + tile_total > buf.len) {
                    buf = allocator.realloc(buf, @max(buf.len * 2, offset + tile_total)) catch {
                        logging.warn("peaks: no memory for more than {d} tiles; later items get no waveform", .{tiles_written});
                        break :tracks;
                    };
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

    logging.debug("peaks_generator: binary success tiles={d} size={d}KB (estimated={d}KB)", .{
        tiles_written,
        offset / 1024,
        buf_size / 1024,
    });

    // Shrink to actual size
    const result = allocator.realloc(buf, offset) catch buf;
    return result[0..offset];
}

// =============================================================================
// Tests
// =============================================================================

const mock = @import("../reaper/mock/mod.zig");
const mock_state = @import("../reaper/mock/state.zig");
const mockPeak = @import("../reaper/mock/tracks.zig").TracksMethods.mockPeak;

fn expectPeaksMatchMock(result: *const ItemPeaksResult, num_peaks: usize, channels: usize) !void {
    try std.testing.expectEqual(num_peaks, result.num_peaks);
    try std.testing.expectEqual(channels, result.channels);
    for (0..num_peaks) |p| {
        for (0..channels) |ch| {
            const i = p * channels + ch;
            try std.testing.expectEqual(mockPeak(p, ch), result.peak_max[i]);
            try std.testing.expectEqual(-mockPeak(p, ch), result.peak_min[i]);
        }
    }
}

test "an item past its audio gets REAPER's minimums, read where REAPER writes them for the count asked for" {
    var api = mock.MockBackend{};
    api.tracks[0].item_count = 1;
    api.tracks[0].items[0].position = 1.0;
    api.tracks[0].items[0].length = 12.0;
    api.tracks[0].items[0].take_count = 1;
    api.tracks[0].items[0].takes[0].audio_length = 8.0;
    const take = mock_state.encodeTakePtr(0, 0, 0).?;

    // 120 peaks asked for, 80 returned: the minimums start 240 slots in, not 160.
    var result = fetchItemPeaksViaTakePeaksAPI(std.testing.allocator, &api, take, 1.0, 12.0, 10.0).?;
    defer result.deinit();
    try expectPeaksMatchMock(&result, 80, 2);
}

test "a mono item past its audio gets its channel's minimums out of REAPER's two-channel layout" {
    var api = mock.MockBackend{};
    api.tracks[0].item_count = 1;
    api.tracks[0].items[0].length = 3.0;
    api.tracks[0].items[0].take_count = 1;
    api.tracks[0].items[0].takes[0].channel_count = 1;
    api.tracks[0].items[0].takes[0].audio_length = 1.0;
    const take = mock_state.encodeTakePtr(0, 0, 0).?;

    var result = fetchItemPeaksViaTakePeaksAPI(std.testing.allocator, &api, take, 0.0, 3.0, 64.0).?;
    defer result.deinit();
    try expectPeaksMatchMock(&result, 64, 1);
}

test "an item whose audio covers it gets every peak asked for" {
    var api = mock.MockBackend{};
    api.tracks[0].item_count = 1;
    api.tracks[0].items[0].length = 2.0;
    api.tracks[0].items[0].take_count = 1;
    const take = mock_state.encodeTakePtr(0, 0, 0).?;

    var result = fetchItemPeaksViaTakePeaksAPI(std.testing.allocator, &api, take, 0.0, 2.0, 16.0).?;
    defer result.deinit();
    try expectPeaksMatchMock(&result, 32, 2);
}

/// Fetch a one-take item's peaks, its take's source having
/// `source_channels` channels and the take channel mode `channel_mode`.
fn fetchWithChannelMode(api: *mock.MockBackend, source_channels: c_int, channel_mode: c_int) ItemPeaksResult {
    api.tracks[0].item_count = 1;
    api.tracks[0].items[0].length = 2.0;
    api.tracks[0].items[0].take_count = 1;
    api.tracks[0].items[0].takes[0].channel_count = source_channels;
    api.tracks[0].items[0].takes[0].channel_mode = channel_mode;
    const take = mock_state.encodeTakePtr(0, 0, 0).?;
    return fetchItemPeaksViaTakePeaksAPI(std.testing.allocator, api, take, 0.0, 2.0, 16.0).?;
}

test "a take in a mono channel mode gets one channel, as REAPER draws one waveform" {
    for ([_]c_int{ 2, 3, 4, 5, 66, 131, 194 }) |mode| {
        for ([_]c_int{ 2, 4 }) |source_channels| {
            var api = mock.MockBackend{};
            var result = fetchWithChannelMode(&api, source_channels, mode);
            defer result.deinit();
            expectPeaksMatchMock(&result, 32, 1) catch |err| {
                std.debug.print("channel mode {d}, {d}-channel source\n", .{ mode, source_channels });
                return err;
            };
        }
    }
}

test "a take in normal, reverse-stereo, stereo-pair or unknown channel mode keeps two channels" {
    for ([_]c_int{ 0, 1, 67, 130, 195, 257, 258, 300 }) |mode| {
        for ([_]c_int{ 2, 4 }) |source_channels| {
            var api = mock.MockBackend{};
            var result = fetchWithChannelMode(&api, source_channels, mode);
            defer result.deinit();
            expectPeaksMatchMock(&result, 32, 2) catch |err| {
                std.debug.print("channel mode {d}, {d}-channel source\n", .{ mode, source_channels });
                return err;
            };
        }
    }
}

test "a mono source keeps one channel in a mono or stereo-pair channel mode" {
    for ([_]c_int{ 0, 2, 3, 67 }) |mode| {
        var api = mock.MockBackend{};
        var result = fetchWithChannelMode(&api, 1, mode);
        defer result.deinit();
        expectPeaksMatchMock(&result, 32, 1) catch |err| {
            std.debug.print("channel mode {d}\n", .{mode});
            return err;
        };
    }
}

/// The LOD, channel count and epoch of each tile in a binary peaks frame.
fn sentTileHeaders(bin: []const u8, out: []binary_protocol.TileHeader) []binary_protocol.TileHeader {
    const count = std.mem.readInt(u16, bin[2..4], .little);
    var off: usize = binary_protocol.BATCH_ENVELOPE_SIZE;
    for (0..count) |i| {
        out[i] = std.mem.bytesToValue(binary_protocol.TileHeader, bin[off..][0..binary_protocol.TILE_HEADER_SIZE]);
        off += binary_protocol.TILE_FIXED_SIZE + @as(usize, out[i].num_peaks) * out[i].channels * 2;
    }
    std.debug.assert(off == bin.len);
    return out[0..count];
}

test "tiles read while an edit the change check hasn't reached is in place aren't sent as the take's waveform once it's undone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var api = mock.MockBackend{ .track_count = 1 };
    api.tracks[1].item_count = 1;
    api.tracks[1].items[0].length = 8.0;
    api.tracks[1].items[0].take_count = 1;
    const mock_take = &api.tracks[1].items[0].takes[0];
    const guid = "{take-1}";
    @memcpy(mock_take.guid[0..guid.len], guid);
    mock_take.guid_len = guid.len;

    var tile_cache = peaks_tile.TileCache.init(std.testing.allocator);
    defer tile_cache.deinit();
    var guids = guid_cache_mod.GuidCache.init(std.testing.allocator);
    defer guids.deinit();
    var sub = @import("peaks_subscriptions.zig").ClientSubscription{
        .mode = .range,
        .range_start = 1,
        .range_end = 1,
        .viewport_start = 0,
        .viewport_end = 14,
        .viewport_width_px = 1400,
    };
    var headers: [64]binary_protocol.TileHeader = undefined;

    const near = sentTileHeaders(generateTilesForSubscriptionBinary(scratch, &api, &guids, &tile_cache, &sub).?, &headers);
    const normal_epoch = near[0].epoch;
    for (near) |h| try std.testing.expectEqual(@as(u8, 2), h.channels);

    // The take goes mono and the phone zooms out to a level it hasn't
    // shown, all before the change check gets to the track.
    mock_take.channel_mode = 3;
    sub.viewport_end = 60;
    const far_mono = sentTileHeaders(generateTilesForSubscriptionBinary(scratch, &api, &guids, &tile_cache, &sub).?, &headers);
    try std.testing.expect(far_mono.len > 0);
    for (far_mono) |h| {
        try std.testing.expectEqual(@as(u8, 1), h.channels);
        try std.testing.expect(h.epoch != normal_epoch);
    }
    try std.testing.expect(tile_cache.consumeEpochMoved());

    // Undone, still before the check: the phone gets the take in normal mode.
    mock_take.channel_mode = 0;
    const far = sentTileHeaders(generateTilesForSubscriptionBinary(scratch, &api, &guids, &tile_cache, &sub).?, &headers);
    try std.testing.expect(far.len > 0);
    for (far) |h| {
        try std.testing.expectEqual(@as(u8, 2), h.channels);
        try std.testing.expectEqual(normal_epoch, h.epoch);
    }
    try std.testing.expect(tile_cache.consumeEpochMoved());
}
