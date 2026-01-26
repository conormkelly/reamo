//! Client Management Module
//!
//! Extracted from main.zig doProcessing() to enable unit testing of
//! client lifecycle behaviors in isolation.
//!
//! This module handles three key client lifecycle events:
//! 1. Disconnected client cleanup - removes subscriptions and flushes gestures
//! 2. Gesture timeout handling - safety net for missed gesture/end commands
//! 3. Snapshot sending - sends full state to newly connected clients
//!
//! All operations are designed to be called every frame (30Hz) but only
//! do work when there are relevant events to process.

const std = @import("std");
const reaper = @import("reaper.zig");
const logging = @import("logging.zig");
const ws_server = @import("ws_server.zig");
const gesture_state = @import("gesture_state.zig");
const tiered_state = @import("tiered_state.zig");

// State types for snapshots
const transport = @import("transport.zig");
const project = @import("project.zig");
const markers = @import("markers.zig");
const items = @import("items.zig");
const tracks = @import("tracks.zig");
const tempomap = @import("tempomap.zig");
const track_skeleton = @import("track_skeleton.zig");
const playlist = @import("playlist.zig");

// Subscription types for cleanup
const toggle_subscriptions = @import("toggle_subscriptions.zig");
const project_notes = @import("project_notes.zig");
const track_subscriptions = @import("track_subscriptions.zig");
const peaks_subscriptions = @import("peaks_subscriptions.zig");
const routing_subscriptions = @import("routing_subscriptions.zig");
const trackfx_subscriptions = @import("trackfx_subscriptions.zig");
const trackfxparam_subscriptions = @import("trackfxparam_subscriptions.zig");

// ============================================================================
// Static Buffers (to avoid stack overflow in deep call stacks)
// ============================================================================

/// Static buffers for client management to avoid stack allocation.
/// These are sized to handle realistic client counts.
const Buffers = struct {
    /// Buffer for disconnected client IDs
    var disconnected: [16]usize = undefined;
    /// Buffer for flushed gesture control IDs
    var flush: [16]gesture_state.ControlId = undefined;
    /// Buffer for timed-out gesture control IDs
    var timeout: [16]gesture_state.ControlId = undefined;
    /// Buffer for clients needing snapshots
    var snapshot_clients: [16]usize = undefined;

    // Snapshot state buffers (for pollInto to avoid large stack allocations)
    var snap_transport: transport.State = .{};
    var snap_project: project.State = .{};
    var snap_markers: markers.State = .{};
    var snap_tempomap: tempomap.State = .{};

    // Static backing buffers for snapshot pollInto (slice-based states)
    var snap_markers_buf: [markers.MAX_MARKERS]markers.Marker = undefined;
    var snap_regions_buf: [markers.MAX_REGIONS]markers.Region = undefined;
};

// ============================================================================
// Context Types
// ============================================================================

/// Context for client management operations.
/// Contains references to all subscription systems and shared state.
pub const ClientContext = struct {
    /// REAPER API reference
    api: *const reaper.Api,
    /// WebSocket shared state for client management
    shared_state: *ws_server.SharedState,
    /// Gesture state for undo coalescing (optional)
    gestures: ?*gesture_state.GestureState,
    /// Toggle subscriptions (optional)
    toggle_subs: ?*toggle_subscriptions.ToggleSubscriptions,
    /// Notes subscriptions (optional)
    notes_subs: ?*project_notes.NotesSubscriptions,
    /// Track subscriptions (optional)
    track_subs: ?*track_subscriptions.TrackSubscriptions,
    /// Peaks subscriptions (optional)
    peaks_subs: ?*peaks_subscriptions.PeaksSubscriptions,
    /// Routing subscriptions (optional)
    routing_subs: ?*routing_subscriptions.RoutingSubscriptions,
    /// TrackFx subscriptions (optional)
    trackfx_subs: ?*trackfx_subscriptions.TrackFxSubscriptions,
    /// TrackFxParam subscriptions (optional)
    trackfxparam_subs: ?*trackfxparam_subscriptions.TrackFxParamSubscriptions,
};

/// Context for sending snapshots to newly connected clients.
/// Separate from ClientContext to keep snapshot-specific state isolated.
pub const SnapshotContext = struct {
    /// WebSocket shared state for sending to clients
    shared_state: *ws_server.SharedState,
    /// REAPER API backend for state polling
    backend: *reaper.RealBackend,
    /// Tiered arenas for scratch allocation
    tiered: *tiered_state.TieredArenas,
    /// Current playlist state for snapshot
    playlist_state: *const playlist.State,
    /// Cached regions for playlist serialization
    last_markers_regions: []const markers.Region,

    /// Create a scratch allocator from the tiered arenas
    pub fn scratchAllocator(self: *const SnapshotContext) std.mem.Allocator {
        return self.tiered.scratchAllocator();
    }
};

// ============================================================================
// Client Cleanup
// ============================================================================

/// Clean up all subscriptions and gestures for disconnected clients.
/// Called every frame to handle clients that have disconnected.
///
/// This function:
/// 1. Pops disconnected client IDs from shared state
/// 2. Flushes any active gestures for those clients (with proper undo handling)
/// 3. Removes clients from all subscription systems
pub fn cleanupDisconnectedClients(ctx: *const ClientContext) void {
    // Pop disconnected client IDs from shared state
    const disconnected_count = ctx.shared_state.popDisconnectedClients(&Buffers.disconnected);
    if (disconnected_count == 0) {
        return;
    }

    for (Buffers.disconnected[0..disconnected_count]) |client_id| {
        // Clean up gestures
        if (ctx.gestures) |gestures| {
            const flush_count = gestures.removeClientFromAll(client_id, &Buffers.flush);
            if (flush_count > 0) {
                logging.info("Client {d} disconnected, flushing {d} gestures", .{ client_id, flush_count });
                handleFlushedGestures(ctx, gestures, Buffers.flush[0..flush_count], "client disconnect");
            }
        }

        // Clean up all subscription types
        if (ctx.toggle_subs) |subs| subs.removeClient(client_id);
        if (ctx.notes_subs) |subs| subs.removeClient(client_id);
        if (ctx.track_subs) |subs| subs.removeClient(client_id);
        if (ctx.peaks_subs) |subs| subs.removeClient(client_id);
        if (ctx.routing_subs) |subs| subs.removeClient(client_id);
        if (ctx.trackfx_subs) |subs| subs.removeClient(client_id);
        if (ctx.trackfxparam_subs) |subs| subs.removeClient(client_id);
    }
}

// ============================================================================
// Gesture Timeout Handling
// ============================================================================

/// Check for gesture timeouts and flush expired gestures.
/// Safety net for missed gesture/end commands from clients.
///
/// Gestures time out after a configurable period (default 5 seconds).
/// This prevents orphaned undo blocks from accumulating.
pub fn checkGestureTimeouts(ctx: *const ClientContext) void {
    const gestures = ctx.gestures orelse return;

    const timeout_count = gestures.checkTimeouts(&Buffers.timeout);
    if (timeout_count == 0) {
        return;
    }

    logging.info("Flushing {d} timed-out gestures", .{timeout_count});
    handleFlushedGestures(ctx, gestures, Buffers.timeout[0..timeout_count], "gesture timeout");
}

/// Handle flushed gestures by closing undo blocks appropriately.
/// Shared logic between disconnect cleanup and timeout handling.
fn handleFlushedGestures(
    ctx: *const ClientContext,
    gestures: *gesture_state.GestureState,
    flushed_controls: []const gesture_state.ControlId,
    reason: []const u8,
) void {
    var had_csurf_gesture = false;

    for (flushed_controls) |control| {
        if (gesture_state.GestureState.isHwOutputControl(control.control_type)) {
            // Hardware output control - uses separate undo block tracking
            if (gestures.endHwUndoBlock()) {
                logging.info("Closing HW undo block ({s})", .{reason});
                ctx.api.undoEndBlock("REAmo: Adjust audio hardware outputs");
            }
        } else {
            had_csurf_gesture = true;
        }
    }

    // Flush CSurf undo for non-hw gestures
    if (had_csurf_gesture) {
        ctx.api.csurfFlushUndo(true);
    }
}

// ============================================================================
// Snapshot Sending
// ============================================================================

/// Send initial state snapshot to newly connected clients.
/// Includes transport, project, markers, regions, items, skeleton, tempomap, playlist.
///
/// This ensures new clients immediately have the current project state
/// without waiting for change detection to trigger broadcasts.
pub fn sendSnapshotsToNewClients(ctx: *const SnapshotContext) void {
    // Pop clients needing snapshots
    const snapshot_count = ctx.shared_state.popClientsNeedingSnapshot(&Buffers.snapshot_clients);
    if (snapshot_count == 0) {
        return;
    }

    // Poll current state for all domains (use static buffers to avoid stack overflow)
    Buffers.snap_transport = transport.State.poll(ctx.backend);
    Buffers.snap_project = project.State.poll(ctx.backend);
    Buffers.snap_markers.pollInto(&Buffers.snap_markers_buf, &Buffers.snap_regions_buf, ctx.backend);
    Buffers.snap_tempomap = tempomap.State.poll(ctx.backend);

    // Poll track skeleton and items using scratch allocator
    const scratch = ctx.scratchAllocator();
    const snap_skeleton = track_skeleton.State.poll(scratch, ctx.backend) catch null;
    const snap_items = items.State.poll(scratch, ctx.backend) catch null;

    // Send snapshot to each new client
    for (Buffers.snapshot_clients[0..snapshot_count]) |client_id| {
        sendSnapshotToClient(ctx, client_id, snap_skeleton, snap_items, scratch);
    }
}

/// Send complete state snapshot to a single client.
fn sendSnapshotToClient(
    ctx: *const SnapshotContext,
    client_id: usize,
    snap_skeleton: ?track_skeleton.State,
    snap_items: ?items.State,
    scratch: std.mem.Allocator,
) void {
    // Transport
    if (Buffers.snap_transport.toJsonAlloc(scratch)) |json| {
        ctx.shared_state.sendToClient(client_id, json);
    } else |_| {}

    // Project (undo/redo state)
    if (Buffers.snap_project.toJsonAlloc(scratch)) |json| {
        ctx.shared_state.sendToClient(client_id, json);
    } else |_| {}

    // Markers (broadcast - no subscription required)
    if (Buffers.snap_markers.markersToJsonAlloc(scratch)) |json| {
        ctx.shared_state.sendToClient(client_id, json);
    } else |_| {}

    // Regions (broadcast - no subscription required)
    if (Buffers.snap_markers.regionsToJsonAlloc(scratch)) |json| {
        ctx.shared_state.sendToClient(client_id, json);
    } else |_| {}

    // Items (broadcast - no subscription required)
    if (snap_items) |item_state| {
        if (item_state.itemsToJsonAlloc(scratch)) |json| {
            ctx.shared_state.sendToClient(client_id, json);
        } else |_| {}
    }

    // Track skeleton (client must subscribe to receive full track data)
    if (snap_skeleton) |skeleton| {
        if (skeleton.toJsonAlloc(scratch)) |json| {
            ctx.shared_state.sendToClient(client_id, json);
        } else |_| {}
    }

    // Tempo map
    if (Buffers.snap_tempomap.toJsonAlloc(scratch)) |json| {
        ctx.shared_state.sendToClient(client_id, json);
    } else |_| {}

    // Playlist (cue list) - uses last_markers_regions for region resolution
    if (ctx.playlist_state.toJsonAlloc(scratch, ctx.last_markers_regions)) |json| {
        ctx.shared_state.sendToClient(client_id, json);
    } else |_| {}
}

// ============================================================================
// Tests
// ============================================================================

test "ClientContext compiles" {
    // Verify struct compiles correctly
    _ = ClientContext;
}

test "SnapshotContext compiles" {
    // Verify struct compiles correctly
    _ = SnapshotContext;
}

test "Buffers are correctly sized" {
    // Verify buffer sizes are reasonable
    try std.testing.expect(Buffers.disconnected.len >= 16);
    try std.testing.expect(Buffers.flush.len >= 16);
    try std.testing.expect(Buffers.timeout.len >= 16);
    try std.testing.expect(Buffers.snapshot_clients.len >= 16);
}
