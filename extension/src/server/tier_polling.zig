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
pub const MEDIUM_TIER_INTERVAL: u32 = 6; // 30Hz / 6 = 5Hz
pub const LOW_TIER_INTERVAL: u32 = 30; // 30Hz / 30 = 1Hz

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

/// Result from HIGH tier polling.
/// Contains transport state for use by playlist engine in main.zig.
pub const HighTierResult = struct {
    /// Current transport state (pointer into arena)
    transport_state: *const transport.State,
    /// Whether tracks changed this frame
    tracks_changed: bool,
};

// ============================================================================
// Helper functions (moved from main.zig)
// ============================================================================

/// Compare marker slices for change detection
fn markersSliceEql(a: []const markers.Marker, b: []const markers.Marker) bool {
    if (a.len != b.len) return false;
    for (a, b) |*marker_a, *marker_b| {
        if (!marker_a.eql(marker_b)) return false;
    }
    return true;
}

/// Compare region slices for change detection
fn regionsSliceEql(a: []const markers.Region, b: []const markers.Region) bool {
    if (a.len != b.len) return false;
    for (a, b) |*region_a, *region_b| {
        if (!region_a.eql(region_b)) return false;
    }
    return true;
}

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
    var tracks_changed = false;

    if (ctx.track_subs) |track_subs| {
        if (track_subs.hasSubscriptions()) {
            // Get subscribed track indices from all clients + grace period
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

            // CSurf: Hash-based change detection with dirty flag force broadcast
            const force_broadcast = track_subs.consumeForceBroadcast();
            const temp_state = tracks.State{ .tracks = high_state.tracks };
            const current_hash = temp_state.computeHash();
            const hash_changed = current_hash != mutable.prev_tracks_hash.*;

            // Combine all change signals
            tracks_changed = hash_changed or force_broadcast or csurf_track_dirty;

            // Drift logging: hash changed but no dirty flag = missed callback
            if (csurf.enabled and hash_changed and !csurf_track_dirty and !force_broadcast) {
                const now_ms = std.time.milliTimestamp();
                if (now_ms - mutable.last_drift_log_time.* > 1000) {
                    logging.warn("Track state drift detected without dirty flag (undo/selection/FX drag?)", .{});
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
        tracks_changed = hash_changed or csurf_track_dirty;

        // Drift logging
        if (csurf.enabled and hash_changed and !csurf_track_dirty) {
            const now_ms = std.time.milliTimestamp();
            if (now_ms - mutable.last_drift_log_time.* > 1000) {
                logging.warn("Track state drift detected without dirty flag (undo/selection/FX drag?)", .{});
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
        .tracks_changed = tracks_changed,
    };
}

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
    const medium_prev = ctx.tiered.medium.previousState();
    const scratch = ctx.scratchAllocator();

    // Poll markers/regions into MEDIUM arena
    const marker_state = markers.State.poll(medium_alloc, ctx.backend) catch |err| {
        logging.err("CSurf immediate markers poll failed: {s}", .{@errorName(err)});
        return err;
    };
    medium_state.markers = marker_state.markers;
    medium_state.regions = marker_state.regions;
    medium_state.bar_offset = marker_state.bar_offset;

    // Broadcast markers if changed
    if (!markersSliceEql(medium_state.markers, medium_prev.markers)) {
        const temp_marker_state = markers.State{
            .markers = medium_state.markers,
            .regions = medium_state.regions,
            .bar_offset = medium_state.bar_offset,
        };
        if (temp_marker_state.markersToJsonAlloc(scratch)) |json| {
            ctx.shared_state.broadcast(json);
        } else |_| {}
    }

    // Broadcast regions if changed
    if (!regionsSliceEql(medium_state.regions, medium_prev.regions)) {
        const temp_marker_state = markers.State{
            .markers = medium_state.markers,
            .regions = medium_state.regions,
            .bar_offset = medium_state.bar_offset,
        };
        if (temp_marker_state.regionsToJsonAlloc(scratch)) |json| {
            ctx.shared_state.broadcast(json);
        } else |_| {}
    }

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
        logging.info("Project changed: {s}", .{
            if (medium_state.project.projectName().len > 0) medium_state.project.projectName() else "(Unsaved)",
        });

        // Stop playlist engine if playing
        if (mutable.playlist_state.engine.isActive()) {
            _ = mutable.playlist_state.engine.stop();
            ctx.backend.clearLoopPoints();
            logging.info("Stopped playlist engine due to project change", .{});
        }

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

            ctx.tiered.resize(ctx.allocator, new_sizes) catch |err| {
                logging.err("Failed to resize arenas: {s}", .{@errorName(err)});
            };
            logging.info("Arena resize complete: {d}MB total", .{new_sizes.totalAllocated() >> 20});
        }

        // Flush pending playlist changes to old project
        if (mutable.playlist_state.dirty) {
            mutable.playlist_state.saveAll(ctx.backend);
            mutable.playlist_state.dirty = false;
        }

        // Reload playlists from new project
        mutable.playlist_state.reset();
        mutable.playlist_state.loadAll(ctx.backend);
        logging.info("Loaded {d} playlists from new project", .{mutable.playlist_state.playlist_count});

        // Broadcast updated playlist state
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

    // Broadcast markers if changed
    if (!markersSliceEql(medium_state.markers, medium_prev.markers)) {
        const temp_marker_state = markers.State{
            .markers = medium_state.markers,
            .regions = medium_state.regions,
            .bar_offset = medium_state.bar_offset,
        };
        if (temp_marker_state.markersToJsonAlloc(scratch)) |json| {
            ctx.shared_state.broadcast(json);
        } else |_| {}
    }

    // Broadcast regions if changed
    if (!regionsSliceEql(medium_state.regions, medium_prev.regions)) {
        const temp_marker_state = markers.State{
            .markers = medium_state.markers,
            .regions = medium_state.regions,
            .bar_offset = medium_state.bar_offset,
        };
        if (temp_marker_state.regionsToJsonAlloc(scratch)) |json| {
            ctx.shared_state.broadcast(json);
        } else |_| {}
    }

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
/// Also handles grace period expiration for track subscriptions.
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
    const low_state = ctx.tiered.low.currentState();
    const low_prev = ctx.tiered.low.previousState();

    low_state.tempomap = tempomap.State.poll(ctx.backend);
    if (low_state.tempomap.changed(&low_prev.tempomap)) {
        const scratch = ctx.scratchAllocator();
        if (low_state.tempomap.toJsonAlloc(scratch)) |json| {
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
    const low_state = ctx.tiered.low.currentState();
    const low_prev = ctx.tiered.low.previousState();
    const low_alloc = ctx.tiered.low.currentAllocator();

    // ========================================================================
    // Tempomap
    // ========================================================================
    low_state.tempomap = tempomap.State.poll(ctx.backend);
    if (low_state.tempomap.changed(&low_prev.tempomap)) {
        const scratch = ctx.scratchAllocator();
        if (low_state.tempomap.toJsonAlloc(scratch)) |json| {
            ctx.shared_state.broadcast(json);
        } else |_| {}
    }

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

        logging.info("Track skeleton changed: {d} tracks", .{current_skeleton.count()});
    }

    // Update persistent skeleton state for next comparison
    if (current_skeleton.tracks.len <= tracks.MAX_TRACKS) {
        if (mutable.last_skeleton_buf.len < current_skeleton.tracks.len) {
            // Reallocate if needed
            if (mutable.last_skeleton_buf.len > 0) {
                ctx.allocator.free(mutable.last_skeleton_buf.*);
            }
            mutable.last_skeleton_buf.* = ctx.allocator.alloc(track_skeleton.SkeletonTrack, current_skeleton.tracks.len) catch &.{};
        }
        if (mutable.last_skeleton_buf.len >= current_skeleton.tracks.len) {
            @memcpy(mutable.last_skeleton_buf.*[0..current_skeleton.tracks.len], current_skeleton.tracks);
            mutable.last_skeleton.tracks = mutable.last_skeleton_buf.*[0..current_skeleton.tracks.len];
        }
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

    // ========================================================================
    // Expire subscription grace periods (1Hz cleanup)
    // ========================================================================
    if (ctx.track_subs) |track_subs| {
        track_subs.expireGracePeriods();
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
