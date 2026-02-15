/// Mock track, item, and take methods.
const std = @import("std");
const state = @import("state.zig");
const types = @import("../types.zig");
const ffi = @import("../../core/ffi.zig");

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

    pub fn setTrackColor(self: anytype, track: *anyopaque, color: c_int) void {
        self.recordCall(.setTrackColor);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return;
        self.tracks[idx].color = color;
    }

    pub fn isMasterMuted(self: anytype) bool {
        self.recordCall(.isMasterMuted);
        return self.master_muted;
    }

    pub fn isMasterSoloed(self: anytype) bool {
        self.recordCall(.isMasterSoloed);
        return self.master_soloed;
    }

    /// Get peak hold in dB for a track channel. Returns > 0 if clipped.
    pub fn getTrackPeakHoldDB(self: anytype, track: *anyopaque, channel: c_int, clear: bool) f64 {
        self.recordCall(.getTrackPeakHoldDB);
        _ = channel; // Mock returns same value for both channels
        _ = clear; // Mock doesn't support clearing
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return -150.0;
        // Return +1 dB if clipped (triggers skeleton.clipped = true), else -12 dB
        return if (self.tracks[idx].clipped) 1.0 else -12.0;
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

    pub fn getSelectedTrackByIdx(self: anytype, sel_idx: c_int) ?*anyopaque {
        self.recordCall(.getSelectedTrackByIdx);
        // Find the sel_idx'th selected track
        var selected_count: c_int = 0;
        for (0..state.MAX_TRACKS) |i| {
            if (i > @as(usize, @intCast(self.track_count))) break;
            if (self.tracks[i].selected) {
                if (selected_count == sel_idx) {
                    return state.encodeTrackPtr(@intCast(i));
                }
                selected_count += 1;
            }
        }
        return null;
    }

    pub fn setTrackName(self: anytype, track: *anyopaque, name: []const u8) bool {
        self.recordCall(.setTrackName);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return false;
        self.tracks[idx].setName(name);
        return true;
    }

    pub fn insertTrack(self: anytype, idx: c_int, _: bool) void {
        self.recordCall(.insertTrack);
        // In mock, just bump track count if valid insertion point
        if (idx >= 0 and idx <= self.track_count and self.track_count < state.MAX_TRACKS) {
            self.track_count += 1;
        }
    }

    pub fn deleteTrackPtr(self: anytype, track: *anyopaque) void {
        self.recordCall(.deleteTrackPtr);
        _ = track;
        // In mock, just decrement track count
        if (self.track_count > 0) {
            self.track_count -= 1;
        }
    }

    pub fn getTrackFolderDepth(self: anytype, track: *anyopaque) ffi.FFIError!c_int {
        self.recordCall(.getTrackFolderDepth);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return 0;
        return self.tracks[idx].folder_depth;
    }

    /// Format track GUID as string into provided buffer.
    /// Mock generates deterministic GUIDs based on track index.
    pub fn formatTrackGuid(self: anytype, track: *anyopaque, buf: []u8) []const u8 {
        self.recordCall(.formatTrackGuid);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return "";
        if (buf.len < 40) return "";

        // Generate deterministic mock GUID: {00000000-0000-0000-0000-00000000XXXX}
        // where XXXX is the track index in hex
        const guid = std.fmt.bufPrint(buf, "{{00000000-0000-0000-0000-{d:0>12}}}", .{idx}) catch return "";
        return guid;
    }

    /// Get unified track index from track pointer (reverse lookup).
    /// Returns unified index: 0=master, 1+=user tracks.
    pub fn getTrackIdx(self: anytype, track: *anyopaque) c_int {
        self.recordCall(.getTrackIdx);
        const idx = state.decodeTrackPtr(track);
        // In mock, the encoded pointer IS the unified index
        if (idx > @as(usize, @intCast(self.track_count))) return -1;
        return @intCast(idx);
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
    // Pointer Validation
    // =========================================================================

    /// Mock always returns true for valid-looking pointers.
    /// In tests, use track_count to control what's "valid".
    /// Uses <= because unified indexing: 0=master, 1..track_count=user tracks
    pub fn validateTrackPtr(self: anytype, track: ?*anyopaque) bool {
        self.recordCall(.validateTrackPtr);
        if (track == null) return false;
        const idx = state.decodeTrackPtr(track.?);
        // Unified indexing: 0 = master (always valid), 1..track_count = user tracks
        return idx <= self.track_count;
    }

    /// Mock always returns true for valid-looking pointers.
    pub fn validateItemPtr(self: anytype, item: ?*anyopaque) bool {
        self.recordCall(.validateItemPtr);
        if (item == null) return false;
        const info = state.decodeItemPtr(item.?);
        if (info.track_idx >= self.track_count) return false;
        return info.item_idx < self.tracks[info.track_idx].item_count;
    }

    /// Mock always returns true for valid-looking pointers.
    pub fn validateTakePtr(self: anytype, take: ?*anyopaque) bool {
        self.recordCall(.validateTakePtr);
        // For mock, we just check it's not null and decode works
        if (take == null) return false;
        // Takes use same encoding as items in mock
        const info = state.decodeItemPtr(take.?);
        return info.track_idx < self.track_count;
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

        // Decode item pointer to get track and item indices
        const info = state.decodeItemPtr(item);
        if (info.track_idx >= state.MAX_TRACKS) return false;
        if (info.item_idx >= state.MAX_ITEMS_PER_TRACK) return false;

        // Validate track pointer matches (optional safety check)
        const track_idx = state.decodeTrackPtr(track);
        if (track_idx != info.track_idx) return false;

        const mock_track = &self.tracks[info.track_idx];
        const item_count: usize = @intCast(@max(0, mock_track.item_count));
        if (info.item_idx >= item_count) return false;

        // Shift remaining items down to fill the gap
        var i = info.item_idx;
        while (i + 1 < item_count) : (i += 1) {
            mock_track.items[i] = mock_track.items[i + 1];
        }
        // Clear the last slot
        mock_track.items[item_count - 1] = .{};
        mock_track.item_count -= 1;

        return true;
    }

    pub fn moveItemToTrack(self: anytype, item: *anyopaque, dest_track: *anyopaque) bool {
        self.recordCall(.moveItemToTrack);

        const info = state.decodeItemPtr(item);
        const dest_track_idx = state.decodeTrackPtr(dest_track);
        if (info.track_idx >= state.MAX_TRACKS) return false;
        if (dest_track_idx >= state.MAX_TRACKS) return false;
        if (info.track_idx == dest_track_idx) return true; // already on target track

        const src_track = &self.tracks[info.track_idx];
        const dst_track = &self.tracks[dest_track_idx];
        const src_count: usize = @intCast(@max(0, src_track.item_count));
        const dst_count: usize = @intCast(@max(0, dst_track.item_count));

        if (info.item_idx >= src_count) return false;
        if (dst_count >= state.MAX_ITEMS_PER_TRACK) return false;

        // Copy item to destination
        dst_track.items[dst_count] = src_track.items[info.item_idx];
        dst_track.item_count += 1;

        // Remove from source (shift down)
        var i = info.item_idx;
        while (i + 1 < src_count) : (i += 1) {
            src_track.items[i] = src_track.items[i + 1];
        }
        src_track.items[src_count - 1] = .{};
        src_track.item_count -= 1;

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

    pub fn getTakeColor(self: anytype, take: *anyopaque) ffi.FFIError!c_int {
        self.recordCall(.getTakeColor);
        const info = state.decodeTakePtr(take);
        if (info.track_idx >= state.MAX_TRACKS) return 0;
        if (info.item_idx >= state.MAX_ITEMS_PER_TRACK) return 0;
        if (info.take_idx >= state.MAX_TAKES_PER_ITEM) return 0;
        return self.tracks[info.track_idx].items[info.item_idx].takes[info.take_idx].color;
    }

    pub fn setTakeColor(self: anytype, take: *anyopaque, color: c_int) bool {
        self.recordCall(.setTakeColor);
        const info = state.decodeTakePtr(take);
        if (info.track_idx >= state.MAX_TRACKS) return false;
        if (info.item_idx >= state.MAX_ITEMS_PER_TRACK) return false;
        if (info.take_idx >= state.MAX_TAKES_PER_ITEM) return false;
        self.tracks[info.track_idx].items[info.item_idx].takes[info.take_idx].color = color;
        return true;
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

    /// Get root source - mock just returns the source itself (no parent chain)
    pub fn getRootSource(self: anytype, source: *anyopaque) *anyopaque {
        self.recordCall(.getRootSource);
        return source;
    }

    pub fn getMediaItemTakePeaks(self: anytype, take: *anyopaque, peakrate: f64, starttime: f64, numchannels: c_int, numsamplesperchannel: c_int, buf: []f64) c_int {
        self.recordCall(.getMediaItemTakePeaks);
        _ = take;
        _ = peakrate;
        _ = starttime;
        // Fill buffer with mock peak data: alternating 0.5/-0.5 pattern
        const num_peaks: usize = @intCast(numsamplesperchannel);
        const num_chans: usize = @intCast(numchannels);
        const total_values = num_chans * num_peaks * 2; // max + min per channel
        if (buf.len >= total_values) {
            for (0..total_values) |i| {
                // Simple pattern: max values positive, min values negative
                buf[i] = if (i < num_chans * num_peaks) 0.5 else -0.5;
            }
        }
        // Return format: sample_count in low 20 bits, mode in bits 20-23 (mode 1 = ready)
        return @as(c_int, numsamplesperchannel) | (1 << 20);
    }

    // AudioAccessor (mock for fallback peak generation)
    pub fn makeTakeAccessor(self: anytype, take: *anyopaque) ?*anyopaque {
        self.recordCall(.makeTakeAccessor);
        // Return the take pointer as the accessor (simplifies mock)
        return take;
    }

    pub fn destroyTakeAccessor(self: anytype, accessor: *anyopaque) void {
        self.recordCall(.destroyTakeAccessor);
        _ = accessor;
    }

    pub fn readAccessorSamples(self: anytype, accessor: *anyopaque, samplerate: c_int, numchannels: c_int, starttime_sec: f64, numsamplesperchannel: c_int, buf: []f64) c_int {
        self.recordCall(.readAccessorSamples);
        _ = accessor;
        _ = samplerate;
        _ = starttime_sec;
        // Fill buffer with mock audio samples: sine wave pattern
        const num_samples: usize = @intCast(numsamplesperchannel);
        const num_chans: usize = @intCast(numchannels);
        for (0..num_samples) |i| {
            const phase = @as(f64, @floatFromInt(i)) / 100.0;
            const sample = @sin(phase * 6.28318);
            for (0..num_chans) |ch| {
                buf[i * num_chans + ch] = sample * 0.5; // Interleaved
            }
        }
        return 1; // Success
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

    /// Get number of Input FX (recording FX) on a track.
    /// Note: Mock doesn't track Input FX, always returns 0.
    pub fn trackFxRecCount(self: anytype, track: *anyopaque) c_int {
        self.recordCall(.trackFxRecCount);
        _ = track;
        return 0; // Mock doesn't simulate Input FX
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

    pub fn trackFxGetEnabled(self: anytype, track: *anyopaque, fx_idx: c_int) bool {
        self.recordCall(.trackFxGetEnabled);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return true;
        if (fx_idx < 0 or fx_idx >= self.tracks[idx].fx_count) return true;
        const fx_usize: usize = @intCast(fx_idx);
        if (fx_usize >= state.MAX_FX_PER_TRACK) return true;
        return self.tracks[idx].fx[fx_usize].enabled;
    }

    pub fn trackFxSetEnabled(self: anytype, track: *anyopaque, fx_idx: c_int, enabled: bool) void {
        self.recordCall(.trackFxSetEnabled);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return;
        if (fx_idx < 0 or fx_idx >= self.tracks[idx].fx_count) return;
        const fx_usize: usize = @intCast(fx_idx);
        if (fx_usize >= state.MAX_FX_PER_TRACK) return;
        self.tracks[idx].fx[fx_usize].enabled = enabled;
    }

    // =========================================================================
    // FX Management (mock implementations for testing)
    // =========================================================================

    /// Add an FX to a track by name (mock: always adds at end, returns new index).
    pub fn trackFxAddByName(self: anytype, track: *anyopaque, name: [*:0]const u8, recFX: bool, position: c_int) c_int {
        _ = recFX; // Mock ignores recFX
        _ = position; // Mock always adds at end
        self.recordCall(.trackFxAddByName);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return -1;
        const fx_count = self.tracks[idx].fx_count;
        if (fx_count >= state.MAX_FX_PER_TRACK) return -1;
        const fx_idx: usize = @intCast(fx_count);
        // Set FX name from input
        const name_slice = std.mem.sliceTo(name, 0);
        self.tracks[idx].fx[fx_idx].setName(name_slice);
        self.tracks[idx].fx[fx_idx].enabled = true;
        self.tracks[idx].fx_count += 1;
        return fx_count;
    }

    /// Delete an FX from a track (mock: shifts remaining FX down).
    pub fn trackFxDelete(self: anytype, track: *anyopaque, fx_idx: c_int) bool {
        self.recordCall(.trackFxDelete);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return false;
        if (fx_idx < 0 or fx_idx >= self.tracks[idx].fx_count) return false;
        const fx_usize: usize = @intCast(fx_idx);
        // Shift FX down
        const count: usize = @intCast(self.tracks[idx].fx_count);
        var i: usize = fx_usize;
        while (i + 1 < count) : (i += 1) {
            self.tracks[idx].fx[i] = self.tracks[idx].fx[i + 1];
        }
        // Clear last slot
        self.tracks[idx].fx[count - 1] = .{};
        self.tracks[idx].fx_count -= 1;
        return true;
    }

    /// Copy or move FX (mock: only supports move within same track).
    pub fn trackFxCopyToTrack(self: anytype, src_track: *anyopaque, src_fx: c_int, dest_track: *anyopaque, dest_fx: c_int, is_move: bool) void {
        _ = is_move; // Mock only supports move
        self.recordCall(.trackFxCopyToTrack);
        // Only support same-track reorder in mock
        if (src_track != dest_track) return;
        const idx = state.decodeTrackPtr(src_track);
        if (idx >= state.MAX_TRACKS) return;
        if (src_fx < 0 or src_fx >= self.tracks[idx].fx_count) return;
        var effective_dest = dest_fx;
        if (effective_dest < 0 or effective_dest >= self.tracks[idx].fx_count) {
            effective_dest = self.tracks[idx].fx_count - 1;
        }
        if (src_fx == effective_dest) return;
        // Swap-based move (simplified)
        const src_usize: usize = @intCast(src_fx);
        const dest_usize: usize = @intCast(effective_dest);
        const temp = self.tracks[idx].fx[src_usize];
        if (src_usize < dest_usize) {
            // Shift left
            var i: usize = src_usize;
            while (i < dest_usize) : (i += 1) {
                self.tracks[idx].fx[i] = self.tracks[idx].fx[i + 1];
            }
        } else {
            // Shift right
            var i: usize = src_usize;
            while (i > dest_usize) : (i -= 1) {
                self.tracks[idx].fx[i] = self.tracks[idx].fx[i - 1];
            }
        }
        self.tracks[idx].fx[dest_usize] = temp;
    }

    /// Get FX GUID (mock: generates deterministic GUID from track+fx indices).
    pub fn trackFxGetGuid(self: anytype, track: *anyopaque, fx_idx: c_int, buf: []u8) []const u8 {
        self.recordCall(.trackFxGetGuid);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return "";
        if (fx_idx < 0 or fx_idx >= self.tracks[idx].fx_count) return "";
        if (buf.len < 38) return "";
        // Generate deterministic mock GUID: {TTTTTTTT-FFFF-0000-0000-000000000000}
        // where T = track index, F = fx index
        const result = std.fmt.bufPrint(buf, "{{0000{d:0>4}-{d:0>4}-0000-0000-000000000000}}", .{ idx, @as(u32, @intCast(fx_idx)) }) catch return "";
        return result;
    }

    // =========================================================================
    // FX Parameters
    // =========================================================================

    /// Get number of parameters for an FX.
    pub fn trackFxGetNumParams(self: anytype, track: *anyopaque, fx_idx: c_int) c_int {
        self.recordCall(.trackFxGetNumParams);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return 0;
        if (fx_idx < 0 or fx_idx >= self.tracks[idx].fx_count) return 0;
        const fx_usize: usize = @intCast(fx_idx);
        return self.tracks[idx].fx[fx_usize].param_count;
    }

    /// Get parameter name.
    pub fn trackFxGetParamName(self: anytype, track: *anyopaque, fx_idx: c_int, param_idx: c_int, buf: []u8) []const u8 {
        self.recordCall(.trackFxGetParamName);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return "";
        if (fx_idx < 0 or fx_idx >= self.tracks[idx].fx_count) return "";
        const fx_usize: usize = @intCast(fx_idx);
        const fx = &self.tracks[idx].fx[fx_usize];
        if (param_idx < 0 or param_idx >= fx.param_count) return "";
        const param_usize: usize = @intCast(param_idx);
        const name = fx.params[param_usize].getName();
        if (buf.len == 0 or name.len == 0) return "";
        const len = @min(name.len, buf.len - 1);
        @memcpy(buf[0..len], name[0..len]);
        buf[len] = 0;
        return buf[0..len];
    }

    /// Get normalized parameter value.
    pub fn trackFxGetParamNormalized(self: anytype, track: *anyopaque, fx_idx: c_int, param_idx: c_int) f64 {
        self.recordCall(.trackFxGetParamNormalized);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return 0.0;
        if (fx_idx < 0 or fx_idx >= self.tracks[idx].fx_count) return 0.0;
        const fx_usize: usize = @intCast(fx_idx);
        const fx = &self.tracks[idx].fx[fx_usize];
        if (param_idx < 0 or param_idx >= fx.param_count) return 0.0;
        const param_usize: usize = @intCast(param_idx);
        return fx.params[param_usize].value;
    }

    /// Get actual parameter value (not normalized). Mock returns same as normalized.
    pub fn trackFxGetParam(self: anytype, track: *anyopaque, fx_idx: c_int, param_idx: c_int) f64 {
        self.recordCall(.trackFxGetParam);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return 0.0;
        if (fx_idx < 0 or fx_idx >= self.tracks[idx].fx_count) return 0.0;
        const fx_usize: usize = @intCast(fx_idx);
        const fx = &self.tracks[idx].fx[fx_usize];
        if (param_idx < 0 or param_idx >= fx.param_count) return 0.0;
        const param_usize: usize = @intCast(param_idx);
        return fx.params[param_usize].value;
    }

    /// Set normalized parameter value.
    pub fn trackFxSetParamNormalized(self: anytype, track: *anyopaque, fx_idx: c_int, param_idx: c_int, value: f64) bool {
        self.recordCall(.trackFxSetParamNormalized);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return false;
        if (fx_idx < 0 or fx_idx >= self.tracks[idx].fx_count) return false;
        const fx_usize: usize = @intCast(fx_idx);
        const fx = &self.tracks[idx].fx[fx_usize];
        if (param_idx < 0 or param_idx >= fx.param_count) return false;
        const param_usize: usize = @intCast(param_idx);
        self.tracks[idx].fx[fx_usize].params[param_usize].value = value;
        return true;
    }

    /// Get formatted parameter value string.
    pub fn trackFxGetFormattedParamValue(self: anytype, track: *anyopaque, fx_idx: c_int, param_idx: c_int, buf: []u8) []const u8 {
        self.recordCall(.trackFxGetFormattedParamValue);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return "";
        if (fx_idx < 0 or fx_idx >= self.tracks[idx].fx_count) return "";
        const fx_usize: usize = @intCast(fx_idx);
        const fx = &self.tracks[idx].fx[fx_usize];
        if (param_idx < 0 or param_idx >= fx.param_count) return "";
        const param_usize: usize = @intCast(param_idx);
        const formatted = fx.params[param_usize].getFormatted();
        if (buf.len == 0 or formatted.len == 0) return "";
        const len = @min(formatted.len, buf.len - 1);
        @memcpy(buf[0..len], formatted[0..len]);
        buf[len] = 0;
        return buf[0..len];
    }

    // =========================================================================
    // Track Sends
    // =========================================================================

    pub fn trackSendCount(self: anytype, track: *anyopaque) c_int {
        self.recordCall(.trackSendCount);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return 0;
        return self.tracks[idx].send_count;
    }

    pub fn trackReceiveCount(self: anytype, track: *anyopaque) c_int {
        self.recordCall(.trackReceiveCount);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return 0;
        return self.tracks[idx].receive_count;
    }

    pub fn trackSendGetVolume(self: anytype, track: *anyopaque, send_idx: c_int) f64 {
        self.recordCall(.trackSendGetVolume);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return 1.0;
        if (send_idx < 0 or send_idx >= self.tracks[idx].send_count) return 1.0;
        const send_usize: usize = @intCast(send_idx);
        if (send_usize >= state.MAX_SENDS_PER_TRACK) return 1.0;
        return self.tracks[idx].sends[send_usize].volume;
    }

    pub fn trackSendGetMute(self: anytype, track: *anyopaque, send_idx: c_int) bool {
        self.recordCall(.trackSendGetMute);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return false;
        if (send_idx < 0 or send_idx >= self.tracks[idx].send_count) return false;
        const send_usize: usize = @intCast(send_idx);
        if (send_usize >= state.MAX_SENDS_PER_TRACK) return false;
        return self.tracks[idx].sends[send_usize].muted;
    }

    pub fn trackSendGetMode(self: anytype, track: *anyopaque, send_idx: c_int) ffi.FFIError!c_int {
        self.recordCall(.trackSendGetMode);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return 0;
        if (send_idx < 0 or send_idx >= self.tracks[idx].send_count) return 0;
        const send_usize: usize = @intCast(send_idx);
        if (send_usize >= state.MAX_SENDS_PER_TRACK) return 0;
        return self.tracks[idx].sends[send_usize].mode;
    }

    pub fn trackSendGetDestTrack(self: anytype, track: *anyopaque, send_idx: c_int) ?*anyopaque {
        self.recordCall(.trackSendGetDestTrack);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return null;
        if (send_idx < 0 or send_idx >= self.tracks[idx].send_count) return null;
        const send_usize: usize = @intCast(send_idx);
        if (send_usize >= state.MAX_SENDS_PER_TRACK) return null;
        const dest_track_idx = self.tracks[idx].sends[send_usize].dest_track_idx;
        if (dest_track_idx < 0) return null;
        return state.encodeTrackPtr(@intCast(dest_track_idx));
    }

    pub fn trackSendGetDestName(self: anytype, track: *anyopaque, send_idx: c_int, buf: []u8) []const u8 {
        self.recordCall(.trackSendGetDestName);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return "";
        if (send_idx < 0 or send_idx >= self.tracks[idx].send_count) return "";
        const send_usize: usize = @intCast(send_idx);
        if (send_usize >= state.MAX_SENDS_PER_TRACK) return "";
        const dest_name = self.tracks[idx].sends[send_usize].getDestName();
        const len = @min(dest_name.len, buf.len);
        @memcpy(buf[0..len], dest_name[0..len]);
        return buf[0..len];
    }

    pub fn trackSendSetVolume(self: anytype, track: *anyopaque, send_idx: c_int, volume: f64) f64 {
        self.recordCall(.trackSendSetVolume);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return volume;
        if (send_idx < 0 or send_idx >= self.tracks[idx].send_count) return volume;
        const send_usize: usize = @intCast(send_idx);
        if (send_usize >= state.MAX_SENDS_PER_TRACK) return volume;
        self.tracks[idx].sends[send_usize].volume = volume;
        return volume;
    }

    pub fn trackSendToggleMute(self: anytype, track: *anyopaque, send_idx: c_int) bool {
        self.recordCall(.trackSendToggleMute);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return false;
        if (send_idx < 0 or send_idx >= self.tracks[idx].send_count) return false;
        const send_usize: usize = @intCast(send_idx);
        if (send_usize >= state.MAX_SENDS_PER_TRACK) return false;
        self.tracks[idx].sends[send_usize].muted = !self.tracks[idx].sends[send_usize].muted;
        return true;
    }

    pub fn trackSendSetMute(self: anytype, track: *anyopaque, send_idx: c_int, muted: bool) bool {
        self.recordCall(.trackSendSetMute);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return false;
        if (send_idx < 0 or send_idx >= self.tracks[idx].send_count) return false;
        const send_usize: usize = @intCast(send_idx);
        if (send_usize >= state.MAX_SENDS_PER_TRACK) return false;
        self.tracks[idx].sends[send_usize].muted = muted;
        return true;
    }

    pub fn trackSendGetPan(self: anytype, track: *anyopaque, send_idx: c_int) f64 {
        self.recordCall(.trackSendGetPan);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return 0.0;
        if (send_idx < 0 or send_idx >= self.tracks[idx].send_count) return 0.0;
        const send_usize: usize = @intCast(send_idx);
        if (send_usize >= state.MAX_SENDS_PER_TRACK) return 0.0;
        return self.tracks[idx].sends[send_usize].pan;
    }

    pub fn trackSendSetPan(self: anytype, track: *anyopaque, send_idx: c_int, pan: f64) f64 {
        self.recordCall(.trackSendSetPan);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return pan;
        if (send_idx < 0 or send_idx >= self.tracks[idx].send_count) return pan;
        const send_usize: usize = @intCast(send_idx);
        if (send_usize >= state.MAX_SENDS_PER_TRACK) return pan;
        self.tracks[idx].sends[send_usize].pan = pan;
        return pan;
    }

    pub fn trackSendSetMode(self: anytype, track: *anyopaque, send_idx: c_int, mode: c_int) bool {
        self.recordCall(.trackSendSetMode);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return false;
        if (send_idx < 0 or send_idx >= self.tracks[idx].send_count) return false;
        const send_usize: usize = @intCast(send_idx);
        if (send_usize >= state.MAX_SENDS_PER_TRACK) return false;
        self.tracks[idx].sends[send_usize].mode = mode;
        return true;
    }

    // =========================================================================
    // Track Receives
    // =========================================================================

    pub fn trackReceiveGetVolume(self: anytype, track: *anyopaque, recv_idx: c_int) f64 {
        self.recordCall(.trackReceiveGetVolume);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return 1.0;
        if (recv_idx < 0 or recv_idx >= self.tracks[idx].receive_count) return 1.0;
        const recv_usize: usize = @intCast(recv_idx);
        if (recv_usize >= state.MAX_RECEIVES_PER_TRACK) return 1.0;
        return self.tracks[idx].receives[recv_usize].volume;
    }

    pub fn trackReceiveGetMute(self: anytype, track: *anyopaque, recv_idx: c_int) bool {
        self.recordCall(.trackReceiveGetMute);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return false;
        if (recv_idx < 0 or recv_idx >= self.tracks[idx].receive_count) return false;
        const recv_usize: usize = @intCast(recv_idx);
        if (recv_usize >= state.MAX_RECEIVES_PER_TRACK) return false;
        return self.tracks[idx].receives[recv_usize].muted;
    }

    pub fn trackReceiveGetMode(self: anytype, track: *anyopaque, recv_idx: c_int) ffi.FFIError!c_int {
        self.recordCall(.trackReceiveGetMode);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return 0;
        if (recv_idx < 0 or recv_idx >= self.tracks[idx].receive_count) return 0;
        const recv_usize: usize = @intCast(recv_idx);
        if (recv_usize >= state.MAX_RECEIVES_PER_TRACK) return 0;
        return self.tracks[idx].receives[recv_usize].mode;
    }

    pub fn trackReceiveGetPan(self: anytype, track: *anyopaque, recv_idx: c_int) f64 {
        self.recordCall(.trackReceiveGetPan);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return 0.0;
        if (recv_idx < 0 or recv_idx >= self.tracks[idx].receive_count) return 0.0;
        const recv_usize: usize = @intCast(recv_idx);
        if (recv_usize >= state.MAX_RECEIVES_PER_TRACK) return 0.0;
        return self.tracks[idx].receives[recv_usize].pan;
    }

    pub fn trackReceiveGetSrcTrack(self: anytype, track: *anyopaque, recv_idx: c_int) ?*anyopaque {
        self.recordCall(.trackReceiveGetSrcTrack);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return null;
        if (recv_idx < 0 or recv_idx >= self.tracks[idx].receive_count) return null;
        const recv_usize: usize = @intCast(recv_idx);
        if (recv_usize >= state.MAX_RECEIVES_PER_TRACK) return null;
        const src_track_idx = self.tracks[idx].receives[recv_usize].src_track_idx;
        if (src_track_idx < 0) return null;
        return state.encodeTrackPtr(@intCast(src_track_idx));
    }

    pub fn trackReceiveGetSrcName(self: anytype, track: *anyopaque, recv_idx: c_int, buf: []u8) []const u8 {
        self.recordCall(.trackReceiveGetSrcName);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return "";
        if (recv_idx < 0 or recv_idx >= self.tracks[idx].receive_count) return "";
        const recv_usize: usize = @intCast(recv_idx);
        if (recv_usize >= state.MAX_RECEIVES_PER_TRACK) return "";
        const src_name = self.tracks[idx].receives[recv_usize].getSrcName();
        const len = @min(src_name.len, buf.len);
        @memcpy(buf[0..len], src_name[0..len]);
        return buf[0..len];
    }

    pub fn trackReceiveSetVolume(self: anytype, track: *anyopaque, recv_idx: c_int, volume: f64) f64 {
        self.recordCall(.trackReceiveSetVolume);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return volume;
        if (recv_idx < 0 or recv_idx >= self.tracks[idx].receive_count) return volume;
        const recv_usize: usize = @intCast(recv_idx);
        if (recv_usize >= state.MAX_RECEIVES_PER_TRACK) return volume;
        self.tracks[idx].receives[recv_usize].volume = volume;
        return volume;
    }

    pub fn trackReceiveSetMute(self: anytype, track: *anyopaque, recv_idx: c_int, muted: bool) bool {
        self.recordCall(.trackReceiveSetMute);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return false;
        if (recv_idx < 0 or recv_idx >= self.tracks[idx].receive_count) return false;
        const recv_usize: usize = @intCast(recv_idx);
        if (recv_usize >= state.MAX_RECEIVES_PER_TRACK) return false;
        self.tracks[idx].receives[recv_usize].muted = muted;
        return true;
    }

    pub fn trackReceiveSetPan(self: anytype, track: *anyopaque, recv_idx: c_int, pan: f64) f64 {
        self.recordCall(.trackReceiveSetPan);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return pan;
        if (recv_idx < 0 or recv_idx >= self.tracks[idx].receive_count) return pan;
        const recv_usize: usize = @intCast(recv_idx);
        if (recv_usize >= state.MAX_RECEIVES_PER_TRACK) return pan;
        self.tracks[idx].receives[recv_usize].pan = pan;
        return pan;
    }

    pub fn trackReceiveSetMode(self: anytype, track: *anyopaque, recv_idx: c_int, mode: c_int) bool {
        self.recordCall(.trackReceiveSetMode);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return false;
        if (recv_idx < 0 or recv_idx >= self.tracks[idx].receive_count) return false;
        const recv_usize: usize = @intCast(recv_idx);
        if (recv_usize >= state.MAX_RECEIVES_PER_TRACK) return false;
        self.tracks[idx].receives[recv_usize].mode = mode;
        return true;
    }

    // =========================================================================
    // Hardware Outputs
    // =========================================================================

    pub fn trackHwOutputCount(self: anytype, track: *anyopaque) c_int {
        self.recordCall(.trackHwOutputCount);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return 0;
        return self.tracks[idx].hw_output_count;
    }

    pub fn trackHwOutputGetVolume(self: anytype, track: *anyopaque, hw_idx: c_int) f64 {
        self.recordCall(.trackHwOutputGetVolume);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return 1.0;
        if (hw_idx < 0 or hw_idx >= self.tracks[idx].hw_output_count) return 1.0;
        const hw_usize: usize = @intCast(hw_idx);
        if (hw_usize >= state.MAX_HW_OUTPUTS_PER_TRACK) return 1.0;
        return self.tracks[idx].hw_outputs[hw_usize].volume;
    }

    pub fn trackHwOutputGetPan(self: anytype, track: *anyopaque, hw_idx: c_int) f64 {
        self.recordCall(.trackHwOutputGetPan);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return 0.0;
        if (hw_idx < 0 or hw_idx >= self.tracks[idx].hw_output_count) return 0.0;
        const hw_usize: usize = @intCast(hw_idx);
        if (hw_usize >= state.MAX_HW_OUTPUTS_PER_TRACK) return 0.0;
        return self.tracks[idx].hw_outputs[hw_usize].pan;
    }

    pub fn trackHwOutputGetMute(self: anytype, track: *anyopaque, hw_idx: c_int) bool {
        self.recordCall(.trackHwOutputGetMute);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return false;
        if (hw_idx < 0 or hw_idx >= self.tracks[idx].hw_output_count) return false;
        const hw_usize: usize = @intCast(hw_idx);
        if (hw_usize >= state.MAX_HW_OUTPUTS_PER_TRACK) return false;
        return self.tracks[idx].hw_outputs[hw_usize].muted;
    }

    pub fn trackHwOutputGetMode(self: anytype, track: *anyopaque, hw_idx: c_int) ffi.FFIError!c_int {
        self.recordCall(.trackHwOutputGetMode);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return 0;
        if (hw_idx < 0 or hw_idx >= self.tracks[idx].hw_output_count) return 0;
        const hw_usize: usize = @intCast(hw_idx);
        if (hw_usize >= state.MAX_HW_OUTPUTS_PER_TRACK) return 0;
        return self.tracks[idx].hw_outputs[hw_usize].mode;
    }

    pub fn trackHwOutputGetDestChannel(self: anytype, track: *anyopaque, hw_idx: c_int) ffi.FFIError!c_int {
        self.recordCall(.trackHwOutputGetDestChannel);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return 0;
        if (hw_idx < 0 or hw_idx >= self.tracks[idx].hw_output_count) return 0;
        const hw_usize: usize = @intCast(hw_idx);
        if (hw_usize >= state.MAX_HW_OUTPUTS_PER_TRACK) return 0;
        return self.tracks[idx].hw_outputs[hw_usize].dest_channel;
    }

    pub fn trackHwOutputSetVolume(self: anytype, track: *anyopaque, hw_idx: c_int, volume: f64) bool {
        self.recordCall(.trackHwOutputSetVolume);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return false;
        if (hw_idx < 0 or hw_idx >= self.tracks[idx].hw_output_count) return false;
        const hw_usize: usize = @intCast(hw_idx);
        if (hw_usize >= state.MAX_HW_OUTPUTS_PER_TRACK) return false;
        self.tracks[idx].hw_outputs[hw_usize].volume = volume;
        return true;
    }

    pub fn trackHwOutputSetPan(self: anytype, track: *anyopaque, hw_idx: c_int, pan: f64) bool {
        self.recordCall(.trackHwOutputSetPan);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return false;
        if (hw_idx < 0 or hw_idx >= self.tracks[idx].hw_output_count) return false;
        const hw_usize: usize = @intCast(hw_idx);
        if (hw_usize >= state.MAX_HW_OUTPUTS_PER_TRACK) return false;
        self.tracks[idx].hw_outputs[hw_usize].pan = pan;
        return true;
    }

    pub fn trackHwOutputSetMute(self: anytype, track: *anyopaque, hw_idx: c_int, muted: bool) bool {
        self.recordCall(.trackHwOutputSetMute);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return false;
        if (hw_idx < 0 or hw_idx >= self.tracks[idx].hw_output_count) return false;
        const hw_usize: usize = @intCast(hw_idx);
        if (hw_usize >= state.MAX_HW_OUTPUTS_PER_TRACK) return false;
        self.tracks[idx].hw_outputs[hw_usize].muted = muted;
        return true;
    }

    pub fn trackHwOutputSetMode(self: anytype, track: *anyopaque, hw_idx: c_int, mode: c_int) bool {
        self.recordCall(.trackHwOutputSetMode);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return false;
        if (hw_idx < 0 or hw_idx >= self.tracks[idx].hw_output_count) return false;
        const hw_usize: usize = @intCast(hw_idx);
        if (hw_usize >= state.MAX_HW_OUTPUTS_PER_TRACK) return false;
        self.tracks[idx].hw_outputs[hw_usize].mode = mode;
        return true;
    }

    pub fn trackHwOutputSetDestChannel(self: anytype, track: *anyopaque, hw_idx: c_int, dest_chan: c_int) bool {
        self.recordCall(.trackHwOutputSetDestChannel);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return false;
        if (hw_idx < 0 or hw_idx >= self.tracks[idx].hw_output_count) return false;
        const hw_usize: usize = @intCast(hw_idx);
        if (hw_usize >= state.MAX_HW_OUTPUTS_PER_TRACK) return false;
        self.tracks[idx].hw_outputs[hw_usize].dest_channel = dest_chan;
        return true;
    }

    // =========================================================================
    // Send/Receive/HW Output Creation & Removal
    // =========================================================================

    pub fn createSend(self: anytype, track: *anyopaque, dest_track: ?*anyopaque) c_int {
        self.recordCall(.createSend);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return -1;

        if (dest_track) |_| {
            // Create a send
            const send_count: usize = @intCast(self.tracks[idx].send_count);
            if (send_count >= state.MAX_SENDS_PER_TRACK) return -1;
            self.tracks[idx].sends[send_count] = .{};
            self.tracks[idx].send_count += 1;
            return @intCast(send_count);
        } else {
            // Create a hardware output
            const hw_count: usize = @intCast(self.tracks[idx].hw_output_count);
            if (hw_count >= state.MAX_HW_OUTPUTS_PER_TRACK) return -1;
            self.tracks[idx].hw_outputs[hw_count] = .{};
            self.tracks[idx].hw_output_count += 1;
            return @intCast(hw_count);
        }
    }

    pub fn removeSend(self: anytype, track: *anyopaque, category: c_int, send_idx: c_int) bool {
        self.recordCall(.removeSend);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return false;

        if (category == 0) {
            // Remove a send
            if (send_idx < 0 or send_idx >= self.tracks[idx].send_count) return false;
            self.tracks[idx].send_count -= 1;
            return true;
        } else if (category < 0) {
            // Remove a receive
            if (send_idx < 0 or send_idx >= self.tracks[idx].receive_count) return false;
            self.tracks[idx].receive_count -= 1;
            return true;
        } else {
            // Remove a hw output
            if (send_idx < 0 or send_idx >= self.tracks[idx].hw_output_count) return false;
            self.tracks[idx].hw_output_count -= 1;
            return true;
        }
    }

    // =========================================================================
    // Fixed Lanes (swipe comping)
    // =========================================================================

    pub fn getNumFixedLanes(self: anytype, track: *anyopaque) ffi.FFIError!c_int {
        self.recordCall(.getNumFixedLanes);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return 0;
        return self.tracks[idx].num_fixed_lanes;
    }

    pub fn getTrackFreeMode(self: anytype, track: *anyopaque) ffi.FFIError!c_int {
        self.recordCall(.getTrackFreeMode);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return 0;
        return self.tracks[idx].free_mode;
    }

    pub fn setTrackFreeMode(self: anytype, track: *anyopaque, mode: c_int) bool {
        self.recordCall(.setTrackFreeMode);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return false;
        self.tracks[idx].free_mode = mode;
        return true;
    }

    pub fn getTrackLanePlays(self: anytype, track: *anyopaque, lane_idx: c_int) ffi.FFIError!c_int {
        self.recordCall(.getTrackLanePlays);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return 0;
        if (lane_idx < 0 or lane_idx >= self.tracks[idx].num_fixed_lanes) return 0;
        const lane_usize: usize = @intCast(lane_idx);
        if (lane_usize >= state.MAX_LANES_PER_TRACK) return 0;
        return self.tracks[idx].lane_plays[lane_usize];
    }

    pub fn setTrackLanePlays(self: anytype, track: *anyopaque, lane_idx: c_int, plays: c_int) bool {
        self.recordCall(.setTrackLanePlays);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return false;
        if (lane_idx < 0) return false;
        const lane_usize: usize = @intCast(lane_idx);
        if (lane_usize >= state.MAX_LANES_PER_TRACK) return false;
        self.tracks[idx].lane_plays[lane_usize] = plays;
        return true;
    }

    pub fn getAllLanesPlay(self: anytype, track: *anyopaque) ffi.FFIError!c_int {
        self.recordCall(.getAllLanesPlay);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return 0;
        // Return 0=none, 1=all, 2=some based on lane_plays
        var playing: c_int = 0;
        var total: c_int = 0;
        for (0..@intCast(self.tracks[idx].num_fixed_lanes)) |i| {
            total += 1;
            if (self.tracks[idx].lane_plays[i] != 0) playing += 1;
        }
        if (playing == 0) return 0;
        if (playing == total) return 1;
        return 2;
    }

    pub fn setRazorEditsExt(self: anytype, track: *anyopaque, razor_str: []const u8) bool {
        self.recordCall(.setRazorEditsExt);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return false;
        self.tracks[idx].setRazorEdits(razor_str);
        return true;
    }

    pub fn clearRazorEdits(self: anytype, track: *anyopaque) bool {
        self.recordCall(.clearRazorEdits);
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return false;
        self.tracks[idx].setRazorEdits("");
        return true;
    }

    pub fn getTrackStateChunkStr(self: anytype, track: *anyopaque, buf: []u8, isundo: bool) []const u8 {
        self.recordCall(.getTrackStateChunkStr);
        _ = isundo;
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return "";
        const chunk = self.tracks[idx].getStateChunk();
        const len = @min(chunk.len, buf.len);
        @memcpy(buf[0..len], chunk[0..len]);
        return buf[0..len];
    }

    pub fn setTrackStateChunkStr(self: anytype, track: *anyopaque, chunk: [:0]const u8, isundo: bool) bool {
        self.recordCall(.setTrackStateChunkStr);
        _ = isundo;
        const idx = state.decodeTrackPtr(track);
        if (idx >= state.MAX_TRACKS) return false;
        // [:0]const u8 coerces to []const u8 for the internal mock storage
        self.tracks[idx].setStateChunk(chunk);
        return true;
    }

    pub fn getItemFixedLane(self: anytype, item: *anyopaque) ffi.FFIError!c_int {
        self.recordCall(.getItemFixedLane);
        const info = state.decodeItemPtr(item);
        if (info.track_idx >= state.MAX_TRACKS) return 0;
        if (info.item_idx >= state.MAX_ITEMS_PER_TRACK) return 0;
        return self.tracks[info.track_idx].items[info.item_idx].fixed_lane;
    }

    pub fn getItemLanePlays(self: anytype, item: *anyopaque) ffi.FFIError!c_int {
        self.recordCall(.getItemLanePlays);
        const info = state.decodeItemPtr(item);
        if (info.track_idx >= state.MAX_TRACKS) return 0;
        if (info.item_idx >= state.MAX_ITEMS_PER_TRACK) return 0;
        return self.tracks[info.track_idx].items[info.item_idx].lane_plays;
    }

    pub fn getLaneName(self: anytype, track: *anyopaque, lane_idx: c_int, buf: []u8) []const u8 {
        self.recordCall(.getLaneName);
        const track_idx = state.decodeTrackPtr(track);
        if (track_idx >= state.MAX_TRACKS) return "";
        if (lane_idx < 0 or lane_idx >= state.MAX_LANES_PER_TRACK) return "";
        const name = self.tracks[track_idx].getLaneName(@intCast(lane_idx));
        const len = @min(name.len, buf.len);
        @memcpy(buf[0..len], name[0..len]);
        if (len < buf.len) buf[len] = 0;
        return buf[0..len];
    }
};
