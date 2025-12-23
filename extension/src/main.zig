const std = @import("std");
const builtin = @import("builtin");
const ws_server = @import("ws_server.zig");

// REAPER plugin API types
const REAPER_PLUGIN_VERSION: c_int = 0x20E;
const DEFAULT_PORT: u16 = 9224;
const MAX_PORT_ATTEMPTS: u8 = 10;

const ReaperPluginInfo = extern struct {
    caller_version: c_int,
    hwnd_main: ?*anyopaque,
    Register: *const fn ([*:0]const u8, ?*anyopaque) callconv(std.builtin.CallingConvention.c) c_int,
    GetFunc: *const fn ([*:0]const u8) callconv(std.builtin.CallingConvention.c) ?*anyopaque,
};

// REAPER function pointers (loaded at runtime)
var ShowConsoleMsg: ?*const fn ([*:0]const u8) callconv(std.builtin.CallingConvention.c) void = null;
var SetExtState: ?*const fn ([*:0]const u8, [*:0]const u8, [*:0]const u8, c_int) callconv(std.builtin.CallingConvention.c) void = null;
var plugin_register: ?*const fn ([*:0]const u8, ?*anyopaque) callconv(std.builtin.CallingConvention.c) c_int = null;

// State
var g_initialized: bool = false;
var g_allocator: std.mem.Allocator = undefined;
var g_shared_state: ?*ws_server.SharedState = null;
var g_server: ?ws_server.Server = null;
var g_port: u16 = 0;

// Logging with format support
fn log(comptime fmt: []const u8, args: anytype) void {
    if (ShowConsoleMsg) |func| {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
        // Null-terminate for C
        if (msg.len < buf.len) {
            buf[msg.len] = 0;
            func(@ptrCast(&buf));
            func("\n");
        }
    }
}

fn logSimple(msg: [*:0]const u8) void {
    if (ShowConsoleMsg) |func| {
        func(msg);
        func("\n");
    }
}

fn initTimerCallback() callconv(std.builtin.CallingConvention.c) void {
    if (g_initialized) return;
    g_initialized = true;

    logSimple("Reamo: Deferred initialization starting...");

    // Initialize allocator
    g_allocator = std.heap.page_allocator;

    // Initialize shared state
    const state = g_allocator.create(ws_server.SharedState) catch {
        logSimple("Reamo: Failed to allocate shared state");
        return;
    };
    state.* = ws_server.SharedState.init(g_allocator);
    g_shared_state = state;

    // Start WebSocket server with port retry
    const result = ws_server.startWithPortRetry(g_allocator, state, DEFAULT_PORT, MAX_PORT_ATTEMPTS) catch {
        logSimple("Reamo: Could not bind to ports 9224-9233");
        return;
    };

    g_server = result.server;
    g_port = result.port;

    // Set EXTSTATE for client discovery
    if (SetExtState) |setExt| {
        var port_buf: [8]u8 = undefined;
        const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{g_port}) catch "9224";
        // Null-terminate
        if (port_str.len < port_buf.len) {
            port_buf[port_str.len] = 0;
            setExt("Reamo", "WebSocketPort", @ptrCast(&port_buf), 0);
        }
    }

    log("Reamo: WebSocket server started on port {d}", .{g_port});

    // Unregister init timer, register processing timer
    if (plugin_register) |reg| {
        _ = reg("-timer", @ptrCast(@constCast(&initTimerCallback)));
        _ = reg("timer", @ptrCast(@constCast(&processTimerCallback)));
    }
}

fn processTimerCallback() callconv(std.builtin.CallingConvention.c) void {
    const state = g_shared_state orelse return;

    // Process pending commands from WebSocket clients
    while (state.popCommand()) |cmd| {
        var command = cmd;
        defer command.deinit();

        // TODO: Parse JSON command and execute REAPER API
        // For now, just log it
        log("Reamo: Received command from client {d}: {s}", .{ command.client_id, command.data });
    }
}

fn shutdown() void {
    logSimple("Reamo: Shutting down...");

    // Unregister timer
    if (plugin_register) |reg| {
        _ = reg("-timer", @ptrCast(@constCast(&processTimerCallback)));
    }

    // Stop WebSocket server
    if (g_server) |*server| {
        server.stop();
        server.deinit();
        g_server = null;
    }

    // Cleanup shared state
    if (g_shared_state) |state| {
        state.deinit();
        g_allocator.destroy(state);
        g_shared_state = null;
    }

    logSimple("Reamo: Shutdown complete");
}

// Main entry point - called by REAPER on load
export fn ReaperPluginEntry(hInstance: ?*anyopaque, rec: ?*ReaperPluginInfo) callconv(std.builtin.CallingConvention.c) c_int {
    _ = hInstance;

    if (rec == null) {
        // Cleanup on unload
        shutdown();
        return 0;
    }

    const info = rec.?;

    // Version check
    if (info.caller_version != REAPER_PLUGIN_VERSION) {
        return 0;
    }

    // Load REAPER functions
    if (info.GetFunc("ShowConsoleMsg")) |ptr| {
        ShowConsoleMsg = @ptrCast(@alignCast(ptr));
    } else {
        return 0;
    }

    if (info.GetFunc("SetExtState")) |ptr| {
        SetExtState = @ptrCast(@alignCast(ptr));
    }

    // info.Register is already the function pointer we need
    plugin_register = info.Register;

    // Register timer for deferred init
    if (plugin_register) |reg| {
        _ = reg("timer", @ptrCast(@constCast(&initTimerCallback)));
    }

    logSimple("Reamo: Extension loaded successfully!");

    return 1; // Success
}
