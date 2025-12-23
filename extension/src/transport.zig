const std = @import("std");
const reaper = @import("reaper.zig");

// Transport state snapshot
pub const State = struct {
    play_state: c_int = 0,
    play_position: f64 = 0,
    cursor_position: f64 = 0,
    bpm: f64 = 120,
    time_sig_num: f64 = 4,
    time_sel_start: f64 = 0,
    time_sel_end: f64 = 0,

    // Comparison with tolerance for change detection
    pub fn eql(self: State, other: State) bool {
        if (self.play_state != other.play_state) return false;
        if (!floatEql(self.bpm, other.bpm)) return false;
        if (self.time_sig_num != other.time_sig_num) return false;
        if (!floatEql(self.time_sel_start, other.time_sel_start)) return false;
        if (!floatEql(self.time_sel_end, other.time_sel_end)) return false;

        // Position changes frequently during playback - only check when stopped
        if (self.play_state == 0) {
            if (!floatEql(self.cursor_position, other.cursor_position)) return false;
        }
        return true;
    }

    fn floatEql(a: f64, b: f64) bool {
        return @abs(a - b) <= 0.001;
    }

    // Safe conversion for time signature numerator - clamps to valid range
    // Prevents panic on NaN/Inf from corrupt project data
    fn safeTimeSigNum(val: f64) u32 {
        if (std.math.isNan(val) or std.math.isInf(val)) return 4;
        const clamped = @max(1.0, @min(32.0, val));
        return @intFromFloat(clamped);
    }

    // Get current position based on play state
    pub fn currentPosition(self: State) f64 {
        // If playing (bit 0 set), use play position, otherwise cursor
        return if (self.play_state & 1 != 0) self.play_position else self.cursor_position;
    }

    // Poll current state from REAPER
    pub fn poll(api: *const reaper.Api) State {
        const ts = api.timeSignature();
        const sel = api.timeSelection();

        return .{
            .play_state = api.playState(),
            .play_position = api.playPosition(),
            .cursor_position = api.cursorPosition(),
            .bpm = ts.bpm,
            .time_sig_num = ts.num,
            .time_sel_start = sel.start,
            .time_sel_end = sel.end,
        };
    }

    // Build JSON event for this state
    pub fn toJson(self: State, buf: []u8) ?[]const u8 {
        const result = std.fmt.bufPrint(buf,
            \\{{"type":"event","event":"transport","payload":{{"playState":{d},"position":{d:.3},"cursorPosition":{d:.3},"bpm":{d:.2},"timeSignature":{{"numerator":{d},"denominator":4}},"timeSelection":{{"start":{d:.3},"end":{d:.3}}}}}}}
        , .{
            self.play_state,
            self.currentPosition(),
            self.cursor_position,
            self.bpm,
            safeTimeSigNum(self.time_sig_num),
            self.time_sel_start,
            self.time_sel_end,
        }) catch return null;

        return result;
    }
};

// Play state values (from REAPER)
pub const PlayState = struct {
    pub const STOPPED: c_int = 0;
    pub const PLAYING: c_int = 1;
    pub const PAUSED: c_int = 2;
    pub const RECORDING: c_int = 5;
    pub const RECORD_PAUSED: c_int = 6;

    pub fn isPlaying(state: c_int) bool {
        return state & 1 != 0;
    }

    pub fn isRecording(state: c_int) bool {
        return state & 4 != 0;
    }

    pub fn isPaused(state: c_int) bool {
        return state & 2 != 0;
    }
};

// Tests - these can run without REAPER
test "State.eql detects play state changes" {
    const a = State{ .play_state = 0 };
    const b = State{ .play_state = 1 };
    try std.testing.expect(!a.eql(b));
}

test "State.eql ignores small float differences" {
    const a = State{ .bpm = 120.0 };
    const b = State{ .bpm = 120.0005 };
    try std.testing.expect(a.eql(b));
}

test "State.eql detects significant bpm changes" {
    const a = State{ .bpm = 120.0 };
    const b = State{ .bpm = 121.0 };
    try std.testing.expect(!a.eql(b));
}

test "State.eql ignores cursor during playback" {
    const a = State{ .play_state = 1, .cursor_position = 0.0 };
    const b = State{ .play_state = 1, .cursor_position = 5.0 };
    try std.testing.expect(a.eql(b));
}

test "State.eql checks cursor when stopped" {
    const a = State{ .play_state = 0, .cursor_position = 0.0 };
    const b = State{ .play_state = 0, .cursor_position = 5.0 };
    try std.testing.expect(!a.eql(b));
}

test "State.currentPosition" {
    const stopped = State{ .play_state = 0, .play_position = 10.0, .cursor_position = 5.0 };
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), stopped.currentPosition(), 0.001);

    const playing = State{ .play_state = 1, .play_position = 10.0, .cursor_position = 5.0 };
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), playing.currentPosition(), 0.001);
}

test "State.toJson" {
    const state = State{
        .play_state = 1,
        .play_position = 10.5,
        .cursor_position = 5.0,
        .bpm = 120.0,
        .time_sig_num = 4,
        .time_sel_start = 0,
        .time_sel_end = 30.0,
    };

    var buf: [512]u8 = undefined;
    const json = state.toJson(&buf).?;

    // Verify it's valid-ish JSON with expected fields
    try std.testing.expect(std.mem.indexOf(u8, json, "\"playState\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"position\":10.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"bpm\":120") != null);
}

test "PlayState helpers" {
    try std.testing.expect(!PlayState.isPlaying(0));
    try std.testing.expect(PlayState.isPlaying(1));
    try std.testing.expect(PlayState.isPlaying(5)); // recording includes playing bit
    try std.testing.expect(PlayState.isRecording(5));
    try std.testing.expect(!PlayState.isRecording(1));
}

test "safeTimeSigNum handles edge cases" {
    // Normal values
    try std.testing.expectEqual(@as(u32, 4), State.safeTimeSigNum(4.0));
    try std.testing.expectEqual(@as(u32, 3), State.safeTimeSigNum(3.0));

    // Clamping
    try std.testing.expectEqual(@as(u32, 1), State.safeTimeSigNum(0.0));
    try std.testing.expectEqual(@as(u32, 1), State.safeTimeSigNum(-5.0));
    try std.testing.expectEqual(@as(u32, 32), State.safeTimeSigNum(100.0));

    // NaN and Inf return default of 4
    try std.testing.expectEqual(@as(u32, 4), State.safeTimeSigNum(std.math.nan(f64)));
    try std.testing.expectEqual(@as(u32, 4), State.safeTimeSigNum(std.math.inf(f64)));
    try std.testing.expectEqual(@as(u32, 4), State.safeTimeSigNum(-std.math.inf(f64)));
}
