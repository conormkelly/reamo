/// Raw REAPER C API bindings.
/// This module contains the C function pointers loaded at runtime from REAPER.
/// For the abstract interface used by state modules, see api.zig.
const std = @import("std");
const types = @import("types.zig");

// Re-export types for convenience
pub const BeatsInfo = types.BeatsInfo;
pub const TempoAtPosition = types.TempoAtPosition;
pub const TempoMarker = types.TempoMarker;
pub const TimeSelection = types.TimeSelection;
pub const TimeSignature = types.TimeSignature;
pub const MarkerInfo = types.MarkerInfo;
pub const MarkerCount = types.MarkerCount;
pub const FxPresetInfo = types.FxPresetInfo;

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
    timeMap_GetTimeSigAtTime: ?*const fn (?*anyopaque, f64, *c_int, *c_int, *f64) callconv(.c) void = null,
    countTempoTimeSigMarkers: ?*const fn (?*anyopaque) callconv(.c) c_int = null,
    getTempoTimeSigMarker: ?*const fn (?*anyopaque, c_int, ?*f64, ?*c_int, ?*f64, ?*f64, ?*c_int, ?*c_int, ?*bool) callconv(.c) bool = null,

    // Project info
    getProjectLength: ?*const fn (?*anyopaque) callconv(.c) f64 = null,

    // Command state
    getToggleCommandState: ?*const fn (c_int) callconv(.c) c_int = null,
    namedCommandLookup_fn: ?*const fn ([*:0]const u8) callconv(.c) c_int = null,

    // Markers & Regions
    countProjectMarkers: ?*const fn (?*anyopaque, ?*c_int, ?*c_int) callconv(.c) c_int = null,
    enumProjectMarkers3: ?*const fn (?*anyopaque, c_int, ?*bool, ?*f64, ?*f64, ?*[*:0]const u8, ?*c_int, ?*c_int) callconv(.c) c_int = null,
    addProjectMarker2: ?*const fn (?*anyopaque, bool, f64, f64, [*:0]const u8, c_int, c_int) callconv(.c) c_int = null,
    setProjectMarker4: ?*const fn (?*anyopaque, c_int, bool, f64, f64, [*:0]const u8, c_int, c_int) callconv(.c) bool = null,
    deleteProjectMarker: ?*const fn (?*anyopaque, c_int, bool) callconv(.c) bool = null,

    // Tracks
    countTracks: ?*const fn (?*anyopaque) callconv(.c) c_int = null,
    getTrack: ?*const fn (?*anyopaque, c_int) callconv(.c) ?*anyopaque = null,
    getMasterTrack: ?*const fn (?*anyopaque) callconv(.c) ?*anyopaque = null,
    getSelectedTrack: ?*const fn (?*anyopaque, c_int) callconv(.c) ?*anyopaque = null,
    getTrackName: ?*const fn (?*anyopaque, [*]u8, c_int) callconv(.c) bool = null,
    getMediaTrackInfo_Value: ?*const fn (?*anyopaque, [*:0]const u8) callconv(.c) f64 = null,
    setMediaTrackInfo_Value: ?*const fn (?*anyopaque, [*:0]const u8, f64) callconv(.c) bool = null,
    getSetMediaTrackInfo_String: ?*const fn (?*anyopaque, [*:0]const u8, [*]u8, bool) callconv(.c) bool = null,
    insertTrackAtIndex: ?*const fn (c_int, bool) callconv(.c) void = null,
    deleteTrack: ?*const fn (?*anyopaque) callconv(.c) void = null,

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
    getSetMediaItemTakeInfo_Value: ?*const fn (?*anyopaque, [*:0]const u8, f64, bool) callconv(.c) f64 = null,
    takeIsMIDI: ?*const fn (?*anyopaque) callconv(.c) bool = null,
    getMediaItemTake_Source: ?*const fn (?*anyopaque) callconv(.c) ?*anyopaque = null,
    getMediaSourceNumChannels: ?*const fn (?*anyopaque) callconv(.c) c_int = null,
    getMediaSourceParent: ?*const fn (?*anyopaque) callconv(.c) ?*anyopaque = null,
    getMediaItemTake_Peaks: ?*const fn (?*anyopaque, f64, f64, c_int, c_int, c_int, [*]f64) callconv(.c) c_int = null,

    // AudioAccessor - for reading raw audio samples from takes
    createTakeAudioAccessor: ?*const fn (?*anyopaque) callconv(.c) ?*anyopaque = null,
    destroyAudioAccessor: ?*const fn (?*anyopaque) callconv(.c) void = null,
    getAudioAccessorSamples: ?*const fn (?*anyopaque, c_int, c_int, f64, c_int, [*]f64) callconv(.c) c_int = null,

    // ExtState (global and project-specific)
    getExtState: ?*const fn ([*:0]const u8, [*:0]const u8) callconv(.c) ?[*:0]const u8 = null,
    getProjExtState: ?*const fn (?*anyopaque, [*:0]const u8, [*:0]const u8, [*]u8, c_int) callconv(.c) c_int = null,
    setProjExtState: ?*const fn (?*anyopaque, [*:0]const u8, [*:0]const u8, [*:0]const u8) callconv(.c) c_int = null,

    // Undo
    undo_BeginBlock2: ?*const fn (?*anyopaque) callconv(.c) void = null,
    undo_EndBlock2: ?*const fn (?*anyopaque, [*:0]const u8, c_int) callconv(.c) void = null,
    undo_OnStateChange: ?*const fn ([*:0]const u8) callconv(.c) void = null,
    undo_CanUndo2: ?*const fn (?*anyopaque) callconv(.c) ?[*:0]const u8 = null,
    undo_CanRedo2: ?*const fn (?*anyopaque) callconv(.c) ?[*:0]const u8 = null,
    undo_DoUndo2: ?*const fn (?*anyopaque) callconv(.c) c_int = null,
    undo_DoRedo2: ?*const fn (?*anyopaque) callconv(.c) c_int = null,

    // Project state
    getProjectStateChangeCount: ?*const fn (?*anyopaque) callconv(.c) c_int = null,

    // Master track state (reliable for master mute/solo)
    getMasterMuteSoloFlags: ?*const fn () callconv(.c) c_int = null,

    // Control Surface API (for undo-coalesced continuous control changes)
    csurf_OnVolumeChange: ?*const fn (?*anyopaque, f64, bool) callconv(.c) f64 = null,
    csurf_OnVolumeChangeEx: ?*const fn (?*anyopaque, f64, bool, bool) callconv(.c) f64 = null,
    csurf_OnPanChange: ?*const fn (?*anyopaque, f64, bool) callconv(.c) f64 = null,
    csurf_OnPanChangeEx: ?*const fn (?*anyopaque, f64, bool, bool) callconv(.c) f64 = null,
    csurf_OnMuteChange: ?*const fn (?*anyopaque, c_int) callconv(.c) bool = null,
    csurf_OnMuteChangeEx: ?*const fn (?*anyopaque, c_int, bool) callconv(.c) bool = null,
    csurf_OnSoloChange: ?*const fn (?*anyopaque, c_int) callconv(.c) bool = null,
    csurf_OnSoloChangeEx: ?*const fn (?*anyopaque, c_int, bool) callconv(.c) bool = null,
    csurf_OnRecArmChange: ?*const fn (?*anyopaque, c_int) callconv(.c) bool = null,
    csurf_OnRecArmChangeEx: ?*const fn (?*anyopaque, c_int, bool) callconv(.c) bool = null,
    csurf_OnInputMonitorChange: ?*const fn (?*anyopaque, c_int) callconv(.c) c_int = null,
    csurf_OnInputMonitorChangeEx: ?*const fn (?*anyopaque, c_int, bool) callconv(.c) c_int = null,
    csurf_OnFXChange: ?*const fn (?*anyopaque, c_int) callconv(.c) bool = null,
    csurf_FlushUndo: ?*const fn (bool) callconv(.c) void = null,

    // Metering
    track_GetPeakInfo: ?*const fn (?*anyopaque, c_int) callconv(.c) f64 = null,
    track_GetPeakHoldDB: ?*const fn (?*anyopaque, c_int, bool) callconv(.c) f64 = null,

    // Project config variables (for metronome volume, etc.)
    projectconfig_var_getoffs: ?*const fn ([*:0]const u8, ?*c_int) callconv(.c) c_int = null,
    projectconfig_var_addr: ?*const fn (?*anyopaque, c_int) callconv(.c) ?*anyopaque = null,

    // Global config variables (for smoothseek, etc.)
    getConfigVar: ?*const fn ([*:0]const u8, *c_int) callconv(.c) ?*anyopaque = null,

    // UI refresh
    updateTimeline_fn: ?*const fn () callconv(.c) void = null,

    // Resource path
    getResourcePath: ?*const fn () callconv(.c) [*:0]const u8 = null,

    // High-precision timing (for transport sync)
    time_precise: ?*const fn () callconv(.c) f64 = null,

    // MIDI injection (Virtual MIDI Keyboard)
    stuffMIDIMessage: ?*const fn (c_int, c_int, c_int, c_int) callconv(.c) void = null,

    // Project notes
    getSetProjectNotes: ?*const fn (?*anyopaque, bool, [*]u8, c_int) callconv(.c) void = null,
    markProjectDirty: ?*const fn (?*anyopaque) callconv(.c) void = null,
    isProjectDirty: ?*const fn (?*anyopaque) callconv(.c) c_int = null,

    // Frame rate / timecode
    timeMapCurFrameRate: ?*const fn (?*anyopaque, *bool) callconv(.c) f64 = null,

    // Track FX
    trackFX_GetCount: ?*const fn (?*anyopaque) callconv(.c) c_int = null,
    trackFX_GetFXName: ?*const fn (?*anyopaque, c_int, [*]u8, c_int) callconv(.c) bool = null,
    trackFX_GetPresetIndex: ?*const fn (?*anyopaque, c_int, *c_int) callconv(.c) c_int = null,
    trackFX_GetPreset: ?*const fn (?*anyopaque, c_int, [*]u8, c_int) callconv(.c) bool = null,
    trackFX_NavigatePresets: ?*const fn (?*anyopaque, c_int, c_int) callconv(.c) bool = null,
    trackFX_SetPresetByIndex: ?*const fn (?*anyopaque, c_int, c_int) callconv(.c) bool = null,
    trackFX_GetEnabled: ?*const fn (?*anyopaque, c_int) callconv(.c) bool = null,

    // Track Sends
    getTrackNumSends: ?*const fn (?*anyopaque, c_int) callconv(.c) c_int = null,
    getTrackSendInfo_Value: ?*const fn (?*anyopaque, c_int, c_int, [*:0]const u8) callconv(.c) f64 = null,
    setTrackSendInfo_Value: ?*const fn (?*anyopaque, c_int, c_int, [*:0]const u8, f64) callconv(.c) bool = null,
    getTrackSendName: ?*const fn (?*anyopaque, c_int, [*]u8, c_int) callconv(.c) bool = null,
    csurf_OnSendVolumeChange: ?*const fn (?*anyopaque, c_int, f64, bool) callconv(.c) f64 = null,
    toggleTrackSendUIMute: ?*const fn (?*anyopaque, c_int) callconv(.c) bool = null,

    // Project enumeration and identity
    enumProjects_fn: ?*const fn (c_int, [*]u8, c_int) callconv(.c) ?*anyopaque = null,
    getProjectName_fn: ?*const fn (?*anyopaque, [*]u8, c_int) callconv(.c) void = null,
    getMainHwnd_fn: ?*const fn () callconv(.c) ?*anyopaque = null,

    // Pointer validation
    validatePtr2_fn: ?*const fn (?*anyopaque, ?*anyopaque, [*:0]const u8) callconv(.c) bool = null,

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
            .timeMap_GetTimeSigAtTime = getFunc(info, "TimeMap_GetTimeSigAtTime", fn (?*anyopaque, f64, *c_int, *c_int, *f64) callconv(.c) void),
            .countTempoTimeSigMarkers = getFunc(info, "CountTempoTimeSigMarkers", fn (?*anyopaque) callconv(.c) c_int),
            .getTempoTimeSigMarker = getFunc(info, "GetTempoTimeSigMarker", fn (?*anyopaque, c_int, ?*f64, ?*c_int, ?*f64, ?*f64, ?*c_int, ?*c_int, ?*bool) callconv(.c) bool),
            // Project info
            .getProjectLength = getFunc(info, "GetProjectLength", fn (?*anyopaque) callconv(.c) f64),
            // Command state
            .getToggleCommandState = getFunc(info, "GetToggleCommandState", fn (c_int) callconv(.c) c_int),
            .namedCommandLookup_fn = getFunc(info, "NamedCommandLookup", fn ([*:0]const u8) callconv(.c) c_int),
            .countProjectMarkers = getFunc(info, "CountProjectMarkers", fn (?*anyopaque, ?*c_int, ?*c_int) callconv(.c) c_int),
            .enumProjectMarkers3 = getFunc(info, "EnumProjectMarkers3", fn (?*anyopaque, c_int, ?*bool, ?*f64, ?*f64, ?*[*:0]const u8, ?*c_int, ?*c_int) callconv(.c) c_int),
            .addProjectMarker2 = getFunc(info, "AddProjectMarker2", fn (?*anyopaque, bool, f64, f64, [*:0]const u8, c_int, c_int) callconv(.c) c_int),
            .setProjectMarker4 = getFunc(info, "SetProjectMarker4", fn (?*anyopaque, c_int, bool, f64, f64, [*:0]const u8, c_int, c_int) callconv(.c) bool),
            .deleteProjectMarker = getFunc(info, "DeleteProjectMarker", fn (?*anyopaque, c_int, bool) callconv(.c) bool),
            // Tracks
            .countTracks = getFunc(info, "CountTracks", fn (?*anyopaque) callconv(.c) c_int),
            .getTrack = getFunc(info, "GetTrack", fn (?*anyopaque, c_int) callconv(.c) ?*anyopaque),
            .getMasterTrack = getFunc(info, "GetMasterTrack", fn (?*anyopaque) callconv(.c) ?*anyopaque),
            .getSelectedTrack = getFunc(info, "GetSelectedTrack", fn (?*anyopaque, c_int) callconv(.c) ?*anyopaque),
            .getTrackName = getFunc(info, "GetTrackName", fn (?*anyopaque, [*]u8, c_int) callconv(.c) bool),
            .getMediaTrackInfo_Value = getFunc(info, "GetMediaTrackInfo_Value", fn (?*anyopaque, [*:0]const u8) callconv(.c) f64),
            .setMediaTrackInfo_Value = getFunc(info, "SetMediaTrackInfo_Value", fn (?*anyopaque, [*:0]const u8, f64) callconv(.c) bool),
            .getSetMediaTrackInfo_String = getFunc(info, "GetSetMediaTrackInfo_String", fn (?*anyopaque, [*:0]const u8, [*]u8, bool) callconv(.c) bool),
            .insertTrackAtIndex = getFunc(info, "InsertTrackAtIndex", fn (c_int, bool) callconv(.c) void),
            .deleteTrack = getFunc(info, "DeleteTrack", fn (?*anyopaque) callconv(.c) void),
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
            .getSetMediaItemTakeInfo_Value = getFunc(info, "GetSetMediaItemTakeInfo_Value", fn (?*anyopaque, [*:0]const u8, f64, bool) callconv(.c) f64),
            .takeIsMIDI = getFunc(info, "TakeIsMIDI", fn (?*anyopaque) callconv(.c) bool),
            .getMediaItemTake_Source = getFunc(info, "GetMediaItemTake_Source", fn (?*anyopaque) callconv(.c) ?*anyopaque),
            .getMediaSourceNumChannels = getFunc(info, "GetMediaSourceNumChannels", fn (?*anyopaque) callconv(.c) c_int),
            .getMediaSourceParent = getFunc(info, "GetMediaSourceParent", fn (?*anyopaque) callconv(.c) ?*anyopaque),
            .getMediaItemTake_Peaks = getFunc(info, "GetMediaItemTake_Peaks", fn (?*anyopaque, f64, f64, c_int, c_int, c_int, [*]f64) callconv(.c) c_int),
            // AudioAccessor
            .createTakeAudioAccessor = getFunc(info, "CreateTakeAudioAccessor", fn (?*anyopaque) callconv(.c) ?*anyopaque),
            .destroyAudioAccessor = getFunc(info, "DestroyAudioAccessor", fn (?*anyopaque) callconv(.c) void),
            .getAudioAccessorSamples = getFunc(info, "GetAudioAccessorSamples", fn (?*anyopaque, c_int, c_int, f64, c_int, [*]f64) callconv(.c) c_int),
            // ExtState
            .getExtState = getFunc(info, "GetExtState", fn ([*:0]const u8, [*:0]const u8) callconv(.c) ?[*:0]const u8),
            .getProjExtState = getFunc(info, "GetProjExtState", fn (?*anyopaque, [*:0]const u8, [*:0]const u8, [*]u8, c_int) callconv(.c) c_int),
            .setProjExtState = getFunc(info, "SetProjExtState", fn (?*anyopaque, [*:0]const u8, [*:0]const u8, [*:0]const u8) callconv(.c) c_int),
            // Undo
            .undo_BeginBlock2 = getFunc(info, "Undo_BeginBlock2", fn (?*anyopaque) callconv(.c) void),
            .undo_EndBlock2 = getFunc(info, "Undo_EndBlock2", fn (?*anyopaque, [*:0]const u8, c_int) callconv(.c) void),
            .undo_OnStateChange = getFunc(info, "Undo_OnStateChange", fn ([*:0]const u8) callconv(.c) void),
            .undo_CanUndo2 = getFunc(info, "Undo_CanUndo2", fn (?*anyopaque) callconv(.c) ?[*:0]const u8),
            .undo_CanRedo2 = getFunc(info, "Undo_CanRedo2", fn (?*anyopaque) callconv(.c) ?[*:0]const u8),
            .undo_DoUndo2 = getFunc(info, "Undo_DoUndo2", fn (?*anyopaque) callconv(.c) c_int),
            .undo_DoRedo2 = getFunc(info, "Undo_DoRedo2", fn (?*anyopaque) callconv(.c) c_int),
            // Project state
            .getProjectStateChangeCount = getFunc(info, "GetProjectStateChangeCount", fn (?*anyopaque) callconv(.c) c_int),
            // Master track state
            .getMasterMuteSoloFlags = getFunc(info, "GetMasterMuteSoloFlags", fn () callconv(.c) c_int),
            // Control Surface API
            .csurf_OnVolumeChange = getFunc(info, "CSurf_OnVolumeChange", fn (?*anyopaque, f64, bool) callconv(.c) f64),
            .csurf_OnVolumeChangeEx = getFunc(info, "CSurf_OnVolumeChangeEx", fn (?*anyopaque, f64, bool, bool) callconv(.c) f64),
            .csurf_OnPanChange = getFunc(info, "CSurf_OnPanChange", fn (?*anyopaque, f64, bool) callconv(.c) f64),
            .csurf_OnPanChangeEx = getFunc(info, "CSurf_OnPanChangeEx", fn (?*anyopaque, f64, bool, bool) callconv(.c) f64),
            .csurf_OnMuteChange = getFunc(info, "CSurf_OnMuteChange", fn (?*anyopaque, c_int) callconv(.c) bool),
            .csurf_OnMuteChangeEx = getFunc(info, "CSurf_OnMuteChangeEx", fn (?*anyopaque, c_int, bool) callconv(.c) bool),
            .csurf_OnSoloChange = getFunc(info, "CSurf_OnSoloChange", fn (?*anyopaque, c_int) callconv(.c) bool),
            .csurf_OnSoloChangeEx = getFunc(info, "CSurf_OnSoloChangeEx", fn (?*anyopaque, c_int, bool) callconv(.c) bool),
            .csurf_OnRecArmChange = getFunc(info, "CSurf_OnRecArmChange", fn (?*anyopaque, c_int) callconv(.c) bool),
            .csurf_OnRecArmChangeEx = getFunc(info, "CSurf_OnRecArmChangeEx", fn (?*anyopaque, c_int, bool) callconv(.c) bool),
            .csurf_OnInputMonitorChange = getFunc(info, "CSurf_OnInputMonitorChange", fn (?*anyopaque, c_int) callconv(.c) c_int),
            .csurf_OnInputMonitorChangeEx = getFunc(info, "CSurf_OnInputMonitorChangeEx", fn (?*anyopaque, c_int, bool) callconv(.c) c_int),
            .csurf_OnFXChange = getFunc(info, "CSurf_OnFXChange", fn (?*anyopaque, c_int) callconv(.c) bool),
            .csurf_FlushUndo = getFunc(info, "CSurf_FlushUndo", fn (bool) callconv(.c) void),
            // Metering
            .track_GetPeakInfo = getFunc(info, "Track_GetPeakInfo", fn (?*anyopaque, c_int) callconv(.c) f64),
            .track_GetPeakHoldDB = getFunc(info, "Track_GetPeakHoldDB", fn (?*anyopaque, c_int, bool) callconv(.c) f64),
            // Project config variables
            .projectconfig_var_getoffs = getFunc(info, "projectconfig_var_getoffs", fn ([*:0]const u8, ?*c_int) callconv(.c) c_int),
            .projectconfig_var_addr = getFunc(info, "projectconfig_var_addr", fn (?*anyopaque, c_int) callconv(.c) ?*anyopaque),
            // Global config variables
            .getConfigVar = getFunc(info, "get_config_var", fn ([*:0]const u8, *c_int) callconv(.c) ?*anyopaque),
            // UI refresh
            .updateTimeline_fn = getFunc(info, "UpdateTimeline", fn () callconv(.c) void),
            // Resource path
            .getResourcePath = getFunc(info, "GetResourcePath", fn () callconv(.c) [*:0]const u8),
            // High-precision timing
            .time_precise = getFunc(info, "time_precise", fn () callconv(.c) f64),
            // MIDI injection
            .stuffMIDIMessage = getFunc(info, "StuffMIDIMessage", fn (c_int, c_int, c_int, c_int) callconv(.c) void),
            // Project notes
            .getSetProjectNotes = getFunc(info, "GetSetProjectNotes", fn (?*anyopaque, bool, [*]u8, c_int) callconv(.c) void),
            .markProjectDirty = getFunc(info, "MarkProjectDirty", fn (?*anyopaque) callconv(.c) void),
            .isProjectDirty = getFunc(info, "IsProjectDirty", fn (?*anyopaque) callconv(.c) c_int),
            // Frame rate / timecode
            .timeMapCurFrameRate = getFunc(info, "TimeMap_curFrameRate", fn (?*anyopaque, *bool) callconv(.c) f64),
            // Track FX
            .trackFX_GetCount = getFunc(info, "TrackFX_GetCount", fn (?*anyopaque) callconv(.c) c_int),
            .trackFX_GetFXName = getFunc(info, "TrackFX_GetFXName", fn (?*anyopaque, c_int, [*]u8, c_int) callconv(.c) bool),
            .trackFX_GetPresetIndex = getFunc(info, "TrackFX_GetPresetIndex", fn (?*anyopaque, c_int, *c_int) callconv(.c) c_int),
            .trackFX_GetPreset = getFunc(info, "TrackFX_GetPreset", fn (?*anyopaque, c_int, [*]u8, c_int) callconv(.c) bool),
            .trackFX_NavigatePresets = getFunc(info, "TrackFX_NavigatePresets", fn (?*anyopaque, c_int, c_int) callconv(.c) bool),
            .trackFX_SetPresetByIndex = getFunc(info, "TrackFX_SetPresetByIndex", fn (?*anyopaque, c_int, c_int) callconv(.c) bool),
            .trackFX_GetEnabled = getFunc(info, "TrackFX_GetEnabled", fn (?*anyopaque, c_int) callconv(.c) bool),
            // Track Sends
            .getTrackNumSends = getFunc(info, "GetTrackNumSends", fn (?*anyopaque, c_int) callconv(.c) c_int),
            .getTrackSendInfo_Value = getFunc(info, "GetTrackSendInfo_Value", fn (?*anyopaque, c_int, c_int, [*:0]const u8) callconv(.c) f64),
            .setTrackSendInfo_Value = getFunc(info, "SetTrackSendInfo_Value", fn (?*anyopaque, c_int, c_int, [*:0]const u8, f64) callconv(.c) bool),
            .getTrackSendName = getFunc(info, "GetTrackSendName", fn (?*anyopaque, c_int, [*]u8, c_int) callconv(.c) bool),
            .csurf_OnSendVolumeChange = getFunc(info, "CSurf_OnSendVolumeChange", fn (?*anyopaque, c_int, f64, bool) callconv(.c) f64),
            .toggleTrackSendUIMute = getFunc(info, "ToggleTrackSendUIMute", fn (?*anyopaque, c_int) callconv(.c) bool),
            // Project enumeration and identity
            .enumProjects_fn = getFunc(info, "EnumProjects", fn (c_int, [*]u8, c_int) callconv(.c) ?*anyopaque),
            .getProjectName_fn = getFunc(info, "GetProjectName", fn (?*anyopaque, [*]u8, c_int) callconv(.c) void),
            .getMainHwnd_fn = getFunc(info, "GetMainHwnd", fn () callconv(.c) ?*anyopaque),
            // Pointer validation
            .validatePtr2_fn = getFunc(info, "ValidatePtr2", fn (?*anyopaque, ?*anyopaque, [*:0]const u8) callconv(.c) bool),
        };
    }

    /// Get path to REAPER's resource directory
    pub fn resourcePath(self: *const Api) ?[]const u8 {
        const func = self.getResourcePath orelse return null;
        const path = func();
        return std.mem.sliceTo(path, 0);
    }

    fn getFunc(info: *PluginInfo, name: [*:0]const u8, comptime T: type) ?*const T {
        const ptr = info.GetFunc(name) orelse return null;
        return @ptrCast(@alignCast(ptr));
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

    /// High-precision time in seconds (for transport sync timestamps)
    pub fn timePrecise(self: *const Api) f64 {
        return if (self.time_precise) |f| f() else 0;
    }

    /// High-precision time in milliseconds (for transport sync)
    pub fn timePreciseMs(self: *const Api) f64 {
        return self.timePrecise() * 1000.0;
    }

    pub fn timeSignature(self: *const Api) TimeSignature {
        var bpm: f64 = 120;
        var num: f64 = 4;
        if (self.getProjectTimeSignature2) |f| {
            f(null, &bpm, &num);
        }
        return .{ .bpm = bpm, .num = num };
    }

    pub fn timeSelection(self: *const Api) TimeSelection {
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

    // Loop points (separate from time selection - used with repeat mode)
    pub fn getLoopPoints(self: *const Api) TimeSelection {
        var start: f64 = 0;
        var end: f64 = 0;
        if (self.getSetLoopTimeRange2) |f| {
            f(null, false, true, &start, &end, false); // isLoop=true
        }
        return .{ .start = start, .end = end };
    }

    pub fn setLoopPoints(self: *const Api, start: f64, end: f64) void {
        if (self.getSetLoopTimeRange2) |f| {
            var s = start;
            var e = end;
            f(null, true, true, &s, &e, false); // isLoop=true
        }
    }

    pub fn clearLoopPoints(self: *const Api) void {
        self.setLoopPoints(0, 0);
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

    // Smooth seek config (REAPER global preference)
    // When enabled, seeks are queued and executed at measure boundaries with pre-buffering
    pub fn getSmoothSeekEnabled(self: *const Api) bool {
        const f = self.getConfigVar orelse return false;
        var size: c_int = 0;
        const ptr = f("smoothseek", &size);
        if (ptr == null or size != @sizeOf(c_int)) return false;
        const value_ptr: *c_int = @ptrCast(@alignCast(ptr));
        return value_ptr.* != 0;
    }

    pub fn setSmoothSeekEnabled(self: *const Api, enabled: bool) void {
        const f = self.getConfigVar orelse return;
        var size: c_int = 0;
        const ptr = f("smoothseek", &size);
        if (ptr == null or size != @sizeOf(c_int)) return;
        const value_ptr: *c_int = @ptrCast(@alignCast(ptr));
        // Preserve bit 1 (mode), only modify bit 0 (enabled)
        if (enabled) {
            value_ptr.* |= 1; // Set bit 0
        } else {
            value_ptr.* &= ~@as(c_int, 1); // Clear bit 0
        }
    }

    /// Get smooth seek measures (how many measures before seek executes)
    pub fn getSmoothSeekMeasures(self: *const Api) c_int {
        const f = self.getConfigVar orelse return 0;
        var size: c_int = 0;
        const ptr = f("smoothseekmeas", &size);
        if (ptr == null or size != @sizeOf(c_int)) return 0;
        const value_ptr: *c_int = @ptrCast(@alignCast(ptr));
        return value_ptr.*;
    }

    pub fn setSmoothSeekMeasures(self: *const Api, measures: c_int) void {
        const f = self.getConfigVar orelse return;
        var size: c_int = 0;
        const ptr = f("smoothseekmeas", &size);
        if (ptr == null or size != @sizeOf(c_int)) return;
        const value_ptr: *c_int = @ptrCast(@alignCast(ptr));
        value_ptr.* = measures;
    }

    /// Get smooth seek mode from bit 1 of smoothseek config
    /// Returns: 0 = "measures" mode (play to end of N measures)
    ///          1 = "marker" mode (play to next marker/region boundary)
    pub fn getSeekMode(self: *const Api) c_int {
        const f = self.getConfigVar orelse return 0;
        var size: c_int = 0;
        const ptr = f("smoothseek", &size);
        if (ptr == null or size != @sizeOf(c_int)) return 0;
        const value_ptr: *c_int = @ptrCast(@alignCast(ptr));
        // Bit 1 controls mode: 0=measures, 1=marker/region
        return (value_ptr.* >> 1) & 1;
    }

    /// Set smooth seek mode via bit 1 of smoothseek config
    /// mode: 0 = "measures", 1 = "marker"
    pub fn setSeekMode(self: *const Api, mode: c_int) void {
        const f = self.getConfigVar orelse return;
        var size: c_int = 0;
        const ptr = f("smoothseek", &size);
        if (ptr == null or size != @sizeOf(c_int)) return;
        const value_ptr: *c_int = @ptrCast(@alignCast(ptr));
        // Preserve bit 0 (enabled), only modify bit 1 (mode)
        if (mode != 0) {
            value_ptr.* |= 2; // Set bit 1 (marker mode)
        } else {
            value_ptr.* &= ~@as(c_int, 2); // Clear bit 1 (measures mode)
        }
    }

    // Tempo: set BPM for current project
    pub fn setTempo(self: *const Api, bpm: f64) void {
        const f = self.setCurrentBPM orelse return;
        // Clamp to REAPER's valid range (2-960 BPM)
        const clamped = @max(2.0, @min(960.0, bpm));
        f(null, clamped, true); // true = add undo point
    }

    /// Get tempo and time signature at a specific position (handles tempo markers)
    /// This is position-aware unlike timeSignature() which returns project defaults
    pub fn getTempoAtPosition(self: *const Api, time: f64) TempoAtPosition {
        var num: c_int = 4;
        var denom: c_int = 4;
        var bpm: f64 = 120;
        if (self.timeMap_GetTimeSigAtTime) |f| {
            f(null, time, &num, &denom, &bpm);
        }
        return .{ .bpm = bpm, .timesig_num = num, .timesig_denom = denom };
    }

    /// Count tempo/time signature markers in the project (0 = fixed tempo)
    pub fn tempoMarkerCount(self: *const Api) c_int {
        const f = self.countTempoTimeSigMarkers orelse return 0;
        return f(null);
    }

    /// Get tempo/time signature marker by index
    /// Returns null if index out of range or function unavailable
    pub fn getTempoMarker(self: *const Api, idx: c_int) ?TempoMarker {
        const f = self.getTempoTimeSigMarker orelse return null;
        var position: f64 = 0;
        var bpm: f64 = 120;
        var timesig_num: c_int = 4;
        var timesig_denom: c_int = 4;
        var linear: bool = false;
        // Unused outputs from GetTempoTimeSigMarker
        var measure_pos: c_int = 0;
        var beat_pos: f64 = 0;

        const ok = f(null, idx, &position, &measure_pos, &beat_pos, &bpm, &timesig_num, &timesig_denom, &linear);
        if (!ok) return null;

        // Get full beat position using timeToBeats
        const beats_info = self.timeToBeats(position);

        return .{
            .position = position,
            .position_beats = beats_info.beats,
            .bpm = bpm,
            .timesig_num = timesig_num,
            .timesig_denom = timesig_denom,
            .linear_tempo = linear,
        };
    }

    // Project length in seconds (based on last item/region end)
    pub fn projectLength(self: *const Api) f64 {
        const f = self.getProjectLength orelse return 0.0;
        return f(null);
    }

    // Command toggle state: returns 1 if on, 0 if off, -1 if not toggle command
    pub fn getCommandState(self: *const Api, cmd: c_int) c_int {
        const f = self.getToggleCommandState orelse return -1;
        return f(cmd);
    }

    // Named command lookup: converts command name (e.g., "_SWS_ABOUT") to command ID
    // Returns 0 if command not found
    pub fn namedCommandLookup(self: *const Api, name: []const u8) c_int {
        const f = self.namedCommandLookup_fn orelse return 0;
        // Need null-terminated string
        var buf: [256]u8 = undefined;
        const len = @min(name.len, buf.len - 1);
        @memcpy(buf[0..len], name[0..len]);
        buf[len] = 0;
        return f(@ptrCast(&buf));
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
        const buf_size: c_int = @intCast(buf.len);
        const len = f(null, extname, key, buf.ptr, buf_size);
        if (len <= 0) return null;
        // Note: REAPER's return value is unreliable - find the actual null terminator
        const actual_len = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
        return buf[0..actual_len];
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

    // Undo: get description of next undo action (or null if nothing to undo)
    pub fn canUndo(self: *const Api) ?[]const u8 {
        const f = self.undo_CanUndo2 orelse return null;
        const ptr = f(null) orelse return null;
        return std.mem.sliceTo(ptr, 0);
    }

    // Undo: get description of next redo action (or null if nothing to redo)
    pub fn canRedo(self: *const Api) ?[]const u8 {
        const f = self.undo_CanRedo2 orelse return null;
        const ptr = f(null) orelse return null;
        return std.mem.sliceTo(ptr, 0);
    }

    // Undo: perform undo, returns true on success
    pub fn doUndo(self: *const Api) bool {
        const f = self.undo_DoUndo2 orelse return false;
        return f(null) != 0;
    }

    // Undo: perform redo, returns true on success
    pub fn doRedo(self: *const Api) bool {
        const f = self.undo_DoRedo2 orelse return false;
        return f(null) != 0;
    }

    // Project: get state change counter (increments on any project change)
    pub fn projectStateChangeCount(self: *const Api) c_int {
        const f = self.getProjectStateChangeCount orelse return 0;
        return f(null);
    }

    // Control Surface: set track volume (undo-coalesced, use with csurfFlushUndo)
    // Returns the new volume value. Use allowGang=true to respect track grouping.
    pub fn csurfSetVolume(self: *const Api, track: *anyopaque, vol: f64, allowGang: bool) f64 {
        if (self.csurf_OnVolumeChangeEx) |f| {
            return f(track, vol, false, allowGang);
        } else if (self.csurf_OnVolumeChange) |f| {
            return f(track, vol, false);
        }
        // Fallback to direct set (creates immediate undo point)
        _ = self.setTrackVolume(track, vol);
        return vol;
    }

    // Control Surface: set track pan (undo-coalesced, use with csurfFlushUndo)
    // Returns the new pan value. Use allowGang=true to respect track grouping.
    pub fn csurfSetPan(self: *const Api, track: *anyopaque, pan: f64, allowGang: bool) f64 {
        if (self.csurf_OnPanChangeEx) |f| {
            return f(track, pan, false, allowGang);
        } else if (self.csurf_OnPanChange) |f| {
            return f(track, pan, false);
        }
        // Fallback to direct set (creates immediate undo point)
        _ = self.setTrackPan(track, pan);
        return pan;
    }

    // Control Surface: flush pending undo (creates single undo point for all CSurf changes)
    pub fn csurfFlushUndo(self: *const Api, force: bool) void {
        const f = self.csurf_FlushUndo orelse return;
        f(force);
    }

    // Control Surface: set track mute
    // Returns true on success. Use allowGang=true to respect track grouping.
    // This properly handles master track mute unlike SetMediaTrackInfo_Value.
    pub fn csurfSetMute(self: *const Api, track: *anyopaque, mute: bool, allowGang: bool) bool {
        const mute_val: c_int = if (mute) 1 else 0;
        if (self.csurf_OnMuteChangeEx) |f| {
            return f(track, mute_val, allowGang);
        } else if (self.csurf_OnMuteChange) |f| {
            return f(track, mute_val);
        }
        // Fallback to direct set
        return self.setTrackMute(track, mute);
    }

    // Control Surface: set track solo
    // Returns true on success. Use allowGang=true to respect track grouping.
    // This properly handles master track solo unlike SetMediaTrackInfo_Value.
    pub fn csurfSetSolo(self: *const Api, track: *anyopaque, solo: c_int, allowGang: bool) bool {
        if (self.csurf_OnSoloChangeEx) |f| {
            return f(track, solo, allowGang);
        } else if (self.csurf_OnSoloChange) |f| {
            return f(track, solo);
        }
        // Fallback to direct set
        return self.setTrackSolo(track, solo);
    }

    // Control Surface: set track record arm
    // Returns true on success. Use allowGang=true to respect track grouping.
    pub fn csurfSetRecArm(self: *const Api, track: *anyopaque, arm: bool, allowGang: bool) bool {
        const arm_val: c_int = if (arm) 1 else 0;
        if (self.csurf_OnRecArmChangeEx) |f| {
            return f(track, arm_val, allowGang);
        } else if (self.csurf_OnRecArmChange) |f| {
            return f(track, arm_val);
        }
        // Fallback to direct set
        return self.setTrackRecArm(track, arm);
    }

    // Control Surface: set track input monitor
    // Returns the new monitor value. Use allowGang=true to respect track grouping.
    // monitor: 0=off, 1=on, 2=auto (not when playing)
    pub fn csurfSetRecMon(self: *const Api, track: *anyopaque, mon: c_int, allowGang: bool) c_int {
        if (self.csurf_OnInputMonitorChangeEx) |f| {
            return f(track, mon, allowGang);
        } else if (self.csurf_OnInputMonitorChange) |f| {
            return f(track, mon);
        }
        // Fallback to direct set
        if (self.setTrackRecMon(track, mon)) {
            return mon;
        }
        return -1; // Error indicator
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

    pub fn timeToBeats(self: *const Api, time: f64) BeatsInfo {
        const f = self.timeMap2_timeToBeats orelse return .{
            .beats = 0,
            .measures = 1,
            .beats_in_measure = 0, // 0-indexed (beat 1 = index 0)
            .time_sig_denom = 4,
        };
        var measures: c_int = 0;
        var fullbeats: f64 = 0;
        var cdenom: c_int = 4;
        // The RETURN VALUE is beats within measure (0-indexed with fraction)
        // cml (4th param) is just the time sig numerator, so we pass null
        // fullbeats is cumulative from project start
        const beats_in_measure = f(null, time, &measures, null, &fullbeats, &cdenom);
        return .{
            .beats = fullbeats, // Total beats from project start
            .measures = measures + 1, // Convert to 1-based
            .beats_in_measure = beats_in_measure, // Return value IS beats within measure (0-indexed)
            .time_sig_denom = cdenom,
        };
    }

    pub fn runCommand(self: *const Api, cmd: c_int) void {
        if (self.mainOnCommand) |f| f(cmd, 0);
    }

    pub fn setCursorPos(self: *const Api, pos: f64) void {
        if (self.setEditCurPos) |f| f(pos, true, true);
    }

    // Project Notes: get project notes into buffer
    // Returns slice of notes content, or null if API not available
    // Uses iterative resizing strategy since API doesn't report truncation
    pub fn getProjectNotes(self: *const Api, buf: []u8) ?[]const u8 {
        const f = self.getSetProjectNotes orelse return null;
        if (buf.len == 0) return null;

        // Clear buffer first
        @memset(buf, 0);

        // Call API - set=false means get
        f(null, false, buf.ptr, @intCast(buf.len));

        // Find actual length (null terminator)
        const len = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
        return buf[0..len];
    }

    // Project Notes: set project notes
    // Notes outside undo system - always marks project dirty after
    pub fn setProjectNotes(self: *const Api, notes: []const u8) void {
        const f = self.getSetProjectNotes orelse return;

        // Need null-terminated buffer for API
        var buf: [65536]u8 = undefined; // 64KB max
        const copy_len = @min(notes.len, buf.len - 1);
        @memcpy(buf[0..copy_len], notes[0..copy_len]);
        buf[copy_len] = 0;

        // Call API - set=true means set
        f(null, true, &buf, @intCast(copy_len + 1));

        // Always mark dirty since notes are outside undo system
        self.markDirty();
    }

    // Project: mark project as needing save
    pub fn markDirty(self: *const Api) void {
        const f = self.markProjectDirty orelse return;
        f(null);
    }

    // Project: check if project needs saving
    // Returns true if project is dirty (has unsaved changes)
    // Note: Returns false if "undo/prompt to save" is disabled in REAPER preferences
    pub fn isDirty(self: *const Api) bool {
        const f = self.isProjectDirty orelse return false;
        return f(null) != 0;
    }

    /// Frame rate: returns project frame rate and drop-frame flag
    /// Returns: struct with frame_rate (e.g., 29.97, 24, 25) and drop_frame boolean
    pub fn getFrameRate(self: *const Api) types.FrameRateInfo {
        var drop_frame: bool = false;
        const f = self.timeMapCurFrameRate orelse return .{ .frame_rate = 0, .drop_frame = false };
        const rate = f(null, &drop_frame);
        return .{ .frame_rate = rate, .drop_frame = drop_frame };
    }

    pub fn registerTimer(self: *const Api, callback: *const fn () callconv(.c) void) void {
        _ = self.register("timer", @ptrCast(@constCast(callback)));
    }

    pub fn unregisterTimer(self: *const Api, callback: *const fn () callconv(.c) void) void {
        _ = self.register("-timer", @ptrCast(@constCast(callback)));
    }

    // Marker/Region methods

    pub fn markerCount(self: *const Api) MarkerCount {
        var markers: c_int = 0;
        var regions: c_int = 0;
        const total = if (self.countProjectMarkers) |f| f(null, &markers, &regions) else 0;
        return .{ .total = total, .markers = markers, .regions = regions };
    }

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

    /// Add marker with a specific ID (for delete/recreate workflows)
    pub fn addMarkerWithId(self: *const Api, pos: f64, name: [*:0]const u8, color: c_int, wanted_id: c_int) c_int {
        const f = self.addProjectMarker2 orelse return -1;
        return f(null, false, pos, 0, name, wanted_id, color);
    }

    pub fn addRegion(self: *const Api, start: f64, end: f64, name: [*:0]const u8, color: c_int) c_int {
        const f = self.addProjectMarker2 orelse return -1;
        return f(null, true, start, end, name, -1, color);
    }

    /// Add region with a specific ID (for delete/recreate workflows like color reset)
    pub fn addRegionWithId(self: *const Api, start: f64, end: f64, name: [*:0]const u8, color: c_int, wanted_id: c_int) c_int {
        const f = self.addProjectMarker2 orelse return -1;
        return f(null, true, start, end, name, wanted_id, color);
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

    /// Get the master track
    pub fn masterTrack(self: *const Api) ?*anyopaque {
        const f = self.getMasterTrack orelse return null;
        return f(null);
    }

    /// Get track by unified index: 0 = master, 1+ = user tracks
    /// This matches REAPER's HTTP API convention where track 0 is master
    pub fn getTrackByUnifiedIdx(self: *const Api, idx: c_int) ?*anyopaque {
        if (idx == 0) {
            return self.masterTrack();
        } else {
            return self.getTrackByIdx(idx - 1);
        }
    }

    pub fn getTrackNameStr(self: *const Api, track: *anyopaque, buf: []u8) []const u8 {
        const f = self.getTrackName orelse return "";
        if (f(track, buf.ptr, @intCast(buf.len))) {
            return std.mem.sliceTo(buf, 0);
        }
        return "";
    }

    /// Get selected track by selection index (0 = first selected track)
    pub fn getSelectedTrackByIdx(self: *const Api, sel_idx: c_int) ?*anyopaque {
        const f = self.getSelectedTrack orelse return null;
        return f(null, sel_idx);
    }

    /// Set track name using GetSetMediaTrackInfo_String with P_NAME
    pub fn setTrackName(self: *const Api, track: *anyopaque, name: []const u8) bool {
        const f = self.getSetMediaTrackInfo_String orelse return false;
        var buf: [256]u8 = undefined;
        const len = @min(name.len, buf.len - 1);
        @memcpy(buf[0..len], name[0..len]);
        buf[len] = 0;
        return f(track, "P_NAME", &buf, true);
    }

    /// Insert a new track at the specified index
    /// idx: position to insert at (0 = first track, trackCount() = append at end)
    /// wantDefaults: true to apply default track settings from preferences
    pub fn insertTrack(self: *const Api, idx: c_int, want_defaults: bool) void {
        const f = self.insertTrackAtIndex orelse return;
        f(idx, want_defaults);
    }

    /// Delete a track
    pub fn deleteTrackPtr(self: *const Api, track: *anyopaque) void {
        const f = self.deleteTrack orelse return;
        f(track);
    }

    /// Get track folder depth (I_FOLDERDEPTH)
    /// Returns: 1 = folder parent, 0 = normal, -N = closes N folder levels
    pub fn getTrackFolderDepth(self: *const Api, track: *anyopaque) c_int {
        const f = self.getMediaTrackInfo_Value orelse return 0;
        const val = f(track, "I_FOLDERDEPTH");
        return @intFromFloat(val);
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

    // Master mute/solo flags (reliable for master track)
    // Returns: &1=mute, &2=solo
    pub fn getMasterMuteFlags(self: *const Api) c_int {
        const f = self.getMasterMuteSoloFlags orelse return 0;
        return f();
    }

    /// Check if master track is muted (reliable - uses GetMasterMuteSoloFlags)
    pub fn isMasterMuted(self: *const Api) bool {
        return (self.getMasterMuteFlags() & 1) != 0;
    }

    /// Check if master track is soloed (reliable - uses GetMasterMuteSoloFlags)
    pub fn isMasterSoloed(self: *const Api) bool {
        return (self.getMasterMuteFlags() & 2) != 0;
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
    // Returns raw f64 from REAPER - validation happens in RealBackend
    pub fn getTrackSolo(self: *const Api, track: *anyopaque) f64 {
        const f = self.getMediaTrackInfo_Value orelse return 0;
        return f(track, "I_SOLO");
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
    // Returns raw f64 from REAPER - validation happens in RealBackend
    pub fn getTrackRecMon(self: *const Api, track: *anyopaque) f64 {
        const f = self.getMediaTrackInfo_Value orelse return 0;
        return f(track, "I_RECMON");
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
        const f = self.csurf_OnFXChange orelse return false;
        return f(track, if (enabled) 1 else 0);
    }

    // Track selection: true/false
    pub fn getTrackSelected(self: *const Api, track: *anyopaque) bool {
        const f = self.getMediaTrackInfo_Value orelse return false;
        return f(track, "I_SELECTED") != 0;
    }

    pub fn setTrackSelected(self: *const Api, track: *anyopaque, selected: bool) bool {
        const f = self.setMediaTrackInfo_Value orelse return false;
        return f(track, "I_SELECTED", if (selected) 1.0 else 0.0);
    }

    // Track color: returns raw f64 from REAPER - validation and flag check in RealBackend
    pub fn getTrackColor(self: *const Api, track: *anyopaque) f64 {
        const f = self.getMediaTrackInfo_Value orelse return 0;
        return f(track, "I_CUSTOMCOLOR");
    }

    // Track FX methods

    /// Get number of FX on a track
    pub fn trackFxCount(self: *const Api, track: *anyopaque) c_int {
        const f = self.trackFX_GetCount orelse return 0;
        return f(track);
    }

    /// Get FX name into buffer, returns slice of populated bytes
    pub fn trackFxGetName(self: *const Api, track: *anyopaque, fx_idx: c_int, buf: []u8) []const u8 {
        const f = self.trackFX_GetFXName orelse return "";
        if (buf.len == 0) return "";
        const success = f(track, fx_idx, buf.ptr, @intCast(buf.len));
        if (!success) return "";
        // Find null terminator
        const len = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
        return buf[0..len];
    }

    /// Get preset index and count. Returns -1 on error.
    pub fn trackFxGetPresetIndex(self: *const Api, track: *anyopaque, fx_idx: c_int, preset_count: *c_int) c_int {
        const f = self.trackFX_GetPresetIndex orelse {
            preset_count.* = 0;
            return -1;
        };
        return f(track, fx_idx, preset_count);
    }

    /// Get preset name into buffer. Returns true if params match preset (NOT modified).
    pub fn trackFxGetPreset(self: *const Api, track: *anyopaque, fx_idx: c_int, buf: []u8) FxPresetInfo {
        const f = self.trackFX_GetPreset orelse return .{ .name = "", .matches_preset = false };
        if (buf.len == 0) return .{ .name = "", .matches_preset = false };
        const matches = f(track, fx_idx, buf.ptr, @intCast(buf.len));
        // Find null terminator
        const len = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
        return .{ .name = buf[0..len], .matches_preset = matches };
    }

    /// Navigate to next/prev preset. presetmove: +1=next, -1=prev
    pub fn trackFxNavigatePresets(self: *const Api, track: *anyopaque, fx_idx: c_int, presetmove: c_int) bool {
        const f = self.trackFX_NavigatePresets orelse return false;
        return f(track, fx_idx, presetmove);
    }

    /// Set preset by index. -1=default user, -2=factory
    pub fn trackFxSetPresetByIndex(self: *const Api, track: *anyopaque, fx_idx: c_int, preset_idx: c_int) bool {
        const f = self.trackFX_SetPresetByIndex orelse return false;
        return f(track, fx_idx, preset_idx);
    }

    /// Get FX enabled state (true = enabled, false = bypassed)
    pub fn trackFxGetEnabled(self: *const Api, track: *anyopaque, fx_idx: c_int) bool {
        const f = self.trackFX_GetEnabled orelse return true;
        return f(track, fx_idx);
    }

    // Track Send methods

    /// Get number of sends for a track. category: 0 = track sends
    pub fn trackSendCount(self: *const Api, track: *anyopaque) c_int {
        const f = self.getTrackNumSends orelse return 0;
        return f(track, 0); // category 0 = sends to other tracks
    }

    /// Get number of receives for a track. category: -1 = receives
    pub fn trackReceiveCount(self: *const Api, track: *anyopaque) c_int {
        const f = self.getTrackNumSends orelse return 0;
        return f(track, -1); // category -1 = receives from other tracks
    }

    /// Get send volume (linear, 1.0 = 0dB)
    pub fn trackSendGetVolume(self: *const Api, track: *anyopaque, send_idx: c_int) f64 {
        const f = self.getTrackSendInfo_Value orelse return 1.0;
        return f(track, 0, send_idx, "D_VOL");
    }

    /// Get send mute state (true = muted)
    pub fn trackSendGetMute(self: *const Api, track: *anyopaque, send_idx: c_int) bool {
        const f = self.getTrackSendInfo_Value orelse return false;
        return f(track, 0, send_idx, "B_MUTE") != 0;
    }

    /// Get send mode (0=post-fader, 1=pre-FX, 3=post-FX)
    pub fn trackSendGetMode(self: *const Api, track: *anyopaque, send_idx: c_int) c_int {
        const f = self.getTrackSendInfo_Value orelse return 0;
        const val = f(track, 0, send_idx, "I_SENDMODE");
        return @intFromFloat(val);
    }

    /// Get send destination name into buffer
    pub fn trackSendGetDestName(self: *const Api, track: *anyopaque, send_idx: c_int, buf: []u8) []const u8 {
        const f = self.getTrackSendName orelse return "";
        if (buf.len == 0) return "";
        const success = f(track, send_idx, buf.ptr, @intCast(buf.len));
        if (!success) return "";
        const len = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
        return buf[0..len];
    }

    /// Set send volume using CSurf (with undo coalescing)
    pub fn trackSendSetVolume(self: *const Api, track: *anyopaque, send_idx: c_int, volume: f64) f64 {
        const f = self.csurf_OnSendVolumeChange orelse return volume;
        return f(track, send_idx, volume, false); // absolute, not relative
    }

    /// Toggle send mute state
    pub fn trackSendToggleMute(self: *const Api, track: *anyopaque, send_idx: c_int) bool {
        const f = self.toggleTrackSendUIMute orelse return false;
        return f(track, send_idx);
    }

    /// Set send mute state directly (when toggle isn't appropriate)
    pub fn trackSendSetMute(self: *const Api, track: *anyopaque, send_idx: c_int, muted: bool) bool {
        const f = self.setTrackSendInfo_Value orelse return false;
        return f(track, 0, send_idx, "B_MUTE", if (muted) 1.0 else 0.0);
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

    // Returns raw f64 from REAPER - validation in RealBackend
    pub fn getItemColor(self: *const Api, item: *anyopaque) f64 {
        const f = self.getMediaItemInfo_Value orelse return 0;
        return f(item, "I_CUSTOMCOLOR");
    }

    // Returns raw f64 from REAPER - validation in RealBackend
    pub fn getItemLocked(self: *const Api, item: *anyopaque) f64 {
        const f = self.getMediaItemInfo_Value orelse return 0;
        return f(item, "C_LOCK");
    }

    // Returns raw f64 from REAPER - validation in RealBackend
    pub fn getItemSelected(self: *const Api, item: *anyopaque) f64 {
        const f = self.getMediaItemInfo_Value orelse return 0;
        return f(item, "B_UISEL");
    }

    pub fn setItemSelected(self: *const Api, item: *anyopaque, selected: bool) bool {
        const f = self.setMediaItemInfo_Value orelse return false;
        return f(item, "B_UISEL", if (selected) 1.0 else 0.0);
    }

    // Returns raw f64 from REAPER - validation in RealBackend
    pub fn getItemActiveTakeIdx(self: *const Api, item: *anyopaque) f64 {
        const f = self.getMediaItemInfo_Value orelse return 0;
        return f(item, "I_CURTAKE");
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

    /// Get item GUID as string (38 char format: {XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX})
    pub fn getItemGUID(self: *const Api, item: *anyopaque, buf: []u8) []const u8 {
        const f = self.getSetMediaItemInfo_String orelse return "";
        if (buf.len < 40) return ""; // Need at least 38 chars + null
        if (f(item, "GUID", buf.ptr, false)) {
            return std.mem.sliceTo(buf, 0);
        }
        return "";
    }

    /// Get take GUID as string (38 char format: {XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX})
    pub fn getTakeGUID(self: *const Api, take: *anyopaque, buf: []u8) []const u8 {
        const f = self.getSetMediaItemTakeInfo_String orelse return "";
        if (buf.len < 40) return ""; // Need at least 38 chars + null
        if (f(take, "GUID", buf.ptr, false)) {
            return std.mem.sliceTo(buf, 0);
        }
        return "";
    }

    /// Get take start offset in seconds (D_STARTOFFS)
    pub fn getTakeStartOffset(self: *const Api, take: *anyopaque) f64 {
        const f = self.getSetMediaItemTakeInfo_Value orelse return 0;
        return f(take, "D_STARTOFFS", 0, false); // set_val=false for get
    }

    /// Get take playback rate (D_PLAYRATE, 1.0 = normal)
    pub fn getTakePlayrate(self: *const Api, take: *anyopaque) f64 {
        const f = self.getSetMediaItemTakeInfo_Value orelse return 1.0;
        return f(take, "D_PLAYRATE", 0, false); // set_val=false for get
    }

    /// Check if take is MIDI (as opposed to audio)
    pub fn isTakeMIDI(self: *const Api, take: *anyopaque) bool {
        const f = self.takeIsMIDI orelse return false;
        return f(take);
    }

    /// Get the PCM source for a take (needed for channel count and peaks)
    pub fn getTakeSource(self: *const Api, take: *anyopaque) ?*anyopaque {
        const f = self.getMediaItemTake_Source orelse return null;
        return f(take);
    }

    /// Get number of channels in a media source (1=mono, 2=stereo, etc.)
    pub fn getMediaSourceChannels(self: *const Api, source: *anyopaque) c_int {
        const f = self.getMediaSourceNumChannels orelse return 0;
        return f(source);
    }

    /// Get the root (PCM) source by traversing parent chain
    /// Returns the deepest parent, or the original source if no parent
    pub fn getRootSource(self: *const Api, source: *anyopaque) *anyopaque {
        const f = self.getMediaSourceParent orelse return source;
        var current = source;
        while (f(current)) |parent| {
            current = parent;
        }
        return current;
    }

    /// Get waveform peaks for a take
    /// peakrate: peaks per second (e.g., item_duration/desired_peaks)
    /// starttime/numchannels: usually 0 and source channel count
    /// numsamplesperchannel: number of peak samples to get
    /// buf: buffer for peak data (needs numchannels * numsamplesperchannel * 2 floats for min+max)
    /// Returns: sample_count in low 20 bits, mode in bits 20-23 (0=not yet ready, use previous)
    pub fn getMediaItemTakePeaks(self: *const Api, take: *anyopaque, peakrate: f64, starttime: f64, numchannels: c_int, numsamplesperchannel: c_int, buf: []f64) c_int {
        const f = self.getMediaItemTake_Peaks orelse return 0;
        const want_extra: c_int = 0; // We don't need extra info (source location)
        return f(take, peakrate, starttime, numchannels, numsamplesperchannel, want_extra, buf.ptr);
    }

    // AudioAccessor methods - for reading raw audio samples

    /// Create an audio accessor for a take. Must be destroyed with destroyTakeAccessor.
    /// Returns null if the API is unavailable or take is invalid.
    pub fn makeTakeAccessor(self: *const Api, take: *anyopaque) ?*anyopaque {
        const f = self.createTakeAudioAccessor orelse return null;
        return f(take);
    }

    /// Destroy an audio accessor created with makeTakeAccessor.
    pub fn destroyTakeAccessor(self: *const Api, accessor: *anyopaque) void {
        const f = self.destroyAudioAccessor orelse return;
        f(accessor);
    }

    /// Get audio samples from an accessor.
    /// samplerate: sample rate to read at (e.g., 44100)
    /// numchannels: number of channels to read
    /// starttime_sec: start time in seconds (source-relative)
    /// numsamplesperchannel: number of samples to read per channel
    /// buf: buffer for interleaved samples (needs numchannels * numsamplesperchannel floats)
    /// Returns: 0=no audio, 1=audio, -1=error
    pub fn readAccessorSamples(self: *const Api, accessor: *anyopaque, samplerate: c_int, numchannels: c_int, starttime_sec: f64, numsamplesperchannel: c_int, buf: []f64) c_int {
        const f = self.getAudioAccessorSamples orelse return -1;
        return f(accessor, samplerate, numchannels, starttime_sec, numsamplesperchannel, buf.ptr);
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

    // Time signature methods (using project config variables like REAPER's Project Settings dialog)

    /// Get project bar offset (e.g., -4 means display starts at bar -4, time 0 = bar 1)
    /// Returns 0 if bar offset is not set (bar 1 starts at time 0)
    pub fn getBarOffset(self: *const Api) c_int {
        const getoffs = self.projectconfig_var_getoffs orelse return 0;
        const getaddr = self.projectconfig_var_addr orelse return 0;

        var sz: c_int = 0;
        const offs = getoffs("projmeasoffs", &sz);
        if (offs < 0) return 0;
        if (sz != 4) return 0; // sizeof(c_int)

        const ptr = getaddr(null, offs) orelse return 0;
        const val_ptr: *c_int = @ptrCast(@alignCast(ptr));
        return val_ptr.*;
    }

    /// Get project time signature numerator (beats per measure, e.g., 6 for 6/8)
    pub fn getTimeSignatureNumerator(self: *const Api) c_int {
        const getoffs = self.projectconfig_var_getoffs orelse return 4;
        const getaddr = self.projectconfig_var_addr orelse return 4;

        var sz: c_int = 0;
        const offs = getoffs("projmeaslen", &sz);
        if (offs < 0) return 4;
        if (sz != 4) return 4; // sizeof(c_int)

        const ptr = getaddr(null, offs) orelse return 4;
        const val_ptr: *c_int = @ptrCast(@alignCast(ptr));
        return val_ptr.*;
    }

    /// Get project time signature denominator (beat note value, e.g., 8 for 6/8)
    pub fn getTimeSignatureDenominator(self: *const Api) c_int {
        const getoffs = self.projectconfig_var_getoffs orelse return 4;
        const getaddr = self.projectconfig_var_addr orelse return 4;

        var sz: c_int = 0;
        const offs = getoffs("projtsdenom", &sz);
        if (offs < 0) return 4;
        if (sz != 4) return 4; // sizeof(c_int)

        const ptr = getaddr(null, offs) orelse return 4;
        const val_ptr: *c_int = @ptrCast(@alignCast(ptr));
        return val_ptr.*;
    }

    /// Set project time signature (fixed project-level, no tempo markers)
    pub fn setTimeSignature(self: *const Api, numerator: c_int, denominator: c_int) bool {
        const getoffs = self.projectconfig_var_getoffs orelse return false;
        const getaddr = self.projectconfig_var_addr orelse return false;

        // Capture current state BEFORE changing time signature
        const current_bpm = self.timeSignature().bpm;
        const old_denom = self.getTimeSignatureDenominator();

        // Set numerator (projmeaslen = beats per measure)
        var sz_num: c_int = 0;
        const offs_num = getoffs("projmeaslen", &sz_num);
        if (offs_num < 0 or sz_num != 4) return false;

        const ptr_num = getaddr(null, offs_num) orelse return false;
        const num_ptr: *c_int = @ptrCast(@alignCast(ptr_num));
        num_ptr.* = numerator;

        // Set denominator (projtsdenom = beat note value)
        var sz_denom: c_int = 0;
        const offs_denom = getoffs("projtsdenom", &sz_denom);
        if (offs_denom < 0 or sz_denom != 4) return false;

        const ptr_denom = getaddr(null, offs_denom) orelse return false;
        const denom_ptr: *c_int = @ptrCast(@alignCast(ptr_denom));
        denom_ptr.* = denominator;

        // Normalize BPM to quarter notes before setting
        // REAPER's BPM is in denominator-note units (e.g., eighths for 6/8)
        // Convert to quarter-note BPM which is the standard reference
        const old_denom_f: f64 = @floatFromInt(old_denom);
        const quarter_note_bpm = current_bpm * (4.0 / old_denom_f);

        self.setTempo(quarter_note_bpm);

        // Refresh timeline to show changes
        self.updateTimeline();

        return true;
    }

    /// Redraw the arrange view and ruler
    pub fn updateTimeline(self: *const Api) void {
        if (self.updateTimeline_fn) |f| f();
    }

    // MIDI injection methods
    // Dual-sends to both VKB (mode 0) and Control (mode 1) paths:
    // - Mode 0 (VKB): Routes to record-armed/monitored tracks for actual parameter control
    // - Mode 1 (Control): Routes to MIDI Learn dialogs and control surfaces
    // This allows the same button press to work for both learning AND controlling.

    /// Send MIDI Control Change message (dual-send to VKB + Control paths)
    /// channel: 0-15, cc: 0-127, value: 0-127
    pub fn sendMidiCC(self: *const Api, channel: u8, cc: u8, value: u8) void {
        const f = self.stuffMIDIMessage orelse return;
        const status: c_int = 0xB0 | @as(c_int, channel & 0x0F);
        const cc_val: c_int = @as(c_int, cc & 0x7F);
        const val: c_int = @as(c_int, value & 0x7F);
        f(0, status, cc_val, val); // VKB - for actual parameter control
        f(1, status, cc_val, val); // Control - for MIDI Learn
    }

    /// Send MIDI Program Change message (dual-send to VKB + Control paths)
    /// channel: 0-15, program: 0-127
    pub fn sendMidiPC(self: *const Api, channel: u8, program: u8) void {
        const f = self.stuffMIDIMessage orelse return;
        const status: c_int = 0xC0 | @as(c_int, channel & 0x0F);
        const prog: c_int = @as(c_int, program & 0x7F);
        f(0, status, prog, 0); // VKB - for actual parameter control
        f(1, status, prog, 0); // Control - for MIDI Learn
    }

    // Project enumeration and identity

    /// Project identity info returned by enumProjects
    pub const ProjectInfo = struct {
        project: ?*anyopaque, // ReaProject* pointer (identifies tab, not file!)
        path: []const u8, // Full path to .rpp file (empty string if unsaved)
    };

    /// Get current project info (pointer + full path).
    /// The path buffer is caller-provided and filled with the project's full path.
    /// Returns null if the API is unavailable.
    /// Note: project pointer identifies the TAB, not the file! Same pointer persists
    /// when opening a different file in the same tab. Always compare BOTH pointer AND path.
    pub fn enumCurrentProject(self: *const Api, path_buf: []u8) ?ProjectInfo {
        const f = self.enumProjects_fn orelse return null;
        const project = f(-1, path_buf.ptr, @intCast(path_buf.len));
        const path_len = std.mem.indexOfScalar(u8, path_buf, 0) orelse path_buf.len;
        return .{
            .project = project,
            .path = path_buf[0..path_len],
        };
    }

    /// Get project name (filename only, e.g. "MySong.rpp").
    /// For unsaved projects, returns empty string.
    pub fn getProjectName(self: *const Api, project: ?*anyopaque, name_buf: []u8) []const u8 {
        const f = self.getProjectName_fn orelse return "";
        f(project, name_buf.ptr, @intCast(name_buf.len));
        const name_len = std.mem.indexOfScalar(u8, name_buf, 0) orelse name_buf.len;
        return name_buf[0..name_len];
    }

    /// Get REAPER's main window handle.
    /// Returns null if main window not yet initialized (e.g., during startup modal).
    pub fn getMainHwnd(self: *const Api) ?*anyopaque {
        const f = self.getMainHwnd_fn orelse return null;
        return f();
    }

    /// Validate a pointer using REAPER's ValidatePtr2.
    /// Returns true if the pointer is valid for the given type.
    /// Type names: "MediaTrack*", "MediaItem*", "MediaItem_Take*"
    pub fn validatePtr2(self: *const Api, ptr: ?*anyopaque, typename: [*:0]const u8) bool {
        const f = self.validatePtr2_fn orelse return false;
        return f(null, ptr, typename); // null project = current project
    }

    /// Validate a track pointer.
    pub fn validateTrackPtr(self: *const Api, track: ?*anyopaque) bool {
        return self.validatePtr2(track, "MediaTrack*");
    }

    /// Validate an item pointer.
    pub fn validateItemPtr(self: *const Api, item: ?*anyopaque) bool {
        return self.validatePtr2(item, "MediaItem*");
    }

    /// Validate a take pointer.
    pub fn validateTakePtr(self: *const Api, take: ?*anyopaque) bool {
        return self.validatePtr2(take, "MediaItem_Take*");
    }
};

// REAPER action command IDs
pub const Command = struct {
    // Transport
    pub const PLAY: c_int = 1007;
    pub const PAUSE: c_int = 1008;
    pub const PLAY_PAUSE: c_int = 40073; // Play/pause toggle
    pub const RECORD: c_int = 1013;
    pub const STOP: c_int = 1016; // Stop
    pub const STOP_AND_SAVE: c_int = 40667; // Stop (save all recorded media)
    pub const STOP_AND_DELETE: c_int = 40668; // Stop (DELETE all recorded media)
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

    // Tracks
    pub const UNSELECT_ALL_TRACKS: c_int = 40297; // Track: Unselect all tracks
    pub const DUPLICATE_TRACKS: c_int = 40062; // Track: Duplicate tracks
    pub const DELETE_SELECTED_TRACKS: c_int = 40005; // Track: Remove tracks
};
