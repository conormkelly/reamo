//! Counts project loads, so a different project opened in the same tab can be
//! told apart from edits to the one already open: the ReaProject* stays the
//! same and REAPER's state-change count only rises, but a load runs
//! BeginLoadProjectState of every registered "projectconfig" extension.
//!
//! Undo also reloads project state (isUndo=true); those are not counted.
//! Callbacks run on REAPER's main thread during the load, so they only bump
//! a counter.

const std = @import("std");

const ProjectStateContext = opaque {};

/// REAPER's project_config_extension_t.
const Extension = extern struct {
    ProcessExtensionLine: *const fn ([*:0]const u8, ?*ProjectStateContext, bool, *Extension) callconv(.c) bool,
    SaveExtensionConfig: *const fn (?*ProjectStateContext, bool, *Extension) callconv(.c) void,
    BeginLoadProjectState: *const fn (bool, *Extension) callconv(.c) void,
    userData: ?*anyopaque,
};

fn processExtensionLine(_: [*:0]const u8, _: ?*ProjectStateContext, _: bool, _: *Extension) callconv(.c) bool {
    return false; // REAmo keeps no lines of its own in the project file
}

fn saveExtensionConfig(_: ?*ProjectStateContext, _: bool, _: *Extension) callconv(.c) void {}

fn beginLoadProjectState(is_undo: bool, _: *Extension) callconv(.c) void {
    if (!is_undo) _ = g_loads.fetchAdd(1, .monotonic);
}

var g_extension = Extension{
    .ProcessExtensionLine = processExtensionLine,
    .SaveExtensionConfig = saveExtensionConfig,
    .BeginLoadProjectState = beginLoadProjectState,
    .userData = null,
};

var g_loads = std.atomic.Value(u32).init(0);

pub const PluginRegisterFn = *const fn ([*:0]const u8, ?*anyopaque) callconv(.c) c_int;

pub fn register(plugin_register: PluginRegisterFn) bool {
    return plugin_register("projectconfig", @ptrCast(&g_extension)) != 0;
}

pub fn unregister(plugin_register: PluginRegisterFn) void {
    _ = plugin_register("-projectconfig", @ptrCast(&g_extension));
}

/// Project loads (not undo reloads) since the extension started.
pub fn loadCount() u32 {
    return g_loads.load(.monotonic);
}

test "only real loads are counted" {
    const before = loadCount();
    beginLoadProjectState(true, &g_extension);
    try std.testing.expectEqual(before, loadCount());
    beginLoadProjectState(false, &g_extension);
    try std.testing.expectEqual(before + 1, loadCount());
}
