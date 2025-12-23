const std = @import("std");
const reaper = @import("reaper.zig");
const transport = @import("transport.zig");
const markers = @import("markers.zig");
const items = @import("items.zig");
const tracks = @import("tracks.zig");
const commands = @import("commands/mod.zig");
const ws_server = @import("ws_server.zig");

// Configuration
const DEFAULT_PORT: u16 = 9224;
const MAX_PORT_ATTEMPTS: u8 = 10;

// Global state - minimized to essentials
var g_api: ?reaper.Api = null;
var g_allocator: std.mem.Allocator = undefined;
var g_shared_state: ?*ws_server.SharedState = null;
var g_server: ?ws_server.Server = null;
var g_port: u16 = 0;
var g_last_transport: transport.State = .{};
var g_last_markers: markers.State = .{};
var g_last_items: items.State = .{};
var g_last_tracks: tracks.State = .{};
var g_initialized: bool = false;

// Debug logging (can be disabled in release)
var g_log_file: ?std.fs.File = null;

fn logFile(msg: []const u8) void {
    if (g_log_file) |f| {
        const ts = std.time.timestamp();
        var buf: [64]u8 = undefined;
        const ts_str = std.fmt.bufPrint(&buf, "[{d}] ", .{ts}) catch return;
        _ = f.write(ts_str) catch {};
        _ = f.write(msg) catch {};
        _ = f.write("\n") catch {};
    }
}

fn initLogFile() void {
    g_log_file = std.fs.cwd().createFile("/tmp/reamo-extension.log", .{ .truncate = false }) catch null;
    if (g_log_file) |f| {
        f.seekFromEnd(0) catch {};
        logFile("=== Reamo Extension Started ===");
    }
}

fn closeLogFile() void {
    if (g_log_file) |f| {
        logFile("=== Reamo Extension Ended ===");
        f.close();
        g_log_file = null;
    }
}

// Timer callback for deferred initialization
fn initTimerCallback() callconv(.c) void {
    if (g_initialized) return;
    g_initialized = true;

    const api = &(g_api orelse return);
    api.logSimple("Reamo: Deferred initialization starting...");

    g_allocator = std.heap.page_allocator;

    initLogFile();
    logFile("initTimerCallback() started");

    // Create shared state
    const state = g_allocator.create(ws_server.SharedState) catch {
        api.logSimple("Reamo: Failed to allocate shared state");
        return;
    };
    state.* = ws_server.SharedState.init(g_allocator);
    g_shared_state = state;

    // Generate session token and store in EXTSTATE
    var token_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&token_bytes);
    const token_hex = std.fmt.bytesToHex(token_bytes, .lower);
    state.setToken(&token_hex);
    api.setExtStateStr("Reamo", "SessionToken", &token_hex);
    api.log("Reamo: Session token generated", .{});

    // Start WebSocket server
    const result = ws_server.startWithPortRetry(g_allocator, state, DEFAULT_PORT, MAX_PORT_ATTEMPTS) catch {
        api.logSimple("Reamo: Could not bind to ports 9224-9233");
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
    g_last_markers = markers.State.poll(api);
    g_last_items = items.State.poll(api);
    g_last_tracks = tracks.State.poll(api);

    api.log("Reamo: WebSocket server started on port {d}", .{g_port});
    logFile("WebSocket server started");

    // Switch to processing timer
    api.unregisterTimer(&initTimerCallback);
    api.registerTimer(&processTimerCallback);

    logFile("initTimerCallback() complete");
}

// Main processing timer - runs every ~30ms
fn processTimerCallback() callconv(.c) void {
    const api = &(g_api orelse return);
    const shared_state = g_shared_state orelse return;

    // Process pending commands from WebSocket clients
    while (shared_state.popCommand()) |cmd| {
        var command = cmd;
        defer command.deinit();
        commands.dispatch(api, command.client_id, command.data, shared_state);
    }

    // Poll transport state and broadcast changes
    const current_transport = transport.State.poll(api);
    if (!current_transport.eql(g_last_transport)) {
        var buf: [512]u8 = undefined;
        if (current_transport.toJson(&buf)) |json| {
            shared_state.broadcast(json);
        }
        g_last_transport = current_transport;
    }

    // Poll markers/regions and broadcast changes
    const current_markers = markers.State.poll(api);
    if (current_markers.markersChanged(&g_last_markers)) {
        var buf: [8192]u8 = undefined; // Larger buffer for many markers
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
        var buf: [32768]u8 = undefined; // Large buffer for many items with takes
        if (current_items.itemsToJson(&buf)) |json| {
            shared_state.broadcast(json);
        }
    }
    g_last_items = current_items;

    // Poll tracks and broadcast changes
    const current_tracks = tracks.State.poll(api);
    if (!current_tracks.eql(&g_last_tracks)) {
        var buf: [16384]u8 = undefined; // Large buffer for many tracks
        if (current_tracks.toJson(&buf)) |json| {
            shared_state.broadcast(json);
        }
    }
    g_last_tracks = current_tracks;
}

// Shutdown - called when REAPER unloads the extension
fn shutdown() void {
    logFile("shutdown() called");

    if (g_api) |*api| {
        api.logSimple("Reamo: Shutting down...");
        api.unregisterTimer(&processTimerCallback);
    }
    logFile("timer unregistered");

    if (g_server) |*server| {
        logFile("stopping server");
        server.stop();
        server.deinit();
        g_server = null;
    }
    logFile("server stopped");

    if (g_shared_state) |state| {
        logFile("cleaning up shared state");
        state.deinit();
        g_allocator.destroy(state);
        g_shared_state = null;
    }
    logFile("shared state cleaned up");

    if (g_api) |*api| {
        api.logSimple("Reamo: Shutdown complete");
    }
    logFile("shutdown() complete");
    closeLogFile();
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

    g_api.?.logSimple("Reamo: Extension loaded successfully!");

    return 1;
}

// Re-export tests from modules
test {
    _ = @import("protocol.zig");
    _ = @import("transport.zig");
    _ = @import("markers.zig");
    _ = @import("items.zig");
    _ = @import("tracks.zig");
    _ = @import("commands/mod.zig");
    _ = @import("ws_server.zig");
}
