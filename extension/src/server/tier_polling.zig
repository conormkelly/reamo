//! Tier Polling Module
//!
//! Extracted from main.zig doProcessing() to enable unit testing of
//! tier-based polling behaviors.
//!
//! Polling tiers:
//! - HIGH (30Hz): Transport, Tracks, Metering - real-time responsiveness
//! - MEDIUM (5Hz): Project, Markers, Regions, Items, FX, Sends - less frequent
//! - LOW (1Hz): Tempomap, Skeleton, Project Notes - rarely changes
//!
//! Each tier uses arena allocation for efficient change detection via
//! double-buffering (current vs previous state comparison).

const std = @import("std");
const reaper = @import("../reaper.zig");
const logging = @import("../core/logging.zig");
const tiered_state = @import("tiered_state.zig");
const guid_cache = @import("../state/guid_cache.zig");
const ws_server = @import("ws_server.zig");
const csurf = @import("csurf.zig");
const csurf_dirty = @import("csurf_dirty.zig");

// State types
const transport = @import("../state/transport.zig");
const tracks = @import("../state/tracks.zig");
const markers = @import("../state/markers.zig");
const items = @import("../state/items.zig");
const project = @import("../state/project.zig");
const tempomap = @import("../state/tempomap.zig");
const fx = @import("../state/fx.zig");
const sends = @import("../state/sends.zig");
const track_skeleton = @import("../state/track_skeleton.zig");
const project_notes = @import("../subscriptions/project_notes.zig");
const playlist = @import("../state/playlist.zig");

// Subscriptions
const track_subscriptions = @import("../subscriptions/track_subscriptions.zig");

// Commands (for project_notes_cmds.formatChangedEvent)
const commands = @import("../commands/mod.zig");

// Caches
const item_guid_cache = @import("../state/item_guid_cache.zig");

// Constants
pub const MEDIUM_TIER_INTERVAL = tiered_state.MEDIUM_TIER_INTERVAL; // 30Hz / 6 = 5Hz
pub const LOW_TIER_INTERVAL = tiered_state.LOW_TIER_INTERVAL; // 30Hz / 30 = 1Hz

/// Context shared across all tier polling functions.
/// Contains references to infrastructure needed for polling and broadcasting.
/// This struct is READ-ONLY - mutable state is passed separately.
pub const TierContext = struct {
    /// Tiered arena allocator for scratch memory
    tiered: *tiered_state.TieredArenas,
    /// REAPER API backend
    backend: *reaper.RealBackend,
    /// REAPER API reference (for track count, notes polling, etc.)
    api: *const reaper.Api,
    /// WebSocket shared state for broadcasting
    shared_state: *ws_server.SharedState,
    /// GUID cache for track lookups (optional - may not be initialized)
    guid_cache_ptr: ?*guid_cache.GuidCache,
    /// Item GUID cache (optional - rebuilt during medium tier)
    item_cache_ptr: ?*item_guid_cache.ItemGuidCache,
    /// Track subscriptions (optional)
    track_subs: ?*track_subscriptions.TrackSubscriptions,
    /// Project notes subscriptions (optional)
    notes_subs: ?*project_notes.NotesSubscriptions,
    /// Allocator for skeleton buffer reallocation
    allocator: std.mem.Allocator,
    /// CSurf dirty flags reference (optional)
    dirty_flags: ?*csurf_dirty.DirtyFlags,

    /// Create a scratch allocator from the tiered arenas
    pub fn scratchAllocator(self: *const TierContext) std.mem.Allocator {
        return self.tiered.scratchAllocator();
    }
};

/// Mutable state that persists across frames.
/// Passed by pointer so tier polling can update change detection state.
pub const MutableState = struct {
    /// Previous track hash for change detection
    prev_tracks_hash: *u64,
    /// Hash of the track indices polled last frame (subscription mode), so
    /// drift logging can tell a subscription change from a missed callback
    prev_polled_indices_hash: *u64,
    /// Rate-limit timestamp for drift warnings
    last_drift_log_time: *i64,
    /// Previous skeleton state for comparison
    last_skeleton: *track_skeleton.State,
    /// Persistent buffer for skeleton data
    last_skeleton_buf: *[]track_skeleton.SkeletonTrack,
    /// Cached markers state for playlist engine
    last_markers: *markers.State,
    /// Persistent buffer for markers
    last_markers_buf: *[markers.MAX_MARKERS]markers.Marker,
    /// Persistent buffer for regions
    last_regions_buf: *[markers.MAX_REGIONS]markers.Region,
    /// Previous playlist state for change detection
    last_playlist: *playlist.State,
    /// Current playlist state (may be modified)
    playlist_state: *playlist.State,
};

/// Logs when a polled list reaches the cap on what phones are sent, and when
/// it falls back under: a project past a cap otherwise loses the rest on
/// every phone without a trace, polled 5 times a second.
const CapLatch = struct {
    capped: bool = false,

    fn update(self: *CapLatch, what: []const u8, len: usize, cap: usize) void {
        const capped = len >= cap;
        if (capped == self.capped) return;
        self.capped = capped;
        if (capped) {
            logging.warn("The project has {d} or more {s}; phones get the first {d}", .{ cap, what, cap });
        } else {
            logging.info("All the project's {s} reach phones again", .{what});
        }
    }
};

var g_markers_cap: CapLatch = .{};
var g_regions_cap: CapLatch = .{};
var g_items_cap: CapLatch = .{};

/// Result from HIGH tier polling.
/// Contains transport state for use by playlist engine in main.zig.
pub const HighTierResult = struct {
    /// Current transport state (pointer into arena)
    transport_state: *const transport.State,
};

// ============================================================================
// Helper functions (moved from main.zig)
// ============================================================================

/// Compare item slices for change detection
fn itemsSliceEql(a: []const items.Item, b: []const items.Item) bool {
    if (a.len != b.len) return false;
    for (a, b) |*item_a, *item_b| {
        if (!item_a.eql(item_b)) return false;
    }
    return true;
}

/// Compare FX slot slices for change detection
fn fxSliceEql(a: []const fx.FxSlot, b: []const fx.FxSlot) bool {
    if (a.len != b.len) return false;
    for (a, b) |*fx_a, *fx_b| {
        if (!fx_a.eql(fx_b.*)) return false;
    }
    return true;
}

/// Compare send slot slices for change detection
fn sendsSliceEql(a: []const sends.SendSlot, b: []const sends.SendSlot) bool {
    if (a.len != b.len) return false;
    for (a, b) |*send_a, *send_b| {
        if (!send_a.eql(send_b.*)) return false;
    }
    return true;
}

// ============================================================================
// HIGH TIER (30Hz)
// ============================================================================

/// Poll HIGH tier (30Hz): Transport, Tracks, Metering.
/// Returns transport state for playlist engine synchronization.
pub fn pollHighTier(
    ctx: *const TierContext,
    mutable: *MutableState,
    force_transport: bool,
    csurf_track_dirty: bool,
) !HighTierResult {
    const high_state = ctx.tiered.high.currentState();
    const high_prev = ctx.tiered.high.previousState();

    // ========================================================================
    // Transport polling
    // ========================================================================
    high_state.transport = transport.State.poll(ctx.backend);
    const current_transport = &high_state.transport;

    // Broadcast when changed OR when CSurf force flag set
    if (force_transport or !current_transport.eql(high_prev.transport)) {
        const state_changed = force_transport or !current_transport.stateOnlyEql(high_prev.transport);
        const is_playing = transport.PlayState.isPlaying(current_transport.play_state);

        const scratch = ctx.scratchAllocator();
        if (state_changed) {
            // State changed (play/pause, BPM, time sig, etc.) - send full transport
            if (current_transport.toJsonAlloc(scratch)) |json| {
                ctx.shared_state.broadcast(json);
            } else |_| {}
        } else if (is_playing) {
            // Only position changed during playback - send lightweight tick
            if (current_transport.toTickJsonAlloc(scratch)) |json| {
                ctx.shared_state.broadcast(json);
            } else |_| {}
        } else {
            // Stopped and only position changed (cursor moved) - send full transport
            if (current_transport.toJsonAlloc(scratch)) |json| {
                ctx.shared_state.broadcast(json);
            } else |_| {}
        }
    }

    // ========================================================================
    // Track polling (subscription mode)
    // ========================================================================
    const high_alloc = ctx.tiered.high.currentAllocator();
    const total_tracks: usize = @intCast(@max(0, ctx.backend.trackCount()));

    if (ctx.track_subs) |track_subs| {
        if (track_subs.hasSubscriptions()) {
            // Get subscribed track indices from all clients
            const cache = ctx.guid_cache_ptr orelse {
                logging.err("GUID cache not initialized for track subscriptions", .{});
                return error.GuidCacheNotInitialized;
            };
            var subscribed_buf: [track_subscriptions.MAX_TRACKS_PER_CLIENT * track_subscriptions.MAX_CLIENTS]c_int = undefined;
            const subscribed_indices = track_subs.getSubscribedIndices(cache, ctx.backend, &subscribed_buf);

            // Poll only subscribed tracks
            const track_state = tracks.State.pollIndices(high_alloc, ctx.backend, subscribed_indices) catch |err| {
                logging.err("Failed to poll tracks: {s}", .{@errorName(err)});
                return err;
            };
            high_state.tracks = track_state.tracks;

            // Poll metering for subscribed tracks
            high_state.metering.pollSubscribedInto(ctx.api, subscribed_indices);

            // Drift logging: the same tracks were polled as last frame, they
            // changed, and no CSurf dirty flag said so, i.e. REAPER skipped a
            // callback. A subscribe or scroll changes the polled set instead.
            const temp_state = tracks.State{ .tracks = high_state.tracks };
            const current_hash = temp_state.computeHash();
            const indices_hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(subscribed_indices));
            const same_indices = indices_hash == mutable.prev_polled_indices_hash.*;
            mutable.prev_polled_indices_hash.* = indices_hash;
            if (csurf.enabled and same_indices and current_hash != mutable.prev_tracks_hash.* and !csurf_track_dirty) {
                const now_ms = std.time.milliTimestamp();
                if (now_ms - mutable.last_drift_log_time.* > 1000) {
                    logging.debug("Track state drift detected without dirty flag (undo/selection/FX drag?)", .{});
                    mutable.last_drift_log_time.* = now_ms;
                }
            }
            mutable.prev_tracks_hash.* = current_hash;

            const sent = sendTracksToSubscribers(
                ctx.scratchAllocator(),
                ctx.shared_state,
                track_subs,
                cache,
                ctx.backend,
                high_state.tracks,
                &high_state.metering,
                total_tracks,
            );
            if (sent.failure) |err| {
                // Those clients missed this frame's events (tracks are retried
                // next frame); usually the per-frame scratch running out.
                const now_ms = std.time.milliTimestamp();
                if (now_ms - g_last_track_send_failure_log_ms > 1000) {
                    logging.warn("Couldn't build some clients' tracks or meters: {s}", .{@errorName(err)});
                    g_last_track_send_failure_log_ms = now_ms;
                }
            }
        } else {
            // No track subscriptions - skip track polling entirely
            high_state.tracks = &.{};
            high_state.metering.count = 0;
        }
    } else {
        // Track subscriptions not initialized - fall back to full polling
        const track_state = tracks.State.poll(high_alloc, ctx.backend) catch |err| {
            logging.err("Failed to poll tracks: {s}", .{@errorName(err)});
            return err;
        };
        high_state.tracks = track_state.tracks;

        // Poll all meters when no subscription system
        high_state.metering.pollInto(ctx.api);

        // CSurf: Hash-based change detection (fallback path)
        const temp_state = tracks.State{ .tracks = high_state.tracks };
        const current_hash = temp_state.computeHash();
        const hash_changed = current_hash != mutable.prev_tracks_hash.*;
        const tracks_changed = hash_changed or csurf_track_dirty;

        // Drift logging
        if (csurf.enabled and hash_changed and !csurf_track_dirty) {
            const now_ms = std.time.milliTimestamp();
            if (now_ms - mutable.last_drift_log_time.* > 1000) {
                logging.debug("Track state drift detected without dirty flag (undo/selection/FX drag?)", .{});
                mutable.last_drift_log_time.* = now_ms;
            }
        }

        if (tracks_changed) {
            const scratch = ctx.scratchAllocator();
            if (temp_state.toJsonWithTotalAlloc(scratch, null, total_tracks)) |json| {
                ctx.shared_state.broadcast(json);
            } else |_| {}
            mutable.prev_tracks_hash.* = current_hash;
        }

        // Broadcast separate meters event
        if (high_state.metering.hasData()) {
            const scratch = ctx.scratchAllocator();
            if (high_state.metering.toJsonEventAlloc(scratch, high_state.tracks)) |json| {
                ctx.shared_state.broadcast(json);
            } else |_| {}
        }
    }

    return HighTierResult{
        .transport_state = current_transport,
    };
}

/// One subscription's share of a frame's polled tracks and meters. Clients
/// whose subscriptions resolve to the same indices share one, so each event
/// is serialised once per distinct subscription, not once per client.
const SubscriberView = struct {
    indices: []const c_int,
    state: tracks.State,
    meters: *tracks.MeteringState,
    /// Covers every field of the tracks event, the project's track total included
    hash: u64,
    tracks_json: ?[]const u8 = null,
    meters_json: ?[]const u8 = null,

    fn init(
        scratch: std.mem.Allocator,
        indices: []const c_int,
        polled: []const tracks.Track,
        metering: *const tracks.MeteringState,
        total: usize,
    ) std.mem.Allocator.Error!SubscriberView {
        // polled, metering and indices are all in ascending index order
        const subset = try scratch.alloc(tracks.Track, @min(indices.len, polled.len));
        var n: usize = 0;
        var i: usize = 0;
        for (polled) |*t| {
            while (i < indices.len and indices[i] < t.idx) i += 1;
            if (i == indices.len) break;
            if (indices[i] == t.idx) {
                subset[n] = t.*;
                n += 1;
            }
        }
        const state = tracks.State{ .tracks = subset[0..n] };

        const meters = try scratch.create(tracks.MeteringState);
        meters.count = 0;
        i = 0;
        for (metering.meters[0..metering.count]) |m| {
            while (i < indices.len and indices[i] < m.track_idx) i += 1;
            if (i == indices.len) break;
            if (indices[i] == m.track_idx) {
                meters.meters[meters.count] = m;
                meters.count += 1;
            }
        }

        var hasher = std.hash.Wyhash.init(state.computeHash());
        hasher.update(std.mem.asBytes(&total));
        return .{ .indices = indices, .state = state, .meters = meters, .hash = hasher.final() };
    }
};

/// Send each subscribed client the tracks and meters it subscribed to, and
/// no others, out of this frame's poll of every client's tracks: a tracks
/// event when its tracks differ from what it was last sent (or it has just
/// subscribed), and a meters event every frame its tracks have meters.
/// `polled` and `metering` hold the union of the subscriptions in ascending
/// index order. `sender` is the SharedState (or a test double); only clients
/// that completed the handshake receive anything. A client whose events
/// can't be built this frame is skipped (its tracks are retried next frame);
/// the result carries the first such error.
pub fn sendTracksToSubscribers(
    scratch: std.mem.Allocator,
    sender: anytype,
    subs: *track_subscriptions.TrackSubscriptions,
    cache: *const guid_cache.GuidCache,
    api: anytype,
    polled: []const tracks.Track,
    metering: *const tracks.MeteringState,
    total: usize,
) SendResult {
    var views: [track_subscriptions.MAX_CLIENTS]SubscriberView = undefined;
    var view_count: usize = 0;
    var result: SendResult = .{};

    var iter = subs.activeClients();
    while (iter.next()) |entry| {
        const indices = track_subscriptions.TrackSubscriptions.clientIndices(entry.sub, cache, api, scratch) catch |err| {
            result.failure = result.failure orelse err;
            continue;
        };

        const view: *SubscriberView = for (views[0..view_count]) |*v| {
            if (std.mem.eql(c_int, v.indices, indices)) break v;
        } else blk: {
            const v = &views[view_count];
            v.* = SubscriberView.init(scratch, indices, polled, metering, total) catch |err| {
                result.failure = result.failure orelse err;
                continue;
            };
            view_count += 1;
            break :blk v;
        };

        const changed = if (entry.sub.sent_hash) |h| h != view.hash else true;
        if (changed) {
            if (view.tracks_json == null) {
                view.tracks_json = view.state.toJsonWithTotalAlloc(scratch, null, total) catch |err| blk: {
                    result.failure = result.failure orelse err;
                    break :blk null;
                };
            }
            if (view.tracks_json) |json| {
                if (sender.sendToHandshakenClient(entry.client_id, json)) {
                    entry.sub.sent_hash = view.hash;
                    result.sent_tracks = true;
                }
            }
        }

        if (view.meters.hasData()) {
            if (view.meters_json == null) {
                view.meters_json = view.meters.toJsonEventAlloc(scratch, view.state.tracks) catch |err| blk: {
                    result.failure = result.failure orelse err;
                    break :blk null;
                };
            }
            if (view.meters_json) |json| _ = sender.sendToHandshakenClient(entry.client_id, json);
        }
    }
    return result;
}

pub const SendResult = struct {
    /// Some client was sent a tracks event.
    sent_tracks: bool = false,
    /// The first error building a client's events this frame, if any.
    failure: ?anyerror = null,
};

/// Main thread only (the high tier's).
var g_last_track_send_failure_log_ms: i64 = 0;

// ============================================================================
// MEDIUM TIER (5Hz)
// ============================================================================

/// Poll MEDIUM tier (5Hz): Project, Markers, Regions, Items, FX, Sends.
/// Also handles playlist state change detection and persistence.
pub fn pollMediumTier(
    ctx: *const TierContext,
    mutable: *MutableState,
    force_markers: bool,
    frame_counter: u32,
) !void {
    const medium_tick = frame_counter % MEDIUM_TIER_INTERVAL == 0;

    // ========================================================================
    // Immediate markers poll (CSurf triggered, skip if on medium tick)
    // ========================================================================
    if (force_markers and !medium_tick) {
        try pollMarkersImmediate(ctx, mutable);
    }

    // ========================================================================
    // Regular medium tier polling
    // ========================================================================
    if (medium_tick) {
        try pollMediumTierRegular(ctx, mutable);
    }
}

/// Immediate markers poll when CSurf dirty flag is set.
fn pollMarkersImmediate(ctx: *const TierContext, mutable: *MutableState) !void {
    const medium_alloc = ctx.tiered.medium.currentAllocator();
    const medium_state = ctx.tiered.medium.currentState();
    const scratch = ctx.scratchAllocator();

    // Compare with this period's latest poll, which is what clients last
    // heard, not with the previous period's: an edit undone within one
    // period would otherwise match the previous period and never be sent,
    // leaving clients showing the edit.
    const last_sent = medium_state.*;

    // Poll markers/regions into MEDIUM arena
    const marker_state = markers.State.poll(medium_alloc, ctx.backend) catch |err| {
        logging.err("CSurf immediate markers poll failed: {s}", .{@errorName(err)});
        return err;
    };
    medium_state.markers = marker_state.markers;
    medium_state.regions = marker_state.regions;
    medium_state.bar_offset = marker_state.bar_offset;

    broadcastMarkersIfChanged(ctx, medium_state, &last_sent, scratch);

    // Update g_last_markers cache for playlist engine
    updateMarkersCache(mutable, medium_state.markers, medium_state.regions, medium_state.bar_offset);
}

/// Regular medium tier polling (5Hz).
fn pollMediumTierRegular(ctx: *const TierContext, mutable: *MutableState) !void {
    const medium_alloc = ctx.tiered.medium.currentAllocator();
    const medium_state = ctx.tiered.medium.currentState();
    const medium_prev = ctx.tiered.medium.previousState();
    const scratch = ctx.scratchAllocator();

    // ========================================================================
    // Project state
    // ========================================================================
    medium_state.project = project.State.poll(ctx.backend);
    medium_state.project.memory_warning = ctx.tiered.isMemoryWarning();

    // Check for project identity change
    if (medium_prev.project.projectChanged(&medium_state.project)) {
        // The name is the user's (often a client's or artist's): debug only.
        logging.info("Project changed ({s})", .{if (medium_state.project.projectName().len > 0) "saved project" else "unsaved project"});
        logging.debug("Project name: {s}", .{medium_state.project.projectName()});

        // Resize arenas if new project has significantly different entity counts
        const new_counts = tiered_state.EntityCounts.countFromApi(ctx.backend);
        const new_sizes = tiered_state.CalculatedSizes.fromCounts(new_counts);

        if (ctx.tiered.shouldResize(new_sizes, 25)) {
            var counts_buf: [256]u8 = undefined;
            var sizes_buf: [256]u8 = undefined;
            if (new_counts.format(&counts_buf)) |counts_str| {
                logging.info("New project entities: {s}", .{counts_str});
            }
            if (new_sizes.format(&sizes_buf)) |sizes_str| {
                logging.info("Resizing arenas: {s}", .{sizes_str});
            }

            // This poll holds state from the arenas, so the resize waits for
            // the next frame boundary.
            ctx.tiered.requestResize(new_sizes);
        }

    }

    // Playlists belong to the project now open (usually a no-op; see followProject).
    if (mutable.playlist_state.followProject(ctx.backend, medium_state.project.identity())) {
        if (mutable.playlist_state.toJsonAlloc(scratch, null)) |json| {
            ctx.shared_state.broadcast(json);
        } else |_| {}
        mutable.last_playlist.* = mutable.playlist_state.*;
    }

    // Broadcast project state if changed
    if (!medium_state.project.eql(&medium_prev.project)) {
        if (medium_state.project.toJsonAlloc(scratch)) |json| {
            ctx.shared_state.broadcast(json);
        } else |_| {}
    }

    // ========================================================================
    // Markers/Regions
    // ========================================================================
    const marker_state = markers.State.poll(medium_alloc, ctx.backend) catch |err| {
        logging.err("Failed to poll markers: {s}", .{@errorName(err)});
        return err;
    };
    medium_state.markers = marker_state.markers;
    medium_state.regions = marker_state.regions;
    medium_state.bar_offset = marker_state.bar_offset;
    g_markers_cap.update("markers", marker_state.markers.len, markers.MAX_MARKERS);
    g_regions_cap.update("regions", marker_state.regions.len, markers.MAX_REGIONS);

    broadcastMarkersIfChanged(ctx, medium_state, medium_prev, scratch);

    // Update markers cache for playlist engine
    updateMarkersCache(mutable, medium_state.markers, medium_state.regions, medium_state.bar_offset);

    // ========================================================================
    // Items
    // ========================================================================
    const item_state = items.State.poll(medium_alloc, ctx.backend) catch |err| {
        logging.err("Failed to poll items: {s}", .{@errorName(err)});
        return err;
    };
    medium_state.items = item_state.items;
    g_items_cap.update("items", item_state.items.len, items.MAX_ITEMS);

    // Rebuild item GUID cache
    if (ctx.item_cache_ptr) |icache| {
        icache.rebuildFromItems(items, medium_state.items) catch |err| {
            logging.warn("Failed to rebuild item cache: {s}", .{@errorName(err)});
        };
    }

    // Broadcast items if changed
    if (!itemsSliceEql(medium_state.items, medium_prev.items)) {
        const temp_item_state = items.State{ .items = medium_state.items };
        if (temp_item_state.itemsToJsonAlloc(scratch)) |json| {
            ctx.shared_state.broadcast(json);
        } else |_| {}
    }

    // ========================================================================
    // Playlist state change detection
    // ========================================================================
    if (!mutable.playlist_state.eql(mutable.last_playlist)) {
        if (mutable.playlist_state.toJsonAlloc(scratch, medium_state.regions)) |json| {
            ctx.shared_state.broadcast(json);
        } else |_| {}
        mutable.last_playlist.* = mutable.playlist_state.*;
    }

    // Deferred playlist persistence
    _ = mutable.playlist_state.flushIfNeeded(ctx.backend, ctx.backend.timePrecise());

    // ========================================================================
    // FX
    // ========================================================================
    const fx_state = fx.State.poll(medium_alloc, ctx.backend) catch |err| {
        logging.err("Failed to poll FX: {s}", .{@errorName(err)});
        return err;
    };
    medium_state.fx_slots = fx_state.fx;

    if (!fxSliceEql(medium_state.fx_slots, medium_prev.fx_slots)) {
        const temp_fx_state = fx.State{ .fx = medium_state.fx_slots };
        if (temp_fx_state.toJsonAlloc(scratch)) |json| {
            ctx.shared_state.broadcast(json);
        } else |_| {}
    }

    // ========================================================================
    // Sends
    // ========================================================================
    const sends_state = sends.State.poll(medium_alloc, ctx.backend) catch |err| {
        logging.err("Failed to poll sends: {s}", .{@errorName(err)});
        return err;
    };
    medium_state.send_slots = sends_state.sends;

    if (!sendsSliceEql(medium_state.send_slots, medium_prev.send_slots)) {
        const temp_sends_state = sends.State{ .sends = medium_state.send_slots };
        if (temp_sends_state.toJsonAlloc(scratch)) |json| {
            ctx.shared_state.broadcast(json);
        } else |_| {}
    }
}

/// Broadcast the markers and regions events whose content differs from the
/// previous medium-tier poll.
fn broadcastMarkersIfChanged(
    ctx: *const TierContext,
    cur: *const tiered_state.MediumTierState,
    prev: *const tiered_state.MediumTierState,
    scratch: std.mem.Allocator,
) void {
    const cur_view = markers.State{ .markers = cur.markers, .regions = cur.regions, .bar_offset = cur.bar_offset };
    const prev_view = markers.State{ .markers = prev.markers, .regions = prev.regions, .bar_offset = prev.bar_offset };

    if (cur_view.markersChanged(&prev_view)) {
        if (cur_view.markersToJsonAlloc(scratch)) |json| {
            ctx.shared_state.broadcast(json);
        } else |_| {}
    }
    if (cur_view.regionsChanged(&prev_view)) {
        if (cur_view.regionsToJsonAlloc(scratch)) |json| {
            ctx.shared_state.broadcast(json);
        } else |_| {}
    }
}

/// Update the persistent markers cache for playlist engine.
fn updateMarkersCache(
    mutable: *MutableState,
    new_markers: []const markers.Marker,
    new_regions: []const markers.Region,
    bar_offset: c_int,
) void {
    const cur_markers_len = new_markers.len;
    const cur_regions_len = new_regions.len;
    @memcpy(mutable.last_markers_buf[0..cur_markers_len], new_markers);
    @memcpy(mutable.last_regions_buf[0..cur_regions_len], new_regions);
    mutable.last_markers.markers = mutable.last_markers_buf[0..cur_markers_len];
    mutable.last_markers.regions = mutable.last_regions_buf[0..cur_regions_len];
    mutable.last_markers.bar_offset = bar_offset;
}

// ============================================================================
// LOW TIER (1Hz)
// ============================================================================

/// Poll LOW tier (1Hz): Tempomap, Skeleton, Project Notes.
pub fn pollLowTier(
    ctx: *const TierContext,
    mutable: *MutableState,
    force_tempo: bool,
    frame_counter: u32,
    notes_buf: *[256]u8,
) !void {
    const low_tick = frame_counter % LOW_TIER_INTERVAL == 0;

    // ========================================================================
    // Immediate tempo poll (CSurf triggered, skip if on low tick)
    // ========================================================================
    if (force_tempo and !low_tick) {
        try pollTempoImmediate(ctx);
    }

    // ========================================================================
    // Regular low tier polling
    // ========================================================================
    if (low_tick) {
        try pollLowTierRegular(ctx, mutable, notes_buf);
    }
}

/// Immediate tempo poll when CSurf dirty flag is set.
fn pollTempoImmediate(ctx: *const TierContext) !void {
    // This period's latest poll is what clients last heard (see
    // pollMarkersImmediate).
    pollTempoMap(ctx, ctx.tiered.low.currentState().tempomap);
}

/// Poll the tempo map and broadcast it if it differs from `last_sent`. The
/// markers go in the frame's scratch arena; the low tier keeps only their
/// summary.
fn pollTempoMap(ctx: *const TierContext, last_sent: tempomap.Summary) void {
    const low_state = ctx.tiered.low.currentState();
    const scratch = ctx.scratchAllocator();

    const tempo = tempomap.State.poll(scratch, ctx.backend) catch |err| {
        logging.err("Tempo map poll failed: {s}", .{@errorName(err)});
        return;
    };
    // Decide before storing the summary: `last_sent` may be the very field
    // being overwritten (Zig can pass a struct parameter by reference).
    const changed = tempo.changed(last_sent);
    low_state.tempomap = tempo.summary();
    if (changed) {
        if (tempo.toJsonAlloc(scratch)) |json| {
            ctx.shared_state.broadcast(json);
        } else |_| {}
    }
}

/// Regular low tier polling (1Hz).
fn pollLowTierRegular(
    ctx: *const TierContext,
    mutable: *MutableState,
    notes_buf: *[256]u8,
) !void {
    const low_alloc = ctx.tiered.low.currentAllocator();

    // ========================================================================
    // Tempomap
    // ========================================================================
    pollTempoMap(ctx, ctx.tiered.low.previousState().tempomap);

    // ========================================================================
    // Track skeleton
    // ========================================================================
    const current_skeleton = track_skeleton.State.poll(low_alloc, ctx.backend) catch |err| {
        logging.err("Failed to poll skeleton: {s}", .{@errorName(err)});
        return err;
    };

    if (!current_skeleton.eql(mutable.last_skeleton)) {
        // Track structure changed - rebuild GUID cache and broadcast
        if (ctx.guid_cache_ptr) |cache| {
            cache.rebuild(ctx.backend) catch |err| {
                logging.err("Failed to rebuild GUID cache: {s}", .{@errorName(err)});
            };
        }

        // Broadcast skeleton event
        const scratch = ctx.scratchAllocator();
        if (current_skeleton.toJsonAlloc(scratch)) |json| {
            ctx.shared_state.broadcast(json);
        } else |_| {}

        logging.debug("Track skeleton changed: {d} tracks", .{current_skeleton.count()});
    }

    // Keep a copy for the next comparison: current_skeleton lives in the low
    // tier's arena, which is reset before the next poll. If the copy can't
    // be made, the next poll sees a change and broadcasts again.
    const n = current_skeleton.tracks.len;
    if (mutable.last_skeleton_buf.len < n) {
        if (ctx.allocator.alloc(track_skeleton.SkeletonTrack, n)) |grown| {
            if (mutable.last_skeleton_buf.len > 0) ctx.allocator.free(mutable.last_skeleton_buf.*);
            mutable.last_skeleton_buf.* = grown;
        } else |err| {
            logging.warn("Track skeleton: can't keep a copy of {d} tracks ({s}); it will be resent every poll", .{ n, @errorName(err) });
        }
    }
    if (mutable.last_skeleton_buf.len >= n) {
        @memcpy(mutable.last_skeleton_buf.*[0..n], current_skeleton.tracks);
        mutable.last_skeleton.tracks = mutable.last_skeleton_buf.*[0..n];
    }

    // ========================================================================
    // Project notes (only if subscribers)
    // ========================================================================
    if (ctx.notes_subs) |notes_subs| {
        if (notes_subs.poll(ctx.api)) |change| {
            if (commands.project_notes_cmds.formatChangedEvent(change.hash, notes_buf)) |json| {
                ctx.shared_state.broadcast(json);
            }
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "TierContext.scratchAllocator returns valid allocator" {
    // Verify struct compiles correctly
    _ = TierContext;
    _ = MutableState;
    _ = HighTierResult;
}

test "tier interval constants are correct" {
    try std.testing.expectEqual(@as(u32, 6), MEDIUM_TIER_INTERVAL);
    try std.testing.expectEqual(@as(u32, 30), LOW_TIER_INTERVAL);
}

/// Records what sendTracksToSubscribers sends, in place of SharedState.
const RecordingSender = struct {
    const Sent = struct { client_id: usize, json: []const u8 };

    handshaken: []const usize,
    sent: [64]Sent = undefined,
    count: usize = 0,

    pub fn sendToHandshakenClient(self: *RecordingSender, client_id: usize, message: []const u8) bool {
        if (std.mem.indexOfScalar(usize, self.handshaken, client_id) == null) return false;
        self.sent[self.count] = .{ .client_id = client_id, .json = message };
        self.count += 1;
        return true;
    }

    /// The JSON of the `event` events sent to `client_id`.
    fn events(self: *const RecordingSender, client_id: usize, event: []const u8, out: [][]const u8) [][]const u8 {
        var tag_buf: [64]u8 = undefined;
        const tag = std.fmt.bufPrint(&tag_buf, "\"event\":\"{s}\"", .{event}) catch unreachable;
        var n: usize = 0;
        for (self.sent[0..self.count]) |s| {
            if (s.client_id == client_id and std.mem.indexOf(u8, s.json, tag) != null) {
                out[n] = s.json;
                n += 1;
            }
        }
        return out[0..n];
    }
};

/// The track indices a tracks event carries, in its order, or a meters
/// event carries, sorted.
fn eventTrackIndices(json: []const u8) ![]c_int {
    const alloc = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    var out: std.ArrayList(c_int) = .empty;
    errdefer out.deinit(alloc);
    const root = parsed.value.object;
    if (std.mem.eql(u8, root.get("event").?.string, "tracks")) {
        for (root.get("payload").?.object.get("tracks").?.array.items) |t| {
            try out.append(alloc, @intCast(t.object.get("idx").?.integer));
        }
    } else {
        var it = root.get("m").?.object.iterator();
        while (it.next()) |e| try out.append(alloc, @intCast(e.value_ptr.object.get("i").?.integer));
        std.mem.sort(c_int, out.items, {}, std.sort.asc(c_int));
    }
    return out.toOwnedSlice(alloc);
}

fn expectEventIndices(json: []const u8, want: []const c_int) !void {
    const got = try eventTrackIndices(json);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualSlices(c_int, want, got);
}

/// Tracks as the poll leaves them for the union of the subscriptions in the
/// tests below (1-3 and 6-8 of a 10-track project), with a meter each.
fn polledTracks(buf: []tracks.Track, metering: *tracks.MeteringState) []tracks.Track {
    const indices = [_]c_int{ 1, 2, 3, 6, 7, 8 };
    metering.count = 0;
    for (indices, 0..) |idx, i| {
        buf[i] = .{ .idx = idx, .name_len = 0, .volume = 1.0 };
        const guid = std.fmt.bufPrint(&buf[i].guid, "{{G{d}}}", .{idx}) catch unreachable;
        buf[i].guid_len = guid.len;
        metering.meters[i] = .{ .track_idx = idx, .peak_l = 0.5, .peak_r = 0.5 };
        metering.count += 1;
    }
    return buf[0..indices.len];
}

const TestFixture = struct {
    arena: std.heap.ArenaAllocator,
    mock: reaper.MockBackend,
    cache: guid_cache.GuidCache,
    subs: track_subscriptions.TrackSubscriptions,
    buf: [6]tracks.Track = undefined,
    metering: tracks.MeteringState = .{},

    fn init(self: *TestFixture) void {
        self.* = .{
            .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
            .mock = reaper.MockBackend{ .track_count = 10 },
            .cache = guid_cache.GuidCache.init(std.testing.allocator),
            .subs = track_subscriptions.TrackSubscriptions.init(std.testing.allocator),
        };
    }

    fn deinit(self: *TestFixture) void {
        self.subs.deinit();
        self.cache.deinit();
        self.arena.deinit();
    }

    fn polled(self: *TestFixture) []tracks.Track {
        return polledTracks(&self.buf, &self.metering);
    }

    fn send(self: *TestFixture, sender: *RecordingSender, polled_tracks: []const tracks.Track, total: usize) bool {
        return sendTracksToSubscribers(self.arena.allocator(), sender, &self.subs, &self.cache, &self.mock, polled_tracks, &self.metering, total).sent_tracks;
    }

    /// Poll the union of the subscriptions from the mock as pollHighTier
    /// does, then send each subscriber its share.
    fn pollAndSend(self: *TestFixture, sender: *RecordingSender) !void {
        var union_buf: [64]c_int = undefined;
        const union_indices = self.subs.getSubscribedIndices(&self.cache, &self.mock, &union_buf);
        const state = try tracks.State.pollIndices(self.arena.allocator(), &self.mock, union_indices);
        self.metering.pollSubscribedInto(&self.mock, union_indices);
        _ = self.send(sender, state.tracks, @intCast(self.mock.track_count));
    }
};

fn mockGuid(buf: []u8, idx: usize) []const u8 {
    return std.fmt.bufPrint(buf, "{{00000000-0000-0000-0000-{d:0>12}}}", .{idx}) catch unreachable;
}

test "a GUID subscription with includeMaster is sent master and its tracks, nothing else" {
    var f: TestFixture = undefined;
    f.init();
    defer f.deinit();
    try f.cache.rebuild(&f.mock);

    var g3: [40]u8 = undefined;
    var g7: [40]u8 = undefined;
    const guids = [_][]const u8{ mockGuid(&g7, 7), mockGuid(&g3, 3) };
    _ = try f.subs.subscribeGuids(1, &guids, true);
    _ = try f.subs.subscribeRange(2, 4, 5, false);

    var sender = RecordingSender{ .handshaken = &.{ 1, 2 } };
    try f.pollAndSend(&sender);

    var out: [8][]const u8 = undefined;
    const t = sender.events(1, "tracks", &out);
    try std.testing.expectEqual(@as(usize, 1), t.len);
    try expectEventIndices(t[0], &.{ 0, 3, 7 });
    const m = sender.events(1, "meters", &out);
    try std.testing.expectEqual(@as(usize, 1), m.len);
    try expectEventIndices(m[0], &.{ 0, 3, 7 });
}

test "a subscription to no existing track is sent one tracks event with the total and no meters" {
    var f: TestFixture = undefined;
    f.init();
    defer f.deinit();

    _ = try f.subs.subscribeRange(1, 50, 60, false); // the project has 10 tracks
    _ = try f.subs.subscribeRange(2, 1, 2, false);

    var sender = RecordingSender{ .handshaken = &.{ 1, 2 } };
    try f.pollAndSend(&sender);
    try f.pollAndSend(&sender);

    var out: [8][]const u8 = undefined;
    const t = sender.events(1, "tracks", &out);
    try std.testing.expectEqual(@as(usize, 1), t.len);
    try std.testing.expectEqualStrings("{\"type\":\"event\",\"event\":\"tracks\",\"payload\":{\"total\":10,\"tracks\":[]}}", t[0]);
    try std.testing.expectEqual(@as(usize, 0), sender.events(1, "meters", &out).len);
}

test "a track deleted from a GUID subscription is dropped from the phone's next tracks event" {
    var f: TestFixture = undefined;
    f.init();
    defer f.deinit();
    try f.cache.rebuild(&f.mock);

    var g2: [40]u8 = undefined;
    var g10: [40]u8 = undefined;
    const guids = [_][]const u8{ mockGuid(&g2, 2), mockGuid(&g10, 10) };
    _ = try f.subs.subscribeGuids(1, &guids, false);

    var sender = RecordingSender{ .handshaken = &.{1} };
    try f.pollAndSend(&sender);
    var out: [8][]const u8 = undefined;
    try expectEventIndices(sender.events(1, "tracks", &out)[0], &.{ 2, 10 });

    // REAPER deletes track 10; the GUID cache has not been rebuilt yet.
    f.mock.track_count = 9;
    sender.count = 0;
    try f.pollAndSend(&sender);
    const t = sender.events(1, "tracks", &out);
    try std.testing.expectEqual(@as(usize, 1), t.len);
    try expectEventIndices(t[0], &.{2});
    const m = sender.events(1, "meters", &out);
    try std.testing.expectEqual(@as(usize, 1), m.len);
    try expectEventIndices(m[0], &.{2});
}

test "each subscribed phone is sent only its own tracks and meters, and an unsubscribed one nothing" {
    var f: TestFixture = undefined;
    f.init();
    defer f.deinit();

    _ = try f.subs.subscribeRange(1, 1, 3, false);
    _ = try f.subs.subscribeRange(2, 6, 8, false);
    _ = try f.subs.subscribeRange(4, 1, 3, false);
    f.subs.unsubscribe(4); // 3 never subscribed; 4 did, then stopped

    var sender = RecordingSender{ .handshaken = &.{ 1, 2, 3, 4 } };
    try std.testing.expect(f.send(&sender, f.polled(), 10));

    var out: [8][]const u8 = undefined;
    const Want = struct { client_id: usize, indices: []const c_int };
    for ([_]Want{ .{ .client_id = 1, .indices = &.{ 1, 2, 3 } }, .{ .client_id = 2, .indices = &.{ 6, 7, 8 } } }) |w| {
        const t = sender.events(w.client_id, "tracks", &out);
        try std.testing.expectEqual(@as(usize, 1), t.len);
        try expectEventIndices(t[0], w.indices);
        const m = sender.events(w.client_id, "meters", &out);
        try std.testing.expectEqual(@as(usize, 1), m.len);
        try expectEventIndices(m[0], w.indices);
    }
    for (sender.sent[0..sender.count]) |s| {
        try std.testing.expect(s.client_id != 3 and s.client_id != 4);
    }
}

test "a phone is resent tracks only when its own tracks or the track total change, or it resubscribes" {
    var f: TestFixture = undefined;
    f.init();
    defer f.deinit();

    _ = try f.subs.subscribeRange(1, 1, 3, false);
    _ = try f.subs.subscribeRange(2, 6, 8, false);
    const polled = f.polled();
    var sender = RecordingSender{ .handshaken = &.{ 1, 2 } };
    _ = f.send(&sender, polled, 10);

    var out: [8][]const u8 = undefined;

    // Nothing changed: meters only
    sender.count = 0;
    try std.testing.expect(!f.send(&sender, polled, 10));
    try std.testing.expectEqual(@as(usize, 0), sender.events(1, "tracks", &out).len);
    try std.testing.expectEqual(@as(usize, 0), sender.events(2, "tracks", &out).len);
    try std.testing.expectEqual(@as(usize, 1), sender.events(1, "meters", &out).len);
    try std.testing.expectEqual(@as(usize, 1), sender.events(2, "meters", &out).len);

    // Track 7, phone 2's, moves: phone 2 alone is sent tracks
    sender.count = 0;
    polled[4].volume = 0.5;
    try std.testing.expect(f.send(&sender, polled, 10));
    try std.testing.expectEqual(@as(usize, 0), sender.events(1, "tracks", &out).len);
    try std.testing.expectEqual(@as(usize, 1), sender.events(2, "tracks", &out).len);

    // A track added to the project changes every phone's total
    sender.count = 0;
    _ = f.send(&sender, polled, 11);
    try std.testing.expectEqual(@as(usize, 1), sender.events(1, "tracks", &out).len);
    try std.testing.expectEqual(@as(usize, 1), sender.events(2, "tracks", &out).len);

    // Resubscribing to the same range is answered though nothing changed
    sender.count = 0;
    _ = try f.subs.subscribeRange(1, 1, 3, false);
    _ = f.send(&sender, polled, 11);
    try std.testing.expectEqual(@as(usize, 1), sender.events(1, "tracks", &out).len);
    try std.testing.expectEqual(@as(usize, 0), sender.events(2, "tracks", &out).len);
}

test "phones with the same subscription share one serialisation" {
    var f: TestFixture = undefined;
    f.init();
    defer f.deinit();

    _ = try f.subs.subscribeRange(1, 1, 3, false);
    _ = try f.subs.subscribeRange(2, 1, 3, false);
    var sender = RecordingSender{ .handshaken = &.{ 1, 2 } };
    _ = f.send(&sender, f.polled(), 10);

    var out1: [8][]const u8 = undefined;
    var out2: [8][]const u8 = undefined;
    for ([_][]const u8{ "tracks", "meters" }) |event| {
        const a = sender.events(1, event, &out1);
        const b = sender.events(2, event, &out2);
        try std.testing.expectEqual(@as(usize, 1), a.len);
        try std.testing.expectEqual(@as(usize, 1), b.len);
        try std.testing.expectEqual(a[0].ptr, b[0].ptr);
    }
}

test "a phone that subscribed before its handshake is sent its tracks once it completes it" {
    var f: TestFixture = undefined;
    f.init();
    defer f.deinit();

    _ = try f.subs.subscribeRange(1, 1, 3, false);
    const polled = f.polled();

    var before = RecordingSender{ .handshaken = &.{} };
    try std.testing.expect(!f.send(&before, polled, 10));
    try std.testing.expectEqual(@as(usize, 0), before.count);

    var after = RecordingSender{ .handshaken = &.{1} };
    try std.testing.expect(f.send(&after, polled, 10));
    var out: [8][]const u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), after.events(1, "tracks", &out).len);
}
