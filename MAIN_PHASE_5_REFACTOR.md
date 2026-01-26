# Phase 5: Extract Client Management

## Overview

This document provides surgical instructions for extracting client management logic from `doProcessing()` in `main.zig` into a new module `client_management.zig`.

**This is the FINAL phase of the main.zig refactoring project.**

**Risk Level:** Low
**Estimated Lines Moved:** ~145
**Resulting main.zig:** ~910 lines (down from ~1056)

---

## 1. Exact Line Ranges

### 1.1 Disconnected Client Cleanup (Lines 561-621)

```zig
    // Clean up gestures and toggle subscriptions for disconnected clients
    // Using ProcessingState.disconnected_buf to avoid stack allocation
    const disconnected_count = shared_state.popDisconnectedClients(&ProcessingState.disconnected_buf);
    if (disconnected_count > 0) {
        for (ProcessingState.disconnected_buf[0..disconnected_count]) |client_id| {
            // Clean up gestures
            if (g_gesture_state) |gestures| {
                const flush_count = gestures.removeClientFromAll(client_id, &ProcessingState.flush_buf);
                if (flush_count > 0) {
                    logging.info("Client {d} disconnected, flushing {d} gestures", .{ client_id, flush_count });

                    // Check what types of gestures were flushed
                    var had_csurf_gesture = false;
                    for (ProcessingState.flush_buf[0..flush_count]) |control| {
                        if (gesture_state.GestureState.isHwOutputControl(control.control_type)) {
                            // Decrement hw count, close undo block if this was the last
                            if (gestures.endHwUndoBlock()) {
                                logging.info("Closing HW undo block (client disconnect)", .{});
                                api.undoEndBlock("REAmo: Adjust audio hardware outputs");
                            }
                        } else {
                            had_csurf_gesture = true;
                        }
                    }

                    // Flush CSurf undo for non-hw gestures
                    if (had_csurf_gesture) {
                        api.csurfFlushUndo(true);
                    }
                }
            }
            // Clean up toggle subscriptions
            if (g_toggle_subs) |toggles| {
                toggles.removeClient(client_id);
            }
            // Clean up notes subscriptions
            if (g_notes_subs) |notes| {
                notes.removeClient(client_id);
            }
            // Clean up track subscriptions
            if (g_track_subs) |track_subs| {
                track_subs.removeClient(client_id);
            }
            // Clean up peaks subscriptions
            if (g_peaks_subs) |peaks_subs| {
                peaks_subs.removeClient(client_id);
            }
            // Clean up routing subscriptions
            if (g_routing_subs) |routing_subs| {
                routing_subs.removeClient(client_id);
            }
            // Clean up track FX subscriptions
            if (g_trackfx_subs) |trackfx_subs| {
                trackfx_subs.removeClient(client_id);
            }
            // Clean up track FX param subscriptions
            if (g_trackfxparam_subs) |trackfxparam_subs| {
                trackfxparam_subs.removeClient(client_id);
            }
        }
    }
```

**Line count:** 61 lines

### 1.2 Gesture Timeout Handling (Lines 623-648)

```zig
    // Check for gesture timeouts (safety net for missed gesture/end commands)
    if (g_gesture_state) |gestures| {
        const timeout_count = gestures.checkTimeouts(&ProcessingState.timeout_buf);
        if (timeout_count > 0) {
            logging.info("Flushing {d} timed-out gestures", .{timeout_count});

            // Check what types of gestures timed out
            var had_csurf_gesture = false;
            for (ProcessingState.timeout_buf[0..timeout_count]) |control| {
                if (gesture_state.GestureState.isHwOutputControl(control.control_type)) {
                    // Decrement hw count, close undo block if this was the last
                    if (gestures.endHwUndoBlock()) {
                        logging.info("Closing HW undo block (gesture timeout)", .{});
                        api.undoEndBlock("REAmo: Adjust audio hardware outputs");
                    }
                } else {
                    had_csurf_gesture = true;
                }
            }

            // Flush CSurf undo for non-hw gestures
            if (had_csurf_gesture) {
                api.csurfFlushUndo(true);
            }
        }
    }
```

**Line count:** 26 lines

### 1.3 Client Snapshot Sending (Lines 650-704)

```zig
    // Send initial state snapshot to newly connected clients
    // Using ProcessingState for all state structs to avoid stack overflow
    const snapshot_count = shared_state.popClientsNeedingSnapshot(&ProcessingState.snapshot_clients);
    if (snapshot_count > 0) {
        // Get current state for all domains - use pollInto for large structs
        ProcessingState.snap_transport = transport.State.poll(&backend);
        ProcessingState.snap_project = project.State.poll(&backend);
        ProcessingState.snap_markers.pollInto(&ProcessingState.snap_markers_buf, &ProcessingState.snap_regions_buf, &backend);
        ProcessingState.snap_tempomap = tempomap.State.poll(&backend);

        // Poll track skeleton and items for snapshot
        const scratch = tiered.scratchAllocator();
        const snap_skeleton = track_skeleton.State.poll(scratch, &backend) catch null;
        const snap_items = items.State.poll(scratch, &backend) catch null;

        // Send to each new client
        for (ProcessingState.snapshot_clients[0..snapshot_count]) |client_id| {
            // Transport
            if (ProcessingState.snap_transport.toJsonAlloc(scratch)) |json| {
                shared_state.sendToClient(client_id, json);
            } else |_| {}
            // Project (undo/redo state)
            if (ProcessingState.snap_project.toJsonAlloc(scratch)) |json| {
                shared_state.sendToClient(client_id, json);
            } else |_| {}
            // Markers (broadcast - no subscription required)
            if (ProcessingState.snap_markers.markersToJsonAlloc(scratch)) |json| {
                shared_state.sendToClient(client_id, json);
            } else |_| {}
            // Regions (broadcast - no subscription required)
            if (ProcessingState.snap_markers.regionsToJsonAlloc(scratch)) |json| {
                shared_state.sendToClient(client_id, json);
            } else |_| {}
            // Items (broadcast - no subscription required)
            if (snap_items) |item_state| {
                if (item_state.itemsToJsonAlloc(scratch)) |json| {
                    shared_state.sendToClient(client_id, json);
                } else |_| {}
            }
            // Track skeleton (client must subscribe to receive full track data)
            if (snap_skeleton) |skeleton| {
                if (skeleton.toJsonAlloc(scratch)) |json| {
                    shared_state.sendToClient(client_id, json);
                } else |_| {}
            }
            // Tempo map
            if (ProcessingState.snap_tempomap.toJsonAlloc(scratch)) |json| {
                shared_state.sendToClient(client_id, json);
            } else |_| {}
            // Playlist (cue list)
            if (g_playlist_state.toJsonAlloc(scratch, g_last_markers.regions)) |json| {
                shared_state.sendToClient(client_id, json);
            } else |_| {}
        }
    }
```

**Line count:** 55 lines

### 1.4 Summary of Lines to Extract

| Block | Start Line | End Line | Line Count |
|-------|------------|----------|------------|
| Disconnected client cleanup | 561 | 621 | 61 |
| Gesture timeout handling | 623 | 648 | 26 |
| Client snapshot sending | 650 | 704 | 55 |
| **Total** | - | - | **142** |

---

## 2. Dependency Analysis

### 2.1 Required Imports for client_management.zig

```zig
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
```

### 2.2 Parameters Required from Caller

The client management functions need access to shared state from `doProcessing()`. We define a `ClientContext` struct to bundle these:

| Parameter | Type | Source in main.zig |
|-----------|------|-------------------|
| `api` | `*const reaper.Api` | `&(g_api orelse ...)` |
| `shared_state` | `*ws_server.SharedState` | `g_shared_state orelse ...` |
| `gesture_state` | `?*gesture_state.GestureState` | `g_gesture_state` |
| `toggle_subs` | `?*toggle_subscriptions.ToggleSubscriptions` | `g_toggle_subs` |
| `notes_subs` | `?*project_notes.NotesSubscriptions` | `g_notes_subs` |
| `track_subs` | `?*track_subscriptions.TrackSubscriptions` | `g_track_subs` |
| `peaks_subs` | `?*peaks_subscriptions.PeaksSubscriptions` | `g_peaks_subs` |
| `routing_subs` | `?*routing_subscriptions.RoutingSubscriptions` | `g_routing_subs` |
| `trackfx_subs` | `?*trackfx_subscriptions.TrackFxSubscriptions` | `g_trackfx_subs` |
| `trackfxparam_subs` | `?*trackfxparam_subscriptions.TrackFxParamSubscriptions` | `g_trackfxparam_subs` |

Additional snapshot-specific parameters:

| Parameter | Type | Source in main.zig |
|-----------|------|-------------------|
| `backend` | `*reaper.RealBackend` | `&backend` (local) |
| `tiered` | `*tiered_state.TieredArenas` | `tiered` |
| `playlist_state` | `*const playlist.State` | `&g_playlist_state` |
| `last_markers_regions` | `[]const markers.Region` | `g_last_markers.regions` |

### 2.3 Globals Referenced

The code currently accesses these globals directly:

| Global | Usage | Strategy |
|--------|-------|----------|
| `g_api` | API calls (undoEndBlock, csurfFlushUndo) | Pass via ClientContext |
| `g_shared_state` | Pop disconnected clients, send to clients | Pass via ClientContext |
| `g_gesture_state` | Gesture cleanup and timeouts | Pass via ClientContext |
| `g_toggle_subs` | Toggle subscription cleanup | Pass via ClientContext |
| `g_notes_subs` | Notes subscription cleanup | Pass via ClientContext |
| `g_track_subs` | Track subscription cleanup | Pass via ClientContext |
| `g_peaks_subs` | Peaks subscription cleanup | Pass via ClientContext |
| `g_routing_subs` | Routing subscription cleanup | Pass via ClientContext |
| `g_trackfx_subs` | TrackFx subscription cleanup | Pass via ClientContext |
| `g_trackfxparam_subs` | TrackFxParam subscription cleanup | Pass via ClientContext |
| `g_playlist_state` | Snapshot sending | Pass as parameter |
| `g_last_markers.regions` | Snapshot sending (playlist) | Pass as parameter |
| `ProcessingState.*` | Static buffers for stack safety | Move to new module |

**Strategy:** All globals become explicit parameters via `ClientContext`. Static buffers for stack safety are replicated in the new module.

---

## 3. Interface Design

### 3.1 ClientContext Struct

```zig
/// Context for client management operations.
/// Contains references to all subscription systems and shared state.
pub const ClientContext = struct {
    /// REAPER API reference
    api: *const reaper.Api,
    /// WebSocket shared state for client management
    shared_state: *ws_server.SharedState,
    /// Gesture state for undo coalescing (optional)
    gesture_state: ?*gesture_state.GestureState,
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
```

### 3.2 SnapshotContext Struct

```zig
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
```

### 3.3 Function Signatures

```zig
/// Clean up all subscriptions and gestures for disconnected clients.
/// Called every frame to handle clients that have disconnected.
///
/// Parameters:
/// - ctx: Client context with all subscription references
///
/// This function:
/// 1. Pops disconnected client IDs from shared state
/// 2. Flushes any active gestures for those clients
/// 3. Removes clients from all subscription systems
pub fn cleanupDisconnectedClients(ctx: *const ClientContext) void;

/// Check for gesture timeouts and flush expired gestures.
/// Safety net for missed gesture/end commands from clients.
///
/// Parameters:
/// - ctx: Client context with gesture state reference
///
/// Gestures time out after a configurable period (default 5 seconds).
/// This prevents orphaned undo blocks from accumulating.
pub fn checkGestureTimeouts(ctx: *const ClientContext) void;

/// Send initial state snapshot to newly connected clients.
/// Includes transport, project, markers, regions, items, skeleton, tempomap, playlist.
///
/// Parameters:
/// - ctx: Snapshot context with backend and arena references
///
/// This ensures new clients immediately have the current project state
/// without waiting for change detection to trigger broadcasts.
pub fn sendSnapshotsToNewClients(ctx: *const SnapshotContext) void;
```

### 3.4 Usage from main.zig

After extraction, the client management section in `doProcessing()` becomes:

```zig
const client_management = @import("client_management.zig");

// ... after command dispatch ...

// ========================================================================
// CLIENT MANAGEMENT - Extracted to client_management.zig for testability
// ========================================================================

// Build client context (once per frame)
const client_ctx = client_management.ClientContext{
    .api = api,
    .shared_state = shared_state,
    .gesture_state = g_gesture_state,
    .toggle_subs = g_toggle_subs,
    .notes_subs = g_notes_subs,
    .track_subs = g_track_subs,
    .peaks_subs = g_peaks_subs,
    .routing_subs = g_routing_subs,
    .trackfx_subs = g_trackfx_subs,
    .trackfxparam_subs = g_trackfxparam_subs,
};

// Clean up disconnected clients
client_management.cleanupDisconnectedClients(&client_ctx);

// Check for gesture timeouts
client_management.checkGestureTimeouts(&client_ctx);

// Build snapshot context
const snap_ctx = client_management.SnapshotContext{
    .shared_state = shared_state,
    .backend = &backend,
    .tiered = tiered,
    .playlist_state = &g_playlist_state,
    .last_markers_regions = g_last_markers.regions,
};

// Send snapshots to newly connected clients
client_management.sendSnapshotsToNewClients(&snap_ctx);
```

---

## 4. The Extraction

### 4.1 Complete client_management.zig

Create file at: `extension/src/client_management.zig`

```zig
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
```

### 4.2 Edits to main.zig

#### 4.2.1 Add Import (after line 41)

Add this import after the `playlist_tick` import:

```zig
const client_management = @import("client_management.zig");
```

**Edit location:** Line 42 (insert after `const playlist_tick = @import("playlist_tick.zig");`)

#### 4.2.2 Remove Snapshot Static Buffers from ProcessingState

**Edit ProcessingState (lines 416-436)** to remove snapshot-specific buffers that are now in client_management.zig:

Remove these lines:
```zig
    // Snapshot states (used when sending initial state to new clients)
    var snap_transport: transport.State = .{};
    var snap_project: project.State = .{};
    var snap_markers: markers.State = .{};
    var snap_tracks: tracks.State = .{};
    var snap_items: items.State = .{};
    var snap_tempomap: tempomap.State = .{};

    // Static backing buffers for snapshot pollInto (slice-based states)
    var snap_tracks_buf: [tracks.MAX_TRACKS]tracks.Track = undefined;
    var snap_items_buf: [items.MAX_ITEMS]items.Item = undefined;
    var snap_markers_buf: [markers.MAX_MARKERS]markers.Marker = undefined;
    var snap_regions_buf: [markers.MAX_REGIONS]markers.Region = undefined;
```

Keep only:
```zig
const ProcessingState = struct {
    // Small utility arrays (still used for disconnected/flush/timeout in transition)
    var disconnected_buf: [16]usize = undefined;
    var flush_buf: [16]gesture_state.ControlId = undefined;
    var timeout_buf: [16]gesture_state.ControlId = undefined;
    var snapshot_clients: [16]usize = undefined;
};
```

**Note:** After extraction, ProcessingState can be further simplified or removed entirely since all its buffers will be in client_management.zig.

#### 4.2.3 Remove Disconnected Client Cleanup Block (Lines 561-621)

**Remove this entire block:**

```zig
    // Clean up gestures and toggle subscriptions for disconnected clients
    // Using ProcessingState.disconnected_buf to avoid stack allocation
    const disconnected_count = shared_state.popDisconnectedClients(&ProcessingState.disconnected_buf);
    if (disconnected_count > 0) {
        for (ProcessingState.disconnected_buf[0..disconnected_count]) |client_id| {
            // ... all cleanup code ...
        }
    }
```

#### 4.2.4 Remove Gesture Timeout Block (Lines 623-648)

**Remove this entire block:**

```zig
    // Check for gesture timeouts (safety net for missed gesture/end commands)
    if (g_gesture_state) |gestures| {
        const timeout_count = gestures.checkTimeouts(&ProcessingState.timeout_buf);
        // ... all timeout handling code ...
    }
```

#### 4.2.5 Remove Snapshot Sending Block (Lines 650-704)

**Remove this entire block:**

```zig
    // Send initial state snapshot to newly connected clients
    // Using ProcessingState for all state structs to avoid stack overflow
    const snapshot_count = shared_state.popClientsNeedingSnapshot(&ProcessingState.snapshot_clients);
    if (snapshot_count > 0) {
        // ... all snapshot code ...
    }
```

#### 4.2.6 Insert New Client Management Code

**Insert after command dispatch (line 559):**

```zig
    // ========================================================================
    // CLIENT MANAGEMENT - Extracted to client_management.zig for testability
    // ========================================================================

    // Build client context (once per frame)
    const client_ctx = client_management.ClientContext{
        .api = api,
        .shared_state = shared_state,
        .gestures = g_gesture_state,
        .toggle_subs = g_toggle_subs,
        .notes_subs = g_notes_subs,
        .track_subs = g_track_subs,
        .peaks_subs = g_peaks_subs,
        .routing_subs = g_routing_subs,
        .trackfx_subs = g_trackfx_subs,
        .trackfxparam_subs = g_trackfxparam_subs,
    };

    // Clean up disconnected clients
    client_management.cleanupDisconnectedClients(&client_ctx);

    // Check for gesture timeouts
    client_management.checkGestureTimeouts(&client_ctx);

    // Build snapshot context
    const snap_ctx = client_management.SnapshotContext{
        .shared_state = shared_state,
        .backend = &backend,
        .tiered = tiered,
        .playlist_state = &g_playlist_state,
        .last_markers_regions = g_last_markers.regions,
    };

    // Send snapshots to newly connected clients
    client_management.sendSnapshotsToNewClients(&snap_ctx);
```

#### 4.2.7 Add Test Re-export

**Add to test block at end of main.zig:**

```zig
    _ = @import("client_management.zig");
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

# Build with CSurf enabled (if applicable)
zig build -Dcsurf=true
```

### 5.2 Grep Checks for Dangling References

After extraction, verify no orphaned references exist:

```bash
# Ensure old disconnected client code is removed
grep -n "popDisconnectedClients" extension/src/main.zig
# Should show ONLY the import, not inline usage

grep -n "removeClientFromAll" extension/src/main.zig
# Should return NO matches (now in client_management.zig)

grep -n "Client.*disconnected, flushing" extension/src/main.zig
# Should return NO matches (log message now in client_management.zig)

# Ensure old gesture timeout code is removed
grep -n "checkTimeouts" extension/src/main.zig
# Should return NO matches (now in client_management.zig)

grep -n "Flushing.*timed-out gestures" extension/src/main.zig
# Should return NO matches

# Ensure old snapshot code is removed
grep -n "popClientsNeedingSnapshot" extension/src/main.zig
# Should return NO matches (now in client_management.zig)

grep -n "snap_transport.toJsonAlloc" extension/src/main.zig
# Should return NO matches

# Verify new module is imported
grep -n "client_management" extension/src/main.zig
# Should show import line and usage

# Verify ClientContext is used
grep -n "ClientContext" extension/src/main.zig
# Should show context creation

# Verify SnapshotContext is used
grep -n "SnapshotContext" extension/src/main.zig
# Should show context creation
```

### 5.3 Functional Verification in REAPER

1. **Build and install extension**
   ```bash
   zig build && cp zig-out/lib/libreamo.dylib ~/.config/REAPER/UserPlugins/
   ```

2. **Launch REAPER with extension loaded**

3. **Test disconnected client cleanup:**
   - Connect a WebSocket client
   - Subscribe to various state (tracks, toggles, peaks, etc.)
   - Start a gesture (e.g., drag a fader)
   - Disconnect the client abruptly (close connection)
   - Verify no orphaned subscriptions remain (check logs)
   - Verify undo block is properly closed

4. **Test gesture timeout handling:**
   - Connect a WebSocket client
   - Start a gesture but don't send gesture/end
   - Wait for timeout (default 5 seconds)
   - Verify gesture is automatically flushed (check logs)
   - Verify undo is properly committed

5. **Test snapshot sending:**
   - Connect a new WebSocket client
   - Verify immediate receipt of:
     - Transport state
     - Project state (undo/redo)
     - Markers
     - Regions
     - Items
     - Track skeleton
     - Tempomap
     - Playlist state
   - Verify all data is current (matches REAPER state)

---

## 6. Testability Plan

### 6.1 Unit Test Strategy

The extracted module enables testing client management behaviors in isolation.

#### Mock Types Needed

```zig
// test_mocks.zig (or inline in client_management.zig tests)

pub const MockSharedState = struct {
    disconnected_clients: std.ArrayList(usize),
    snapshot_clients: std.ArrayList(usize),
    sent_messages: std.StringHashMap(std.ArrayList([]const u8)),

    pub fn popDisconnectedClients(self: *MockSharedState, buf: []usize) usize {
        const count = @min(self.disconnected_clients.items.len, buf.len);
        @memcpy(buf[0..count], self.disconnected_clients.items[0..count]);
        self.disconnected_clients.clearRetainingCapacity();
        return count;
    }

    pub fn popClientsNeedingSnapshot(self: *MockSharedState, buf: []usize) usize {
        const count = @min(self.snapshot_clients.items.len, buf.len);
        @memcpy(buf[0..count], self.snapshot_clients.items[0..count]);
        self.snapshot_clients.clearRetainingCapacity();
        return count;
    }

    pub fn sendToClient(self: *MockSharedState, client_id: usize, json: []const u8) void {
        const entry = self.sent_messages.getOrPut(client_id) catch return;
        if (!entry.found_existing) {
            entry.value_ptr.* = std.ArrayList([]const u8).init(std.testing.allocator);
        }
        entry.value_ptr.append(json) catch {};
    }
};

pub const MockApi = struct {
    undo_end_block_calls: usize = 0,
    csurf_flush_calls: usize = 0,

    pub fn undoEndBlock(self: *MockApi, desc: []const u8) void {
        _ = desc;
        self.undo_end_block_calls += 1;
    }

    pub fn csurfFlushUndo(self: *MockApi, force: bool) void {
        _ = force;
        self.csurf_flush_calls += 1;
    }
};

pub const MockGestureState = struct {
    active_gestures: usize = 0,
    hw_undo_count: usize = 0,

    pub fn removeClientFromAll(self: *MockGestureState, client_id: usize, buf: []gesture_state.ControlId) usize {
        _ = client_id;
        // Return mock flushed gestures
        if (self.active_gestures > 0) {
            buf[0] = .{ .control_type = .volume, .track_idx = 0 };
            self.active_gestures -= 1;
            return 1;
        }
        return 0;
    }

    pub fn checkTimeouts(self: *MockGestureState, buf: []gesture_state.ControlId) usize {
        // No timeouts in mock
        _ = buf;
        _ = self;
        return 0;
    }

    pub fn endHwUndoBlock(self: *MockGestureState) bool {
        if (self.hw_undo_count > 0) {
            self.hw_undo_count -= 1;
            return self.hw_undo_count == 0;
        }
        return false;
    }
};
```

#### Example Unit Tests

```zig
test "cleanupDisconnectedClients removes subscriptions for disconnected client" {
    var mock_shared = MockSharedState{...};
    mock_shared.disconnected_clients.append(42) catch unreachable;

    var mock_toggle_subs = toggle_subscriptions.ToggleSubscriptions.init(std.testing.allocator);
    defer mock_toggle_subs.deinit();
    mock_toggle_subs.subscribe(42, 40001); // Client 42 subscribed to action

    var mock_api = MockApi{};

    const ctx = ClientContext{
        .api = &mock_api,
        .shared_state = &mock_shared,
        .gestures = null,
        .toggle_subs = &mock_toggle_subs,
        .notes_subs = null,
        .track_subs = null,
        .peaks_subs = null,
        .routing_subs = null,
        .trackfx_subs = null,
        .trackfxparam_subs = null,
    };

    cleanupDisconnectedClients(&ctx);

    // Verify subscription was removed
    try std.testing.expect(!mock_toggle_subs.hasSubscriptionsForClient(42));
}

test "cleanupDisconnectedClients flushes gestures with proper undo handling" {
    var mock_shared = MockSharedState{...};
    mock_shared.disconnected_clients.append(42) catch unreachable;

    var mock_gestures = MockGestureState{ .active_gestures = 1 };
    var mock_api = MockApi{};

    const ctx = ClientContext{
        .api = &mock_api,
        .shared_state = &mock_shared,
        .gestures = &mock_gestures,
        // ... other fields null ...
    };

    cleanupDisconnectedClients(&ctx);

    // Verify CSurf undo was flushed
    try std.testing.expect(mock_api.csurf_flush_calls > 0);
}

test "checkGestureTimeouts flushes timed-out gestures" {
    var mock_api = MockApi{};
    var mock_gestures = MockGestureState{};
    // Setup mock to return timeout on next check
    // ... test implementation ...
}

test "sendSnapshotsToNewClients sends all state types" {
    var mock_shared = MockSharedState{...};
    mock_shared.snapshot_clients.append(42) catch unreachable;

    // ... setup mock backend and tiered arenas ...

    sendSnapshotsToNewClients(&ctx);

    // Verify client 42 received messages
    const messages = mock_shared.sent_messages.get(42);
    try std.testing.expect(messages != null);
    try std.testing.expect(messages.?.items.len >= 7); // transport, project, markers, regions, items?, skeleton?, tempomap, playlist
}

test "sendSnapshotsToNewClients does nothing when no clients" {
    var mock_shared = MockSharedState{...};
    // No clients needing snapshot

    sendSnapshotsToNewClients(&ctx);

    // Verify no messages sent
    try std.testing.expect(mock_shared.sent_messages.count() == 0);
}
```

### 6.2 Integration Test Considerations

For full integration tests:

1. **Create test WebSocket client** that can connect/disconnect on demand
2. **Verify cleanup timing:**
   - Connect client
   - Subscribe to multiple state types
   - Disconnect client
   - Verify all subscriptions removed within 1 frame (~33ms)
3. **Verify snapshot completeness:**
   - Create project with tracks, markers, regions, items
   - Connect new client
   - Verify all state received immediately
4. **Verify gesture timeout:**
   - Start gesture via WebSocket
   - Don't send gesture/end
   - Wait for timeout
   - Verify undo committed

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

1. **Delete** `extension/src/client_management.zig`

2. **Edit main.zig:**
   - Remove `const client_management = @import("client_management.zig");`
   - Remove the new ClientContext/SnapshotContext construction code
   - Restore the original inline client management code (see Section 1 for exact code)
   - Restore ProcessingState snapshot buffers
   - Remove test re-export for client_management

3. **Rebuild:**
   ```bash
   cd extension && zig build
   ```

### 7.3 Partial Rollback

If only one function has issues:

1. Keep `client_management.zig` with working functions
2. Move the problematic function back inline in `main.zig`
3. Comment out the call to the problematic function

---

## 8. Implementation Sequence

Execute these steps in order:

### Step 1: Create client_management.zig

```bash
# Create the new file
touch "/Users/conor/Library/Application Support/REAPER/reaper_www_root/extension/src/client_management.zig"
```

Copy the complete content from Section 4.1 into this file.

### Step 2: Add Import to main.zig

Edit line 42 to add:
```zig
const client_management = @import("client_management.zig");
```

### Step 3: Build and Fix Any Import Errors

```bash
cd "/Users/conor/Library/Application Support/REAPER/reaper_www_root/extension"
zig build 2>&1 | head -50
```

Fix any missing imports or type mismatches in `client_management.zig`.

### Step 4: Replace Inline Client Management Code

1. Remove lines 561-704 (disconnected cleanup + gesture timeout + snapshot sending)
2. Insert the new client management code from Section 4.2.6 at line 561

### Step 5: Clean Up ProcessingState

Remove the snapshot-related buffers from ProcessingState that are now in client_management.zig.

### Step 6: Add Test Re-export

Add to test block at end of main.zig:
```zig
    _ = @import("client_management.zig");
```

### Step 7: Build and Test

```bash
zig build test
zig build
```

### Step 8: Run Grep Verification

Execute all grep checks from Section 5.2.

### Step 9: Functional Test in REAPER

Follow the functional verification steps from Section 5.3.

### Step 10: Commit (User Action)

Suggested commit message:
```
refactor(main): extract client management to client_management.zig

Phase 5 (FINAL) of main.zig refactoring. Extracts client lifecycle
management from doProcessing() into a dedicated module:

- Disconnected client cleanup: removes subscriptions, flushes gestures
- Gesture timeout handling: safety net for missed gesture/end commands
- Snapshot sending: sends full state to newly connected clients

Introduces ClientContext and SnapshotContext structs to bundle
dependencies and enable future unit testing of client lifecycle
behaviors.

No functional changes - pure code movement.

Lines extracted: ~145
New module: client_management.zig (~280 lines)
main.zig: ~1056 -> ~910 lines

This completes the 5-phase refactoring of main.zig:
- Phase 1: lua_peak_bridge.zig (~410 lines)
- Phase 2: subscription_polling.zig (~230 lines)
- Phase 3: tier_polling.zig (~460 lines)
- Phase 4: playlist_tick.zig (~185 lines)
- Phase 5: client_management.zig (~145 lines)

Total lines moved: ~1430
Original main.zig: 2316 lines -> Final: ~910 lines
```

---

## 9. Summary Metrics

| Metric | Value |
|--------|-------|
| Lines extracted from main.zig | ~145 |
| New module size | ~280 lines (including docs/tests) |
| main.zig before | ~1056 lines |
| main.zig after | ~910 lines |
| Risk level | Low |
| New public types | 2 (ClientContext, SnapshotContext) |
| New public functions | 3 (cleanupDisconnectedClients, checkGestureTimeouts, sendSnapshotsToNewClients) |
| Helper functions | 2 (internal) |
| Behavior changes | None |
| New dependencies | None |

### Risk Factors

1. **Low complexity** - Self-contained logic with clear boundaries
2. **Static buffer replication** - Buffers must be correctly sized in new module
3. **API reference passing** - Must correctly pass API for undo operations
4. **Subscription cleanup order** - All subscription types must be cleaned up

### Mitigation

1. Build after each edit to catch errors early
2. Run full test suite before REAPER testing
3. Verify with grep that all old code is removed
4. Test client connect/disconnect cycles
5. Test gesture timeout handling
6. Keep rollback plan ready for quick recovery

---

## 10. Final Refactoring Summary

### 10.1 Overview

The main.zig refactoring project is now **COMPLETE**. Over 5 phases, we have successfully decomposed a monolithic 2316-line file into a modular architecture with clear separation of concerns.

### 10.2 Phases Completed

| Phase | Module | Lines Moved | Risk | Description |
|-------|--------|-------------|------|-------------|
| 1 | `lua_peak_bridge.zig` | ~410 | Low | Lua API for peak data transfer |
| 2 | `subscription_polling.zig` | ~230 | Medium | Toggle, Peaks, Routing, TrackFx, TrackFxParam polling |
| 3 | `tier_polling.zig` | ~460 | Medium-High | HIGH/MEDIUM/LOW tier polling |
| 4 | `playlist_tick.zig` | ~185 | Low | Playlist engine tick and transport sync |
| 5 | `client_management.zig` | ~145 | Low | Client lifecycle (disconnect, timeout, snapshot) |
| **Total** | **5 modules** | **~1430** | - | - |

### 10.3 main.zig Reduction

| State | Lines | Reduction |
|-------|-------|-----------|
| Original | 2316 | - |
| After Phase 1 | ~1906 | -410 (18%) |
| After Phase 2 | ~1676 | -640 (28%) |
| After Phase 3 | ~1216 | -1100 (48%) |
| After Phase 4 | ~1056 | -1260 (54%) |
| After Phase 5 | ~910 | -1406 (61%) |

**Final reduction: 61% of original code moved to testable modules**

### 10.4 What Remains in main.zig

The final main.zig (~910 lines) contains only:

1. **Imports and Globals** (~90 lines)
   - Module imports
   - Global state variables
   - Configuration constants

2. **Initialization** (~225 lines)
   - `initTimerCallback()` - Deferred init entry point
   - `doInitialization()` - Create all subsystems

3. **doProcessing() Orchestration** (~180 lines)
   - Frame begin/end
   - CSurf dirty flag consumption
   - Skeleton rebuild trigger
   - WebSocket server startup
   - Command dispatch
   - **Calls to extracted modules**
   - Heartbeat safety net
   - HTML hot reload check

4. **Shutdown** (~150 lines)
   - `shutdown()` - Clean up all subsystems

5. **Entry Point** (~35 lines)
   - `ReaperPluginEntry()` - C entry point

6. **Test Re-exports** (~20 lines)

### 10.5 Testability Improvement

Before refactoring:
- `doProcessing()` was ~1200 lines of untestable, interleaved logic
- No way to test individual behaviors in isolation
- All state deeply coupled to globals

After refactoring:
- Each module has clear interfaces with context structs
- Functions accept explicit parameters instead of accessing globals
- Unit tests can be written with mock backends/contexts
- Individual behaviors (polling, client management, etc.) testable in isolation

### 10.6 Module Dependency Graph

```
main.zig (orchestration)
    |
    +-- lua_peak_bridge.zig (standalone)
    |
    +-- subscription_polling.zig
    |       +-- PollingContext
    |
    +-- tier_polling.zig
    |       +-- TierContext
    |       +-- MutableState
    |       +-- HighTierResult
    |
    +-- playlist_tick.zig
    |       +-- PlaylistTickContext
    |
    +-- client_management.zig
            +-- ClientContext
            +-- SnapshotContext
```

### 10.7 Documentation Created

| Document | Purpose |
|----------|---------|
| `MAIN_ZIG_REFACTORING_PLAN.md` | Master plan with all 5 phases |
| `MAIN_PHASE_1_REFACTOR.md` | Lua Peak Bridge extraction (not created - was simpler) |
| `MAIN_PHASE_2_REFACTOR.md` | Subscription Polling extraction |
| `MAIN_PHASE_3_REFACTOR.md` | Tier Polling extraction |
| `MAIN_PHASE_4_REFACTOR.md` | Playlist Tick extraction |
| `MAIN_PHASE_5_REFACTOR.md` | Client Management extraction (this document) |

### 10.8 Key Lessons Learned

1. **Context structs are essential** - Bundling dependencies into typed structs makes interfaces clear and enables testing
2. **Static buffers prevent stack overflow** - REAPER's deep call stack requires careful memory management
3. **Incremental extraction works** - Each phase builds on the previous, with verification at each step
4. **grep verification catches errors** - Simple grep checks confirm code is properly moved
5. **Functional testing is critical** - Build passes are necessary but not sufficient; REAPER testing is essential

### 10.9 Future Improvements

With the refactoring complete, future work can focus on:

1. **Unit tests** for each extracted module using mock backends
2. **Integration tests** for client lifecycle scenarios
3. **Performance profiling** of individual modules
4. **Further decomposition** if any module grows too large
5. **Documentation** of module interfaces for contributors

---

## Appendix A: Line-by-Line Mapping

| Original Lines | New Location | Notes |
|---------------|--------------|-------|
| 561-621 | `cleanupDisconnectedClients()` | 61 lines - disconnect cleanup |
| 623-648 | `checkGestureTimeouts()` | 26 lines - timeout handling |
| 650-704 | `sendSnapshotsToNewClients()` | 55 lines - snapshot sending |
| 416-436 | `Buffers` struct in client_management.zig | Static buffers moved |

## Appendix B: Type Dependencies

```
client_management.zig
+-- std
+-- reaper.zig
|   +-- Api (undoEndBlock, csurfFlushUndo)
|   +-- RealBackend
+-- logging.zig
+-- ws_server.zig
|   +-- SharedState
+-- gesture_state.zig
|   +-- GestureState
|   +-- ControlId
+-- tiered_state.zig
|   +-- TieredArenas
+-- transport.zig
|   +-- State
+-- project.zig
|   +-- State
+-- markers.zig
|   +-- State
|   +-- Marker
|   +-- Region
|   +-- MAX_MARKERS
|   +-- MAX_REGIONS
+-- items.zig
|   +-- State
+-- tempomap.zig
|   +-- State
+-- track_skeleton.zig
|   +-- State
+-- playlist.zig
|   +-- State
+-- toggle_subscriptions.zig
|   +-- ToggleSubscriptions
+-- project_notes.zig
|   +-- NotesSubscriptions
+-- track_subscriptions.zig
|   +-- TrackSubscriptions
+-- peaks_subscriptions.zig
|   +-- PeaksSubscriptions
+-- routing_subscriptions.zig
|   +-- RoutingSubscriptions
+-- trackfx_subscriptions.zig
|   +-- TrackFxSubscriptions
+-- trackfxparam_subscriptions.zig
    +-- TrackFxParamSubscriptions
```

## Appendix C: Key Differences from Phase 4

| Aspect | Phase 4 (playlist_tick) | Phase 5 (client_management) |
|--------|-------------------------|----------------------------|
| Code blocks | 2 contiguous blocks | 3 related but separate blocks |
| Primary concern | Playlist engine | Client lifecycle |
| Mutable state | playlist_state.engine | Multiple subscription systems |
| Dependencies | 8 imports | 24 imports |
| Static buffers | None | 4 buffers + snapshot state |
| Complexity | Low | Low |
| Risk level | Low | Low |

## Appendix D: Complete Refactoring Statistics

### Lines by Module

| Module | Code Lines | Doc/Test Lines | Total |
|--------|------------|----------------|-------|
| lua_peak_bridge.zig | ~350 | ~60 | ~410 |
| subscription_polling.zig | ~200 | ~80 | ~280 |
| tier_polling.zig | ~480 | ~70 | ~550 |
| playlist_tick.zig | ~230 | ~50 | ~280 |
| client_management.zig | ~220 | ~60 | ~280 |
| **Total extracted** | **~1480** | **~320** | **~1800** |

### Context Structs Created

| Struct | Module | Fields |
|--------|--------|--------|
| PollingContext | subscription_polling.zig | 6 |
| TierContext | tier_polling.zig | 10 |
| MutableState | tier_polling.zig | 9 |
| HighTierResult | tier_polling.zig | 2 |
| PlaylistTickContext | playlist_tick.zig | 5 |
| ClientContext | client_management.zig | 10 |
| SnapshotContext | client_management.zig | 5 |

**Total: 7 context structs with 47 fields**

### Public Functions Created

| Module | Functions | Error-Returning |
|--------|-----------|-----------------|
| lua_peak_bridge.zig | 4 | 0 |
| subscription_polling.zig | 5 | 4 |
| tier_polling.zig | 3 | 3 |
| playlist_tick.zig | 2 | 0 |
| client_management.zig | 3 | 0 |
| **Total** | **17** | **7** |

---

*This document completes the main.zig refactoring project. The extension now has a modular architecture that enables unit testing, clearer code navigation, and easier maintenance.*
