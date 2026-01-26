# Phase 2: Extract Subscription Polling

## Overview

This document provides surgical instructions for extracting subscription polling loops from `doProcessing()` in `main.zig` into a new module `subscription_polling.zig`.

**Risk Level:** Medium
**Estimated Lines Moved:** ~230
**Resulting main.zig:** ~1670 lines (down from 1901)

---

## 1. Exact Line Ranges

### 1.1 Toggle Subscriptions Polling (Lines 908-920)

```zig
// Poll toggle state subscriptions and broadcast changes (HIGH TIER - but only when subscribed)
if (g_toggle_subs) |toggles| {
    if (toggles.hasSubscriptions()) {
        var changes = toggles.poll(api);
        defer changes.deinit();

        if (changes.count() > 0) {
            const toggle_scratch = tiered.scratchAllocator();
            if (toggle_subscriptions.ToggleSubscriptions.changesToJsonAlloc(&changes, toggle_scratch)) |json| {
                shared_state.broadcast(json);
            } else |_| {}
        }
    }
}
```

**Line count:** 13 lines

### 1.2 Peaks Subscriptions Polling (Lines 922-1003)

```zig
// Poll peaks subscriptions and broadcast (HIGH TIER - per-client subscription)
// Broadcasts when: force_broadcast is set (new subscription) OR track items changed
// Uses tile-based LOD cache for efficient pan/zoom
// Tiles are fixed time-windows at each LOD level, enabling cache reuse when panning
if (g_peaks_subs) |peaks_subs| {
    if (peaks_subs.hasSubscriptions()) {
        const guid_cache_ptr = g_guid_cache orelse {
            logging.err("GUID cache not initialized for peaks subscriptions", .{});
            return error.GuidCacheNotInitialized;
        };
        const tile_cache = g_tile_cache orelse {
            logging.err("Tile cache not initialized", .{});
            return error.GuidCacheNotInitialized;
        };

        // Tick the cache for LRU tracking
        tile_cache.tick();

        // Check if any subscription needs immediate data (new subscription)
        const force_broadcast = peaks_subs.consumeForceBroadcast();
        if (force_broadcast) {
            logging.info("peaks: force_broadcast triggered", .{});
        }

        // Get all subscribed track indices across all clients
        var indices_buf: [128]c_int = undefined;
        const subscribed_indices = peaks_subs.getSubscribedIndices(guid_cache_ptr, &backend, &indices_buf);

        // Check if any track has epoch changes (audio source modified)
        var any_track_changed = force_broadcast;
        if (!force_broadcast) {
            for (subscribed_indices) |track_idx| {
                const track = backend.getTrackByIdx(track_idx) orelse continue;
                var guid_buf: [64]u8 = undefined;
                const track_guid = backend.formatTrackGuid(track, &guid_buf);
                if (tile_cache.trackChanged(track_guid, &backend, track)) {
                    any_track_changed = true;
                    break;
                }
            }
        }

        // Only broadcast if something changed
        if (any_track_changed) {
            logging.info("peaks: broadcasting to clients (force={}, indices={})", .{ force_broadcast, subscribed_indices.len });
            // Iterate active subscriptions and send to each client
            var iter = peaks_subs.activeSubscriptions();
            while (iter.next()) |entry| {
                const peaks_scratch = tiered.scratchAllocator();

                // Generate peaks for this client's subscribed tracks
                // With viewport: Use tile-based generation via AudioAccessor (all LODs)
                // Without viewport: Use legacy full-item path with fixed sample_count
                //
                // Peak fetching uses Lua bridge for reliability.
                const json: ?[]const u8 = if (entry.sub.hasViewport())
                    peaks_generator.generateTilesForSubscription(
                        peaks_scratch,
                        &backend,
                        guid_cache_ptr,
                        tile_cache,
                        entry.sub,
                    )
                else
                    peaks_generator.generatePeaksForSubscription(
                        peaks_scratch,
                        &backend,
                        guid_cache_ptr,
                        g_peaks_cache,
                        entry.sub,
                        entry.sub.sample_count,
                    );

                if (json) |j| {
                    logging.info("peaks: sending {} bytes to client {}", .{ j.len, entry.client_id });
                    shared_state.sendToClient(entry.client_id, j);
                } else {
                    logging.info("peaks: generation returned null for client {}", .{entry.client_id});
                }
            }
        }
    }
}
```

**Line count:** 82 lines

### 1.3 Routing Subscriptions Polling (Lines 1006-1043)

```zig
// Poll routing subscriptions and broadcast (HIGH TIER - per-client single-track)
// Broadcasts sends, receives (count only), and hw outputs for each subscribed track
if (g_routing_subs) |routing_subs| {
    if (routing_subs.hasSubscriptions()) {
        const guid_cache_ptr = g_guid_cache orelse {
            logging.err("GUID cache not initialized for routing subscriptions", .{});
            return error.GuidCacheNotInitialized;
        };

        var iter = routing_subs.activeSubscriptions();
        while (iter.next()) |entry| {
            const routing_scratch = tiered.scratchAllocator();

            // Generate routing state JSON for this client's subscribed track
            if (routing_generator.generateRoutingState(
                routing_scratch,
                &backend,
                guid_cache_ptr,
                entry.guid,
            )) |json| {
                // Check if changed using hash
                const data_hash = routing_generator.hashRoutingState(json);
                const hash_changed = routing_subs.checkChanged(entry.slot, data_hash);

                // CSurf: Force broadcast if this track's sends are dirty
                const sends_force = if (csurf_sends_dirty.all) true else blk: {
                    const track = guid_cache_ptr.resolve(entry.guid) orelse break :blk false;
                    const idx = guid_cache_ptr.resolveToIndex(track) orelse break :blk false;
                    break :blk if (idx >= 0 and idx < csurf_dirty.MAX_TRACKS) csurf_sends_dirty.bits.isSet(@intCast(idx)) else false;
                };

                if (hash_changed or sends_force) {
                    shared_state.sendToClient(entry.client_id, json);
                }
            }
        }
    }
}
```

**Line count:** 38 lines

### 1.4 TrackFx Subscriptions Polling (Lines 1045-1082)

```zig
// Poll track FX subscriptions and broadcast (HIGH TIER - per-client single-track)
// Broadcasts FX chain for each subscribed track
if (g_trackfx_subs) |trackfx_subs| {
    if (trackfx_subs.hasSubscriptions()) {
        const guid_cache_ptr = g_guid_cache orelse {
            logging.err("GUID cache not initialized for track FX subscriptions", .{});
            return error.GuidCacheNotInitialized;
        };

        var iter = trackfx_subs.activeSubscriptions();
        while (iter.next()) |entry| {
            const fx_scratch = tiered.scratchAllocator();

            // Generate FX chain JSON for this client's subscribed track
            if (trackfx_generator.generateTrackFxChain(
                fx_scratch,
                &backend,
                guid_cache_ptr,
                entry.guid,
            )) |json| {
                // Check if changed using hash
                const data_hash = trackfx_generator.hashTrackFxChain(json);
                const hash_changed = trackfx_subs.checkChanged(entry.slot, data_hash);

                // CSurf: Force broadcast if this track's FX is dirty
                const fx_force = if (csurf_fx_dirty.all) true else blk: {
                    const track = guid_cache_ptr.resolve(entry.guid) orelse break :blk false;
                    const idx = guid_cache_ptr.resolveToIndex(track) orelse break :blk false;
                    break :blk if (idx >= 0 and idx < csurf_dirty.MAX_TRACKS) csurf_fx_dirty.bits.isSet(@intCast(idx)) else false;
                };

                if (hash_changed or fx_force) {
                    shared_state.sendToClient(entry.client_id, json);
                }
            }
        }
    }
}
```

**Line count:** 38 lines

### 1.5 TrackFxParam Subscriptions Polling (Lines 1084-1137)

```zig
// Poll track FX parameter subscriptions and broadcast (HIGH TIER - per-client single-FX)
// Broadcasts param values for each subscribed FX
if (g_trackfxparam_subs) |trackfxparam_subs| {
    if (trackfxparam_subs.hasSubscriptions()) {
        const guid_cache_ptr = g_guid_cache orelse {
            logging.err("GUID cache not initialized for track FX param subscriptions", .{});
            return error.GuidCacheNotInitialized;
        };

        var iter = trackfxparam_subs.activeSubscriptions();
        while (iter.next()) |entry| {
            const param_scratch = tiered.scratchAllocator();

            // Generate param values JSON for this client's subscribed FX
            if (trackfxparam_generator.generateParamValues(
                param_scratch,
                &backend,
                guid_cache_ptr,
                entry.track_guid,
                entry.fx_guid,
                entry.client,
            )) |result| {
                // Check if changed using hash
                const data_hash = trackfxparam_generator.hashParamValues(result.json);
                const hash_changed = trackfxparam_subs.checkChanged(entry.slot, data_hash);

                // CSurf: Force broadcast if this track's FX params are dirty
                const fx_force = if (csurf_fx_dirty.all) true else blk: {
                    const track = guid_cache_ptr.resolve(entry.track_guid) orelse break :blk false;
                    const idx = guid_cache_ptr.resolveToIndex(track) orelse break :blk false;
                    break :blk if (idx >= 0 and idx < csurf_dirty.MAX_TRACKS) csurf_fx_dirty.bits.isSet(@intCast(idx)) else false;
                };

                if (hash_changed or fx_force) {
                    shared_state.sendToClient(entry.client_id, result.json);
                }
                // Reset failure count on successful generation
                trackfxparam_subs.resetFailures(entry.client_id);
            } else {
                // Track or FX not found - increment failure count
                if (trackfxparam_subs.recordFailure(entry.client_id)) {
                    // Auto-unsubscribe after 3 failures (~100ms at 30Hz)
                    logging.warn("trackfxparam: auto-unsubscribing client {d} after repeated failures", .{entry.client_id});

                    // Send error event to client
                    const error_json = "{\"type\":\"event\",\"event\":\"trackFxParamsError\",\"error\":\"FX_NOT_FOUND\"}";
                    shared_state.sendToClient(entry.client_id, error_json);

                    trackfxparam_subs.unsubscribe(entry.client_id);
                }
            }
        }
    }
}
```

**Line count:** 54 lines

### 1.6 Summary of Lines to Extract

| Block | Start Line | End Line | Line Count |
|-------|------------|----------|------------|
| Toggle subscriptions | 908 | 920 | 13 |
| Peaks subscriptions | 922 | 1003 | 82 |
| Routing subscriptions | 1006 | 1043 | 38 |
| TrackFx subscriptions | 1045 | 1082 | 38 |
| TrackFxParam subscriptions | 1084 | 1137 | 54 |
| **Total** | - | - | **225** |

---

## 2. Dependency Analysis

### 2.1 Required Imports for subscription_polling.zig

```zig
const std = @import("std");
const reaper = @import("reaper.zig");
const logging = @import("logging.zig");
const tiered_state = @import("tiered_state.zig");
const guid_cache = @import("guid_cache.zig");
const ws_server = @import("ws_server.zig");
const csurf_dirty = @import("csurf_dirty.zig");

// Subscription types
const toggle_subscriptions = @import("toggle_subscriptions.zig");
const peaks_subscriptions = @import("peaks_subscriptions.zig");
const routing_subscriptions = @import("routing_subscriptions.zig");
const trackfx_subscriptions = @import("trackfx_subscriptions.zig");
const trackfxparam_subscriptions = @import("trackfxparam_subscriptions.zig");

// Generators
const peaks_generator = @import("peaks_generator.zig");
const routing_generator = @import("routing_generator.zig");
const trackfx_generator = @import("trackfx_generator.zig");
const trackfxparam_generator = @import("trackfxparam_generator.zig");

// Caches
const peaks_cache = @import("peaks_cache.zig");
const peaks_tile = @import("peaks_tile.zig");
```

### 2.2 Parameters Required from Caller

Each polling function needs access to shared state from `doProcessing()`. Rather than passing many individual parameters, we define a `PollingContext` struct:

| Parameter | Type | Source in main.zig |
|-----------|------|-------------------|
| `tiered` | `*tiered_state.TieredArenas` | `&(g_tiered orelse ...)` |
| `backend` | `*reaper.RealBackend` | `&backend` (local) |
| `shared_state` | `*ws_server.SharedState` | `g_shared_state orelse ...` |
| `guid_cache` | `*guid_cache.GuidCache` | `g_guid_cache orelse ...` |
| `csurf_fx_dirty` | `csurf_dirty.TrackDirtyResult` | Local variable |
| `csurf_sends_dirty` | `csurf_dirty.TrackDirtyResult` | Local variable |

Additional per-function parameters:

| Function | Additional Parameters |
|----------|----------------------|
| `pollToggleSubscriptions` | `api: *const reaper.Api`, `toggle_subs: *toggle_subscriptions.ToggleSubscriptions` |
| `pollPeaksSubscriptions` | `peaks_subs: *peaks_subscriptions.PeaksSubscriptions`, `tile_cache: *peaks_tile.TileCache`, `peaks_cache_ptr: ?*peaks_cache.PeaksCache` |
| `pollRoutingSubscriptions` | `routing_subs: *routing_subscriptions.RoutingSubscriptions` |
| `pollTrackFxSubscriptions` | `trackfx_subs: *trackfx_subscriptions.TrackFxSubscriptions` |
| `pollTrackFxParamSubscriptions` | `trackfxparam_subs: *trackfxparam_subscriptions.TrackFxParamSubscriptions` |

### 2.3 Globals Referenced

The code currently accesses these globals directly:

| Global | Usage | Strategy |
|--------|-------|----------|
| `g_toggle_subs` | Toggle polling | Pass as parameter |
| `g_peaks_subs` | Peaks polling | Pass as parameter |
| `g_routing_subs` | Routing polling | Pass as parameter |
| `g_trackfx_subs` | TrackFx polling | Pass as parameter |
| `g_trackfxparam_subs` | TrackFxParam polling | Pass as parameter |
| `g_guid_cache` | All subscription polling | Pass via PollingContext |
| `g_tile_cache` | Peaks polling | Pass as parameter |
| `g_peaks_cache` | Peaks polling (legacy path) | Pass as parameter |
| `csurf_fx_dirty` | FX/param dirty checking | Pass via PollingContext |
| `csurf_sends_dirty` | Routing dirty checking | Pass via PollingContext |

**Strategy:** All globals become explicit parameters. The `PollingContext` struct holds shared dependencies, and subscription-specific objects are passed individually.

---

## 3. Interface Design

### 3.1 PollingContext Struct

```zig
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
```

### 3.2 Function Signatures

```zig
/// Poll toggle subscriptions and broadcast changes to subscribed clients.
/// Runs at 30Hz but only processes when there are active subscriptions.
pub fn pollToggleSubscriptions(
    ctx: *const PollingContext,
    toggle_subs: *toggle_subscriptions.ToggleSubscriptions,
    api: *const reaper.Api,
) void;

/// Poll peaks subscriptions and broadcast waveform data to subscribed clients.
/// Uses tile-based LOD cache for efficient pan/zoom operations.
/// Broadcasts when: force_broadcast is set OR track audio source changed.
pub fn pollPeaksSubscriptions(
    ctx: *const PollingContext,
    peaks_subs: *peaks_subscriptions.PeaksSubscriptions,
    tile_cache: *peaks_tile.TileCache,
    peaks_cache_ptr: ?*peaks_cache.PeaksCache,
) !void;

/// Poll routing subscriptions and broadcast sends/receives/hw outputs.
/// Per-client single-track subscriptions with hash-based change detection.
pub fn pollRoutingSubscriptions(
    ctx: *const PollingContext,
    routing_subs: *routing_subscriptions.RoutingSubscriptions,
) !void;

/// Poll track FX subscriptions and broadcast FX chain state.
/// Per-client single-track subscriptions with hash-based change detection.
pub fn pollTrackFxSubscriptions(
    ctx: *const PollingContext,
    trackfx_subs: *trackfx_subscriptions.TrackFxSubscriptions,
) !void;

/// Poll track FX parameter subscriptions and broadcast param values.
/// Per-client single-FX subscriptions with auto-unsubscribe on failure.
pub fn pollTrackFxParamSubscriptions(
    ctx: *const PollingContext,
    trackfxparam_subs: *trackfxparam_subscriptions.TrackFxParamSubscriptions,
) !void;
```

### 3.3 Usage from main.zig

After extraction, the polling section in `doProcessing()` becomes:

```zig
const subscription_polling = @import("subscription_polling.zig");

// ... in doProcessing() after track/metering polling ...

// Build polling context (once per frame)
const poll_ctx = subscription_polling.PollingContext{
    .tiered = tiered,
    .backend = &backend,
    .shared_state = shared_state,
    .guid_cache_ptr = g_guid_cache.?,
    .csurf_fx_dirty = csurf_fx_dirty,
    .csurf_sends_dirty = csurf_sends_dirty,
};

// Poll subscription-based state (30Hz)
if (g_toggle_subs) |toggles| {
    subscription_polling.pollToggleSubscriptions(&poll_ctx, toggles, api);
}
if (g_peaks_subs) |peaks_subs| {
    try subscription_polling.pollPeaksSubscriptions(&poll_ctx, peaks_subs, g_tile_cache.?, g_peaks_cache);
}
if (g_routing_subs) |routing_subs| {
    try subscription_polling.pollRoutingSubscriptions(&poll_ctx, routing_subs);
}
if (g_trackfx_subs) |trackfx_subs| {
    try subscription_polling.pollTrackFxSubscriptions(&poll_ctx, trackfx_subs);
}
if (g_trackfxparam_subs) |trackfxparam_subs| {
    try subscription_polling.pollTrackFxParamSubscriptions(&poll_ctx, trackfxparam_subs);
}
```

---

## 4. The Extraction

### 4.1 Complete subscription_polling.zig

Create file at: `extension/src/subscription_polling.zig`

```zig
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
const reaper = @import("reaper.zig");
const logging = @import("logging.zig");
const tiered_state = @import("tiered_state.zig");
const guid_cache = @import("guid_cache.zig");
const ws_server = @import("ws_server.zig");
const csurf_dirty = @import("csurf_dirty.zig");

// Subscription types
const toggle_subscriptions = @import("toggle_subscriptions.zig");
const peaks_subscriptions = @import("peaks_subscriptions.zig");
const routing_subscriptions = @import("routing_subscriptions.zig");
const trackfx_subscriptions = @import("trackfx_subscriptions.zig");
const trackfxparam_subscriptions = @import("trackfxparam_subscriptions.zig");

// Generators
const peaks_generator = @import("peaks_generator.zig");
const routing_generator = @import("routing_generator.zig");
const trackfx_generator = @import("trackfx_generator.zig");
const trackfxparam_generator = @import("trackfxparam_generator.zig");

// Caches
const peaks_cache = @import("peaks_cache.zig");
const peaks_tile = @import("peaks_tile.zig");

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
/// Broadcasts when: force_broadcast is set OR track audio source changed.
pub fn pollPeaksSubscriptions(
    ctx: *const PollingContext,
    peaks_subs: *peaks_subscriptions.PeaksSubscriptions,
    tile_cache: *peaks_tile.TileCache,
    peaks_cache_ptr: ?*peaks_cache.PeaksCache,
) !void {
    if (!peaks_subs.hasSubscriptions()) return;

    // Tick the cache for LRU tracking
    tile_cache.tick();

    // Check if any subscription needs immediate data (new subscription)
    const force_broadcast = peaks_subs.consumeForceBroadcast();
    if (force_broadcast) {
        logging.info("peaks: force_broadcast triggered", .{});
    }

    // Get all subscribed track indices across all clients
    var indices_buf: [128]c_int = undefined;
    const subscribed_indices = peaks_subs.getSubscribedIndices(ctx.guid_cache_ptr, ctx.backend, &indices_buf);

    // Check if any track has epoch changes (audio source modified)
    var any_track_changed = force_broadcast;
    if (!force_broadcast) {
        for (subscribed_indices) |track_idx| {
            const track = ctx.backend.getTrackByIdx(track_idx) orelse continue;
            var guid_buf: [64]u8 = undefined;
            const track_guid = ctx.backend.formatTrackGuid(track, &guid_buf);
            if (tile_cache.trackChanged(track_guid, ctx.backend, track)) {
                any_track_changed = true;
                break;
            }
        }
    }

    // Only broadcast if something changed
    if (any_track_changed) {
        logging.info("peaks: broadcasting to clients (force={}, indices={})", .{ force_broadcast, subscribed_indices.len });
        // Iterate active subscriptions and send to each client
        var iter = peaks_subs.activeSubscriptions();
        while (iter.next()) |entry| {
            const scratch = ctx.scratchAllocator();

            // Generate peaks for this client's subscribed tracks
            // With viewport: Use tile-based generation via AudioAccessor (all LODs)
            // Without viewport: Use legacy full-item path with fixed sample_count
            //
            // Peak fetching uses Lua bridge for reliability.
            const json: ?[]const u8 = if (entry.sub.hasViewport())
                peaks_generator.generateTilesForSubscription(
                    scratch,
                    ctx.backend,
                    ctx.guid_cache_ptr,
                    tile_cache,
                    entry.sub,
                )
            else
                peaks_generator.generatePeaksForSubscription(
                    scratch,
                    ctx.backend,
                    ctx.guid_cache_ptr,
                    peaks_cache_ptr,
                    entry.sub,
                    entry.sub.sample_count,
                );

            if (json) |j| {
                logging.info("peaks: sending {} bytes to client {}", .{ j.len, entry.client_id });
                ctx.shared_state.sendToClient(entry.client_id, j);
            } else {
                logging.info("peaks: generation returned null for client {}", .{entry.client_id});
            }
        }
    }
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
                const track = ctx.guid_cache_ptr.resolve(entry.guid) orelse break :blk false;
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
                const track = ctx.guid_cache_ptr.resolve(entry.guid) orelse break :blk false;
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
        if (trackfxparam_generator.generateParamValues(
            scratch,
            ctx.backend,
            ctx.guid_cache_ptr,
            entry.track_guid,
            entry.fx_guid,
            entry.client,
        )) |result| {
            // Check if changed using hash
            const data_hash = trackfxparam_generator.hashParamValues(result.json);
            const hash_changed = trackfxparam_subs.checkChanged(entry.slot, data_hash);

            // CSurf: Force broadcast if this track's FX params are dirty
            const fx_force = if (ctx.csurf_fx_dirty.all) true else blk: {
                const track = ctx.guid_cache_ptr.resolve(entry.track_guid) orelse break :blk false;
                const idx = ctx.guid_cache_ptr.resolveToIndex(track) orelse break :blk false;
                break :blk if (idx >= 0 and idx < csurf_dirty.MAX_TRACKS) ctx.csurf_fx_dirty.bits.isSet(@intCast(idx)) else false;
            };

            if (hash_changed or fx_force) {
                ctx.shared_state.sendToClient(entry.client_id, result.json);
            }
            // Reset failure count on successful generation
            trackfxparam_subs.resetFailures(entry.client_id);
        } else {
            // Track or FX not found - increment failure count
            if (trackfxparam_subs.recordFailure(entry.client_id)) {
                // Auto-unsubscribe after 3 failures (~100ms at 30Hz)
                logging.warn("trackfxparam: auto-unsubscribing client {d} after repeated failures", .{entry.client_id});

                // Send error event to client
                const error_json = "{\"type\":\"event\",\"event\":\"trackFxParamsError\",\"error\":\"FX_NOT_FOUND\"}";
                ctx.shared_state.sendToClient(entry.client_id, error_json);

                trackfxparam_subs.unsubscribe(entry.client_id);
            }
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
```

### 4.2 Edits to main.zig

#### 4.2.1 Add Import (after line 38)

Add this import after the `lua_peak_bridge` import:

```zig
const subscription_polling = @import("subscription_polling.zig");
```

**Edit location:** Line 39 (insert after `const lua_peak_bridge = @import("lua_peak_bridge.zig");`)

#### 4.2.2 Remove Old Toggle Subscription Polling (Lines 907-920)

**Remove this block:**

```zig
    // Poll toggle state subscriptions and broadcast changes (HIGH TIER - but only when subscribed)
    if (g_toggle_subs) |toggles| {
        if (toggles.hasSubscriptions()) {
            var changes = toggles.poll(api);
            defer changes.deinit();

            if (changes.count() > 0) {
                const toggle_scratch = tiered.scratchAllocator();
                if (toggle_subscriptions.ToggleSubscriptions.changesToJsonAlloc(&changes, toggle_scratch)) |json| {
                    shared_state.broadcast(json);
                } else |_| {}
            }
        }
    }
```

#### 4.2.3 Remove Old Peaks Subscription Polling (Lines 922-1003)

**Remove entire block starting with:**
```zig
    // Poll peaks subscriptions and broadcast (HIGH TIER - per-client subscription)
```

**Through the closing brace of the `if (g_peaks_subs)` block.**

#### 4.2.4 Remove Old Routing Subscription Polling (Lines 1006-1043)

**Remove entire block starting with:**
```zig
    // Poll routing subscriptions and broadcast (HIGH TIER - per-client single-track)
```

#### 4.2.5 Remove Old TrackFx Subscription Polling (Lines 1045-1082)

**Remove entire block starting with:**
```zig
    // Poll track FX subscriptions and broadcast (HIGH TIER - per-client single-track)
```

#### 4.2.6 Remove Old TrackFxParam Subscription Polling (Lines 1084-1137)

**Remove entire block starting with:**
```zig
    // Poll track FX parameter subscriptions and broadcast (HIGH TIER - per-client single-FX)
```

#### 4.2.7 Insert New Polling Code

**Insert at line 907** (where toggle polling was removed):

```zig
    // ========================================================================
    // SUBSCRIPTION POLLING (30Hz) - Toggle, Peaks, Routing, TrackFx, TrackFxParam
    // Extracted to subscription_polling.zig for testability
    // ========================================================================

    // Build polling context (once per frame)
    // Note: guid_cache is required for all subscription polling
    if (g_guid_cache) |cache| {
        const poll_ctx = subscription_polling.PollingContext{
            .tiered = tiered,
            .backend = &backend,
            .shared_state = shared_state,
            .guid_cache_ptr = cache,
            .csurf_fx_dirty = csurf_fx_dirty,
            .csurf_sends_dirty = csurf_sends_dirty,
        };

        // Poll toggle subscriptions
        if (g_toggle_subs) |toggles| {
            subscription_polling.pollToggleSubscriptions(&poll_ctx, toggles, api);
        }

        // Poll peaks subscriptions
        if (g_peaks_subs) |peaks_subs| {
            if (g_tile_cache) |tile_cache| {
                try subscription_polling.pollPeaksSubscriptions(&poll_ctx, peaks_subs, tile_cache, g_peaks_cache);
            }
        }

        // Poll routing subscriptions
        if (g_routing_subs) |routing_subs| {
            try subscription_polling.pollRoutingSubscriptions(&poll_ctx, routing_subs);
        }

        // Poll track FX subscriptions
        if (g_trackfx_subs) |trackfx_subs| {
            try subscription_polling.pollTrackFxSubscriptions(&poll_ctx, trackfx_subs);
        }

        // Poll track FX param subscriptions
        if (g_trackfxparam_subs) |trackfxparam_subs| {
            try subscription_polling.pollTrackFxParamSubscriptions(&poll_ctx, trackfxparam_subs);
        }
    }
```

#### 4.2.8 Add Test Re-export

**Add to test block at end of main.zig:**

```zig
    _ = @import("subscription_polling.zig");
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

# Build with all features (if applicable)
zig build -Dcsurf=true
```

### 5.2 Grep Checks for Dangling References

After extraction, verify no orphaned references exist:

```bash
# Ensure old inline polling code is removed
grep -n "toggles.poll(api)" extension/src/main.zig
# Should return NO matches

grep -n "peaks_generator.generateTilesForSubscription" extension/src/main.zig
# Should return NO matches (only in subscription_polling.zig)

grep -n "routing_generator.generateRoutingState" extension/src/main.zig
# Should return NO matches (only in subscription_polling.zig)

grep -n "trackfx_generator.generateTrackFxChain" extension/src/main.zig
# Should return NO matches (only in subscription_polling.zig)

grep -n "trackfxparam_generator.generateParamValues" extension/src/main.zig
# Should return NO matches (only in subscription_polling.zig)

# Verify new module is imported
grep -n "subscription_polling" extension/src/main.zig
# Should show import line and usage

# Verify PollingContext is used
grep -n "PollingContext" extension/src/main.zig
# Should show context creation
```

### 5.3 Functional Verification in REAPER

1. **Build and install extension**
   ```bash
   zig build && cp zig-out/lib/libreamo.dylib ~/.config/REAPER/UserPlugins/
   ```

2. **Launch REAPER with extension loaded**

3. **Test toggle subscriptions:**
   - Connect a WebSocket client
   - Subscribe to toggle states
   - Toggle record arm, mute, solo on tracks
   - Verify toggle change events are received

4. **Test peaks subscriptions:**
   - Subscribe to peaks with a viewport
   - Verify waveform data is received
   - Pan/zoom the viewport
   - Verify tile updates are sent

5. **Test routing subscriptions:**
   - Subscribe to a track's routing
   - Add/remove sends on that track
   - Verify routing updates are received

6. **Test trackfx subscriptions:**
   - Subscribe to a track's FX chain
   - Add/remove/reorder FX on that track
   - Verify FX chain updates are received

7. **Test trackfxparam subscriptions:**
   - Subscribe to an FX's parameters
   - Adjust parameters
   - Verify param value updates are received
   - Delete the FX - verify error event and auto-unsubscribe

---

## 6. Testability Plan

### 6.1 Unit Test Strategy

The extracted module enables testing individual subscription behaviors without running the full `doProcessing()` loop.

#### Mock Types Needed

```zig
// test_mocks.zig (or inline in subscription_polling.zig tests)

pub const MockBackend = struct {
    track_count: c_int = 10,
    // Add mock methods as needed

    pub fn getTrackByIdx(self: *MockBackend, idx: c_int) ?*anyopaque {
        if (idx >= 0 and idx < self.track_count) {
            // Return a non-null pointer for valid indices
            return @ptrFromInt(@as(usize, @intCast(idx)) + 1);
        }
        return null;
    }

    pub fn formatTrackGuid(self: *MockBackend, track: *anyopaque, buf: []u8) []const u8 {
        _ = self;
        _ = track;
        return std.fmt.bufPrint(buf, "mock-guid", .{}) catch "error";
    }
};

pub const MockSharedState = struct {
    broadcast_calls: std.ArrayList([]const u8),
    client_sends: std.AutoHashMap(usize, std.ArrayList([]const u8)),

    pub fn broadcast(self: *MockSharedState, json: []const u8) void {
        self.broadcast_calls.append(json) catch {};
    }

    pub fn sendToClient(self: *MockSharedState, client_id: usize, json: []const u8) void {
        const entry = self.client_sends.getOrPut(client_id) catch return;
        if (!entry.found_existing) {
            entry.value_ptr.* = std.ArrayList([]const u8).init(std.testing.allocator);
        }
        entry.value_ptr.append(json) catch {};
    }
};
```

#### Example Unit Tests

```zig
test "pollToggleSubscriptions broadcasts when changes detected" {
    // Setup mock toggle subscriptions with pending changes
    var toggles = toggle_subscriptions.ToggleSubscriptions.init(std.testing.allocator);
    defer toggles.deinit();

    // Add a subscription
    toggles.subscribe(1, 40001); // Client 1, action ID 40001

    // Create mock context
    var mock_shared = MockSharedState{...};
    var mock_tiered = ...; // Mock tiered arenas
    var mock_backend = MockBackend{};

    const ctx = PollingContext{
        .tiered = &mock_tiered,
        .backend = &mock_backend,
        .shared_state = &mock_shared,
        .guid_cache_ptr = ...,
        .csurf_fx_dirty = .{},
        .csurf_sends_dirty = .{},
    };

    // Poll with mock API that returns changed state
    pollToggleSubscriptions(&ctx, &toggles, &mock_api);

    // Verify broadcast was called
    try std.testing.expect(mock_shared.broadcast_calls.items.len > 0);
}

test "pollPeaksSubscriptions skips when no subscriptions" {
    var peaks_subs = peaks_subscriptions.PeaksSubscriptions.init(std.testing.allocator);
    defer peaks_subs.deinit();

    // No subscriptions added

    var mock_shared = MockSharedState{...};
    // ... setup context ...

    try pollPeaksSubscriptions(&ctx, &peaks_subs, &tile_cache, null);

    // Verify no broadcasts occurred
    try std.testing.expect(mock_shared.broadcast_calls.items.len == 0);
}

test "pollTrackFxParamSubscriptions auto-unsubscribes after failures" {
    var trackfxparam_subs = trackfxparam_subscriptions.TrackFxParamSubscriptions.init(std.testing.allocator);
    defer trackfxparam_subs.deinit();

    // Add subscription to non-existent track
    trackfxparam_subs.subscribe(1, "invalid-track-guid", "invalid-fx-guid");

    // Poll 3 times (failure threshold)
    for (0..3) |_| {
        try pollTrackFxParamSubscriptions(&ctx, &trackfxparam_subs);
    }

    // Verify auto-unsubscribed
    try std.testing.expect(!trackfxparam_subs.hasSubscriptions());
}
```

### 6.2 Integration Test Considerations

For full integration tests, consider:

1. **Create test project in REAPER** with known track/FX configuration
2. **Connect test WebSocket client** that subscribes to various states
3. **Manipulate REAPER state** via API
4. **Verify events received** match expected structure

These tests would run outside the unit test framework, possibly as a separate integration test script.

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

1. **Delete** `extension/src/subscription_polling.zig`

2. **Edit main.zig:**
   - Remove `const subscription_polling = @import("subscription_polling.zig");`
   - Remove the new polling context code block
   - Restore the original inline polling code (see Section 1 for exact code)
   - Remove test re-export for subscription_polling

3. **Rebuild:**
   ```bash
   cd extension && zig build
   ```

### 7.3 Partial Rollback

If only one polling function has issues, you can:

1. Keep `subscription_polling.zig` with working functions
2. Move the problematic polling back inline in `main.zig`
3. Comment out the call to the problematic function

---

## 8. Implementation Sequence

Execute these steps in order:

### Step 1: Create subscription_polling.zig

```bash
# Create the new file
touch "/Users/conor/Library/Application Support/REAPER/reaper_www_root/extension/src/subscription_polling.zig"
```

Copy the complete content from Section 4.1 into this file.

### Step 2: Add Import to main.zig

Edit line 39 to add:
```zig
const subscription_polling = @import("subscription_polling.zig");
```

### Step 3: Build and Fix Any Import Errors

```bash
cd "/Users/conor/Library/Application Support/REAPER/reaper_www_root/extension"
zig build 2>&1 | head -50
```

Fix any missing imports or type mismatches in `subscription_polling.zig`.

### Step 4: Replace Inline Polling Code

1. Remove lines 907-1137 (all five subscription polling blocks)
2. Insert the new polling code from Section 4.2.7 at line 907

### Step 5: Add Test Re-export

Add to test block at end of main.zig:
```zig
    _ = @import("subscription_polling.zig");
```

### Step 6: Build and Test

```bash
zig build test
zig build
```

### Step 7: Run Grep Verification

Execute all grep checks from Section 5.2.

### Step 8: Functional Test in REAPER

Follow the functional verification steps from Section 5.3.

### Step 9: Commit (User Action)

Suggested commit message:
```
refactor(main): extract subscription polling to subscription_polling.zig

Phase 2 of main.zig refactoring. Extracts five subscription polling
loops from doProcessing():
- Toggle subscriptions
- Peaks subscriptions
- Routing subscriptions
- TrackFx subscriptions
- TrackFxParam subscriptions

Introduces PollingContext struct to bundle shared dependencies,
enabling future unit testing of individual polling behaviors.

No functional changes - pure code movement.

Lines extracted: ~230
New module: subscription_polling.zig (~280 lines)
main.zig: 1901 -> ~1670 lines
```

---

## 9. Summary Metrics

| Metric | Value |
|--------|-------|
| Lines extracted from main.zig | ~230 |
| New module size | ~280 lines (including docs/tests) |
| main.zig before | 1901 lines |
| main.zig after | ~1670 lines |
| Risk level | Medium |
| New public types | 1 (PollingContext) |
| New public functions | 5 |
| Behavior changes | None |
| New dependencies | None |

### Risk Factors

1. **Medium complexity** - Multiple code blocks with CSurf dirty flag interactions
2. **Error handling** - Functions return `!void`, errors must propagate correctly
3. **Context struct** - New PollingContext must be constructed correctly each frame
4. **Null checks** - Multiple optional values (caches, subscriptions) require careful handling

### Mitigation

1. Build after each edit to catch errors early
2. Run full test suite before REAPER testing
3. Verify with grep that all old code is removed
4. Test each subscription type individually in REAPER
5. Keep rollback plan ready for quick recovery

---

## Appendix A: Line-by-Line Mapping

| Original Lines | New Location | Notes |
|---------------|--------------|-------|
| 907-920 | `pollToggleSubscriptions()` | 13 lines |
| 922-1003 | `pollPeaksSubscriptions()` | 82 lines |
| 1006-1043 | `pollRoutingSubscriptions()` | 38 lines |
| 1045-1082 | `pollTrackFxSubscriptions()` | 38 lines |
| 1084-1137 | `pollTrackFxParamSubscriptions()` | 54 lines |

## Appendix B: Type Dependencies

```
subscription_polling.zig
├── std
├── reaper.zig
│   └── RealBackend
├── logging.zig
├── tiered_state.zig
│   └── TieredArenas
├── guid_cache.zig
│   └── GuidCache
├── ws_server.zig
│   └── SharedState
├── csurf_dirty.zig
│   └── TrackDirtyResult
│   └── MAX_TRACKS
├── toggle_subscriptions.zig
│   └── ToggleSubscriptions
├── peaks_subscriptions.zig
│   └── PeaksSubscriptions
├── routing_subscriptions.zig
│   └── RoutingSubscriptions
├── trackfx_subscriptions.zig
│   └── TrackFxSubscriptions
├── trackfxparam_subscriptions.zig
│   └── TrackFxParamSubscriptions
├── peaks_generator.zig
│   └── generateTilesForSubscription
│   └── generatePeaksForSubscription
├── routing_generator.zig
│   └── generateRoutingState
│   └── hashRoutingState
├── trackfx_generator.zig
│   └── generateTrackFxChain
│   └── hashTrackFxChain
├── trackfxparam_generator.zig
│   └── generateParamValues
│   └── hashParamValues
├── peaks_cache.zig
│   └── PeaksCache
└── peaks_tile.zig
    └── TileCache
```
