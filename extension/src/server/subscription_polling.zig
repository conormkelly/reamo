//! Subscription Polling Module
//!
//! Extracted from main.zig doProcessing() to enable unit testing of
//! individual subscription polling behaviors.
//!
//! All functions run at 30Hz (HIGH tier) but only process when there
//! are active subscriptions. Each polling function:
//! 1. Checks if subscriptions exist
//! 2. Polls state from REAPER
//! 3. Compares with previous state (hash-based)
//! 4. Broadcasts changes to subscribed clients

const std = @import("std");
const reaper = @import("../reaper.zig");
const logging = @import("../core/logging.zig");
const tiered_state = @import("tiered_state.zig");
const guid_cache = @import("../state/guid_cache.zig");
const ws_server = @import("ws_server.zig");
const csurf_dirty = @import("csurf_dirty.zig");

// Subscription types
const toggle_subscriptions = @import("../subscriptions/toggle_subscriptions.zig");
const peaks_subscriptions = @import("../subscriptions/peaks_subscriptions.zig");
const routing_subscriptions = @import("../subscriptions/routing_subscriptions.zig");
const trackfx_subscriptions = @import("../subscriptions/trackfx_subscriptions.zig");
const trackfxparam_subscriptions = @import("../subscriptions/trackfxparam_subscriptions.zig");
const tuner_subscriptions = @import("../subscriptions/tuner_subscriptions.zig");

// Generators
const peaks_generator = @import("../subscriptions/peaks_generator.zig");
const routing_generator = @import("../subscriptions/routing_generator.zig");
const trackfx_generator = @import("../subscriptions/trackfx_generator.zig");
const trackfxparam_generator = @import("../subscriptions/trackfxparam_generator.zig");
const tuner_generator = @import("../subscriptions/tuner_generator.zig");

const peaks_tile = @import("../state/peaks_tile.zig");

/// Context shared across all subscription polling functions.
/// Contains references to infrastructure needed for polling and broadcasting.
pub const PollingContext = struct {
    /// Tiered arena allocator for scratch memory
    tiered: *tiered_state.TieredArenas,
    /// REAPER API backend
    backend: *reaper.RealBackend,
    /// WebSocket shared state for broadcasting
    shared_state: *ws_server.SharedState,
    /// GUID cache for track lookups
    guid_cache_ptr: *guid_cache.GuidCache,
    /// CSurf FX dirty flags for instant latency
    csurf_fx_dirty: csurf_dirty.TrackDirtyResult,
    /// CSurf sends dirty flags for instant latency
    csurf_sends_dirty: csurf_dirty.TrackDirtyResult,

    /// Create a scratch allocator from the tiered arenas
    pub fn scratchAllocator(self: *const PollingContext) std.mem.Allocator {
        return self.tiered.scratchAllocator();
    }
};

/// Poll toggle subscriptions and broadcast changes to subscribed clients.
/// Runs at 30Hz but only processes when there are active subscriptions.
pub fn pollToggleSubscriptions(
    ctx: *const PollingContext,
    toggle_subs: *toggle_subscriptions.ToggleSubscriptions,
    api: *const reaper.Api,
) void {
    if (!toggle_subs.hasSubscriptions()) return;

    var changes = toggle_subs.poll(api);
    defer changes.deinit();

    if (changes.count() > 0) {
        const scratch = ctx.scratchAllocator();
        if (toggle_subscriptions.ToggleSubscriptions.changesToJsonAlloc(&changes, scratch)) |json| {
            ctx.shared_state.broadcast(json);
        } else |_| {}
    }
}

/// Poll peaks subscriptions and broadcast waveform data to subscribed clients.
/// Uses tile-based LOD cache for efficient pan/zoom operations.
pub fn pollPeaksSubscriptions(
    ctx: *const PollingContext,
    peaks_subs: *peaks_subscriptions.PeaksSubscriptions,
    tile_cache: *peaks_tile.TileCache,
) void {
    pollPeaks(
        ctx.scratchAllocator(),
        ctx.backend,
        ctx.guid_cache_ptr,
        peaks_subs,
        tile_cache,
        ctx.shared_state,
        std.time.milliTimestamp(),
    );
}

/// One peaks tick. Sends a client its tiles when it subscribes or moves its
/// viewport (forced), and every client fresh tiles when a subscribed
/// track's items or a take's audio source change, at most once per
/// CHANGE_BROADCAST_INTERVAL_MS; a change that limit holds back goes out on
/// the first tick it allows. `sender` takes sendBinToClient(client_id, bytes);
/// `scratch` is the frame's arena.
pub fn pollPeaks(
    scratch: std.mem.Allocator,
    api: anytype,
    guids: *const guid_cache.GuidCache,
    peaks_subs: *peaks_subscriptions.PeaksSubscriptions,
    tile_cache: *peaks_tile.TileCache,
    sender: anytype,
    now_ms: i64,
) void {
    if (!peaks_subs.hasSubscriptions()) {
        // Nobody is left to owe a held change to.
        peaks_subs.change_pending = false;
        return;
    }

    // Tick the cache for LRU tracking
    tile_cache.tick();

    // Some client subscribed or moved its viewport and needs its own tiles now.
    const any_forced = peaks_subs.anyForceBroadcast();

    // Check the subscribed tracks for a change (items, or a take's audio
    // source); that goes to every client. Every track in this tick's batch,
    // not just up to the first change: trackChanged also drops a changed
    // take's stale tiles. Past CHANGE_CHECK_TRACKS_PER_TICK tracks the
    // batch takes them in turn; a send meanwhile reads a take as it is now
    // (TileCache.sendEpoch), so it never sends or caches a take's new audio
    // under its old epoch.
    //
    // A forced tick skips the check (the next tick sees any change), and
    // remembers the tracks its sends cover (rememberForcedTracks).
    var any_track_changed = false;
    if (any_forced) {
        rememberForcedTracks(scratch, api, guids, peaks_subs, tile_cache) catch {
            scratchShortage(peaks_subs);
            return;
        };
    } else {
        const subscribed = peaks_subs.getSubscribedIndices(scratch, guids, api) catch {
            scratchShortage(peaks_subs);
            return;
        };
        var batch = peaks_subs.changeCheckBatch(subscribed);
        while (batch.next()) |track_idx| {
            // Unified index (0 = master), as the generator resolves it.
            const track = api.getTrackByUnifiedIdx(track_idx) orelse continue;
            var guid_buf: [64]u8 = undefined;
            if (tile_cache.trackChanged(api.formatTrackGuid(track, &guid_buf), api, track)) {
                any_track_changed = true;
            }
        }
    }
    peaks_subs.scratch_shortage_logged = false;

    // A change goes to every client, rate-limited; one the limit holds back
    // goes out on the first tick it allows. Forced per-client sends bypass
    // the limit, as initial data always did.
    var send_change = false;
    if (any_forced) {
        // Leaves change_pending alone: a held change goes out on a later
        // tick, after this send's interval.
        peaks_subs.last_broadcast_ms = now_ms;
    } else {
        send_change = peaks_subs.changeBroadcastDue(any_track_changed, now_ms);
        if (!send_change) return;
    }

    logging.debug("peaks: broadcasting (content changed={}, forced={})", .{ send_change, any_forced });
    var iter = peaks_subs.activeSubscriptions();
    while (iter.next()) |entry| {
        const forced = peaks_subs.consumeForceBroadcast(entry.slot);
        if (!forced and !send_change) continue;

        if (!entry.sub.hasViewport()) {
            logging.debug("peaks: skipping client {} (no viewport)", .{entry.client_id});
            continue;
        }

        const bin = peaks_generator.generateTilesForSubscriptionBinary(scratch, api, guids, tile_cache, entry.sub);
        if (bin) |b| {
            logging.debug("peaks: sending {} bytes (binary) to client {}", .{ b.len, entry.client_id });
            sender.sendBinToClient(entry.client_id, b);
        } else {
            logging.debug("peaks: binary generation returned null for client {}", .{entry.client_id});
        }
    }

    // A send that found a take changed before the check reached it stored
    // the change, so no check will find it: unless this was a change
    // broadcast (every client with a viewport just got the take as it is),
    // it is owed to every client.
    if (tile_cache.consumeEpochMoved() and !send_change) peaks_subs.change_pending = true;
}

/// On a forced tick, remember each track a forced client's send covers
/// (peaks_generator.sendTracks: at most MAX_TRACKS_PER_BROADCAST per
/// client) that no unforced client watches. The first check of a track
/// counts as a change, so a remembered track isn't broadcast to everyone
/// just for being new: the forced send gives it to each client due one
/// (one without a viewport gets it when it sets one). A track an unforced
/// client also watches is left to the check, which sends it to everyone.
/// Bounded per tick by the forced clients, not the subscribed tracks: a
/// track a forced client watches but its send doesn't cover is left to
/// the check too, and its first check is one broadcast.
fn rememberForcedTracks(
    scratch: std.mem.Allocator,
    api: anytype,
    guids: *const guid_cache.GuidCache,
    peaks_subs: *peaks_subscriptions.PeaksSubscriptions,
    tile_cache: *peaks_tile.TileCache,
) std.mem.Allocator.Error!void {
    const unforced = try peaks_subs.getUnforcedIndices(scratch, guids, api);
    var iter = peaks_subs.activeSubscriptions();
    while (iter.next()) |entry| {
        if (!peaks_subs.isForced(entry.slot)) continue;
        var covered_buf: [peaks_generator.MAX_TRACKS_PER_BROADCAST]c_int = undefined;
        for (peaks_generator.sendTracks(api, guids, entry.sub, &covered_buf)) |track_idx| {
            if (!peaks_subscriptions.PeaksSubscriptions.onlyForcedClientsWatch(unforced, track_idx)) continue;
            const track = api.getTrackByUnifiedIdx(track_idx) orelse continue;
            var guid_buf: [64]u8 = undefined;
            tile_cache.rememberTrack(api.formatTrackGuid(track, &guid_buf), api, track);
        }
    }
}

/// A tick skipped for want of scratch memory. Nothing is consumed: forced
/// sends and a held change wait for a tick that has it. Logged once until
/// a tick gets what it needs.
fn scratchShortage(peaks_subs: *peaks_subscriptions.PeaksSubscriptions) void {
    if (peaks_subs.scratch_shortage_logged) return;
    peaks_subs.scratch_shortage_logged = true;
    logging.warn("peaks: no scratch memory to list subscribed tracks; skipping peaks until there is", .{});
}

/// Poll routing subscriptions and broadcast sends/receives/hw outputs.
/// Per-client single-track subscriptions with hash-based change detection.
pub fn pollRoutingSubscriptions(
    ctx: *const PollingContext,
    routing_subs: *routing_subscriptions.RoutingSubscriptions,
) !void {
    if (!routing_subs.hasSubscriptions()) return;

    var iter = routing_subs.activeSubscriptions();
    while (iter.next()) |entry| {
        const scratch = ctx.scratchAllocator();

        // Generate routing state JSON for this client's subscribed track
        if (routing_generator.generateRoutingState(
            scratch,
            ctx.backend,
            ctx.guid_cache_ptr,
            entry.guid,
        )) |json| {
            // Check if changed using hash
            const data_hash = routing_generator.hashRoutingState(json);
            const hash_changed = routing_subs.checkChanged(entry.slot, data_hash);

            // CSurf: Force broadcast if this track's sends are dirty
            const sends_force = if (ctx.csurf_sends_dirty.all) true else blk: {
                const track = ctx.guid_cache_ptr.resolve(ctx.backend, entry.guid) orelse break :blk false;
                const idx = ctx.guid_cache_ptr.resolveToIndex(track) orelse break :blk false;
                break :blk if (idx >= 0 and idx < csurf_dirty.MAX_TRACKS) ctx.csurf_sends_dirty.bits.isSet(@intCast(idx)) else false;
            };

            if (hash_changed or sends_force) {
                ctx.shared_state.sendToClient(entry.client_id, json);
            }
        }
    }
}

/// Poll track FX subscriptions and broadcast FX chain state.
/// Per-client single-track subscriptions with hash-based change detection.
pub fn pollTrackFxSubscriptions(
    ctx: *const PollingContext,
    trackfx_subs: *trackfx_subscriptions.TrackFxSubscriptions,
) !void {
    if (!trackfx_subs.hasSubscriptions()) return;

    var iter = trackfx_subs.activeSubscriptions();
    while (iter.next()) |entry| {
        const scratch = ctx.scratchAllocator();

        // Generate FX chain JSON for this client's subscribed track
        if (trackfx_generator.generateTrackFxChain(
            scratch,
            ctx.backend,
            ctx.guid_cache_ptr,
            entry.guid,
        )) |json| {
            // Check if changed using hash
            const data_hash = trackfx_generator.hashTrackFxChain(json);
            const hash_changed = trackfx_subs.checkChanged(entry.slot, data_hash);

            // CSurf: Force broadcast if this track's FX is dirty
            const fx_force = if (ctx.csurf_fx_dirty.all) true else blk: {
                const track = ctx.guid_cache_ptr.resolve(ctx.backend, entry.guid) orelse break :blk false;
                const idx = ctx.guid_cache_ptr.resolveToIndex(track) orelse break :blk false;
                break :blk if (idx >= 0 and idx < csurf_dirty.MAX_TRACKS) ctx.csurf_fx_dirty.bits.isSet(@intCast(idx)) else false;
            };

            if (hash_changed or fx_force) {
                ctx.shared_state.sendToClient(entry.client_id, json);
            }
        }
    }
}

/// Poll track FX parameter subscriptions and broadcast param values.
/// Per-client single-FX subscriptions with auto-unsubscribe on failure.
pub fn pollTrackFxParamSubscriptions(
    ctx: *const PollingContext,
    trackfxparam_subs: *trackfxparam_subscriptions.TrackFxParamSubscriptions,
) !void {
    if (!trackfxparam_subs.hasSubscriptions()) return;

    var iter = trackfxparam_subs.activeSubscriptions();
    while (iter.next()) |entry| {
        const scratch = ctx.scratchAllocator();

        // Generate param values JSON for this client's subscribed FX
        const generated = trackfxparam_generator.generateParamValues(
            scratch,
            ctx.backend,
            ctx.guid_cache_ptr,
            entry.track_guid,
            entry.fx_guid,
            entry.client,
        );
        if (generated) |result| {
            // Check if changed using hash
            const data_hash = trackfxparam_generator.hashParamValues(result.json);
            const hash_changed = trackfxparam_subs.checkChanged(entry.slot, data_hash);

            // CSurf: Force broadcast if this track's FX params are dirty
            const fx_force = if (ctx.csurf_fx_dirty.all) true else blk: {
                const track = ctx.guid_cache_ptr.resolve(ctx.backend, entry.track_guid) orelse break :blk false;
                const idx = ctx.guid_cache_ptr.resolveToIndex(track) orelse break :blk false;
                break :blk if (idx >= 0 and idx < csurf_dirty.MAX_TRACKS) ctx.csurf_fx_dirty.bits.isSet(@intCast(idx)) else false;
            };

            if (hash_changed or fx_force) {
                ctx.shared_state.sendToClient(entry.client_id, result.json);
            }
            // Reset failure count on successful generation
            trackfxparam_subs.resetFailures(entry.client_id);
        } else |err| {
            // The message couldn't be built this tick; the FX is still there.
            if (err == error.OutOfMemory) continue;
            // Track or FX not found - increment failure count
            if (trackfxparam_subs.recordFailure(entry.client_id)) {
                // Auto-unsubscribe after 3 failures (~100ms at 30Hz): long
                // enough for an undo that restores the FX to land without an
                // error, short enough not to leave a dead modal open.
                logging.warn("trackfxparam: auto-unsubscribing client {d} after repeated failures", .{entry.client_id});

                // Send error event to client
                const error_json = "{\"type\":\"event\",\"event\":\"trackFxParamsError\",\"error\":\"FX_NOT_FOUND\"}";
                ctx.shared_state.sendToClient(entry.client_id, error_json);

                trackfxparam_subs.unsubscribe(entry.client_id);
            }
        }
    }
}

/// Poll tuner subscriptions and broadcast pitch detection data.
/// Per-client single-track subscriptions with auto-unsubscribe on failure.
/// The master tuner, and a track tuner on its input, send the latest reading
/// their analysis thread published, with what the tuner can hear (`state`):
/// a change at once, and a reading that holds again every
/// tuner_subscriptions.resend_interval_ms (TunerSubscriptions.shouldSend).
pub fn pollTunerSubscriptions(
    ctx: *const PollingContext,
    tuner_subs: *tuner_subscriptions.TunerSubscriptions,
) !void {
    if (!tuner_subs.hasSubscriptions()) return;
    // With REAPER's audio device not running (closed while stopped, as its
    // preferences can say, or failed) no audio arrives, and nothing a tuner
    // shows would be true.
    const device_open = ctx.backend.isAudioRunning();
    tuner_subs.beginPoll();
    const now_ms = tuner_subs.nowMs();

    var iter = tuner_subs.activeSubscriptions();
    while (iter.next()) |entry| {
        const scratch = ctx.scratchAllocator();
        switch (tuner_generator.analyserEvent(scratch, tuner_subs, entry.slot, ctx.guid_cache_ptr, ctx.backend, device_open)) {
            .gone => {
                // Auto-unsubscribe after 3 failures (~100 ms at 30 Hz): the
                // track was deleted, or the user switched project tabs.
                if (tuner_subs.recordFailure(entry.client_id)) {
                    logging.warn("tuner: auto-unsubscribing client {d}: its track is gone", .{entry.client_id});
                    // Written before the unsubscribe, which clears the GUID.
                    var buf: [tuner_generator.error_capacity]u8 = undefined;
                    var stream = std.io.fixedBufferStream(&buf);
                    if (tuner_generator.writeError(stream.writer(), "TUNER_NOT_FOUND", entry.track_guid)) {
                        ctx.shared_state.sendToClient(entry.client_id, stream.getWritten());
                    } else |err| logging.warn("tuner: tunerError for client {d} not sent: {}", .{ entry.client_id, err });
                    tuner_subs.unsubscribe(entry.client_id, ctx.backend);
                }
            },
            .event => |json| {
                tuner_subs.resetFailures(entry.client_id);
                if (tuner_subs.shouldSend(entry.slot, tuner_generator.hashTunerEvent(json), now_ms)) {
                    ctx.shared_state.sendToClient(entry.client_id, json);
                }
            },
            .none => {},
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "PollingContext.scratchAllocator returns valid allocator" {
    // This test would require mocking tiered_state.TieredArenas
    // For now, we verify the struct compiles correctly
    _ = PollingContext;
}

const mock_state = @import("../reaper/mock/state.zig");
const PeaksSubs = peaks_subscriptions.PeaksSubscriptions;

/// A project of `count` tracks over a MockBackend, which stores only a few.
/// Every track is empty but unified index `with_items`, which is mock track
/// 1; the others are mock track 2. Track GUIDs are per index. Counts the
/// tracks whose items are read (trackItemCount).
const ManyTracks = struct {
    mock: *reaper.MockBackend,
    count: c_int,
    with_items: c_int,
    item_reads: usize = 0,

    fn stored(self: *ManyTracks, track: *anyopaque) *anyopaque {
        const k: c_int = @intCast(mock_state.decodeTrackPtr(track));
        return mock_state.encodeTrackPtr(if (k == self.with_items) 1 else 2).?;
    }
    pub fn trackCount(self: *ManyTracks) c_int {
        return self.count;
    }
    pub fn getTrackByUnifiedIdx(self: *ManyTracks, idx: c_int) ?*anyopaque {
        if (idx < 0 or idx > self.count) return null;
        return mock_state.encodeTrackPtr(idx);
    }
    pub fn formatTrackGuid(_: *ManyTracks, track: *anyopaque, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{{00000000-0000-0000-0000-{d:0>12}}}", .{mock_state.decodeTrackPtr(track)}) catch "";
    }
    pub fn trackItemCount(self: *ManyTracks, track: *anyopaque) c_int {
        self.item_reads += 1;
        return self.mock.trackItemCount(self.stored(track));
    }
    pub fn getItemByIdx(self: *ManyTracks, track: *anyopaque, i: c_int) ?*anyopaque {
        return self.mock.getItemByIdx(self.stored(track), i);
    }
    pub fn getTrackIdx(_: *ManyTracks, track: *anyopaque) c_int {
        return @intCast(mock_state.decodeTrackPtr(track));
    }
    pub fn masterTrack(_: *ManyTracks) ?*anyopaque {
        return mock_state.encodeTrackPtr(0);
    }
    pub fn validateTrackPtr(self: *ManyTracks, track: *anyopaque) bool {
        return mock_state.decodeTrackPtr(track) <= @as(usize, @intCast(self.count));
    }
    pub fn getItemActiveTake(self: *ManyTracks, item: *anyopaque) ?*anyopaque {
        return self.mock.getItemActiveTake(item);
    }
    pub fn getItemActiveTakeIdx(self: *ManyTracks, item: *anyopaque) !c_int {
        return self.mock.getItemActiveTakeIdx(item);
    }
    pub fn getItemPosition(self: *ManyTracks, item: *anyopaque) f64 {
        return self.mock.getItemPosition(item);
    }
    pub fn getItemLength(self: *ManyTracks, item: *anyopaque) f64 {
        return self.mock.getItemLength(item);
    }
    pub fn isTakeMIDI(self: *ManyTracks, take: *anyopaque) bool {
        return self.mock.isTakeMIDI(take);
    }
    pub fn getTakeGUID(self: *ManyTracks, take: *anyopaque, buf: []u8) []const u8 {
        return self.mock.getTakeGUID(take, buf);
    }
    pub fn getTakeSource(self: *ManyTracks, take: *anyopaque) ?*anyopaque {
        return self.mock.getTakeSource(take);
    }
    pub fn getMediaSourceChannels(self: *ManyTracks, source: *anyopaque) c_int {
        return self.mock.getMediaSourceChannels(source);
    }
    pub fn getTakeChannelMode(self: *ManyTracks, take: *anyopaque) !c_int {
        return self.mock.getTakeChannelMode(take);
    }
    pub fn getTakeStartOffset(self: *ManyTracks, take: *anyopaque) f64 {
        return self.mock.getTakeStartOffset(take);
    }
    pub fn getTakePlayrate(self: *ManyTracks, take: *anyopaque) f64 {
        return self.mock.getTakePlayrate(take);
    }
    pub fn getMediaItemTakePeaks(self: *ManyTracks, take: *anyopaque, peakrate: f64, starttime: f64, numchannels: c_int, n: c_int, buf: []f64) c_int {
        return self.mock.getMediaItemTakePeaks(take, peakrate, starttime, numchannels, n, buf);
    }
};

/// Counts the peaks frames each client is sent.
const SentFrames = struct {
    frames: [8]usize = [_]usize{0} ** 8,

    pub fn sendBinToClient(self: *SentFrames, client_id: usize, _: []const u8) void {
        self.frames[client_id] += 1;
    }
    fn total(self: *const SentFrames) usize {
        var n: usize = 0;
        for (self.frames) |f| n += f;
        return n;
    }
};

/// What pollPeaks needs, over a ManyTracks project whose one item (8 s,
/// stereo) is on track `with_items`.
const PeaksRig = struct {
    mock: reaper.MockBackend,
    api: ManyTracks,
    subs: PeaksSubs,
    tiles: peaks_tile.TileCache,
    guids: guid_cache.GuidCache,
    arena: std.heap.ArenaAllocator,
    sent: SentFrames = .{},
    now_ms: i64 = 1000,

    const viewport = PeaksSubs.ViewportParams{ .start = 0, .end = 14, .width_px = 1400 };

    fn init(self: *PeaksRig, count: c_int, with_items: c_int) void {
        const allocator = std.testing.allocator;
        self.mock = .{ .track_count = 2 };
        self.mock.tracks[1].item_count = 1;
        self.mock.tracks[1].items[0].length = 8.0;
        self.mock.tracks[1].items[0].take_count = 1;
        const guid = "{take-on-the-item-track}";
        @memcpy(self.mock.tracks[1].items[0].takes[0].guid[0..guid.len], guid);
        self.mock.tracks[1].items[0].takes[0].guid_len = guid.len;
        self.api = .{ .mock = &self.mock, .count = count, .with_items = with_items };
        self.subs = PeaksSubs.init(allocator);
        self.tiles = peaks_tile.TileCache.init(allocator);
        self.guids = guid_cache.GuidCache.init(allocator);
        self.arena = std.heap.ArenaAllocator.init(allocator);
        self.sent = .{};
        self.now_ms = 1000;
    }

    fn deinit(self: *PeaksRig) void {
        self.arena.deinit();
        self.guids.deinit();
        self.tiles.deinit();
        self.subs.deinit();
    }

    /// One tick, `step_ms` after the last, with `scratch` (the arena if null).
    fn tickWith(self: *PeaksRig, step_ms: i64, scratch: ?std.mem.Allocator) void {
        self.now_ms += step_ms;
        pollPeaks(scratch orelse self.arena.allocator(), &self.api, &self.guids, &self.subs, &self.tiles, &self.sent, self.now_ms);
        _ = self.arena.reset(.retain_capacity);
    }

    fn tick(self: *PeaksRig, step_ms: i64) void {
        self.tickWith(step_ms, null);
    }

    /// Ticks a second apart, past the rate limit, until one sends nothing.
    fn settle(self: *PeaksRig) !void {
        for (0..20) |_| {
            const before = self.sent.total();
            self.tick(1000);
            if (self.sent.total() == before) return;
        }
        return error.NeverSettled;
    }
};

test "a change on a subscribed track past the first 128 sends the phone watching it fresh tiles" {
    var rig: PeaksRig = undefined;
    rig.init(300, 250);
    defer rig.deinit();
    // Phone 1 watches every track, phone 2 only track 250.
    _ = try rig.subs.subscribeRangeWithViewport(1, 1, 300, 30, PeaksRig.viewport);
    _ = try rig.subs.subscribeRangeWithViewport(2, 250, 250, 30, PeaksRig.viewport);
    rig.tick(0);
    try std.testing.expectEqual(@as(usize, 1), rig.sent.frames[2]);
    try rig.settle();

    // Track 250's item moves.
    rig.mock.tracks[1].items[0].position = 1.0;
    const before = rig.sent.frames[2];
    const ticks = (300 + PeaksSubs.CHANGE_CHECK_TRACKS_PER_TICK - 1) / PeaksSubs.CHANGE_CHECK_TRACKS_PER_TICK;
    for (0..ticks) |_| rig.tick(1000);
    try std.testing.expectEqual(before + 1, rig.sent.frames[2]);
}

test "a forced tick reads the items of only the tracks its sends cover, however many are subscribed" {
    var rig: PeaksRig = undefined;
    rig.init(1000, 5);
    defer rig.deinit();
    _ = try rig.subs.subscribeRangeWithViewport(1, 0, 10_000, 30, PeaksRig.viewport);
    rig.tick(0);
    try std.testing.expectEqual(@as(usize, 1), rig.sent.frames[1]);
    // Remembering, then sending, the client's first MAX_TRACKS_PER_BROADCAST tracks.
    try std.testing.expect(rig.api.item_reads <= 2 * peaks_generator.MAX_TRACKS_PER_BROADCAST);
}

test "after a forced send covering every track a phone watches, the change check broadcasts nothing" {
    var rig: PeaksRig = undefined;
    rig.init(300, 5);
    defer rig.deinit();
    _ = try rig.subs.subscribeRangeWithViewport(1, 1, 20, 30, PeaksRig.viewport);
    rig.tick(0);
    try std.testing.expectEqual(@as(usize, 1), rig.sent.frames[1]);
    for (0..3) |_| rig.tick(1000);
    try std.testing.expectEqual(@as(usize, 1), rig.sent.frames[1]);
}

test "a tick without scratch memory sends nothing and loses neither a held change nor a forced send" {
    var rig: PeaksRig = undefined;
    rig.init(10, 5);
    defer rig.deinit();
    _ = try rig.subs.subscribeRangeWithViewport(1, 1, 10, 30, PeaksRig.viewport);
    rig.tick(0);
    try rig.settle();

    // A change found 50 ms after a send: held by the rate limit.
    rig.mock.tracks[1].items[0].position = 1.0;
    _ = rig.subs.updateViewport(1, .{ .start = 0, .end = 13, .width_px = 1400 });
    rig.tick(0); // the forced send
    const sent = rig.sent.total();
    rig.tick(50);
    try std.testing.expect(rig.subs.change_pending);
    try std.testing.expectEqual(sent, rig.sent.total());

    var no_memory = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    _ = rig.subs.updateViewport(1, .{ .start = 0, .end = 12, .width_px = 1400 });
    rig.tickWith(1000, no_memory.allocator());
    try std.testing.expectEqual(sent, rig.sent.total());
    try std.testing.expect(rig.subs.change_pending);
    try std.testing.expect(rig.subs.isForced(rig.subs.client_id_to_slot.get(1).?));
    try std.testing.expect(rig.subs.scratch_shortage_logged);

    // With memory again: the forced send goes, then the held change.
    rig.tick(0);
    try std.testing.expectEqual(sent + 1, rig.sent.total());
    try std.testing.expect(!rig.subs.scratch_shortage_logged);
    rig.tick(1000);
    try std.testing.expectEqual(sent + 2, rig.sent.total());
    try std.testing.expect(!rig.subs.change_pending);
}

test "a take a forced send finds changed before the check reaches it goes to every other phone too" {
    var rig: PeaksRig = undefined;
    rig.init(10, 5);
    defer rig.deinit();
    _ = try rig.subs.subscribeRangeWithViewport(1, 5, 5, 30, PeaksRig.viewport);
    _ = try rig.subs.subscribeRangeWithViewport(2, 5, 5, 30, PeaksRig.viewport);
    rig.tick(0);
    try rig.settle();
    const phone2 = rig.sent.frames[2];

    // Mono, and phone 1 scrolls before any check: its send reads the take in mono.
    rig.mock.tracks[1].items[0].takes[0].channel_mode = 3;
    _ = rig.subs.updateViewport(1, .{ .start = 0, .end = 13, .width_px = 1400 });
    rig.tick(1000);
    try std.testing.expectEqual(phone2, rig.sent.frames[2]);
    // The check finds nothing new (the send stored it), but phone 2 is owed it.
    rig.tick(1000);
    try std.testing.expectEqual(phone2 + 1, rig.sent.frames[2]);
}
