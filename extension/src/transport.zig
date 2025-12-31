const std = @import("std");
const reaper = @import("reaper.zig");

// Transport state snapshot
// Note: project_length, repeat, metronome, bar_offset moved to project.zig (low-frequency project-level settings)
pub const State = struct {
    play_state: c_int = 0,
    play_position: f64 = 0,
    cursor_position: f64 = 0,
    bpm: f64 = 120,
    time_sig_num: f64 = 4,
    time_sig_denom: c_int = 4,
    time_sel_start: f64 = 0,
    time_sel_end: f64 = 0,
    // Position in bar.beat format (for display)
    position_bar: c_int = 1,
    position_beat: f64 = 1.0, // Beat within bar (1-based, fractional = ticks)
    // bar_offset needed here for positionBeats display calculation
    bar_offset: c_int = 0,
    // Number of tempo/time sig markers (0 = fixed tempo project)
    tempo_marker_count: c_int = 0,
    // Transport sync fields (for client-side beat prediction)
    server_time_ms: f64 = 0, // High-precision timestamp in ms
    full_beat_position: f64 = 0, // Raw beat position (total beats from project start)

    // Comparison with tolerance for change detection (includes position)
    pub fn eql(self: State, other: State) bool {
        if (!self.stateOnlyEql(other)) return false;

        // Position changes: check cursor when stopped, play_position when playing
        if (self.play_state == 0) {
            // Stopped: check cursor position
            if (!floatEql(self.cursor_position, other.cursor_position)) return false;
        } else {
            // Playing/recording: check play position (updates ~30x/sec during playback)
            if (!floatEql(self.play_position, other.play_position)) return false;
        }
        return true;
    }

    // Compare non-position fields only (for detecting state changes vs position-only changes)
    // Used to decide: full transport event vs lightweight tick
    pub fn stateOnlyEql(self: State, other: State) bool {
        if (self.play_state != other.play_state) return false;
        if (!floatEql(self.bpm, other.bpm)) return false;
        if (self.time_sig_num != other.time_sig_num) return false;
        if (self.time_sig_denom != other.time_sig_denom) return false;
        if (!floatEql(self.time_sel_start, other.time_sel_start)) return false;
        if (!floatEql(self.time_sel_end, other.time_sel_end)) return false;
        if (self.bar_offset != other.bar_offset) return false;
        if (self.tempo_marker_count != other.tempo_marker_count) return false;
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
        // Capture server timestamp first (most accurate timing)
        const server_time_ms = api.timePreciseMs();

        const sel = api.timeSelection();
        const play_state = api.playState();
        const play_pos = api.playPosition();
        const cursor_pos = api.cursorPosition();

        // Get current position for bar.beat display and position-aware tempo
        const current_pos = if (play_state & 1 != 0) play_pos else cursor_pos;
        const beats_info = api.timeToBeats(current_pos);

        // Use position-aware tempo (handles tempo markers, unlike timeSignature())
        const tempo = api.getTempoAtPosition(current_pos);

        return .{
            .play_state = play_state,
            .play_position = play_pos,
            .cursor_position = cursor_pos,
            .bpm = tempo.bpm,
            .time_sig_num = @floatFromInt(tempo.timesig_num),
            .time_sig_denom = tempo.timesig_denom,
            .time_sel_start = sel.start,
            .time_sel_end = sel.end,
            .bar_offset = api.getBarOffset(), // Needed for positionBeats display
            .position_bar = beats_info.measures,
            .position_beat = beats_info.beats_in_measure + 1.0, // Convert 0-based to 1-based
            .tempo_marker_count = api.tempoMarkerCount(),
            // Transport sync fields
            .server_time_ms = server_time_ms,
            .full_beat_position = beats_info.beats,
        };
    }

    // Truncate to 3 decimal places (matching REAPER's display behavior)
    fn truncateMs(val: f64) f64 {
        return @trunc(val * 1000.0) / 1000.0;
    }

    // Build JSON event for this state
    pub fn toJson(self: State, buf: []u8) ?[]const u8 {
        // Format bar.beat.ticks (e.g., "12.3.45" or "-4.1.00")
        // Apply bar_offset to get display bar number (REAPER's bar 1 at time 0 + offset)
        var display_bar = self.position_bar + self.bar_offset;

        // Round position_beat to nearest tick to match REAPER's display behavior
        // This handles cases like 4.999 → 5.00 (REAPER rounds for display)
        // Work with scaled integer to avoid floating-point precision issues:
        // e.g., 6.76 as float can become 0.7599999998 after mod, giving ticks=75 not 76
        const scaled_beat: u32 = @intFromFloat(@round(self.position_beat * 100.0));

        // Extract beat and ticks using integer arithmetic (no precision loss)
        var beat_int: u32 = @max(1, scaled_beat / 100);
        const ticks: u32 = scaled_beat % 100;

        // Handle beat overflow (e.g., beat 7 in 6/8 time → bar + 1, beat 1)
        const beats_per_bar = safeTimeSigNum(self.time_sig_num);
        if (beat_int > beats_per_bar) {
            beat_int = 1;
            display_bar += 1;
        }

        // Truncate display values to 3 decimal places to match REAPER's display
        // Time selection uses full precision (15 decimals) to match REAPER's HTTP API
        const position = truncateMs(self.currentPosition());
        const cursor_position = truncateMs(self.cursor_position);

        const result = std.fmt.bufPrint(buf,
            \\{{"type":"event","event":"transport","payload":{{"t":{d:.3},"b":{d:.6},"playState":{d},"position":{d:.3},"positionBeats":"{d}.{d}.{d:0>2}","cursorPosition":{d:.3},"bpm":{d:.2},"timeSignature":{{"numerator":{d},"denominator":{d}}},"timeSelection":{{"start":{d:.15},"end":{d:.15}}},"tempoMarkerCount":{d}}}}}
        , .{
            self.server_time_ms,
            self.full_beat_position,
            self.play_state,
            position,
            display_bar,
            beat_int,
            ticks,
            cursor_position,
            self.bpm,
            safeTimeSigNum(self.time_sig_num),
            self.time_sig_denom,
            self.time_sel_start,
            self.time_sel_end,
            self.tempo_marker_count,
        }) catch return null;

        return result;
    }

    // Build lightweight tick JSON (position-only, ~65 bytes vs ~350 for full)
    // Used during playback when only position has changed
    pub fn toTickJson(self: State, buf: []u8) ?[]const u8 {
        const result = std.fmt.bufPrint(buf,
            \\{{"type":"event","event":"tt","payload":{{"t":{d:.3},"b":{d:.6}}}}}
        , .{
            self.server_time_ms,
            self.full_beat_position,
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

test "State.eql checks play_position during playback" {
    const a = State{ .play_state = 1, .play_position = 0.0 };
    const b = State{ .play_state = 1, .play_position = 5.0 };
    try std.testing.expect(!a.eql(b)); // Different play positions = not equal
}

test "State.eql ignores cursor during playback" {
    // Cursor changes don't matter when playing - only play_position does
    const a = State{ .play_state = 1, .cursor_position = 0.0, .play_position = 10.0 };
    const b = State{ .play_state = 1, .cursor_position = 5.0, .play_position = 10.0 };
    try std.testing.expect(a.eql(b)); // Same play_position = equal despite cursor diff
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
        .time_sig_denom = 4,
        .time_sel_start = 0,
        .time_sel_end = 30.0,
        .bar_offset = -4,
        .position_bar = 12,
        .position_beat = 3.45, // Beat 3, 45% through
    };

    var buf: [512]u8 = undefined;
    const json = state.toJson(&buf).?;

    // Verify it's valid-ish JSON with expected fields
    try std.testing.expect(std.mem.indexOf(u8, json, "\"playState\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"position\":10.5") != null);
    // Bar 12 + offset -4 = display bar 8
    try std.testing.expect(std.mem.indexOf(u8, json, "\"positionBeats\":\"8.3.45\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"bpm\":120") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"denominator\":4") != null);
    // Note: repeat, metronome, projectLength, barOffset now in project event
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

test "beat rounding matches REAPER display" {
    // When position_beat is 4.999 (beat 4, 99.9% through), it should round to 5.00
    // This matches REAPER's display behavior
    const state = State{
        .play_state = 1,
        .play_position = 17.333,
        .cursor_position = 17.333,
        .bpm = 90.0,
        .time_sig_num = 6, // 6/8 time
        .time_sig_denom = 8,
        .bar_offset = -4,
        .position_bar = 8, // Bar 8 in REAPER (display: 8 + (-4) = 4)
        .position_beat = 4.999, // Almost beat 5 - should round up
    };

    var buf: [512]u8 = undefined;
    const json = state.toJson(&buf).?;

    // Should show "4.5.00" not "4.4.99"
    try std.testing.expect(std.mem.indexOf(u8, json, "\"positionBeats\":\"4.5.00\"") != null);
}

test "beat overflow carries to next bar" {
    // When rounded beat would overflow the time signature (e.g., beat 5 in 4/4)
    const state = State{
        .play_state = 1,
        .play_position = 10.0,
        .cursor_position = 10.0,
        .bpm = 120.0,
        .time_sig_num = 4, // 4/4 time
        .time_sig_denom = 4,
        .bar_offset = 0,
        .position_bar = 5, // Bar 5
        .position_beat = 4.995, // Rounds to 5.00, which overflows to bar 6 beat 1
    };

    var buf: [512]u8 = undefined;
    const json = state.toJson(&buf).?;

    // Beat 5 in 4/4 time should become bar 6, beat 1
    try std.testing.expect(std.mem.indexOf(u8, json, "\"positionBeats\":\"6.1.00\"") != null);
}

test "fractional ticks preserved when not near boundary" {
    // Normal case: 3.45 should display as 3.45
    const state = State{
        .play_state = 1,
        .play_position = 5.0,
        .cursor_position = 5.0,
        .bpm = 120.0,
        .time_sig_num = 4,
        .time_sig_denom = 4,
        .bar_offset = 0,
        .position_bar = 2,
        .position_beat = 3.45,
    };

    var buf: [512]u8 = undefined;
    const json = state.toJson(&buf).?;

    try std.testing.expect(std.mem.indexOf(u8, json, "\"positionBeats\":\"2.3.45\"") != null);
}

test "ticks round correctly at 0.7565" {
    // Regression test for exact user scenario:
    // REAPER beats_in_measure = 5.756500000009879, we add 1.0 → 6.7565
    // Should display as 6.6.76, not 6.6.75
    const state = State{
        .play_state = 2,
        .play_position = 21.918833,
        .cursor_position = 21.918833,
        .bpm = 180.0,
        .time_sig_num = 6,
        .time_sig_denom = 8,
        .bar_offset = -5,
        .position_bar = 11, // 11 + (-5) = 6
        .position_beat = 6.756500000009879, // beats_in_measure + 1.0
    };

    var buf: [512]u8 = undefined;
    const json = state.toJson(&buf).?;

    // Must show 6.6.76 not 6.6.75
    try std.testing.expect(std.mem.indexOf(u8, json, "\"positionBeats\":\"6.6.76\"") != null);
}

test "stateOnlyEql ignores position changes" {
    // Same state, different position - should be equal
    const a = State{ .play_state = 1, .play_position = 0.0, .bpm = 120.0 };
    const b = State{ .play_state = 1, .play_position = 10.0, .bpm = 120.0 };
    try std.testing.expect(a.stateOnlyEql(b)); // Position ignored
    try std.testing.expect(!a.eql(b)); // But full eql sees the difference
}

test "stateOnlyEql detects state changes" {
    const a = State{ .play_state = 1, .bpm = 120.0 };
    const b = State{ .play_state = 0, .bpm = 120.0 };
    try std.testing.expect(!a.stateOnlyEql(b)); // Different play state

    const c = State{ .play_state = 1, .bpm = 120.0 };
    const d = State{ .play_state = 1, .bpm = 130.0 };
    try std.testing.expect(!c.stateOnlyEql(d)); // Different BPM
}

test "toTickJson produces minimal format" {
    const state = State{
        .server_time_ms = 1234567890.123,
        .full_beat_position = 45.678,
        .play_state = 1,
        .bpm = 120.0,
    };

    var buf: [128]u8 = undefined;
    const json = state.toTickJson(&buf).?;

    // Verify minimal format
    try std.testing.expect(std.mem.indexOf(u8, json, "\"event\":\"tt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"t\":1234567890.123") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"b\":45.678") != null);

    // Should NOT contain full transport fields
    try std.testing.expect(std.mem.indexOf(u8, json, "playState") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "bpm") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "position") == null);

    // Verify it's compact (less than 80 bytes)
    try std.testing.expect(json.len < 80);
}
