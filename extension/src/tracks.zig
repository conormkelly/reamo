const std = @import("std");
const Allocator = std.mem.Allocator;
const reaper = @import("reaper.zig");
const protocol = @import("protocol.zig");

// Maximum tracks to poll (keeps buffer sizes bounded)
// Note: With arena allocation, this is a soft limit enforced per-poll
pub const MAX_TRACKS: usize = 128;

// Maximum tracks to meter (match MAX_TRACKS for full mixer metering)
pub const MAX_METERED_TRACKS: usize = MAX_TRACKS;

// Maximum FX per track (covers extreme cases; most tracks have 1-10 FX)
pub const MAX_FX_PER_TRACK: usize = 64;

// Maximum sends per track (typical: 0-4, extreme: 10+)
pub const MAX_SENDS_PER_TRACK: usize = 16;

// Maximum track name length
pub const MAX_NAME_LEN: usize = 128;

// Maximum FX/preset name length
pub const MAX_FX_NAME_LEN: usize = 128;

// Maximum send destination name length
pub const MAX_SEND_NAME_LEN: usize = 128;

/// Single FX slot state (preset info for one FX instance)
pub const FxSlot = struct {
    name: [MAX_FX_NAME_LEN]u8 = undefined,
    name_len: usize = 0,
    preset_name: [MAX_FX_NAME_LEN]u8 = undefined,
    preset_name_len: usize = 0,
    preset_index: c_int = -1, // -1 = no preset selected
    preset_count: c_int = 0,
    modified: bool = false, // True if params DON'T match preset

    pub fn getName(self: *const FxSlot) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn getPresetName(self: *const FxSlot) []const u8 {
        return self.preset_name[0..self.preset_name_len];
    }

    pub fn eql(self: FxSlot, other: FxSlot) bool {
        if (self.name_len != other.name_len) return false;
        if (!std.mem.eql(u8, self.name[0..self.name_len], other.name[0..other.name_len])) return false;
        if (self.preset_name_len != other.preset_name_len) return false;
        if (!std.mem.eql(u8, self.preset_name[0..self.preset_name_len], other.preset_name[0..other.preset_name_len])) return false;
        if (self.preset_index != other.preset_index) return false;
        if (self.preset_count != other.preset_count) return false;
        if (self.modified != other.modified) return false;
        return true;
    }
};

/// Single send slot state
pub const SendSlot = struct {
    dest_name: [MAX_SEND_NAME_LEN]u8 = undefined,
    dest_name_len: usize = 0,
    volume: f64 = 1.0, // Linear, 1.0 = 0dB
    muted: bool = false,
    mode: c_int = 0, // 0=post-fader, 1=pre-FX, 3=post-FX

    pub fn getDestName(self: *const SendSlot) []const u8 {
        return self.dest_name[0..self.dest_name_len];
    }

    pub fn eql(self: SendSlot, other: SendSlot) bool {
        if (self.dest_name_len != other.dest_name_len) return false;
        if (!std.mem.eql(u8, self.dest_name[0..self.dest_name_len], other.dest_name[0..other.dest_name_len])) return false;
        if (@abs(self.volume - other.volume) > 0.001) return false;
        if (self.muted != other.muted) return false;
        if (self.mode != other.mode) return false;
        return true;
    }
};

// Single track state
pub const Track = struct {
    idx: c_int = 0,
    name: [MAX_NAME_LEN]u8 = undefined,
    name_len: usize = 0,
    color: ?c_int = 0, // Native OS color (0 = default, null = corrupt data)
    volume: f64 = 1.0, // 0..inf (1.0 = 0dB)
    pan: f64 = 0.0, // -1.0..1.0
    mute: bool = false,
    // Solo state: 0=off, 1=solo, 2=solo in place, etc.
    // Null if REAPER returned corrupt data (NaN/Inf from stale pointer)
    solo: ?c_int = 0,
    rec_arm: bool = false,
    // Record monitoring: 0=off, 1=normal, 2=not when playing
    // Null if REAPER returned corrupt data
    rec_mon: ?c_int = 0,
    fx_enabled: bool = true,
    selected: bool = false,
    folder_depth: c_int = 0, // 1=folder parent, 0=normal, -N=closes N folder levels
    // FX chain state (polled at 5Hz, merged into track events)
    // Uses slice for arena/buffer-based allocation - variable per track
    fx: []FxSlot = &.{},
    // Send state (polled at 5Hz, merged into track events)
    // Uses slice for arena/buffer-based allocation - variable per track
    sends: []SendSlot = &.{},

    pub fn getName(self: *const Track) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn eql(self: Track, other: Track) bool {
        if (self.idx != other.idx) return false;
        if (self.name_len != other.name_len) return false;
        if (!std.mem.eql(u8, self.name[0..self.name_len], other.name[0..other.name_len])) return false;
        if (self.color != other.color) return false;
        if (!floatEql(self.volume, other.volume)) return false;
        if (!floatEql(self.pan, other.pan)) return false;
        if (self.mute != other.mute) return false;
        if (self.solo != other.solo) return false;
        if (self.rec_arm != other.rec_arm) return false;
        if (self.rec_mon != other.rec_mon) return false;
        if (self.fx_enabled != other.fx_enabled) return false;
        if (self.selected != other.selected) return false;
        if (self.folder_depth != other.folder_depth) return false;
        // Compare FX chain (slice-based)
        if (self.fx.len != other.fx.len) return false;
        for (self.fx, other.fx) |*a, *b| {
            if (!a.eql(b.*)) return false;
        }
        // Compare sends (slice-based)
        if (self.sends.len != other.sends.len) return false;
        for (self.sends, other.sends) |*a, *b| {
            if (!a.eql(b.*)) return false;
        }
        return true;
    }

    fn floatEql(a: f64, b: f64) bool {
        return @abs(a - b) <= 0.001;
    }
};

// Track state snapshot (all tracks)
// Uses slice for arena-based allocation - no fixed size limit.
pub const State = struct {
    tracks: []Track = &.{},

    /// Return an empty state (for initialization)
    pub fn empty() State {
        return .{ .tracks = &.{} };
    }

    /// Number of tracks in this state
    pub fn count(self: *const State) usize {
        return self.tracks.len;
    }

    // Compare for change detection
    pub fn eql(self: *const State, other: *const State) bool {
        if (self.tracks.len != other.tracks.len) return false;
        for (self.tracks, other.tracks) |*a, *b| {
            if (!a.eql(b.*)) return false;
        }
        return true;
    }

    /// Poll current state from REAPER, allocating from the provided allocator.
    /// Accepts any backend type (RealBackend, MockBackend, or test doubles).
    /// Uses unified indexing: idx 0 = master, idx 1+ = user tracks.
    ///
    /// For arena allocation: allocator should be from currentAllocator().
    /// Allocated memory is freed when arena resets.
    pub fn poll(allocator: Allocator, api: anytype) Allocator.Error!State {
        return pollWithLimit(allocator, api, MAX_TRACKS);
    }

    /// Poll with a custom track limit (for user-configurable limits)
    pub fn pollWithLimit(allocator: Allocator, api: anytype, max_tracks: usize) Allocator.Error!State {
        const user_track_count: usize = @intCast(@max(0, api.trackCount()));
        // Total count = master (1) + user tracks, capped at limit
        const total_count = @min(user_track_count + 1, max_tracks);

        const tracks = try allocator.alloc(Track, total_count);

        for (tracks, 0..) |*t, i| {
            const idx: c_int = @intCast(i);
            // Use unified indexing: 0 = master, 1+ = user tracks
            if (api.getTrackByUnifiedIdx(idx)) |track| {
                t.* = Track{}; // Initialize with defaults
                t.idx = idx;

                // Get track name (master track returns "MASTER" from REAPER)
                var name_buf: [MAX_NAME_LEN]u8 = undefined;
                const name = api.getTrackNameStr(track, &name_buf);
                const name_copy_len = @min(name.len, MAX_NAME_LEN);
                @memcpy(t.name[0..name_copy_len], name[0..name_copy_len]);
                t.name_len = name_copy_len;

                // getTrackColor returns error on NaN/Inf - propagate as null to client
                t.color = api.getTrackColor(track) catch null;
                t.volume = api.getTrackVolume(track);
                t.pan = api.getTrackPan(track);
                // For master track (idx=0), use GetMasterMuteSoloFlags which is more reliable
                // than GetMediaTrackInfo_Value with B_MUTE/I_SOLO
                if (idx == 0) {
                    t.mute = api.isMasterMuted();
                    t.solo = if (api.isMasterSoloed()) 1 else 0;
                } else {
                    t.mute = api.getTrackMute(track);
                    // getTrackSolo returns error on NaN/Inf - propagate as null to client
                    t.solo = api.getTrackSolo(track) catch null;
                }
                t.rec_arm = api.getTrackRecArm(track);
                // getTrackRecMon returns error on NaN/Inf - propagate as null to client
                t.rec_mon = api.getTrackRecMon(track) catch null;
                t.fx_enabled = api.getTrackFxEnabled(track);
                t.selected = api.getTrackSelected(track);
                t.folder_depth = api.getTrackFolderDepth(track);
                // Note: fx and sends slices default to empty (&.{}) from Track init
                // They get populated by MEDIUM_TIER polling into g_last_tracks
            } else {
                // Track disappeared between count and fetch - use empty
                t.* = Track{};
            }
        }

        return .{ .tracks = tracks };
    }

    // =========================================================================
    // Legacy API for backwards compatibility (deprecated - will be removed)
    // =========================================================================

    /// Poll current state from REAPER into an existing State struct.
    /// DEPRECATED: Use poll(allocator, api) with arena allocation instead.
    /// NOTE: Uses output pointer to avoid 2.5MB stack allocation.
    pub fn pollInto(self: *State, static_buffer: []Track, api: anytype) void {
        const user_track_count: usize = @intCast(@max(0, api.trackCount()));
        const total_count = @min(user_track_count + 1, @min(static_buffer.len, MAX_TRACKS));

        for (static_buffer[0..total_count], 0..) |*t, i| {
            const idx: c_int = @intCast(i);
            if (api.getTrackByUnifiedIdx(idx)) |track| {
                t.* = Track{};
                t.idx = idx;

                var name_buf: [MAX_NAME_LEN]u8 = undefined;
                const name = api.getTrackNameStr(track, &name_buf);
                const name_copy_len = @min(name.len, MAX_NAME_LEN);
                @memcpy(t.name[0..name_copy_len], name[0..name_copy_len]);
                t.name_len = name_copy_len;

                t.color = api.getTrackColor(track) catch null;
                t.volume = api.getTrackVolume(track);
                t.pan = api.getTrackPan(track);
                if (idx == 0) {
                    t.mute = api.isMasterMuted();
                    t.solo = if (api.isMasterSoloed()) 1 else 0;
                } else {
                    t.mute = api.getTrackMute(track);
                    t.solo = api.getTrackSolo(track) catch null;
                }
                t.rec_arm = api.getTrackRecArm(track);
                t.rec_mon = api.getTrackRecMon(track) catch null;
                t.fx_enabled = api.getTrackFxEnabled(track);
                t.selected = api.getTrackSelected(track);
                t.folder_depth = api.getTrackFolderDepth(track);
                // Note: fx and sends slices default to empty (&.{}) from Track init
                // They get populated by MEDIUM_TIER polling into g_last_tracks
            } else {
                t.* = Track{};
            }
        }

        self.tracks = static_buffer[0..total_count];
    }

    // Build JSON event for tracks state
    // Format: {"type":"event","event":"tracks","payload":{"tracks":[...],"meters":[...]}}
    pub fn toJson(self: *const State, buf: []u8, metering: ?*const MeteringState) ?[]const u8 {
        var stream = std.io.fixedBufferStream(buf);
        const writer = stream.writer();

        writer.writeAll("{\"type\":\"event\",\"event\":\"tracks\",\"payload\":{\"tracks\":[") catch return null;

        for (self.tracks, 0..) |*t, i| {
            if (i > 0) writer.writeByte(',') catch return null;
            writer.print("{{\"idx\":{d},\"name\":\"", .{t.idx}) catch return null;
            protocol.writeJsonString(writer, t.getName()) catch return null;
            writer.writeAll("\",\"color\":") catch return null;

            // color - null if corrupt
            if (t.color) |c| {
                writer.print("{d}", .{c}) catch return null;
            } else {
                writer.writeAll("null") catch return null;
            }

            writer.print(",\"volume\":{d:.4},\"pan\":{d:.3},\"mute\":{s},\"solo\":", .{
                t.volume,
                t.pan,
                if (t.mute) "true" else "false",
            }) catch return null;

            // solo - null if corrupt
            if (t.solo) |s| {
                writer.print("{d}", .{s}) catch return null;
            } else {
                writer.writeAll("null") catch return null;
            }

            writer.print(",\"recArm\":{s},\"recMon\":", .{
                if (t.rec_arm) "true" else "false",
            }) catch return null;

            // rec_mon - null if corrupt
            if (t.rec_mon) |rm| {
                writer.print("{d}", .{rm}) catch return null;
            } else {
                writer.writeAll("null") catch return null;
            }

            writer.print(",\"fxEnabled\":{s},\"selected\":{s},\"folderDepth\":{d}", .{
                if (t.fx_enabled) "true" else "false",
                if (t.selected) "true" else "false",
                t.folder_depth,
            }) catch return null;

            // Serialize FX chain (slice-based)
            writer.writeAll(",\"fx\":[") catch return null;
            for (t.fx, 0..) |*fx, fx_i| {
                if (fx_i > 0) writer.writeByte(',') catch return null;
                writer.writeAll("{\"name\":\"") catch return null;
                protocol.writeJsonString(writer, fx.getName()) catch return null;
                writer.writeAll("\",\"presetName\":\"") catch return null;
                protocol.writeJsonString(writer, fx.getPresetName()) catch return null;
                writer.print("\",\"presetIndex\":{d},\"presetCount\":{d},\"modified\":{s}}}", .{
                    fx.preset_index,
                    fx.preset_count,
                    if (fx.modified) "true" else "false",
                }) catch return null;
            }
            writer.writeAll("]") catch return null;

            // Serialize sends (slice-based)
            writer.writeAll(",\"sends\":[") catch return null;
            for (t.sends, 0..) |*send, send_i| {
                if (send_i > 0) writer.writeByte(',') catch return null;
                writer.print("{{\"idx\":{d},\"destName\":\"", .{send_i}) catch return null;
                protocol.writeJsonString(writer, send.getDestName()) catch return null;
                writer.print("\",\"volume\":{d:.6},\"muted\":{s},\"mode\":{d}}}", .{
                    send.volume,
                    if (send.muted) "true" else "false",
                    send.mode,
                }) catch return null;
            }
            writer.writeAll("]}") catch return null;
        }

        writer.writeAll("]") catch return null;

        // Include metering data if provided
        if (metering) |m| {
            if (m.count > 0) {
                writer.writeAll(",\"meters\":[") catch return null;
                for (0..m.count) |i| {
                    if (i > 0) writer.writeByte(',') catch return null;
                    const meter = &m.meters[i];
                    writer.print(
                        "{{\"trackIdx\":{d},\"peakL\":{d:.4},\"peakR\":{d:.4},\"clipped\":{s}}}",
                        .{
                            meter.track_idx,
                            meter.peak_l,
                            meter.peak_r,
                            if (meter.clipped) "true" else "false",
                        },
                    ) catch return null;
                }
                writer.writeByte(']') catch return null;
            }
        }

        writer.writeAll("}}") catch return null;
        return stream.getWritten();
    }
};

// Track meter data (post-fader output levels)
pub const TrackMeter = struct {
    track_idx: c_int = 0,
    peak_l: f64 = 0.0, // 0.0-1.0+ (1.0 = 0dB), linear amplitude
    peak_r: f64 = 0.0, // 0.0-1.0+
    clipped: bool = false, // Sticky flag: true if peak ever exceeded 0dB
};

// Metering state for all tracks (post-fader output levels for mixer display)
pub const MeteringState = struct {
    meters: [MAX_METERED_TRACKS]TrackMeter = undefined,
    count: usize = 0,

    /// Poll post-fader output meters into an existing MeteringState struct.
    /// Uses unified indexing: 0 = master, 1+ = user tracks
    /// NOTE: Uses output pointer to avoid stack allocation in timer callbacks.
    pub fn pollInto(self: *MeteringState, api: anytype) void {
        self.count = 0; // Reset
        const user_track_count: usize = @intCast(@max(0, api.trackCount()));
        // Total count = master (1) + user tracks
        const total_count = @min(user_track_count + 1, MAX_METERED_TRACKS);

        for (0..total_count) |i| {
            const idx: c_int = @intCast(i);
            // Use unified indexing: 0 = master, 1+ = user tracks
            const track = api.getTrackByUnifiedIdx(idx) orelse continue;

            const peak_l = api.getTrackPeakInfo(track, 0);
            const peak_r = api.getTrackPeakInfo(track, 1);

            // Use peak hold for clip detection (returns dB, so >0 means above 0dB = clipping)
            // The hold is persistent until cleared via meter/clearClip command
            const hold_l = api.getTrackPeakHoldDB(track, 0, false);
            const hold_r = api.getTrackPeakHoldDB(track, 1, false);
            const clipped = hold_l > 0.0 or hold_r > 0.0;

            self.meters[self.count] = .{
                .track_idx = idx,
                .peak_l = peak_l,
                .peak_r = peak_r,
                .clipped = clipped,
            };
            self.count += 1;
        }
    }

    /// Convenience wrapper that returns MeteringState (for tests).
    /// WARNING: Allocates on stack - do NOT use in timer callbacks!
    pub fn poll(api: anytype) MeteringState {
        var state = MeteringState{};
        state.pollInto(api);
        return state;
    }

    /// Check if any meters have data (for change detection)
    pub fn hasData(self: *const MeteringState) bool {
        return self.count > 0;
    }
};

// Tests
test "Track.eql detects changes" {
    const a = Track{ .idx = 0, .volume = 1.0, .mute = false };
    const b = Track{ .idx = 0, .volume = 1.0, .mute = true };
    try std.testing.expect(!a.eql(b));
}

test "Track.eql ignores small float differences" {
    const a = Track{ .idx = 0, .volume = 1.0 };
    const b = Track{ .idx = 0, .volume = 1.0005 };
    try std.testing.expect(a.eql(b));
}

test "State.eql detects track count changes" {
    // Use static buffers for test tracks
    var tracks_a: [2]Track = undefined;
    var tracks_b: [3]Track = undefined;
    const a = State{ .tracks = tracks_a[0..2] };
    const b = State{ .tracks = tracks_b[0..3] };
    try std.testing.expect(!a.eql(&b));
}

test "State.toJson without metering" {
    // Allocate tracks for test
    var tracks_buf: [2]Track = undefined;
    var state = State{ .tracks = &tracks_buf };

    // Track 0 with name "Drums"
    state.tracks[0] = .{ .idx = 0, .color = 16711680, .volume = 1.0, .pan = 0.0, .mute = false, .solo = 0, .rec_arm = false, .rec_mon = 0, .fx_enabled = true };
    state.tracks[0].name[0..5].* = "Drums".*;
    state.tracks[0].name_len = 5;

    // Track 1 with name "Bass"
    state.tracks[1] = .{ .idx = 1, .color = 255, .volume = 0.5, .pan = -0.5, .mute = true, .solo = 1, .rec_arm = true, .rec_mon = 1, .fx_enabled = false };
    state.tracks[1].name[0..4].* = "Bass".*;
    state.tracks[1].name_len = 4;

    var buf: [4096]u8 = undefined;
    const json = state.toJson(&buf, null).?;

    // Verify structure
    try std.testing.expect(std.mem.indexOf(u8, json, "\"event\":\"tracks\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"idx\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"idx\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"Drums\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"Bass\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"color\":16711680") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"color\":255") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"mute\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"recArm\":true") != null);
    // No meters key when metering is null
    try std.testing.expect(std.mem.indexOf(u8, json, "\"meters\"") == null);
}

test "State.toJson with metering" {
    var tracks_buf: [1]Track = undefined;
    var state = State{ .tracks = &tracks_buf };
    state.tracks[0] = .{ .idx = 0, .volume = 1.0, .pan = 0.0, .mute = false, .solo = 0, .rec_arm = true, .rec_mon = 1, .fx_enabled = true };

    var metering = MeteringState{};
    metering.count = 1;
    metering.meters[0] = .{ .track_idx = 0, .peak_l = 0.75, .peak_r = 0.68, .clipped = false };

    var buf: [2048]u8 = undefined;
    const json = state.toJson(&buf, &metering).?;

    // Verify metering data is included
    try std.testing.expect(std.mem.indexOf(u8, json, "\"meters\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"peakL\":0.75") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"peakR\":0.68") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"clipped\":false") != null);
}

test "State.toJson outputs null for corrupt solo/recMon" {
    // When solo or rec_mon is null (corrupt from REAPER),
    // the JSON should contain explicit null values, not fake data
    var tracks_buf: [1]Track = undefined;
    var state = State{ .tracks = &tracks_buf };
    state.tracks[0] = .{
        .idx = 0,
        .volume = 1.0,
        .pan = 0.0,
        .mute = false,
        .solo = null, // Corrupt!
        .rec_arm = false,
        .rec_mon = null, // Corrupt!
        .fx_enabled = true,
    };

    var buf: [2048]u8 = undefined;
    const json = state.toJson(&buf, null).?;

    // Verify null values are output
    try std.testing.expect(std.mem.indexOf(u8, json, "\"solo\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"recMon\":null") != null);
    // Other fields should still be present
    try std.testing.expect(std.mem.indexOf(u8, json, "\"mute\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"fxEnabled\":true") != null);
}

// =============================================================================
// MockBackend-based tests
// =============================================================================

const MockBackend = reaper.MockBackend;

test "poll with MockBackend returns configured values" {
    var mock = MockBackend{
        .track_count = 2, // 2 user tracks + master = 3 total
    };
    // Master track (idx 0)
    mock.tracks[0].setName("MASTER");
    mock.tracks[0].volume = 1.0;
    mock.tracks[0].mute = false;
    mock.master_muted = false;
    mock.master_soloed = false;

    // Track 1 (idx 1)
    mock.tracks[1].setName("Drums");
    mock.tracks[1].volume = 0.8;
    mock.tracks[1].pan = -0.5;
    mock.tracks[1].mute = true;
    mock.tracks[1].solo = 1;
    mock.tracks[1].color = 16711680; // Red

    // Track 2 (idx 2)
    mock.tracks[2].setName("Bass");
    mock.tracks[2].volume = 0.6;
    mock.tracks[2].rec_arm = true;
    mock.tracks[2].rec_mon = 1;

    const state = try State.poll(std.testing.allocator, &mock);
    defer std.testing.allocator.free(state.tracks);

    try std.testing.expectEqual(@as(usize, 3), state.tracks.len);

    // Master track assertions
    try std.testing.expectEqual(@as(c_int, 0), state.tracks[0].idx);
    try std.testing.expectEqualStrings("MASTER", state.tracks[0].getName());

    // Track 1 assertions
    try std.testing.expectEqual(@as(c_int, 1), state.tracks[1].idx);
    try std.testing.expectEqualStrings("Drums", state.tracks[1].getName());
    try std.testing.expect(@abs(state.tracks[1].volume - 0.8) < 0.001);
    try std.testing.expect(@abs(state.tracks[1].pan - (-0.5)) < 0.001);
    try std.testing.expect(state.tracks[1].mute);
    try std.testing.expectEqual(@as(?c_int, 1), state.tracks[1].solo);
    try std.testing.expectEqual(@as(c_int, 16711680), state.tracks[1].color);

    // Track 2 assertions
    try std.testing.expectEqual(@as(c_int, 2), state.tracks[2].idx);
    try std.testing.expectEqualStrings("Bass", state.tracks[2].getName());
    try std.testing.expect(state.tracks[2].rec_arm);
    try std.testing.expectEqual(@as(?c_int, 1), state.tracks[2].rec_mon);
}

test "poll handles solo error gracefully" {
    var mock = MockBackend{
        .inject_solo_error = true,
        .track_count = 1, // 1 user track + master = 2 total
    };
    mock.tracks[0].setName("MASTER");
    mock.tracks[1].setName("Track 1");

    const state = try State.poll(std.testing.allocator, &mock);
    defer std.testing.allocator.free(state.tracks);

    try std.testing.expectEqual(@as(usize, 2), state.tracks.len);
    // Master uses isMasterSoloed, not getTrackSolo, so solo should be set
    try std.testing.expectEqual(@as(?c_int, 0), state.tracks[0].solo);
    // Regular track's solo should be null due to injected error
    try std.testing.expect(state.tracks[1].solo == null);
}

test "poll handles recmon error gracefully" {
    var mock = MockBackend{
        .inject_recmon_error = true,
        .track_count = 1,
    };
    mock.tracks[1].setName("Track 1");
    mock.tracks[1].rec_arm = true;

    const state = try State.poll(std.testing.allocator, &mock);
    defer std.testing.allocator.free(state.tracks);

    try std.testing.expectEqual(@as(usize, 2), state.tracks.len);
    // rec_mon should be null due to injected error
    try std.testing.expect(state.tracks[1].rec_mon == null);
    // Other fields should still work
    try std.testing.expect(state.tracks[1].rec_arm);
}

test "poll handles master track mute/solo specially" {
    var mock = MockBackend{
        .track_count = 0, // Just master track
        .master_muted = true,
        .master_soloed = true,
    };
    mock.tracks[0].setName("MASTER");

    const state = try State.poll(std.testing.allocator, &mock);
    defer std.testing.allocator.free(state.tracks);

    try std.testing.expectEqual(@as(usize, 1), state.tracks.len);
    try std.testing.expect(state.tracks[0].mute);
    try std.testing.expectEqual(@as(?c_int, 1), state.tracks[0].solo);
}

test "poll tracks API calls correctly" {
    var mock = MockBackend{
        .track_count = 1,
    };
    const state = try State.poll(std.testing.allocator, &mock);
    defer std.testing.allocator.free(state.tracks);

    // Verify key API calls were made
    try std.testing.expect(mock.getCallCount(.trackCount) >= 1);
    try std.testing.expect(mock.getCallCount(.getTrackByUnifiedIdx) >= 1);
    try std.testing.expect(mock.getCallCount(.getTrackNameStr) >= 1);
    try std.testing.expect(mock.getCallCount(.getTrackVolume) >= 1);
    try std.testing.expect(mock.getCallCount(.getTrackMute) >= 1);
    try std.testing.expect(mock.getCallCount(.isMasterMuted) >= 1);
}

test "poll respects MAX_TRACKS limit" {
    var mock = MockBackend{
        .track_count = 200, // More than MAX_TRACKS (128)
    };

    const state = try State.poll(std.testing.allocator, &mock);
    defer std.testing.allocator.free(state.tracks);

    // Should cap at MAX_TRACKS (128) = 127 user tracks + 1 master
    try std.testing.expectEqual(MAX_TRACKS, state.tracks.len);
}

test "poll with empty project returns only master" {
    var mock = MockBackend{
        .track_count = 0,
    };
    mock.tracks[0].setName("MASTER");

    const state = try State.poll(std.testing.allocator, &mock);
    defer std.testing.allocator.free(state.tracks);

    try std.testing.expectEqual(@as(usize, 1), state.tracks.len);
    try std.testing.expectEqual(@as(c_int, 0), state.tracks[0].idx);
}

test "State.empty returns empty slice" {
    const state = State.empty();
    try std.testing.expectEqual(@as(usize, 0), state.tracks.len);
}

test "State.count returns slice length" {
    var tracks_buf: [5]Track = undefined;
    const state = State{ .tracks = tracks_buf[0..5] };
    try std.testing.expectEqual(@as(usize, 5), state.count());
}

