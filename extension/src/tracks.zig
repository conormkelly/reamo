const std = @import("std");
const reaper = @import("reaper.zig");

// Maximum tracks to poll (keeps buffer sizes bounded)
pub const MAX_TRACKS: usize = 128;

// Maximum armed tracks to meter (keeps polling bounded)
pub const MAX_METERED_TRACKS: usize = 16;

// Single track state
pub const Track = struct {
    idx: c_int = 0,
    volume: f64 = 1.0, // 0..inf (1.0 = 0dB)
    pan: f64 = 0.0, // -1.0..1.0
    mute: bool = false,
    solo: c_int = 0, // 0=off, 1=solo, 2=solo in place, etc.
    rec_arm: bool = false,
    rec_mon: c_int = 0, // 0=off, 1=normal, 2=not when playing
    fx_enabled: bool = true,

    pub fn eql(self: Track, other: Track) bool {
        if (self.idx != other.idx) return false;
        if (!floatEql(self.volume, other.volume)) return false;
        if (!floatEql(self.pan, other.pan)) return false;
        if (self.mute != other.mute) return false;
        if (self.solo != other.solo) return false;
        if (self.rec_arm != other.rec_arm) return false;
        if (self.rec_mon != other.rec_mon) return false;
        if (self.fx_enabled != other.fx_enabled) return false;
        return true;
    }

    fn floatEql(a: f64, b: f64) bool {
        return @abs(a - b) <= 0.001;
    }
};

// Track state snapshot (all tracks)
pub const State = struct {
    tracks: [MAX_TRACKS]Track = undefined,
    count: usize = 0,

    // Compare for change detection
    pub fn eql(self: *const State, other: *const State) bool {
        if (self.count != other.count) return false;
        for (0..self.count) |i| {
            if (!self.tracks[i].eql(other.tracks[i])) return false;
        }
        return true;
    }

    // Poll current state from REAPER
    pub fn poll(api: *const reaper.Api) State {
        var state = State{};
        const track_count: usize = @intCast(@max(0, api.trackCount()));
        state.count = @min(track_count, MAX_TRACKS);

        for (0..state.count) |i| {
            const idx: c_int = @intCast(i);
            if (api.getTrackByIdx(idx)) |track| {
                state.tracks[i] = .{
                    .idx = idx,
                    .volume = api.getTrackVolume(track),
                    .pan = api.getTrackPan(track),
                    .mute = api.getTrackMute(track),
                    .solo = api.getTrackSolo(track),
                    .rec_arm = api.getTrackRecArm(track),
                    .rec_mon = api.getTrackRecMon(track),
                    .fx_enabled = api.getTrackFxEnabled(track),
                };
            }
        }
        return state;
    }

    // Build JSON event for tracks state
    // Format: {"type":"event","event":"tracks","payload":{"tracks":[...],"meters":[...]}}
    pub fn toJson(self: *const State, buf: []u8, metering: ?*const MeteringState) ?[]const u8 {
        var stream = std.io.fixedBufferStream(buf);
        const writer = stream.writer();

        writer.writeAll("{\"type\":\"event\",\"event\":\"tracks\",\"payload\":{\"tracks\":[") catch return null;

        for (0..self.count) |i| {
            if (i > 0) writer.writeByte(',') catch return null;
            const t = &self.tracks[i];
            writer.print(
                "{{\"idx\":{d},\"volume\":{d:.4},\"pan\":{d:.3},\"mute\":{s},\"solo\":{d},\"recArm\":{s},\"recMon\":{d},\"fxEnabled\":{s}}}",
                .{
                    t.idx,
                    t.volume,
                    t.pan,
                    if (t.mute) "true" else "false",
                    t.solo,
                    if (t.rec_arm) "true" else "false",
                    t.rec_mon,
                    if (t.fx_enabled) "true" else "false",
                },
            ) catch return null;
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

// Input meter for a single track
pub const InputMeter = struct {
    track_idx: c_int = 0,
    peak_l: f64 = 0.0, // 0.0-1.0+ (1.0 = 0dB)
    peak_r: f64 = 0.0, // 0.0-1.0+
    clipped: bool = false, // Sticky flag: true if peak ever exceeded 1.0
};

// Metering state for armed+monitoring tracks
pub const MeteringState = struct {
    meters: [MAX_METERED_TRACKS]InputMeter = undefined,
    count: usize = 0,

    /// Poll input meters for armed+monitoring tracks only
    /// NOTE: Currently runs at ~30ms with track state. May separate to
    /// higher frequency (10-15ms) if UI smoothness requires it.
    pub fn poll(api: *const reaper.Api) MeteringState {
        var state = MeteringState{};
        const track_count: usize = @intCast(@max(0, api.trackCount()));

        for (0..track_count) |i| {
            if (state.count >= MAX_METERED_TRACKS) break;

            const idx: c_int = @intCast(i);
            const track = api.getTrackByIdx(idx) orelse continue;

            // Only meter tracks that are: record armed AND input monitoring enabled
            if (!api.getTrackRecArm(track)) continue;
            if (api.getTrackRecMon(track) == 0) continue;

            const peak_l = api.getTrackPeakInfo(track, 0);
            const peak_r = api.getTrackPeakInfo(track, 1);

            // Use peak hold for clip detection (returns dB×0.01, so >0 means above 0dB = clipping)
            // The hold is persistent until cleared via meter/clearClip command
            const hold_l = api.getTrackPeakHoldDB(track, 0, false);
            const hold_r = api.getTrackPeakHoldDB(track, 1, false);
            const clipped = hold_l > 0.0 or hold_r > 0.0;

            state.meters[state.count] = .{
                .track_idx = idx,
                .peak_l = peak_l,
                .peak_r = peak_r,
                .clipped = clipped,
            };
            state.count += 1;
        }
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
    var a = State{};
    var b = State{};
    a.count = 2;
    b.count = 3;
    try std.testing.expect(!a.eql(&b));
}

test "State.toJson without metering" {
    var state = State{};
    state.count = 2;
    state.tracks[0] = .{ .idx = 0, .volume = 1.0, .pan = 0.0, .mute = false, .solo = 0, .rec_arm = false, .rec_mon = 0, .fx_enabled = true };
    state.tracks[1] = .{ .idx = 1, .volume = 0.5, .pan = -0.5, .mute = true, .solo = 1, .rec_arm = true, .rec_mon = 1, .fx_enabled = false };

    var buf: [2048]u8 = undefined;
    const json = state.toJson(&buf, null).?;

    // Verify structure
    try std.testing.expect(std.mem.indexOf(u8, json, "\"event\":\"tracks\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"idx\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"idx\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"mute\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"recArm\":true") != null);
    // No meters key when metering is null
    try std.testing.expect(std.mem.indexOf(u8, json, "\"meters\"") == null);
}

test "State.toJson with metering" {
    var state = State{};
    state.count = 1;
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

