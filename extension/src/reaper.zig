const std = @import("std");

// Debug logging - set to false for release builds
pub const DEBUG_LOGGING = true;

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

    // Repeat
    getSetRepeat: ?*const fn (c_int) callconv(.c) c_int = null,

    // Time conversion
    timeMap2_beatsToTime: ?*const fn (?*anyopaque, f64, ?*const c_int) callconv(.c) f64 = null,
    timeMap2_timeToBeats: ?*const fn (?*anyopaque, f64, ?*c_int, ?*c_int, ?*f64, ?*c_int) callconv(.c) f64 = null,

    // Tempo
    setCurrentBPM: ?*const fn (?*anyopaque, f64, bool) callconv(.c) void = null,

    // Command state
    getToggleCommandState: ?*const fn (c_int) callconv(.c) c_int = null,

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
    getMediaTrackInfo_Value: ?*const fn (?*anyopaque, [*:0]const u8) callconv(.c) f64 = null,
    setMediaTrackInfo_Value: ?*const fn (?*anyopaque, [*:0]const u8, f64) callconv(.c) bool = null,

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

    // ExtState (global and project-specific)
    getExtState: ?*const fn ([*:0]const u8, [*:0]const u8) callconv(.c) ?[*:0]const u8 = null,
    getProjExtState: ?*const fn (?*anyopaque, [*:0]const u8, [*:0]const u8, [*]u8, c_int) callconv(.c) c_int = null,
    setProjExtState: ?*const fn (?*anyopaque, [*:0]const u8, [*:0]const u8, [*:0]const u8) callconv(.c) c_int = null,

    // Undo
    undo_BeginBlock2: ?*const fn (?*anyopaque) callconv(.c) void = null,
    undo_EndBlock2: ?*const fn (?*anyopaque, [*:0]const u8, c_int) callconv(.c) void = null,
    undo_OnStateChange: ?*const fn ([*:0]const u8) callconv(.c) void = null,

    // Metering
    track_GetPeakInfo: ?*const fn (?*anyopaque, c_int) callconv(.c) f64 = null,
    track_GetPeakHoldDB: ?*const fn (?*anyopaque, c_int, bool) callconv(.c) f64 = null,

    // Project config variables (for metronome volume, etc.)
    projectconfig_var_getoffs: ?*const fn ([*:0]const u8, ?*c_int) callconv(.c) c_int = null,
    projectconfig_var_addr: ?*const fn (?*anyopaque, c_int) callconv(.c) ?*anyopaque = null,

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
            // Repeat
            .getSetRepeat = getFunc(info, "GetSetRepeat", fn (c_int) callconv(.c) c_int),
            // Time conversion
            .timeMap2_beatsToTime = getFunc(info, "TimeMap2_beatsToTime", fn (?*anyopaque, f64, ?*const c_int) callconv(.c) f64),
            .timeMap2_timeToBeats = getFunc(info, "TimeMap2_timeToBeats", fn (?*anyopaque, f64, ?*c_int, ?*c_int, ?*f64, ?*c_int) callconv(.c) f64),
            // Tempo
            .setCurrentBPM = getFunc(info, "SetCurrentBPM", fn (?*anyopaque, f64, bool) callconv(.c) void),
            // Command state
            .getToggleCommandState = getFunc(info, "GetToggleCommandState", fn (c_int) callconv(.c) c_int),
            .countProjectMarkers = getFunc(info, "CountProjectMarkers", fn (?*anyopaque, ?*c_int, ?*c_int) callconv(.c) c_int),
            .enumProjectMarkers3 = getFunc(info, "EnumProjectMarkers3", fn (?*anyopaque, c_int, ?*bool, ?*f64, ?*f64, ?*[*:0]const u8, ?*c_int, ?*c_int) callconv(.c) c_int),
            .addProjectMarker2 = getFunc(info, "AddProjectMarker2", fn (?*anyopaque, bool, f64, f64, [*:0]const u8, c_int, c_int) callconv(.c) c_int),
            .setProjectMarker4 = getFunc(info, "SetProjectMarker4", fn (?*anyopaque, c_int, bool, f64, f64, [*:0]const u8, c_int, c_int) callconv(.c) bool),
            .deleteProjectMarker = getFunc(info, "DeleteProjectMarker", fn (?*anyopaque, c_int, bool) callconv(.c) bool),
            // Tracks
            .countTracks = getFunc(info, "CountTracks", fn (?*anyopaque) callconv(.c) c_int),
            .getTrack = getFunc(info, "GetTrack", fn (?*anyopaque, c_int) callconv(.c) ?*anyopaque),
            .getTrackName = getFunc(info, "GetTrackName", fn (?*anyopaque, [*]u8, c_int) callconv(.c) bool),
            .getMediaTrackInfo_Value = getFunc(info, "GetMediaTrackInfo_Value", fn (?*anyopaque, [*:0]const u8) callconv(.c) f64),
            .setMediaTrackInfo_Value = getFunc(info, "SetMediaTrackInfo_Value", fn (?*anyopaque, [*:0]const u8, f64) callconv(.c) bool),
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
            // ExtState
            .getExtState = getFunc(info, "GetExtState", fn ([*:0]const u8, [*:0]const u8) callconv(.c) ?[*:0]const u8),
            .getProjExtState = getFunc(info, "GetProjExtState", fn (?*anyopaque, [*:0]const u8, [*:0]const u8, [*]u8, c_int) callconv(.c) c_int),
            .setProjExtState = getFunc(info, "SetProjExtState", fn (?*anyopaque, [*:0]const u8, [*:0]const u8, [*:0]const u8) callconv(.c) c_int),
            // Undo
            .undo_BeginBlock2 = getFunc(info, "Undo_BeginBlock2", fn (?*anyopaque) callconv(.c) void),
            .undo_EndBlock2 = getFunc(info, "Undo_EndBlock2", fn (?*anyopaque, [*:0]const u8, c_int) callconv(.c) void),
            .undo_OnStateChange = getFunc(info, "Undo_OnStateChange", fn ([*:0]const u8) callconv(.c) void),
            // Metering
            .track_GetPeakInfo = getFunc(info, "Track_GetPeakInfo", fn (?*anyopaque, c_int) callconv(.c) f64),
            .track_GetPeakHoldDB = getFunc(info, "Track_GetPeakHoldDB", fn (?*anyopaque, c_int, bool) callconv(.c) f64),
            // Project config variables
            .projectconfig_var_getoffs = getFunc(info, "projectconfig_var_getoffs", fn ([*:0]const u8, ?*c_int) callconv(.c) c_int),
            .projectconfig_var_addr = getFunc(info, "projectconfig_var_addr", fn (?*anyopaque, c_int) callconv(.c) ?*anyopaque),
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

    /// Debug log - only outputs when DEBUG_LOGGING is true
    pub fn log(self: *const Api, comptime fmt: []const u8, args: anytype) void {
        if (!DEBUG_LOGGING) return;
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
        if (msg.len < buf.len) {
            buf[msg.len] = 0;
            self.showConsoleMsg(@ptrCast(&buf));
        }
    }

    /// Debug log (simple) - only outputs when DEBUG_LOGGING is true
    pub fn logSimple(self: *const Api, msg: [*:0]const u8) void {
        if (!DEBUG_LOGGING) return;
        self.showConsoleMsg(msg);
        self.showConsoleMsg("\n");
    }

    /// Always log - for critical messages that should appear regardless of DEBUG_LOGGING
    pub fn logAlways(self: *const Api, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
        if (msg.len < buf.len) {
            buf[msg.len] = 0;
            self.showConsoleMsg(@ptrCast(&buf));
        }
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

    pub fn setTimeSelection(self: *const Api, start: f64, end: f64) void {
        if (self.getSetLoopTimeRange2) |f| {
            var s = start;
            var e = end;
            f(null, true, false, &s, &e, false);
        }
    }

    pub fn clearTimeSelection(self: *const Api) void {
        self.setTimeSelection(0, 0);
    }

    // Repeat state: -1 = query, 0 = disable, 1 = enable
    pub fn getRepeat(self: *const Api) bool {
        const f = self.getSetRepeat orelse return false;
        return f(-1) != 0;
    }

    pub fn setRepeat(self: *const Api, enabled: bool) void {
        const f = self.getSetRepeat orelse return;
        _ = f(if (enabled) 1 else 0);
    }

    pub fn toggleRepeat(self: *const Api) void {
        self.setRepeat(!self.getRepeat());
    }

    // Tempo: set BPM for current project
    pub fn setTempo(self: *const Api, bpm: f64) void {
        const f = self.setCurrentBPM orelse return;
        // Clamp to REAPER's valid range (2-960 BPM)
        const clamped = @max(2.0, @min(960.0, bpm));
        f(null, clamped, true); // true = add undo point
    }

    // Command toggle state: returns 1 if on, 0 if off, -1 if not toggle command
    pub fn getCommandState(self: *const Api, cmd: c_int) c_int {
        const f = self.getToggleCommandState orelse return -1;
        return f(cmd);
    }

    // Metronome state
    pub fn isMetronomeEnabled(self: *const Api) bool {
        return self.getCommandState(Command.METRONOME_TOGGLE) == 1;
    }

    // ExtState: get global extended state value
    pub fn getExtStateValue(self: *const Api, section: [*:0]const u8, key: [*:0]const u8) ?[]const u8 {
        const f = self.getExtState orelse return null;
        const ptr = f(section, key) orelse return null;
        return std.mem.sliceTo(ptr, 0);
    }

    // ExtState: set global extended state (persist=true saves across sessions)
    pub fn setExtStateValue(self: *const Api, section: [*:0]const u8, key: [*:0]const u8, value: [*:0]const u8, persist: bool) void {
        const f = self.setExtState orelse return;
        f(section, key, value, if (persist) 1 else 0);
    }

    // ExtState: get project-specific extended state
    pub fn getProjExtStateValue(self: *const Api, extname: [*:0]const u8, key: [*:0]const u8, buf: []u8) ?[]const u8 {
        const f = self.getProjExtState orelse return null;
        const len = f(null, extname, key, buf.ptr, @intCast(buf.len));
        if (len <= 0) return null;
        return buf[0..@intCast(len)];
    }

    // ExtState: set project-specific extended state
    pub fn setProjExtStateValue(self: *const Api, extname: [*:0]const u8, key: [*:0]const u8, value: [*:0]const u8) void {
        const f = self.setProjExtState orelse return;
        _ = f(null, extname, key, value);
    }

    // Undo: begin an undo block
    pub fn undoBeginBlock(self: *const Api) void {
        const f = self.undo_BeginBlock2 orelse return;
        f(null);
    }

    // Undo: end an undo block with description
    pub fn undoEndBlock(self: *const Api, description: [*:0]const u8) void {
        const f = self.undo_EndBlock2 orelse return;
        f(null, description, -1); // -1 = all undo states
    }

    // Undo: add simple undo point
    pub fn undoAddPoint(self: *const Api, description: [*:0]const u8) void {
        const f = self.undo_OnStateChange orelse return;
        f(description);
    }

    // Time conversion: beats (quarter notes from project start) to seconds
    pub fn beatsToTime(self: *const Api, beats: f64) f64 {
        const f = self.timeMap2_beatsToTime orelse return 0;
        return f(null, beats, null);
    }

    // Time conversion: bar.beat to seconds
    // bar is 1-based, beat is 1-based (e.g., bar=1, beat=1 = start of project)
    pub fn barBeatToTime(self: *const Api, bar: c_int, beat: f64) f64 {
        const f = self.timeMap2_beatsToTime orelse return 0;
        // TimeMap2_beatsToTime with measures parameter converts measure-relative position
        // The tpos parameter is beats within the measure, measure number is passed separately
        const adjusted_bar = bar - 1; // Convert to 0-based for API
        return f(null, beat - 1.0, &adjusted_bar);
    }

    // Time conversion: seconds to beats info
    pub const BeatsInfo = struct {
        beats: f64, // Quarter notes from project start
        measures: c_int, // Measure number (1-based)
        beats_in_measure: f64, // Beat position within measure
        time_sig_denom: c_int, // Time signature denominator
    };

    pub fn timeToBeats(self: *const Api, time: f64) BeatsInfo {
        const f = self.timeMap2_timeToBeats orelse return .{
            .beats = 0,
            .measures = 1,
            .beats_in_measure = 1,
            .time_sig_denom = 4,
        };
        var measures: c_int = 0;
        var cml: c_int = 0; // beats since last measure
        var fullbeats: f64 = 0;
        var cdenom: c_int = 4;
        const beats = f(null, time, &measures, &cml, &fullbeats, &cdenom);
        return .{
            .beats = beats,
            .measures = measures + 1, // Convert to 1-based
            .beats_in_measure = fullbeats - @as(f64, @floatFromInt(cml)) + 1.0, // 1-based beat in measure
            .time_sig_denom = cdenom,
        };
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

    // Track control methods
    // Volume: 0..1..inf (0.5=-6dB, 1=0dB, 2=+6dB)
    pub fn getTrackVolume(self: *const Api, track: *anyopaque) f64 {
        const f = self.getMediaTrackInfo_Value orelse return 1.0;
        return f(track, "D_VOL");
    }

    pub fn setTrackVolume(self: *const Api, track: *anyopaque, vol: f64) bool {
        const f = self.setMediaTrackInfo_Value orelse return false;
        return f(track, "D_VOL", vol);
    }

    // Pan: -1.0 (left) to 1.0 (right)
    pub fn getTrackPan(self: *const Api, track: *anyopaque) f64 {
        const f = self.getMediaTrackInfo_Value orelse return 0.0;
        return f(track, "D_PAN");
    }

    pub fn setTrackPan(self: *const Api, track: *anyopaque, pan: f64) bool {
        const f = self.setMediaTrackInfo_Value orelse return false;
        return f(track, "D_PAN", pan);
    }

    // Mute: true/false
    pub fn getTrackMute(self: *const Api, track: *anyopaque) bool {
        const f = self.getMediaTrackInfo_Value orelse return false;
        return f(track, "B_MUTE") != 0;
    }

    pub fn setTrackMute(self: *const Api, track: *anyopaque, mute: bool) bool {
        const f = self.setMediaTrackInfo_Value orelse return false;
        return f(track, "B_MUTE", if (mute) 1.0 else 0.0);
    }

    // Solo: 0=not soloed, 1=soloed, 2=soloed in place, etc.
    pub fn getTrackSolo(self: *const Api, track: *anyopaque) c_int {
        const f = self.getMediaTrackInfo_Value orelse return 0;
        return @intFromFloat(f(track, "I_SOLO"));
    }

    pub fn setTrackSolo(self: *const Api, track: *anyopaque, solo: c_int) bool {
        const f = self.setMediaTrackInfo_Value orelse return false;
        return f(track, "I_SOLO", @floatFromInt(solo));
    }

    // Record arm: true/false
    pub fn getTrackRecArm(self: *const Api, track: *anyopaque) bool {
        const f = self.getMediaTrackInfo_Value orelse return false;
        return f(track, "I_RECARM") != 0;
    }

    pub fn setTrackRecArm(self: *const Api, track: *anyopaque, arm: bool) bool {
        const f = self.setMediaTrackInfo_Value orelse return false;
        return f(track, "I_RECARM", if (arm) 1.0 else 0.0);
    }

    // Record monitoring: 0=off, 1=normal, 2=not when playing
    pub fn getTrackRecMon(self: *const Api, track: *anyopaque) c_int {
        const f = self.getMediaTrackInfo_Value orelse return 0;
        return @intFromFloat(f(track, "I_RECMON"));
    }

    pub fn setTrackRecMon(self: *const Api, track: *anyopaque, mon: c_int) bool {
        const f = self.setMediaTrackInfo_Value orelse return false;
        return f(track, "I_RECMON", @floatFromInt(mon));
    }

    // FX enabled: true/false
    pub fn getTrackFxEnabled(self: *const Api, track: *anyopaque) bool {
        const f = self.getMediaTrackInfo_Value orelse return true;
        return f(track, "I_FXEN") != 0;
    }

    pub fn setTrackFxEnabled(self: *const Api, track: *anyopaque, enabled: bool) bool {
        const f = self.setMediaTrackInfo_Value orelse return false;
        return f(track, "I_FXEN", if (enabled) 1.0 else 0.0);
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

    // Metering methods

    /// Get track peak level (1.0 = 0dB, 0.0 = -inf)
    /// Channel: 0 = left, 1 = right
    pub fn getTrackPeakInfo(self: *const Api, track: *anyopaque, channel: c_int) f64 {
        const f = self.track_GetPeakInfo orelse return 0.0;
        return f(track, channel);
    }

    /// Get track peak hold in dB×0.01 (0 = 0dB, -100 = -1dB, 200 = +2dB)
    /// Set clear=true to reset the hold value
    pub fn getTrackPeakHoldDB(self: *const Api, track: *anyopaque, channel: c_int, clear: bool) f64 {
        const f = self.track_GetPeakHoldDB orelse return -10000.0;
        return f(track, channel, clear);
    }

    /// Clear peak hold for both channels of a track
    pub fn clearTrackPeakHold(self: *const Api, track: *anyopaque) void {
        _ = self.getTrackPeakHoldDB(track, 0, true);
        _ = self.getTrackPeakHoldDB(track, 1, true);
    }

    // Metronome volume methods

    // dB conversion constants
    const MIN_DB: f64 = -60.0; // Treat as -inf below this
    const MAX_DB: f64 = 12.0; // Maximum +12dB

    /// Convert linear amplitude to dB
    pub fn linearToDb(linear: f64) f64 {
        if (linear <= 0.0) return MIN_DB;
        const db = 20.0 * @log10(linear);
        return @max(MIN_DB, @min(MAX_DB, db));
    }

    /// Convert dB to linear amplitude
    pub fn dbToLinear(db: f64) f64 {
        if (db <= MIN_DB) return 0.0;
        return std.math.pow(f64, 10.0, db / 20.0);
    }

    /// Get metronome primary beat volume (linear amplitude, 0.0-4.0 range)
    pub fn getMetronomeVolume(self: *const Api) f64 {
        const getoffs = self.projectconfig_var_getoffs orelse return 1.0;
        const getaddr = self.projectconfig_var_addr orelse return 1.0;

        var sz: c_int = 0;
        const offs = getoffs("projmetrov1", &sz);
        if (offs < 0) return 1.0;
        if (sz != 8) return 1.0; // sizeof(f64)

        const ptr = getaddr(null, offs) orelse return 1.0;
        const vol_ptr: *f64 = @ptrCast(@alignCast(ptr));
        return vol_ptr.*;
    }

    /// Get metronome volume in dB (-60 to +12)
    pub fn getMetronomeVolumeDb(self: *const Api) f64 {
        return linearToDb(self.getMetronomeVolume());
    }

    /// Set metronome primary beat volume (linear amplitude)
    pub fn setMetronomeVolume(self: *const Api, vol: f64) bool {
        const getoffs = self.projectconfig_var_getoffs orelse return false;
        const getaddr = self.projectconfig_var_addr orelse return false;

        var sz: c_int = 0;
        const offs = getoffs("projmetrov1", &sz);
        if (offs < 0) return false;
        if (sz != 8) return false;

        const ptr = getaddr(null, offs) orelse return false;
        const vol_ptr: *f64 = @ptrCast(@alignCast(ptr));

        // Clamp to valid range (0.0 to ~4.0 for +12dB max)
        vol_ptr.* = @max(0.0, @min(4.0, vol));
        return true;
    }

    /// Set metronome volume in dB (-60 to +12)
    pub fn setMetronomeVolumeDb(self: *const Api, db: f64) bool {
        return self.setMetronomeVolume(dbToLinear(db));
    }
};

// REAPER action command IDs
pub const Command = struct {
    // Transport
    pub const PLAY: c_int = 1007;
    pub const PAUSE: c_int = 1008;
    pub const RECORD: c_int = 1013;
    pub const STOP: c_int = 1016; // Stop and save
    pub const ABORT_RECORDING: c_int = 40668; // Stop, delete recorded media
    pub const TOGGLE_REPEAT: c_int = 1068;

    // Navigation
    pub const GO_TO_PROJECT_START: c_int = 40042;
    pub const GO_TO_PROJECT_END: c_int = 40043;

    // Time selection
    pub const TIME_SEL_SET_START: c_int = 40625; // Set start at cursor
    pub const TIME_SEL_SET_END: c_int = 40626; // Set end at cursor
    pub const TIME_SEL_CLEAR: c_int = 40020; // Remove time selection
    pub const TIME_SEL_GO_START: c_int = 40630; // Go to start of selection
    pub const TIME_SEL_GO_END: c_int = 40631; // Go to end of selection

    // Take commands (operate on selected item's active take)
    pub const DELETE_ACTIVE_TAKE: c_int = 40129;
    pub const CROP_TO_ACTIVE_TAKE: c_int = 40131;
    pub const NEXT_TAKE: c_int = 40125; // Activate next take in items
    pub const PREV_TAKE: c_int = 40126; // Activate previous take in items

    // Item selection
    pub const UNSELECT_ALL_ITEMS: c_int = 40289;
    pub const SELECT_ALL_ITEMS_IN_TIME_SEL: c_int = 40717; // All tracks in time selection

    // Marker navigation
    pub const GO_TO_PREV_MARKER: c_int = 40172; // Go to previous marker/project start
    pub const GO_TO_NEXT_MARKER: c_int = 40173; // Go to next marker/project end

    // Metronome
    pub const METRONOME_TOGGLE: c_int = 40364; // Toggle metronome

    // Tempo
    pub const TAP_TEMPO: c_int = 1134; // Tap tempo
};
