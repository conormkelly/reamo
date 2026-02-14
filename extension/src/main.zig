const std = @import("std");
const reaper = @import("reaper.zig");
const transport = @import("state/transport.zig");
const project = @import("state/project.zig");
const markers = @import("state/markers.zig");
const items = @import("state/items.zig");
const tracks = @import("state/tracks.zig");
const tempomap = @import("state/tempomap.zig");
const fx = @import("state/fx.zig");
const sends = @import("state/sends.zig");
const commands = @import("commands/mod.zig");
const ws_server = @import("server/ws_server.zig");
const http_server = @import("server/http_server.zig");
const gesture_state = @import("server/gesture_state.zig");
const toggle_subscriptions = @import("subscriptions/toggle_subscriptions.zig");
const project_notes = @import("subscriptions/project_notes.zig");
const playlist = @import("state/playlist.zig");
const errors = @import("core/errors.zig");
const logging = @import("core/logging.zig");
const tiered_state = @import("server/tiered_state.zig");
const guid_cache = @import("state/guid_cache.zig");
const item_guid_cache = @import("state/item_guid_cache.zig");
const track_subscriptions = @import("subscriptions/track_subscriptions.zig");
const peaks_subscriptions = @import("subscriptions/peaks_subscriptions.zig");
const routing_subscriptions = @import("subscriptions/routing_subscriptions.zig");
const routing_generator = @import("subscriptions/routing_generator.zig");
const trackfx_subscriptions = @import("subscriptions/trackfx_subscriptions.zig");
const trackfx_generator = @import("subscriptions/trackfx_generator.zig");
const trackfxparam_subscriptions = @import("subscriptions/trackfxparam_subscriptions.zig");
const trackfxparam_generator = @import("subscriptions/trackfxparam_generator.zig");
const tuner_subscriptions = @import("subscriptions/tuner_subscriptions.zig");
const peaks_generator = @import("subscriptions/peaks_generator.zig");
const peaks_cache = @import("subscriptions/peaks_cache.zig");
const peaks_tile = @import("state/peaks_tile.zig");
const track_skeleton = @import("state/track_skeleton.zig");
const csurf = @import("server/csurf.zig");
const csurf_dirty = @import("server/csurf_dirty.zig");
const host_validation = @import("server/host_validation.zig");
const network_action = @import("platform/network_action.zig");
const menu = @import("platform/menu.zig");
const swell = @import("platform/swell.zig");
const fast_timer = @import("platform/fast_timer.zig");
const ztracy = @import("ztracy");
const lua_peak_bridge = @import("platform/lua_peak_bridge.zig");
const subscription_polling = @import("server/subscription_polling.zig");
const tier_polling = @import("server/tier_polling.zig");
const playlist_tick = @import("server/playlist_tick.zig");
const client_management = @import("server/client_management.zig");

// Use custom panic handler that flushes log ring buffer before aborting
pub const panic = logging.panic;

// Suppress websocket library debug spam - only show warnings and errors
pub const std_options: std.Options = .{
    .log_level = .warn,
};

// Configuration
const FALLBACK_PORT: u16 = 9224;
const MAX_PORT_ATTEMPTS: u8 = 10;
var g_configured_port: u16 = FALLBACK_PORT; // Updated from ExtState on startup

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
var g_trackfx_subs: ?*trackfx_subscriptions.TrackFxSubscriptions = null;
var g_trackfxparam_subs: ?*trackfxparam_subscriptions.TrackFxParamSubscriptions = null;
var g_tuner_subs: ?*tuner_subscriptions.TunerSubscriptions = null;
var g_peaks_cache: ?*peaks_cache.PeaksCache = null;
var g_tile_cache: ?*peaks_tile.TileCache = null;
var g_csurf: ?*csurf.ControlSurface = null;
var g_plugin_register: ?*const fn ([*:0]const u8, ?*anyopaque) callconv(.c) c_int = null;
var g_dirty_flags: ?*csurf_dirty.DirtyFlags = null;

// Track skeleton state for LOW tier change detection
var g_last_skeleton: track_skeleton.State = .{};
var g_last_skeleton_buf: []track_skeleton.SkeletonTrack = &.{};

// CSurf: Hash-based track change detection
var g_prev_tracks_hash: u64 = 0;
var g_last_drift_log_time: i64 = 0; // Rate-limit drift warnings (max 1/sec)
var g_http_server: ?http_server.HttpServer = null;
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

// Fast timer for 100Hz command queue processing (reduces latency from ~19ms to ~8ms)
var g_fast_timer: fast_timer.FastTimer = .{};

// Fast timer jitter tracking (for debugging)
var g_fast_timer_last_tick: i64 = 0;
var g_fast_timer_call_count: u64 = 0;
var g_fast_timer_slip_count: u64 = 0; // Intervals > 15ms
var g_fast_timer_max_interval: i64 = 0;
var g_fast_timer_total_interval: i64 = 0; // For average calculation

// Hot reload detection
var g_html_path_buf: [512]u8 = undefined;
var g_html_path: ?[]const u8 = null;
var g_web_dir_buf: [512]u8 = undefined;
var g_web_dir: ?[]const u8 = null;
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
        const web_dir = std.fmt.bufPrint(&g_web_dir_buf, "{s}/reaper_www_root/web", .{res_path}) catch null;
        g_web_dir = web_dir;
        const written = std.fmt.bufPrint(&g_html_path_buf, "{s}/reaper_www_root/web/index.html", .{res_path}) catch null;
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

    // Create track FX subscriptions state (per-track FX chain)
    const trackfx_subs = try g_allocator.create(trackfx_subscriptions.TrackFxSubscriptions);
    trackfx_subs.* = trackfx_subscriptions.TrackFxSubscriptions.init(g_allocator);
    g_trackfx_subs = trackfx_subs;
    commands.g_ctx.trackfx_subs = trackfx_subs;

    // Create track FX parameter subscriptions state (per-FX param values)
    const trackfxparam_subs = try g_allocator.create(trackfxparam_subscriptions.TrackFxParamSubscriptions);
    trackfxparam_subs.* = trackfxparam_subscriptions.TrackFxParamSubscriptions.init(g_allocator);
    g_trackfxparam_subs = trackfxparam_subs;
    commands.g_ctx.trackfxparam_subs = trackfxparam_subs;

    // Create tuner subscriptions state (chromatic tuner via JSFX)
    const tuner_subs = try g_allocator.create(tuner_subscriptions.TunerSubscriptions);
    tuner_subs.* = tuner_subscriptions.TunerSubscriptions.init(g_allocator);
    g_tuner_subs = tuner_subs;
    commands.g_ctx.tuner_subs = tuner_subs;

    // Create peaks cache for LRU caching of waveform data
    const p_cache = try g_allocator.create(peaks_cache.PeaksCache);
    p_cache.* = peaks_cache.PeaksCache.init(g_allocator);
    g_peaks_cache = p_cache;

    // Create tile cache for LOD-based waveform tiles
    const t_cache = try g_allocator.create(peaks_tile.TileCache);
    t_cache.* = peaks_tile.TileCache.init(g_allocator);
    g_tile_cache = t_cache;

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

    // Initialize DirtyFlags for CSurf push-based polling
    // Must be created before CSurf registration so callbacks can access it
    const dirty_flags = try g_allocator.create(csurf_dirty.DirtyFlags);
    dirty_flags.* = .{};
    g_dirty_flags = dirty_flags;

    // Generate session token (injected into HTML via <meta> tag by HTTP server)
    var token_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&token_bytes);
    const token_hex = std.fmt.bytesToHex(token_bytes, .lower);
    state.setToken(&token_hex);
    logging.info("Session token generated", .{});

    // Initialize CSurf (Control Surface) for push-based callbacks
    // Only active when built with -Dcsurf=true
    if (csurf.enabled) {
        if (g_plugin_register) |plugin_register| {
            const cs = try g_allocator.create(csurf.ControlSurface);

            // Wire dirty flags and GUID cache to CSurf module BEFORE init
            // This allows callbacks to set dirty flags as soon as they start firing
            // (CSurf callbacks can fire during REAPER startup, before our timer runs)
            csurf.setDirtyFlagsAndCache(g_dirty_flags, g_guid_cache);

            // CRITICAL: init() takes *Self to ensure stable heap pointer for callbacks.
            // Previously init() returned by value, causing a dangling stack pointer bug.
            cs.init(plugin_register) catch |err| {
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

    // Register Lua Peak Bridge API (works even without CSurf)
    if (g_plugin_register) |plugin_register| {
        lua_peak_bridge.LuaPeakBridge.register(plugin_register);
    }

    // Initialize network action handlers (state only — menu registration already done in ReaperPluginEntry)
    if (g_api) |*inner_api| {
        network_action.init(inner_api.showMessageBox, inner_api.getMainHwnd_fn, inner_api.getUserInputs, inner_api.setExtState, inner_api.resourcePath());
    }

    // Initialize Lua script for peak fetching (must be after API registration)
    // Wire up the module-level g_api reference first
    lua_peak_bridge.g_api = if (g_api) |*bridge_api| bridge_api else null;
    if (g_api) |*lua_api| {
        if (lua_peak_bridge.LuaPeakBridge.initScript(lua_api)) {
            // Register the bridge function with peaks_generator
            peaks_generator.setLuaBridgeFn(&lua_peak_bridge.LuaPeakBridge.bridgeFetchAdapter);
        }
    }

    // Read configured port from ExtState (persisted across sessions)
    if (api.getExtStateValue("Reamo", "ServerPort")) |port_str| {
        if (std.fmt.parseInt(u16, port_str, 10)) |port| {
            if (port >= 1024) {
                g_configured_port = port;
                logging.info("Configured port from ExtState: {d}", .{port});
            }
        } else |_| {}
    }

    // Auto-detect machine hostname and add to allowed hosts for DNS rebinding protection.
    // Also allows any .local hostname (mDNS = LAN-only by definition).
    // Users can add custom hostnames (Tailscale, VPN) via ExtState "Reamo/AllowedHosts".
    {
        var hostname_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        const hostname = std.posix.gethostname(&hostname_buf) catch null;
        if (hostname) |name| {
            _ = host_validation.addAllowedHost(name);
            logging.info("Auto-detected hostname: {s}", .{name});

            // Also add hostname.local for mDNS (redundant with .local suffix match,
            // but makes getAllowedHosts() output clearer for the user dialog)
            var local_buf: [std.posix.HOST_NAME_MAX + 6]u8 = undefined;
            if (name.len + 6 <= local_buf.len) {
                @memcpy(local_buf[0..name.len], name);
                @memcpy(local_buf[name.len..][0..6], ".local");
                _ = host_validation.addAllowedHost(local_buf[0 .. name.len + 6]);
            }
        }
    }

    // Read user-configured allowed hosts from ExtState (comma-separated)
    if (api.getExtStateValue("Reamo", "AllowedHosts")) |hosts_str| {
        if (hosts_str.len > 0) {
            var iter = std.mem.splitScalar(u8, hosts_str, ',');
            while (iter.next()) |entry| {
                const trimmed = std.mem.trim(u8, entry, " ");
                if (trimmed.len > 0) {
                    if (!host_validation.addAllowedHost(trimmed)) {
                        logging.warn("Allowed hosts list full, skipping: {s}", .{trimmed});
                        break;
                    }
                }
            }
            logging.info("Loaded {d} allowed hosts from ExtState", .{host_validation.getAllowedHostCount()});
        }
    }

    // HTTP+WS server will be started in processTimerCallback after startup completes
    // This avoids stack overflow when REAPER shows modal dialogs during startup
    g_http_server = null;
    g_port = 0;

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

/// 100Hz command queue timer callback
/// Called directly by OS timer - runs on main thread.
/// Drains ALL pending commands for reduced latency (~8ms vs ~19ms at 30Hz).
///
/// SAFETY: This is a C-callable entry point.
fn commandQueueTimerCallback() callconv(.c) void {
    // Jitter tracking
    const now = std.time.milliTimestamp();
    if (g_fast_timer_last_tick != 0) {
        const delta = now - g_fast_timer_last_tick;
        g_fast_timer_total_interval += delta;

        if (delta > g_fast_timer_max_interval) {
            g_fast_timer_max_interval = delta;
        }

        // Log slips (> 15ms when expecting 10ms)
        if (delta > 15) {
            g_fast_timer_slip_count += 1;
            logging.debug("FastTimer slip: {}ms (slip #{}, call #{})", .{ delta, g_fast_timer_slip_count, g_fast_timer_call_count });
        }
    }
    g_fast_timer_last_tick = now;
    g_fast_timer_call_count += 1;

    // Log stats every 1000 calls (~10 seconds at 100Hz)
    if (g_fast_timer_call_count % 1000 == 0 and g_fast_timer_call_count > 0) {
        const avg = @divTrunc(g_fast_timer_total_interval, @as(i64, @intCast(g_fast_timer_call_count)));
        logging.debug("FastTimer stats: calls={}, slips={}, avg={}ms, max={}ms", .{
            g_fast_timer_call_count,
            g_fast_timer_slip_count,
            avg,
            g_fast_timer_max_interval,
        });
    }

    const api = &(g_api orelse return);
    const shared_state = g_shared_state orelse return;
    var backend = reaper.RealBackend{ .inner = api };

    // Drain all pending commands
    while (shared_state.popCommand()) |cmd| {
        var command = cmd;
        defer command.deinit();
        commands.dispatch(&backend, command.client_id, command.data, shared_state, g_gesture_state, &g_playlist_state);
    }
}

// Helper to compare track slices for change detection
fn tracksSliceEql(a: []const tracks.Track, b: []const tracks.Track) bool {
    if (a.len != b.len) return false;
    for (a, b) |*track_a, *track_b| {
        if (!track_a.eql(track_b.*)) return false;
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

    // Create backend for state polling (needed early for skeleton rebuild)
    var backend = reaper.RealBackend{ .inner = api };

    // ========================================================================
    // CONSUME DIRTY FLAGS (every frame, before any tier logic)
    // CSurf callbacks set these flags; we consume and clear them here.
    // This enables O(changes) polling instead of O(n) unconditional polling.
    // ========================================================================
    var force_skeleton = false;
    var force_transport = false;
    var force_markers = false;
    var force_tempo = false;

    // CSurf: Track dirty flags for instant latency response
    var csurf_track_dirty = false;
    var csurf_fx_dirty: csurf_dirty.TrackDirtyResult = .{ .bits = std.StaticBitSet(csurf_dirty.MAX_TRACKS).initEmpty(), .all = false };
    var csurf_sends_dirty: csurf_dirty.TrackDirtyResult = .{ .bits = std.StaticBitSet(csurf_dirty.MAX_TRACKS).initEmpty(), .all = false };

    if (csurf.enabled) {
        if (g_dirty_flags) |flags| {
            // Consume global dirty flags (reads and clears atomically)
            force_skeleton = csurf_dirty.DirtyFlags.consumeGlobal(&flags.skeleton_dirty);
            force_transport = csurf_dirty.DirtyFlags.consumeGlobal(&flags.transport_dirty);
            force_markers = csurf_dirty.DirtyFlags.consumeGlobal(&flags.markers_dirty);
            force_tempo = csurf_dirty.DirtyFlags.consumeGlobal(&flags.tempo_dirty);

            // Consume per-track dirty flags
            // Note: We don't filter by dirty indices - we still poll all subscribed tracks
            // to maintain hash-based change detection. Dirty flags are used to:
            // 1. Force broadcast even if hash unchanged (instant latency response)
            // 2. Detect drift when hash changes without dirty flags (missed callback)
            const track_dirty_result = flags.consumeTrackDirty();
            csurf_track_dirty = track_dirty_result.all or track_dirty_result.bits.count() > 0;

            // Consume FX and sends dirty flags for FX/routing subscriptions
            csurf_fx_dirty = flags.consumeFxDirty();
            csurf_sends_dirty = flags.consumeSendsDirty();
        }
    }

    // ========================================================================
    // IMMEDIATE SKELETON REBUILD (when dirty, not tier-bound)
    // This minimizes the window where CSurf track callbacks are dropped
    // because reverse_map is invalid (< 33ms vs up to 1s if tier-bound).
    // ========================================================================
    if (force_skeleton) {
        if (g_guid_cache) |cache| {
            cache.rebuild(&backend) catch |err| {
                logging.err("CSurf skeleton rebuild failed: {s}", .{@errorName(err)});
            };
            // Mark reverse_map as valid so track callbacks work again
            if (g_dirty_flags) |flags| {
                flags.reverse_map_valid = true;
            }
            logging.debug("CSurf triggered skeleton rebuild", .{});
        }
    }

    // Deferred HTTP+WS server startup - wait a moment for REAPER UI to settle
    if (!g_ws_started and g_frame_counter >= WS_START_DELAY_FRAMES) {
        g_ws_started = true;
        logging.info("Starting HTTP+WS server (deferred)...", .{});

        // Try ports 9224-9233
        var attempt: u8 = 0;
        var started = false;
        while (attempt < MAX_PORT_ATTEMPTS) : (attempt += 1) {
            const port = g_configured_port + @as(u16, attempt);
            var srv = http_server.HttpServer.init(g_allocator, shared_state, port, g_html_path, g_web_dir) catch |err| {
                logging.debug("http_server: port {d} init failed: {s}", .{ port, @errorName(err) });
                continue;
            };
            srv.start() catch |err| {
                logging.debug("http_server: port {d} listen failed: {s}", .{ port, @errorName(err) });
                srv.deinit();
                continue;
            };
            g_http_server = srv;
            g_port = port;
            started = true;
            break;
        }

        if (!started) {
            logging.err("http_server: all ports {d}-{d} failed", .{ g_configured_port, g_configured_port + MAX_PORT_ATTEMPTS - 1 });
            return error.AllPortsFailed;
        }

        // Update network action module with actual port and wire restart callback
        network_action.setPort(g_port);
        network_action.setRestartCallback(&restartServer);

        logging.info("HTTP+WS server started on port {d}", .{g_port});

        // Start 100Hz command queue timer for reduced latency
        g_fast_timer.start(&commandQueueTimerCallback) catch |err| {
            logging.warn("FastTimer failed to start: {s} - falling back to 30Hz", .{@errorName(err)});
        };
    }

    // Process pending commands from WebSocket clients (fallback if fast timer not running)
    // Normally the 100Hz timer drains the queue; this is defensive fallback
    if (!g_fast_timer.isRunning()) {
        while (shared_state.popCommand()) |cmd| {
            var command = cmd;
            defer command.deinit();
            commands.dispatch(&backend, command.client_id, command.data, shared_state, g_gesture_state, &g_playlist_state);
        }
    }

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
        .tuner_subs = g_tuner_subs,
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

    // Increment frame counter for tiered polling
    g_frame_counter +%= 1;

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

        // Poll tuner subscriptions (chromatic tuner via JSFX)
        if (g_tuner_subs) |tuner_subs| {
            try subscription_polling.pollTunerSubscriptions(&poll_ctx, tuner_subs);
        }
    }

    // ========================================================================
    // PLAYLIST ENGINE TICK - Extracted to playlist_tick.zig for testability
    // ========================================================================

    // Build playlist tick context
    const playlist_ctx = playlist_tick.PlaylistTickContext{
        .playlist_state = &g_playlist_state,
        .transport_state = current_transport,
        .regions = g_last_markers.regions,
        .tiered = tiered,
        .shared_state = shared_state,
    };

    // Sync with external transport changes
    _ = playlist_tick.syncWithTransport(&playlist_ctx, &backend);

    // Advance playlist engine
    playlist_tick.tick(&playlist_ctx, &backend);

    // MEDIUM tier (5Hz) - includes immediate markers poll if force_markers
    try tier_polling.pollMediumTier(&tier_ctx, &mutable, force_markers, g_frame_counter);

    // LOW tier (1Hz) - includes immediate tempo poll if force_tempo
    try tier_polling.pollLowTier(&tier_ctx, &mutable, force_tempo, g_frame_counter, &StaticBuffers.notes);

    // ========================================================================
    // HEARTBEAT SAFETY NET (every 2 seconds = 60 frames at 30Hz)
    // CSurf can miss events (rapid changes, ReaScript, undo/redo).
    // This forces full comparison of all subscribed state to catch drift.
    // SWS-validated interval from research/REAPER_CSURF_API_BEHAVIOUR.md
    // ========================================================================
    if (csurf.enabled and g_frame_counter % csurf_dirty.SAFETY_POLL_INTERVAL == 0) {
        if (g_dirty_flags) |flags| {
            // Force re-broadcast even if hash unchanged - catches any accumulated drift
            flags.setAllTracksDirty();
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
                    // Refresh cached HTML in HTTP server so next request gets new content
                    if (g_http_server) |*server| {
                        server.reloadHtml(path);
                    }
                    shared_state.broadcast("{\"type\":\"event\",\"event\":\"reload\"}");
                    logging.debug("Broadcast reload event", .{});
                }
            } else |err| {
                logging.warn("Stat failed: {s}", .{@errorName(err)});
            }
        }
    }
}

/// Restart the HTTP server on a new port.
/// Called from network_action when user changes port via menu.
fn restartServer(new_port: u16) void {
    const shared_state = g_shared_state orelse return;

    // Stop existing server
    if (g_http_server) |*server| {
        logging.info("Restarting server: stopping on port {d}...", .{g_port});
        server.deinit();
        g_http_server = null;
    }

    // Start on new port
    var srv = http_server.HttpServer.init(g_allocator, shared_state, new_port, g_html_path, g_web_dir) catch |err| {
        logging.err("restartServer: init failed on port {d}: {s}", .{ new_port, @errorName(err) });
        return;
    };
    srv.start() catch |err| {
        logging.err("restartServer: listen failed on port {d}: {s}", .{ new_port, @errorName(err) });
        srv.deinit();
        return;
    };

    g_http_server = srv;
    g_port = new_port;
    g_configured_port = new_port;
    network_action.setPort(new_port);

    logging.info("Server restarted on port {d}", .{new_port});
}

// Shutdown - called when REAPER unloads the extension
fn shutdown() void {
    logging.info("shutdown() called", .{});

    // Stop fast timer first (before REAPER timer)
    g_fast_timer.stop();

    if (g_api) |*api| {
        api.unregisterTimer(&processTimerCallback);
    }
    logging.info("timers stopped", .{});

    // Unregister and clean up CSurf before other cleanup
    if (g_csurf) |cs| {
        logging.info("cleaning up CSurf", .{});
        cs.unregister();
        cs.deinit();
        g_allocator.destroy(cs);
        g_csurf = null;
    }
    logging.info("CSurf cleaned up", .{});

    // Unregister extension menu
    menu.unregister();

    if (g_http_server) |*server| {
        logging.info("stopping server", .{});
        server.deinit();
        g_http_server = null;
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

    if (g_trackfx_subs) |subs| {
        logging.info("cleaning up track FX subscriptions", .{});
        commands.g_ctx.trackfx_subs = null;
        subs.deinit();
        g_allocator.destroy(subs);
        g_trackfx_subs = null;
    }
    logging.info("track FX subscriptions cleaned up", .{});

    if (g_trackfxparam_subs) |subs| {
        logging.info("cleaning up track FX param subscriptions", .{});
        commands.g_ctx.trackfxparam_subs = null;
        subs.deinit();
        g_allocator.destroy(subs);
        g_trackfxparam_subs = null;
    }
    logging.info("track FX param subscriptions cleaned up", .{});

    if (g_tuner_subs) |subs| {
        logging.info("cleaning up tuner subscriptions", .{});
        commands.g_ctx.tuner_subs = null;
        // Remove all clients (cleans up JSFXs)
        if (g_api) |*api| {
            var backend = reaper.RealBackend{ .inner = api };
            subs.removeAllClients(&backend);
        }
        subs.deinit();
        g_allocator.destroy(subs);
        g_tuner_subs = null;
    }
    logging.info("tuner subscriptions cleaned up", .{});

    if (g_peaks_cache) |p_cache| {
        logging.info("cleaning up peaks cache", .{});
        p_cache.deinit();
        g_allocator.destroy(p_cache);
        g_peaks_cache = null;
    }
    logging.info("peaks cache cleaned up", .{});

    if (g_tile_cache) |t_cache| {
        logging.info("cleaning up tile cache", .{});
        t_cache.deinit();
        g_allocator.destroy(t_cache);
        g_tile_cache = null;
    }
    logging.info("tile cache cleaned up", .{});

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

    // Initialize SWELL bridge before menu registration.
    // Menu building (flag=0 callback) needs SWELL functions like CreatePopupMenu.
    // SWELLAPI_GetFunc must be obtained before any SWELL calls work.
    _ = swell.init();

    // Register Extensions menu NOW (before returning 1).
    // hookcustommenu flag=0 fires once when the menu is first created —
    // if SWS already called AddExtensionsMainMenu(), the flag=0 event fires
    // during plugin loading. Deferring this to a timer would miss it.
    if (g_api.?.addExtensionsMainMenu) |add_ext_menu| {
        if (menu.register(info.Register, add_ext_menu)) {
            // Menu items won't be dispatched until network_action.init() runs
            // in doInitialization(), but that's fine — user can't click them yet.
        }
    }

    // Register deferred initialization timer
    g_api.?.registerTimer(&initTimerCallback);

    return 1;
}

// Re-export tests from modules
test {
    _ = @import("core/errors.zig");
    _ = @import("core/ffi.zig");
    _ = @import("core/logging.zig");
    _ = @import("core/protocol.zig");
    _ = @import("state/transport.zig");
    _ = @import("state/project.zig");
    _ = @import("state/markers.zig");
    _ = @import("state/items.zig");
    _ = @import("state/tracks.zig");
    _ = @import("commands/mod.zig");
    _ = @import("server/ws_server.zig");
    _ = @import("server/gesture_state.zig");
    _ = @import("subscriptions/toggle_subscriptions.zig");
    _ = @import("server/subscription_polling.zig");
    _ = @import("server/tier_polling.zig");
    _ = @import("server/playlist_tick.zig");
    _ = @import("server/client_management.zig");
}
