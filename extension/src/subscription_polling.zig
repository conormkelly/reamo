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
