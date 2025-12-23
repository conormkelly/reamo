const std = @import("std");

// REAPER plugin API version
pub const PLUGIN_VERSION: c_int = 0x20E;

// REAPER plugin info struct passed to ReaperPluginEntry
pub const PluginInfo = extern struct {
    caller_version: c_int,
    hwnd_main: ?*anyopaque,
    Register: *const fn ([*:0]const u8, ?*anyopaque) callconv(.c) c_int,
    GetFunc: *const fn ([*:0]const u8) callconv(.c) ?*anyopaque,
};

// REAPER API - loaded at runtime from plugin info
pub const Api = struct {
    // Core
    showConsoleMsg: *const fn ([*:0]const u8) callconv(.c) void,
    register: *const fn ([*:0]const u8, ?*anyopaque) callconv(.c) c_int,

    // State
    setExtState: ?*const fn ([*:0]const u8, [*:0]const u8, [*:0]const u8, c_int) callconv(.c) void = null,

    // Transport - read
    getPlayState: ?*const fn () callconv(.c) c_int = null,
    getPlayPosition: ?*const fn () callconv(.c) f64 = null,
    getCursorPosition: ?*const fn () callconv(.c) f64 = null,
    getProjectTimeSignature2: ?*const fn (?*anyopaque, *f64, *f64) callconv(.c) void = null,
    getSetLoopTimeRange2: ?*const fn (?*anyopaque, bool, bool, *f64, *f64, bool) callconv(.c) void = null,

    // Transport - write
    mainOnCommand: ?*const fn (c_int, c_int) callconv(.c) void = null,
    setEditCurPos: ?*const fn (f64, bool, bool) callconv(.c) void = null,

    // Markers & Regions
    countProjectMarkers: ?*const fn (?*anyopaque, ?*c_int, ?*c_int) callconv(.c) c_int = null,
    enumProjectMarkers3: ?*const fn (?*anyopaque, c_int, ?*bool, ?*f64, ?*f64, ?*[*:0]const u8, ?*c_int, ?*c_int) callconv(.c) c_int = null,
    addProjectMarker2: ?*const fn (?*anyopaque, bool, f64, f64, [*:0]const u8, c_int, c_int) callconv(.c) c_int = null,
    setProjectMarker4: ?*const fn (?*anyopaque, c_int, bool, f64, f64, [*:0]const u8, c_int, c_int) callconv(.c) bool = null,
    deleteProjectMarker: ?*const fn (?*anyopaque, c_int, bool) callconv(.c) bool = null,

    // Load API from REAPER plugin info
    pub fn load(info: *PluginInfo) ?Api {
        const showConsoleMsg = getFunc(info, "ShowConsoleMsg", fn ([*:0]const u8) callconv(.c) void) orelse return null;

        return Api{
            .showConsoleMsg = showConsoleMsg,
            .register = info.Register,
            .setExtState = getFunc(info, "SetExtState", fn ([*:0]const u8, [*:0]const u8, [*:0]const u8, c_int) callconv(.c) void),
            .getPlayState = getFunc(info, "GetPlayState", fn () callconv(.c) c_int),
            .getPlayPosition = getFunc(info, "GetPlayPosition", fn () callconv(.c) f64),
            .getCursorPosition = getFunc(info, "GetCursorPosition", fn () callconv(.c) f64),
            .getProjectTimeSignature2 = getFunc(info, "GetProjectTimeSignature2", fn (?*anyopaque, *f64, *f64) callconv(.c) void),
            .getSetLoopTimeRange2 = getFunc(info, "GetSet_LoopTimeRange2", fn (?*anyopaque, bool, bool, *f64, *f64, bool) callconv(.c) void),
            .mainOnCommand = getFunc(info, "Main_OnCommand", fn (c_int, c_int) callconv(.c) void),
            .setEditCurPos = getFunc(info, "SetEditCurPos", fn (f64, bool, bool) callconv(.c) void),
            .countProjectMarkers = getFunc(info, "CountProjectMarkers", fn (?*anyopaque, ?*c_int, ?*c_int) callconv(.c) c_int),
            .enumProjectMarkers3 = getFunc(info, "EnumProjectMarkers3", fn (?*anyopaque, c_int, ?*bool, ?*f64, ?*f64, ?*[*:0]const u8, ?*c_int, ?*c_int) callconv(.c) c_int),
            .addProjectMarker2 = getFunc(info, "AddProjectMarker2", fn (?*anyopaque, bool, f64, f64, [*:0]const u8, c_int, c_int) callconv(.c) c_int),
            .setProjectMarker4 = getFunc(info, "SetProjectMarker4", fn (?*anyopaque, c_int, bool, f64, f64, [*:0]const u8, c_int, c_int) callconv(.c) bool),
            .deleteProjectMarker = getFunc(info, "DeleteProjectMarker", fn (?*anyopaque, c_int, bool) callconv(.c) bool),
        };
    }

    fn getFunc(info: *PluginInfo, name: [*:0]const u8, comptime T: type) ?*const T {
        const ptr = info.GetFunc(name) orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    // Safe wrapper methods

    pub fn log(self: *const Api, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
        if (msg.len < buf.len) {
            buf[msg.len] = 0;
            self.showConsoleMsg(@ptrCast(&buf));
        }
    }

    pub fn logSimple(self: *const Api, msg: [*:0]const u8) void {
        self.showConsoleMsg(msg);
        self.showConsoleMsg("\n");
    }

    pub fn setExtStateStr(self: *const Api, section: [*:0]const u8, key: [*:0]const u8, value: []const u8) void {
        if (self.setExtState) |f| {
            var buf: [64]u8 = undefined;
            if (value.len < buf.len) {
                @memcpy(buf[0..value.len], value);
                buf[value.len] = 0;
                f(section, key, @ptrCast(&buf), 0);
            }
        }
    }

    pub fn playState(self: *const Api) c_int {
        return if (self.getPlayState) |f| f() else 0;
    }

    pub fn playPosition(self: *const Api) f64 {
        return if (self.getPlayPosition) |f| f() else 0;
    }

    pub fn cursorPosition(self: *const Api) f64 {
        return if (self.getCursorPosition) |f| f() else 0;
    }

    pub fn timeSignature(self: *const Api) struct { bpm: f64, num: f64 } {
        var bpm: f64 = 120;
        var num: f64 = 4;
        if (self.getProjectTimeSignature2) |f| {
            f(null, &bpm, &num);
        }
        return .{ .bpm = bpm, .num = num };
    }

    pub fn timeSelection(self: *const Api) struct { start: f64, end: f64 } {
        var start: f64 = 0;
        var end: f64 = 0;
        if (self.getSetLoopTimeRange2) |f| {
            f(null, false, false, &start, &end, false);
        }
        return .{ .start = start, .end = end };
    }

    pub fn runCommand(self: *const Api, cmd: c_int) void {
        if (self.mainOnCommand) |f| f(cmd, 0);
    }

    pub fn setCursorPos(self: *const Api, pos: f64) void {
        if (self.setEditCurPos) |f| f(pos, true, true);
    }

    pub fn registerTimer(self: *const Api, callback: *const fn () callconv(.c) void) void {
        _ = self.register("timer", @ptrCast(@constCast(callback)));
    }

    pub fn unregisterTimer(self: *const Api, callback: *const fn () callconv(.c) void) void {
        _ = self.register("-timer", @ptrCast(@constCast(callback)));
    }

    // Marker/Region methods

    pub fn markerCount(self: *const Api) struct { total: c_int, markers: c_int, regions: c_int } {
        var markers: c_int = 0;
        var regions: c_int = 0;
        const total = if (self.countProjectMarkers) |f| f(null, &markers, &regions) else 0;
        return .{ .total = total, .markers = markers, .regions = regions };
    }

    pub const MarkerInfo = struct {
        idx: c_int, // enumeration index
        id: c_int, // displayed marker/region ID
        is_region: bool,
        pos: f64,
        end: f64, // only valid for regions
        name: []const u8,
        color: c_int,
    };

    pub fn enumMarker(self: *const Api, idx: c_int) ?MarkerInfo {
        const f = self.enumProjectMarkers3 orelse return null;

        var is_region: bool = false;
        var pos: f64 = 0;
        var end: f64 = 0;
        var name_ptr: [*:0]const u8 = "";
        var id: c_int = 0;
        var color: c_int = 0;

        const next_idx = f(null, idx, &is_region, &pos, &end, &name_ptr, &id, &color);
        if (next_idx == 0 and idx > 0) return null; // end of list
        if (next_idx == 0 and idx == 0) {
            // Check if there are any markers at all
            const count = self.markerCount();
            if (count.total == 0) return null;
        }

        return .{
            .idx = idx,
            .id = id,
            .is_region = is_region,
            .pos = pos,
            .end = end,
            .name = std.mem.sliceTo(name_ptr, 0),
            .color = color,
        };
    }

    pub fn addMarker(self: *const Api, pos: f64, name: [*:0]const u8, color: c_int) c_int {
        const f = self.addProjectMarker2 orelse return -1;
        return f(null, false, pos, 0, name, -1, color);
    }

    pub fn addRegion(self: *const Api, start: f64, end: f64, name: [*:0]const u8, color: c_int) c_int {
        const f = self.addProjectMarker2 orelse return -1;
        return f(null, true, start, end, name, -1, color);
    }

    pub fn updateMarker(self: *const Api, id: c_int, pos: f64, name: [*:0]const u8, color: c_int) bool {
        const f = self.setProjectMarker4 orelse return false;
        return f(null, id, false, pos, 0, name, color, 0);
    }

    pub fn updateRegion(self: *const Api, id: c_int, start: f64, end: f64, name: [*:0]const u8, color: c_int) bool {
        const f = self.setProjectMarker4 orelse return false;
        return f(null, id, true, start, end, name, color, 0);
    }

    pub fn deleteMarker(self: *const Api, id: c_int) bool {
        const f = self.deleteProjectMarker orelse return false;
        return f(null, id, false);
    }

    pub fn deleteRegion(self: *const Api, id: c_int) bool {
        const f = self.deleteProjectMarker orelse return false;
        return f(null, id, true);
    }
};

// REAPER action command IDs
pub const Command = struct {
    pub const PLAY: c_int = 1007;
    pub const PAUSE: c_int = 1008;
    pub const RECORD: c_int = 1013;
    pub const STOP: c_int = 1016;
};
