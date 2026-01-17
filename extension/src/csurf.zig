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
const csurf_dirty = @import("csurf_dirty.zig");
const guid_cache = @import("guid_cache.zig");

/// Whether CSurf is enabled at compile time
pub const enabled = csurf_options.enable_csurf;

// Module-level access to dirty flags and guid cache.
// Set by main.zig during initialization (Phase 4).
// CSurf callbacks use these to set dirty flags for push-based polling.
var g_dirty_flags: ?*csurf_dirty.DirtyFlags = null;
var g_guid_cache: ?*guid_cache.GuidCache = null;

/// Called by main.zig to provide access to dirty flags and guid cache.
/// Must be called after both are initialized but before CSurf registration.
pub fn setDirtyFlagsAndCache(flags: ?*csurf_dirty.DirtyFlags, cache: ?*guid_cache.GuidCache) void {
    g_dirty_flags = flags;
    g_guid_cache = cache;
}

/// Helper to resolve track pointer to unified index using GuidCache reverse map.
/// Returns null if track is null, cache is unavailable, or track not found.
fn resolveTrackIndex(track: ?*anyopaque) ?c_int {
    const t = track orelse return null;
    const cache = g_guid_cache orelse return null;
    return cache.resolveToIndex(t);
}

// CSURF_EXT_* notification codes from reaper_csurf.h
pub const ExtCode = struct {
    pub const RESET: c_int = 0x0001FFFF;
    pub const SETSENDVOLUME: c_int = 0x00010005;
    pub const SETSENDPAN: c_int = 0x00010006;
    pub const SETFXENABLED: c_int = 0x00010007;
    pub const SETFXPARAM: c_int = 0x00010008;
    pub const SETBPMANDPLAYRATE: c_int = 0x00010009;
    pub const SETRECVVOLUME: c_int = 0x00010010;
    pub const SETRECVPAN: c_int = 0x00010011;
    pub const SETFXCHANGE: c_int = 0x00010013;
    pub const SETPROJECTMARKERCHANGE: c_int = 0x00010014;
    pub const SETFXPARAM_RECFX: c_int = 0x00010018; // Input/monitoring FX parameter
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

    /// Called when transport state changes (play/pause/record).
    /// Sets transport_dirty flag for main loop to poll current state.
    fn setPlayState(ctx: ?*anyopaque, play: bool, pause: bool, rec: bool) callconv(.c) void {
        _ = ctx;
        _ = play;
        _ = pause;
        _ = rec;

        // Set dirty flag - main loop will poll and broadcast actual state
        if (g_dirty_flags) |flags| {
            flags.transport_dirty = true;
        }
    }

    fn setRepeatState(ctx: ?*anyopaque, rep: bool) callconv(.c) void {
        const self = getSelf(ctx) orelse return;

        var buf: [64]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "{{\"type\":\"event\",\"event\":\"csurfRepeat\",\"repeat\":{}}}", .{rep}) catch return;
        self.shared_state.broadcast(json);

        logging.debug("CSurf: SetRepeatState repeat={}", .{rep});
    }

    /// Called when track list changes (add/remove/reorder).
    /// Sets skeleton_dirty and invalidates reverse_map until rebuild.
    /// SWS pattern: Don't rebuild here - wait for callback burst to settle.
    fn setTrackListChange(ctx: ?*anyopaque) callconv(.c) void {
        _ = ctx;

        if (g_dirty_flags) |flags| {
            flags.skeleton_dirty = true;
            flags.reverse_map_valid = false; // Mark stale until rebuild in main loop
        }
    }

    /// Called when track volume changes.
    /// Research: Called at ~30Hz during automation playback, no built-in debouncing.
    fn setSurfaceVolume(ctx: ?*anyopaque, track: MediaTrackHandle, vol: f64) callconv(.c) void {
        _ = ctx;
        _ = vol;
        const flags = g_dirty_flags orelse return;
        if (!flags.reverse_map_valid) return; // Skip until map rebuilt
        const track_idx = resolveTrackIndex(track) orelse return;
        if (track_idx >= 0) flags.setTrackDirty(@intCast(track_idx));
    }

    /// Called when track pan changes.
    fn setSurfacePan(ctx: ?*anyopaque, track: MediaTrackHandle, pan: f64) callconv(.c) void {
        _ = ctx;
        _ = pan;
        const flags = g_dirty_flags orelse return;
        if (!flags.reverse_map_valid) return;
        const track_idx = resolveTrackIndex(track) orelse return;
        if (track_idx >= 0) flags.setTrackDirty(@intCast(track_idx));
    }

    /// Called when track mute changes.
    fn setSurfaceMute(ctx: ?*anyopaque, track: MediaTrackHandle, mute: bool) callconv(.c) void {
        _ = ctx;
        _ = mute;
        const flags = g_dirty_flags orelse return;
        if (!flags.reverse_map_valid) return;
        const track_idx = resolveTrackIndex(track) orelse return;
        if (track_idx >= 0) flags.setTrackDirty(@intCast(track_idx));
    }

    /// Called when track solo changes.
    fn setSurfaceSolo(ctx: ?*anyopaque, track: MediaTrackHandle, solo: bool) callconv(.c) void {
        _ = ctx;
        _ = solo;
        const flags = g_dirty_flags orelse return;
        if (!flags.reverse_map_valid) return;
        const track_idx = resolveTrackIndex(track) orelse return;
        if (track_idx >= 0) flags.setTrackDirty(@intCast(track_idx));
    }

    /// Called when track selection changes (fires per-track).
    fn setSurfaceSelected(ctx: ?*anyopaque, track: MediaTrackHandle, selected: bool) callconv(.c) void {
        _ = ctx;
        _ = selected;
        const flags = g_dirty_flags orelse return;
        if (!flags.reverse_map_valid) return;
        const track_idx = resolveTrackIndex(track) orelse return;
        if (track_idx >= 0) flags.setTrackDirty(@intCast(track_idx));
    }

    /// Called when track record arm changes.
    fn setSurfaceRecArm(ctx: ?*anyopaque, track: MediaTrackHandle, arm: bool) callconv(.c) void {
        _ = ctx;
        _ = arm;
        const flags = g_dirty_flags orelse return;
        if (!flags.reverse_map_valid) return;
        const track_idx = resolveTrackIndex(track) orelse return;
        if (track_idx >= 0) flags.setTrackDirty(@intCast(track_idx));
    }

    /// Called when track selection changes (alternative callback).
    fn onTrackSelection(ctx: ?*anyopaque, track: MediaTrackHandle) callconv(.c) void {
        _ = ctx;
        const flags = g_dirty_flags orelse return;
        if (!flags.reverse_map_valid) return;
        const track_idx = resolveTrackIndex(track) orelse return;
        if (track_idx >= 0) flags.setTrackDirty(@intCast(track_idx));
    }

    /// Extended callbacks for FX, markers, sends, tempo.
    /// CRITICAL: Always return 0 per SWS best practice - never consume callbacks.
    /// Return value semantics are undocumented; defensive coding says propagate to all surfaces.
    fn extended(ctx: ?*anyopaque, call: c_int, p1: ?*anyopaque, p2: ?*anyopaque, p3: ?*anyopaque) callconv(.c) c_int {
        _ = ctx;
        _ = p2;
        _ = p3;

        const flags = g_dirty_flags orelse return 0;

        switch (call) {
            ExtCode.SETPROJECTMARKERCHANGE => {
                flags.markers_dirty = true;
            },
            ExtCode.SETFXPARAM, ExtCode.SETFXPARAM_RECFX => {
                // FX parameter changed - parm1=track
                // Research: 43-187 callbacks/sec per automated parameter
                // Just set dirty flag - polling handles debouncing
                if (!flags.reverse_map_valid) return 0;
                const track_idx = resolveTrackIndex(p1) orelse return 0;
                if (track_idx >= 0) flags.setFxDirty(@intCast(track_idx));
            },
            ExtCode.SETFXENABLED => {
                // FX bypass toggled - parm1=track
                if (!flags.reverse_map_valid) return 0;
                const track_idx = resolveTrackIndex(p1) orelse return 0;
                if (track_idx >= 0) flags.setFxDirty(@intCast(track_idx));
            },
            ExtCode.SETBPMANDPLAYRATE => {
                flags.tempo_dirty = true;
            },
            ExtCode.SETFXCHANGE => {
                // FX added/removed/reordered - need skeleton refresh
                flags.skeleton_dirty = true;
            },
            ExtCode.SETSENDVOLUME, ExtCode.SETSENDPAN => {
                // Send volume/pan changed - parm1=track
                if (!flags.reverse_map_valid) return 0;
                const track_idx = resolveTrackIndex(p1) orelse return 0;
                if (track_idx >= 0) flags.setSendsDirty(@intCast(track_idx));
            },
            ExtCode.SETRECVVOLUME, ExtCode.SETRECVPAN => {
                // Receive volume/pan changed - parm1=track
                if (!flags.reverse_map_valid) return 0;
                const track_idx = resolveTrackIndex(p1) orelse return 0;
                if (track_idx >= 0) flags.setSendsDirty(@intCast(track_idx));
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
