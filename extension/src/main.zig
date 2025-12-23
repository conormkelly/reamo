const std = @import("std");
const builtin = @import("builtin");

// REAPER plugin API types
const REAPER_PLUGIN_VERSION: c_int = 0x20E;

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

fn log(msg: [*:0]const u8) void {
    if (ShowConsoleMsg) |func| {
        func(msg);
        func("\n");
    }
}

fn timerCallback() callconv(std.builtin.CallingConvention.c) void {
    if (g_initialized) return;
    g_initialized = true;

    log("Reamo: Timer fired - initialization complete!");

    // Set some EXTSTATE values for the client to read
    if (SetExtState) |setExt| {
        setExt("Reamo", "WebSocketPort", "9224", 0);
        setExt("Reamo", "Secret", "hello_from_zig_extension", 0);
        log("Reamo: EXTSTATE values set");
    }

    // Unregister timer after init
    if (plugin_register) |reg| {
        _ = reg("-timer", @ptrCast(@constCast(&timerCallback)));
    }
}

// Main entry point - called by REAPER on load
export fn ReaperPluginEntry(hInstance: ?*anyopaque, rec: ?*ReaperPluginInfo) callconv(std.builtin.CallingConvention.c) c_int {
    _ = hInstance;

    if (rec == null) {
        // Cleanup on unload
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
        _ = reg("timer", @ptrCast(@constCast(&timerCallback)));
    }

    log("Reamo: Extension loaded successfully!");

    return 1; // Success
}
