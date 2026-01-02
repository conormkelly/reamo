/// Abstract API interface for REAPER functions.
/// Enables dependency injection of mock implementations for testing.
///
/// Usage:
///   // Production: wrap real API
///   var real = RealApi{ .inner = &raw_api };
///   const api = real.interface();
///
///   // Testing: use mock
///   var mock = MockApi{};
///   const api = mock.interface();
///
///   // Both can be passed to state modules
///   const state = transport.poll(api);
const std = @import("std");
const raw = @import("raw.zig");
const types = @import("types.zig");
const ffi = @import("../ffi.zig");

// Re-export types
pub const BeatsInfo = types.BeatsInfo;
pub const TempoAtPosition = types.TempoAtPosition;
pub const TempoMarker = types.TempoMarker;
pub const TimeSelection = types.TimeSelection;
pub const TimeSignature = types.TimeSignature;
pub const MarkerInfo = types.MarkerInfo;
pub const MarkerCount = types.MarkerCount;

/// Abstract API interface using vtable pattern.
/// Matches std.mem.Allocator design - zero overhead, testable.
pub const ApiInterface = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        // =========================================================================
        // Transport
        // =========================================================================
        playState: *const fn (*anyopaque) c_int,
        playPosition: *const fn (*anyopaque) f64,
        cursorPosition: *const fn (*anyopaque) f64,
        timePrecise: *const fn (*anyopaque) f64,
        timePreciseMs: *const fn (*anyopaque) f64,

        // =========================================================================
        // Time conversion
        // =========================================================================
        timeToBeats: *const fn (*anyopaque, f64) BeatsInfo,
        beatsToTime: *const fn (*anyopaque, f64) f64,
        barBeatToTime: *const fn (*anyopaque, c_int, f64) f64,

        // =========================================================================
        // Tempo / Time signature
        // =========================================================================
        timeSignature: *const fn (*anyopaque) TimeSignature,
        getTempoAtPosition: *const fn (*anyopaque, f64) TempoAtPosition,
        tempoMarkerCount: *const fn (*anyopaque) c_int,
        getTempoMarker: *const fn (*anyopaque, c_int) ?TempoMarker,
        getBarOffset: *const fn (*anyopaque) c_int,
        getTimeSignatureNumerator: *const fn (*anyopaque) c_int,
        getTimeSignatureDenominator: *const fn (*anyopaque) c_int,

        // =========================================================================
        // Time selection
        // =========================================================================
        timeSelection: *const fn (*anyopaque) TimeSelection,

        // =========================================================================
        // Repeat
        // =========================================================================
        getRepeat: *const fn (*anyopaque) bool,

        // =========================================================================
        // Project info
        // =========================================================================
        projectLength: *const fn (*anyopaque) f64,
        projectStateChangeCount: *const fn (*anyopaque) c_int,
        isDirty: *const fn (*anyopaque) bool,

        // =========================================================================
        // Command state
        // =========================================================================
        getCommandState: *const fn (*anyopaque, c_int) c_int,
        isMetronomeEnabled: *const fn (*anyopaque) bool,

        // =========================================================================
        // Tracks
        // =========================================================================
        trackCount: *const fn (*anyopaque) c_int,
        getTrackByIdx: *const fn (*anyopaque, c_int) ?*anyopaque,
        getTrackByUnifiedIdx: *const fn (*anyopaque, c_int) ?*anyopaque,
        masterTrack: *const fn (*anyopaque) ?*anyopaque,
        getTrackNameStr: *const fn (*anyopaque, *anyopaque, []u8) []const u8,
        getTrackVolume: *const fn (*anyopaque, *anyopaque) f64,
        getTrackPan: *const fn (*anyopaque, *anyopaque) f64,
        getTrackMute: *const fn (*anyopaque, *anyopaque) bool,
        getTrackSolo: *const fn (*anyopaque, *anyopaque) ffi.FFIError!c_int,
        getTrackRecArm: *const fn (*anyopaque, *anyopaque) bool,
        getTrackRecMon: *const fn (*anyopaque, *anyopaque) ffi.FFIError!c_int,
        getTrackFxEnabled: *const fn (*anyopaque, *anyopaque) bool,
        getTrackSelected: *const fn (*anyopaque, *anyopaque) bool,
        getTrackColor: *const fn (*anyopaque, *anyopaque) c_int,
        isMasterMuted: *const fn (*anyopaque) bool,
        isMasterSoloed: *const fn (*anyopaque) bool,

        // =========================================================================
        // Items
        // =========================================================================
        trackItemCount: *const fn (*anyopaque, *anyopaque) c_int,
        getItemByIdx: *const fn (*anyopaque, *anyopaque, c_int) ?*anyopaque,
        getItemPosition: *const fn (*anyopaque, *anyopaque) f64,
        getItemLength: *const fn (*anyopaque, *anyopaque) f64,
        getItemColor: *const fn (*anyopaque, *anyopaque) c_int,
        getItemLocked: *const fn (*anyopaque, *anyopaque) bool,
        getItemSelected: *const fn (*anyopaque, *anyopaque) bool,
        getItemActiveTakeIdx: *const fn (*anyopaque, *anyopaque) c_int,
        getItemNotes: *const fn (*anyopaque, *anyopaque, []u8) []const u8,
        getItemGUID: *const fn (*anyopaque, *anyopaque, []u8) []const u8,

        // =========================================================================
        // Takes
        // =========================================================================
        itemTakeCount: *const fn (*anyopaque, *anyopaque) c_int,
        getTakeByIdx: *const fn (*anyopaque, *anyopaque, c_int) ?*anyopaque,
        getItemActiveTake: *const fn (*anyopaque, *anyopaque) ?*anyopaque,
        getTakeNameStr: *const fn (*anyopaque, *anyopaque) []const u8,
        getTakeGUID: *const fn (*anyopaque, *anyopaque, []u8) []const u8,
        getTakeStartOffset: *const fn (*anyopaque, *anyopaque) f64,
        getTakePlayrate: *const fn (*anyopaque, *anyopaque) f64,
        isTakeMIDI: *const fn (*anyopaque, *anyopaque) bool,
        getTakeSource: *const fn (*anyopaque, *anyopaque) ?*anyopaque,
        getMediaSourceChannels: *const fn (*anyopaque, *anyopaque) c_int,

        // =========================================================================
        // Markers
        // =========================================================================
        markerCount: *const fn (*anyopaque) MarkerCount,
        enumMarker: *const fn (*anyopaque, c_int) ?MarkerInfo,

        // =========================================================================
        // Metering
        // =========================================================================
        getTrackPeakInfo: *const fn (*anyopaque, *anyopaque, c_int) f64,

        // =========================================================================
        // ExtState
        // =========================================================================
        getExtStateValue: *const fn (*anyopaque, [*:0]const u8, [*:0]const u8) ?[]const u8,
        getProjExtStateValue: *const fn (*anyopaque, [*:0]const u8, [*:0]const u8, []u8) ?[]const u8,
    };

    // =========================================================================
    // Ergonomic wrapper methods (inline for performance)
    // =========================================================================

    // Transport
    pub inline fn playState(self: ApiInterface) c_int {
        return self.vtable.playState(self.ptr);
    }

    pub inline fn playPosition(self: ApiInterface) f64 {
        return self.vtable.playPosition(self.ptr);
    }

    pub inline fn cursorPosition(self: ApiInterface) f64 {
        return self.vtable.cursorPosition(self.ptr);
    }

    pub inline fn timePrecise(self: ApiInterface) f64 {
        return self.vtable.timePrecise(self.ptr);
    }

    pub inline fn timePreciseMs(self: ApiInterface) f64 {
        return self.vtable.timePreciseMs(self.ptr);
    }

    // Time conversion
    pub inline fn timeToBeats(self: ApiInterface, time: f64) BeatsInfo {
        return self.vtable.timeToBeats(self.ptr, time);
    }

    pub inline fn beatsToTime(self: ApiInterface, beats: f64) f64 {
        return self.vtable.beatsToTime(self.ptr, beats);
    }

    pub inline fn barBeatToTime(self: ApiInterface, bar: c_int, beat: f64) f64 {
        return self.vtable.barBeatToTime(self.ptr, bar, beat);
    }

    // Tempo / Time signature
    pub inline fn timeSignature(self: ApiInterface) TimeSignature {
        return self.vtable.timeSignature(self.ptr);
    }

    pub inline fn getTempoAtPosition(self: ApiInterface, time: f64) TempoAtPosition {
        return self.vtable.getTempoAtPosition(self.ptr, time);
    }

    pub inline fn tempoMarkerCount(self: ApiInterface) c_int {
        return self.vtable.tempoMarkerCount(self.ptr);
    }

    pub inline fn getTempoMarker(self: ApiInterface, idx: c_int) ?TempoMarker {
        return self.vtable.getTempoMarker(self.ptr, idx);
    }

    pub inline fn getBarOffset(self: ApiInterface) c_int {
        return self.vtable.getBarOffset(self.ptr);
    }

    pub inline fn getTimeSignatureNumerator(self: ApiInterface) c_int {
        return self.vtable.getTimeSignatureNumerator(self.ptr);
    }

    pub inline fn getTimeSignatureDenominator(self: ApiInterface) c_int {
        return self.vtable.getTimeSignatureDenominator(self.ptr);
    }

    // Time selection
    pub inline fn timeSelection(self: ApiInterface) TimeSelection {
        return self.vtable.timeSelection(self.ptr);
    }

    // Repeat
    pub inline fn getRepeat(self: ApiInterface) bool {
        return self.vtable.getRepeat(self.ptr);
    }

    // Project info
    pub inline fn projectLength(self: ApiInterface) f64 {
        return self.vtable.projectLength(self.ptr);
    }

    pub inline fn projectStateChangeCount(self: ApiInterface) c_int {
        return self.vtable.projectStateChangeCount(self.ptr);
    }

    pub inline fn isDirty(self: ApiInterface) bool {
        return self.vtable.isDirty(self.ptr);
    }

    // Command state
    pub inline fn getCommandState(self: ApiInterface, cmd: c_int) c_int {
        return self.vtable.getCommandState(self.ptr, cmd);
    }

    pub inline fn isMetronomeEnabled(self: ApiInterface) bool {
        return self.vtable.isMetronomeEnabled(self.ptr);
    }

    // Tracks
    pub inline fn trackCount(self: ApiInterface) c_int {
        return self.vtable.trackCount(self.ptr);
    }

    pub inline fn getTrackByIdx(self: ApiInterface, idx: c_int) ?*anyopaque {
        return self.vtable.getTrackByIdx(self.ptr, idx);
    }

    pub inline fn getTrackByUnifiedIdx(self: ApiInterface, idx: c_int) ?*anyopaque {
        return self.vtable.getTrackByUnifiedIdx(self.ptr, idx);
    }

    pub inline fn masterTrack(self: ApiInterface) ?*anyopaque {
        return self.vtable.masterTrack(self.ptr);
    }

    pub inline fn getTrackNameStr(self: ApiInterface, track: *anyopaque, buf: []u8) []const u8 {
        return self.vtable.getTrackNameStr(self.ptr, track, buf);
    }

    pub inline fn getTrackVolume(self: ApiInterface, track: *anyopaque) f64 {
        return self.vtable.getTrackVolume(self.ptr, track);
    }

    pub inline fn getTrackPan(self: ApiInterface, track: *anyopaque) f64 {
        return self.vtable.getTrackPan(self.ptr, track);
    }

    pub inline fn getTrackMute(self: ApiInterface, track: *anyopaque) bool {
        return self.vtable.getTrackMute(self.ptr, track);
    }

    pub inline fn getTrackSolo(self: ApiInterface, track: *anyopaque) ffi.FFIError!c_int {
        return self.vtable.getTrackSolo(self.ptr, track);
    }

    pub inline fn getTrackRecArm(self: ApiInterface, track: *anyopaque) bool {
        return self.vtable.getTrackRecArm(self.ptr, track);
    }

    pub inline fn getTrackRecMon(self: ApiInterface, track: *anyopaque) ffi.FFIError!c_int {
        return self.vtable.getTrackRecMon(self.ptr, track);
    }

    pub inline fn getTrackFxEnabled(self: ApiInterface, track: *anyopaque) bool {
        return self.vtable.getTrackFxEnabled(self.ptr, track);
    }

    pub inline fn getTrackSelected(self: ApiInterface, track: *anyopaque) bool {
        return self.vtable.getTrackSelected(self.ptr, track);
    }

    pub inline fn getTrackColor(self: ApiInterface, track: *anyopaque) c_int {
        return self.vtable.getTrackColor(self.ptr, track);
    }

    pub inline fn isMasterMuted(self: ApiInterface) bool {
        return self.vtable.isMasterMuted(self.ptr);
    }

    pub inline fn isMasterSoloed(self: ApiInterface) bool {
        return self.vtable.isMasterSoloed(self.ptr);
    }

    // Items
    pub inline fn trackItemCount(self: ApiInterface, track: *anyopaque) c_int {
        return self.vtable.trackItemCount(self.ptr, track);
    }

    pub inline fn getItemByIdx(self: ApiInterface, track: *anyopaque, idx: c_int) ?*anyopaque {
        return self.vtable.getItemByIdx(self.ptr, track, idx);
    }

    pub inline fn getItemPosition(self: ApiInterface, item: *anyopaque) f64 {
        return self.vtable.getItemPosition(self.ptr, item);
    }

    pub inline fn getItemLength(self: ApiInterface, item: *anyopaque) f64 {
        return self.vtable.getItemLength(self.ptr, item);
    }

    pub inline fn getItemColor(self: ApiInterface, item: *anyopaque) c_int {
        return self.vtable.getItemColor(self.ptr, item);
    }

    pub inline fn getItemLocked(self: ApiInterface, item: *anyopaque) bool {
        return self.vtable.getItemLocked(self.ptr, item);
    }

    pub inline fn getItemSelected(self: ApiInterface, item: *anyopaque) bool {
        return self.vtable.getItemSelected(self.ptr, item);
    }

    pub inline fn getItemActiveTakeIdx(self: ApiInterface, item: *anyopaque) c_int {
        return self.vtable.getItemActiveTakeIdx(self.ptr, item);
    }

    pub inline fn getItemNotes(self: ApiInterface, item: *anyopaque, buf: []u8) []const u8 {
        return self.vtable.getItemNotes(self.ptr, item, buf);
    }

    pub inline fn getItemGUID(self: ApiInterface, item: *anyopaque, buf: []u8) []const u8 {
        return self.vtable.getItemGUID(self.ptr, item, buf);
    }

    // Takes
    pub inline fn itemTakeCount(self: ApiInterface, item: *anyopaque) c_int {
        return self.vtable.itemTakeCount(self.ptr, item);
    }

    pub inline fn getTakeByIdx(self: ApiInterface, item: *anyopaque, idx: c_int) ?*anyopaque {
        return self.vtable.getTakeByIdx(self.ptr, item, idx);
    }

    pub inline fn getItemActiveTake(self: ApiInterface, item: *anyopaque) ?*anyopaque {
        return self.vtable.getItemActiveTake(self.ptr, item);
    }

    pub inline fn getTakeNameStr(self: ApiInterface, take: *anyopaque) []const u8 {
        return self.vtable.getTakeNameStr(self.ptr, take);
    }

    pub inline fn getTakeGUID(self: ApiInterface, take: *anyopaque, buf: []u8) []const u8 {
        return self.vtable.getTakeGUID(self.ptr, take, buf);
    }

    pub inline fn getTakeStartOffset(self: ApiInterface, take: *anyopaque) f64 {
        return self.vtable.getTakeStartOffset(self.ptr, take);
    }

    pub inline fn getTakePlayrate(self: ApiInterface, take: *anyopaque) f64 {
        return self.vtable.getTakePlayrate(self.ptr, take);
    }

    pub inline fn isTakeMIDI(self: ApiInterface, take: *anyopaque) bool {
        return self.vtable.isTakeMIDI(self.ptr, take);
    }

    pub inline fn getTakeSource(self: ApiInterface, take: *anyopaque) ?*anyopaque {
        return self.vtable.getTakeSource(self.ptr, take);
    }

    pub inline fn getMediaSourceChannels(self: ApiInterface, source: *anyopaque) c_int {
        return self.vtable.getMediaSourceChannels(self.ptr, source);
    }

    // Markers
    pub inline fn markerCount(self: ApiInterface) MarkerCount {
        return self.vtable.markerCount(self.ptr);
    }

    pub inline fn enumMarker(self: ApiInterface, idx: c_int) ?MarkerInfo {
        return self.vtable.enumMarker(self.ptr, idx);
    }

    // Metering
    pub inline fn getTrackPeakInfo(self: ApiInterface, track: *anyopaque, channel: c_int) f64 {
        return self.vtable.getTrackPeakInfo(self.ptr, track, channel);
    }

    // ExtState
    pub inline fn getExtStateValue(self: ApiInterface, section: [*:0]const u8, key: [*:0]const u8) ?[]const u8 {
        return self.vtable.getExtStateValue(self.ptr, section, key);
    }

    pub inline fn getProjExtStateValue(self: ApiInterface, extname: [*:0]const u8, key: [*:0]const u8, buf: []u8) ?[]const u8 {
        return self.vtable.getProjExtStateValue(self.ptr, extname, key, buf);
    }
};

/// Wraps the real reaper.Api to implement ApiInterface.
/// Use this in production code.
pub const RealApi = struct {
    inner: *const raw.Api,

    pub fn interface(self: *RealApi) ApiInterface {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: ApiInterface.VTable = .{
        // Transport
        .playState = struct {
            fn f(ctx: *anyopaque) c_int {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.playState();
            }
        }.f,
        .playPosition = struct {
            fn f(ctx: *anyopaque) f64 {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.playPosition();
            }
        }.f,
        .cursorPosition = struct {
            fn f(ctx: *anyopaque) f64 {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.cursorPosition();
            }
        }.f,
        .timePrecise = struct {
            fn f(ctx: *anyopaque) f64 {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.timePrecise();
            }
        }.f,
        .timePreciseMs = struct {
            fn f(ctx: *anyopaque) f64 {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.timePreciseMs();
            }
        }.f,

        // Time conversion
        .timeToBeats = struct {
            fn f(ctx: *anyopaque, time: f64) BeatsInfo {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.timeToBeats(time);
            }
        }.f,
        .beatsToTime = struct {
            fn f(ctx: *anyopaque, beats: f64) f64 {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.beatsToTime(beats);
            }
        }.f,
        .barBeatToTime = struct {
            fn f(ctx: *anyopaque, bar: c_int, beat: f64) f64 {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.barBeatToTime(bar, beat);
            }
        }.f,

        // Tempo / Time signature
        .timeSignature = struct {
            fn f(ctx: *anyopaque) TimeSignature {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.timeSignature();
            }
        }.f,
        .getTempoAtPosition = struct {
            fn f(ctx: *anyopaque, time: f64) TempoAtPosition {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.getTempoAtPosition(time);
            }
        }.f,
        .tempoMarkerCount = struct {
            fn f(ctx: *anyopaque) c_int {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.tempoMarkerCount();
            }
        }.f,
        .getTempoMarker = struct {
            fn f(ctx: *anyopaque, idx: c_int) ?TempoMarker {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.getTempoMarker(idx);
            }
        }.f,
        .getBarOffset = struct {
            fn f(ctx: *anyopaque) c_int {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.getBarOffset();
            }
        }.f,
        .getTimeSignatureNumerator = struct {
            fn f(ctx: *anyopaque) c_int {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.getTimeSignatureNumerator();
            }
        }.f,
        .getTimeSignatureDenominator = struct {
            fn f(ctx: *anyopaque) c_int {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.getTimeSignatureDenominator();
            }
        }.f,

        // Time selection
        .timeSelection = struct {
            fn f(ctx: *anyopaque) TimeSelection {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.timeSelection();
            }
        }.f,

        // Repeat
        .getRepeat = struct {
            fn f(ctx: *anyopaque) bool {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.getRepeat();
            }
        }.f,

        // Project info
        .projectLength = struct {
            fn f(ctx: *anyopaque) f64 {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.projectLength();
            }
        }.f,
        .projectStateChangeCount = struct {
            fn f(ctx: *anyopaque) c_int {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.projectStateChangeCount();
            }
        }.f,
        .isDirty = struct {
            fn f(ctx: *anyopaque) bool {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.isDirty();
            }
        }.f,

        // Command state
        .getCommandState = struct {
            fn f(ctx: *anyopaque, cmd: c_int) c_int {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.getCommandState(cmd);
            }
        }.f,
        .isMetronomeEnabled = struct {
            fn f(ctx: *anyopaque) bool {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.isMetronomeEnabled();
            }
        }.f,

        // Tracks
        .trackCount = struct {
            fn f(ctx: *anyopaque) c_int {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.trackCount();
            }
        }.f,
        .getTrackByIdx = struct {
            fn f(ctx: *anyopaque, idx: c_int) ?*anyopaque {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.getTrackByIdx(idx);
            }
        }.f,
        .getTrackByUnifiedIdx = struct {
            fn f(ctx: *anyopaque, idx: c_int) ?*anyopaque {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.getTrackByUnifiedIdx(idx);
            }
        }.f,
        .masterTrack = struct {
            fn f(ctx: *anyopaque) ?*anyopaque {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.masterTrack();
            }
        }.f,
        .getTrackNameStr = struct {
            fn f(ctx: *anyopaque, track: *anyopaque, buf: []u8) []const u8 {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.getTrackNameStr(track, buf);
            }
        }.f,
        .getTrackVolume = struct {
            fn f(ctx: *anyopaque, track: *anyopaque) f64 {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.getTrackVolume(track);
            }
        }.f,
        .getTrackPan = struct {
            fn f(ctx: *anyopaque, track: *anyopaque) f64 {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.getTrackPan(track);
            }
        }.f,
        .getTrackMute = struct {
            fn f(ctx: *anyopaque, track: *anyopaque) bool {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.getTrackMute(track);
            }
        }.f,
        .getTrackSolo = struct {
            fn f(ctx: *anyopaque, track: *anyopaque) ffi.FFIError!c_int {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.getTrackSolo(track);
            }
        }.f,
        .getTrackRecArm = struct {
            fn f(ctx: *anyopaque, track: *anyopaque) bool {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.getTrackRecArm(track);
            }
        }.f,
        .getTrackRecMon = struct {
            fn f(ctx: *anyopaque, track: *anyopaque) ffi.FFIError!c_int {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.getTrackRecMon(track);
            }
        }.f,
        .getTrackFxEnabled = struct {
            fn f(ctx: *anyopaque, track: *anyopaque) bool {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.getTrackFxEnabled(track);
            }
        }.f,
        .getTrackSelected = struct {
            fn f(ctx: *anyopaque, track: *anyopaque) bool {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.getTrackSelected(track);
            }
        }.f,
        .getTrackColor = struct {
            fn f(ctx: *anyopaque, track: *anyopaque) c_int {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.getTrackColor(track);
            }
        }.f,
        .isMasterMuted = struct {
            fn f(ctx: *anyopaque) bool {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.isMasterMuted();
            }
        }.f,
        .isMasterSoloed = struct {
            fn f(ctx: *anyopaque) bool {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.isMasterSoloed();
            }
        }.f,

        // Items
        .trackItemCount = struct {
            fn f(ctx: *anyopaque, track: *anyopaque) c_int {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.trackItemCount(track);
            }
        }.f,
        .getItemByIdx = struct {
            fn f(ctx: *anyopaque, track: *anyopaque, idx: c_int) ?*anyopaque {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.getItemByIdx(track, idx);
            }
        }.f,
        .getItemPosition = struct {
            fn f(ctx: *anyopaque, item: *anyopaque) f64 {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.getItemPosition(item);
            }
        }.f,
        .getItemLength = struct {
            fn f(ctx: *anyopaque, item: *anyopaque) f64 {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.getItemLength(item);
            }
        }.f,
        .getItemColor = struct {
            fn f(ctx: *anyopaque, item: *anyopaque) c_int {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.getItemColor(item);
            }
        }.f,
        .getItemLocked = struct {
            fn f(ctx: *anyopaque, item: *anyopaque) bool {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.getItemLocked(item);
            }
        }.f,
        .getItemSelected = struct {
            fn f(ctx: *anyopaque, item: *anyopaque) bool {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.getItemSelected(item);
            }
        }.f,
        .getItemActiveTakeIdx = struct {
            fn f(ctx: *anyopaque, item: *anyopaque) c_int {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.getItemActiveTakeIdx(item);
            }
        }.f,
        .getItemNotes = struct {
            fn f(ctx: *anyopaque, item: *anyopaque, buf: []u8) []const u8 {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.getItemNotes(item, buf);
            }
        }.f,
        .getItemGUID = struct {
            fn f(ctx: *anyopaque, item: *anyopaque, buf: []u8) []const u8 {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.getItemGUID(item, buf);
            }
        }.f,

        // Takes
        .itemTakeCount = struct {
            fn f(ctx: *anyopaque, item: *anyopaque) c_int {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.itemTakeCount(item);
            }
        }.f,
        .getTakeByIdx = struct {
            fn f(ctx: *anyopaque, item: *anyopaque, idx: c_int) ?*anyopaque {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.getTakeByIdx(item, idx);
            }
        }.f,
        .getItemActiveTake = struct {
            fn f(ctx: *anyopaque, item: *anyopaque) ?*anyopaque {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.getItemActiveTake(item);
            }
        }.f,
        .getTakeNameStr = struct {
            fn f(ctx: *anyopaque, take: *anyopaque) []const u8 {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.getTakeNameStr(take);
            }
        }.f,
        .getTakeGUID = struct {
            fn f(ctx: *anyopaque, take: *anyopaque, buf: []u8) []const u8 {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.getTakeGUID(take, buf);
            }
        }.f,
        .getTakeStartOffset = struct {
            fn f(ctx: *anyopaque, take: *anyopaque) f64 {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.getTakeStartOffset(take);
            }
        }.f,
        .getTakePlayrate = struct {
            fn f(ctx: *anyopaque, take: *anyopaque) f64 {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.getTakePlayrate(take);
            }
        }.f,
        .isTakeMIDI = struct {
            fn f(ctx: *anyopaque, take: *anyopaque) bool {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.isTakeMIDI(take);
            }
        }.f,
        .getTakeSource = struct {
            fn f(ctx: *anyopaque, take: *anyopaque) ?*anyopaque {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.getTakeSource(take);
            }
        }.f,
        .getMediaSourceChannels = struct {
            fn f(ctx: *anyopaque, source: *anyopaque) c_int {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.getMediaSourceChannels(source);
            }
        }.f,

        // Markers
        .markerCount = struct {
            fn f(ctx: *anyopaque) MarkerCount {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.markerCount();
            }
        }.f,
        .enumMarker = struct {
            fn f(ctx: *anyopaque, idx: c_int) ?MarkerInfo {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.enumMarker(idx);
            }
        }.f,

        // Metering
        .getTrackPeakInfo = struct {
            fn f(ctx: *anyopaque, track: *anyopaque, channel: c_int) f64 {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.getTrackPeakInfo(track, channel);
            }
        }.f,

        // ExtState
        .getExtStateValue = struct {
            fn f(ctx: *anyopaque, section: [*:0]const u8, key: [*:0]const u8) ?[]const u8 {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.getExtStateValue(section, key);
            }
        }.f,
        .getProjExtStateValue = struct {
            fn f(ctx: *anyopaque, extname: [*:0]const u8, key: [*:0]const u8, buf: []u8) ?[]const u8 {
                const self: *RealApi = @ptrCast(@alignCast(ctx));
                return self.inner.getProjExtStateValue(extname, key, buf);
            }
        }.f,
    };
};
