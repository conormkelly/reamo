/// Mock track, item, and take methods.
const std = @import("std");
const state = @import("state.zig");
const types = @import("../types.zig");
const ffi = @import("../../ffi.zig");

/// Track, item, and take method implementations for MockBackend.
pub const TracksMethods = struct {
    // =========================================================================
    // Tracks
    // =========================================================================

    pub fn trackCount(self: anytype) c_int {
        self.recordCall(.trackCount);
        return self.track_count;
    }

    pub fn getTrackByIdx(self: anytype, idx: c_int) ?*anyopaque {
        self.recordCall(.getTrackByIdx);
        if (idx < 0 or idx >= self.track_count) return null;
        return state.encodeTrackPtr(idx);
    }

    pub fn getTrackByUnifiedIdx(self: anytype, idx: c_int) ?*anyopaque {
        self.recordCall(.getTrackByUnifiedIdx);
        // 0 = master, 1+ = regular tracks
        if (idx < 0 or idx > self.track_count) return null;
        return state.encodeTrackPtr(idx);
    }

    pub fn masterTrack(self: anytype) ?*anyopaque {
        self.recordCall(.masterTrack);
        return state.encodeTrackPtr(0); // Master is track 0 in unified scheme
    }

    pub fn getTrackNameStr(self: anytype, track: *anyopaque, buf: []u8) []const u8 {
        self.recordCall(.getTrackNameStr);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return "";
        const name = self.tracks[idx].getName();
        const len = @min(name.len, buf.len);
        @memcpy(buf[0..len], name[0..len]);
        return buf[0..len];
    }

    pub fn getTrackVolume(self: anytype, track: *anyopaque) f64 {
        self.recordCall(.getTrackVolume);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return 1.0;
        return self.tracks[idx].volume;
    }

    pub fn getTrackPan(self: anytype, track: *anyopaque) f64 {
        self.recordCall(.getTrackPan);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return 0.0;
        return self.tracks[idx].pan;
    }

    pub fn getTrackMute(self: anytype, track: *anyopaque) bool {
        self.recordCall(.getTrackMute);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return false;
        return self.tracks[idx].mute;
    }

    pub fn getTrackSolo(self: anytype, track: *anyopaque) ffi.FFIError!c_int {
        self.recordCall(.getTrackSolo);
        if (self.inject_solo_error) return ffi.FFIError.FloatIsNaN;
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return 0;
        return self.tracks[idx].solo;
    }

    pub fn getTrackRecArm(self: anytype, track: *anyopaque) bool {
        self.recordCall(.getTrackRecArm);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return false;
        return self.tracks[idx].rec_arm;
    }

    pub fn getTrackRecMon(self: anytype, track: *anyopaque) ffi.FFIError!c_int {
        self.recordCall(.getTrackRecMon);
        if (self.inject_recmon_error) return ffi.FFIError.FloatIsNaN;
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return 0;
        return self.tracks[idx].rec_mon;
    }

    pub fn getTrackFxEnabled(self: anytype, track: *anyopaque) bool {
        self.recordCall(.getTrackFxEnabled);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return true;
        return self.tracks[idx].fx_enabled;
    }

    pub fn getTrackSelected(self: anytype, track: *anyopaque) bool {
        self.recordCall(.getTrackSelected);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return false;
        return self.tracks[idx].selected;
    }

    pub fn getTrackColor(self: anytype, track: *anyopaque) ffi.FFIError!c_int {
        self.recordCall(.getTrackColor);
        if (self.inject_track_color_error) return ffi.FFIError.FloatIsNaN;
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return 0;
        return self.tracks[idx].color;
    }

    pub fn isMasterMuted(self: anytype) bool {
        self.recordCall(.isMasterMuted);
        return self.master_muted;
    }

    pub fn isMasterSoloed(self: anytype) bool {
        self.recordCall(.isMasterSoloed);
        return self.master_soloed;
    }

    // Track setters
    pub fn setTrackVolume(self: anytype, track: *anyopaque, vol: f64) bool {
        self.recordCall(.setTrackVolume);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return false;
        self.tracks[idx].volume = vol;
        return true;
    }

    pub fn setTrackPan(self: anytype, track: *anyopaque, pan: f64) bool {
        self.recordCall(.setTrackPan);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return false;
        self.tracks[idx].pan = pan;
        return true;
    }

    pub fn setTrackMute(self: anytype, track: *anyopaque, mute: bool) bool {
        self.recordCall(.setTrackMute);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return false;
        self.tracks[idx].mute = mute;
        return true;
    }

    pub fn setTrackSolo(self: anytype, track: *anyopaque, solo: c_int) bool {
        self.recordCall(.setTrackSolo);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return false;
        self.tracks[idx].solo = solo;
        return true;
    }

    pub fn setTrackRecArm(self: anytype, track: *anyopaque, arm: bool) bool {
        self.recordCall(.setTrackRecArm);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return false;
        self.tracks[idx].rec_arm = arm;
        return true;
    }

    pub fn setTrackRecMon(self: anytype, track: *anyopaque, mon: c_int) bool {
        self.recordCall(.setTrackRecMon);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return false;
        self.tracks[idx].rec_mon = mon;
        return true;
    }

    pub fn setTrackFxEnabled(self: anytype, track: *anyopaque, enabled: bool) bool {
        self.recordCall(.setTrackFxEnabled);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return false;
        self.tracks[idx].fx_enabled = enabled;
        return true;
    }

    pub fn setTrackSelected(self: anytype, track: *anyopaque, selected: bool) bool {
        self.recordCall(.setTrackSelected);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return false;
        self.tracks[idx].selected = selected;
        return true;
    }

    // CSurf methods (mock just delegates to regular setters)
    pub fn csurfSetVolume(self: anytype, track: *anyopaque, vol: f64, _: bool) f64 {
        self.recordCall(.csurfSetVolume);
        _ = setTrackVolume(self, track, vol);
        return vol;
    }

    pub fn csurfSetPan(self: anytype, track: *anyopaque, pan: f64, _: bool) f64 {
        self.recordCall(.csurfSetPan);
        _ = setTrackPan(self, track, pan);
        return pan;
    }

    pub fn csurfSetMute(self: anytype, track: *anyopaque, mute: bool, _: bool) bool {
        self.recordCall(.csurfSetMute);
        return setTrackMute(self, track, mute);
    }

    pub fn csurfSetSolo(self: anytype, track: *anyopaque, solo: c_int, _: bool) bool {
        self.recordCall(.csurfSetSolo);
        return setTrackSolo(self, track, solo);
    }

    pub fn csurfSetRecArm(self: anytype, track: *anyopaque, arm: bool, _: bool) bool {
        self.recordCall(.csurfSetRecArm);
        return setTrackRecArm(self, track, arm);
    }

    pub fn csurfSetRecMon(self: anytype, track: *anyopaque, mon: c_int, _: bool) c_int {
        self.recordCall(.csurfSetRecMon);
        if (setTrackRecMon(self, track, mon)) {
            return mon;
        }
        return -1;
    }

    pub fn csurfFlushUndo(self: anytype, _: bool) void {
        self.recordCall(.csurfFlushUndo);
        // No-op in mock
    }

    // =========================================================================
    // Items
    // =========================================================================

    pub fn trackItemCount(self: anytype, track: *anyopaque) c_int {
        self.recordCall(.trackItemCount);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return 0;
        return self.tracks[idx].item_count;
    }

    pub fn getItemByIdx(self: anytype, track: *anyopaque, item_idx: c_int) ?*anyopaque {
        self.recordCall(.getItemByIdx);
        const track_idx = state.decodeTrackPtr(track);
        if (track_idx >= state.MAX_TRACKS) return null;
        if (item_idx < 0 or item_idx >= self.tracks[track_idx].item_count) return null;
        return state.encodeItemPtr(track_idx, item_idx);
    }

    pub fn getItemPosition(self: anytype, item: *anyopaque) f64 {
        self.recordCall(.getItemPosition);
        const info = state.decodeItemPtr(item);
        if (info.track_idx >= state.MAX_TRACKS) return 0;
        if (info.item_idx >= state.MAX_ITEMS_PER_TRACK) return 0;
        return self.tracks[info.track_idx].items[info.item_idx].position;
    }

    pub fn getItemLength(self: anytype, item: *anyopaque) f64 {
        self.recordCall(.getItemLength);
        const info = state.decodeItemPtr(item);
        if (info.track_idx >= state.MAX_TRACKS) return 0;
        if (info.item_idx >= state.MAX_ITEMS_PER_TRACK) return 0;
        return self.tracks[info.track_idx].items[info.item_idx].length;
    }

    pub fn getItemColor(self: anytype, item: *anyopaque) ffi.FFIError!c_int {
        self.recordCall(.getItemColor);
        if (self.inject_item_color_error) return ffi.FFIError.FloatIsNaN;
        const info = state.decodeItemPtr(item);
        if (info.track_idx >= state.MAX_TRACKS) return 0;
        if (info.item_idx >= state.MAX_ITEMS_PER_TRACK) return 0;
        return self.tracks[info.track_idx].items[info.item_idx].color;
    }

    pub fn getItemLocked(self: anytype, item: *anyopaque) ffi.FFIError!bool {
        self.recordCall(.getItemLocked);
        if (self.inject_item_locked_error) return ffi.FFIError.FloatIsNaN;
        const info = state.decodeItemPtr(item);
        if (info.track_idx >= state.MAX_TRACKS) return false;
        if (info.item_idx >= state.MAX_ITEMS_PER_TRACK) return false;
        return self.tracks[info.track_idx].items[info.item_idx].locked;
    }

    pub fn getItemSelected(self: anytype, item: *anyopaque) ffi.FFIError!bool {
        self.recordCall(.getItemSelected);
        if (self.inject_item_selected_error) return ffi.FFIError.FloatIsNaN;
        const info = state.decodeItemPtr(item);
        if (info.track_idx >= state.MAX_TRACKS) return false;
        if (info.item_idx >= state.MAX_ITEMS_PER_TRACK) return false;
        return self.tracks[info.track_idx].items[info.item_idx].selected;
    }

    pub fn getItemActiveTakeIdx(self: anytype, item: *anyopaque) ffi.FFIError!c_int {
        self.recordCall(.getItemActiveTakeIdx);
        if (self.inject_item_active_take_error) return ffi.FFIError.FloatIsNaN;
        const info = state.decodeItemPtr(item);
        if (info.track_idx >= state.MAX_TRACKS) return 0;
        if (info.item_idx >= state.MAX_ITEMS_PER_TRACK) return 0;
        return self.tracks[info.track_idx].items[info.item_idx].active_take_idx;
    }

    pub fn getItemNotes(self: anytype, item: *anyopaque, buf: []u8) []const u8 {
        self.recordCall(.getItemNotes);
        const info = state.decodeItemPtr(item);
        if (info.track_idx >= state.MAX_TRACKS) return "";
        if (info.item_idx >= state.MAX_ITEMS_PER_TRACK) return "";
        const mock_item = &self.tracks[info.track_idx].items[info.item_idx];
        const len = @min(mock_item.notes_len, buf.len);
        @memcpy(buf[0..len], mock_item.notes[0..len]);
        return buf[0..len];
    }

    pub fn getItemGUID(self: anytype, item: *anyopaque, buf: []u8) []const u8 {
        self.recordCall(.getItemGUID);
        const info = state.decodeItemPtr(item);
        if (info.track_idx >= state.MAX_TRACKS) return "";
        if (info.item_idx >= state.MAX_ITEMS_PER_TRACK) return "";
        const mock_item = &self.tracks[info.track_idx].items[info.item_idx];
        const len = @min(mock_item.guid_len, buf.len);
        @memcpy(buf[0..len], mock_item.guid[0..len]);
        return buf[0..len];
    }

    // Item setters
    pub fn setItemPosition(self: anytype, item: *anyopaque, pos: f64) bool {
        self.recordCall(.setItemPosition);
        const info = state.decodeItemPtr(item);
        if (info.track_idx >= state.MAX_TRACKS) return false;
        if (info.item_idx >= state.MAX_ITEMS_PER_TRACK) return false;
        self.tracks[info.track_idx].items[info.item_idx].position = pos;
        return true;
    }

    pub fn setItemColor(self: anytype, item: *anyopaque, color: c_int) bool {
        self.recordCall(.setItemColor);
        const info = state.decodeItemPtr(item);
        if (info.track_idx >= state.MAX_TRACKS) return false;
        if (info.item_idx >= state.MAX_ITEMS_PER_TRACK) return false;
        self.tracks[info.track_idx].items[info.item_idx].color = color;
        return true;
    }

    pub fn setItemLocked(self: anytype, item: *anyopaque, locked: bool) bool {
        self.recordCall(.setItemLocked);
        const info = state.decodeItemPtr(item);
        if (info.track_idx >= state.MAX_TRACKS) return false;
        if (info.item_idx >= state.MAX_ITEMS_PER_TRACK) return false;
        self.tracks[info.track_idx].items[info.item_idx].locked = locked;
        return true;
    }

    pub fn setItemSelected(self: anytype, item: *anyopaque, selected: bool) bool {
        self.recordCall(.setItemSelected);
        const info = state.decodeItemPtr(item);
        if (info.track_idx >= state.MAX_TRACKS) return false;
        if (info.item_idx >= state.MAX_ITEMS_PER_TRACK) return false;
        self.tracks[info.track_idx].items[info.item_idx].selected = selected;
        return true;
    }

    pub fn setItemNotes(self: anytype, item: *anyopaque, notes: []const u8) bool {
        self.recordCall(.setItemNotes);
        const info = state.decodeItemPtr(item);
        if (info.track_idx >= state.MAX_TRACKS) return false;
        if (info.item_idx >= state.MAX_ITEMS_PER_TRACK) return false;
        self.tracks[info.track_idx].items[info.item_idx].setNotes(notes);
        return true;
    }

    pub fn setItemActiveTake(self: anytype, item: *anyopaque, take_idx: c_int) bool {
        self.recordCall(.setItemActiveTake);
        const info = state.decodeItemPtr(item);
        if (info.track_idx >= state.MAX_TRACKS) return false;
        if (info.item_idx >= state.MAX_ITEMS_PER_TRACK) return false;
        self.tracks[info.track_idx].items[info.item_idx].active_take_idx = take_idx;
        return true;
    }

    pub fn deleteItem(self: anytype, track: *anyopaque, item: *anyopaque) bool {
        self.recordCall(.deleteItem);
        _ = track;
        _ = item;
        // In real mock we'd remove from array, for now just acknowledge
        return true;
    }

    // =========================================================================
    // Takes
    // =========================================================================

    pub fn itemTakeCount(self: anytype, item: *anyopaque) c_int {
        self.recordCall(.itemTakeCount);
        const info = state.decodeItemPtr(item);
        if (info.track_idx >= state.MAX_TRACKS) return 0;
        if (info.item_idx >= state.MAX_ITEMS_PER_TRACK) return 0;
        return self.tracks[info.track_idx].items[info.item_idx].take_count;
    }

    pub fn getTakeByIdx(self: anytype, item: *anyopaque, take_idx: c_int) ?*anyopaque {
        self.recordCall(.getTakeByIdx);
        const info = state.decodeItemPtr(item);
        if (info.track_idx >= state.MAX_TRACKS) return null;
        if (info.item_idx >= state.MAX_ITEMS_PER_TRACK) return null;
        const mock_item = &self.tracks[info.track_idx].items[info.item_idx];
        if (take_idx < 0 or take_idx >= mock_item.take_count) return null;
        return state.encodeTakePtr(info.track_idx, info.item_idx, take_idx);
    }

    pub fn getItemActiveTake(self: anytype, item: *anyopaque) ?*anyopaque {
        self.recordCall(.getItemActiveTake);
        const info = state.decodeItemPtr(item);
        if (info.track_idx >= state.MAX_TRACKS) return null;
        if (info.item_idx >= state.MAX_ITEMS_PER_TRACK) return null;
        const mock_item = &self.tracks[info.track_idx].items[info.item_idx];
        if (mock_item.take_count == 0) return null;
        return state.encodeTakePtr(info.track_idx, info.item_idx, mock_item.active_take_idx);
    }

    pub fn getTakeNameStr(self: anytype, take: *anyopaque) []const u8 {
        self.recordCall(.getTakeNameStr);
        const info = state.decodeTakePtr(take);
        if (info.track_idx >= state.MAX_TRACKS) return "";
        if (info.item_idx >= state.MAX_ITEMS_PER_TRACK) return "";
        if (info.take_idx >= state.MAX_TAKES_PER_ITEM) return "";
        const mock_take = &self.tracks[info.track_idx].items[info.item_idx].takes[info.take_idx];
        return mock_take.name[0..mock_take.name_len];
    }

    pub fn getTakeGUID(self: anytype, take: *anyopaque, buf: []u8) []const u8 {
        self.recordCall(.getTakeGUID);
        const info = state.decodeTakePtr(take);
        if (info.track_idx >= state.MAX_TRACKS) return "";
        if (info.item_idx >= state.MAX_ITEMS_PER_TRACK) return "";
        if (info.take_idx >= state.MAX_TAKES_PER_ITEM) return "";
        const mock_take = &self.tracks[info.track_idx].items[info.item_idx].takes[info.take_idx];
        const len = @min(mock_take.guid_len, buf.len);
        @memcpy(buf[0..len], mock_take.guid[0..len]);
        return buf[0..len];
    }

    pub fn getTakeStartOffset(self: anytype, take: *anyopaque) f64 {
        self.recordCall(.getTakeStartOffset);
        const info = state.decodeTakePtr(take);
        if (info.track_idx >= state.MAX_TRACKS) return 0;
        if (info.item_idx >= state.MAX_ITEMS_PER_TRACK) return 0;
        if (info.take_idx >= state.MAX_TAKES_PER_ITEM) return 0;
        return self.tracks[info.track_idx].items[info.item_idx].takes[info.take_idx].start_offset;
    }

    pub fn getTakePlayrate(self: anytype, take: *anyopaque) f64 {
        self.recordCall(.getTakePlayrate);
        const info = state.decodeTakePtr(take);
        if (info.track_idx >= state.MAX_TRACKS) return 1.0;
        if (info.item_idx >= state.MAX_ITEMS_PER_TRACK) return 1.0;
        if (info.take_idx >= state.MAX_TAKES_PER_ITEM) return 1.0;
        return self.tracks[info.track_idx].items[info.item_idx].takes[info.take_idx].playrate;
    }

    pub fn isTakeMIDI(self: anytype, take: *anyopaque) bool {
        self.recordCall(.isTakeMIDI);
        const info = state.decodeTakePtr(take);
        if (info.track_idx >= state.MAX_TRACKS) return false;
        if (info.item_idx >= state.MAX_ITEMS_PER_TRACK) return false;
        if (info.take_idx >= state.MAX_TAKES_PER_ITEM) return false;
        return self.tracks[info.track_idx].items[info.item_idx].takes[info.take_idx].is_midi;
    }

    pub fn getTakeSource(self: anytype, take: *anyopaque) ?*anyopaque {
        self.recordCall(.getTakeSource);
        // Return the take pointer as source (simplified mock)
        return take;
    }

    pub fn getMediaSourceChannels(self: anytype, source: *anyopaque) c_int {
        self.recordCall(.getMediaSourceChannels);
        // Source is same as take in our mock
        const info = state.decodeTakePtr(source);
        if (info.track_idx >= state.MAX_TRACKS) return 0;
        if (info.item_idx >= state.MAX_ITEMS_PER_TRACK) return 0;
        if (info.take_idx >= state.MAX_TAKES_PER_ITEM) return 0;
        return self.tracks[info.track_idx].items[info.item_idx].takes[info.take_idx].channel_count;
    }

    // Metering
    pub fn getTrackPeakInfo(self: anytype, track: *anyopaque, channel: c_int) f64 {
        self.recordCall(.getTrackPeakInfo);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return 0.0;
        if (channel == 0) return self.tracks[idx].peak_left;
        return self.tracks[idx].peak_right;
    }

    // =========================================================================
    // Track FX
    // =========================================================================

    pub fn trackFxCount(self: anytype, track: *anyopaque) c_int {
        self.recordCall(.trackFxCount);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return 0;
        return self.tracks[idx].fx_count;
    }

    pub fn trackFxGetName(self: anytype, track: *anyopaque, fx_idx: c_int, buf: []u8) []const u8 {
        self.recordCall(.trackFxGetName);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return "";
        if (fx_idx < 0 or fx_idx >= self.tracks[idx].fx_count) return "";
        const fx_usize: usize = @intCast(fx_idx);
        if (fx_usize >= state.MAX_FX_PER_TRACK) return "";
        const name = self.tracks[idx].fx[fx_usize].getName();
        const len = @min(name.len, buf.len);
        @memcpy(buf[0..len], name[0..len]);
        return buf[0..len];
    }

    pub fn trackFxGetPresetIndex(self: anytype, track: *anyopaque, fx_idx: c_int, preset_count: *c_int) c_int {
        self.recordCall(.trackFxGetPresetIndex);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) {
            preset_count.* = 0;
            return -1;
        }
        if (fx_idx < 0 or fx_idx >= self.tracks[idx].fx_count) {
            preset_count.* = 0;
            return -1;
        }
        const fx_usize: usize = @intCast(fx_idx);
        if (fx_usize >= state.MAX_FX_PER_TRACK) {
            preset_count.* = 0;
            return -1;
        }
        preset_count.* = self.tracks[idx].fx[fx_usize].preset_count;
        return self.tracks[idx].fx[fx_usize].preset_index;
    }

    pub fn trackFxGetPreset(self: anytype, track: *anyopaque, fx_idx: c_int, buf: []u8) types.FxPresetInfo {
        self.recordCall(.trackFxGetPreset);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return .{ .name = "", .matches_preset = false };
        if (fx_idx < 0 or fx_idx >= self.tracks[idx].fx_count) return .{ .name = "", .matches_preset = false };
        const fx_usize: usize = @intCast(fx_idx);
        if (fx_usize >= state.MAX_FX_PER_TRACK) return .{ .name = "", .matches_preset = false };
        const preset_name = self.tracks[idx].fx[fx_usize].getPresetName();
        const len = @min(preset_name.len, buf.len);
        @memcpy(buf[0..len], preset_name[0..len]);
        return .{
            .name = buf[0..len],
            .matches_preset = self.tracks[idx].fx[fx_usize].params_match_preset,
        };
    }

    pub fn trackFxNavigatePresets(self: anytype, track: *anyopaque, fx_idx: c_int, presetmove: c_int) bool {
        self.recordCall(.trackFxNavigatePresets);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return false;
        if (fx_idx < 0 or fx_idx >= self.tracks[idx].fx_count) return false;
        const fx_usize: usize = @intCast(fx_idx);
        if (fx_usize >= state.MAX_FX_PER_TRACK) return false;
        const fx = &self.tracks[idx].fx[fx_usize];
        if (fx.preset_count == 0) return false;
        // Navigate: wrap around
        var new_idx = fx.preset_index + presetmove;
        if (new_idx < 0) new_idx = fx.preset_count - 1;
        if (new_idx >= fx.preset_count) new_idx = 0;
        fx.preset_index = new_idx;
        fx.params_match_preset = true; // Preset was just loaded
        return true;
    }

    pub fn trackFxSetPresetByIndex(self: anytype, track: *anyopaque, fx_idx: c_int, preset_idx: c_int) bool {
        self.recordCall(.trackFxSetPresetByIndex);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return false;
        if (fx_idx < 0 or fx_idx >= self.tracks[idx].fx_count) return false;
        const fx_usize: usize = @intCast(fx_idx);
        if (fx_usize >= state.MAX_FX_PER_TRACK) return false;
        const fx = &self.tracks[idx].fx[fx_usize];
        // Special indices: -1 = default user, -2 = factory
        if (preset_idx < -2 or (preset_idx >= 0 and preset_idx >= fx.preset_count)) return false;
        fx.preset_index = preset_idx;
        fx.params_match_preset = true; // Preset was just loaded
        return true;
    }
};
