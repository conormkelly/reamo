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
const errors = @import("errors.zig");
const logging = @import("logging.zig");

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
var g_server: ?ws_server.Server = null;
var g_port: u16 = 0;
var g_last_transport: transport.State = .{};
var g_last_project: project.State = .{};
var g_last_markers: markers.State = .{};
var g_last_items: items.State = .{};
var g_last_tracks: tracks.State = .{};
var g_last_metering: tracks.MeteringState = .{};
var g_last_tempomap: tempomap.State = .{};
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
const MEDIUM_TIER_INTERVAL: u32 = 6; // 30Hz / 6 = 5Hz
const LOW_TIER_INTERVAL: u32 = 30; // 30Hz / 30 = 1Hz


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
fn initTimerCallback() callconv(.c) void {
    if (g_initialized) return;
    g_initialized = true;

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

    // Start WebSocket server
    const result = ws_server.startWithPortRetry(g_allocator, state, DEFAULT_PORT, MAX_PORT_ATTEMPTS) catch {
        logging.err("Could not bind to ports 9224-9233", .{});
        return;
    };

    g_server = result.server;
    g_port = result.port;

    // Store port in REAPER's extension state for discovery
    var port_buf: [8]u8 = undefined;
    const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{g_port}) catch "9224";
    api.setExtStateStr("Reamo", "WebSocketPort", port_str);

    // Initialize state caches
    g_last_transport = transport.State.poll(api);
    g_last_project = project.State.poll(api);
    g_last_markers = markers.State.poll(api);
    g_last_items = items.State.poll(api);
    g_last_tracks = tracks.State.poll(api);
    g_last_tempomap = tempomap.State.poll(api);

    logging.info("WebSocket server started on port {d}", .{g_port});

    // Switch to processing timer
    api.unregisterTimer(&initTimerCallback);
    api.registerTimer(&processTimerCallback);

    logging.info("initTimerCallback() complete", .{});
}

// Main processing timer - runs every ~30ms
fn processTimerCallback() callconv(.c) void {
    const api = &(g_api orelse return);
    const shared_state = g_shared_state orelse return;

    // Process pending commands from WebSocket clients
    while (shared_state.popCommand()) |cmd| {
        var command = cmd;
        defer command.deinit();
        commands.dispatch(api, command.client_id, command.data, shared_state, g_gesture_state);
    }

    // Clean up gestures and toggle subscriptions for disconnected clients
    var disconnected_buf: [16]usize = undefined;
    const disconnected_count = shared_state.popDisconnectedClients(&disconnected_buf);
    if (disconnected_count > 0) {
        for (disconnected_buf[0..disconnected_count]) |client_id| {
            // Clean up gestures
            if (g_gesture_state) |gestures| {
                var flush_buf: [16]gesture_state.ControlId = undefined;
                const flush_count = gestures.removeClientFromAll(client_id, &flush_buf);
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
        var timeout_buf: [16]gesture_state.ControlId = undefined;
        const timeout_count = gestures.checkTimeouts(&timeout_buf);
        if (timeout_count > 0) {
            logging.info("Flushing {d} timed-out gestures", .{timeout_count});
            api.csurfFlushUndo(true);
        }
    }

    // Send initial state snapshot to newly connected clients
    var snapshot_clients: [16]usize = undefined;
    const snapshot_count = shared_state.popClientsNeedingSnapshot(&snapshot_clients);
    if (snapshot_count > 0) {
        // Get current state for all domains
        const trans = transport.State.poll(api);
        const proj = project.State.poll(api);
        const mark = markers.State.poll(api);
        const trks = tracks.State.poll(api);
        const tmap = tempomap.State.poll(api);

        // Send to each new client
        for (snapshot_clients[0..snapshot_count]) |client_id| {
            // Transport
            var buf1: [512]u8 = undefined;
            if (trans.toJson(&buf1)) |json| {
                shared_state.sendToClient(client_id, json);
            }
            // Project (undo/redo state)
            var buf_proj: [512]u8 = undefined;
            if (proj.toJson(&buf_proj)) |json| {
                shared_state.sendToClient(client_id, json);
            }
            // Markers
            var buf2: [8192]u8 = undefined;
            if (mark.markersToJson(&buf2)) |json| {
                shared_state.sendToClient(client_id, json);
            }
            // Regions
            var buf3: [8192]u8 = undefined;
            if (mark.regionsToJson(&buf3)) |json| {
                shared_state.sendToClient(client_id, json);
            }
            // Tracks (without metering for initial snapshot)
            var buf4: [16384]u8 = undefined;
            if (trks.toJson(&buf4, null)) |json| {
                shared_state.sendToClient(client_id, json);
            }
            // Items
            var buf5: [32768]u8 = undefined;
            const itms = items.State.poll(api);
            if (itms.itemsToJson(&buf5)) |json| {
                shared_state.sendToClient(client_id, json);
            }
            // Tempo map
            var buf6: [4096]u8 = undefined;
            if (tmap.toJson(&buf6)) |json| {
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
    const current_transport = transport.State.poll(api);
    if (!current_transport.eql(g_last_transport)) {
        const state_changed = !current_transport.stateOnlyEql(g_last_transport);
        const is_playing = transport.PlayState.isPlaying(current_transport.play_state);

        if (state_changed) {
            // State changed (play/pause, BPM, time sig, etc.) - send full transport
            var buf: [512]u8 = undefined;
            if (current_transport.toJson(&buf)) |json| {
                shared_state.broadcast(json);
            }
        } else if (is_playing) {
            // Only position changed during playback - send lightweight tick
            var buf: [128]u8 = undefined;
            if (current_transport.toTickJson(&buf)) |json| {
                shared_state.broadcast(json);
            }
        } else {
            // Stopped and only position changed (cursor moved) - send full transport
            // This is infrequent so full context is fine
            var buf: [512]u8 = undefined;
            if (current_transport.toJson(&buf)) |json| {
                shared_state.broadcast(json);
            }
        }
        g_last_transport = current_transport;
    }

    // Poll tracks and metering, broadcast changes (HIGH TIER - needs smooth fader/meter updates)
    const current_tracks = tracks.State.poll(api);
    const current_metering = tracks.MeteringState.poll(api);

    // Broadcast if tracks changed OR if we have active metering
    // (metering values change constantly so we always send when metering is active)
    const tracks_changed = !current_tracks.eql(&g_last_tracks);
    const has_metering = current_metering.hasData();

    if (tracks_changed or has_metering) {
        var buf: [16384]u8 = undefined; // Large buffer for many tracks
        const metering_ptr: ?*const tracks.MeteringState = if (has_metering) &current_metering else null;
        if (current_tracks.toJson(&buf, metering_ptr)) |json| {
            shared_state.broadcast(json);
        }
    }
    g_last_tracks = current_tracks;
    g_last_metering = current_metering;

    // Poll toggle state subscriptions and broadcast changes (HIGH TIER - but only when subscribed)
    if (g_toggle_subs) |toggles| {
        if (toggles.hasSubscriptions()) {
            var changes = toggles.poll(api);
            defer changes.deinit();

            if (changes.count() > 0) {
                var buf: [2048]u8 = undefined;
                if (toggle_subscriptions.ToggleSubscriptions.changesToJson(&changes, &buf)) |json| {
                    shared_state.broadcast(json);
                }
            }
        }
    }

    // ========================================================================
    // MEDIUM TIER (5Hz) - Project state, Markers, Regions, Items
    // These change less frequently and don't need instant feedback
    // ========================================================================
    if (g_frame_counter % MEDIUM_TIER_INTERVAL == 0) {
        // Poll project state (undo/redo) and broadcast changes
        const current_project = project.State.poll(api);
        if (!current_project.eql(&g_last_project)) {
            var buf: [512]u8 = undefined;
            if (current_project.toJson(&buf)) |json| {
                shared_state.broadcast(json);
            }
            g_last_project = current_project;
        }

        // Poll markers/regions and broadcast changes
        const current_markers = markers.State.poll(api);
        if (current_markers.markersChanged(&g_last_markers)) {
            var buf: [8192]u8 = undefined;
            if (current_markers.markersToJson(&buf)) |json| {
                shared_state.broadcast(json);
            }
        }
        if (current_markers.regionsChanged(&g_last_markers)) {
            var buf: [8192]u8 = undefined;
            if (current_markers.regionsToJson(&buf)) |json| {
                shared_state.broadcast(json);
            }
        }
        g_last_markers = current_markers;

        // Poll items and broadcast changes
        const current_items = items.State.poll(api);
        if (current_items.itemsChanged(&g_last_items)) {
            var buf: [32768]u8 = undefined;
            if (current_items.itemsToJson(&buf)) |json| {
                shared_state.broadcast(json);
            }
        }
        g_last_items = current_items;
    }

    // ========================================================================
    // LOW TIER (1Hz) - Tempomap, Project Notes (Phase 2)
    // These rarely change during normal operation
    // ========================================================================
    if (g_frame_counter % LOW_TIER_INTERVAL == 0) {
        // Poll tempo map and broadcast changes
        const current_tempomap = tempomap.State.poll(api);
        if (current_tempomap.changed(&g_last_tempomap)) {
            var buf: [4096]u8 = undefined;
            if (current_tempomap.toJson(&buf)) |json| {
                shared_state.broadcast(json);
            }
        }
        g_last_tempomap = current_tempomap;

        // Poll project notes and broadcast changes (only if subscribers)
        if (g_notes_subs) |notes_subs| {
            if (notes_subs.poll(api)) |change| {
                // Notes changed externally - broadcast to all subscribers
                var buf: [256]u8 = undefined;
                if (commands.project_notes_cmds.formatChangedEvent(change.hash, &buf)) |json| {
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
