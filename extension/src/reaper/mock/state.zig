/// Mock state fields and helper types for testing.
///
/// This file contains all the configurable state that MockBackend exposes.
/// The actual method implementations are in domain-specific files.
const std = @import("std");
const types = @import("../types.zig");

// =========================================================================
// Constants
// =========================================================================

pub const MAX_TRACKS = 32;
pub const MAX_ITEMS_PER_TRACK = 16;
pub const MAX_TAKES_PER_ITEM = 4;
pub const MAX_FX_PER_TRACK = 64;
pub const MAX_SENDS_PER_TRACK = 16;
pub const MAX_MARKERS = 64;
pub const MAX_CALLS = 256;

// =========================================================================
// Helper types
// =========================================================================

pub const CommandStateEntry = struct {
    cmd: c_int = 0,
    state: c_int = -1,
};

pub const ExtStateEntry = struct {
    section: [64]u8 = undefined,
    section_len: usize = 0,
    key: [64]u8 = undefined,
    key_len: usize = 0,
    value: [256]u8 = undefined,
    value_len: usize = 0,
};

pub const CallEntry = struct {
    method: Method,
    timestamp_ns: i128 = 0,
};

pub const Method = enum {
    // Transport
    playState,
    playPosition,
    cursorPosition,
    timePrecise,
    timePreciseMs,
    runCommand,
    setCursorPos,
    // Time
    timeToBeats,
    beatsToTime,
    barBeatToTime,
    timeSignature,
    getTempoAtPosition,
    tempoMarkerCount,
    getTempoMarker,
    getBarOffset,
    getTimeSignatureNumerator,
    getTimeSignatureDenominator,
    setTempo,
    setTimeSignature,
    timeSelection,
    setTimeSelection,
    clearTimeSelection,
    // Loop points
    getLoopPoints,
    setLoopPoints,
    clearLoopPoints,
    // Repeat
    getRepeat,
    setRepeat,
    // Smooth seek
    getSmoothSeekEnabled,
    setSmoothSeekEnabled,
    getSmoothSeekMeasures,
    setSmoothSeekMeasures,
    getSeekMode,
    setSeekMode,
    // Project
    projectLength,
    projectStateChangeCount,
    isDirty,
    markDirty,
    getFrameRate,
    enumCurrentProject,
    getProjectName,
    getCommandState,
    isMetronomeEnabled,
    getMetronomeVolume,
    setMetronomeVolume,
    canUndo,
    canRedo,
    doUndo,
    doRedo,
    undoBeginBlock,
    undoEndBlock,
    // Tracks
    trackCount,
    getTrackByIdx,
    getTrackByUnifiedIdx,
    masterTrack,
    getTrackNameStr,
    getTrackVolume,
    getTrackPan,
    getTrackMute,
    getTrackSolo,
    getTrackRecArm,
    getTrackRecMon,
    getTrackFxEnabled,
    getTrackSelected,
    getTrackColor,
    getTrackFolderDepth,
    getSelectedTrackByIdx,
    isMasterMuted,
    isMasterSoloed,
    setTrackVolume,
    setTrackPan,
    setTrackMute,
    setTrackSolo,
    setTrackRecArm,
    setTrackRecMon,
    setTrackFxEnabled,
    setTrackSelected,
    setTrackName,
    insertTrack,
    deleteTrackPtr,
    csurfSetVolume,
    csurfSetPan,
    csurfSetMute,
    csurfSetSolo,
    csurfSetRecArm,
    csurfSetRecMon,
    csurfFlushUndo,
    // Items
    trackItemCount,
    getItemByIdx,
    getItemPosition,
    getItemLength,
    getItemColor,
    getItemLocked,
    getItemSelected,
    getItemActiveTakeIdx,
    getItemNotes,
    getItemGUID,
    setItemPosition,
    setItemColor,
    setItemLocked,
    setItemSelected,
    setItemNotes,
    setItemActiveTake,
    deleteItem,
    // Takes
    itemTakeCount,
    getTakeByIdx,
    getItemActiveTake,
    getTakeNameStr,
    getTakeGUID,
    getTakeStartOffset,
    getTakePlayrate,
    isTakeMIDI,
    getTakeSource,
    getMediaSourceChannels,
    // Markers
    markerCount,
    enumMarker,
    addMarker,
    addMarkerWithId,
    addRegion,
    addRegionWithId,
    updateMarker,
    updateRegion,
    deleteMarker,
    deleteRegion,
    // Metering
    getTrackPeakInfo,
    // ExtState
    getExtStateValue,
    setExtStateValue,
    getProjExtStateValue,
    setProjExtStateValue,
    // Project notes
    getProjectNotes,
    setProjectNotes,
    // Named command
    namedCommandLookup,
    // MIDI
    sendMidiCC,
    sendMidiPC,
    // UI
    updateTimeline,
    // Track FX
    trackFxCount,
    trackFxGetName,
    trackFxGetPresetIndex,
    trackFxGetPreset,
    trackFxNavigatePresets,
    trackFxSetPresetByIndex,
    // Track Sends
    trackSendCount,
    trackSendGetVolume,
    trackSendGetMute,
    trackSendGetMode,
    trackSendGetDestName,
    trackSendSetVolume,
    trackSendToggleMute,
    trackSendSetMute,
};

pub const MockTrack = struct {
    name: [128]u8 = [_]u8{0} ** 128,
    name_len: usize = 0,
    volume: f64 = 1.0,
    pan: f64 = 0.0,
    mute: bool = false,
    solo: c_int = 0,
    rec_arm: bool = false,
    rec_mon: c_int = 0,
    fx_enabled: bool = true,
    selected: bool = false,
    color: c_int = 0,
    folder_depth: c_int = 0,
    peak_left: f64 = 0.0,
    peak_right: f64 = 0.0,

    // Items for this track
    item_count: c_int = 0,
    items: [MAX_ITEMS_PER_TRACK]MockItem = [_]MockItem{.{}} ** MAX_ITEMS_PER_TRACK,

    // FX for this track
    fx_count: c_int = 0,
    fx: [MAX_FX_PER_TRACK]MockFx = [_]MockFx{.{}} ** MAX_FX_PER_TRACK,

    // Sends for this track
    send_count: c_int = 0,
    sends: [MAX_SENDS_PER_TRACK]MockSend = [_]MockSend{.{}} ** MAX_SENDS_PER_TRACK,

    pub fn setName(self: *MockTrack, name: []const u8) void {
        const len = @min(name.len, self.name.len);
        @memcpy(self.name[0..len], name[0..len]);
        self.name_len = len;
    }

    pub fn getName(self: *const MockTrack) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const MockItem = struct {
    position: f64 = 0.0,
    length: f64 = 1.0,
    color: c_int = 0,
    locked: bool = false,
    selected: bool = false,
    active_take_idx: c_int = 0,
    notes: [256]u8 = [_]u8{0} ** 256,
    notes_len: usize = 0,
    guid: [40]u8 = [_]u8{0} ** 40,
    guid_len: usize = 0,

    // Takes for this item
    take_count: c_int = 0,
    takes: [MAX_TAKES_PER_ITEM]MockTake = [_]MockTake{.{}} ** MAX_TAKES_PER_ITEM,

    pub fn setNotes(self: *MockItem, notes: []const u8) void {
        const len = @min(notes.len, self.notes.len);
        @memcpy(self.notes[0..len], notes[0..len]);
        self.notes_len = len;
    }
};

pub const MockTake = struct {
    name: [128]u8 = [_]u8{0} ** 128,
    name_len: usize = 0,
    guid: [40]u8 = [_]u8{0} ** 40,
    guid_len: usize = 0,
    start_offset: f64 = 0.0,
    playrate: f64 = 1.0,
    is_midi: bool = false,
    channel_count: c_int = 2,

    pub fn setName(self: *MockTake, name: []const u8) void {
        const len = @min(name.len, self.name.len);
        @memcpy(self.name[0..len], name[0..len]);
        self.name_len = len;
    }
};

/// Mock marker/region info with fixed-size name storage.
/// The real types.MarkerInfo uses a slice for name which doesn't work
/// with fixed storage. This type mirrors the field layout tests expect.
pub const MockMarkerInfo = struct {
    idx: c_int = 0, // enumeration index
    id: c_int = 0, // displayed marker/region ID
    is_region: bool = false,
    pos: f64 = 0.0, // position in seconds
    end: f64 = 0.0, // end position for regions
    name: [128]u8 = [_]u8{0} ** 128,
    name_len: usize = 0,
    color: c_int = 0,

    pub fn setName(self: *MockMarkerInfo, name_str: []const u8) void {
        const len = @min(name_str.len, self.name.len);
        @memcpy(self.name[0..len], name_str[0..len]);
        self.name_len = len;
    }

    pub fn getName(self: *const MockMarkerInfo) []const u8 {
        return self.name[0..self.name_len];
    }

    /// Convert to types.MarkerInfo for API return.
    /// The returned slice points to this struct's name buffer.
    pub fn toMarkerInfo(self: *const MockMarkerInfo) types.MarkerInfo {
        return .{
            .idx = self.idx,
            .id = self.id,
            .is_region = self.is_region,
            .pos = self.pos,
            .end = self.end,
            .name = self.name[0..self.name_len],
            .color = self.color,
        };
    }
};

/// Mock FX slot for testing preset switching.
pub const MockFx = struct {
    name: [128]u8 = [_]u8{0} ** 128,
    name_len: usize = 0,
    preset_name: [128]u8 = [_]u8{0} ** 128,
    preset_name_len: usize = 0,
    preset_index: c_int = -1, // -1 = no preset selected
    preset_count: c_int = 0,
    params_match_preset: bool = true, // True if params exactly match loaded preset

    pub fn setName(self: *MockFx, fx_name: []const u8) void {
        const len = @min(fx_name.len, self.name.len);
        @memcpy(self.name[0..len], fx_name[0..len]);
        self.name_len = len;
    }

    pub fn getName(self: *const MockFx) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn setPresetName(self: *MockFx, preset: []const u8) void {
        const len = @min(preset.len, self.preset_name.len);
        @memcpy(self.preset_name[0..len], preset[0..len]);
        self.preset_name_len = len;
    }

    pub fn getPresetName(self: *const MockFx) []const u8 {
        return self.preset_name[0..self.preset_name_len];
    }
};

/// Mock send slot for testing send control.
pub const MockSend = struct {
    dest_name: [128]u8 = [_]u8{0} ** 128,
    dest_name_len: usize = 0,
    volume: f64 = 1.0, // Linear, 1.0 = 0dB
    muted: bool = false,
    mode: c_int = 0, // 0=post-fader, 1=pre-FX, 3=post-FX

    pub fn setDestName(self: *MockSend, name: []const u8) void {
        const len = @min(name.len, self.dest_name.len);
        @memcpy(self.dest_name[0..len], name[0..len]);
        self.dest_name_len = len;
    }

    pub fn getDestName(self: *const MockSend) []const u8 {
        return self.dest_name[0..self.dest_name_len];
    }
};

// =========================================================================
// Index-as-pointer encoding
// =========================================================================

/// Encode a track index as a pointer.
/// +1 to avoid null (index 0 becomes pointer 1).
pub fn encodeTrackPtr(idx: c_int) ?*anyopaque {
    if (idx < 0) return null;
    return @ptrFromInt(@as(usize, @intCast(idx)) + 1);
}

/// Decode a track pointer back to index.
pub fn decodeTrackPtr(ptr: *anyopaque) usize {
    return @intFromPtr(ptr) - 1;
}

/// Encode an item index as a pointer.
/// High bits = track index, low bits = item index.
pub fn encodeItemPtr(track_idx: usize, item_idx: c_int) ?*anyopaque {
    if (item_idx < 0) return null;
    const encoded = (track_idx << 16) | @as(usize, @intCast(item_idx));
    return @ptrFromInt(encoded + 1);
}

/// Decode an item pointer back to (track_idx, item_idx).
pub fn decodeItemPtr(ptr: *anyopaque) struct { track_idx: usize, item_idx: usize } {
    const val = @intFromPtr(ptr) - 1;
    return .{
        .track_idx = val >> 16,
        .item_idx = val & 0xFFFF,
    };
}

/// Encode a take index as a pointer.
/// High bits = track index, mid bits = item index, low bits = take index.
pub fn encodeTakePtr(track_idx: usize, item_idx: usize, take_idx: c_int) ?*anyopaque {
    if (take_idx < 0) return null;
    const encoded = (track_idx << 24) | (item_idx << 12) | @as(usize, @intCast(take_idx));
    return @ptrFromInt(encoded + 1);
}

/// Decode a take pointer back to (track_idx, item_idx, take_idx).
pub fn decodeTakePtr(ptr: *anyopaque) struct { track_idx: usize, item_idx: usize, take_idx: usize } {
    const val = @intFromPtr(ptr) - 1;
    return .{
        .track_idx = (val >> 24) & 0xFF,
        .item_idx = (val >> 12) & 0xFFF,
        .take_idx = val & 0xFFF,
    };
}
