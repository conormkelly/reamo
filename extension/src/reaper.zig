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

    // Tracks
    countTracks: ?*const fn (?*anyopaque) callconv(.c) c_int = null,
    getTrack: ?*const fn (?*anyopaque, c_int) callconv(.c) ?*anyopaque = null,
    getTrackName: ?*const fn (?*anyopaque, [*]u8, c_int) callconv(.c) bool = null,

    // Items
    countTrackMediaItems: ?*const fn (?*anyopaque) callconv(.c) c_int = null,
    getTrackMediaItem: ?*const fn (?*anyopaque, c_int) callconv(.c) ?*anyopaque = null,
    getMediaItemInfo_Value: ?*const fn (?*anyopaque, [*:0]const u8) callconv(.c) f64 = null,
    setMediaItemInfo_Value: ?*const fn (?*anyopaque, [*:0]const u8, f64) callconv(.c) bool = null,
    getSetMediaItemInfo_String: ?*const fn (?*anyopaque, [*:0]const u8, [*]u8, bool) callconv(.c) bool = null,
    deleteTrackMediaItem: ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) bool = null,

    // Takes
    getMediaItemNumTakes: ?*const fn (?*anyopaque) callconv(.c) c_int = null,
    getMediaItemTake: ?*const fn (?*anyopaque, c_int) callconv(.c) ?*anyopaque = null,
    getActiveTake: ?*const fn (?*anyopaque) callconv(.c) ?*anyopaque = null,
    getTakeName: ?*const fn (?*anyopaque) callconv(.c) ?[*:0]const u8 = null,
    getSetMediaItemTakeInfo_String: ?*const fn (?*anyopaque, [*:0]const u8, [*]u8, bool) callconv(.c) bool = null,

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
            // Tracks
            .countTracks = getFunc(info, "CountTracks", fn (?*anyopaque) callconv(.c) c_int),
            .getTrack = getFunc(info, "GetTrack", fn (?*anyopaque, c_int) callconv(.c) ?*anyopaque),
            .getTrackName = getFunc(info, "GetTrackName", fn (?*anyopaque, [*]u8, c_int) callconv(.c) bool),
            // Items
            .countTrackMediaItems = getFunc(info, "CountTrackMediaItems", fn (?*anyopaque) callconv(.c) c_int),
            .getTrackMediaItem = getFunc(info, "GetTrackMediaItem", fn (?*anyopaque, c_int) callconv(.c) ?*anyopaque),
            .getMediaItemInfo_Value = getFunc(info, "GetMediaItemInfo_Value", fn (?*anyopaque, [*:0]const u8) callconv(.c) f64),
            .setMediaItemInfo_Value = getFunc(info, "SetMediaItemInfo_Value", fn (?*anyopaque, [*:0]const u8, f64) callconv(.c) bool),
            .getSetMediaItemInfo_String = getFunc(info, "GetSetMediaItemInfo_String", fn (?*anyopaque, [*:0]const u8, [*]u8, bool) callconv(.c) bool),
            .deleteTrackMediaItem = getFunc(info, "DeleteTrackMediaItem", fn (?*anyopaque, ?*anyopaque) callconv(.c) bool),
            // Takes
            .getMediaItemNumTakes = getFunc(info, "GetMediaItemNumTakes", fn (?*anyopaque) callconv(.c) c_int),
            .getMediaItemTake = getFunc(info, "GetMediaItemTake", fn (?*anyopaque, c_int) callconv(.c) ?*anyopaque),
            .getActiveTake = getFunc(info, "GetActiveTake", fn (?*anyopaque) callconv(.c) ?*anyopaque),
            .getTakeName = getFunc(info, "GetTakeName", fn (?*anyopaque) callconv(.c) ?[*:0]const u8),
            .getSetMediaItemTakeInfo_String = getFunc(info, "GetSetMediaItemTakeInfo_String", fn (?*anyopaque, [*:0]const u8, [*]u8, bool) callconv(.c) bool),
        };
    }

    fn getFunc(info: *PluginInfo, name: [*:0]const u8, comptime T: type) ?*const T {
        const ptr = info.GetFunc(name) orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    // Safe float to int conversion - handles NaN/Inf from corrupt data
    fn safeFloatToInt(comptime T: type, val: f64, default: T) T {
        if (std.math.isNan(val) or std.math.isInf(val)) return default;
        // Clamp to representable range for the target type
        const min_val: f64 = @floatFromInt(std.math.minInt(T));
        const max_val: f64 = @floatFromInt(std.math.maxInt(T));
        const clamped = @max(min_val, @min(max_val, val));
        return @intFromFloat(clamped);
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

    // Track methods

    pub fn trackCount(self: *const Api) c_int {
        return if (self.countTracks) |f| f(null) else 0;
    }

    pub fn getTrackByIdx(self: *const Api, idx: c_int) ?*anyopaque {
        const f = self.getTrack orelse return null;
        return f(null, idx);
    }

    pub fn getTrackNameStr(self: *const Api, track: *anyopaque, buf: []u8) []const u8 {
        const f = self.getTrackName orelse return "";
        if (f(track, buf.ptr, @intCast(buf.len))) {
            return std.mem.sliceTo(buf, 0);
        }
        return "";
    }

    // Item methods

    pub fn trackItemCount(self: *const Api, track: *anyopaque) c_int {
        const f = self.countTrackMediaItems orelse return 0;
        return f(track);
    }

    pub fn getItemByIdx(self: *const Api, track: *anyopaque, idx: c_int) ?*anyopaque {
        const f = self.getTrackMediaItem orelse return null;
        return f(track, idx);
    }

    pub fn getItemPosition(self: *const Api, item: *anyopaque) f64 {
        const f = self.getMediaItemInfo_Value orelse return 0;
        return f(item, "D_POSITION");
    }

    pub fn getItemLength(self: *const Api, item: *anyopaque) f64 {
        const f = self.getMediaItemInfo_Value orelse return 0;
        return f(item, "D_LENGTH");
    }

    pub fn getItemColor(self: *const Api, item: *anyopaque) c_int {
        const f = self.getMediaItemInfo_Value orelse return 0;
        return safeFloatToInt(c_int, f(item, "I_CUSTOMCOLOR"), 0);
    }

    pub fn getItemLocked(self: *const Api, item: *anyopaque) bool {
        const f = self.getMediaItemInfo_Value orelse return false;
        return safeFloatToInt(c_int, f(item, "C_LOCK"), 0) != 0;
    }

    pub fn getItemActiveTakeIdx(self: *const Api, item: *anyopaque) c_int {
        const f = self.getMediaItemInfo_Value orelse return 0;
        return safeFloatToInt(c_int, f(item, "I_CURTAKE"), 0);
    }

    pub fn setItemPosition(self: *const Api, item: *anyopaque, pos: f64) bool {
        const f = self.setMediaItemInfo_Value orelse return false;
        return f(item, "D_POSITION", pos);
    }

    pub fn setItemColor(self: *const Api, item: *anyopaque, color: c_int) bool {
        const f = self.setMediaItemInfo_Value orelse return false;
        return f(item, "I_CUSTOMCOLOR", @floatFromInt(color));
    }

    pub fn setItemLocked(self: *const Api, item: *anyopaque, locked: bool) bool {
        const f = self.setMediaItemInfo_Value orelse return false;
        return f(item, "C_LOCK", if (locked) 1.0 else 0.0);
    }

    pub fn setItemActiveTake(self: *const Api, item: *anyopaque, take_idx: c_int) bool {
        const f = self.setMediaItemInfo_Value orelse return false;
        return f(item, "I_CURTAKE", @floatFromInt(take_idx));
    }

    pub fn getItemNotes(self: *const Api, item: *anyopaque, buf: []u8) []const u8 {
        const f = self.getSetMediaItemInfo_String orelse return "";
        if (f(item, "P_NOTES", buf.ptr, false)) {
            return std.mem.sliceTo(buf, 0);
        }
        return "";
    }

    pub fn setItemNotes(self: *const Api, item: *anyopaque, notes: []const u8) bool {
        const f = self.getSetMediaItemInfo_String orelse return false;
        var buf: [1024]u8 = undefined;
        const len = @min(notes.len, buf.len - 1);
        @memcpy(buf[0..len], notes[0..len]);
        buf[len] = 0;
        return f(item, "P_NOTES", &buf, true);
    }

    pub fn deleteItem(self: *const Api, track: *anyopaque, item: *anyopaque) bool {
        const f = self.deleteTrackMediaItem orelse return false;
        return f(track, item);
    }

    // Take methods

    pub fn itemTakeCount(self: *const Api, item: *anyopaque) c_int {
        const f = self.getMediaItemNumTakes orelse return 0;
        return f(item);
    }

    pub fn getTakeByIdx(self: *const Api, item: *anyopaque, idx: c_int) ?*anyopaque {
        const f = self.getMediaItemTake orelse return null;
        return f(item, idx);
    }

    pub fn getItemActiveTake(self: *const Api, item: *anyopaque) ?*anyopaque {
        const f = self.getActiveTake orelse return null;
        return f(item);
    }

    pub fn getTakeNameStr(self: *const Api, take: *anyopaque) []const u8 {
        const f = self.getTakeName orelse return "";
        const ptr = f(take) orelse return "";
        return std.mem.sliceTo(ptr, 0);
    }
};

// REAPER action command IDs
pub const Command = struct {
    pub const PLAY: c_int = 1007;
    pub const PAUSE: c_int = 1008;
    pub const RECORD: c_int = 1013;
    pub const STOP: c_int = 1016;
    // Take commands (operate on selected item's active take)
    pub const DELETE_ACTIVE_TAKE: c_int = 40129;
    pub const CROP_TO_ACTIVE_TAKE: c_int = 40131;
};
