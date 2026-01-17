/// CSurf (Control Surface) integration module
///
/// Provides push-based callbacks from REAPER via IReaperControlSurface.
/// This replaces some 30Hz polling with instant notifications for:
/// - Transport state (play/pause/record)
/// - Track volume/pan/mute/solo/selection
/// - FX parameter changes
/// - Marker/region changes
///
/// When built with -Dcsurf=true, uses C++ shim for IReaperControlSurface.
/// When disabled, provides no-op stubs.
///
/// See: research/ZIG_CONTROL_SURFACE.md

const std = @import("std");
const logging = @import("logging.zig");
const ws_server = @import("ws_server.zig");
const csurf_options = @import("csurf_options");

/// Whether CSurf is enabled at compile time
pub const enabled = csurf_options.enable_csurf;

// CSURF_EXT_* notification codes
pub const ExtCode = struct {
    pub const RESET: c_int = 0x0001FFFF;
    pub const SETFXPARAM: c_int = 0x00010008;
    pub const SETFXENABLED: c_int = 0x00010007;
    pub const SETFXCHANGE: c_int = 0x00010013;
    pub const SETPROJECTMARKERCHANGE: c_int = 0x00010014;
    pub const SETBPMANDPLAYRATE: c_int = 0x00010009;
    pub const SETSENDVOLUME: c_int = 0x00010005;
    pub const SETSENDPAN: c_int = 0x00010006;
    pub const SETRECVVOLUME: c_int = 0x00010010;
    pub const SETRECVPAN: c_int = 0x00010011;
};

/// Control Surface bridge - receives push notifications from REAPER
/// Conditional implementation based on build flags
pub const ControlSurface = if (enabled) RealControlSurface else StubControlSurface;

/// Stub implementation when CSurf is disabled - all methods are no-ops
const StubControlSurface = struct {
    const Self = @This();

    pub fn init(
        _: *ws_server.SharedState,
        _: *const fn ([*:0]const u8, ?*anyopaque) callconv(.c) c_int,
    ) !Self {
        return Self{};
    }

    pub fn register(_: *Self) bool {
        return false;
    }

    pub fn unregister(_: *Self) void {}

    pub fn deinit(_: *Self) void {}
};

/// Real implementation when CSurf is enabled
const RealControlSurface = struct {
    // C API types from the shim
    const ZigCSurfHandle = ?*anyopaque;
    const MediaTrackHandle = ?*anyopaque;
    const PluginRegisterFn = ?*const fn ([*:0]const u8, ?*anyopaque) callconv(.c) c_int;

    // Callback function pointer types
    const ZigGetStringCb = ?*const fn (?*anyopaque) callconv(.c) [*:0]const u8;
    const ZigRunCb = ?*const fn (?*anyopaque) callconv(.c) void;
    const ZigSetPlayStateCb = ?*const fn (?*anyopaque, bool, bool, bool) callconv(.c) void;
    const ZigSetRepeatStateCb = ?*const fn (?*anyopaque, bool) callconv(.c) void;
    const ZigSetTrackListChangeCb = ?*const fn (?*anyopaque) callconv(.c) void;
    const ZigSetSurfaceVolumeCb = ?*const fn (?*anyopaque, MediaTrackHandle, f64) callconv(.c) void;
    const ZigSetSurfacePanCb = ?*const fn (?*anyopaque, MediaTrackHandle, f64) callconv(.c) void;
    const ZigSetSurfaceMuteCb = ?*const fn (?*anyopaque, MediaTrackHandle, bool) callconv(.c) void;
    const ZigSetSurfaceSoloCb = ?*const fn (?*anyopaque, MediaTrackHandle, bool) callconv(.c) void;
    const ZigSetSurfaceSelectedCb = ?*const fn (?*anyopaque, MediaTrackHandle, bool) callconv(.c) void;
    const ZigSetSurfaceRecArmCb = ?*const fn (?*anyopaque, MediaTrackHandle, bool) callconv(.c) void;
    const ZigOnTrackSelectionCb = ?*const fn (?*anyopaque, MediaTrackHandle) callconv(.c) void;
    const ZigSetAutoModeCb = ?*const fn (?*anyopaque, c_int) callconv(.c) void;
    const ZigExtendedCb = ?*const fn (?*anyopaque, c_int, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) c_int;

    // Callback struct passed to C++ shim
    const ZigCSurfCallbacks = extern struct {
        user_context: ?*anyopaque,
        get_type_string: ZigGetStringCb,
        get_desc_string: ZigGetStringCb,
        run: ZigRunCb,
        set_play_state: ZigSetPlayStateCb,
        set_repeat_state: ZigSetRepeatStateCb,
        set_track_list_change: ZigSetTrackListChangeCb,
        set_surface_volume: ZigSetSurfaceVolumeCb,
        set_surface_pan: ZigSetSurfacePanCb,
        set_surface_mute: ZigSetSurfaceMuteCb,
        set_surface_solo: ZigSetSurfaceSoloCb,
        set_surface_selected: ZigSetSurfaceSelectedCb,
        set_surface_rec_arm: ZigSetSurfaceRecArmCb,
        on_track_selection: ZigOnTrackSelectionCb,
        set_auto_mode: ZigSetAutoModeCb,
        extended: ZigExtendedCb,
    };

    // C API functions from the shim
    extern fn zig_csurf_create(callbacks: *const ZigCSurfCallbacks) ZigCSurfHandle;
    extern fn zig_csurf_destroy(handle: ZigCSurfHandle) void;
    extern fn zig_csurf_register(handle: ZigCSurfHandle, plugin_register: PluginRegisterFn) bool;
    extern fn zig_csurf_unregister(handle: ZigCSurfHandle, plugin_register: PluginRegisterFn) void;

    // Instance fields
    handle: ZigCSurfHandle,
    shared_state: *ws_server.SharedState,
    plugin_register: PluginRegisterFn,
    is_playing: bool = false,

    const Self = @This();

    /// Create a new control surface bridge
    pub fn init(
        shared_state: *ws_server.SharedState,
        plugin_register: *const fn ([*:0]const u8, ?*anyopaque) callconv(.c) c_int,
    ) !Self {
        var self = Self{
            .handle = null,
            .shared_state = shared_state,
            .plugin_register = plugin_register,
        };

        const callbacks = ZigCSurfCallbacks{
            .user_context = @ptrCast(&self),
            .get_type_string = getTypeString,
            .get_desc_string = getDescString,
            .run = null, // We use timer callback instead of Run()
            .set_play_state = setPlayState,
            .set_repeat_state = setRepeatState,
            .set_track_list_change = setTrackListChange,
            .set_surface_volume = setSurfaceVolume,
            .set_surface_pan = setSurfacePan,
            .set_surface_mute = setSurfaceMute,
            .set_surface_solo = setSurfaceSolo,
            .set_surface_selected = setSurfaceSelected,
            .set_surface_rec_arm = setSurfaceRecArm,
            .on_track_selection = onTrackSelection,
            .set_auto_mode = null,
            .extended = extended,
        };

        self.handle = zig_csurf_create(&callbacks);
        if (self.handle == null) {
            return error.CSurfCreateFailed;
        }

        return self;
    }

    /// Register with REAPER
    pub fn register(self: *Self) bool {
        if (self.handle == null) return false;
        return zig_csurf_register(self.handle, self.plugin_register);
    }

    /// Unregister from REAPER
    pub fn unregister(self: *Self) void {
        if (self.handle == null) return;
        zig_csurf_unregister(self.handle, self.plugin_register);
    }

    /// Destroy the control surface
    pub fn deinit(self: *Self) void {
        if (self.handle) |handle| {
            zig_csurf_destroy(handle);
            self.handle = null;
        }
    }

    // ========================================================================
    // Callback implementations - called from C++ shim
    // ========================================================================

    fn getTypeString(_: ?*anyopaque) callconv(.c) [*:0]const u8 {
        return "reamo_ws";
    }

    fn getDescString(_: ?*anyopaque) callconv(.c) [*:0]const u8 {
        return "REAmo WebSocket Control Surface";
    }

    fn setPlayState(ctx: ?*anyopaque, play: bool, pause: bool, rec: bool) callconv(.c) void {
        const self = getSelf(ctx) orelse return;
        self.is_playing = play and !pause;

        // Broadcast transport state change
        var buf: [128]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "{{\"type\":\"event\",\"event\":\"csurfTransport\",\"play\":{},\"pause\":{},\"rec\":{}}}", .{
            play, pause, rec,
        }) catch return;
        self.shared_state.broadcast(json);

        logging.debug("CSurf: SetPlayState play={} pause={} rec={}", .{ play, pause, rec });
    }

    fn setRepeatState(ctx: ?*anyopaque, rep: bool) callconv(.c) void {
        const self = getSelf(ctx) orelse return;

        var buf: [64]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "{{\"type\":\"event\",\"event\":\"csurfRepeat\",\"repeat\":{}}}", .{rep}) catch return;
        self.shared_state.broadcast(json);

        logging.debug("CSurf: SetRepeatState repeat={}", .{rep});
    }

    fn setTrackListChange(ctx: ?*anyopaque) callconv(.c) void {
        const self = getSelf(ctx) orelse return;

        // Signal track list changed - frontend should re-fetch skeleton
        self.shared_state.broadcast("{\"type\":\"event\",\"event\":\"csurfTrackListChange\"}");

        logging.debug("CSurf: SetTrackListChange", .{});
    }

    fn setSurfaceVolume(ctx: ?*anyopaque, track: MediaTrackHandle, vol: f64) callconv(.c) void {
        const self = getSelf(ctx) orelse return;
        _ = track; // TODO: Map track pointer to index

        // TODO: Debounce and batch these updates
        _ = vol;
        _ = self;
    }

    fn setSurfacePan(ctx: ?*anyopaque, track: MediaTrackHandle, pan: f64) callconv(.c) void {
        const self = getSelf(ctx) orelse return;
        _ = track;
        _ = pan;
        _ = self;
    }

    fn setSurfaceMute(ctx: ?*anyopaque, track: MediaTrackHandle, mute: bool) callconv(.c) void {
        const self = getSelf(ctx) orelse return;
        _ = track;
        _ = mute;
        _ = self;
    }

    fn setSurfaceSolo(ctx: ?*anyopaque, track: MediaTrackHandle, solo: bool) callconv(.c) void {
        const self = getSelf(ctx) orelse return;
        _ = track;
        _ = solo;
        _ = self;
    }

    fn setSurfaceSelected(ctx: ?*anyopaque, track: MediaTrackHandle, selected: bool) callconv(.c) void {
        const self = getSelf(ctx) orelse return;
        _ = track;
        _ = selected;
        // Note: This fires per-track - should debounce before broadcasting
        _ = self;
    }

    fn setSurfaceRecArm(ctx: ?*anyopaque, track: MediaTrackHandle, arm: bool) callconv(.c) void {
        const self = getSelf(ctx) orelse return;
        _ = track;
        _ = arm;
        _ = self;
    }

    fn onTrackSelection(ctx: ?*anyopaque, track: MediaTrackHandle) callconv(.c) void {
        const self = getSelf(ctx) orelse return;
        _ = track;
        _ = self;
    }

    /// Extended callbacks for FX, markers, sends, tempo
    /// CRITICAL: Always return 0 per SWS best practice - never consume callbacks.
    /// Return value semantics are undocumented; defensive coding says propagate to all surfaces.
    fn extended(ctx: ?*anyopaque, call: c_int, p1: ?*anyopaque, p2: ?*anyopaque, p3: ?*anyopaque) callconv(.c) c_int {
        const self = getSelf(ctx) orelse return 0;

        switch (call) {
            ExtCode.SETPROJECTMARKERCHANGE => {
                // Marker/region changed - signal frontend to re-fetch
                self.shared_state.broadcast("{\"type\":\"event\",\"event\":\"csurfMarkersChange\"}");
                logging.debug("CSurf: Extended SETPROJECTMARKERCHANGE", .{});
            },
            ExtCode.SETFXPARAM => {
                // FX parameter changed
                // parm1=track, parm2=packed_val (fxidx<<16|paramidx), parm3=value
                _ = p1;
                if (p2) |packed_ptr| {
                    if (p3) |value_ptr| {
                        const packed_val: c_int = @as(*c_int, @ptrCast(@alignCast(packed_ptr))).*;
                        const value: f64 = @as(*f64, @ptrCast(@alignCast(value_ptr))).*;
                        const fxidx = @as(u16, @truncate(@as(u32, @bitCast(packed_val)) >> 16));
                        const paramidx = @as(u16, @truncate(@as(u32, @bitCast(packed_val))));
                        _ = fxidx;
                        _ = paramidx;
                        _ = value;
                        // TODO: Debounce and batch FX param updates
                    }
                }
            },
            ExtCode.SETBPMANDPLAYRATE => {
                // BPM or playrate changed
                self.shared_state.broadcast("{\"type\":\"event\",\"event\":\"csurfTempoChange\"}");
                logging.debug("CSurf: Extended SETBPMANDPLAYRATE", .{});
            },
            ExtCode.SETFXCHANGE => {
                // FX added/removed/reordered
                self.shared_state.broadcast("{\"type\":\"event\",\"event\":\"csurfFxChange\"}");
                logging.debug("CSurf: Extended SETFXCHANGE", .{});
            },
            else => {},
        }
        return 0; // ALWAYS 0 - never consume callbacks
    }

    /// Helper to get self from context pointer
    fn getSelf(ctx: ?*anyopaque) ?*Self {
        return @as(?*Self, @ptrCast(@alignCast(ctx)));
    }
};

test "ControlSurface basic" {
    // Can't test without REAPER, but ensure types compile
    _ = ControlSurface;
    _ = ExtCode;
}
