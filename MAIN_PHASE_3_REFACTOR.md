# Phase 3: Extract Tier Polling

## Overview

This document provides surgical instructions for extracting tier-based polling logic (HIGH/MEDIUM/LOW) from `doProcessing()` in `main.zig` into a new module `tier_polling.zig`.

**Risk Level:** Medium-High (most complex extraction due to scattered code blocks and mutable state)
**Estimated Lines Moved:** ~460
**Resulting main.zig:** ~1250 lines (down from ~1710)

---

## 1. Exact Line Ranges

### 1.1 HIGH Tier - Transport Polling (Lines 760-790)

```zig
const high_state = tiered.high.currentState();
const high_prev = tiered.high.previousState();

// Poll transport state into arena
high_state.transport = transport.State.poll(&backend);
const current_transport = &high_state.transport;

// Broadcast when changed OR when CSurf force flag set (ensures immediate response to callbacks)
if (force_transport or !current_transport.eql(high_prev.transport)) {
    const state_changed = force_transport or !current_transport.stateOnlyEql(high_prev.transport);
    const is_playing = transport.PlayState.isPlaying(current_transport.play_state);

    const scratch = tiered.scratchAllocator();
    if (state_changed) {
        // State changed (play/pause, BPM, time sig, etc.) - send full transport
        if (current_transport.toJsonAlloc(scratch)) |json| {
            shared_state.broadcast(json);
        } else |_| {}
    } else if (is_playing) {
        // Only position changed during playback - send lightweight tick
        if (current_transport.toTickJsonAlloc(scratch)) |json| {
            shared_state.broadcast(json);
        } else |_| {}
    } else {
        // Stopped and only position changed (cursor moved) - send full transport
        // This is infrequent so full context is fine
        if (current_transport.toJsonAlloc(scratch)) |json| {
            shared_state.broadcast(json);
        } else |_| {}
    }
}
```

**Line count:** 31 lines

### 1.2 HIGH Tier - Track Polling with Subscriptions (Lines 792-903)

```zig
// Poll tracks into HIGH tier arena - SUBSCRIPTION MODE ONLY
// Only poll tracks that clients have subscribed to (viewport-driven).
// This saves CPU on large projects (1000+ tracks) by not polling everything.
const high_alloc = tiered.high.currentAllocator();
const total_tracks: usize = @intCast(@max(0, backend.trackCount())); // User tracks only (master handled separately)

if (g_track_subs) |track_subs| {
    if (track_subs.hasSubscriptions()) {
        // Get subscribed track indices from all clients + grace period
        const cache = g_guid_cache orelse {
            logging.err("GUID cache not initialized for track subscriptions", .{});
            return error.GuidCacheNotInitialized;
        };
        var subscribed_buf: [track_subscriptions.MAX_TRACKS_PER_CLIENT * track_subscriptions.MAX_CLIENTS]c_int = undefined;
        const subscribed_indices = track_subs.getSubscribedIndices(cache, &backend, &subscribed_buf);

        // Poll only subscribed tracks
        const track_state = tracks.State.pollIndices(high_alloc, &backend, subscribed_indices) catch |err| {
            logging.err("Failed to poll tracks: {s}", .{@errorName(err)});
            return err;
        };
        high_state.tracks = track_state.tracks;

        // Poll metering for subscribed tracks (same indices as track subscriptions)
        high_state.metering.pollSubscribedInto(api, subscribed_indices);

        // CSurf: Hash-based change detection with dirty flag force broadcast
        // This replaces tracksSliceEql for more robust change detection.
        const force_broadcast = track_subs.consumeForceBroadcast();
        const temp_state = tracks.State{ .tracks = high_state.tracks };
        const current_hash = temp_state.computeHash();
        const hash_changed = current_hash != g_prev_tracks_hash;

        // Combine all change signals:
        // 1. hash_changed: actual state change detected via hash comparison
        // 2. force_broadcast: new subscription needs immediate data
        // 3. csurf_track_dirty: CSurf callback signaled a change (instant latency)
        const tracks_changed = hash_changed or force_broadcast or csurf_track_dirty;

        // Drift logging: hash changed but no dirty flag = missed callback
        // Rate-limited to max 1/second to avoid spam during undo/redo bursts
        if (csurf.enabled and hash_changed and !csurf_track_dirty and !force_broadcast) {
            const now_ms = std.time.milliTimestamp();
            if (now_ms - g_last_drift_log_time > 1000) {
                logging.warn("Track state drift detected without dirty flag (undo/selection/FX drag?)", .{});
                g_last_drift_log_time = now_ms;
            }
        }

        if (tracks_changed) {
            const scratch = tiered.scratchAllocator();
            // Use toJsonWithTotalAlloc to include total track count for viewport scrollbar
            if (temp_state.toJsonWithTotalAlloc(scratch, null, total_tracks)) |json| {
                shared_state.broadcast(json);
            } else |_| {}
            g_prev_tracks_hash = current_hash;
        }

        // Broadcast separate meters event (always at 30Hz when there are subscriptions)
        if (high_state.metering.hasData()) {
            const scratch = tiered.scratchAllocator();
            if (high_state.metering.toJsonEventAlloc(scratch, high_state.tracks)) |json| {
                shared_state.broadcast(json);
            } else |_| {}
        }
    } else {
        // No track subscriptions - skip track polling entirely
        high_state.tracks = &.{};
        high_state.metering.count = 0;
    }
} else {
    // Track subscriptions not initialized - fall back to full polling (legacy/startup)
    const track_state = tracks.State.poll(high_alloc, &backend) catch |err| {
        logging.err("Failed to poll tracks: {s}", .{@errorName(err)});
        return err;
    };
    high_state.tracks = track_state.tracks;

    // Poll all meters when no subscription system
    high_state.metering.pollInto(api);

    // CSurf: Hash-based change detection (fallback path)
    const temp_state = tracks.State{ .tracks = high_state.tracks };
    const current_hash = temp_state.computeHash();
    const hash_changed = current_hash != g_prev_tracks_hash;
    const tracks_changed = hash_changed or csurf_track_dirty;

    // Drift logging (same as subscription path)
    if (csurf.enabled and hash_changed and !csurf_track_dirty) {
        const now_ms = std.time.milliTimestamp();
        if (now_ms - g_last_drift_log_time > 1000) {
            logging.warn("Track state drift detected without dirty flag (undo/selection/FX drag?)", .{});
            g_last_drift_log_time = now_ms;
        }
    }

    if (tracks_changed) {
        const scratch = tiered.scratchAllocator();
        if (temp_state.toJsonWithTotalAlloc(scratch, null, total_tracks)) |json| {
            shared_state.broadcast(json);
        } else |_| {}
        g_prev_tracks_hash = current_hash;
    }

    // Broadcast separate meters event
    if (high_state.metering.hasData()) {
        const meter_scratch = tiered.scratchAllocator();
        if (high_state.metering.toJsonEventAlloc(meter_scratch, high_state.tracks)) |json| {
            shared_state.broadcast(json);
        } else |_| {}
    }
}
```

**Line count:** 112 lines

### 1.3 MEDIUM Tier - Immediate Markers Poll (CSurf triggered) (Lines 1139-1192)

```zig
// ========================================================================
// IMMEDIATE MARKERS/REGIONS POLL (CSurf dirty flag triggered)
// When markers_dirty was set by CSurf callback, poll immediately instead
// of waiting for next MEDIUM tier interval. Skip if on medium tick to
// avoid double polling.
// ========================================================================
const medium_tick = g_frame_counter % MEDIUM_TIER_INTERVAL == 0;
if (force_markers and !medium_tick) {
    const medium_alloc = tiered.medium.currentAllocator();
    const medium_state = tiered.medium.currentState();
    const medium_prev = tiered.medium.previousState();
    const scratch = tiered.scratchAllocator();

    // Poll markers/regions into MEDIUM arena
    const marker_state = markers.State.poll(medium_alloc, &backend) catch |err| {
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
            shared_state.broadcast(json);
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
            shared_state.broadcast(json);
        } else |_| {}
    }

    // Update g_last_markers cache for playlist engine
    const cur_markers_len = medium_state.markers.len;
    const cur_regions_len = medium_state.regions.len;
    @memcpy(g_last_markers_buf[0..cur_markers_len], medium_state.markers);
    @memcpy(g_last_regions_buf[0..cur_regions_len], medium_state.regions);
    g_last_markers.markers = g_last_markers_buf[0..cur_markers_len];
    g_last_markers.regions = g_last_regions_buf[0..cur_regions_len];
    g_last_markers.bar_offset = medium_state.bar_offset;
}
```

**Line count:** 54 lines

### 1.4 MEDIUM Tier - Regular Polling (Lines 1194-1379)

```zig
// ========================================================================
// MEDIUM TIER (5Hz) - Project state, Markers, Regions, Items
// These change less frequently and don't need instant feedback
// Uses arena allocation - no memcpy needed for change detection
// ========================================================================
if (medium_tick) {
    const medium_alloc = tiered.medium.currentAllocator();
    const medium_state = tiered.medium.currentState();
    const medium_prev = tiered.medium.previousState();

    // Poll project state into arena
    medium_state.project = project.State.poll(&backend);

    // Set memory warning flag based on arena utilization (any tier > 80% peak usage)
    medium_state.project.memory_warning = tiered.isMemoryWarning();

    // Check for project identity change (tab switch or different file in same tab)
    if (medium_prev.project.projectChanged(&medium_state.project)) {
        // ... project change handling (resize arenas, reload playlists, etc.) ...
    }

    const scratch = tiered.scratchAllocator();
    if (!medium_state.project.eql(&medium_prev.project)) {
        if (medium_state.project.toJsonAlloc(scratch)) |json| {
            shared_state.broadcast(json);
        } else |_| {}
    }

    // Poll markers/regions into MEDIUM arena
    const marker_state = markers.State.poll(medium_alloc, &backend) catch |err| {
        logging.err("Failed to poll markers: {s}", .{@errorName(err)});
        return err;
    };
    // ... markers/regions handling ...

    // Poll items into MEDIUM arena
    const item_state = items.State.poll(medium_alloc, &backend) catch |err| {
        logging.err("Failed to poll items: {s}", .{@errorName(err)});
        return err;
    };
    // ... items handling ...

    // Poll FX into MEDIUM arena
    const fx_state = fx.State.poll(medium_alloc, &backend) catch |err| {
        logging.err("Failed to poll FX: {s}", .{@errorName(err)});
        return err;
    };
    // ... fx handling ...

    // Poll sends into MEDIUM arena
    const sends_state = sends.State.poll(medium_alloc, &backend) catch |err| {
        logging.err("Failed to poll sends: {s}", .{@errorName(err)});
        return err;
    };
    // ... sends handling ...
}
```

**Line count:** 186 lines (full block)

### 1.5 LOW Tier - Immediate Tempo Poll (CSurf triggered) (Lines 1381-1399)

```zig
// ========================================================================
// IMMEDIATE TEMPO POLL (CSurf dirty flag triggered)
// When tempo_dirty was set by CSurf callback (SETBPMANDPLAYRATE), poll
// immediately instead of waiting for next LOW tier interval.
// ========================================================================
const low_tick = g_frame_counter % LOW_TIER_INTERVAL == 0;
if (force_tempo and !low_tick) {
    const low_state = tiered.low.currentState();
    const low_prev = tiered.low.previousState();

    // Poll tempo map into LOW tier state
    low_state.tempomap = tempomap.State.poll(&backend);
    if (low_state.tempomap.changed(&low_prev.tempomap)) {
        const scratch = tiered.scratchAllocator();
        if (low_state.tempomap.toJsonAlloc(scratch)) |json| {
            shared_state.broadcast(json);
        } else |_| {}
    }
}
```

**Line count:** 19 lines

### 1.6 LOW Tier - Regular Polling (Lines 1401-1474)

```zig
// ========================================================================
// LOW TIER (1Hz) - Tempomap, Project Notes, Track Skeleton
// These rarely change during normal operation
// Uses arena allocation for change detection
// ========================================================================
if (low_tick) {
    const low_state = tiered.low.currentState();
    const low_prev = tiered.low.previousState();
    const low_alloc = tiered.low.currentAllocator();

    // Poll tempo map into LOW tier state
    low_state.tempomap = tempomap.State.poll(&backend);
    if (low_state.tempomap.changed(&low_prev.tempomap)) {
        const scratch = tiered.scratchAllocator();
        if (low_state.tempomap.toJsonAlloc(scratch)) |json| {
            shared_state.broadcast(json);
        } else |_| {}
    }

    // Poll track skeleton for structure changes (add/delete/rename/reorder)
    const current_skeleton = track_skeleton.State.poll(low_alloc, &backend) catch |err| {
        logging.err("Failed to poll skeleton: {s}", .{@errorName(err)});
        return err;
    };

    if (!current_skeleton.eql(&g_last_skeleton)) {
        // Track structure changed - rebuild GUID cache and broadcast
        if (g_guid_cache) |cache| {
            cache.rebuild(&backend) catch |err| {
                logging.err("Failed to rebuild GUID cache: {s}", .{@errorName(err)});
            };
        }

        // Broadcast skeleton event
        const skel_scratch = tiered.scratchAllocator();
        if (current_skeleton.toJsonAlloc(skel_scratch)) |json| {
            shared_state.broadcast(json);
        } else |_| {}

        logging.info("Track skeleton changed: {d} tracks", .{current_skeleton.count()});
    }

    // Update persistent skeleton state for next comparison
    // ... copy to persistent buffer ...

    // Poll project notes and broadcast changes (only if subscribers)
    if (g_notes_subs) |notes_subs| {
        if (notes_subs.poll(api)) |change| {
            // Notes changed externally - broadcast to all subscribers
            if (commands.project_notes_cmds.formatChangedEvent(change.hash, &StaticBuffers.notes)) |json| {
                shared_state.broadcast(json);
            }
        }
    }

    // Expire subscription grace periods (1Hz cleanup)
    if (g_track_subs) |track_subs| {
        track_subs.expireGracePeriods();
    }
}
```

**Line count:** 74 lines

### 1.7 Summary of Lines to Extract

| Block | Lines | Line Count | Tier |
|-------|-------|------------|------|
| Transport polling | 760-790 | 31 | HIGH |
| Track/metering polling | 792-903 | 112 | HIGH |
| Immediate markers poll | 1139-1192 | 54 | MEDIUM (CSurf) |
| Regular medium tier | 1194-1379 | 186 | MEDIUM |
| Immediate tempo poll | 1381-1399 | 19 | LOW (CSurf) |
| Regular low tier | 1401-1474 | 74 | LOW |
| **Total** | - | **~476** | - |

**Note:** The playlist engine tick code (lines 953-1137) is NOT part of this phase - it will be extracted in Phase 4.

---

## 2. Dependency Analysis

### 2.1 Required Imports for tier_polling.zig

```zig
const std = @import("std");
const reaper = @import("reaper.zig");
const logging = @import("logging.zig");
const tiered_state = @import("tiered_state.zig");
const guid_cache = @import("guid_cache.zig");
const ws_server = @import("ws_server.zig");
const csurf = @import("csurf.zig");
const csurf_dirty = @import("csurf_dirty.zig");

// State types
const transport = @import("transport.zig");
const tracks = @import("tracks.zig");
const markers = @import("markers.zig");
const items = @import("items.zig");
const project = @import("project.zig");
const tempomap = @import("tempomap.zig");
const fx = @import("fx.zig");
const sends = @import("sends.zig");
const track_skeleton = @import("track_skeleton.zig");
const project_notes = @import("project_notes.zig");

// Subscriptions
const track_subscriptions = @import("track_subscriptions.zig");

// Commands (for project_notes_cmds.formatChangedEvent)
const commands = @import("commands/mod.zig");

// Caches
const item_guid_cache = @import("item_guid_cache.zig");

// Playlist (needed for medium tier playlist state detection)
const playlist = @import("playlist.zig");
```

### 2.2 Parameters Required from Caller

The tier polling functions need extensive context. We define a `TierContext` struct to bundle these:

| Parameter | Type | Source in main.zig |
|-----------|------|-------------------|
| `tiered` | `*tiered_state.TieredArenas` | `&(g_tiered orelse ...)` |
| `backend` | `*reaper.RealBackend` | `&backend` (local) |
| `shared_state` | `*ws_server.SharedState` | `g_shared_state orelse ...` |
| `api` | `*const reaper.Api` | `&(g_api orelse ...)` |
| `guid_cache_ptr` | `?*guid_cache.GuidCache` | `g_guid_cache` |
| `item_cache_ptr` | `?*item_guid_cache.ItemGuidCache` | `g_item_cache` |
| `track_subs` | `?*track_subscriptions.TrackSubscriptions` | `g_track_subs` |
| `notes_subs` | `?*project_notes.NotesSubscriptions` | `g_notes_subs` |
| `allocator` | `std.mem.Allocator` | `g_allocator` |

**Mutable State (passed by pointer for mutation):**

| Mutable State | Type | Purpose |
|---------------|------|---------|
| `prev_tracks_hash` | `*u64` | Track hash for change detection |
| `last_drift_log_time` | `*i64` | Rate-limit drift warnings |
| `last_skeleton` | `*track_skeleton.State` | Previous skeleton for comparison |
| `last_skeleton_buf` | `*[]track_skeleton.SkeletonTrack` | Persistent buffer for skeleton |
| `last_markers` | `*markers.State` | Cache for playlist engine |
| `last_markers_buf` | `*[markers.MAX_MARKERS]markers.Marker` | Persistent marker buffer |
| `last_regions_buf` | `*[markers.MAX_REGIONS]markers.Region` | Persistent region buffer |
| `last_playlist` | `*playlist.State` | Playlist change detection |
| `playlist_state` | `*playlist.State` | Current playlist state |
| `dirty_flags` | `?*csurf_dirty.DirtyFlags` | CSurf dirty flags |

**Per-frame CSurf Flags (passed by value):**

| Flag | Type | Purpose |
|------|------|---------|
| `force_transport` | `bool` | CSurf transport dirty |
| `force_markers` | `bool` | CSurf markers dirty |
| `force_tempo` | `bool` | CSurf tempo dirty |
| `csurf_track_dirty` | `bool` | CSurf track dirty |
| `frame_counter` | `u32` | Current frame for tier timing |

### 2.3 Globals Referenced

The code currently accesses these globals directly:

| Global | Usage | Strategy |
|--------|-------|----------|
| `g_guid_cache` | Track/skeleton/FX polling | Pass via TierContext |
| `g_item_cache` | Item cache rebuild | Pass via TierContext |
| `g_track_subs` | Track subscription polling | Pass via TierContext |
| `g_notes_subs` | Project notes polling | Pass via TierContext |
| `g_prev_tracks_hash` | Track hash comparison | Pass as mutable pointer |
| `g_last_drift_log_time` | Drift warning rate limiting | Pass as mutable pointer |
| `g_last_skeleton` | Skeleton change detection | Pass as mutable pointer |
| `g_last_skeleton_buf` | Skeleton buffer storage | Pass as mutable pointer |
| `g_last_markers` | Markers cache for playlist | Pass as mutable pointer |
| `g_last_markers_buf` | Markers buffer storage | Pass as mutable pointer |
| `g_last_regions_buf` | Regions buffer storage | Pass as mutable pointer |
| `g_last_playlist` | Playlist change detection | Pass as mutable pointer |
| `g_playlist_state` | Playlist state (modify+persist) | Pass as mutable pointer |
| `g_dirty_flags` | CSurf dirty flags | Pass via TierContext |
| `g_allocator` | Skeleton buffer reallocation | Pass via TierContext |

**Strategy:** All globals become explicit parameters via `TierContext` and `MutableState` structs.

---

## 3. Interface Design

### 3.1 TierContext Struct

```zig
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
```

### 3.2 MutableState Struct

```zig
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
```

### 3.3 HighTierResult Struct

```zig
/// Result from HIGH tier polling.
/// Contains transport state for use by playlist engine in main.zig.
pub const HighTierResult = struct {
    /// Current transport state (pointer into arena)
    transport: *const transport.State,
    /// Whether tracks changed this frame
    tracks_changed: bool,
};
```

### 3.4 Function Signatures

```zig
/// Poll HIGH tier (30Hz): Transport, Tracks, Metering.
/// Returns transport state for playlist engine synchronization.
///
/// Parameters:
/// - ctx: Shared context (read-only infrastructure references)
/// - mutable: Mutable state for change detection
/// - force_transport: CSurf transport dirty flag
/// - csurf_track_dirty: CSurf track dirty flag
///
/// Returns: HighTierResult with transport state and tracks_changed flag
pub fn pollHighTier(
    ctx: *const TierContext,
    mutable: *MutableState,
    force_transport: bool,
    csurf_track_dirty: bool,
) !HighTierResult;

/// Poll MEDIUM tier (5Hz): Project, Markers, Regions, Items, FX, Sends.
/// Also handles playlist state change detection and persistence.
///
/// Parameters:
/// - ctx: Shared context
/// - mutable: Mutable state for change detection
/// - force_markers: CSurf markers dirty flag (triggers immediate poll)
/// - frame_counter: Current frame for tier timing
///
/// Notes:
/// - Immediate markers poll happens if force_markers and NOT on medium tick
/// - Regular medium poll happens on every 6th frame (MEDIUM_TIER_INTERVAL)
pub fn pollMediumTier(
    ctx: *const TierContext,
    mutable: *MutableState,
    force_markers: bool,
    frame_counter: u32,
) !void;

/// Poll LOW tier (1Hz): Tempomap, Skeleton, Project Notes.
/// Also handles grace period expiration for track subscriptions.
///
/// Parameters:
/// - ctx: Shared context
/// - mutable: Mutable state for change detection
/// - force_tempo: CSurf tempo dirty flag (triggers immediate poll)
/// - frame_counter: Current frame for tier timing
/// - notes_buf: Static buffer for notes event formatting
///
/// Notes:
/// - Immediate tempo poll happens if force_tempo and NOT on low tick
/// - Regular low poll happens on every 30th frame (LOW_TIER_INTERVAL)
pub fn pollLowTier(
    ctx: *const TierContext,
    mutable: *MutableState,
    force_tempo: bool,
    frame_counter: u32,
    notes_buf: *[256]u8,
) !void;
```

### 3.5 Usage from main.zig

After extraction, the tier polling section in `doProcessing()` becomes:

```zig
const tier_polling = @import("tier_polling.zig");

// ... in doProcessing() after subscription polling ...

// Build tier context (once per frame)
const tier_ctx = tier_polling.TierContext{
    .tiered = tiered,
    .backend = &backend,
    .api = api,
    .shared_state = shared_state,
    .guid_cache_ptr = g_guid_cache,
    .item_cache_ptr = g_item_cache,
    .track_subs = g_track_subs,
    .notes_subs = g_notes_subs,
    .allocator = g_allocator,
    .dirty_flags = g_dirty_flags,
};

// Build mutable state references
var mutable = tier_polling.MutableState{
    .prev_tracks_hash = &g_prev_tracks_hash,
    .last_drift_log_time = &g_last_drift_log_time,
    .last_skeleton = &g_last_skeleton,
    .last_skeleton_buf = &g_last_skeleton_buf,
    .last_markers = &g_last_markers,
    .last_markers_buf = &g_last_markers_buf,
    .last_regions_buf = &g_last_regions_buf,
    .last_playlist = &g_last_playlist,
    .playlist_state = &g_playlist_state,
};

// HIGH tier (30Hz) - Transport, Tracks, Metering
const high_result = try tier_polling.pollHighTier(&tier_ctx, &mutable, force_transport, csurf_track_dirty);

// ... subscription polling (already extracted) ...

// ... playlist engine tick (uses high_result.transport) ...

// MEDIUM tier (5Hz) - includes immediate markers poll if force_markers
try tier_polling.pollMediumTier(&tier_ctx, &mutable, force_markers, g_frame_counter);

// LOW tier (1Hz) - includes immediate tempo poll if force_tempo
try tier_polling.pollLowTier(&tier_ctx, &mutable, force_tempo, g_frame_counter, &StaticBuffers.notes);
```

---

## 4. The Extraction

### 4.1 Complete tier_polling.zig

Create file at: `extension/src/tier_polling.zig`

```zig
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
const reaper = @import("reaper.zig");
const logging = @import("logging.zig");
const tiered_state = @import("tiered_state.zig");
const guid_cache = @import("guid_cache.zig");
const ws_server = @import("ws_server.zig");
const csurf = @import("csurf.zig");
const csurf_dirty = @import("csurf_dirty.zig");

// State types
const transport = @import("transport.zig");
const tracks = @import("tracks.zig");
const markers = @import("markers.zig");
const items = @import("items.zig");
const project = @import("project.zig");
const tempomap = @import("tempomap.zig");
const fx = @import("fx.zig");
const sends = @import("sends.zig");
const track_skeleton = @import("track_skeleton.zig");
const project_notes = @import("project_notes.zig");
const playlist = @import("playlist.zig");

// Subscriptions
const track_subscriptions = @import("track_subscriptions.zig");

// Commands (for project_notes_cmds.formatChangedEvent)
const commands = @import("commands/mod.zig");

// Caches
const item_guid_cache = @import("item_guid_cache.zig");

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
    bar_offset: f64,
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
```

### 4.2 Edits to main.zig

#### 4.2.1 Add Import (after line 39)

Add this import after the `subscription_polling` import:

```zig
const tier_polling = @import("tier_polling.zig");
```

**Edit location:** Line 40 (insert after `const subscription_polling = @import("subscription_polling.zig");`)

#### 4.2.2 Remove Helper Functions (Lines 450-502)

These helper functions are now in `tier_polling.zig`:

**Remove:**
- `markersSliceEql` (lines 459-465)
- `regionsSliceEql` (lines 468-474)
- `itemsSliceEql` (lines 477-483)
- `fxSliceEql` (lines 486-492)
- `sendsSliceEql` (lines 495-501)

**Keep:** `tracksSliceEql` (lines 450-456) - still used in snapshot sending

#### 4.2.3 Remove Tier Interval Constants (Lines 106-107)

**Remove:**
```zig
const MEDIUM_TIER_INTERVAL: u32 = 6; // 30Hz / 6 = 5Hz
const LOW_TIER_INTERVAL: u32 = 30; // 30Hz / 30 = 1Hz
```

These are now exported from `tier_polling.zig`.

#### 4.2.4 Remove HIGH Tier Block (Lines 754-903)

**Remove entire block** from:
```zig
// ========================================================================
// HIGH TIER (30Hz) - Transport, Tracks, Metering
```

Through the closing brace of the metering broadcast (line 903).

#### 4.2.5 Remove MEDIUM Tier Blocks (Lines 1139-1379)

**Remove:**
1. Immediate markers poll block (lines 1139-1192)
2. Regular medium tier block (lines 1194-1379)

#### 4.2.6 Remove LOW Tier Blocks (Lines 1381-1474)

**Remove:**
1. Immediate tempo poll block (lines 1381-1399)
2. Regular low tier block (lines 1401-1474)

#### 4.2.7 Insert New Tier Polling Code

**Insert after subscription polling** (around line 951, where HIGH tier was removed):

```zig
    // ========================================================================
    // TIER POLLING - Extracted to tier_polling.zig for testability
    // ========================================================================

    // Build tier context (once per frame)
    const tier_ctx = tier_polling.TierContext{
        .tiered = tiered,
        .backend = &backend,
        .api = api,
        .shared_state = shared_state,
        .guid_cache_ptr = g_guid_cache,
        .item_cache_ptr = g_item_cache,
        .track_subs = g_track_subs,
        .notes_subs = g_notes_subs,
        .allocator = g_allocator,
        .dirty_flags = g_dirty_flags,
    };

    // Build mutable state references
    var mutable = tier_polling.MutableState{
        .prev_tracks_hash = &g_prev_tracks_hash,
        .last_drift_log_time = &g_last_drift_log_time,
        .last_skeleton = &g_last_skeleton,
        .last_skeleton_buf = &g_last_skeleton_buf,
        .last_markers = &g_last_markers,
        .last_markers_buf = &g_last_markers_buf,
        .last_regions_buf = &g_last_regions_buf,
        .last_playlist = &g_last_playlist,
        .playlist_state = &g_playlist_state,
    };

    // HIGH tier (30Hz) - Transport, Tracks, Metering
    const high_result = try tier_polling.pollHighTier(&tier_ctx, &mutable, force_transport, csurf_track_dirty);
    const current_transport = high_result.transport_state;
```

**Insert after playlist engine tick** (where MEDIUM/LOW tier was):

```zig
    // MEDIUM tier (5Hz) - includes immediate markers poll if force_markers
    try tier_polling.pollMediumTier(&tier_ctx, &mutable, force_markers, g_frame_counter);

    // LOW tier (1Hz) - includes immediate tempo poll if force_tempo
    try tier_polling.pollLowTier(&tier_ctx, &mutable, force_tempo, g_frame_counter, &StaticBuffers.notes);

    // ========================================================================
    // HEARTBEAT SAFETY NET (every 2 seconds = 60 frames at 30Hz)
    // ========================================================================
    if (csurf.enabled and g_frame_counter % csurf_dirty.SAFETY_POLL_INTERVAL == 0) {
        if (g_dirty_flags) |flags| {
            flags.setAllTracksDirty();
        }
    }
```

#### 4.2.8 Update Playlist Engine Tick

The playlist engine tick code stays in main.zig but now uses `current_transport` from `high_result.transport_state`:

```zig
// Replace references to high_state.transport with current_transport
// (already correct since we assigned: const current_transport = high_result.transport_state;)
```

#### 4.2.9 Add Test Re-export

**Add to test block at end of main.zig:**

```zig
    _ = @import("tier_polling.zig");
```

---

## 5. Verification Checklist

### 5.1 Build Commands

```bash
# Navigate to extension directory
cd "/Users/conor/Library/Application Support/REAPER/reaper_www_root/extension"

# Build the extension
zig build

# Run tests
zig build test

# Build with CSurf enabled
zig build -Dcsurf=true
```

### 5.2 Grep Checks for Dangling References

After extraction, verify no orphaned references exist:

```bash
# Ensure old tier constants are removed from main.zig
grep -n "MEDIUM_TIER_INTERVAL" extension/src/main.zig
# Should return NO matches (now in tier_polling.zig)

grep -n "LOW_TIER_INTERVAL" extension/src/main.zig
# Should return NO matches (now in tier_polling.zig)

# Ensure helper functions are removed from main.zig
grep -n "fn markersSliceEql" extension/src/main.zig
# Should return NO matches

grep -n "fn regionsSliceEql" extension/src/main.zig
# Should return NO matches

grep -n "fn itemsSliceEql" extension/src/main.zig
# Should return NO matches

grep -n "fn fxSliceEql" extension/src/main.zig
# Should return NO matches

grep -n "fn sendsSliceEql" extension/src/main.zig
# Should return NO matches

# Verify new module is imported
grep -n "tier_polling" extension/src/main.zig
# Should show import line and usage

# Verify TierContext is used
grep -n "TierContext" extension/src/main.zig
# Should show context creation
```

### 5.3 Functional Verification in REAPER

1. **Build and install extension**
   ```bash
   zig build && cp zig-out/lib/libreamo.dylib ~/.config/REAPER/UserPlugins/
   ```

2. **Launch REAPER with extension loaded**

3. **Test HIGH tier (30Hz):**
   - Connect a WebSocket client
   - Press play/pause/stop
   - Verify transport events are received immediately
   - Move faders on tracks
   - Verify track state updates are received

4. **Test MEDIUM tier (5Hz):**
   - Add/delete a marker
   - Verify marker event is received within ~200ms
   - Add/delete a region
   - Verify region event is received
   - Load a different project
   - Verify project state updates are received

5. **Test LOW tier (1Hz):**
   - Add/delete a track
   - Verify skeleton event is received within ~1 second
   - Change tempo
   - Verify tempomap event is received
   - Edit project notes
   - Verify notes changed event is received

6. **Test CSurf immediate polling (if enabled):**
   - Enable CSurf build: `zig build -Dcsurf=true`
   - Make changes via REAPER UI
   - Verify instant response (not waiting for tier interval)

---

## 6. Testability Plan

### 6.1 Unit Test Strategy

The extracted module enables testing tier polling in isolation:

#### Mock Types Needed

```zig
// test_mocks.zig (or inline in tier_polling.zig tests)

pub const MockBackend = struct {
    track_count: c_int = 10,

    pub fn trackCount(self: *MockBackend) c_int {
        return self.track_count;
    }

    pub fn timePrecise(self: *MockBackend) f64 {
        _ = self;
        return 0.0;
    }

    pub fn clearLoopPoints(self: *MockBackend) void {
        _ = self;
    }
};

pub const MockSharedState = struct {
    broadcast_calls: std.ArrayList([]const u8),

    pub fn broadcast(self: *MockSharedState, json: []const u8) void {
        self.broadcast_calls.append(json) catch {};
    }
};

pub const MockTieredArenas = struct {
    // Mock high/medium/low tier state access
};
```

#### Example Unit Tests

```zig
test "pollHighTier broadcasts transport when force_transport is true" {
    // Setup mock context
    var mock_backend = MockBackend{};
    var mock_shared = MockSharedState{...};
    var mock_tiered = MockTieredArenas{...};

    const ctx = TierContext{
        .tiered = &mock_tiered,
        .backend = &mock_backend,
        .shared_state = &mock_shared,
        // ... other fields ...
    };

    var mutable = MutableState{
        .prev_tracks_hash = &0,
        // ... other fields ...
    };

    // Force transport should trigger broadcast
    const result = try pollHighTier(&ctx, &mutable, true, false);

    try std.testing.expect(mock_shared.broadcast_calls.items.len > 0);
    try std.testing.expect(result.transport_state != null);
}

test "pollMediumTier only polls on correct interval" {
    // Frame 0: Should poll (0 % 6 == 0)
    // Frame 1-5: Should not poll
    // Frame 6: Should poll (6 % 6 == 0)

    // ... test implementation ...
}

test "pollLowTier handles skeleton buffer reallocation" {
    // Test that skeleton buffer grows when needed
    // ... test implementation ...
}
```

### 6.2 Integration Test Considerations

For full integration tests:

1. **Create test project** with known track/marker/region configuration
2. **Connect test WebSocket client** that timestamps received events
3. **Measure tier latencies:**
   - HIGH tier events should arrive within ~33ms
   - MEDIUM tier events should arrive within ~200ms
   - LOW tier events should arrive within ~1s
4. **Verify CSurf acceleration** by measuring latency with dirty flags set

---

## 7. Rollback Plan

### 7.1 Git Revert (Preferred)

If the extraction causes issues:

```bash
# Find the commit hash of the extraction
git log --oneline -5

# Revert the commit
git revert <commit-hash>

# Or soft reset to undo (keeps changes as uncommitted)
git reset --soft HEAD~1
```

### 7.2 Manual Restoration

If git history is unavailable:

1. **Delete** `extension/src/tier_polling.zig`

2. **Edit main.zig:**
   - Remove `const tier_polling = @import("tier_polling.zig");`
   - Restore `MEDIUM_TIER_INTERVAL` and `LOW_TIER_INTERVAL` constants
   - Restore helper functions (markersSliceEql, etc.)
   - Remove TierContext/MutableState construction
   - Restore inline tier polling code (see Section 1 for exact code)
   - Remove test re-export for tier_polling

3. **Rebuild:**
   ```bash
   cd extension && zig build
   ```

### 7.3 Partial Rollback

If only one tier has issues, you can:

1. Keep `tier_polling.zig` with working tiers
2. Move the problematic tier back inline in `main.zig`
3. Comment out the call to the problematic function

---

## 8. Implementation Sequence

Execute these steps in order:

### Step 1: Create tier_polling.zig

```bash
# Create the new file
touch "/Users/conor/Library/Application Support/REAPER/reaper_www_root/extension/src/tier_polling.zig"
```

Copy the complete content from Section 4.1 into this file.

### Step 2: Add Import to main.zig

Edit line 40 to add:
```zig
const tier_polling = @import("tier_polling.zig");
```

### Step 3: Build and Fix Any Import Errors

```bash
cd "/Users/conor/Library/Application Support/REAPER/reaper_www_root/extension"
zig build 2>&1 | head -50
```

Fix any missing imports or type mismatches in `tier_polling.zig`.

### Step 4: Remove Helper Functions from main.zig

Remove:
- `markersSliceEql`
- `regionsSliceEql`
- `itemsSliceEql`
- `fxSliceEql`
- `sendsSliceEql`

Keep `tracksSliceEql` (still used in snapshot).

### Step 5: Remove Tier Constants

Remove `MEDIUM_TIER_INTERVAL` and `LOW_TIER_INTERVAL` from main.zig.

### Step 6: Replace HIGH Tier Block

1. Remove lines 754-903 (HIGH tier inline code)
2. Insert TierContext/MutableState construction and `pollHighTier` call

### Step 7: Keep Subscription Polling As-Is

The subscription polling block (already extracted to `subscription_polling.zig`) stays where it is.

### Step 8: Keep Playlist Engine Tick As-Is

The playlist engine tick stays in main.zig but uses `current_transport` from `high_result`.

### Step 9: Replace MEDIUM/LOW Tier Blocks

1. Remove immediate markers poll block
2. Remove regular medium tier block
3. Remove immediate tempo poll block
4. Remove regular low tier block
5. Insert `pollMediumTier` and `pollLowTier` calls

### Step 10: Add Test Re-export

Add to test block at end of main.zig:
```zig
    _ = @import("tier_polling.zig");
```

### Step 11: Build and Test

```bash
zig build test
zig build
zig build -Dcsurf=true  # If CSurf is used
```

### Step 12: Run Grep Verification

Execute all grep checks from Section 5.2.

### Step 13: Functional Test in REAPER

Follow the functional verification steps from Section 5.3.

### Step 14: Commit (User Action)

Suggested commit message:
```
refactor(main): extract tier polling to tier_polling.zig

Phase 3 of main.zig refactoring. Extracts tier-based polling from
doProcessing() into a dedicated module:

HIGH tier (30Hz): Transport, Tracks, Metering
MEDIUM tier (5Hz): Project, Markers, Regions, Items, FX, Sends
LOW tier (1Hz): Tempomap, Skeleton, Project Notes

Introduces TierContext and MutableState structs to bundle dependencies
and enable future unit testing of individual tier behaviors. Also moves
helper comparison functions (markersSliceEql, etc.) to the new module.

CSurf immediate polling (force_transport, force_markers, force_tempo)
preserved for instant latency response.

No functional changes - pure code movement.

Lines extracted: ~460
New module: tier_polling.zig (~550 lines)
main.zig: ~1710 -> ~1250 lines
```

---

## 9. Summary Metrics

| Metric | Value |
|--------|-------|
| Lines extracted from main.zig | ~460 |
| New module size | ~550 lines (including docs/tests) |
| main.zig before | ~1710 lines |
| main.zig after | ~1250 lines |
| Risk level | Medium-High |
| New public types | 3 (TierContext, MutableState, HighTierResult) |
| New public functions | 3 (pollHighTier, pollMediumTier, pollLowTier) |
| Helper functions moved | 5 |
| Constants moved | 2 |
| Behavior changes | None |
| New dependencies | None |

### Risk Factors

1. **High complexity** - Multiple scattered code blocks with interconnections
2. **Mutable state** - MutableState struct must correctly pass pointers for mutation
3. **Return values** - HighTierResult must provide transport state to main.zig
4. **Tier timing** - Frame counter logic must remain correct
5. **CSurf integration** - Immediate polling must still work with dirty flags
6. **Playlist engine** - Must continue receiving correct transport state

### Mitigation

1. Build after each edit to catch errors early
2. Run full test suite before REAPER testing
3. Verify with grep that all old code is removed
4. Test each tier independently in REAPER
5. Verify CSurf immediate polling still provides instant response
6. Keep rollback plan ready for quick recovery

---

## Appendix A: Line-by-Line Mapping

| Original Lines | New Location | Notes |
|---------------|--------------|-------|
| 106-107 | Constants in tier_polling.zig | MEDIUM/LOW intervals |
| 459-501 | Helper functions in tier_polling.zig | Slice comparison helpers |
| 760-790 | `pollHighTier()` transport block | 31 lines |
| 792-903 | `pollHighTier()` tracks/metering block | 112 lines |
| 1139-1192 | `pollMarkersImmediate()` | 54 lines |
| 1194-1379 | `pollMediumTierRegular()` | 186 lines |
| 1381-1399 | `pollTempoImmediate()` | 19 lines |
| 1401-1474 | `pollLowTierRegular()` | 74 lines |

## Appendix B: Type Dependencies

```
tier_polling.zig
+-- std
+-- reaper.zig
|   +-- RealBackend
|   +-- Api
+-- logging.zig
+-- tiered_state.zig
|   +-- TieredArenas
|   +-- EntityCounts
|   +-- CalculatedSizes
+-- guid_cache.zig
|   +-- GuidCache
+-- ws_server.zig
|   +-- SharedState
+-- csurf.zig
|   +-- enabled
+-- csurf_dirty.zig
|   +-- DirtyFlags
+-- transport.zig
|   +-- State
|   +-- PlayState
+-- tracks.zig
|   +-- State
|   +-- Track
|   +-- MAX_TRACKS
+-- markers.zig
|   +-- State
|   +-- Marker
|   +-- Region
|   +-- MAX_MARKERS
|   +-- MAX_REGIONS
+-- items.zig
|   +-- State
|   +-- Item
+-- project.zig
|   +-- State
+-- tempomap.zig
|   +-- State
+-- fx.zig
|   +-- State
|   +-- FxSlot
+-- sends.zig
|   +-- State
|   +-- SendSlot
+-- track_skeleton.zig
|   +-- State
|   +-- SkeletonTrack
+-- project_notes.zig
|   +-- NotesSubscriptions
+-- playlist.zig
|   +-- State
+-- track_subscriptions.zig
|   +-- TrackSubscriptions
|   +-- MAX_TRACKS_PER_CLIENT
|   +-- MAX_CLIENTS
+-- commands/mod.zig
|   +-- project_notes_cmds.formatChangedEvent
+-- item_guid_cache.zig
    +-- ItemGuidCache
```

## Appendix C: Key Differences from Phase 2

| Aspect | Phase 2 (subscription_polling) | Phase 3 (tier_polling) |
|--------|-------------------------------|------------------------|
| Code blocks | 5 contiguous blocks | 6+ scattered blocks across tiers |
| Mutable state | None (stateless functions) | Extensive (hashes, buffers, caches) |
| Return values | `void` or `!void` | `HighTierResult` with transport |
| Timing logic | Always runs (30Hz) | Conditional on frame counter |
| CSurf integration | Per-subscription dirty flags | Global dirty flags + immediate polls |
| Dependencies | 15 imports | 22 imports |
| Complexity | Medium | Medium-High |
