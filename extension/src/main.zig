const std = @import("std");
const reaper = @import("reaper.zig");
const transport = @import("transport.zig");
const project = @import("project.zig");
const markers = @import("markers.zig");
const items = @import("items.zig");
const tracks = @import("tracks.zig");
const tempomap = @import("tempomap.zig");
const fx = @import("fx.zig");
const sends = @import("sends.zig");
const commands = @import("commands/mod.zig");
const ws_server = @import("ws_server.zig");
const gesture_state = @import("gesture_state.zig");
const toggle_subscriptions = @import("toggle_subscriptions.zig");
const project_notes = @import("project_notes.zig");
const playlist = @import("playlist.zig");
const errors = @import("errors.zig");
const logging = @import("logging.zig");
const tiered_state = @import("tiered_state.zig");
const guid_cache = @import("guid_cache.zig");
const item_guid_cache = @import("item_guid_cache.zig");
const track_subscriptions = @import("track_subscriptions.zig");
const peaks_subscriptions = @import("peaks_subscriptions.zig");
const routing_subscriptions = @import("routing_subscriptions.zig");
const routing_generator = @import("routing_generator.zig");
const peaks_generator = @import("peaks_generator.zig");
const peaks_cache = @import("peaks_cache.zig");
const track_skeleton = @import("track_skeleton.zig");
const csurf = @import("csurf.zig");
const csurf_dirty = @import("csurf_dirty.zig");
const ztracy = @import("ztracy");

// Use custom panic handler that flushes log ring buffer before aborting
pub const panic = logging.panic;

// Configuration
const DEFAULT_PORT: u16 = 9224;
const MAX_PORT_ATTEMPTS: u8 = 10;

// Global state - minimized to essentials
var g_api: ?reaper.Api = null;
var g_allocator: std.mem.Allocator = undefined;
var g_shared_state: ?*ws_server.SharedState = null;
var g_gesture_state: ?*gesture_state.GestureState = null;
var g_toggle_subs: ?*toggle_subscriptions.ToggleSubscriptions = null;
var g_notes_subs: ?*project_notes.NotesSubscriptions = null;
var g_guid_cache: ?*guid_cache.GuidCache = null;
var g_item_cache: ?*item_guid_cache.ItemGuidCache = null;
var g_track_subs: ?*track_subscriptions.TrackSubscriptions = null;
var g_peaks_subs: ?*peaks_subscriptions.PeaksSubscriptions = null;
var g_routing_subs: ?*routing_subscriptions.RoutingSubscriptions = null;
var g_peaks_cache: ?*peaks_cache.PeaksCache = null;
var g_csurf: ?*csurf.ControlSurface = null;
var g_plugin_register: ?*const fn ([*:0]const u8, ?*anyopaque) callconv(.c) c_int = null;
var g_dirty_flags: ?*csurf_dirty.DirtyFlags = null;

// Track skeleton state for LOW tier change detection
var g_last_skeleton: track_skeleton.State = .{};
var g_last_skeleton_buf: []track_skeleton.SkeletonTrack = &.{};
var g_server: ?ws_server.Server = null;
var g_port: u16 = 0;
var g_tiered: ?tiered_state.TieredArenas = null;

// Playlist engine state - needs regions cache for cross-tier lookups
// The playlist engine runs at 30Hz (HIGH tier) but regions are polled at 5Hz (MEDIUM tier).
// This cache persists regions between MEDIUM polls so the playlist engine can look up region bounds.
var g_last_markers: markers.State = .{};
var g_last_markers_buf: [markers.MAX_MARKERS]markers.Marker = undefined;
var g_last_regions_buf: [markers.MAX_REGIONS]markers.Region = undefined;
var g_playlist_state: playlist.State = .{};
var g_last_playlist: playlist.State = .{}; // For change detection
var g_initialized: bool = false;

// Error rate limiting for broadcast errors
var g_error_limiter: errors.ErrorRateLimiter = .{};

// Hot reload detection
var g_html_path_buf: [512]u8 = undefined;
var g_html_path: ?[]const u8 = null;
var g_html_mtime: i128 = 0;
var g_file_check_counter: u32 = 0;
const FILE_CHECK_INTERVAL: u32 = 60; // Check every ~2 seconds (60 * 33ms)

// Tiered polling frame counter
// HIGH TIER (30Hz): Transport, Tracks, Metering - every frame
// MEDIUM TIER (5Hz): Markers, Regions, Items, Project - every 6th frame
// LOW TIER (1Hz): Tempomap, Project Notes - every 30th frame
var g_frame_counter: u32 = 0;
var g_init_complete: bool = false; // Safety flag to prevent timer callback running before init
var g_ws_started: bool = false; // Track if WebSocket server has been started
const MEDIUM_TIER_INTERVAL: u32 = 6; // 30Hz / 6 = 5Hz
const LOW_TIER_INTERVAL: u32 = 30; // 30Hz / 30 = 1Hz
const WS_START_DELAY_FRAMES: u32 = 30; // Wait ~1 second before starting WebSocket server

/// Broadcast an error event to all clients with rate limiting
/// Only broadcasts if enough time has passed since the last broadcast of this error type
fn broadcastRateLimitedError(code: errors.ErrorCode, detail: ?[]const u8) void {
    const shared_state = g_shared_state orelse return;
    const current_time = std.time.timestamp();

    if (g_error_limiter.shouldBroadcast(code, current_time)) {
        const event = errors.ErrorEvent{ .code = code, .detail = detail };
        // Use scratch allocator if available, otherwise use fixed buffer
        if (g_tiered) |*tiered| {
            const scratch = tiered.scratchAllocator();
            if (event.toJsonAlloc(scratch)) |json| {
                shared_state.broadcast(json);
            } else |_| {}
        } else {
            // Fallback for errors before tiered state is initialized
            var buf: [2048]u8 = undefined;
            if (event.toJson(&buf)) |json| {
                shared_state.broadcast(json);
            }
        }
    }
}

// Timer callback for deferred initialization
// First call does initialization, then immediately switches to processing timer.
// No warmup delays needed since pollInto() avoids large stack allocations.
//
// SAFETY: This is a C-callable entry point. All Zig errors must be caught here
// to prevent error propagation across the FFI boundary which would crash REAPER.
fn initTimerCallback() callconv(.c) void {
    initTimerCallbackImpl() catch |err| {
        logging.err("initTimerCallback failed: {s}", .{@errorName(err)});
        // Error is logged but not propagated - REAPER must not see Zig errors
    };
}

fn initTimerCallbackImpl() !void {
    // First call: do initialization
    if (!g_initialized) {
        g_initialized = true;
        try doInitialization();
        return;
    }

    // Initialization done - switch directly to processing timer
    const api = &(g_api orelse return error.ApiNotInitialized);
    api.unregisterTimer(&initTimerCallback);
    api.registerTimer(&processTimerCallback);
    g_init_complete = true;
    logging.info("Initialization complete, starting processing timer", .{});
}

fn doInitialization() !void {
    const api = &(g_api orelse return error.ApiNotInitialized);
    logging.info("Deferred initialization starting...", .{});

    g_allocator = std.heap.page_allocator;

    // Initialize logging with REAPER's resource path
    logging.init(api.resourcePath());
    logging.info("initTimerCallback() started", .{});

    // Initialize hot reload file path
    if (api.resourcePath()) |res_path| {
        logging.debug("Resource path: {s}", .{res_path});
        const written = std.fmt.bufPrint(&g_html_path_buf, "{s}/reaper_www_root/reamo.html", .{res_path}) catch null;
        if (written) |path| {
            g_html_path = path;
            logging.debug("Watching: {s}", .{path});
            // Get initial mtime
            if (std.fs.cwd().statFile(path)) |stat| {
                g_html_mtime = stat.mtime;
                logging.debug("Initial mtime: {}", .{stat.mtime});
            } else |err| {
                logging.warn("Could not stat file: {s}", .{@errorName(err)});
            }
        }
    } else {
        logging.warn("Could not get resource path", .{});
    }

    // Create shared state
    const state = try g_allocator.create(ws_server.SharedState);
    state.* = ws_server.SharedState.init(g_allocator);
    g_shared_state = state;

    // Create gesture state for undo coalescing
    const gestures = try g_allocator.create(gesture_state.GestureState);
    gestures.* = gesture_state.GestureState.init(g_allocator);
    g_gesture_state = gestures;

    // Create toggle subscriptions state
    const toggles = try g_allocator.create(toggle_subscriptions.ToggleSubscriptions);
    toggles.* = toggle_subscriptions.ToggleSubscriptions.init(g_allocator);
    g_toggle_subs = toggles;
    commands.g_ctx.toggle_subs = toggles;

    // Create project notes subscriptions state
    const notes_subs = try g_allocator.create(project_notes.NotesSubscriptions);
    notes_subs.* = project_notes.NotesSubscriptions.init(g_allocator);
    g_notes_subs = notes_subs;
    commands.g_ctx.notes_subs = notes_subs;

    // Create GUID cache for track subscriptions
    const cache = try g_allocator.create(guid_cache.GuidCache);
    cache.* = guid_cache.GuidCache.init(g_allocator);
    g_guid_cache = cache;
    commands.g_ctx.guid_cache = cache;

    // Create item GUID cache (rebuilt every 5Hz during items poll)
    const i_cache = try g_allocator.create(item_guid_cache.ItemGuidCache);
    i_cache.* = item_guid_cache.ItemGuidCache.init(g_allocator);
    g_item_cache = i_cache;
    commands.g_ctx.item_cache = i_cache;

    // Create track subscriptions state
    const track_subs = try g_allocator.create(track_subscriptions.TrackSubscriptions);
    track_subs.* = track_subscriptions.TrackSubscriptions.init(g_allocator);
    g_track_subs = track_subs;
    commands.g_ctx.track_subs = track_subs;

    // Create peaks subscriptions state
    const peaks_subs = try g_allocator.create(peaks_subscriptions.PeaksSubscriptions);
    peaks_subs.* = peaks_subscriptions.PeaksSubscriptions.init(g_allocator);
    g_peaks_subs = peaks_subs;
    commands.g_ctx.peaks_subs = peaks_subs;

    // Create routing subscriptions state (per-track routing: sends/receives/hw outputs)
    const routing_subs = try g_allocator.create(routing_subscriptions.RoutingSubscriptions);
    routing_subs.* = routing_subscriptions.RoutingSubscriptions.init(g_allocator);
    g_routing_subs = routing_subs;
    commands.g_ctx.routing_subs = routing_subs;

    // Create peaks cache for LRU caching of waveform data
    const p_cache = try g_allocator.create(peaks_cache.PeaksCache);
    p_cache.* = peaks_cache.PeaksCache.init(g_allocator);
    g_peaks_cache = p_cache;

    // Count project entities and calculate arena sizes dynamically
    // This allows memory allocation to scale with project size
    var backend = reaper.RealBackend{ .inner = api };
    const entity_counts = tiered_state.EntityCounts.countFromApi(&backend);
    const arena_sizes = tiered_state.CalculatedSizes.fromCounts(entity_counts);

    // Log entity counts and calculated sizes
    var counts_buf: [256]u8 = undefined;
    var sizes_buf: [256]u8 = undefined;
    if (entity_counts.format(&counts_buf)) |counts_str| {
        logging.info("Project entities: {s}", .{counts_str});
    }
    if (arena_sizes.format(&sizes_buf)) |sizes_str| {
        logging.info("Arena sizes: {s}", .{sizes_str});
    }

    // Initialize tiered arenas with calculated sizes
    g_tiered = try tiered_state.TieredArenas.initWithSizes(g_allocator, arena_sizes);
    logging.info("Tiered arenas initialized: {d}MB total", .{arena_sizes.totalAllocated() >> 20});

    // Set global reference for debug command
    commands.g_ctx.tiered = &(g_tiered.?);

    // Sync initial HTML mtime to shared state
    state.setHtmlMtime(g_html_mtime);

    // Set time_precise function for clock sync (thread-safe read-only call)
    if (api.time_precise) |time_fn| {
        state.setTimePreciseFn(time_fn);
    }

    // Generate session token and store in EXTSTATE
    var token_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&token_bytes);
    const token_hex = std.fmt.bytesToHex(token_bytes, .lower);
    state.setToken(&token_hex);
    api.setExtStateStr("Reamo", "SessionToken", &token_hex);
    logging.info("Session token generated", .{});

    // Initialize CSurf (Control Surface) for push-based callbacks
    // Only active when built with -Dcsurf=true
    if (csurf.enabled) {
        if (g_plugin_register) |plugin_register| {
            const cs = try g_allocator.create(csurf.ControlSurface);
            cs.* = csurf.ControlSurface.init(state, plugin_register) catch |err| {
                logging.err("Failed to create CSurf: {s}", .{@errorName(err)});
                g_allocator.destroy(cs);
                return err;
            };
            if (cs.register()) {
                g_csurf = cs;
                logging.info("CSurf registered for push-based callbacks", .{});
            } else {
                logging.warn("CSurf registration failed", .{});
                cs.deinit();
                g_allocator.destroy(cs);
            }
        }
    }

    // WebSocket server will be started in processTimerCallback after startup completes
    // This avoids stack overflow when REAPER shows modal dialogs during startup
    g_server = null;
    g_port = 0;

    // Store port in REAPER's extension state for discovery
    var port_buf: [8]u8 = undefined;
    const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{g_port}) catch "9224";
    api.setExtStateStr("Reamo", "WebSocketPort", port_str);

    // Initialize g_last_markers for playlist engine - it needs regions across tier boundaries
    // The playlist engine runs at 30Hz (HIGH tier) but regions are polled at 5Hz (MEDIUM tier).
    // This cache persists regions between MEDIUM polls so the playlist engine can look up region bounds.
    g_last_markers.pollInto(&g_last_markers_buf, &g_last_regions_buf, &backend);

    // Load playlist state from ProjExtState
    g_playlist_state.loadAll(&backend);
    g_last_playlist = g_playlist_state;
    logging.info("Loaded {d} playlists from project", .{g_playlist_state.playlist_count});
    logging.info("Initialization complete, waiting for warmup", .{});
}

// Static buffers for modules that haven't migrated to allocator pattern yet
// Most JSON serialization now uses the scratch arena allocator
const StaticBuffers = struct {
    var notes: [256]u8 = undefined; // project_notes_cmds.formatChangedEvent
};

// Compile-time size assertions to catch regressions
// These structs are stored in static memory to avoid stack overflow
// If any exceed the threshold, consider redesigning with smaller inline arrays
comptime {
    const MAX_STATE_SIZE = 4 * 1024 * 1024; // 4MB threshold warning
    // tracks.State is now slice-based, check Track size * MAX_TRACKS instead
    const tracks_buffer_size = @sizeOf(tracks.Track) * tracks.MAX_TRACKS;
    if (tracks_buffer_size > MAX_STATE_SIZE) {
        @compileError("tracks buffer exceeds 4MB - consider reducing MAX_TRACKS or MAX_FX_PER_TRACK");
    }
    if (@sizeOf([markers.MAX_MARKERS]markers.Marker) + @sizeOf([markers.MAX_REGIONS]markers.Region) > MAX_STATE_SIZE) {
        @compileError("markers buffers exceed 4MB - consider reducing MAX_MARKERS or MAX_REGIONS");
    }
    if (@sizeOf([items.MAX_ITEMS]items.Item) > MAX_STATE_SIZE) {
        @compileError("items buffer exceeds 4MB - consider reducing MAX_ITEMS");
    }
}

// Static state storage for doProcessing() to avoid large stack allocations
// Zig allocates ALL local variables at function entry, so we move large State
// structs to static memory to prevent stack overflow in deep REAPER startup stacks
const ProcessingState = struct {
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

    // Small utility arrays
    var disconnected_buf: [16]usize = undefined;
    var flush_buf: [16]gesture_state.ControlId = undefined;
    var timeout_buf: [16]gesture_state.ControlId = undefined;
    var snapshot_clients: [16]usize = undefined;
};

// Main processing timer - calls doProcessing() directly.
// No warmup delays needed since pollInto() avoids large stack allocations.
//
// SAFETY: This is a C-callable entry point. All Zig errors must be caught here
// to prevent error propagation across the FFI boundary which would crash REAPER.
fn processTimerCallback() callconv(.c) void {
    doProcessing() catch |err| {
        logging.err("processTimerCallback failed: {s}", .{@errorName(err)});
        // Error is logged but not propagated - REAPER must not see Zig errors
    };
}

// Helper to compare track slices for change detection
fn tracksSliceEql(a: []const tracks.Track, b: []const tracks.Track) bool {
    if (a.len != b.len) return false;
    for (a, b) |*track_a, *track_b| {
        if (!track_a.eql(track_b.*)) return false;
    }
    return true;
}

// Helper to compare marker slices for change detection
fn markersSliceEql(a: []const markers.Marker, b: []const markers.Marker) bool {
    if (a.len != b.len) return false;
    for (a, b) |*marker_a, *marker_b| {
        if (!marker_a.eql(marker_b)) return false;
    }
    return true;
}

// Helper to compare region slices for change detection
fn regionsSliceEql(a: []const markers.Region, b: []const markers.Region) bool {
    if (a.len != b.len) return false;
    for (a, b) |*region_a, *region_b| {
        if (!region_a.eql(region_b)) return false;
    }
    return true;
}

// Helper to compare item slices for change detection
fn itemsSliceEql(a: []const items.Item, b: []const items.Item) bool {
    if (a.len != b.len) return false;
    for (a, b) |*item_a, *item_b| {
        if (!item_a.eql(item_b)) return false;
    }
    return true;
}

// Helper to compare FX slot slices for change detection
fn fxSliceEql(a: []const fx.FxSlot, b: []const fx.FxSlot) bool {
    if (a.len != b.len) return false;
    for (a, b) |*fx_a, *fx_b| {
        if (!fx_a.eql(fx_b.*)) return false;
    }
    return true;
}

// Helper to compare send slot slices for change detection
fn sendsSliceEql(a: []const sends.SendSlot, b: []const sends.SendSlot) bool {
    if (a.len != b.len) return false;
    for (a, b) |*send_a, *send_b| {
        if (!send_a.eql(send_b.*)) return false;
    }
    return true;
}

// The actual processing logic
// IMPORTANT: This function uses ProcessingState and pollInto() to avoid stack overflow
fn doProcessing() !void {
    // Safety check - don't run until init is complete
    if (!g_init_complete) {
        return;
    }

    // Tracy frame marker for 30Hz timer callback
    ztracy.FrameMark();
    const zone = ztracy.ZoneN(@src(), "doProcessing");
    defer zone.End();

    const api = &(g_api orelse return error.ApiNotInitialized);
    const shared_state = g_shared_state orelse return error.StateNotInitialized;

    // Begin new frame - resets scratch arena and swaps tier arenas based on frame counter
    var tiered = &(g_tiered orelse return error.TieredNotInitialized);
    try tiered.beginFrame(g_frame_counter);

    // Deferred WebSocket server startup - wait a moment for REAPER UI to settle
    if (!g_ws_started and g_frame_counter >= WS_START_DELAY_FRAMES) {
        g_ws_started = true;
        logging.info("Starting WebSocket server (deferred)...", .{});

        const result = try ws_server.startWithPortRetry(g_allocator, shared_state, DEFAULT_PORT, MAX_PORT_ATTEMPTS);
        g_server = result.server;
        g_port = result.port;

        // Update port in REAPER's extension state
        var port_buf: [8]u8 = undefined;
        const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{g_port}) catch "9224";
        api.setExtStateStr("Reamo", "WebSocketPort", port_str);

        logging.info("WebSocket server started on port {d}", .{g_port});
    }

    // Create backend for state polling
    var backend = reaper.RealBackend{ .inner = api };

    // Process pending commands from WebSocket clients
    while (shared_state.popCommand()) |cmd| {
        var command = cmd;
        defer command.deinit();
        commands.dispatch(&backend, command.client_id, command.data, shared_state, g_gesture_state, &g_playlist_state);
    }

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
        }
    }

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

    // Send initial state snapshot to newly connected clients
    // Using ProcessingState for all state structs to avoid stack overflow
    const snapshot_count = shared_state.popClientsNeedingSnapshot(&ProcessingState.snapshot_clients);
    if (snapshot_count > 0) {
        // Get current state for all domains - use pollInto for large structs
        ProcessingState.snap_transport = transport.State.poll(&backend); // Small
        ProcessingState.snap_project = project.State.poll(&backend); // Small
        ProcessingState.snap_markers.pollInto(&ProcessingState.snap_markers_buf, &ProcessingState.snap_regions_buf, &backend); // ~95KB
        ProcessingState.snap_tempomap = tempomap.State.poll(&backend); // Small

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

    // Increment frame counter for tiered polling
    g_frame_counter +%= 1;

    // ========================================================================
    // HIGH TIER (30Hz) - Transport, Tracks, Metering
    // These need real-time responsiveness for playhead and fader movements
    // Uses arena allocation - no memcpy needed, arena swap handles it
    // ========================================================================

    const high_state = tiered.high.currentState();
    const high_prev = tiered.high.previousState();

    // Poll transport state into arena
    high_state.transport = transport.State.poll(&backend);
    const current_transport = &high_state.transport;

    if (!current_transport.eql(high_prev.transport)) {
        const state_changed = !current_transport.stateOnlyEql(high_prev.transport);
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

            // Broadcast tracks event (when data changes OR new subscription needs immediate data)
            const force_broadcast = track_subs.consumeForceBroadcast();
            const tracks_changed = !tracksSliceEql(high_state.tracks, high_prev.tracks);
            if (tracks_changed or force_broadcast) {
                const temp_state = tracks.State{ .tracks = high_state.tracks };
                const scratch = tiered.scratchAllocator();
                // Use toJsonWithTotalAlloc to include total track count for viewport scrollbar
                if (temp_state.toJsonWithTotalAlloc(scratch, null, total_tracks)) |json| {
                    shared_state.broadcast(json);
                } else |_| {}
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

        // Broadcast tracks event (only when changed)
        // Use toJsonWithTotalAlloc for consistent format with subscription path (includes total, GUID, recInput)
        const tracks_changed = !tracksSliceEql(high_state.tracks, high_prev.tracks);
        if (tracks_changed) {
            const temp_state = tracks.State{ .tracks = high_state.tracks };
            const scratch = tiered.scratchAllocator();
            if (temp_state.toJsonWithTotalAlloc(scratch, null, total_tracks)) |json| {
                shared_state.broadcast(json);
            } else |_| {}
        }

        // Broadcast separate meters event
        if (high_state.metering.hasData()) {
            const meter_scratch = tiered.scratchAllocator();
            if (high_state.metering.toJsonEventAlloc(meter_scratch, high_state.tracks)) |json| {
                shared_state.broadcast(json);
            } else |_| {}
        }
    }

    // Note: FX/sends are sparse counts populated during poll().
    // Full FX/sends data is fetched on-demand via track/getFx, track/getSends commands.


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

    // Poll peaks subscriptions and broadcast (HIGH TIER - per-client subscription)
    // Broadcasts when: force_broadcast is set (new subscription) OR track items changed
    // Uses PeaksCache for LRU caching of individual item peaks
    // Multi-track mode: sends track-keyed map with peaks for all subscribed tracks
    if (g_peaks_subs) |peaks_subs| {
        if (peaks_subs.hasSubscriptions()) {
            const guid_cache_ptr = g_guid_cache orelse {
                logging.err("GUID cache not initialized for peaks subscriptions", .{});
                return error.GuidCacheNotInitialized;
            };
            const p_cache = g_peaks_cache orelse {
                logging.err("Peaks cache not initialized", .{});
                return error.GuidCacheNotInitialized;
            };

            // Tick the cache for LRU tracking
            p_cache.tick();

            // Check if any subscription needs immediate data (new subscription)
            const force_broadcast = peaks_subs.consumeForceBroadcast();

            // Get all subscribed track indices across all clients
            var indices_buf: [128]c_int = undefined;
            const subscribed_indices = peaks_subs.getSubscribedIndices(guid_cache_ptr, &backend, &indices_buf);

            // Check if any track has changes (items added/removed/modified)
            var any_track_changed = force_broadcast;
            if (!force_broadcast) {
                for (subscribed_indices) |track_idx| {
                    const track = backend.getTrackByIdx(track_idx) orelse continue;
                    var guid_buf: [64]u8 = undefined;
                    const track_guid = backend.formatTrackGuid(track, &guid_buf);
                    if (p_cache.trackChanged(track_guid, &backend, track)) {
                        any_track_changed = true;
                        break;
                    }
                }
            }

            // Only broadcast if something changed
            if (any_track_changed) {
                // Iterate active subscriptions and send to each client
                var iter = peaks_subs.activeSubscriptions();
                while (iter.next()) |entry| {
                    const sample_count = entry.sub.sample_count;
                    const peaks_scratch = tiered.scratchAllocator();

                    // Generate peaks for this client's subscribed tracks
                    if (peaks_generator.generatePeaksForSubscription(
                        peaks_scratch,
                        &backend,
                        guid_cache_ptr,
                        p_cache,
                        entry.sub,
                        sample_count,
                    )) |json| {
                        shared_state.sendToClient(entry.client_id, json);
                    }
                }
            }
        }
    }

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
                    if (routing_subs.checkChanged(entry.slot, data_hash)) {
                        shared_state.sendToClient(entry.client_id, json);
                    }
                }
            }
        }
    }

    // Sync playlist engine with external transport changes
    // (user paused/stopped REAPER transport outside of our control)
    if (g_playlist_state.engine.isActive()) {
        const transport_playing = transport.PlayState.isPlaying(current_transport.play_state);
        const transport_stopped = current_transport.play_state == transport.PlayState.STOPPED;

        if (g_playlist_state.engine.isPlaying() and !transport_playing) {
            // Engine thinks it's playing but transport isn't
            if (transport_stopped) {
                _ = g_playlist_state.engine.stop();
                backend.setRepeat(false);
                backend.clearLoopPoints();
                logging.debug("Stopped playlist engine - transport stopped externally", .{});
            } else {
                // Transport paused
                _ = g_playlist_state.engine.pause();
                logging.debug("Paused playlist engine - transport paused externally", .{});
            }
            // Broadcast state change
            const scratch = tiered.scratchAllocator();
            if (g_playlist_state.toJsonAlloc(scratch, g_last_markers.regions)) |json| {
                shared_state.broadcast(json);
            } else |_| {}
        }
    }

    // Playlist engine tick (when playing)
    if (g_playlist_state.engine.isPlaying()) {
        const current_pos = current_transport.play_position;

        // Get current entry's region info
        if (g_playlist_state.getPlaylist(g_playlist_state.engine.playlist_idx)) |p| {
            if (g_playlist_state.engine.entry_idx < p.entry_count) {
                const entry = &p.entries[g_playlist_state.engine.entry_idx];

                // Find region by ID in cached markers state
                var region_start: f64 = 0;
                var region_end: f64 = 0;
                var region_found = false;
                for (g_last_markers.regions) |*r| {
                    if (r.id == entry.region_id) {
                        region_start = r.start;
                        region_end = r.end;
                        region_found = true;
                        break;
                    }
                }

                if (region_found) {
                    // Get next entry info if available
                    const next_entry: ?playlist.NextEntryInfo = blk: {
                        if (g_playlist_state.engine.entry_idx + 1 < p.entry_count) {
                            const next = &p.entries[g_playlist_state.engine.entry_idx + 1];
                            // Find next region's start and end
                            for (g_last_markers.regions) |*r| {
                                if (r.id == next.region_id) {
                                    break :blk playlist.NextEntryInfo{
                                        .loop_count = next.loop_count,
                                        .region_start = r.start,
                                        .region_end = r.end,
                                    };
                                }
                            }
                        }
                        break :blk null;
                    };

                    // Calculate bar length for non-contiguous transition timing
                    // bar_length = beats_per_bar * seconds_per_beat
                    const bpm = current_transport.bpm;
                    const beats_per_bar = current_transport.time_sig_num;
                    const bar_length = if (bpm > 0) beats_per_bar * (60.0 / bpm) else 2.0;

                    const action = g_playlist_state.engine.tick(
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
                            const scratch = tiered.scratchAllocator();
                            if (g_playlist_state.toJsonAlloc(scratch, g_last_markers.regions)) |json| {
                                shared_state.broadcast(json);
                            } else |_| {}
                        },
                        .none => {},
                    }
                } else {
                    // Current region was deleted - skip to next valid entry
                    logging.debug("Region {d} deleted, finding next valid entry", .{entry.region_id});

                    // Find next entry with a valid region
                    var next_valid_idx: ?usize = null;
                    var next_bounds: ?struct { start: f64, end: f64 } = null;
                    var search_idx = g_playlist_state.engine.entry_idx + 1;
                    while (search_idx < p.entry_count) : (search_idx += 1) {
                        const candidate = &p.entries[search_idx];
                        for (g_last_markers.regions) |*r| {
                            if (r.id == candidate.region_id) {
                                next_valid_idx = search_idx;
                                next_bounds = .{ .start = r.start, .end = r.end };
                                break;
                            }
                        }
                        if (next_valid_idx != null) break;
                    }

                    if (next_valid_idx) |valid_idx| {
                        // Advance to valid entry
                        const next_entry_data = &p.entries[valid_idx];
                        g_playlist_state.engine.entry_idx = valid_idx;
                        g_playlist_state.engine.loops_remaining = next_entry_data.loop_count;
                        g_playlist_state.engine.current_loop_iteration = 1;
                        g_playlist_state.engine.advance_after_loop = false;
                        g_playlist_state.engine.next_loop_pending = false;

                        // Set up loop for valid region
                        if (next_bounds) |bounds| {
                            backend.setCursorPos(bounds.start);
                            backend.setLoopPoints(bounds.start, bounds.end);
                        }

                        logging.debug("Skipped to entry {d}", .{valid_idx});
                    } else {
                        // No valid entries remaining - stop
                        _ = g_playlist_state.engine.stop();
                        backend.setRepeat(false);
                        backend.clearLoopPoints();
                        logging.debug("No valid entries remaining, stopped playlist", .{});
                    }

                    // Broadcast state change
                    const scratch = tiered.scratchAllocator();
                    if (g_playlist_state.toJsonAlloc(scratch, g_last_markers.regions)) |json| {
                        shared_state.broadcast(json);
                    } else |_| {}
                }
            }
        }
    }

    // ========================================================================
    // MEDIUM TIER (5Hz) - Project state, Markers, Regions, Items
    // These change less frequently and don't need instant feedback
    // Uses arena allocation - no memcpy needed for change detection
    // ========================================================================
    if (g_frame_counter % MEDIUM_TIER_INTERVAL == 0) {
        const medium_alloc = tiered.medium.currentAllocator();
        const medium_state = tiered.medium.currentState();
        const medium_prev = tiered.medium.previousState();

        // Poll project state into arena
        medium_state.project = project.State.poll(&backend);

        // Set memory warning flag based on arena utilization (any tier > 80% peak usage)
        medium_state.project.memory_warning = tiered.isMemoryWarning();

        // Check for project identity change (tab switch or different file in same tab)
        if (medium_prev.project.projectChanged(&medium_state.project)) {
            logging.info("Project changed: {s}", .{
                if (medium_state.project.projectName().len > 0) medium_state.project.projectName() else "(Unsaved)",
            });

            // Stop playlist engine if playing
            if (g_playlist_state.engine.isActive()) {
                _ = g_playlist_state.engine.stop();
                backend.clearLoopPoints();
                logging.info("Stopped playlist engine due to project change", .{});
            }

            // Resize arenas if new project has significantly different entity counts
            const new_counts = tiered_state.EntityCounts.countFromApi(&backend);
            const new_sizes = tiered_state.CalculatedSizes.fromCounts(new_counts);

            // 25% threshold - only resize if allocation differs significantly
            if (tiered.shouldResize(new_sizes, 25)) {
                var counts_buf: [256]u8 = undefined;
                var sizes_buf: [256]u8 = undefined;
                if (new_counts.format(&counts_buf)) |counts_str| {
                    logging.info("New project entities: {s}", .{counts_str});
                }
                if (new_sizes.format(&sizes_buf)) |sizes_str| {
                    logging.info("Resizing arenas: {s}", .{sizes_str});
                }

                tiered.resize(g_allocator, new_sizes) catch |err| {
                    logging.err("Failed to resize arenas: {s}", .{@errorName(err)});
                    // Continue with existing arenas - graceful degradation
                };
                logging.info("Arena resize complete: {d}MB total", .{new_sizes.totalAllocated() >> 20});
            }

            // Flush any pending playlist changes to old project before loading new
            if (g_playlist_state.dirty) {
                g_playlist_state.saveAll(&backend);
                g_playlist_state.dirty = false;
            }

            // Reload playlists from new project's ProjExtState
            g_playlist_state.reset();
            g_playlist_state.loadAll(&backend);
            logging.info("Loaded {d} playlists from new project", .{g_playlist_state.playlist_count});

            // Broadcast updated playlist state
            // Note: regions not available yet, pass null - next tick will have accurate regions
            const scratch = tiered.scratchAllocator();
            if (g_playlist_state.toJsonAlloc(scratch, null)) |json| {
                shared_state.broadcast(json);
            } else |_| {}
            g_last_playlist = g_playlist_state;
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
        medium_state.markers = marker_state.markers;
        medium_state.regions = marker_state.regions;
        medium_state.bar_offset = marker_state.bar_offset;

        // Broadcast markers if changed (no subscription required)
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
        // Broadcast regions if changed (no subscription required)
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

        // Update g_last_markers for playlist engine - required for cross-tier timing
        // Playlist engine runs at 30Hz (HIGH) but regions poll at 5Hz (MEDIUM).
        // This cache persists regions between MEDIUM polls for region lookups.
        const cur_markers_len = medium_state.markers.len;
        const cur_regions_len = medium_state.regions.len;
        @memcpy(g_last_markers_buf[0..cur_markers_len], medium_state.markers);
        @memcpy(g_last_regions_buf[0..cur_regions_len], medium_state.regions);
        g_last_markers.markers = g_last_markers_buf[0..cur_markers_len];
        g_last_markers.regions = g_last_regions_buf[0..cur_regions_len];
        g_last_markers.bar_offset = medium_state.bar_offset;

        // Poll items into MEDIUM arena (for playlist engine cross-tier access)
        const item_state = items.State.poll(medium_alloc, &backend) catch |err| {
            logging.err("Failed to poll items: {s}", .{@errorName(err)});
            return err;
        };
        medium_state.items = item_state.items;

        // Rebuild item GUID cache from polled items (O(1) lookup for commands)
        if (g_item_cache) |icache| {
            icache.rebuildFromItems(items, medium_state.items) catch |err| {
                logging.warn("Failed to rebuild item cache: {s}", .{@errorName(err)});
            };
        }

        // Broadcast items if changed (no subscription required - like markers/regions)
        if (!itemsSliceEql(medium_state.items, medium_prev.items)) {
            const temp_item_state = items.State{ .items = medium_state.items };
            if (temp_item_state.itemsToJsonAlloc(scratch)) |json| {
                shared_state.broadcast(json);
            } else |_| {}
        }

        // Playlist state change detection
        // (Playlist state is modified by commands, not polled from REAPER)
        if (!g_playlist_state.eql(&g_last_playlist)) {
            if (g_playlist_state.toJsonAlloc(scratch, medium_state.regions)) |json| {
                shared_state.broadcast(json);
            } else |_| {}
            g_last_playlist = g_playlist_state;
        }

        // Deferred playlist persistence - flush dirty state to ProjExtState
        // Debounces writes: immediate when not playing, 1s delay when playing
        _ = g_playlist_state.flushIfNeeded(&backend, backend.timePrecise());

        // Poll FX into MEDIUM arena (flat array with track_idx parent references)
        const fx_state = fx.State.poll(medium_alloc, &backend) catch |err| {
            logging.err("Failed to poll FX: {s}", .{@errorName(err)});
            return err;
        };
        medium_state.fx_slots = fx_state.fx;

        // Broadcast if FX changed
        if (!fxSliceEql(medium_state.fx_slots, medium_prev.fx_slots)) {
            const temp_fx_state = fx.State{ .fx = medium_state.fx_slots };
            if (temp_fx_state.toJsonAlloc(scratch)) |json| {
                shared_state.broadcast(json);
            } else |_| {}
        }

        // Poll sends into MEDIUM arena (flat array with track_idx parent references)
        const sends_state = sends.State.poll(medium_alloc, &backend) catch |err| {
            logging.err("Failed to poll sends: {s}", .{@errorName(err)});
            return err;
        };
        medium_state.send_slots = sends_state.sends;

        // Broadcast if sends changed
        if (!sendsSliceEql(medium_state.send_slots, medium_prev.send_slots)) {
            const temp_sends_state = sends.State{ .sends = medium_state.send_slots };
            if (temp_sends_state.toJsonAlloc(scratch)) |json| {
                shared_state.broadcast(json);
            } else |_| {}
        }
    }

    // ========================================================================
    // LOW TIER (1Hz) - Tempomap, Project Notes, Track Skeleton
    // These rarely change during normal operation
    // Uses arena allocation for change detection
    // ========================================================================
    if (g_frame_counter % LOW_TIER_INTERVAL == 0) {
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
        // Copy to persistent buffer since arena will be swapped
        if (current_skeleton.tracks.len <= tracks.MAX_TRACKS) {
            // Ensure we have a buffer large enough
            if (g_last_skeleton_buf.len < current_skeleton.tracks.len) {
                // Reallocate if needed (shouldn't happen often)
                if (g_last_skeleton_buf.len > 0) {
                    g_allocator.free(g_last_skeleton_buf);
                }
                g_last_skeleton_buf = g_allocator.alloc(track_skeleton.SkeletonTrack, current_skeleton.tracks.len) catch &.{};
            }
            if (g_last_skeleton_buf.len >= current_skeleton.tracks.len) {
                @memcpy(g_last_skeleton_buf[0..current_skeleton.tracks.len], current_skeleton.tracks);
                g_last_skeleton.tracks = g_last_skeleton_buf[0..current_skeleton.tracks.len];
            }
        }

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

    // ========================================================================
    // INFREQUENT - HTML hot reload check (~2 seconds)
    // ========================================================================
    g_file_check_counter += 1;
    if (g_file_check_counter >= FILE_CHECK_INTERVAL) {
        g_file_check_counter = 0;

        if (g_html_path) |path| {
            if (std.fs.cwd().statFile(path)) |stat| {
                if (stat.mtime != g_html_mtime) {
                    logging.debug("HTML changed: mtime {} -> {}", .{ g_html_mtime, stat.mtime });
                    g_html_mtime = stat.mtime;
                    shared_state.setHtmlMtime(stat.mtime);
                    shared_state.broadcast("{\"type\":\"event\",\"event\":\"reload\"}");
                    logging.debug("Broadcast reload event", .{});
                }
            } else |err| {
                logging.warn("Stat failed: {s}", .{@errorName(err)});
            }
        }
    }
}

// Shutdown - called when REAPER unloads the extension
fn shutdown() void {
    logging.info("shutdown() called", .{});

    if (g_api) |*api| {
        api.unregisterTimer(&processTimerCallback);
    }
    logging.info("timer unregistered", .{});

    // Unregister and clean up CSurf before other cleanup
    if (g_csurf) |cs| {
        logging.info("cleaning up CSurf", .{});
        cs.unregister();
        cs.deinit();
        g_allocator.destroy(cs);
        g_csurf = null;
    }
    logging.info("CSurf cleaned up", .{});

    if (g_server) |*server| {
        logging.info("stopping server", .{});
        server.stop();
        server.deinit();
        g_server = null;
    }
    logging.info("server stopped", .{});

    if (g_gesture_state) |gestures| {
        logging.info("cleaning up gesture state", .{});
        gestures.deinit();
        g_allocator.destroy(gestures);
        g_gesture_state = null;
    }
    logging.info("gesture state cleaned up", .{});

    if (g_toggle_subs) |toggles| {
        logging.info("cleaning up toggle subscriptions", .{});
        commands.g_ctx.toggle_subs = null;
        toggles.deinit();
        g_allocator.destroy(toggles);
        g_toggle_subs = null;
    }
    logging.info("toggle subscriptions cleaned up", .{});

    if (g_notes_subs) |notes| {
        logging.info("cleaning up notes subscriptions", .{});
        commands.g_ctx.notes_subs = null;
        notes.deinit();
        g_allocator.destroy(notes);
        g_notes_subs = null;
    }
    logging.info("notes subscriptions cleaned up", .{});

    if (g_track_subs) |subs| {
        logging.info("cleaning up track subscriptions", .{});
        commands.g_ctx.track_subs = null;
        subs.deinit();
        g_allocator.destroy(subs);
        g_track_subs = null;
    }
    logging.info("track subscriptions cleaned up", .{});

    if (g_peaks_subs) |subs| {
        logging.info("cleaning up peaks subscriptions", .{});
        commands.g_ctx.peaks_subs = null;
        subs.deinit();
        g_allocator.destroy(subs);
        g_peaks_subs = null;
    }
    logging.info("peaks subscriptions cleaned up", .{});

    if (g_routing_subs) |subs| {
        logging.info("cleaning up routing subscriptions", .{});
        commands.g_ctx.routing_subs = null;
        subs.deinit();
        g_allocator.destroy(subs);
        g_routing_subs = null;
    }
    logging.info("routing subscriptions cleaned up", .{});

    if (g_peaks_cache) |p_cache| {
        logging.info("cleaning up peaks cache", .{});
        p_cache.deinit();
        g_allocator.destroy(p_cache);
        g_peaks_cache = null;
    }
    logging.info("peaks cache cleaned up", .{});

    if (g_guid_cache) |cache| {
        logging.info("cleaning up GUID cache", .{});
        commands.g_ctx.guid_cache = null;
        cache.deinit();
        g_allocator.destroy(cache);
        g_guid_cache = null;
    }
    logging.info("GUID cache cleaned up", .{});

    if (g_item_cache) |icache| {
        logging.info("cleaning up item GUID cache", .{});
        commands.g_ctx.item_cache = null;
        icache.deinit();
        g_allocator.destroy(icache);
        g_item_cache = null;
    }
    logging.info("item GUID cache cleaned up", .{});

    if (g_shared_state) |state| {
        logging.info("cleaning up shared state", .{});
        state.deinit();
        g_allocator.destroy(state);
        g_shared_state = null;
    }
    logging.info("shared state cleaned up", .{});

    if (g_tiered) |*tiered| {
        logging.info("cleaning up tiered arenas", .{});
        commands.g_ctx.tiered = null; // Clear global reference before deinit
        tiered.deinit(g_allocator);
        g_tiered = null;
    }
    logging.info("tiered arenas cleaned up", .{});

    logging.info("shutdown() complete", .{});
    logging.deinit();
}

// Main entry point - called by REAPER
//
// SAFETY: This is a C-callable entry point. Returns c_int directly (no error union)
// so no Zig errors can escape. Internal operations use orelse/catch for safety.
// Any panics are caught by the custom panic handler (logging.panic).
export fn ReaperPluginEntry(hInstance: ?*anyopaque, rec: ?*reaper.PluginInfo) callconv(.c) c_int {
    _ = hInstance;

    // Null rec means unload
    if (rec == null) {
        shutdown();
        return 0;
    }

    const info = rec.?;

    // Version check
    if (info.caller_version != reaper.PLUGIN_VERSION) {
        return 0;
    }

    // Load REAPER API
    g_api = reaper.Api.load(info) orelse return 0;

    // Save plugin_register for CSurf integration
    g_plugin_register = info.Register;

    // Register deferred initialization timer
    g_api.?.registerTimer(&initTimerCallback);

    return 1;
}

// Re-export tests from modules
test {
    _ = @import("errors.zig");
    _ = @import("ffi.zig");
    _ = @import("logging.zig");
    _ = @import("protocol.zig");
    _ = @import("transport.zig");
    _ = @import("project.zig");
    _ = @import("markers.zig");
    _ = @import("items.zig");
    _ = @import("tracks.zig");
    _ = @import("commands/mod.zig");
    _ = @import("ws_server.zig");
    _ = @import("gesture_state.zig");
    _ = @import("toggle_subscriptions.zig");
}
