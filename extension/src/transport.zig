const std = @import("std");
const reaper = @import("reaper.zig");
const ffi = @import("ffi.zig");

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
    // Beat within bar (1-based, fractional = ticks). Null if REAPER returned corrupt data.
    position_beat: ?f64 = 1.0,
    // bar_offset needed here for positionBeats display calculation
    bar_offset: c_int = 0,
    // Number of tempo/time sig markers (0 = fixed tempo project)
    tempo_marker_count: c_int = 0,
    // Transport sync fields (for client-side beat prediction)
    server_time_ms: f64 = 0, // High-precision timestamp in ms
    // Raw beat position (total beats from project start). Null if corrupt.
    full_beat_position: ?f64 = 0,

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

    // Normalized beat position result
    const NormalizedBeat = struct {
        bar: c_int,
        beat: f64, // 0-indexed, normalized to [0, beats_per_bar)
    };

    // Normalize REAPER's beats_in_measure into valid range [0, beats_per_bar)
    // REAPER returns negative beats_in_measure during pre-roll (before project start)
    // using ceiling-style division. We normalize to get displayable bar.beat values.
    // Returns null if input is NaN/Inf or beats_per_bar is invalid.
    fn normalizeBeats(measures: c_int, beats_in_measure: f64, beats_per_bar: c_int) ?NormalizedBeat {
        if (!ffi.isFinite(beats_in_measure)) return null;
        if (beats_per_bar <= 0) return null;

        var bar = measures;
        var beat = beats_in_measure;
        const bpb: f64 = @floatFromInt(beats_per_bar);

        // Normalize negative beats_in_measure into [0, bpb)
        while (beat < 0.0) {
            bar -= 1;
            beat += bpb;
        }
        // Also handle overflow (beat >= beats_per_bar)
        while (beat >= bpb) {
            bar += 1;
            beat -= bpb;
        }

        return .{ .bar = bar, .beat = beat };
    }

    // Get current position based on play state
    pub fn currentPosition(self: State) f64 {
        // If playing (bit 0 set), use play position, otherwise cursor
        return if (self.play_state & 1 != 0) self.play_position else self.cursor_position;
    }

    /// Poll current state from REAPER.
    /// Accepts any backend type (RealBackend, MockBackend, or test doubles).
    pub fn poll(api: anytype) State {
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

        // Normalize beat data from REAPER
        // REAPER returns negative beats_in_measure during pre-roll (before project start)
        // We normalize to get valid bar.beat values for display
        const normalized = normalizeBeats(
            beats_info.measures,
            beats_info.beats_in_measure,
            tempo.timesig_num,
        );

        // Convert normalized 0-indexed beat to 1-indexed for display
        // If normalization failed (NaN/Inf input), position_beat is null
        const position_bar: c_int = if (normalized) |n| n.bar else beats_info.measures;
        const position_beat: ?f64 = if (normalized) |n| n.beat + 1.0 else null;

        // full_beat_position can be negative (before project start) - that's valid for sync purposes
        // but must be finite
        const full_beat_position: ?f64 = if (ffi.isFinite(beats_info.beats))
            beats_info.beats
        else
            null;

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
            .position_bar = position_bar,
            .position_beat = position_beat,
            .tempo_marker_count = api.tempoMarkerCount(),
            // Transport sync fields
            .server_time_ms = server_time_ms,
            .full_beat_position = full_beat_position,
        };
    }

    // Truncate to 3 decimal places (matching REAPER's display behavior)
    fn truncateMs(val: f64) f64 {
        return @trunc(val * 1000.0) / 1000.0;
    }

    // Build JSON event for this state
    pub fn toJson(self: State, buf: []u8) ?[]const u8 {
        var stream = std.io.fixedBufferStream(buf);
        const writer = stream.writer();

        // Truncate display values to 3 decimal places to match REAPER's display
        const position = truncateMs(self.currentPosition());
        const cursor_position = truncateMs(self.cursor_position);

        // Start building JSON - use regular strings with escape sequences
        writer.print("{{\"type\":\"event\",\"event\":\"transport\",\"payload\":{{\"t\":{d:.3},", .{self.server_time_ms}) catch return null;

        // full_beat_position - null if corrupt
        if (self.full_beat_position) |b| {
            writer.print("\"b\":{d:.6},", .{b}) catch return null;
        } else {
            writer.writeAll("\"b\":null,") catch return null;
        }

        writer.print("\"playState\":{d},\"position\":{d:.3},", .{ self.play_state, position }) catch return null;

        // positionBeats - null if corrupt, otherwise format as "bar.beat.ticks"
        if (self.position_beat) |pos_beat| {
            // Format bar.beat.ticks (e.g., "12.3.45" or "-4.1.00")
            var display_bar = self.position_bar + self.bar_offset;

            // Round position_beat to nearest tick to match REAPER's display behavior
            // Safe: poll() normalizes pos_beat to [1.0, beats_per_bar + 1.0)
            const scaled_beat: u32 = @intFromFloat(@round(pos_beat * 100.0));
            var beat_int: u32 = @max(1, scaled_beat / 100);
            const ticks: u32 = scaled_beat % 100;

            // Handle beat overflow from rounding (e.g., 4.995 rounds to 5.00 in 4/4)
            const beats_per_bar = safeTimeSigNum(self.time_sig_num);
            if (beat_int > beats_per_bar) {
                beat_int = 1;
                display_bar += 1;
            }

            writer.print("\"positionBeats\":\"{d}.{d}.{d:0>2}\",", .{ display_bar, beat_int, ticks }) catch return null;
        } else {
            writer.writeAll("\"positionBeats\":null,") catch return null;
        }

        // Remaining fields
        writer.print("\"cursorPosition\":{d:.3},\"bpm\":{d:.2},\"timeSignature\":{{\"numerator\":{d},\"denominator\":{d}}},\"timeSelection\":{{\"start\":{d:.15},\"end\":{d:.15}}},\"tempoMarkerCount\":{d}}}}}", .{
            cursor_position,
            self.bpm,
            safeTimeSigNum(self.time_sig_num),
            self.time_sig_denom,
            self.time_sel_start,
            self.time_sel_end,
            self.tempo_marker_count,
        }) catch return null;

        return stream.getWritten();
    }

    // Allocator-based version - returns owned slice from allocator
    pub fn toJsonAlloc(self: State, allocator: std.mem.Allocator) ![]const u8 {
        var buf: [512]u8 = undefined;
        const json = self.toJson(&buf) orelse return error.JsonSerializationFailed;
        return allocator.dupe(u8, json);
    }

    // Build lightweight tick JSON (~140 bytes vs ~350 for full)
    // Used during playback when only position has changed
    // Enhanced format includes position (seconds), BPM and time sig
    pub fn toTickJson(self: State, buf: []u8) ?[]const u8 {
        var stream = std.io.fixedBufferStream(buf);
        const writer = stream.writer();

        // Include position (seconds) for accurate time display after seeks
        const position = truncateMs(self.currentPosition());
        writer.print("{{\"type\":\"event\",\"event\":\"tt\",\"payload\":{{\"p\":{d:.3},\"t\":{d:.3},", .{ position, self.server_time_ms }) catch return null;

        // full_beat_position - null if corrupt
        if (self.full_beat_position) |b| {
            writer.print("\"b\":{d:.6},", .{b}) catch return null;
        } else {
            writer.writeAll("\"b\":null,") catch return null;
        }

        writer.print("\"bpm\":{d:.2},\"ts\":[{d},{d}],", .{ self.bpm, safeTimeSigNum(self.time_sig_num), self.time_sig_denom }) catch return null;

        // bbt (bar.beat.ticks) - null if corrupt
        if (self.position_beat) |pos_beat| {
            var display_bar = self.position_bar + self.bar_offset;
            // Safe: poll() normalizes pos_beat to [1.0, beats_per_bar + 1.0)
            const scaled_beat: u32 = @intFromFloat(@round(pos_beat * 100.0));
            var beat_int: u32 = @max(1, scaled_beat / 100);
            const ticks: u32 = scaled_beat % 100;

            // Handle beat overflow from rounding (e.g., 4.995 rounds to 5.00 in 4/4)
            const beats_per_bar = safeTimeSigNum(self.time_sig_num);
            if (beat_int > beats_per_bar) {
                beat_int = 1;
                display_bar += 1;
            }

            writer.print("\"bbt\":\"{d}.{d}.{d:0>2}\"}}}}", .{ display_bar, beat_int, ticks }) catch return null;
        } else {
            writer.writeAll("\"bbt\":null}}}}") catch return null;
        }

        return stream.getWritten();
    }

    // Allocator-based version of tick JSON
    pub fn toTickJsonAlloc(self: State, allocator: std.mem.Allocator) ![]const u8 {
        var buf: [256]u8 = undefined;
        const json = self.toTickJson(&buf) orelse return error.JsonSerializationFailed;
        return allocator.dupe(u8, json);
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

test "toTickJson produces enhanced tick format" {
    const state = State{
        .server_time_ms = 1234567890.123,
        .full_beat_position = 45.678,
        .play_state = 1,
        .play_position = 22.875, // Position in seconds
        .bpm = 127.5,
        .time_sig_num = 6,
        .time_sig_denom = 8,
        .position_bar = 16,
        .position_beat = 3.48,
        .bar_offset = -4,
    };

    var buf: [256]u8 = undefined;
    const json = state.toTickJson(&buf).?;

    // Verify enhanced tick format fields
    try std.testing.expect(std.mem.indexOf(u8, json, "\"event\":\"tt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"p\":22.875") != null); // Position in seconds
    try std.testing.expect(std.mem.indexOf(u8, json, "\"t\":1234567890.123") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"b\":45.678") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"bpm\":127.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ts\":[6,8]") != null);
    // Bar 16 + offset -4 = 12, beat 3, ticks 48
    try std.testing.expect(std.mem.indexOf(u8, json, "\"bbt\":\"12.3.48\"") != null);

    // Should NOT contain full transport fields
    try std.testing.expect(std.mem.indexOf(u8, json, "playState") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "timeSelection") == null);

    // Verify it's reasonably compact (~140 bytes with position field)
    try std.testing.expect(json.len < 170);
}

test "toJson outputs null for corrupt beat data" {
    // When position_beat or full_beat_position is null (corrupt from REAPER),
    // the JSON should contain explicit null values, not fake data
    const state = State{
        .play_state = 1,
        .play_position = 10.5,
        .cursor_position = 5.0,
        .bpm = 120.0,
        .time_sig_num = 4,
        .time_sig_denom = 4,
        .bar_offset = 0,
        .position_bar = 5,
        .position_beat = null, // Corrupt!
        .full_beat_position = null, // Corrupt!
    };

    var buf: [512]u8 = undefined;
    const json = state.toJson(&buf).?;

    // Verify null values are output
    try std.testing.expect(std.mem.indexOf(u8, json, "\"positionBeats\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"b\":null") != null);
    // Other fields should still be present
    try std.testing.expect(std.mem.indexOf(u8, json, "\"playState\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"bpm\":120") != null);
}

test "toTickJson outputs null for corrupt beat data" {
    const state = State{
        .server_time_ms = 1234567890.123,
        .full_beat_position = null, // Corrupt!
        .play_state = 1,
        .bpm = 120.0,
        .time_sig_num = 4,
        .time_sig_denom = 4,
        .position_bar = 5,
        .position_beat = null, // Corrupt!
        .bar_offset = 0,
    };

    var buf: [256]u8 = undefined;
    const json = state.toTickJson(&buf).?;

    // Verify null values are output
    try std.testing.expect(std.mem.indexOf(u8, json, "\"b\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"bbt\":null") != null);
    // Other fields should still be present
    try std.testing.expect(std.mem.indexOf(u8, json, "\"bpm\":120") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ts\":[4,4]") != null);
}

test "normalizeBeats handles negative beats_in_measure (pre-roll)" {
    // REAPER returns measures=-1, beats_in_measure=-4.49 for pre-roll
    // In 6/8 time, this should normalize to bar=-2, beat=1.51
    const result = State.normalizeBeats(-1, -4.49, 6).?;
    try std.testing.expectEqual(@as(c_int, -2), result.bar);
    try std.testing.expectApproxEqAbs(@as(f64, 1.51), result.beat, 0.001);
}

test "normalizeBeats handles positive values unchanged" {
    // Normal case: bar 5, beat 2.5 in 4/4 time
    const result = State.normalizeBeats(5, 2.5, 4).?;
    try std.testing.expectEqual(@as(c_int, 5), result.bar);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), result.beat, 0.001);
}

test "normalizeBeats handles beat overflow" {
    // Beat 5.0 in 4/4 time should become bar+1, beat 1.0
    const result = State.normalizeBeats(3, 5.0, 4).?;
    try std.testing.expectEqual(@as(c_int, 4), result.bar);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.beat, 0.001);
}

test "normalizeBeats returns null for NaN" {
    const result = State.normalizeBeats(0, std.math.nan(f64), 4);
    try std.testing.expect(result == null);
}

test "normalizeBeats returns null for invalid beats_per_bar" {
    const result = State.normalizeBeats(0, 2.0, 0);
    try std.testing.expect(result == null);
}

// =============================================================================
// MockBackend-based tests
// =============================================================================

const MockBackend = reaper.MockBackend;

test "poll with MockBackend returns configured values" {
    var mock = MockBackend{
        .play_state = 1,
        .play_position = 5.5,
        .cursor_position = 2.0,
        .bpm = 140.0,
        .timesig_num = 6,
        .timesig_denom = 8,
        .time_sel_start = 1.0,
        .time_sel_end = 10.0,
        .bar_offset = -4,
        .tempo_marker_count = 2,
        .server_time_s = 123.456,
    };
    const state = State.poll(&mock);

    try std.testing.expectEqual(@as(c_int, 1), state.play_state);
    try std.testing.expectEqual(@as(f64, 5.5), state.play_position);
    try std.testing.expectEqual(@as(f64, 2.0), state.cursor_position);
    try std.testing.expectApproxEqAbs(@as(f64, 140.0), state.bpm, 0.01);
    try std.testing.expectEqual(@as(c_int, 8), state.time_sig_denom);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), state.time_sel_start, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), state.time_sel_end, 0.001);
    try std.testing.expectEqual(@as(c_int, -4), state.bar_offset);
    try std.testing.expectEqual(@as(c_int, 2), state.tempo_marker_count);
    try std.testing.expectApproxEqAbs(@as(f64, 123456.0), state.server_time_ms, 0.1);
}

test "poll handles NaN position gracefully" {
    var mock = MockBackend{
        .inject_nan_position = true,
        .play_state = 1,
        .cursor_position = 5.0, // Cursor is valid, but play position is NaN
    };
    const state = State.poll(&mock);

    // Play state should still be captured
    try std.testing.expectEqual(@as(c_int, 1), state.play_state);
    // Cursor position is valid
    try std.testing.expectEqual(@as(f64, 5.0), state.cursor_position);
    // Play position is NaN - we still store it (NaN comparison will fail in eql)
    try std.testing.expect(std.math.isNan(state.play_position));
}

test "poll handles NaN beats gracefully" {
    var mock = MockBackend{
        .inject_nan_beats = true,
        .play_state = 1,
        .play_position = 10.0,
    };
    const state = State.poll(&mock);

    // full_beat_position should be null when NaN
    try std.testing.expect(state.full_beat_position == null);
    // position_beat should be null when beats_in_measure is NaN
    try std.testing.expect(state.position_beat == null);
}

test "poll calculates bar.beat from time" {
    var mock = MockBackend{
        .play_state = 1,
        .play_position = 2.0, // 2 seconds
        .bpm = 120.0, // 2 beats per second = 4 beats in 2 seconds
        .timesig_num = 4, // 4/4 time = 4 beats per bar
        .timesig_denom = 4,
    };
    const state = State.poll(&mock);

    // At 120 BPM, 2 seconds = 4 beats = 1 full bar
    // MockBackend returns bar 2 (1-based), beat 0 (0-based in beats_in_measure)
    try std.testing.expectEqual(@as(c_int, 2), state.position_bar);
    // After normalization, beat should be 1.0 (1-based display)
    try std.testing.expect(state.position_beat != null);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), state.position_beat.?, 0.01);
}

test "poll tracks API calls correctly" {
    var mock = MockBackend{};
    _ = State.poll(&mock);

    // Verify key API calls were made
    try std.testing.expect(mock.getCallCount(.playState) >= 1);
    try std.testing.expect(mock.getCallCount(.playPosition) >= 1);
    try std.testing.expect(mock.getCallCount(.cursorPosition) >= 1);
    try std.testing.expect(mock.getCallCount(.timeToBeats) >= 1);
    try std.testing.expect(mock.getCallCount(.timeSelection) >= 1);
    try std.testing.expect(mock.getCallCount(.getTempoAtPosition) >= 1);
    try std.testing.expect(mock.getCallCount(.tempoMarkerCount) >= 1);
}

test "poll uses play_position when playing" {
    var mock = MockBackend{
        .play_state = 1, // Playing
        .play_position = 10.0,
        .cursor_position = 5.0,
    };
    const state = State.poll(&mock);

    // currentPosition should return play_position when playing
    try std.testing.expectEqual(@as(f64, 10.0), state.currentPosition());
}

test "poll uses cursor_position when stopped" {
    var mock = MockBackend{
        .play_state = 0, // Stopped
        .play_position = 10.0,
        .cursor_position = 5.0,
    };
    const state = State.poll(&mock);

    // currentPosition should return cursor_position when stopped
    try std.testing.expectEqual(@as(f64, 5.0), state.currentPosition());
}
