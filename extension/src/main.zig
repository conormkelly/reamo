const std = @import("std");
const reaper = @import("reaper.zig");
const transport = @import("transport.zig");
const project = @import("project.zig");
const markers = @import("markers.zig");
const items = @import("items.zig");
const tracks = @import("tracks.zig");
const tempomap = @import("tempomap.zig");
const commands = @import("commands/mod.zig");
const ws_server = @import("ws_server.zig");
const gesture_state = @import("gesture_state.zig");
const toggle_subscriptions = @import("toggle_subscriptions.zig");
const project_notes = @import("project_notes.zig");
const playlist = @import("playlist.zig");
const errors = @import("errors.zig");
const logging = @import("logging.zig");

// Use custom panic handler that flushes log ring buffer before aborting
pub const panic = logging.panic;

// Debug file logging for playlist tick debugging
var g_tick_log_file: ?std.fs.File = null;

fn logTickToFile(comptime fmt: []const u8, args: anytype) void {
    if (g_tick_log_file == null) {
        g_tick_log_file = std.fs.cwd().createFile("playlist_tick.log", .{ .truncate = true }) catch return;
    }
    if (g_tick_log_file) |file| {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
        _ = file.write(msg) catch {};
    }
}

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
var g_server: ?ws_server.Server = null;
var g_port: u16 = 0;
var g_last_transport: transport.State = .{};
var g_last_project: project.State = .{};
var g_last_markers: markers.State = .{};
var g_last_items: items.State = .{};
var g_last_tracks: tracks.State = .{};
var g_last_metering: tracks.MeteringState = .{};
var g_last_tempomap: tempomap.State = .{};
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
        var buf: [512]u8 = undefined;
        if (event.toJson(&buf)) |json| {
            shared_state.broadcast(json);
        }
    }
}

// Timer callback for deferred initialization
// First call does initialization, then immediately switches to processing timer.
// No warmup delays needed since pollInto() avoids large stack allocations.
fn initTimerCallback() callconv(.c) void {
    // First call: do initialization
    if (!g_initialized) {
        g_initialized = true;
        doInitialization();
        return;
    }

    // Initialization done - switch directly to processing timer
    const api = &(g_api orelse return);
    api.unregisterTimer(&initTimerCallback);
    api.registerTimer(&processTimerCallback);
    g_init_complete = true;
    logging.info("Initialization complete, starting processing timer", .{});
}

fn doInitialization() void {

    const api = &(g_api orelse return);
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
    const state = g_allocator.create(ws_server.SharedState) catch {
        logging.err("Failed to allocate shared state", .{});
        return;
    };
    state.* = ws_server.SharedState.init(g_allocator);
    g_shared_state = state;

    // Create gesture state for undo coalescing
    const gestures = g_allocator.create(gesture_state.GestureState) catch {
        logging.err("Failed to allocate gesture state", .{});
        return;
    };
    gestures.* = gesture_state.GestureState.init(g_allocator);
    g_gesture_state = gestures;

    // Create toggle subscriptions state
    const toggles = g_allocator.create(toggle_subscriptions.ToggleSubscriptions) catch {
        logging.err("Failed to allocate toggle subscriptions state", .{});
        return;
    };
    toggles.* = toggle_subscriptions.ToggleSubscriptions.init(g_allocator);
    g_toggle_subs = toggles;
    // Set the global reference in the command handler module
    commands.toggle_state_cmds.g_toggle_subs = toggles;

    // Create project notes subscriptions state
    const notes_subs = g_allocator.create(project_notes.NotesSubscriptions) catch {
        logging.err("Failed to allocate notes subscriptions state", .{});
        return;
    };
    notes_subs.* = project_notes.NotesSubscriptions.init(g_allocator);
    g_notes_subs = notes_subs;
    // Set the global reference in the command handler module
    commands.project_notes_cmds.g_notes_subs = notes_subs;

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

    // WebSocket server will be started in processTimerCallback after startup completes
    // This avoids stack overflow when REAPER shows modal dialogs during startup
    g_server = null;
    g_port = 0;

    // Store port in REAPER's extension state for discovery
    var port_buf: [8]u8 = undefined;
    const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{g_port}) catch "9224";
    api.setExtStateStr("Reamo", "WebSocketPort", port_str);

    // Initialize state caches using RealBackend
    // Use pollInto to avoid large stack allocations during initialization
    var backend = reaper.RealBackend{ .inner = api };
    g_last_transport = transport.State.poll(&backend); // Small, OK on stack
    g_last_project = project.State.poll(&backend); // Small, OK on stack
    g_last_markers.pollInto(&backend); // ~95KB - use pollInto
    g_last_items.pollInto(&backend); // ~600KB - use pollInto
    g_last_tracks.pollInto(&backend); // ~2.5MB - use pollInto
    g_last_tempomap = tempomap.State.poll(&backend); // Small, OK on stack

    // Load playlist state from ProjExtState
    g_playlist_state.loadAll(&backend);
    g_last_playlist = g_playlist_state;
    logging.info("Loaded {d} playlists from project", .{g_playlist_state.playlist_count});
    logging.info("Initialization complete, waiting for warmup", .{});
}

// Static buffers to reduce stack usage in processTimerCallback
// These are large and would overflow the stack when called from deep event loops
const StaticBuffers = struct {
    var snapshot_transport: [512]u8 = undefined;
    var snapshot_project: [512]u8 = undefined;
    var snapshot_markers: [8192]u8 = undefined;
    var snapshot_regions: [8192]u8 = undefined;
    var snapshot_tracks: [16384]u8 = undefined;
    var snapshot_items: [32768]u8 = undefined;
    var snapshot_tempo: [4096]u8 = undefined;
    var snapshot_playlist: [8192]u8 = undefined;
    var transport_buf: [512]u8 = undefined;
    var transport_tick: [128]u8 = undefined;
    var tracks_buf: [16384]u8 = undefined;
    var toggles: [2048]u8 = undefined;
    var playlist_buf: [8192]u8 = undefined;
    var project_buf: [1024]u8 = undefined;
    var markers_buf: [8192]u8 = undefined;
    var regions_buf: [8192]u8 = undefined;
    var items_buf: [32768]u8 = undefined;
    var tempomap_buf: [4096]u8 = undefined;
    var notes: [256]u8 = undefined;
};

// Compile-time size assertions to catch regressions
// These structs are stored in static memory to avoid stack overflow
// If any exceed the threshold, consider redesigning with smaller inline arrays
comptime {
    const MAX_STATE_SIZE = 4 * 1024 * 1024; // 4MB threshold warning
    if (@sizeOf(tracks.State) > MAX_STATE_SIZE) {
        @compileError("tracks.State exceeds 4MB - consider reducing MAX_TRACKS or MAX_FX_PER_TRACK");
    }
    if (@sizeOf(markers.State) > MAX_STATE_SIZE) {
        @compileError("markers.State exceeds 4MB - consider reducing MAX_MARKERS or MAX_REGIONS");
    }
    if (@sizeOf(items.State) > MAX_STATE_SIZE) {
        @compileError("items.State exceeds 4MB - consider reducing MAX_ITEMS");
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

    // Current poll states (used for change detection)
    var cur_transport: transport.State = .{};
    var cur_project: project.State = .{};
    var cur_markers: markers.State = .{};
    var cur_tracks: tracks.State = .{};
    var cur_items: items.State = .{};
    var cur_tempomap: tempomap.State = .{};
    var cur_metering: tracks.MeteringState = .{};

    // Small arrays that still add up
    var disconnected_buf: [16]usize = undefined;
    var flush_buf: [16]gesture_state.ControlId = undefined;
    var timeout_buf: [16]gesture_state.ControlId = undefined;
    var snapshot_clients: [16]usize = undefined;
};

// Main processing timer - calls doProcessing() directly.
// No warmup delays needed since pollInto() avoids large stack allocations.
fn processTimerCallback() callconv(.c) void {
    doProcessing();
}

// The actual processing logic
// IMPORTANT: This function uses ProcessingState and pollInto() to avoid stack overflow
fn doProcessing() void {
    // Safety check - don't run until init is complete
    if (!g_init_complete) {
        return;
    }

    const api = &(g_api orelse return);
    const shared_state = g_shared_state orelse return;

    // Deferred WebSocket server startup - wait a moment for REAPER UI to settle
    if (!g_ws_started and g_frame_counter >= WS_START_DELAY_FRAMES) {
        g_ws_started = true;
        logging.info("Starting WebSocket server (deferred)...", .{});

        const result = ws_server.startWithPortRetry(g_allocator, shared_state, DEFAULT_PORT, MAX_PORT_ATTEMPTS) catch {
            logging.err("Could not bind to ports 9224-9233", .{});
            return;
        };
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
                    api.csurfFlushUndo(true);
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
        }
    }

    // Check for gesture timeouts (safety net for missed gesture/end commands)
    if (g_gesture_state) |gestures| {
        const timeout_count = gestures.checkTimeouts(&ProcessingState.timeout_buf);
        if (timeout_count > 0) {
            logging.info("Flushing {d} timed-out gestures", .{timeout_count});
            api.csurfFlushUndo(true);
        }
    }

    // Send initial state snapshot to newly connected clients
    // Using ProcessingState for all state structs to avoid stack overflow
    const snapshot_count = shared_state.popClientsNeedingSnapshot(&ProcessingState.snapshot_clients);
    if (snapshot_count > 0) {
        // Get current state for all domains - use pollInto for large structs
        ProcessingState.snap_transport = transport.State.poll(&backend); // Small
        ProcessingState.snap_project = project.State.poll(&backend); // Small
        ProcessingState.snap_markers.pollInto(&backend); // ~95KB
        ProcessingState.snap_tracks.pollInto(&backend); // ~2.5MB
        ProcessingState.snap_tempomap = tempomap.State.poll(&backend); // Small
        ProcessingState.snap_items.pollInto(&backend); // ~600KB

        // Send to each new client
        for (ProcessingState.snapshot_clients[0..snapshot_count]) |client_id| {
            // Transport
            if (ProcessingState.snap_transport.toJson(&StaticBuffers.snapshot_transport)) |json| {
                shared_state.sendToClient(client_id, json);
            }
            // Project (undo/redo state)
            if (ProcessingState.snap_project.toJson(&StaticBuffers.snapshot_project)) |json| {
                shared_state.sendToClient(client_id, json);
            }
            // Markers
            if (ProcessingState.snap_markers.markersToJson(&StaticBuffers.snapshot_markers)) |json| {
                shared_state.sendToClient(client_id, json);
            }
            // Regions
            if (ProcessingState.snap_markers.regionsToJson(&StaticBuffers.snapshot_regions)) |json| {
                shared_state.sendToClient(client_id, json);
            }
            // Tracks (without metering for initial snapshot)
            if (ProcessingState.snap_tracks.toJson(&StaticBuffers.snapshot_tracks, null)) |json| {
                shared_state.sendToClient(client_id, json);
            }
            // Items
            if (ProcessingState.snap_items.itemsToJson(&StaticBuffers.snapshot_items)) |json| {
                shared_state.sendToClient(client_id, json);
            }
            // Tempo map
            if (ProcessingState.snap_tempomap.toJson(&StaticBuffers.snapshot_tempo)) |json| {
                shared_state.sendToClient(client_id, json);
            }
            // Playlist (cue list)
            if (g_playlist_state.toJson(&StaticBuffers.snapshot_playlist, g_last_markers.regions[0..g_last_markers.region_count])) |json| {
                shared_state.sendToClient(client_id, json);
            }
        }
    }

    // Increment frame counter for tiered polling
    g_frame_counter +%= 1;

    // ========================================================================
    // HIGH TIER (30Hz) - Transport, Tracks, Metering
    // These need real-time responsiveness for playhead and fader movements
    // ========================================================================

    // Poll transport state and broadcast changes
    // Use lightweight tick when only position changed during playback
    ProcessingState.cur_transport = transport.State.poll(&backend);
    const current_transport = &ProcessingState.cur_transport;

    if (!current_transport.eql(g_last_transport)) {
        const state_changed = !current_transport.stateOnlyEql(g_last_transport);
        const is_playing = transport.PlayState.isPlaying(current_transport.play_state);

        if (state_changed) {
            // State changed (play/pause, BPM, time sig, etc.) - send full transport
            if (current_transport.toJson(&StaticBuffers.transport_buf)) |json| {
                shared_state.broadcast(json);
            }
        } else if (is_playing) {
            // Only position changed during playback - send lightweight tick
            if (current_transport.toTickJson(&StaticBuffers.transport_tick)) |json| {
                shared_state.broadcast(json);
            }
        } else {
            // Stopped and only position changed (cursor moved) - send full transport
            // This is infrequent so full context is fine
            if (current_transport.toJson(&StaticBuffers.transport_buf)) |json| {
                shared_state.broadcast(json);
            }
        }
        g_last_transport = current_transport.*;
    }

    // Poll tracks and metering, broadcast changes (HIGH TIER - needs smooth fader/meter updates)
    // Use pollInto to avoid ~2.5MB stack allocation
    ProcessingState.cur_tracks.pollInto(&backend);

    // Preserve FX and Send data which is polled at MEDIUM_TIER rate (5Hz), not every frame
    // FX/Send data is updated in g_last_tracks by MEDIUM_TIER polling, so copy it forward
    for (0..@min(ProcessingState.cur_tracks.count, g_last_tracks.count)) |i| {
        ProcessingState.cur_tracks.tracks[i].fx = g_last_tracks.tracks[i].fx;
        ProcessingState.cur_tracks.tracks[i].fx_count = g_last_tracks.tracks[i].fx_count;
        ProcessingState.cur_tracks.tracks[i].sends = g_last_tracks.tracks[i].sends;
        ProcessingState.cur_tracks.tracks[i].send_count = g_last_tracks.tracks[i].send_count;
    }
    ProcessingState.cur_metering.pollInto(api);

    // Broadcast if tracks changed OR if we have active metering
    // (metering values change constantly so we always send when metering is active)
    const tracks_changed = !ProcessingState.cur_tracks.eql(&g_last_tracks);
    const has_metering = ProcessingState.cur_metering.hasData();

    if (tracks_changed or has_metering) {
        const metering_ptr: ?*const tracks.MeteringState = if (has_metering) &ProcessingState.cur_metering else null;
        if (ProcessingState.cur_tracks.toJson(&StaticBuffers.tracks_buf, metering_ptr)) |json| {
            shared_state.broadcast(json);
        }
    }
    g_last_tracks = ProcessingState.cur_tracks;
    g_last_metering = ProcessingState.cur_metering;

    // Poll toggle state subscriptions and broadcast changes (HIGH TIER - but only when subscribed)
    if (g_toggle_subs) |toggles| {
        if (toggles.hasSubscriptions()) {
            var changes = toggles.poll(api);
            defer changes.deinit();

            if (changes.count() > 0) {
                if (toggle_subscriptions.ToggleSubscriptions.changesToJson(&changes, &StaticBuffers.toggles)) |json| {
                    shared_state.broadcast(json);
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
            if (g_playlist_state.toJson(&StaticBuffers.playlist_buf, g_last_markers.regions[0..g_last_markers.region_count])) |json| {
                shared_state.broadcast(json);
            }
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
                for (g_last_markers.regions[0..g_last_markers.region_count]) |*r| {
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
                            for (g_last_markers.regions[0..g_last_markers.region_count]) |*r| {
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

                    // Tick the engine
                    const prev_pos = g_playlist_state.engine.prev_pos;
                    const loops_rem = g_playlist_state.engine.loops_remaining;
                    const iter = g_playlist_state.engine.current_loop_iteration;
                    const pending = g_playlist_state.engine.next_loop_pending;

                    // Calculate bar length for non-contiguous transition timing
                    // bar_length = beats_per_bar * seconds_per_beat
                    const bpm = current_transport.bpm;
                    const beats_per_bar = current_transport.time_sig_num;
                    const bar_length = if (bpm > 0) beats_per_bar * (60.0 / bpm) else 2.0;

                    logTickToFile("TICK: pos={d:.3} prev={d:.3} region=[{d:.3},{d:.3}] loops_rem={d} iter={d} pending={}", .{
                        current_pos, prev_pos, region_start, region_end, loops_rem, iter, pending,
                    });

                    const action = g_playlist_state.engine.tick(
                        current_pos,
                        region_end,
                        region_start,
                        next_entry,
                        p.entry_count,
                        bar_length,
                    );

                    // Log action result
                    switch (action) {
                        .none => {},
                        .broadcast_state => logTickToFile("  -> ACTION: broadcast_state (loops_rem now {d})", .{g_playlist_state.engine.loops_remaining}),
                        .setup_native_loop => |info| logTickToFile("  -> ACTION: setup_native_loop [{d:.3},{d:.3}]", .{ info.region_start, info.region_end }),
                        .stop => logTickToFile("  -> ACTION: stop", .{}),
                        .seek_to => |pos| logTickToFile("  -> ACTION: seek_to {d:.3}", .{pos}),
                    }

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
                            if (g_playlist_state.toJson(&StaticBuffers.playlist_buf, g_last_markers.regions[0..g_last_markers.region_count])) |json| {
                                shared_state.broadcast(json);
                            }
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
                        for (g_last_markers.regions[0..g_last_markers.region_count]) |*r| {
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
                    if (g_playlist_state.toJson(&StaticBuffers.playlist_buf, g_last_markers.regions[0..g_last_markers.region_count])) |json| {
                        shared_state.broadcast(json);
                    }
                }
            }
        }
    }

    // ========================================================================
    // MEDIUM TIER (5Hz) - Project state, Markers, Regions, Items
    // These change less frequently and don't need instant feedback
    // All State structs stored in ProcessingState to avoid stack overflow
    // ========================================================================
    if (g_frame_counter % MEDIUM_TIER_INTERVAL == 0) {
        // Poll project state (undo/redo) and broadcast changes
        ProcessingState.cur_project = project.State.poll(&backend);

        // Check for project identity change (tab switch or different file in same tab)
        if (ProcessingState.cur_project.projectChanged(&g_last_project)) {
            logging.info("Project changed: {s}", .{
                if (ProcessingState.cur_project.projectName().len > 0) ProcessingState.cur_project.projectName() else "(Unsaved)",
            });

            // Stop playlist engine if playing
            if (g_playlist_state.engine.isActive()) {
                _ = g_playlist_state.engine.stop();
                backend.clearLoopPoints();
                logging.info("Stopped playlist engine due to project change", .{});
            }

            // Reload playlists from new project's ProjExtState
            g_playlist_state.reset();
            g_playlist_state.loadAll(&backend);
            logging.info("Loaded {d} playlists from new project", .{g_playlist_state.playlist_count});

            // Broadcast updated playlist state
            // Note: g_last_markers still has old project data, pass null - next tick will have accurate regions
            if (g_playlist_state.toJson(&StaticBuffers.playlist_buf, null)) |json| {
                shared_state.broadcast(json);
            }
            g_last_playlist = g_playlist_state;
        }

        if (!ProcessingState.cur_project.eql(&g_last_project)) {
            if (ProcessingState.cur_project.toJson(&StaticBuffers.project_buf)) |json| {
                shared_state.broadcast(json);
            }
            g_last_project = ProcessingState.cur_project;
        }

        // Poll markers/regions and broadcast changes - use pollInto for ~95KB struct
        ProcessingState.cur_markers.pollInto(&backend);
        if (ProcessingState.cur_markers.markersChanged(&g_last_markers)) {
            if (ProcessingState.cur_markers.markersToJson(&StaticBuffers.markers_buf)) |json| {
                shared_state.broadcast(json);
            }
        }
        if (ProcessingState.cur_markers.regionsChanged(&g_last_markers)) {
            if (ProcessingState.cur_markers.regionsToJson(&StaticBuffers.regions_buf)) |json| {
                shared_state.broadcast(json);
            }
        }
        g_last_markers = ProcessingState.cur_markers;

        // Poll items and broadcast changes - use pollInto for ~600KB struct
        ProcessingState.cur_items.pollInto(&backend);
        if (ProcessingState.cur_items.itemsChanged(&g_last_items)) {
            if (ProcessingState.cur_items.itemsToJson(&StaticBuffers.items_buf)) |json| {
                shared_state.broadcast(json);
            }
        }
        g_last_items = ProcessingState.cur_items;

        // Playlist state change detection
        // (Playlist state is modified by commands, not polled from REAPER)
        if (!g_playlist_state.eql(&g_last_playlist)) {
            if (g_playlist_state.toJson(&StaticBuffers.playlist_buf, g_last_markers.regions[0..g_last_markers.region_count])) |json| {
                shared_state.broadcast(json);
            }
            g_last_playlist = g_playlist_state;
        }

        // Poll FX state for all tracks and update g_last_tracks
        // (FX data is merged into 30Hz track events, not broadcast separately)
        for (0..g_last_tracks.count) |i| {
            const track_idx: c_int = @intCast(i);
            if (backend.getTrackByUnifiedIdx(track_idx)) |track| {
                var t = &g_last_tracks.tracks[i];
                // Get FX count - skip FX API calls if no FX
                const fx_count_raw = backend.trackFxCount(track);
                const fx_count: usize = @intCast(@max(0, @min(fx_count_raw, @as(c_int, @intCast(tracks.MAX_FX_PER_TRACK)))));
                t.fx_count = fx_count;

                for (0..fx_count) |fx_i| {
                    const fx_idx: c_int = @intCast(fx_i);
                    var fx = &t.fx[fx_i];

                    // Get FX name
                    var name_buf: [tracks.MAX_FX_NAME_LEN]u8 = undefined;
                    const name = backend.trackFxGetName(track, fx_idx, &name_buf);
                    const name_len = @min(name.len, tracks.MAX_FX_NAME_LEN);
                    @memcpy(fx.name[0..name_len], name[0..name_len]);
                    fx.name_len = name_len;

                    // Get preset index and count
                    var preset_count: c_int = 0;
                    fx.preset_index = backend.trackFxGetPresetIndex(track, fx_idx, &preset_count);
                    fx.preset_count = preset_count;

                    // Get preset name and modified state
                    var preset_buf: [tracks.MAX_FX_NAME_LEN]u8 = undefined;
                    const preset_info = backend.trackFxGetPreset(track, fx_idx, &preset_buf);
                    const preset_len = @min(preset_info.name.len, tracks.MAX_FX_NAME_LEN);
                    @memcpy(fx.preset_name[0..preset_len], preset_info.name[0..preset_len]);
                    fx.preset_name_len = preset_len;
                    fx.modified = !preset_info.matches_preset;
                }

                // Get send count - skip send API calls if no sends
                const send_count_raw = backend.trackSendCount(track);
                const send_count: usize = @intCast(@max(0, @min(send_count_raw, @as(c_int, @intCast(tracks.MAX_SENDS_PER_TRACK)))));
                t.send_count = send_count;

                for (0..send_count) |send_i| {
                    const send_idx: c_int = @intCast(send_i);
                    var send = &t.sends[send_i];

                    // Get destination name
                    var name_buf: [tracks.MAX_SEND_NAME_LEN]u8 = undefined;
                    const dest_name = backend.trackSendGetDestName(track, send_idx, &name_buf);
                    const name_len = @min(dest_name.len, tracks.MAX_SEND_NAME_LEN);
                    @memcpy(send.dest_name[0..name_len], dest_name[0..name_len]);
                    send.dest_name_len = name_len;

                    // Get send volume, mute, mode
                    send.volume = backend.trackSendGetVolume(track, send_idx);
                    send.muted = backend.trackSendGetMute(track, send_idx);
                    send.mode = backend.trackSendGetMode(track, send_idx);
                }
            }
        }
    }

    // ========================================================================
    // LOW TIER (1Hz) - Tempomap, Project Notes (Phase 2)
    // These rarely change during normal operation
    // ========================================================================
    if (g_frame_counter % LOW_TIER_INTERVAL == 0) {
        // Poll tempo map and broadcast changes (stored in ProcessingState)
        ProcessingState.cur_tempomap = tempomap.State.poll(&backend);
        if (ProcessingState.cur_tempomap.changed(&g_last_tempomap)) {
            if (ProcessingState.cur_tempomap.toJson(&StaticBuffers.tempomap_buf)) |json| {
                shared_state.broadcast(json);
            }
        }
        g_last_tempomap = ProcessingState.cur_tempomap;

        // Poll project notes and broadcast changes (only if subscribers)
        if (g_notes_subs) |notes_subs| {
            if (notes_subs.poll(api)) |change| {
                // Notes changed externally - broadcast to all subscribers
                if (commands.project_notes_cmds.formatChangedEvent(change.hash, &StaticBuffers.notes)) |json| {
                    shared_state.broadcast(json);
                }
            }
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
        commands.toggle_state_cmds.g_toggle_subs = null;
        toggles.deinit();
        g_allocator.destroy(toggles);
        g_toggle_subs = null;
    }
    logging.info("toggle subscriptions cleaned up", .{});

    if (g_notes_subs) |notes| {
        logging.info("cleaning up notes subscriptions", .{});
        commands.project_notes_cmds.g_notes_subs = null;
        notes.deinit();
        g_allocator.destroy(notes);
        g_notes_subs = null;
    }
    logging.info("notes subscriptions cleaned up", .{});

    if (g_shared_state) |state| {
        logging.info("cleaning up shared state", .{});
        state.deinit();
        g_allocator.destroy(state);
        g_shared_state = null;
    }
    logging.info("shared state cleaned up", .{});

    logging.info("shutdown() complete", .{});
    logging.deinit();
}

// Main entry point - called by REAPER
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
