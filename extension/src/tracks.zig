const std = @import("std");
const reaper = @import("reaper.zig");

// Maximum tracks to poll (keeps buffer sizes bounded)
pub const MAX_TRACKS: usize = 128;

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
    // Format: {"type":"event","event":"tracks","payload":{"tracks":[...]}}
    pub fn toJson(self: *const State, buf: []u8) ?[]const u8 {
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

        writer.writeAll("]}}") catch return null;
        return stream.getWritten();
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

test "State.toJson" {
    var state = State{};
    state.count = 2;
    state.tracks[0] = .{ .idx = 0, .volume = 1.0, .pan = 0.0, .mute = false, .solo = 0, .rec_arm = false, .rec_mon = 0, .fx_enabled = true };
    state.tracks[1] = .{ .idx = 1, .volume = 0.5, .pan = -0.5, .mute = true, .solo = 1, .rec_arm = true, .rec_mon = 1, .fx_enabled = false };

    var buf: [2048]u8 = undefined;
    const json = state.toJson(&buf).?;

    // Verify structure
    try std.testing.expect(std.mem.indexOf(u8, json, "\"event\":\"tracks\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"idx\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"idx\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"mute\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"recArm\":true") != null);
}
