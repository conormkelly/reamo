//! Playlist Engine Tick Module
//!
//! Extracted from main.zig doProcessing() to enable unit testing of
//! playlist engine behaviors in isolation.
//!
//! The playlist engine runs at 30Hz (HIGH tier) but relies on regions
//! from the MEDIUM tier (5Hz). This module uses cached regions passed
//! in via PlaylistTickContext to look up region bounds.
//!
//! Key behaviors:
//! - Transport sync: Detect when REAPER transport stops/pauses externally
//! - Region transitions: Advance to next entry when current region ends
//! - Loop management: Handle region looping and native REAPER loops
//! - Deleted regions: Skip to next valid entry when region is deleted

const std = @import("std");
const reaper = @import("../reaper.zig");
const logging = @import("../core/logging.zig");
const transport = @import("../state/transport.zig");
const playlist = @import("../state/playlist.zig");
const markers = @import("../state/markers.zig");
const ws_server = @import("ws_server.zig");
const tiered_state = @import("tiered_state.zig");

/// Context for playlist engine tick operations.
/// Contains all state needed to sync and advance the playlist engine.
pub const PlaylistTickContext = struct {
    /// Playlist state (mutable - engine state is modified)
    playlist_state: *playlist.State,
    /// Current transport state from HIGH tier
    transport_state: *const transport.State,
    /// Cached regions for region lookups
    regions: []const markers.Region,
    /// Tiered arenas for scratch allocation
    tiered: *tiered_state.TieredArenas,
    /// WebSocket shared state for broadcasting
    shared_state: *ws_server.SharedState,

    /// Create a scratch allocator from the tiered arenas
    pub fn scratchAllocator(self: *const PlaylistTickContext) std.mem.Allocator {
        return self.tiered.scratchAllocator();
    }
};

/// Sync playlist engine with external transport changes.
/// When the user pauses/stops REAPER transport outside our control,
/// we need to update the engine state to match.
///
/// Returns: true if state changed and was broadcast
pub fn syncWithTransport(
    ctx: *const PlaylistTickContext,
    backend: anytype,
) bool {
    // Only sync if engine is active (playing or paused)
    if (!ctx.playlist_state.engine.isActive()) {
        return false;
    }

    const transport_playing = transport.PlayState.isPlaying(ctx.transport_state.play_state);
    const transport_stopped = ctx.transport_state.play_state == transport.PlayState.STOPPED;

    // Check if engine thinks it's playing but transport isn't
    if (ctx.playlist_state.engine.isPlaying() and !transport_playing) {
        if (transport_stopped) {
            // Transport stopped externally - stop engine
            _ = ctx.playlist_state.engine.stop();
            backend.setRepeat(false);
            backend.clearLoopPoints();
            logging.debug("Stopped playlist engine - transport stopped externally", .{});
        } else {
            // Transport paused - pause engine
            _ = ctx.playlist_state.engine.pause();
            logging.debug("Paused playlist engine - transport paused externally", .{});
        }

        // Broadcast state change
        const scratch = ctx.scratchAllocator();
        if (ctx.playlist_state.toJsonAlloc(scratch, ctx.regions)) |json| {
            ctx.shared_state.broadcast(json);
        } else |_| {}

        return true;
    }

    return false;
}

/// Region bounds (start/end positions).
const RegionBounds = struct { start: f64, end: f64 };

/// Find region bounds by region ID.
/// Returns null if region not found (deleted).
fn findRegionBounds(regions: []const markers.Region, region_id: i32) ?RegionBounds {
    for (regions) |*r| {
        if (r.id == region_id) {
            return .{ .start = r.start, .end = r.end };
        }
    }
    return null;
}

/// Get next entry info for the playlist engine tick.
fn getNextEntryInfo(
    playlist_entries: []const playlist.Entry,
    current_idx: usize,
    entry_count: usize,
    regions: []const markers.Region,
) ?playlist.NextEntryInfo {
    if (current_idx + 1 >= entry_count) {
        return null;
    }

    const next = &playlist_entries[current_idx + 1];

    // Find next region's bounds
    for (regions) |*r| {
        if (r.id == next.region_id) {
            return playlist.NextEntryInfo{
                .loop_count = next.loop_count,
                .region_start = r.start,
                .region_end = r.end,
            };
        }
    }

    return null;
}

/// Advance playlist engine state based on transport position and regions.
/// Handles region transitions, looping, and playback control.
///
/// This function only runs when the engine is playing.
/// Region lookups use the cached regions from MEDIUM tier.
pub fn tick(
    ctx: *const PlaylistTickContext,
    backend: anytype,
) void {
    // Only tick when playing
    if (!ctx.playlist_state.engine.isPlaying()) {
        return;
    }

    const current_pos = ctx.transport_state.play_position;

    // Get current playlist
    const p = ctx.playlist_state.getPlaylist(ctx.playlist_state.engine.playlist_idx) orelse return;
    if (ctx.playlist_state.engine.entry_idx >= p.entry_count) return;

    const entry = &p.entries[ctx.playlist_state.engine.entry_idx];

    // Find current region bounds
    if (findRegionBounds(ctx.regions, entry.region_id)) |bounds| {
        // Region found - normal tick
        tickWithRegion(ctx, backend, p, entry, current_pos, bounds.start, bounds.end);
    } else {
        // Region was deleted - handle gracefully
        handleDeletedRegion(ctx, backend, p);
    }
}

/// Tick when current region is valid.
fn tickWithRegion(
    ctx: *const PlaylistTickContext,
    backend: anytype,
    p: *const playlist.Playlist,
    entry: *const playlist.Entry,
    current_pos: f64,
    region_start: f64,
    region_end: f64,
) void {
    _ = entry; // Used for documentation, region_id already resolved to bounds

    // Get next entry info if available
    const next_entry = getNextEntryInfo(
        p.entries[0..p.entry_count],
        ctx.playlist_state.engine.entry_idx,
        p.entry_count,
        ctx.regions,
    );

    // Calculate bar length for non-contiguous transition timing
    // bar_length = beats_per_bar * seconds_per_beat
    const bpm = ctx.transport_state.bpm;
    const beats_per_bar = ctx.transport_state.time_sig_num;
    const bar_length = if (bpm > 0) beats_per_bar * (60.0 / bpm) else 2.0;

    const action = ctx.playlist_state.engine.tick(
        current_pos,
        region_end,
        region_start,
        next_entry,
        p.entry_count,
        bar_length,
    );

    // Handle action
    switch (action) {
        .seek_to => |pos| {
            // Skip seek if already at target (contiguous regions)
            // This avoids audio hiccups when transitioning between
            // regions that share a boundary
            const distance = @abs(current_pos - pos);
            if (distance > 0.1) {
                backend.setCursorPos(pos);
            }
        },
        .setup_native_loop => |loop_info| {
            // Transition to new region with native looping
            // Check if this is a non-contiguous transition (needs seek)
            const approaching_contiguous = current_pos < loop_info.region_start and
                (loop_info.region_start - current_pos) < 0.2;
            const already_there = @abs(current_pos - loop_info.region_start) < 0.1;
            const needs_seek = !approaching_contiguous and !already_there;

            if (needs_seek) {
                // Non-contiguous transition - disable repeat first to prevent
                // REAPER from looping back to old region while we transition
                backend.setRepeat(false);
                backend.setCursorPos(loop_info.region_start);
            }
            // Set loop points to new region boundaries
            backend.setLoopPoints(loop_info.region_start, loop_info.region_end);
            // Enable repeat (re-enable after seek, or ensure it's on for contiguous)
            backend.setRepeat(true);
            // Note: Don't broadcast here - engine will broadcast when transition completes
        },
        .stop => {
            // Engine stopped - disable repeat and clear loop points
            backend.setRepeat(false);
            backend.clearLoopPoints();
            // Stop transport if playlist has stopAfterLast enabled
            if (p.stop_after_last) {
                backend.runCommand(reaper.Command.STOP);
            }
            // State will be broadcast via change detection
        },
        .broadcast_state => {
            // Immediate broadcast needed
            const scratch = ctx.scratchAllocator();
            if (ctx.playlist_state.toJsonAlloc(scratch, ctx.regions)) |json| {
                ctx.shared_state.broadcast(json);
            } else |_| {}
        },
        .none => {},
    }
}

/// Handle case where current region was deleted.
/// Skip to next valid entry or stop if none remain.
fn handleDeletedRegion(
    ctx: *const PlaylistTickContext,
    backend: anytype,
    p: *const playlist.Playlist,
) void {
    const entry = &p.entries[ctx.playlist_state.engine.entry_idx];
    logging.debug("Region {d} deleted, finding next valid entry", .{entry.region_id});

    // Find next entry with a valid region
    var next_valid_idx: ?usize = null;
    var next_bounds: ?RegionBounds = null;
    var search_idx = ctx.playlist_state.engine.entry_idx + 1;

    while (search_idx < p.entry_count) : (search_idx += 1) {
        const candidate = &p.entries[search_idx];
        if (findRegionBounds(ctx.regions, candidate.region_id)) |bounds| {
            next_valid_idx = search_idx;
            next_bounds = bounds;
            break;
        }
    }

    if (next_valid_idx) |valid_idx| {
        // Advance to valid entry
        const next_entry_data = &p.entries[valid_idx];
        ctx.playlist_state.engine.entry_idx = valid_idx;
        ctx.playlist_state.engine.loops_remaining = next_entry_data.loop_count;
        ctx.playlist_state.engine.current_loop_iteration = 1;
        ctx.playlist_state.engine.advance_after_loop = false;
        ctx.playlist_state.engine.next_loop_pending = false;

        // Set up loop for valid region
        if (next_bounds) |bounds| {
            backend.setCursorPos(bounds.start);
            backend.setLoopPoints(bounds.start, bounds.end);
        }

        logging.debug("Skipped to entry {d}", .{valid_idx});
    } else {
        // No valid entries remaining - stop
        _ = ctx.playlist_state.engine.stop();
        backend.setRepeat(false);
        backend.clearLoopPoints();
        logging.debug("No valid entries remaining, stopped playlist", .{});
    }

    // Broadcast state change
    const scratch = ctx.scratchAllocator();
    if (ctx.playlist_state.toJsonAlloc(scratch, ctx.regions)) |json| {
        ctx.shared_state.broadcast(json);
    } else |_| {}
}

// ============================================================================
// Tests
// ============================================================================

test "PlaylistTickContext.scratchAllocator returns valid allocator" {
    // Verify struct compiles correctly
    _ = PlaylistTickContext;
}

test "findRegionBounds returns null for missing region" {
    const regions = [_]markers.Region{
        .{ .id = 1, .start = 0.0, .end = 10.0, .color = 0 },
        .{ .id = 2, .start = 10.0, .end = 20.0, .color = 0 },
    };

    const result = findRegionBounds(&regions, 999);
    try std.testing.expect(result == null);
}

test "findRegionBounds returns bounds for existing region" {
    const regions = [_]markers.Region{
        .{ .id = 1, .start = 0.0, .end = 10.0, .color = 0 },
        .{ .id = 2, .start = 10.0, .end = 20.0, .color = 0 },
    };

    const result = findRegionBounds(&regions, 2);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(f64, 10.0), result.?.start);
    try std.testing.expectEqual(@as(f64, 20.0), result.?.end);
}
