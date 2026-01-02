/// Mock API for testing state modules without REAPER running.
///
/// Features:
/// - Field-based state for fast access and easy setup
/// - Index-as-pointer pattern for track/item handles (can't dangle)
/// - Error injection flags for testing error paths
/// - Call tracking for verification
///
/// Usage:
///   var mock = MockApi{
///       .play_state = 1,
///       .play_position = 5.5,
///       .track_count = 2,
///   };
///   mock.tracks[0].name = "Track 1";
///   mock.tracks[0].volume = 0.8;
///
///   const api = mock.interface();
///   const state = transport.poll(api);
const std = @import("std");
const api_mod = @import("api.zig");
const ApiInterface = api_mod.ApiInterface;
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

/// Mock REAPER API for testing.
pub const MockApi = struct {
    // =========================================================================
    // Transport state
    // =========================================================================
    play_state: c_int = 0,
    play_position: f64 = 0.0,
    cursor_position: f64 = 0.0,
    server_time_s: f64 = 0.0,

    // =========================================================================
    // Tempo/timing state
    // =========================================================================
    bpm: f64 = 120.0,
    timesig_num: c_int = 4,
    timesig_denom: c_int = 4,
    bar_offset: c_int = 0,
    tempo_marker_count: c_int = 0,
    tempo_markers: [8]TempoMarker = [_]TempoMarker{.{
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
    // Repeat state
    // =========================================================================
    repeat_enabled: bool = false,

    // =========================================================================
    // Project state
    // =========================================================================
    project_length: f64 = 0.0,
    project_state_change_count: c_int = 0,
    project_dirty: bool = false,

    // =========================================================================
    // Command state
    // =========================================================================
    metronome_enabled: bool = false,
    metronome_volume: f64 = 1.0,
    command_states: [16]CommandStateEntry = [_]CommandStateEntry{.{}} ** 16,
    command_state_count: usize = 0,

    // =========================================================================
    // Undo/Redo (fixed buffers for testing)
    // =========================================================================
    undo_desc: [128]u8 = [_]u8{0} ** 128,
    undo_desc_len: usize = 0,
    redo_desc: [128]u8 = [_]u8{0} ** 128,
    redo_desc_len: usize = 0,

    // =========================================================================
    // Tracks (fixed array for testing)
    // =========================================================================
    track_count: c_int = 0,
    tracks: [MAX_TRACKS]MockTrack = [_]MockTrack{.{}} ** MAX_TRACKS,
    master_muted: bool = false,
    master_soloed: bool = false,

    // =========================================================================
    // Markers (fixed array for testing)
    // =========================================================================
    marker_count: c_int = 0,
    region_count: c_int = 0,
    markers: [MAX_MARKERS]MarkerInfo = undefined,

    // =========================================================================
    // ExtState (fixed array for testing)
    // =========================================================================
    ext_states: [16]ExtStateEntry = [_]ExtStateEntry{.{}} ** 16,
    ext_state_count: usize = 0,

    // =========================================================================
    // Error injection flags
    // =========================================================================
    inject_nan_position: bool = false,
    inject_nan_beats: bool = false,
    inject_solo_error: bool = false,
    inject_recmon_error: bool = false,

    // =========================================================================
    // Call tracking (fixed-size, no allocation)
    // =========================================================================
    call_log: [MAX_CALLS]CallEntry = undefined,
    call_count: usize = 0,

    // =========================================================================
    // Constants
    // =========================================================================
    pub const MAX_TRACKS = 32;
    pub const MAX_ITEMS_PER_TRACK = 16;
    pub const MAX_TAKES_PER_ITEM = 4;
    pub const MAX_MARKERS = 64;
    pub const MAX_CALLS = 256;

    pub const CommandStateEntry = struct { cmd: c_int = 0, state: c_int = -1 };

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
        playState,
        playPosition,
        cursorPosition,
        timePrecise,
        timePreciseMs,
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
        timeSelection,
        getRepeat,
        projectLength,
        projectStateChangeCount,
        isDirty,
        getCommandState,
        isMetronomeEnabled,
        getMetronomeVolume,
        canUndo,
        canRedo,
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
        isMasterMuted,
        isMasterSoloed,
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
        markerCount,
        enumMarker,
        getTrackPeakInfo,
        getExtStateValue,
        getProjExtStateValue,
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
        peak_left: f64 = 0.0,
        peak_right: f64 = 0.0,

        // Items for this track
        item_count: c_int = 0,
        items: [MAX_ITEMS_PER_TRACK]MockItem = [_]MockItem{.{}} ** MAX_ITEMS_PER_TRACK,

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

    /// Get ApiInterface for this mock.
    pub fn interface(self: *MockApi) ApiInterface {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Record a method call for verification.
    fn recordCall(self: *MockApi, method: Method) void {
        if (self.call_count < MAX_CALLS) {
            self.call_log[self.call_count] = .{
                .method = method,
                .timestamp_ns = std.time.nanoTimestamp(),
            };
            self.call_count += 1;
        }
    }

    /// Get count of calls to a specific method.
    pub fn getCallCount(self: *const MockApi, method: Method) usize {
        var count: usize = 0;
        for (self.call_log[0..self.call_count]) |entry| {
            if (entry.method == method) count += 1;
        }
        return count;
    }

    /// Reset call tracking.
    pub fn resetCalls(self: *MockApi) void {
        self.call_count = 0;
    }

    /// Set a command state for testing.
    pub fn setCommandState(self: *MockApi, cmd: c_int, state: c_int) void {
        // Check if command already exists
        for (&self.command_states[0..self.command_state_count]) |*entry| {
            if (entry.cmd == cmd) {
                entry.state = state;
                return;
            }
        }
        // Add new entry
        if (self.command_state_count < self.command_states.len) {
            self.command_states[self.command_state_count] = .{ .cmd = cmd, .state = state };
            self.command_state_count += 1;
        }
    }

    /// Set undo description for testing.
    pub fn setUndoDesc(self: *MockApi, desc: []const u8) void {
        const len = @min(desc.len, self.undo_desc.len);
        @memcpy(self.undo_desc[0..len], desc[0..len]);
        self.undo_desc_len = len;
    }

    /// Set redo description for testing.
    pub fn setRedoDesc(self: *MockApi, desc: []const u8) void {
        const len = @min(desc.len, self.redo_desc.len);
        @memcpy(self.redo_desc[0..len], desc[0..len]);
        self.redo_desc_len = len;
    }

    // =========================================================================
    // Index-as-pointer encoding
    // =========================================================================

    /// Encode a track index as a pointer.
    /// +1 to avoid null (index 0 becomes pointer 1).
    fn encodeTrackPtr(idx: c_int) ?*anyopaque {
        if (idx < 0) return null;
        return @ptrFromInt(@as(usize, @intCast(idx)) + 1);
    }

    /// Decode a track pointer back to index.
    fn decodeTrackPtr(ptr: *anyopaque) usize {
        return @intFromPtr(ptr) - 1;
    }

    /// Encode an item index as a pointer.
    /// High bits = track index, low bits = item index.
    fn encodeItemPtr(track_idx: usize, item_idx: c_int) ?*anyopaque {
        if (item_idx < 0) return null;
        const encoded = (track_idx << 16) | @as(usize, @intCast(item_idx));
        return @ptrFromInt(encoded + 1);
    }

    /// Decode an item pointer back to (track_idx, item_idx).
    fn decodeItemPtr(ptr: *anyopaque) struct { track_idx: usize, item_idx: usize } {
        const val = @intFromPtr(ptr) - 1;
        return .{
            .track_idx = val >> 16,
            .item_idx = val & 0xFFFF,
        };
    }

    /// Encode a take index as a pointer.
    /// High bits = track index, mid bits = item index, low bits = take index.
    fn encodeTakePtr(track_idx: usize, item_idx: usize, take_idx: c_int) ?*anyopaque {
        if (take_idx < 0) return null;
        const encoded = (track_idx << 24) | (item_idx << 12) | @as(usize, @intCast(take_idx));
        return @ptrFromInt(encoded + 1);
    }

    /// Decode a take pointer back to (track_idx, item_idx, take_idx).
    fn decodeTakePtr(ptr: *anyopaque) struct { track_idx: usize, item_idx: usize, take_idx: usize } {
        const val = @intFromPtr(ptr) - 1;
        return .{
            .track_idx = (val >> 24) & 0xFF,
            .item_idx = (val >> 12) & 0xFFF,
            .take_idx = val & 0xFFF,
        };
    }

    // =========================================================================
    // VTable implementation
    // =========================================================================

    const vtable: ApiInterface.VTable = .{
        // Transport
        .playState = struct {
            fn f(ctx: *anyopaque) c_int {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.playState);
                return self.play_state;
            }
        }.f,
        .playPosition = struct {
            fn f(ctx: *anyopaque) f64 {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.playPosition);
                if (self.inject_nan_position) return std.math.nan(f64);
                return self.play_position;
            }
        }.f,
        .cursorPosition = struct {
            fn f(ctx: *anyopaque) f64 {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.cursorPosition);
                return self.cursor_position;
            }
        }.f,
        .timePrecise = struct {
            fn f(ctx: *anyopaque) f64 {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.timePrecise);
                return self.server_time_s;
            }
        }.f,
        .timePreciseMs = struct {
            fn f(ctx: *anyopaque) f64 {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.timePreciseMs);
                return self.server_time_s * 1000.0;
            }
        }.f,

        // Time conversion
        .timeToBeats = struct {
            fn f(ctx: *anyopaque, time: f64) BeatsInfo {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.timeToBeats);

                if (self.inject_nan_beats) {
                    return .{
                        .beats = std.math.nan(f64),
                        .measures = 1,
                        .beats_in_measure = std.math.nan(f64),
                        .time_sig_denom = 4,
                    };
                }

                // Simple calculation for testing
                const beats_per_second = self.bpm / 60.0;
                const total_beats = time * beats_per_second;
                const beats_per_bar: f64 = @floatFromInt(self.timesig_num);
                const bar = @as(c_int, @intFromFloat(@floor(total_beats / beats_per_bar)));
                const beat_in_bar = @mod(total_beats, beats_per_bar);

                return .{
                    .beats = total_beats,
                    .measures = bar + 1,
                    .beats_in_measure = beat_in_bar,
                    .time_sig_denom = self.timesig_denom,
                };
            }
        }.f,
        .beatsToTime = struct {
            fn f(ctx: *anyopaque, beats: f64) f64 {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.beatsToTime);
                const beats_per_second = self.bpm / 60.0;
                return beats / beats_per_second;
            }
        }.f,
        .barBeatToTime = struct {
            fn f(ctx: *anyopaque, bar: c_int, beat: f64) f64 {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.barBeatToTime);
                const beats_per_bar: f64 = @floatFromInt(self.timesig_num);
                const total_beats = @as(f64, @floatFromInt(bar - 1)) * beats_per_bar + (beat - 1.0);
                const beats_per_second = self.bpm / 60.0;
                return total_beats / beats_per_second;
            }
        }.f,

        // Tempo / Time signature
        .timeSignature = struct {
            fn f(ctx: *anyopaque) TimeSignature {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.timeSignature);
                return .{ .bpm = self.bpm, .num = @floatFromInt(self.timesig_num) };
            }
        }.f,
        .getTempoAtPosition = struct {
            fn f(ctx: *anyopaque, _: f64) TempoAtPosition {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getTempoAtPosition);
                return .{
                    .bpm = self.bpm,
                    .timesig_num = self.timesig_num,
                    .timesig_denom = self.timesig_denom,
                };
            }
        }.f,
        .tempoMarkerCount = struct {
            fn f(ctx: *anyopaque) c_int {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.tempoMarkerCount);
                return self.tempo_marker_count;
            }
        }.f,
        .getTempoMarker = struct {
            fn f(ctx: *anyopaque, idx: c_int) ?TempoMarker {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getTempoMarker);
                if (idx < 0 or idx >= self.tempo_marker_count) return null;
                return self.tempo_markers[@intCast(idx)];
            }
        }.f,
        .getBarOffset = struct {
            fn f(ctx: *anyopaque) c_int {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getBarOffset);
                return self.bar_offset;
            }
        }.f,
        .getTimeSignatureNumerator = struct {
            fn f(ctx: *anyopaque) c_int {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getTimeSignatureNumerator);
                return self.timesig_num;
            }
        }.f,
        .getTimeSignatureDenominator = struct {
            fn f(ctx: *anyopaque) c_int {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getTimeSignatureDenominator);
                return self.timesig_denom;
            }
        }.f,

        // Time selection
        .timeSelection = struct {
            fn f(ctx: *anyopaque) TimeSelection {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.timeSelection);
                return .{ .start = self.time_sel_start, .end = self.time_sel_end };
            }
        }.f,

        // Repeat
        .getRepeat = struct {
            fn f(ctx: *anyopaque) bool {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getRepeat);
                return self.repeat_enabled;
            }
        }.f,

        // Project info
        .projectLength = struct {
            fn f(ctx: *anyopaque) f64 {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.projectLength);
                return self.project_length;
            }
        }.f,
        .projectStateChangeCount = struct {
            fn f(ctx: *anyopaque) c_int {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.projectStateChangeCount);
                return self.project_state_change_count;
            }
        }.f,
        .isDirty = struct {
            fn f(ctx: *anyopaque) bool {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.isDirty);
                return self.project_dirty;
            }
        }.f,

        // Command state
        .getCommandState = struct {
            fn f(ctx: *anyopaque, cmd: c_int) c_int {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getCommandState);
                for (self.command_states[0..self.command_state_count]) |entry| {
                    if (entry.cmd == cmd) return entry.state;
                }
                return -1;
            }
        }.f,
        .isMetronomeEnabled = struct {
            fn f(ctx: *anyopaque) bool {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.isMetronomeEnabled);
                return self.metronome_enabled;
            }
        }.f,
        .getMetronomeVolume = struct {
            fn f(ctx: *anyopaque) f64 {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getMetronomeVolume);
                return self.metronome_volume;
            }
        }.f,

        // Undo/Redo
        .canUndo = struct {
            fn f(ctx: *anyopaque) ?[]const u8 {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.canUndo);
                if (self.undo_desc_len == 0) return null;
                return self.undo_desc[0..self.undo_desc_len];
            }
        }.f,
        .canRedo = struct {
            fn f(ctx: *anyopaque) ?[]const u8 {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.canRedo);
                if (self.redo_desc_len == 0) return null;
                return self.redo_desc[0..self.redo_desc_len];
            }
        }.f,

        // Tracks
        .trackCount = struct {
            fn f(ctx: *anyopaque) c_int {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.trackCount);
                return self.track_count;
            }
        }.f,
        .getTrackByIdx = struct {
            fn f(ctx: *anyopaque, idx: c_int) ?*anyopaque {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getTrackByIdx);
                if (idx < 0 or idx >= self.track_count) return null;
                return encodeTrackPtr(idx);
            }
        }.f,
        .getTrackByUnifiedIdx = struct {
            fn f(ctx: *anyopaque, idx: c_int) ?*anyopaque {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getTrackByUnifiedIdx);
                // 0 = master, 1+ = regular tracks
                if (idx < 0 or idx > self.track_count) return null;
                return encodeTrackPtr(idx);
            }
        }.f,
        .masterTrack = struct {
            fn f(ctx: *anyopaque) ?*anyopaque {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.masterTrack);
                return encodeTrackPtr(0); // Master is track 0 in unified scheme
            }
        }.f,
        .getTrackNameStr = struct {
            fn f(ctx: *anyopaque, track: *anyopaque, buf: []u8) []const u8 {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getTrackNameStr);
                const idx = decodeTrackPtr(track);
                if (idx >= MAX_TRACKS) return "";
                const name = self.tracks[idx].getName();
                const len = @min(name.len, buf.len);
                @memcpy(buf[0..len], name[0..len]);
                return buf[0..len];
            }
        }.f,
        .getTrackVolume = struct {
            fn f(ctx: *anyopaque, track: *anyopaque) f64 {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getTrackVolume);
                const idx = decodeTrackPtr(track);
                if (idx >= MAX_TRACKS) return 1.0;
                return self.tracks[idx].volume;
            }
        }.f,
        .getTrackPan = struct {
            fn f(ctx: *anyopaque, track: *anyopaque) f64 {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getTrackPan);
                const idx = decodeTrackPtr(track);
                if (idx >= MAX_TRACKS) return 0.0;
                return self.tracks[idx].pan;
            }
        }.f,
        .getTrackMute = struct {
            fn f(ctx: *anyopaque, track: *anyopaque) bool {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getTrackMute);
                const idx = decodeTrackPtr(track);
                if (idx >= MAX_TRACKS) return false;
                return self.tracks[idx].mute;
            }
        }.f,
        .getTrackSolo = struct {
            fn f(ctx: *anyopaque, track: *anyopaque) ffi.FFIError!c_int {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getTrackSolo);
                if (self.inject_solo_error) return ffi.FFIError.FloatIsNaN;
                const idx = decodeTrackPtr(track);
                if (idx >= MAX_TRACKS) return 0;
                return self.tracks[idx].solo;
            }
        }.f,
        .getTrackRecArm = struct {
            fn f(ctx: *anyopaque, track: *anyopaque) bool {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getTrackRecArm);
                const idx = decodeTrackPtr(track);
                if (idx >= MAX_TRACKS) return false;
                return self.tracks[idx].rec_arm;
            }
        }.f,
        .getTrackRecMon = struct {
            fn f(ctx: *anyopaque, track: *anyopaque) ffi.FFIError!c_int {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getTrackRecMon);
                if (self.inject_recmon_error) return ffi.FFIError.FloatIsNaN;
                const idx = decodeTrackPtr(track);
                if (idx >= MAX_TRACKS) return 0;
                return self.tracks[idx].rec_mon;
            }
        }.f,
        .getTrackFxEnabled = struct {
            fn f(ctx: *anyopaque, track: *anyopaque) bool {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getTrackFxEnabled);
                const idx = decodeTrackPtr(track);
                if (idx >= MAX_TRACKS) return true;
                return self.tracks[idx].fx_enabled;
            }
        }.f,
        .getTrackSelected = struct {
            fn f(ctx: *anyopaque, track: *anyopaque) bool {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getTrackSelected);
                const idx = decodeTrackPtr(track);
                if (idx >= MAX_TRACKS) return false;
                return self.tracks[idx].selected;
            }
        }.f,
        .getTrackColor = struct {
            fn f(ctx: *anyopaque, track: *anyopaque) c_int {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getTrackColor);
                const idx = decodeTrackPtr(track);
                if (idx >= MAX_TRACKS) return 0;
                return self.tracks[idx].color;
            }
        }.f,
        .isMasterMuted = struct {
            fn f(ctx: *anyopaque) bool {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.isMasterMuted);
                return self.master_muted;
            }
        }.f,
        .isMasterSoloed = struct {
            fn f(ctx: *anyopaque) bool {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.isMasterSoloed);
                return self.master_soloed;
            }
        }.f,

        // Items
        .trackItemCount = struct {
            fn f(ctx: *anyopaque, track: *anyopaque) c_int {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.trackItemCount);
                const idx = decodeTrackPtr(track);
                if (idx >= MAX_TRACKS) return 0;
                return self.tracks[idx].item_count;
            }
        }.f,
        .getItemByIdx = struct {
            fn f(ctx: *anyopaque, track: *anyopaque, item_idx: c_int) ?*anyopaque {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getItemByIdx);
                const track_idx = decodeTrackPtr(track);
                if (track_idx >= MAX_TRACKS) return null;
                if (item_idx < 0 or item_idx >= self.tracks[track_idx].item_count) return null;
                return encodeItemPtr(track_idx, item_idx);
            }
        }.f,
        .getItemPosition = struct {
            fn f(ctx: *anyopaque, item: *anyopaque) f64 {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getItemPosition);
                const info = decodeItemPtr(item);
                if (info.track_idx >= MAX_TRACKS) return 0;
                if (info.item_idx >= MAX_ITEMS_PER_TRACK) return 0;
                return self.tracks[info.track_idx].items[info.item_idx].position;
            }
        }.f,
        .getItemLength = struct {
            fn f(ctx: *anyopaque, item: *anyopaque) f64 {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getItemLength);
                const info = decodeItemPtr(item);
                if (info.track_idx >= MAX_TRACKS) return 0;
                if (info.item_idx >= MAX_ITEMS_PER_TRACK) return 0;
                return self.tracks[info.track_idx].items[info.item_idx].length;
            }
        }.f,
        .getItemColor = struct {
            fn f(ctx: *anyopaque, item: *anyopaque) c_int {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getItemColor);
                const info = decodeItemPtr(item);
                if (info.track_idx >= MAX_TRACKS) return 0;
                if (info.item_idx >= MAX_ITEMS_PER_TRACK) return 0;
                return self.tracks[info.track_idx].items[info.item_idx].color;
            }
        }.f,
        .getItemLocked = struct {
            fn f(ctx: *anyopaque, item: *anyopaque) bool {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getItemLocked);
                const info = decodeItemPtr(item);
                if (info.track_idx >= MAX_TRACKS) return false;
                if (info.item_idx >= MAX_ITEMS_PER_TRACK) return false;
                return self.tracks[info.track_idx].items[info.item_idx].locked;
            }
        }.f,
        .getItemSelected = struct {
            fn f(ctx: *anyopaque, item: *anyopaque) bool {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getItemSelected);
                const info = decodeItemPtr(item);
                if (info.track_idx >= MAX_TRACKS) return false;
                if (info.item_idx >= MAX_ITEMS_PER_TRACK) return false;
                return self.tracks[info.track_idx].items[info.item_idx].selected;
            }
        }.f,
        .getItemActiveTakeIdx = struct {
            fn f(ctx: *anyopaque, item: *anyopaque) c_int {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getItemActiveTakeIdx);
                const info = decodeItemPtr(item);
                if (info.track_idx >= MAX_TRACKS) return 0;
                if (info.item_idx >= MAX_ITEMS_PER_TRACK) return 0;
                return self.tracks[info.track_idx].items[info.item_idx].active_take_idx;
            }
        }.f,
        .getItemNotes = struct {
            fn f(ctx: *anyopaque, item: *anyopaque, buf: []u8) []const u8 {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getItemNotes);
                const info = decodeItemPtr(item);
                if (info.track_idx >= MAX_TRACKS) return "";
                if (info.item_idx >= MAX_ITEMS_PER_TRACK) return "";
                const mock_item = &self.tracks[info.track_idx].items[info.item_idx];
                const len = @min(mock_item.notes_len, buf.len);
                @memcpy(buf[0..len], mock_item.notes[0..len]);
                return buf[0..len];
            }
        }.f,
        .getItemGUID = struct {
            fn f(ctx: *anyopaque, item: *anyopaque, buf: []u8) []const u8 {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getItemGUID);
                const info = decodeItemPtr(item);
                if (info.track_idx >= MAX_TRACKS) return "";
                if (info.item_idx >= MAX_ITEMS_PER_TRACK) return "";
                const mock_item = &self.tracks[info.track_idx].items[info.item_idx];
                const len = @min(mock_item.guid_len, buf.len);
                @memcpy(buf[0..len], mock_item.guid[0..len]);
                return buf[0..len];
            }
        }.f,

        // Takes
        .itemTakeCount = struct {
            fn f(ctx: *anyopaque, item: *anyopaque) c_int {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.itemTakeCount);
                const info = decodeItemPtr(item);
                if (info.track_idx >= MAX_TRACKS) return 0;
                if (info.item_idx >= MAX_ITEMS_PER_TRACK) return 0;
                return self.tracks[info.track_idx].items[info.item_idx].take_count;
            }
        }.f,
        .getTakeByIdx = struct {
            fn f(ctx: *anyopaque, item: *anyopaque, take_idx: c_int) ?*anyopaque {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getTakeByIdx);
                const info = decodeItemPtr(item);
                if (info.track_idx >= MAX_TRACKS) return null;
                if (info.item_idx >= MAX_ITEMS_PER_TRACK) return null;
                const mock_item = &self.tracks[info.track_idx].items[info.item_idx];
                if (take_idx < 0 or take_idx >= mock_item.take_count) return null;
                return encodeTakePtr(info.track_idx, info.item_idx, take_idx);
            }
        }.f,
        .getItemActiveTake = struct {
            fn f(ctx: *anyopaque, item: *anyopaque) ?*anyopaque {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getItemActiveTake);
                const info = decodeItemPtr(item);
                if (info.track_idx >= MAX_TRACKS) return null;
                if (info.item_idx >= MAX_ITEMS_PER_TRACK) return null;
                const mock_item = &self.tracks[info.track_idx].items[info.item_idx];
                if (mock_item.take_count == 0) return null;
                return encodeTakePtr(info.track_idx, info.item_idx, mock_item.active_take_idx);
            }
        }.f,
        .getTakeNameStr = struct {
            fn f(ctx: *anyopaque, take: *anyopaque) []const u8 {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getTakeNameStr);
                const info = decodeTakePtr(take);
                if (info.track_idx >= MAX_TRACKS) return "";
                if (info.item_idx >= MAX_ITEMS_PER_TRACK) return "";
                if (info.take_idx >= MAX_TAKES_PER_ITEM) return "";
                const mock_take = &self.tracks[info.track_idx].items[info.item_idx].takes[info.take_idx];
                return mock_take.name[0..mock_take.name_len];
            }
        }.f,
        .getTakeGUID = struct {
            fn f(ctx: *anyopaque, take: *anyopaque, buf: []u8) []const u8 {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getTakeGUID);
                const info = decodeTakePtr(take);
                if (info.track_idx >= MAX_TRACKS) return "";
                if (info.item_idx >= MAX_ITEMS_PER_TRACK) return "";
                if (info.take_idx >= MAX_TAKES_PER_ITEM) return "";
                const mock_take = &self.tracks[info.track_idx].items[info.item_idx].takes[info.take_idx];
                const len = @min(mock_take.guid_len, buf.len);
                @memcpy(buf[0..len], mock_take.guid[0..len]);
                return buf[0..len];
            }
        }.f,
        .getTakeStartOffset = struct {
            fn f(ctx: *anyopaque, take: *anyopaque) f64 {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getTakeStartOffset);
                const info = decodeTakePtr(take);
                if (info.track_idx >= MAX_TRACKS) return 0;
                if (info.item_idx >= MAX_ITEMS_PER_TRACK) return 0;
                if (info.take_idx >= MAX_TAKES_PER_ITEM) return 0;
                return self.tracks[info.track_idx].items[info.item_idx].takes[info.take_idx].start_offset;
            }
        }.f,
        .getTakePlayrate = struct {
            fn f(ctx: *anyopaque, take: *anyopaque) f64 {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getTakePlayrate);
                const info = decodeTakePtr(take);
                if (info.track_idx >= MAX_TRACKS) return 1.0;
                if (info.item_idx >= MAX_ITEMS_PER_TRACK) return 1.0;
                if (info.take_idx >= MAX_TAKES_PER_ITEM) return 1.0;
                return self.tracks[info.track_idx].items[info.item_idx].takes[info.take_idx].playrate;
            }
        }.f,
        .isTakeMIDI = struct {
            fn f(ctx: *anyopaque, take: *anyopaque) bool {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.isTakeMIDI);
                const info = decodeTakePtr(take);
                if (info.track_idx >= MAX_TRACKS) return false;
                if (info.item_idx >= MAX_ITEMS_PER_TRACK) return false;
                if (info.take_idx >= MAX_TAKES_PER_ITEM) return false;
                return self.tracks[info.track_idx].items[info.item_idx].takes[info.take_idx].is_midi;
            }
        }.f,
        .getTakeSource = struct {
            fn f(ctx: *anyopaque, take: *anyopaque) ?*anyopaque {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getTakeSource);
                // Return the take pointer as source (simplified mock)
                return take;
            }
        }.f,
        .getMediaSourceChannels = struct {
            fn f(ctx: *anyopaque, source: *anyopaque) c_int {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getMediaSourceChannels);
                // Source is same as take in our mock
                const info = decodeTakePtr(source);
                if (info.track_idx >= MAX_TRACKS) return 0;
                if (info.item_idx >= MAX_ITEMS_PER_TRACK) return 0;
                if (info.take_idx >= MAX_TAKES_PER_ITEM) return 0;
                return self.tracks[info.track_idx].items[info.item_idx].takes[info.take_idx].channel_count;
            }
        }.f,

        // Markers
        .markerCount = struct {
            fn f(ctx: *anyopaque) MarkerCount {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.markerCount);
                return .{
                    .total = self.marker_count + self.region_count,
                    .markers = self.marker_count,
                    .regions = self.region_count,
                };
            }
        }.f,
        .enumMarker = struct {
            fn f(ctx: *anyopaque, idx: c_int) ?MarkerInfo {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.enumMarker);
                const total = self.marker_count + self.region_count;
                if (idx < 0 or idx >= total) return null;
                return self.markers[@intCast(idx)];
            }
        }.f,

        // Metering
        .getTrackPeakInfo = struct {
            fn f(ctx: *anyopaque, track: *anyopaque, channel: c_int) f64 {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getTrackPeakInfo);
                const idx = decodeTrackPtr(track);
                if (idx >= MAX_TRACKS) return 0.0;
                if (channel == 0) return self.tracks[idx].peak_left;
                return self.tracks[idx].peak_right;
            }
        }.f,

        // ExtState
        .getExtStateValue = struct {
            fn f(ctx: *anyopaque, section: [*:0]const u8, key: [*:0]const u8) ?[]const u8 {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getExtStateValue);
                const section_slice = std.mem.sliceTo(section, 0);
                const key_slice = std.mem.sliceTo(key, 0);
                for (self.ext_states[0..self.ext_state_count]) |entry| {
                    if (std.mem.eql(u8, entry.section[0..entry.section_len], section_slice) and
                        std.mem.eql(u8, entry.key[0..entry.key_len], key_slice))
                    {
                        return entry.value[0..entry.value_len];
                    }
                }
                return null;
            }
        }.f,
        .getProjExtStateValue = struct {
            fn f(ctx: *anyopaque, extname: [*:0]const u8, key: [*:0]const u8, buf: []u8) ?[]const u8 {
                const self: *MockApi = @ptrCast(@alignCast(ctx));
                self.recordCall(.getProjExtStateValue);
                // Same as getExtStateValue for mock
                const section_slice = std.mem.sliceTo(extname, 0);
                const key_slice = std.mem.sliceTo(key, 0);
                for (self.ext_states[0..self.ext_state_count]) |entry| {
                    if (std.mem.eql(u8, entry.section[0..entry.section_len], section_slice) and
                        std.mem.eql(u8, entry.key[0..entry.key_len], key_slice))
                    {
                        const len = @min(entry.value_len, buf.len);
                        @memcpy(buf[0..len], entry.value[0..len]);
                        return buf[0..len];
                    }
                }
                return null;
            }
        }.f,
    };
};

// =============================================================================
// Tests
// =============================================================================

test "MockApi returns configured values" {
    var mock = MockApi{
        .play_state = 1,
        .play_position = 5.5,
        .bpm = 140.0,
    };
    const api = mock.interface();

    try std.testing.expectEqual(@as(c_int, 1), api.playState());
    try std.testing.expectEqual(@as(f64, 5.5), api.playPosition());
}

test "MockApi injects NaN for position" {
    var mock = MockApi{
        .inject_nan_position = true,
    };
    const api = mock.interface();

    try std.testing.expect(std.math.isNan(api.playPosition()));
}

test "MockApi tracks call counts" {
    var mock = MockApi{};
    const api = mock.interface();

    _ = api.playState();
    _ = api.playState();
    _ = api.playPosition();

    try std.testing.expectEqual(@as(usize, 2), mock.getCallCount(.playState));
    try std.testing.expectEqual(@as(usize, 1), mock.getCallCount(.playPosition));
}

test "MockApi injects solo error" {
    var mock = MockApi{
        .inject_solo_error = true,
        .track_count = 1,
    };
    const api = mock.interface();
    const track = api.getTrackByUnifiedIdx(0).?;

    const result = api.getTrackSolo(track);
    try std.testing.expectError(ffi.FFIError.FloatIsNaN, result);
}

test "MockApi index-as-pointer pattern for tracks" {
    var mock = MockApi{
        .track_count = 2,
    };
    mock.tracks[0].solo = 1;
    mock.tracks[1].solo = 2;
    const api = mock.interface();

    // Get track handles (encoded indices)
    const track0 = api.getTrackByUnifiedIdx(0).?;
    const track1 = api.getTrackByUnifiedIdx(1).?;

    // Verify they decode correctly
    try std.testing.expectEqual(@as(c_int, 1), try api.getTrackSolo(track0));
    try std.testing.expectEqual(@as(c_int, 2), try api.getTrackSolo(track1));
}

test "MockApi time conversion" {
    var mock = MockApi{
        .bpm = 120.0, // 2 beats per second
        .timesig_num = 4,
        .timesig_denom = 4,
    };
    const api = mock.interface();

    // At 120 BPM, 2 seconds = 4 beats = 1 bar
    const beats = api.timeToBeats(2.0);
    try std.testing.expectEqual(@as(f64, 4.0), beats.beats);
    try std.testing.expectEqual(@as(c_int, 2), beats.measures); // Bar 2 (1-based)

    // And back to time
    const time = api.beatsToTime(4.0);
    try std.testing.expectEqual(@as(f64, 2.0), time);
}

test "MockApi track name" {
    var mock = MockApi{
        .track_count = 1,
    };
    mock.tracks[0].setName("My Track");
    const api = mock.interface();

    const track = api.getTrackByUnifiedIdx(0).?;
    var buf: [128]u8 = undefined;
    const name = api.getTrackNameStr(track, &buf);

    try std.testing.expectEqualStrings("My Track", name);
}

test "MockApi items and takes" {
    var mock = MockApi{
        .track_count = 1,
    };
    mock.tracks[0].item_count = 1;
    mock.tracks[0].items[0].position = 1.5;
    mock.tracks[0].items[0].length = 2.0;
    mock.tracks[0].items[0].take_count = 1;
    mock.tracks[0].items[0].takes[0].setName("Take 1");

    const api = mock.interface();
    const track = api.getTrackByUnifiedIdx(0).?;
    const item = api.getItemByIdx(track, 0).?;

    try std.testing.expectEqual(@as(f64, 1.5), api.getItemPosition(item));
    try std.testing.expectEqual(@as(f64, 2.0), api.getItemLength(item));

    const take = api.getTakeByIdx(item, 0).?;
    try std.testing.expectEqualStrings("Take 1", api.getTakeNameStr(take));
}
