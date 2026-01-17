/// Mock REAPER API for testing state modules without REAPER running.
///
/// Features:
/// - Field-based state for fast access and easy setup
/// - Index-as-pointer pattern for track/item handles (can't dangle)
/// - Error injection flags for testing error paths
/// - Call tracking for verification
///
/// Usage:
///   var mock = MockBackend{
///       .play_state = 1,
///       .play_position = 5.5,
///       .track_count = 2,
///   };
///   mock.tracks[0].setName("Track 1");
///   mock.tracks[0].volume = 0.8;
///
///   const state = transport.poll(&mock);
const std = @import("std");
const types = @import("../types.zig");
const backend = @import("../backend.zig");
const state = @import("state.zig");
const transport = @import("transport.zig");
const tracks = @import("tracks.zig");
const markers = @import("markers.zig");
const project = @import("project.zig");
const preferences = @import("preferences.zig");
const inputs = @import("inputs.zig");

// Re-export state types for convenience
pub const MockTrack = state.MockTrack;
pub const MockItem = state.MockItem;
pub const MockTake = state.MockTake;
pub const MockFx = state.MockFx;
pub const MockSend = state.MockSend;
pub const MockHwOutput = state.MockHwOutput;
pub const MockMarkerInfo = state.MockMarkerInfo;
pub const Method = state.Method;
pub const CallEntry = state.CallEntry;
pub const MAX_TRACKS = state.MAX_TRACKS;
pub const MAX_ITEMS_PER_TRACK = state.MAX_ITEMS_PER_TRACK;
pub const MAX_TAKES_PER_ITEM = state.MAX_TAKES_PER_ITEM;
pub const MAX_FX_PER_TRACK = state.MAX_FX_PER_TRACK;
pub const MAX_SENDS_PER_TRACK = state.MAX_SENDS_PER_TRACK;
pub const MAX_HW_OUTPUTS_PER_TRACK = state.MAX_HW_OUTPUTS_PER_TRACK;
pub const MAX_MARKERS = state.MAX_MARKERS;
pub const MAX_CALLS = state.MAX_CALLS;

/// Mock REAPER API backend for testing.
pub const MockBackend = struct {
    // =========================================================================
    // Transport state
    // =========================================================================
    play_state: c_int = 0,
    play_position: f64 = 0.0,
    cursor_position: f64 = 0.0,
    server_time_s: f64 = 0.0,
    last_command: c_int = 0,

    // =========================================================================
    // Tempo/timing state
    // =========================================================================
    bpm: f64 = 120.0,
    timesig_num: c_int = 4,
    timesig_denom: c_int = 4,
    bar_offset: c_int = 0,
    tempo_marker_count: c_int = 0,
    tempo_markers: [8]types.TempoMarker = [_]types.TempoMarker{.{
        .position = 0,
        .position_beats = 0,
        .bpm = 120,
        .timesig_num = 4,
        .timesig_denom = 4,
        .linear_tempo = false,
    }} ** 8,

    // =========================================================================
    // Time selection state
    // =========================================================================
    time_sel_start: f64 = 0.0,
    time_sel_end: f64 = 0.0,

    // =========================================================================
    // Loop points state (for native looping)
    // =========================================================================
    loop_start: f64 = 0.0,
    loop_end: f64 = 0.0,

    // =========================================================================
    // Repeat state
    // =========================================================================
    repeat_enabled: bool = false,

    // =========================================================================
    // Smooth seek state
    // =========================================================================
    smooth_seek_enabled: bool = false,
    smooth_seek_measures: c_int = 1,
    seek_mode: c_int = 0,

    // =========================================================================
    // Project state
    // =========================================================================
    project_length: f64 = 0.0,
    project_state_change_count: c_int = 0,
    project_dirty: bool = false,
    project_notes: [1024]u8 = [_]u8{0} ** 1024,
    project_notes_len: usize = 0,
    frame_rate: f64 = 30.0,
    drop_frame: bool = false,

    // Project identity (for project switch detection)
    project_pointer: ?*anyopaque = null, // Simulated ReaProject* pointer
    project_path: [512]u8 = [_]u8{0} ** 512, // Full path to .rpp file
    project_path_len: usize = 0,
    project_name: [128]u8 = [_]u8{0} ** 128, // Filename only
    project_name_len: usize = 0,

    // =========================================================================
    // Command state
    // =========================================================================
    metronome_enabled: bool = false,
    metronome_volume: f64 = 1.0,
    command_states: [16]state.CommandStateEntry = [_]state.CommandStateEntry{.{}} ** 16,
    command_state_count: usize = 0,

    // =========================================================================
    // Undo/Redo (fixed buffers for testing)
    // =========================================================================
    undo_desc: [128]u8 = [_]u8{0} ** 128,
    undo_desc_len: usize = 0,
    redo_desc: [128]u8 = [_]u8{0} ** 128,
    redo_desc_len: usize = 0,
    undo_block_active: bool = false,

    // =========================================================================
    // Tracks (fixed array for testing)
    // =========================================================================
    track_count: c_int = 0,
    tracks: [MAX_TRACKS]MockTrack = [_]MockTrack{.{}} ** MAX_TRACKS,
    master_muted: bool = false,
    master_soloed: bool = false,

    // =========================================================================
    // Input enumeration (configurable for testing)
    // =========================================================================
    audio_input_count: c_int = 8,
    midi_input_count: c_int = 4,

    // =========================================================================
    // Markers (fixed array for testing)
    // =========================================================================
    marker_count: c_int = 0,
    region_count: c_int = 0,
    markers: [MAX_MARKERS]MockMarkerInfo = [_]MockMarkerInfo{.{}} ** MAX_MARKERS,

    // =========================================================================
    // ExtState (fixed array for testing)
    // =========================================================================
    ext_states: [16]state.ExtStateEntry = [_]state.ExtStateEntry{.{}} ** 16,
    ext_state_count: usize = 0,

    // =========================================================================
    // MIDI state (for tracking sent messages)
    // =========================================================================
    last_midi_channel: u8 = 0,
    last_midi_cc: c_int = 0,
    last_midi_value: c_int = 0,
    last_midi_program: c_int = 0,
    last_midi_note: u8 = 0,
    last_midi_velocity: u8 = 0,
    last_pitch_bend: u16 = 8192, // center position

    // =========================================================================
    // UI state
    // =========================================================================
    timeline_updated: bool = false,

    // =========================================================================
    // Error injection flags
    // =========================================================================
    inject_nan_position: bool = false,
    inject_nan_beats: bool = false,
    inject_solo_error: bool = false,
    inject_recmon_error: bool = false,
    inject_track_color_error: bool = false,
    inject_item_color_error: bool = false,
    inject_item_locked_error: bool = false,
    inject_item_selected_error: bool = false,
    inject_item_active_take_error: bool = false,

    // =========================================================================
    // Call tracking (fixed-size, no allocation)
    // =========================================================================
    call_log: [MAX_CALLS]CallEntry = undefined,
    call_count: usize = 0,

    // =========================================================================
    // Call tracking helpers
    // =========================================================================

    /// Record a method call for verification.
    pub fn recordCall(self: *MockBackend, method: Method) void {
        if (self.call_count < MAX_CALLS) {
            self.call_log[self.call_count] = .{
                .method = method,
                .timestamp_ns = std.time.nanoTimestamp(),
            };
            self.call_count += 1;
        }
    }

    /// Get count of calls to a specific method.
    pub fn getCallCount(self: *const MockBackend, method: Method) usize {
        var count: usize = 0;
        for (self.call_log[0..self.call_count]) |entry| {
            if (entry.method == method) count += 1;
        }
        return count;
    }

    /// Reset call tracking.
    pub fn resetCalls(self: *MockBackend) void {
        self.call_count = 0;
    }

    // =========================================================================
    // Test setup helpers
    // =========================================================================

    /// Set a command state for testing.
    pub fn setCommandState(self: *MockBackend, cmd: c_int, cmd_state: c_int) void {
        // Check if command already exists
        for (self.command_states[0..self.command_state_count]) |*entry| {
            if (entry.cmd == cmd) {
                entry.state = cmd_state;
                return;
            }
        }
        // Add new entry
        if (self.command_state_count < self.command_states.len) {
            self.command_states[self.command_state_count] = .{ .cmd = cmd, .state = cmd_state };
            self.command_state_count += 1;
        }
    }

    /// Set undo description for testing.
    pub fn setUndoDesc(self: *MockBackend, desc: []const u8) void {
        const len = @min(desc.len, self.undo_desc.len);
        @memcpy(self.undo_desc[0..len], desc[0..len]);
        self.undo_desc_len = len;
    }

    /// Set redo description for testing.
    pub fn setRedoDesc(self: *MockBackend, desc: []const u8) void {
        const len = @min(desc.len, self.redo_desc.len);
        @memcpy(self.redo_desc[0..len], desc[0..len]);
        self.redo_desc_len = len;
    }

    /// Set project notes for testing.
    pub fn setProjectNotes(self: *MockBackend, notes: []const u8) void {
        const len = @min(notes.len, self.project_notes.len);
        @memcpy(self.project_notes[0..len], notes[0..len]);
        self.project_notes_len = len;
    }

    /// Set project identity for testing (simulates project switch).
    /// pointer: simulated ReaProject* (use any unique value to represent a project tab)
    /// path: full path to .rpp file (empty string for unsaved projects)
    /// name: filename only (e.g. "MySong.rpp")
    pub fn setProjectIdentity(self: *MockBackend, pointer: ?*anyopaque, path: []const u8, name: []const u8) void {
        self.project_pointer = pointer;
        const path_len = @min(path.len, self.project_path.len);
        @memcpy(self.project_path[0..path_len], path[0..path_len]);
        self.project_path_len = path_len;
        const name_len = @min(name.len, self.project_name.len);
        @memcpy(self.project_name[0..name_len], name[0..name_len]);
        self.project_name_len = name_len;
    }

    // =========================================================================
    // Transport methods (delegated)
    // =========================================================================
    pub const playState = transport.TransportMethods.playState;
    pub const playPosition = transport.TransportMethods.playPosition;
    pub const cursorPosition = transport.TransportMethods.cursorPosition;
    pub const timePrecise = transport.TransportMethods.timePrecise;
    pub const timePreciseMs = transport.TransportMethods.timePreciseMs;
    pub const runCommand = transport.TransportMethods.runCommand;
    pub const setCursorPos = transport.TransportMethods.setCursorPos;
    pub const timeToBeats = transport.TransportMethods.timeToBeats;
    pub const beatsToTime = transport.TransportMethods.beatsToTime;
    pub const barBeatToTime = transport.TransportMethods.barBeatToTime;
    pub const timeSignature = transport.TransportMethods.timeSignature;
    pub const getTempoAtPosition = transport.TransportMethods.getTempoAtPosition;
    pub const tempoMarkerCount = transport.TransportMethods.tempoMarkerCount;
    pub const getTempoMarker = transport.TransportMethods.getTempoMarker;
    pub const getBarOffset = transport.TransportMethods.getBarOffset;
    pub const getTimeSignatureNumerator = transport.TransportMethods.getTimeSignatureNumerator;
    pub const getTimeSignatureDenominator = transport.TransportMethods.getTimeSignatureDenominator;
    pub const setTempo = transport.TransportMethods.setTempo;
    pub const setTimeSignature = transport.TransportMethods.setTimeSignature;
    pub const timeSelection = transport.TransportMethods.timeSelection;
    pub const setTimeSelection = transport.TransportMethods.setTimeSelection;
    pub const clearTimeSelection = transport.TransportMethods.clearTimeSelection;
    pub const getLoopPoints = transport.TransportMethods.getLoopPoints;
    pub const setLoopPoints = transport.TransportMethods.setLoopPoints;
    pub const clearLoopPoints = transport.TransportMethods.clearLoopPoints;
    pub const getRepeat = transport.TransportMethods.getRepeat;
    pub const setRepeat = transport.TransportMethods.setRepeat;
    pub const getSmoothSeekEnabled = preferences.PreferencesMethods.getSmoothSeekEnabled;
    pub const setSmoothSeekEnabled = preferences.PreferencesMethods.setSmoothSeekEnabled;
    pub const getSmoothSeekMeasures = preferences.PreferencesMethods.getSmoothSeekMeasures;
    pub const setSmoothSeekMeasures = preferences.PreferencesMethods.setSmoothSeekMeasures;
    pub const getSeekMode = preferences.PreferencesMethods.getSeekMode;
    pub const setSeekMode = preferences.PreferencesMethods.setSeekMode;

    // =========================================================================
    // Track methods (delegated)
    // =========================================================================
    pub const trackCount = tracks.TracksMethods.trackCount;
    pub const getTrackByIdx = tracks.TracksMethods.getTrackByIdx;
    pub const getTrackByUnifiedIdx = tracks.TracksMethods.getTrackByUnifiedIdx;
    pub const masterTrack = tracks.TracksMethods.masterTrack;
    pub const getTrackNameStr = tracks.TracksMethods.getTrackNameStr;
    pub const getTrackVolume = tracks.TracksMethods.getTrackVolume;
    pub const getTrackPan = tracks.TracksMethods.getTrackPan;
    pub const getTrackMute = tracks.TracksMethods.getTrackMute;
    pub const getTrackSolo = tracks.TracksMethods.getTrackSolo;
    pub const getTrackRecArm = tracks.TracksMethods.getTrackRecArm;
    pub const getTrackRecMon = tracks.TracksMethods.getTrackRecMon;
    pub const getTrackFxEnabled = tracks.TracksMethods.getTrackFxEnabled;
    pub const getTrackSelected = tracks.TracksMethods.getTrackSelected;
    pub const getTrackColor = tracks.TracksMethods.getTrackColor;
    pub const setTrackColor = tracks.TracksMethods.setTrackColor;
    pub const isMasterMuted = tracks.TracksMethods.isMasterMuted;
    pub const isMasterSoloed = tracks.TracksMethods.isMasterSoloed;
    pub const setTrackVolume = tracks.TracksMethods.setTrackVolume;
    pub const setTrackPan = tracks.TracksMethods.setTrackPan;
    pub const setTrackMute = tracks.TracksMethods.setTrackMute;
    pub const setTrackSolo = tracks.TracksMethods.setTrackSolo;
    pub const setTrackRecArm = tracks.TracksMethods.setTrackRecArm;
    pub const setTrackRecMon = tracks.TracksMethods.setTrackRecMon;
    pub const setTrackFxEnabled = tracks.TracksMethods.setTrackFxEnabled;
    pub const setTrackSelected = tracks.TracksMethods.setTrackSelected;
    pub const getSelectedTrackByIdx = tracks.TracksMethods.getSelectedTrackByIdx;
    pub const setTrackName = tracks.TracksMethods.setTrackName;
    pub const insertTrack = tracks.TracksMethods.insertTrack;
    pub const deleteTrackPtr = tracks.TracksMethods.deleteTrackPtr;
    pub const getTrackFolderDepth = tracks.TracksMethods.getTrackFolderDepth;
    pub const formatTrackGuid = tracks.TracksMethods.formatTrackGuid;
    pub const getTrackIdx = tracks.TracksMethods.getTrackIdx;
    pub const csurfSetVolume = tracks.TracksMethods.csurfSetVolume;
    pub const csurfSetPan = tracks.TracksMethods.csurfSetPan;
    pub const csurfSetMute = tracks.TracksMethods.csurfSetMute;
    pub const csurfSetSolo = tracks.TracksMethods.csurfSetSolo;
    pub const csurfSetRecArm = tracks.TracksMethods.csurfSetRecArm;
    pub const csurfSetRecMon = tracks.TracksMethods.csurfSetRecMon;
    pub const csurfFlushUndo = tracks.TracksMethods.csurfFlushUndo;

    // =========================================================================
    // Pointer Validation (delegated)
    // =========================================================================
    pub const validateTrackPtr = tracks.TracksMethods.validateTrackPtr;
    pub const validateItemPtr = tracks.TracksMethods.validateItemPtr;
    pub const validateTakePtr = tracks.TracksMethods.validateTakePtr;

    // =========================================================================
    // Item methods (delegated)
    // =========================================================================
    pub const trackItemCount = tracks.TracksMethods.trackItemCount;
    pub const getItemByIdx = tracks.TracksMethods.getItemByIdx;
    pub const getItemPosition = tracks.TracksMethods.getItemPosition;
    pub const getItemLength = tracks.TracksMethods.getItemLength;
    pub const getItemColor = tracks.TracksMethods.getItemColor;
    pub const getItemLocked = tracks.TracksMethods.getItemLocked;
    pub const getItemSelected = tracks.TracksMethods.getItemSelected;
    pub const getItemActiveTakeIdx = tracks.TracksMethods.getItemActiveTakeIdx;
    pub const getItemNotes = tracks.TracksMethods.getItemNotes;
    pub const getItemGUID = tracks.TracksMethods.getItemGUID;
    pub const setItemPosition = tracks.TracksMethods.setItemPosition;
    pub const setItemColor = tracks.TracksMethods.setItemColor;
    pub const setItemLocked = tracks.TracksMethods.setItemLocked;
    pub const setItemSelected = tracks.TracksMethods.setItemSelected;
    pub const setItemNotes = tracks.TracksMethods.setItemNotes;
    pub const setItemActiveTake = tracks.TracksMethods.setItemActiveTake;
    pub const deleteItem = tracks.TracksMethods.deleteItem;

    // =========================================================================
    // Take methods (delegated)
    // =========================================================================
    pub const itemTakeCount = tracks.TracksMethods.itemTakeCount;
    pub const getTakeByIdx = tracks.TracksMethods.getTakeByIdx;
    pub const getItemActiveTake = tracks.TracksMethods.getItemActiveTake;
    pub const getTakeNameStr = tracks.TracksMethods.getTakeNameStr;
    pub const getTakeGUID = tracks.TracksMethods.getTakeGUID;
    pub const getTakeStartOffset = tracks.TracksMethods.getTakeStartOffset;
    pub const getTakePlayrate = tracks.TracksMethods.getTakePlayrate;
    pub const isTakeMIDI = tracks.TracksMethods.isTakeMIDI;
    pub const getTakeSource = tracks.TracksMethods.getTakeSource;
    pub const getMediaSourceChannels = tracks.TracksMethods.getMediaSourceChannels;

    // =========================================================================
    // Metering (delegated)
    // =========================================================================
    pub const getTrackPeakInfo = tracks.TracksMethods.getTrackPeakInfo;

    // =========================================================================
    // Track FX (delegated)
    // =========================================================================
    pub const trackFxCount = tracks.TracksMethods.trackFxCount;
    pub const trackFxGetName = tracks.TracksMethods.trackFxGetName;
    pub const trackFxGetPresetIndex = tracks.TracksMethods.trackFxGetPresetIndex;
    pub const trackFxGetPreset = tracks.TracksMethods.trackFxGetPreset;
    pub const trackFxNavigatePresets = tracks.TracksMethods.trackFxNavigatePresets;
    pub const trackFxSetPresetByIndex = tracks.TracksMethods.trackFxSetPresetByIndex;
    pub const trackFxGetEnabled = tracks.TracksMethods.trackFxGetEnabled;
    pub const trackFxSetEnabled = tracks.TracksMethods.trackFxSetEnabled;

    // =========================================================================
    // Track Sends/Receives (delegated)
    // =========================================================================
    pub const trackSendCount = tracks.TracksMethods.trackSendCount;
    pub const trackReceiveCount = tracks.TracksMethods.trackReceiveCount;
    pub const trackSendGetVolume = tracks.TracksMethods.trackSendGetVolume;
    pub const trackSendGetPan = tracks.TracksMethods.trackSendGetPan;
    pub const trackSendGetMute = tracks.TracksMethods.trackSendGetMute;
    pub const trackSendGetMode = tracks.TracksMethods.trackSendGetMode;
    pub const trackSendGetDestTrack = tracks.TracksMethods.trackSendGetDestTrack;
    pub const trackSendGetDestName = tracks.TracksMethods.trackSendGetDestName;
    pub const trackSendSetVolume = tracks.TracksMethods.trackSendSetVolume;
    pub const trackSendSetPan = tracks.TracksMethods.trackSendSetPan;
    pub const trackSendToggleMute = tracks.TracksMethods.trackSendToggleMute;
    pub const trackSendSetMute = tracks.TracksMethods.trackSendSetMute;
    pub const trackSendSetMode = tracks.TracksMethods.trackSendSetMode;

    // =========================================================================
    // Hardware Outputs (delegated)
    // =========================================================================
    pub const trackHwOutputCount = tracks.TracksMethods.trackHwOutputCount;
    pub const trackHwOutputGetVolume = tracks.TracksMethods.trackHwOutputGetVolume;
    pub const trackHwOutputGetPan = tracks.TracksMethods.trackHwOutputGetPan;
    pub const trackHwOutputGetMute = tracks.TracksMethods.trackHwOutputGetMute;
    pub const trackHwOutputGetMode = tracks.TracksMethods.trackHwOutputGetMode;
    pub const trackHwOutputGetDestChannel = tracks.TracksMethods.trackHwOutputGetDestChannel;
    pub const trackHwOutputSetVolume = tracks.TracksMethods.trackHwOutputSetVolume;
    pub const trackHwOutputSetPan = tracks.TracksMethods.trackHwOutputSetPan;
    pub const trackHwOutputSetMute = tracks.TracksMethods.trackHwOutputSetMute;
    pub const trackHwOutputSetMode = tracks.TracksMethods.trackHwOutputSetMode;

    // =========================================================================
    // Marker methods (delegated)
    // =========================================================================
    pub const markerCount = markers.MarkersMethods.markerCount;
    pub const enumMarker = markers.MarkersMethods.enumMarker;
    pub const addMarker = markers.MarkersMethods.addMarker;
    pub const addMarkerWithId = markers.MarkersMethods.addMarkerWithId;
    pub const addRegion = markers.MarkersMethods.addRegion;
    pub const addRegionWithId = markers.MarkersMethods.addRegionWithId;
    pub const updateMarker = markers.MarkersMethods.updateMarker;
    pub const updateRegion = markers.MarkersMethods.updateRegion;
    pub const deleteMarker = markers.MarkersMethods.deleteMarker;
    pub const deleteRegion = markers.MarkersMethods.deleteRegion;

    // =========================================================================
    // Project methods (delegated)
    // =========================================================================
    pub const projectLength = project.ProjectMethods.projectLength;
    pub const projectStateChangeCount = project.ProjectMethods.projectStateChangeCount;
    pub const isDirty = project.ProjectMethods.isDirty;
    pub const markDirty = project.ProjectMethods.markDirty;
    pub const getCommandState = project.ProjectMethods.getCommandState;
    pub const getCommandStateEx = project.ProjectMethods.getCommandStateEx;
    pub const getSectionFromUniqueID = project.ProjectMethods.getSectionFromUniqueID;
    pub const enumerateActions = project.ProjectMethods.enumerateActions;
    pub const reverseNamedCommandLookup = project.ProjectMethods.reverseNamedCommandLookup;
    pub const isMetronomeEnabled = project.ProjectMethods.isMetronomeEnabled;
    pub const getMetronomeVolume = project.ProjectMethods.getMetronomeVolume;
    pub const setMetronomeVolume = project.ProjectMethods.setMetronomeVolume;
    pub const canUndo = project.ProjectMethods.canUndo;
    pub const canRedo = project.ProjectMethods.canRedo;
    pub const doUndo = project.ProjectMethods.doUndo;
    pub const doRedo = project.ProjectMethods.doRedo;
    pub const undoBeginBlock = project.ProjectMethods.undoBeginBlock;
    pub const undoEndBlock = project.ProjectMethods.undoEndBlock;
    pub const getExtStateValue = project.ProjectMethods.getExtStateValue;
    pub const setExtStateValue = project.ProjectMethods.setExtStateValue;
    pub const getProjExtStateValue = project.ProjectMethods.getProjExtStateValue;
    pub const setProjExtStateValue = project.ProjectMethods.setProjExtStateValue;
    pub const getProjectNotes = project.ProjectMethods.getProjectNotes;
    // Note: setProjectNotes is a test helper defined above, not delegated
    pub const getFrameRate = project.ProjectMethods.getFrameRate;
    pub const enumCurrentProject = project.ProjectMethods.enumCurrentProject;
    pub const getProjectName = project.ProjectMethods.getProjectName;
    pub const namedCommandLookup = project.ProjectMethods.namedCommandLookup;
    pub const sendMidiCC = project.ProjectMethods.sendMidiCC;
    pub const sendMidiPC = project.ProjectMethods.sendMidiPC;
    pub const sendNoteOn = project.ProjectMethods.sendNoteOn;
    pub const sendPitchBend = project.ProjectMethods.sendPitchBend;
    pub const updateTimeline = project.ProjectMethods.updateTimeline;

    // =========================================================================
    // MIDI Editor (for section-specific action execution)
    // =========================================================================
    pub const midiEditorGetActive = project.ProjectMethods.midiEditorGetActive;
    pub const midiEditorOnCommand = project.ProjectMethods.midiEditorOnCommand;

    // =========================================================================
    // Input enumeration (delegated)
    // =========================================================================
    pub const numAudioInputs = inputs.InputsMethods.numAudioInputs;
    pub const audioInputName = inputs.InputsMethods.audioInputName;
    pub const maxMidiInputs = inputs.InputsMethods.maxMidiInputs;
    pub const midiInputName = inputs.InputsMethods.midiInputName;
    pub const getTrackRecInput = inputs.InputsMethods.getTrackRecInput;
    pub const setTrackRecInput = inputs.InputsMethods.setTrackRecInput;
};

// Validate at comptime that MockBackend has all required methods
comptime {
    backend.validateBackend(MockBackend);
}

// =============================================================================
// Tests
// =============================================================================

test "MockBackend returns configured values" {
    var mock = MockBackend{
        .play_state = 1,
        .play_position = 5.5,
        .bpm = 140.0,
    };

    try std.testing.expectEqual(@as(c_int, 1), mock.playState());
    try std.testing.expectEqual(@as(f64, 5.5), mock.playPosition());
}

test "MockBackend injects NaN for position" {
    var mock = MockBackend{
        .inject_nan_position = true,
    };

    try std.testing.expect(std.math.isNan(mock.playPosition()));
}

test "MockBackend tracks call counts" {
    var mock = MockBackend{};

    _ = mock.playState();
    _ = mock.playState();
    _ = mock.playPosition();

    try std.testing.expectEqual(@as(usize, 2), mock.getCallCount(.playState));
    try std.testing.expectEqual(@as(usize, 1), mock.getCallCount(.playPosition));
}

test "MockBackend index-as-pointer pattern for tracks" {
    var mock = MockBackend{
        .track_count = 2,
    };
    mock.tracks[0].solo = 1;
    mock.tracks[1].solo = 2;

    // Get track handles (encoded indices)
    const track0 = mock.getTrackByUnifiedIdx(0).?;
    const track1 = mock.getTrackByUnifiedIdx(1).?;

    // Verify they decode correctly
    try std.testing.expectEqual(@as(c_int, 1), try mock.getTrackSolo(track0));
    try std.testing.expectEqual(@as(c_int, 2), try mock.getTrackSolo(track1));
}

test "MockBackend time conversion" {
    var mock = MockBackend{
        .bpm = 120.0, // 2 beats per second
        .timesig_num = 4,
        .timesig_denom = 4,
    };

    // At 120 BPM, 2 seconds = 4 beats = 1 bar
    const beats = mock.timeToBeats(2.0);
    try std.testing.expectEqual(@as(f64, 4.0), beats.beats);
    try std.testing.expectEqual(@as(c_int, 2), beats.measures); // Bar 2 (1-based)

    // And back to time
    const time = mock.beatsToTime(4.0);
    try std.testing.expectEqual(@as(f64, 2.0), time);
}

test "MockBackend track name" {
    var mock = MockBackend{
        .track_count = 1,
    };
    mock.tracks[0].setName("My Track");

    const track = mock.getTrackByUnifiedIdx(0).?;
    var buf: [128]u8 = undefined;
    const name = mock.getTrackNameStr(track, &buf);

    try std.testing.expectEqualStrings("My Track", name);
}

test "MockBackend items and takes" {
    var mock = MockBackend{
        .track_count = 1,
    };
    mock.tracks[0].item_count = 1;
    mock.tracks[0].items[0].position = 1.5;
    mock.tracks[0].items[0].length = 2.0;
    mock.tracks[0].items[0].take_count = 1;
    mock.tracks[0].items[0].takes[0].setName("Take 1");

    const track = mock.getTrackByUnifiedIdx(0).?;
    const item = mock.getItemByIdx(track, 0).?;

    try std.testing.expectEqual(@as(f64, 1.5), mock.getItemPosition(item));
    try std.testing.expectEqual(@as(f64, 2.0), mock.getItemLength(item));

    const take = mock.getTakeByIdx(item, 0).?;
    try std.testing.expectEqualStrings("Take 1", mock.getTakeNameStr(take));
}

test "MockBackend setTrackColor" {
    var mock = MockBackend{
        .track_count = 1,
    };
    mock.tracks[0].color = 0;

    const track = mock.getTrackByUnifiedIdx(0).?;

    // Set custom color
    mock.setTrackColor(track, 0x01FF0000); // Red with custom flag
    try std.testing.expectEqual(@as(c_int, 0x01FF0000), mock.getTrackColor(track));

    // Reset to default (0)
    mock.setTrackColor(track, 0);
    try std.testing.expectEqual(@as(c_int, 0), mock.getTrackColor(track));
}

test "MockBackend trackFxSetEnabled" {
    var mock = MockBackend{
        .track_count = 1,
    };
    mock.tracks[0].fx_count = 2;
    mock.tracks[0].fx[0].enabled = true;
    mock.tracks[0].fx[1].enabled = false;

    const track = mock.getTrackByUnifiedIdx(0).?;

    // Verify initial state
    try std.testing.expect(mock.trackFxGetEnabled(track, 0));
    try std.testing.expect(!mock.trackFxGetEnabled(track, 1));

    // Toggle FX 0 off
    mock.trackFxSetEnabled(track, 0, false);
    try std.testing.expect(!mock.trackFxGetEnabled(track, 0));

    // Toggle FX 1 on
    mock.trackFxSetEnabled(track, 1, true);
    try std.testing.expect(mock.trackFxGetEnabled(track, 1));
}

test "MockBackend trackFxSetEnabled bounds check" {
    var mock = MockBackend{
        .track_count = 1,
    };
    mock.tracks[0].fx_count = 1;
    mock.tracks[0].fx[0].enabled = true;

    const track = mock.getTrackByUnifiedIdx(0).?;

    // Negative index should be ignored (no crash)
    mock.trackFxSetEnabled(track, -1, false);
    try std.testing.expect(mock.trackFxGetEnabled(track, 0)); // Unchanged

    // Out of range index should be ignored (no crash)
    mock.trackFxSetEnabled(track, 5, false);
    try std.testing.expect(mock.trackFxGetEnabled(track, 0)); // Unchanged
}
