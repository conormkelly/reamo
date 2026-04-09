/// RealBackend - Production implementation wrapping raw REAPER API.
///
/// This is a thin delegation layer. Each method just calls the corresponding
/// raw.Api method. No logic here - that's in raw.zig.
///
/// Usage:
///   var backend = RealBackend{ .inner = &raw_api };
///   const state = transport.poll(&backend);
const std = @import("std");
const raw = @import("raw.zig");
const types = @import("types.zig");
const ffi = @import("../core/ffi.zig");
const backend = @import("backend.zig");

pub const RealBackend = struct {
    inner: *const raw.Api,

    // =========================================================================
    // Transport
    // =========================================================================

    pub fn playState(self: *const RealBackend) c_int {
        return self.inner.playState();
    }

    pub fn playPosition(self: *const RealBackend) f64 {
        return self.inner.playPosition();
    }

    pub fn cursorPosition(self: *const RealBackend) f64 {
        return self.inner.cursorPosition();
    }

    pub fn timePrecise(self: *const RealBackend) f64 {
        return self.inner.timePrecise();
    }

    pub fn timePreciseMs(self: *const RealBackend) f64 {
        return self.inner.timePreciseMs();
    }

    pub fn runCommand(self: *const RealBackend, cmd: c_int) void {
        self.inner.runCommand(cmd);
    }

    pub fn setCursorPos(self: *const RealBackend, pos: f64) void {
        self.inner.setCursorPos(pos);
    }

    // =========================================================================
    // Time conversion
    // =========================================================================

    pub fn timeToBeats(self: *const RealBackend, time: f64) types.BeatsInfo {
        return self.inner.timeToBeats(time);
    }

    pub fn beatsToTime(self: *const RealBackend, beats: f64) f64 {
        return self.inner.beatsToTime(beats);
    }

    pub fn barBeatToTime(self: *const RealBackend, bar: c_int, beat: f64) f64 {
        return self.inner.barBeatToTime(bar, beat);
    }

    // =========================================================================
    // Tempo / Time signature
    // =========================================================================

    pub fn timeSignature(self: *const RealBackend) types.TimeSignature {
        return self.inner.timeSignature();
    }

    pub fn getTempoAtPosition(self: *const RealBackend, time: f64) types.TempoAtPosition {
        return self.inner.getTempoAtPosition(time);
    }

    pub fn tempoMarkerCount(self: *const RealBackend) c_int {
        return self.inner.tempoMarkerCount();
    }

    pub fn getTempoMarker(self: *const RealBackend, idx: c_int) ?types.TempoMarker {
        return self.inner.getTempoMarker(idx);
    }

    pub fn getBarOffset(self: *const RealBackend) c_int {
        return self.inner.getBarOffset();
    }

    pub fn getTimeSignatureNumerator(self: *const RealBackend) c_int {
        return self.inner.getTimeSignatureNumerator();
    }

    pub fn getTimeSignatureDenominator(self: *const RealBackend) c_int {
        return self.inner.getTimeSignatureDenominator();
    }

    pub fn setTempo(self: *const RealBackend, bpm: f64) void {
        self.inner.setTempo(bpm);
    }

    pub fn setTimeSignature(self: *const RealBackend, num: c_int, denom: c_int) bool {
        return self.inner.setTimeSignature(num, denom);
    }

    // =========================================================================
    // Time selection
    // =========================================================================

    pub fn timeSelection(self: *const RealBackend) types.TimeSelection {
        return self.inner.timeSelection();
    }

    pub fn setTimeSelection(self: *const RealBackend, start: f64, end: f64) void {
        self.inner.setTimeSelection(start, end);
    }

    pub fn clearTimeSelection(self: *const RealBackend) void {
        self.inner.clearTimeSelection();
    }

    // =========================================================================
    // Loop points (for native looping with repeat mode)
    // =========================================================================

    pub fn getLoopPoints(self: *const RealBackend) types.TimeSelection {
        return self.inner.getLoopPoints();
    }

    pub fn setLoopPoints(self: *const RealBackend, start: f64, end: f64) void {
        self.inner.setLoopPoints(start, end);
    }

    pub fn clearLoopPoints(self: *const RealBackend) void {
        self.inner.clearLoopPoints();
    }

    // =========================================================================
    // Repeat
    // =========================================================================

    pub fn getRepeat(self: *const RealBackend) bool {
        return self.inner.getRepeat();
    }

    pub fn setRepeat(self: *const RealBackend, enabled: bool) void {
        self.inner.setRepeat(enabled);
    }

    // =========================================================================
    // Smooth seek config
    // =========================================================================

    pub fn getSmoothSeekEnabled(self: *const RealBackend) bool {
        return self.inner.getSmoothSeekEnabled();
    }

    pub fn setSmoothSeekEnabled(self: *const RealBackend, enabled: bool) void {
        self.inner.setSmoothSeekEnabled(enabled);
    }

    pub fn getSmoothSeekMeasures(self: *const RealBackend) c_int {
        return self.inner.getSmoothSeekMeasures();
    }

    pub fn setSmoothSeekMeasures(self: *const RealBackend, measures: c_int) void {
        self.inner.setSmoothSeekMeasures(measures);
    }

    pub fn getSeekMode(self: *const RealBackend) c_int {
        return self.inner.getSeekMode();
    }

    pub fn setSeekMode(self: *const RealBackend, mode: c_int) void {
        self.inner.setSeekMode(mode);
    }

    // =========================================================================
    // Project info
    // =========================================================================

    pub fn projectLength(self: *const RealBackend) f64 {
        return self.inner.projectLength();
    }

    /// Get effective audio engine sample rate using canonical Cockos fallback:
    /// 1. If PROJECT_SRATE_USE > 0, return PROJECT_SRATE (project enforces its own rate)
    /// 2. Otherwise, query GetAudioDeviceInfo("SRATE") for the device's actual rate
    /// 3. Returns 0 if both APIs unavailable (caller should use a sensible default)
    pub fn getSampleRate(self: *const RealBackend) u32 {
        const use_flag = self.inner.getProjectInfoValue("PROJECT_SRATE_USE");
        if (use_flag > 0.0) {
            const srate = self.inner.getProjectInfoValue("PROJECT_SRATE");
            if (srate > 0.0) {
                return ffi.safeFloatToInt(u32, srate) catch 0;
            }
        }

        // Fall back to audio device info (returns integer string like "48000")
        var buf: [64]u8 = undefined;
        if (self.inner.audioDeviceInfo("SRATE", &buf, 64)) {
            // Parse integer string — find first non-digit to determine length
            var len: usize = 0;
            while (len < 64 and buf[len] >= '0' and buf[len] <= '9') : (len += 1) {}
            if (len > 0) {
                return std.fmt.parseInt(u32, buf[0..len], 10) catch return 0;
            }
        }

        return 0;
    }

    pub fn projectStateChangeCount(self: *const RealBackend) c_int {
        return self.inner.projectStateChangeCount();
    }

    pub fn isDirty(self: *const RealBackend) bool {
        return self.inner.isDirty();
    }

    pub fn markDirty(self: *const RealBackend) void {
        self.inner.markDirty();
    }

    pub fn getFrameRate(self: *const RealBackend) types.FrameRateInfo {
        return self.inner.getFrameRate();
    }

    /// Get current project info (pointer + full path).
    /// Note: project pointer identifies the TAB, not the file!
    pub fn enumCurrentProject(self: *const RealBackend, path_buf: []u8) ?raw.Api.ProjectInfo {
        return self.inner.enumCurrentProject(path_buf);
    }

    /// Get project name (filename only, e.g. "MySong.rpp").
    pub fn getProjectName(self: *const RealBackend, project: ?*anyopaque, name_buf: []u8) []const u8 {
        return self.inner.getProjectName(project, name_buf);
    }

    // =========================================================================
    // Command state
    // =========================================================================

    pub fn getCommandState(self: *const RealBackend, cmd: c_int) c_int {
        return self.inner.getCommandState(cmd);
    }

    pub fn getCommandStateEx(self: *const RealBackend, section_id: c_int, cmd: c_int) c_int {
        return self.inner.getCommandStateEx(section_id, cmd);
    }

    pub fn getSectionFromUniqueID(self: *const RealBackend, unique_id: c_int) ?*anyopaque {
        return self.inner.getSectionFromUniqueID(unique_id);
    }

    pub fn enumerateActions(self: *const RealBackend, section: ?*anyopaque, idx: c_int, name_out: *[*:0]const u8) c_int {
        return self.inner.enumerateActions(section, idx, name_out);
    }

    pub fn reverseNamedCommandLookup(self: *const RealBackend, cmd_id: c_int) ?[]const u8 {
        return self.inner.reverseNamedCommandLookup(cmd_id);
    }

    // =========================================================================
    // MIDI Editor (for section-specific action execution)
    // =========================================================================

    /// Get the active MIDI editor window, or null if none is open
    pub fn midiEditorGetActive(self: *const RealBackend) ?*anyopaque {
        return self.inner.midiEditorGetActive();
    }

    /// Execute a command in the MIDI editor. Returns true if successful.
    pub fn midiEditorOnCommand(self: *const RealBackend, hwnd: ?*anyopaque, command_id: c_int) bool {
        return self.inner.midiEditorOnCommand(hwnd, command_id);
    }

    pub fn isMetronomeEnabled(self: *const RealBackend) bool {
        return self.inner.isMetronomeEnabled();
    }

    pub fn getMetronomeVolume(self: *const RealBackend) f64 {
        return self.inner.getMetronomeVolume();
    }

    pub fn setMetronomeVolume(self: *const RealBackend, vol: f64) bool {
        return self.inner.setMetronomeVolume(vol);
    }

    pub fn getCountInPlayback(self: *const RealBackend) bool {
        return self.inner.getCountInPlayback();
    }

    pub fn getCountInRecord(self: *const RealBackend) bool {
        return self.inner.getCountInRecord();
    }

    pub fn toggleCountInPlayback(self: *const RealBackend) void {
        self.inner.toggleCountInPlayback();
    }

    pub fn toggleCountInRecord(self: *const RealBackend) void {
        self.inner.toggleCountInRecord();
    }

    pub fn isPreRollPlay(self: *const RealBackend) bool {
        return self.inner.isPreRollPlay();
    }

    pub fn isPreRollRecord(self: *const RealBackend) bool {
        return self.inner.isPreRollRecord();
    }

    // =========================================================================
    // Undo/Redo
    // =========================================================================

    pub fn canUndo(self: *const RealBackend) ?[]const u8 {
        return self.inner.canUndo();
    }

    pub fn canRedo(self: *const RealBackend) ?[]const u8 {
        return self.inner.canRedo();
    }

    pub fn doUndo(self: *const RealBackend) bool {
        return self.inner.doUndo();
    }

    pub fn doRedo(self: *const RealBackend) bool {
        return self.inner.doRedo();
    }

    pub fn undoBeginBlock(self: *const RealBackend) void {
        self.inner.undoBeginBlock();
    }

    pub fn undoEndBlock(self: *const RealBackend, description: [*:0]const u8) void {
        self.inner.undoEndBlock(description);
    }

    pub fn undoAddPoint(self: *const RealBackend, description: [*:0]const u8) void {
        self.inner.undoAddPoint(description);
    }

    // =========================================================================
    // Tracks
    // =========================================================================

    pub fn trackCount(self: *const RealBackend) c_int {
        return self.inner.trackCount();
    }

    pub fn getTrackByIdx(self: *const RealBackend, idx: c_int) ?*anyopaque {
        return self.inner.getTrackByIdx(idx);
    }

    pub fn getTrackByUnifiedIdx(self: *const RealBackend, idx: c_int) ?*anyopaque {
        return self.inner.getTrackByUnifiedIdx(idx);
    }

    pub fn masterTrack(self: *const RealBackend) ?*anyopaque {
        return self.inner.masterTrack();
    }

    pub fn getTrackNameStr(self: *const RealBackend, track: *anyopaque, buf: []u8) []const u8 {
        return self.inner.getTrackNameStr(track, buf);
    }

    pub fn getTrackVolume(self: *const RealBackend, track: *anyopaque) f64 {
        return self.inner.getTrackVolume(track);
    }

    pub fn getTrackPan(self: *const RealBackend, track: *anyopaque) f64 {
        return self.inner.getTrackPan(track);
    }

    pub fn getTrackMute(self: *const RealBackend, track: *anyopaque) bool {
        return self.inner.getTrackMute(track);
    }

    pub fn getTrackSolo(self: *const RealBackend, track: *anyopaque) ffi.FFIError!c_int {
        return ffi.safeFloatToInt(c_int, self.inner.getTrackSolo(track));
    }

    pub fn getTrackRecArm(self: *const RealBackend, track: *anyopaque) bool {
        return self.inner.getTrackRecArm(track);
    }

    pub fn getTrackRecMon(self: *const RealBackend, track: *anyopaque) ffi.FFIError!c_int {
        return ffi.safeFloatToInt(c_int, self.inner.getTrackRecMon(track));
    }

    pub fn getTrackFxEnabled(self: *const RealBackend, track: *anyopaque) bool {
        return self.inner.getTrackFxEnabled(track);
    }

    pub fn getTrackSelected(self: *const RealBackend, track: *anyopaque) bool {
        return self.inner.getTrackSelected(track);
    }

    pub fn getTrackColor(self: *const RealBackend, track: *anyopaque) ffi.FFIError!c_int {
        const color_val = try ffi.safeFloatToInt(c_int, self.inner.getTrackColor(track));
        // REAPER uses bit 24 (0x01000000) as an "enabled" flag - if not set, track uses theme default
        const CUSTOM_COLOR_FLAG: c_int = 0x01000000;
        if ((color_val & CUSTOM_COLOR_FLAG) == 0) {
            return 0; // No custom color - uses theme default
        }
        return color_val;
    }

    /// Set track color. Pass 0 to reset to theme default.
    pub fn setTrackColor(self: *const RealBackend, track: *anyopaque, color: c_int) void {
        if (color == 0) {
            // Reset to theme default
            _ = self.inner.resetTrackColor(track);
        } else {
            // SetTrackColor API handles OS color format internally
            self.inner.setTrackColorRaw(track, color);
        }
    }

    pub fn isMasterMuted(self: *const RealBackend) bool {
        return self.inner.isMasterMuted();
    }

    pub fn isMasterSoloed(self: *const RealBackend) bool {
        return self.inner.isMasterSoloed();
    }

    // Track setters
    pub fn setTrackVolume(self: *const RealBackend, track: *anyopaque, vol: f64) bool {
        return self.inner.setTrackVolume(track, vol);
    }

    pub fn setTrackPan(self: *const RealBackend, track: *anyopaque, pan: f64) bool {
        return self.inner.setTrackPan(track, pan);
    }

    pub fn setTrackMute(self: *const RealBackend, track: *anyopaque, mute: bool) bool {
        return self.inner.setTrackMute(track, mute);
    }

    pub fn setTrackSolo(self: *const RealBackend, track: *anyopaque, solo: c_int) bool {
        return self.inner.setTrackSolo(track, solo);
    }

    pub fn setTrackRecArm(self: *const RealBackend, track: *anyopaque, arm: bool) bool {
        return self.inner.setTrackRecArm(track, arm);
    }

    pub fn setTrackRecMon(self: *const RealBackend, track: *anyopaque, mon: c_int) bool {
        return self.inner.setTrackRecMon(track, mon);
    }

    pub fn setTrackFxEnabled(self: *const RealBackend, track: *anyopaque, enabled: bool) bool {
        return self.inner.setTrackFxEnabled(track, enabled);
    }

    pub fn setTrackSelected(self: *const RealBackend, track: *anyopaque, selected: bool) bool {
        return self.inner.setTrackSelected(track, selected);
    }

    pub fn getSelectedTrackByIdx(self: *const RealBackend, sel_idx: c_int) ?*anyopaque {
        return self.inner.getSelectedTrackByIdx(sel_idx);
    }

    pub fn setTrackName(self: *const RealBackend, track: *anyopaque, name: []const u8) bool {
        return self.inner.setTrackName(track, name);
    }

    pub fn insertTrack(self: *const RealBackend, idx: c_int, want_defaults: bool) void {
        self.inner.insertTrack(idx, want_defaults);
    }

    pub fn deleteTrackPtr(self: *const RealBackend, track: *anyopaque) void {
        self.inner.deleteTrackPtr(track);
    }

    pub fn getTrackFolderDepth(self: *const RealBackend, track: *anyopaque) ffi.FFIError!c_int {
        return ffi.safeFloatToInt(c_int, self.inner.getTrackFolderDepth(track));
    }

    /// Format track GUID as string into provided buffer.
    /// Returns slice of the GUID string (38 chars), or empty string on failure.
    /// Note: Master track GUID is unreliable in REAPER - use "master" literal instead.
    pub fn formatTrackGuid(self: *const RealBackend, track: *anyopaque, buf: []u8) []const u8 {
        const getGuid = self.inner.getTrackGUID orelse return "";
        const toString = self.inner.guidToString_fn orelse return "";
        if (buf.len < 64) return ""; // guidToString needs 64 bytes

        const guid_ptr = getGuid(track) orelse return "";
        toString(guid_ptr, buf.ptr);

        // Find null terminator (GUID is 38 chars: {XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX})
        for (buf, 0..) |c, i| {
            if (c == 0) return buf[0..i];
        }
        return buf[0..@min(38, buf.len)];
    }

    /// Get unified track index from track pointer (reverse lookup).
    /// Returns unified index: 0=master, 1+=user tracks.
    /// Returns -1 if track not found.
    pub fn getTrackIdx(self: *const RealBackend, track: *anyopaque) c_int {
        // Check if master track
        if (self.masterTrack()) |master| {
            if (track == master) return 0;
        }

        // Search user tracks
        const count = self.trackCount();
        var idx: c_int = 0;
        while (idx < count) : (idx += 1) {
            if (self.getTrackByIdx(idx)) |t| {
                if (t == track) return idx + 1; // +1 for unified indexing
            }
        }

        return -1; // Not found
    }

    // CSurf methods for undo-coalesced changes
    pub fn csurfSetVolume(self: *const RealBackend, track: *anyopaque, vol: f64, allowGang: bool) f64 {
        return self.inner.csurfSetVolume(track, vol, allowGang);
    }

    pub fn csurfSetPan(self: *const RealBackend, track: *anyopaque, pan: f64, allowGang: bool) f64 {
        return self.inner.csurfSetPan(track, pan, allowGang);
    }

    pub fn csurfSetMute(self: *const RealBackend, track: *anyopaque, mute: bool, allowGang: bool) bool {
        return self.inner.csurfSetMute(track, mute, allowGang);
    }

    pub fn csurfSetSolo(self: *const RealBackend, track: *anyopaque, solo: c_int, allowGang: bool) bool {
        return self.inner.csurfSetSolo(track, solo, allowGang);
    }

    pub fn csurfSetRecArm(self: *const RealBackend, track: *anyopaque, arm: bool, allowGang: bool) bool {
        return self.inner.csurfSetRecArm(track, arm, allowGang);
    }

    pub fn csurfSetRecMon(self: *const RealBackend, track: *anyopaque, mon: c_int, allowGang: bool) c_int {
        return self.inner.csurfSetRecMon(track, mon, allowGang);
    }

    pub fn csurfFlushUndo(self: *const RealBackend, force: bool) void {
        self.inner.csurfFlushUndo(force);
    }

    // =========================================================================
    // Pointer Validation
    // =========================================================================

    /// Validate a track pointer using REAPER's ValidatePtr2.
    /// Returns true if the track still exists in the current project.
    pub fn validateTrackPtr(self: *const RealBackend, track: ?*anyopaque) bool {
        return self.inner.validateTrackPtr(track);
    }

    /// Validate an item pointer using REAPER's ValidatePtr2.
    /// Returns true if the item still exists in the current project.
    pub fn validateItemPtr(self: *const RealBackend, item: ?*anyopaque) bool {
        return self.inner.validateItemPtr(item);
    }

    /// Validate a take pointer using REAPER's ValidatePtr2.
    /// Returns true if the take still exists in the current project.
    pub fn validateTakePtr(self: *const RealBackend, take: ?*anyopaque) bool {
        return self.inner.validateTakePtr(take);
    }

    // =========================================================================
    // Track FX
    // =========================================================================

    pub fn trackFxCount(self: *const RealBackend, track: *anyopaque) c_int {
        return self.inner.trackFxCount(track);
    }

    pub fn trackFxRecCount(self: *const RealBackend, track: *anyopaque) c_int {
        return self.inner.trackFxRecCount(track);
    }

    pub fn trackFxGetName(self: *const RealBackend, track: *anyopaque, fx_idx: c_int, buf: []u8) []const u8 {
        return self.inner.trackFxGetName(track, fx_idx, buf);
    }

    pub fn trackFxGetPresetIndex(self: *const RealBackend, track: *anyopaque, fx_idx: c_int, preset_count: *c_int) c_int {
        return self.inner.trackFxGetPresetIndex(track, fx_idx, preset_count);
    }

    pub fn trackFxGetPreset(self: *const RealBackend, track: *anyopaque, fx_idx: c_int, buf: []u8) types.FxPresetInfo {
        return self.inner.trackFxGetPreset(track, fx_idx, buf);
    }

    pub fn trackFxNavigatePresets(self: *const RealBackend, track: *anyopaque, fx_idx: c_int, presetmove: c_int) bool {
        return self.inner.trackFxNavigatePresets(track, fx_idx, presetmove);
    }

    pub fn trackFxSetPresetByIndex(self: *const RealBackend, track: *anyopaque, fx_idx: c_int, preset_idx: c_int) bool {
        return self.inner.trackFxSetPresetByIndex(track, fx_idx, preset_idx);
    }

    pub fn trackFxGetEnabled(self: *const RealBackend, track: *anyopaque, fx_idx: c_int) bool {
        return self.inner.trackFxGetEnabled(track, fx_idx);
    }

    pub fn trackFxSetEnabled(self: *const RealBackend, track: *anyopaque, fx_idx: c_int, enabled: bool) void {
        self.inner.trackFxSetEnabled(track, fx_idx, enabled);
    }

    /// Add an FX to a track by name.
    /// name: FX name or filename. Prefix with "JS:" for JS effects, "VST:" for VST, etc.
    /// recFX: true for recording FX chain, false for normal FX chain
    /// position: -1 to add at end, or index to insert before
    /// Returns: FX index on success, -1 on failure
    pub fn trackFxAddByName(self: *const RealBackend, track: *anyopaque, name: [*:0]const u8, recFX: bool, position: c_int) c_int {
        const func = self.inner.trackFX_AddByName orelse return -1;
        return func(track, name, recFX, position);
    }

    /// Delete an FX from a track.
    /// Returns true on success.
    pub fn trackFxDelete(self: *const RealBackend, track: *anyopaque, fx_idx: c_int) bool {
        const func = self.inner.trackFX_Delete orelse return false;
        return func(track, fx_idx);
    }

    /// Copy or move FX to another position (or another track).
    /// For reordering within same track: src_track == dest_track, is_move = true
    /// dest_fx: destination index (-1 = end of chain)
    pub fn trackFxCopyToTrack(self: *const RealBackend, src_track: *anyopaque, src_fx: c_int, dest_track: *anyopaque, dest_fx: c_int, is_move: bool) void {
        const func = self.inner.trackFX_CopyToTrack orelse return;
        func(src_track, src_fx, dest_track, dest_fx, is_move);
    }

    /// Get FX GUID as string into provided buffer.
    /// Returns slice of the GUID string (38 chars), or empty string on failure.
    pub fn trackFxGetGuid(self: *const RealBackend, track: *anyopaque, fx_idx: c_int, buf: []u8) []const u8 {
        const getGuid = self.inner.trackFX_GetFXGUID orelse return "";
        const toString = self.inner.guidToString_fn orelse return "";
        if (buf.len < 64) return ""; // guidToString needs 64 bytes

        const guid_ptr = getGuid(track, fx_idx) orelse return "";
        toString(guid_ptr, buf.ptr);

        // Find null terminator (GUID is 38 chars: {XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX})
        for (buf, 0..) |c, i| {
            if (c == 0) return buf[0..i];
        }
        return buf[0..@min(38, buf.len)];
    }

    // FX Parameter methods

    /// Get number of parameters for an FX
    pub fn trackFxGetNumParams(self: *const RealBackend, track: *anyopaque, fx_idx: c_int) c_int {
        return self.inner.trackFxGetNumParams(track, fx_idx);
    }

    /// Get parameter name. Returns empty string on failure.
    pub fn trackFxGetParamName(self: *const RealBackend, track: *anyopaque, fx_idx: c_int, param_idx: c_int, buf: []u8) []const u8 {
        return self.inner.trackFxGetParamName(track, fx_idx, param_idx, buf);
    }

    /// Get normalized parameter value (0.0 to 1.0). Returns 0.0 on failure or invalid index.
    pub fn trackFxGetParamNormalized(self: *const RealBackend, track: *anyopaque, fx_idx: c_int, param_idx: c_int) f64 {
        return self.inner.trackFxGetParamNormalized(track, fx_idx, param_idx);
    }

    /// Get actual parameter value (not normalized). Returns 0.0 on failure.
    pub fn trackFxGetParam(self: *const RealBackend, track: *anyopaque, fx_idx: c_int, param_idx: c_int) f64 {
        return self.inner.trackFxGetParam(track, fx_idx, param_idx);
    }

    /// Set normalized parameter value. Returns false on failure.
    pub fn trackFxSetParamNormalized(self: *const RealBackend, track: *anyopaque, fx_idx: c_int, param_idx: c_int, value: f64) bool {
        return self.inner.trackFxSetParamNormalized(track, fx_idx, param_idx, value);
    }

    /// Get formatted parameter value string (e.g., "-6.0 dB", "250 Hz"). Returns empty string on failure.
    pub fn trackFxGetFormattedParamValue(self: *const RealBackend, track: *anyopaque, fx_idx: c_int, param_idx: c_int, buf: []u8) []const u8 {
        return self.inner.trackFxGetFormattedParamValue(track, fx_idx, param_idx, buf);
    }

    /// Enumerate installed FX plugins (global, not per-track).
    /// index: 0-based, increment until returns false.
    /// name_out: receives plugin display name.
    /// ident_out: receives identifier for TrackFX_AddByName.
    /// Returns: true if valid, false when enumeration complete.
    pub fn enumInstalledFX(self: *const RealBackend, index: c_int, name_out: *[*:0]const u8, ident_out: *[*:0]const u8) bool {
        const f = self.inner.enumInstalledFX orelse return false;
        return f(index, name_out, ident_out);
    }

    // =========================================================================
    // Track Sends
    // =========================================================================

    pub fn trackSendCount(self: *const RealBackend, track: *anyopaque) c_int {
        return self.inner.trackSendCount(track);
    }

    pub fn trackReceiveCount(self: *const RealBackend, track: *anyopaque) c_int {
        return self.inner.trackReceiveCount(track);
    }

    pub fn trackReceiveGetVolume(self: *const RealBackend, track: *anyopaque, recv_idx: c_int) f64 {
        return self.inner.trackReceiveGetVolume(track, recv_idx);
    }

    pub fn trackReceiveGetMute(self: *const RealBackend, track: *anyopaque, recv_idx: c_int) bool {
        return self.inner.trackReceiveGetMute(track, recv_idx);
    }

    pub fn trackReceiveGetMode(self: *const RealBackend, track: *anyopaque, recv_idx: c_int) ffi.FFIError!c_int {
        return ffi.safeFloatToInt(c_int, self.inner.trackReceiveGetModeRaw(track, recv_idx));
    }

    pub fn trackReceiveGetPan(self: *const RealBackend, track: *anyopaque, recv_idx: c_int) f64 {
        return self.inner.trackReceiveGetPan(track, recv_idx);
    }

    pub fn trackReceiveGetSrcTrack(self: *const RealBackend, track: *anyopaque, recv_idx: c_int) ?*anyopaque {
        return self.inner.trackReceiveGetSrcTrack(track, recv_idx);
    }

    pub fn trackReceiveGetSrcName(self: *const RealBackend, track: *anyopaque, recv_idx: c_int, buf: []u8) []const u8 {
        return self.inner.trackReceiveGetSrcName(track, recv_idx, buf);
    }

    pub fn trackReceiveSetVolume(self: *const RealBackend, track: *anyopaque, recv_idx: c_int, volume: f64) f64 {
        return self.inner.trackReceiveSetVolume(track, recv_idx, volume);
    }

    pub fn trackReceiveSetMute(self: *const RealBackend, track: *anyopaque, recv_idx: c_int, muted: bool) bool {
        return self.inner.trackReceiveSetMute(track, recv_idx, muted);
    }

    pub fn trackReceiveSetPan(self: *const RealBackend, track: *anyopaque, recv_idx: c_int, pan: f64) f64 {
        return self.inner.trackReceiveSetPan(track, recv_idx, pan);
    }

    pub fn trackReceiveSetMode(self: *const RealBackend, track: *anyopaque, recv_idx: c_int, mode: c_int) bool {
        return self.inner.trackReceiveSetMode(track, recv_idx, mode);
    }

    pub fn trackSendGetVolume(self: *const RealBackend, track: *anyopaque, send_idx: c_int) f64 {
        return self.inner.trackSendGetVolume(track, send_idx);
    }

    pub fn trackSendGetMute(self: *const RealBackend, track: *anyopaque, send_idx: c_int) bool {
        return self.inner.trackSendGetMute(track, send_idx);
    }

    pub fn trackSendGetMode(self: *const RealBackend, track: *anyopaque, send_idx: c_int) ffi.FFIError!c_int {
        return ffi.safeFloatToInt(c_int, self.inner.trackSendGetModeRaw(track, send_idx));
    }

    pub fn trackSendGetDestTrack(self: *const RealBackend, track: *anyopaque, send_idx: c_int) ?*anyopaque {
        return self.inner.trackSendGetDestTrack(track, send_idx);
    }

    pub fn trackSendGetDestName(self: *const RealBackend, track: *anyopaque, send_idx: c_int, buf: []u8) []const u8 {
        return self.inner.trackSendGetDestName(track, send_idx, buf);
    }

    pub fn trackSendSetVolume(self: *const RealBackend, track: *anyopaque, send_idx: c_int, volume: f64) f64 {
        return self.inner.trackSendSetVolume(track, send_idx, volume);
    }

    pub fn trackSendToggleMute(self: *const RealBackend, track: *anyopaque, send_idx: c_int) bool {
        return self.inner.trackSendToggleMute(track, send_idx);
    }

    pub fn trackSendSetMute(self: *const RealBackend, track: *anyopaque, send_idx: c_int, muted: bool) bool {
        return self.inner.trackSendSetMute(track, send_idx, muted);
    }

    pub fn trackSendGetPan(self: *const RealBackend, track: *anyopaque, send_idx: c_int) f64 {
        return self.inner.trackSendGetPan(track, send_idx);
    }

    pub fn trackSendSetPan(self: *const RealBackend, track: *anyopaque, send_idx: c_int, pan: f64) f64 {
        return self.inner.trackSendSetPan(track, send_idx, pan);
    }

    pub fn trackSendSetMode(self: *const RealBackend, track: *anyopaque, send_idx: c_int, mode: c_int) bool {
        return self.inner.trackSendSetMode(track, send_idx, mode);
    }

    // =========================================================================
    // Hardware Outputs
    // =========================================================================

    pub fn trackHwOutputCount(self: *const RealBackend, track: *anyopaque) c_int {
        return self.inner.trackHwOutputCount(track);
    }

    pub fn trackHwOutputGetVolume(self: *const RealBackend, track: *anyopaque, hw_idx: c_int) f64 {
        return self.inner.trackHwOutputGetVolume(track, hw_idx);
    }

    pub fn trackHwOutputGetPan(self: *const RealBackend, track: *anyopaque, hw_idx: c_int) f64 {
        return self.inner.trackHwOutputGetPan(track, hw_idx);
    }

    pub fn trackHwOutputGetMute(self: *const RealBackend, track: *anyopaque, hw_idx: c_int) bool {
        return self.inner.trackHwOutputGetMute(track, hw_idx);
    }

    pub fn trackHwOutputGetMode(self: *const RealBackend, track: *anyopaque, hw_idx: c_int) ffi.FFIError!c_int {
        return ffi.safeFloatToInt(c_int, self.inner.trackHwOutputGetModeRaw(track, hw_idx));
    }

    pub fn trackHwOutputGetDestChannel(self: *const RealBackend, track: *anyopaque, hw_idx: c_int) ffi.FFIError!c_int {
        return ffi.safeFloatToInt(c_int, self.inner.trackHwOutputGetDestChannelRaw(track, hw_idx));
    }

    pub fn trackHwOutputSetVolume(self: *const RealBackend, track: *anyopaque, hw_idx: c_int, volume: f64) bool {
        return self.inner.trackHwOutputSetVolume(track, hw_idx, volume);
    }

    pub fn trackHwOutputSetPan(self: *const RealBackend, track: *anyopaque, hw_idx: c_int, pan: f64) bool {
        return self.inner.trackHwOutputSetPan(track, hw_idx, pan);
    }

    pub fn trackHwOutputSetMute(self: *const RealBackend, track: *anyopaque, hw_idx: c_int, muted: bool) bool {
        return self.inner.trackHwOutputSetMute(track, hw_idx, muted);
    }

    pub fn trackHwOutputSetMode(self: *const RealBackend, track: *anyopaque, hw_idx: c_int, mode: c_int) bool {
        return self.inner.trackHwOutputSetMode(track, hw_idx, mode);
    }

    pub fn trackHwOutputSetDestChannel(self: *const RealBackend, track: *anyopaque, hw_idx: c_int, dest_chan: c_int) bool {
        return self.inner.trackHwOutputSetDestChannel(track, hw_idx, dest_chan);
    }

    // =========================================================================
    // Send/Receive/HW Output Creation & Removal
    // =========================================================================

    pub fn createSend(self: *const RealBackend, track: *anyopaque, dest_track: ?*anyopaque) c_int {
        return self.inner.createTrackSend(track, dest_track);
    }

    pub fn removeSend(self: *const RealBackend, track: *anyopaque, category: c_int, send_idx: c_int) bool {
        return self.inner.removeTrackSend(track, category, send_idx);
    }

    // =========================================================================
    // Items
    // =========================================================================

    pub fn trackItemCount(self: *const RealBackend, track: *anyopaque) c_int {
        return self.inner.trackItemCount(track);
    }

    pub fn getItemByIdx(self: *const RealBackend, track: *anyopaque, idx: c_int) ?*anyopaque {
        return self.inner.getItemByIdx(track, idx);
    }

    pub fn getItemPosition(self: *const RealBackend, item: *anyopaque) f64 {
        return self.inner.getItemPosition(item);
    }

    pub fn getItemLength(self: *const RealBackend, item: *anyopaque) f64 {
        return self.inner.getItemLength(item);
    }

    pub fn getItemColor(self: *const RealBackend, item: *anyopaque) ffi.FFIError!c_int {
        return ffi.safeFloatToInt(c_int, self.inner.getItemColor(item));
    }

    pub fn getItemLocked(self: *const RealBackend, item: *anyopaque) ffi.FFIError!bool {
        const val = try ffi.safeFloatToInt(c_int, self.inner.getItemLocked(item));
        return val != 0;
    }

    pub fn getItemSelected(self: *const RealBackend, item: *anyopaque) ffi.FFIError!bool {
        const val = try ffi.safeFloatToInt(c_int, self.inner.getItemSelected(item));
        return val != 0;
    }

    pub fn getItemActiveTakeIdx(self: *const RealBackend, item: *anyopaque) ffi.FFIError!c_int {
        return ffi.safeFloatToInt(c_int, self.inner.getItemActiveTakeIdx(item));
    }

    pub fn getItemNotes(self: *const RealBackend, item: *anyopaque, buf: []u8) []const u8 {
        return self.inner.getItemNotes(item, buf);
    }

    pub fn getItemGUID(self: *const RealBackend, item: *anyopaque, buf: []u8) []const u8 {
        return self.inner.getItemGUID(item, buf);
    }

    // Item setters
    pub fn setItemPosition(self: *const RealBackend, item: *anyopaque, pos: f64) bool {
        return self.inner.setItemPosition(item, pos);
    }

    pub fn setItemColor(self: *const RealBackend, item: *anyopaque, color: c_int) bool {
        return self.inner.setItemColor(item, color);
    }

    pub fn setItemLocked(self: *const RealBackend, item: *anyopaque, locked: bool) bool {
        return self.inner.setItemLocked(item, locked);
    }

    pub fn setItemSelected(self: *const RealBackend, item: *anyopaque, selected: bool) bool {
        return self.inner.setItemSelected(item, selected);
    }

    pub fn setItemNotes(self: *const RealBackend, item: *anyopaque, notes: []const u8) bool {
        return self.inner.setItemNotes(item, notes);
    }

    pub fn setItemActiveTake(self: *const RealBackend, item: *anyopaque, take_idx: c_int) bool {
        return self.inner.setItemActiveTake(item, take_idx);
    }

    pub fn deleteItem(self: *const RealBackend, track: *anyopaque, item: *anyopaque) bool {
        return self.inner.deleteItem(track, item);
    }

    pub fn moveItemToTrack(self: *const RealBackend, item: *anyopaque, dest_track: *anyopaque) bool {
        return self.inner.moveItemToTrack(item, dest_track);
    }

    // =========================================================================
    // Takes
    // =========================================================================

    pub fn itemTakeCount(self: *const RealBackend, item: *anyopaque) c_int {
        return self.inner.itemTakeCount(item);
    }

    pub fn getTakeByIdx(self: *const RealBackend, item: *anyopaque, idx: c_int) ?*anyopaque {
        return self.inner.getTakeByIdx(item, idx);
    }

    pub fn getItemActiveTake(self: *const RealBackend, item: *anyopaque) ?*anyopaque {
        return self.inner.getItemActiveTake(item);
    }

    pub fn getTakeNameStr(self: *const RealBackend, take: *anyopaque) []const u8 {
        return self.inner.getTakeNameStr(take);
    }

    pub fn getTakeGUID(self: *const RealBackend, take: *anyopaque, buf: []u8) []const u8 {
        return self.inner.getTakeGUID(take, buf);
    }

    pub fn getTakeStartOffset(self: *const RealBackend, take: *anyopaque) f64 {
        return self.inner.getTakeStartOffset(take);
    }

    pub fn getTakePlayrate(self: *const RealBackend, take: *anyopaque) f64 {
        return self.inner.getTakePlayrate(take);
    }

    pub fn getTakeColor(self: *const RealBackend, take: *anyopaque) ffi.FFIError!c_int {
        return ffi.safeFloatToInt(c_int, self.inner.getTakeColor(take));
    }

    pub fn setTakeColor(self: *const RealBackend, take: *anyopaque, color: c_int) bool {
        return self.inner.setTakeColor(take, color);
    }

    pub fn isTakeMIDI(self: *const RealBackend, take: *anyopaque) bool {
        return self.inner.isTakeMIDI(take);
    }

    pub fn getTakeSource(self: *const RealBackend, take: *anyopaque) ?*anyopaque {
        return self.inner.getTakeSource(take);
    }

    pub fn getRootSource(self: *const RealBackend, source: *anyopaque) *anyopaque {
        return self.inner.getRootSource(source);
    }

    pub fn getMediaSourceChannels(self: *const RealBackend, source: *anyopaque) c_int {
        return self.inner.getMediaSourceChannels(source);
    }

    pub fn getMediaItemTakePeaks(self: *const RealBackend, take: *anyopaque, peakrate: f64, starttime: f64, numchannels: c_int, numsamplesperchannel: c_int, buf: []f64) c_int {
        return self.inner.getMediaItemTakePeaks(take, peakrate, starttime, numchannels, numsamplesperchannel, buf);
    }

    pub fn makeTakeAccessor(self: *const RealBackend, take: *anyopaque) ?*anyopaque {
        return self.inner.makeTakeAccessor(take);
    }

    pub fn destroyTakeAccessor(self: *const RealBackend, accessor: *anyopaque) void {
        self.inner.destroyTakeAccessor(accessor);
    }

    pub fn accessorValidate(self: *const RealBackend, accessor: *anyopaque) bool {
        return self.inner.accessorValidate(accessor);
    }

    pub fn accessorGetPeaks(self: *const RealBackend, accessor: *anyopaque, channel: c_int, start_time: f64, end_time: f64, samples: c_int, buf: []f64) ?[]const f64 {
        return self.inner.accessorGetPeaks(accessor, channel, start_time, end_time, samples, buf);
    }

    pub fn readAccessorSamples(self: *const RealBackend, accessor: *anyopaque, samplerate: c_int, numchannels: c_int, starttime_sec: f64, numsamplesperchannel: c_int, buf: []f64) c_int {
        return self.inner.readAccessorSamples(accessor, samplerate, numchannels, starttime_sec, numsamplesperchannel, buf);
    }

    // =========================================================================
    // Markers
    // =========================================================================

    pub fn markerCount(self: *const RealBackend) types.MarkerCount {
        return self.inner.markerCount();
    }

    pub fn enumMarker(self: *const RealBackend, idx: c_int) ?types.MarkerInfo {
        return self.inner.enumMarker(idx);
    }

    pub fn addMarker(self: *const RealBackend, pos: f64, name: [*:0]const u8, color: c_int) c_int {
        return self.inner.addMarker(pos, name, color);
    }

    pub fn addMarkerWithId(self: *const RealBackend, pos: f64, name: [*:0]const u8, color: c_int, id: c_int) c_int {
        return self.inner.addMarkerWithId(pos, name, color, id);
    }

    pub fn addRegion(self: *const RealBackend, start: f64, end: f64, name: [*:0]const u8, color: c_int) c_int {
        return self.inner.addRegion(start, end, name, color);
    }

    pub fn addRegionWithId(self: *const RealBackend, start: f64, end: f64, name: [*:0]const u8, color: c_int, id: c_int) c_int {
        return self.inner.addRegionWithId(start, end, name, color, id);
    }

    pub fn updateMarker(self: *const RealBackend, id: c_int, pos: f64, name: [*:0]const u8, color: c_int) bool {
        return self.inner.updateMarker(id, pos, name, color);
    }

    pub fn updateRegion(self: *const RealBackend, id: c_int, start: f64, end: f64, name: [*:0]const u8, color: c_int) bool {
        return self.inner.updateRegion(id, start, end, name, color);
    }

    pub fn deleteMarker(self: *const RealBackend, id: c_int) bool {
        return self.inner.deleteMarker(id);
    }

    pub fn deleteRegion(self: *const RealBackend, id: c_int) bool {
        return self.inner.deleteRegion(id);
    }

    // =========================================================================
    // Metering
    // =========================================================================

    pub fn getTrackPeakInfo(self: *const RealBackend, track: *anyopaque, channel: c_int) f64 {
        return self.inner.getTrackPeakInfo(track, channel);
    }

    pub fn clearTrackPeakHold(self: *const RealBackend, track: *anyopaque) void {
        self.inner.clearTrackPeakHold(track);
    }

    pub fn getTrackPeakHoldDB(self: *const RealBackend, track: *anyopaque, channel: c_int, clear: bool) f64 {
        return self.inner.getTrackPeakHoldDB(track, channel, clear);
    }

    // =========================================================================
    // ExtState
    // =========================================================================

    pub fn getExtStateValue(self: *const RealBackend, section: [*:0]const u8, key: [*:0]const u8) ?[]const u8 {
        return self.inner.getExtStateValue(section, key);
    }

    pub fn setExtStateValue(self: *const RealBackend, section: [*:0]const u8, key: [*:0]const u8, value: [*:0]const u8, persist: bool) void {
        self.inner.setExtStateValue(section, key, value, persist);
    }

    pub fn getProjExtStateValue(self: *const RealBackend, extname: [*:0]const u8, key: [*:0]const u8, buf: []u8) ?[]const u8 {
        return self.inner.getProjExtStateValue(extname, key, buf);
    }

    pub fn setProjExtStateValue(self: *const RealBackend, extname: [*:0]const u8, key: [*:0]const u8, value: [*:0]const u8) void {
        self.inner.setProjExtStateValue(extname, key, value);
    }

    // =========================================================================
    // Project notes
    // =========================================================================

    pub fn getProjectNotes(self: *const RealBackend, buf: []u8) ?[]const u8 {
        return self.inner.getProjectNotes(buf);
    }

    pub fn setProjectNotes(self: *const RealBackend, notes: []const u8) void {
        self.inner.setProjectNotes(notes);
    }

    // =========================================================================
    // Named command lookup
    // =========================================================================

    pub fn namedCommandLookup(self: *const RealBackend, name: []const u8) c_int {
        return self.inner.namedCommandLookup(name);
    }

    // =========================================================================
    // MIDI
    // =========================================================================

    pub fn sendMidiCC(self: *const RealBackend, channel: u8, cc: u8, value: u8) void {
        self.inner.sendMidiCC(channel, cc, value);
    }

    pub fn sendMidiPC(self: *const RealBackend, channel: u8, program: u8) void {
        self.inner.sendMidiPC(channel, program);
    }

    pub fn sendNoteOn(self: *const RealBackend, channel: u8, note: u8, velocity: u8) void {
        self.inner.sendNoteOn(channel, note, velocity);
    }

    pub fn sendPitchBend(self: *const RealBackend, channel: u8, value: u16) void {
        self.inner.sendPitchBend(channel, value);
    }

    // =========================================================================
    // UI
    // =========================================================================

    pub fn updateTimeline(self: *const RealBackend) void {
        self.inner.updateTimeline();
    }

    // =========================================================================
    // Input enumeration (for track input selection)
    // =========================================================================

    pub fn numAudioInputs(self: *const RealBackend) c_int {
        return self.inner.numAudioInputs();
    }

    pub fn audioInputName(self: *const RealBackend, channel: c_int) ?[*:0]const u8 {
        return self.inner.audioInputName(channel);
    }

    pub fn numAudioOutputs(self: *const RealBackend) c_int {
        return self.inner.numAudioOutputs();
    }

    pub fn audioOutputName(self: *const RealBackend, channel: c_int) ?[*:0]const u8 {
        return self.inner.audioOutputName(channel);
    }

    pub fn maxMidiInputs(self: *const RealBackend) c_int {
        return self.inner.maxMidiInputs();
    }

    pub fn midiInputName(self: *const RealBackend, dev: c_int, name_buf: [*]u8, buf_size: c_int) bool {
        return self.inner.midiInputName(dev, name_buf, buf_size);
    }

    /// Get track record input value (I_RECINPUT encoding).
    /// Returns -1 for no input (or on FFI error), or encoded bitfield for audio/MIDI inputs.
    pub fn getTrackRecInput(self: *const RealBackend, track: *anyopaque) c_int {
        const f = self.inner.getMediaTrackInfo_Value orelse return -1;
        const val = f(track, "I_RECINPUT");
        return ffi.safeFloatToInt(c_int, val) catch -1;
    }

    /// Set track record input value (I_RECINPUT encoding).
    /// Pass -1 for no input, or encoded bitfield for audio/MIDI inputs.
    pub fn setTrackRecInput(self: *const RealBackend, track: *anyopaque, value: c_int) bool {
        const f = self.inner.setMediaTrackInfo_Value orelse return false;
        return f(track, "I_RECINPUT", @floatFromInt(value));
    }

    // =========================================================================
    // Fixed Lanes (swipe comping)
    // =========================================================================

    pub fn getNumFixedLanes(self: *const RealBackend, track: *anyopaque) ffi.FFIError!c_int {
        return ffi.safeFloatToInt(c_int, self.inner.getNumFixedLanes(track));
    }

    pub fn getTrackFreeMode(self: *const RealBackend, track: *anyopaque) ffi.FFIError!c_int {
        return ffi.safeFloatToInt(c_int, self.inner.getTrackFreeMode(track));
    }

    pub fn setTrackFreeMode(self: *const RealBackend, track: *anyopaque, mode: c_int) bool {
        return self.inner.setTrackFreeMode(track, mode);
    }

    pub fn getTrackLanePlays(self: *const RealBackend, track: *anyopaque, lane_idx: c_int) ffi.FFIError!c_int {
        return ffi.safeFloatToInt(c_int, self.inner.getTrackLanePlays(track, lane_idx));
    }

    pub fn setTrackLanePlays(self: *const RealBackend, track: *anyopaque, lane_idx: c_int, plays: c_int) bool {
        return self.inner.setTrackLanePlays(track, lane_idx, plays);
    }

    pub fn getAllLanesPlay(self: *const RealBackend, track: *anyopaque) ffi.FFIError!c_int {
        return ffi.safeFloatToInt(c_int, self.inner.getAllLanesPlay(track));
    }

    pub fn setRazorEditsExt(self: *const RealBackend, track: *anyopaque, razor_str: []const u8) bool {
        return self.inner.setRazorEditsExt(track, razor_str);
    }

    pub fn clearRazorEdits(self: *const RealBackend, track: *anyopaque) bool {
        return self.inner.clearRazorEdits(track);
    }

    pub fn getTrackStateChunkStr(self: *const RealBackend, track: *anyopaque, buf: []u8, isundo: bool) []const u8 {
        return self.inner.getTrackStateChunkStr(track, buf, isundo);
    }

    pub fn setTrackStateChunkStr(self: *const RealBackend, track: *anyopaque, chunk: [:0]const u8, isundo: bool) bool {
        return self.inner.setTrackStateChunkStr(track, chunk, isundo);
    }

    pub fn getItemFixedLane(self: *const RealBackend, item: *anyopaque) ffi.FFIError!c_int {
        return ffi.safeFloatToInt(c_int, self.inner.getItemFixedLane(item));
    }

    pub fn getItemLanePlays(self: *const RealBackend, item: *anyopaque) ffi.FFIError!c_int {
        return ffi.safeFloatToInt(c_int, self.inner.getItemLanePlays(item));
    }

    pub fn getLaneName(self: *const RealBackend, track: *anyopaque, lane_idx: c_int, buf: []u8) []const u8 {
        return self.inner.getLaneName(track, lane_idx, buf);
    }
};

// Validate at comptime that RealBackend has all required methods
comptime {
    backend.validateBackend(RealBackend);
}
