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
/// Sends a client its tiles when it subscribes or moves its viewport
/// (forced), and every client fresh tiles when a subscribed track's items
/// or a take's audio source change, at most once per
/// CHANGE_BROADCAST_INTERVAL_MS; a change that limit holds back goes out on
/// the first tick it allows.
pub fn pollPeaksSubscriptions(
    ctx: *const PollingContext,
    peaks_subs: *peaks_subscriptions.PeaksSubscriptions,
    tile_cache: *peaks_tile.TileCache,
) !void {
    if (!peaks_subs.hasSubscriptions()) {
        // Nobody is left to owe a held change to.
        peaks_subs.change_pending = false;
        return;
    }

    // Tick the cache for LRU tracking
    tile_cache.tick();

    // Some client subscribed or moved its viewport and needs its own tiles now.
    const any_forced = peaks_subs.anyForceBroadcast();

    // Get all subscribed track indices across all clients
    var indices_buf: [128]c_int = undefined;
    const subscribed_indices = peaks_subs.getSubscribedIndices(ctx.guid_cache_ptr, ctx.backend, &indices_buf);

    // Check every subscribed track for a change (items, or a take's audio
    // source); that goes to every client. Every track, not just up to the
    // first change: trackChanged also drops a changed take's stale tiles,
    // which the broadcast below must not send. A forced tick skips the check
    // (the next tick sees any change) and only remembers tracks never
    // checked: the forced send gives them as they are, and the first check
    // of a track counts as a change, which would resend them to everyone.
    var any_track_changed = false;
    for (subscribed_indices) |track_idx| {
        // Unified index (0 = master), as the generator resolves it.
        const track = ctx.backend.getTrackByUnifiedIdx(track_idx) orelse continue;
        var guid_buf: [64]u8 = undefined;
        const track_guid = ctx.backend.formatTrackGuid(track, &guid_buf);
        if (any_forced) {
            tile_cache.rememberTrack(track_guid, ctx.backend, track);
        } else if (tile_cache.trackChanged(track_guid, ctx.backend, track)) {
            any_track_changed = true;
        }
    }

    // A change goes to every client, rate-limited; one the limit holds back
    // goes out on the first tick it allows. Forced per-client sends bypass
    // the limit, as initial data always did.
    const now_ms = std.time.milliTimestamp();
    var send_change = false;
    if (any_forced) {
        // Leaves change_pending alone: a held change goes out on a later
        // tick, after this send's interval.
        peaks_subs.last_broadcast_ms = now_ms;
    } else {
        send_change = peaks_subs.changeBroadcastDue(any_track_changed, now_ms);
        if (!send_change) return;
    }

    logging.debug("peaks: broadcasting (content changed={}, forced={}, indices={})", .{ send_change, any_forced, subscribed_indices.len });
    var iter = peaks_subs.activeSubscriptions();
    while (iter.next()) |entry| {
        const forced = peaks_subs.consumeForceBroadcast(entry.slot);
        if (!forced and !send_change) continue;

        const scratch = ctx.scratchAllocator();

        if (!entry.sub.hasViewport()) {
            logging.debug("peaks: skipping client {} (no viewport)", .{entry.client_id});
            continue;
        }

        const bin = peaks_generator.generateTilesForSubscriptionBinary(
            scratch,
            ctx.backend,
            ctx.guid_cache_ptr,
            tile_cache,
            entry.sub,
        );
        if (bin) |b| {
            logging.debug("peaks: sending {} bytes (binary) to client {}", .{ b.len, entry.client_id });
            ctx.shared_state.sendBinToClient(entry.client_id, b);
        } else {
            logging.debug("peaks: binary generation returned null for client {}", .{entry.client_id});
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
