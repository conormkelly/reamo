/// Mock transport and time conversion methods.
const std = @import("std");
const types = @import("../types.zig");
const state = @import("state.zig");

/// Transport and time method implementations for MockBackend.
/// Called via @fieldParentPtr from the main MockBackend struct.
pub const TransportMethods = struct {
    // =========================================================================
    // Transport
    // =========================================================================

    pub fn playState(self: anytype) c_int {
        self.recordCall(.playState);
        return self.play_state;
    }

    pub fn playPosition(self: anytype) f64 {
        self.recordCall(.playPosition);
        if (self.inject_nan_position) return std.math.nan(f64);
        return self.play_position;
    }

    pub fn cursorPosition(self: anytype) f64 {
        self.recordCall(.cursorPosition);
        return self.cursor_position;
    }

    pub fn timePrecise(self: anytype) f64 {
        self.recordCall(.timePrecise);
        return self.server_time_s;
    }

    pub fn timePreciseMs(self: anytype) f64 {
        self.recordCall(.timePreciseMs);
        return self.server_time_s * 1000.0;
    }

    pub fn runCommand(self: anytype, cmd: c_int) void {
        self.recordCall(.runCommand);
        self.last_command = cmd;
    }

    pub fn setCursorPos(self: anytype, pos: f64) void {
        self.recordCall(.setCursorPos);
        self.cursor_position = pos;
    }

    // =========================================================================
    // Time conversion
    // =========================================================================

    pub fn timeToBeats(self: anytype, time: f64) types.BeatsInfo {
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

    pub fn beatsToTime(self: anytype, beats: f64) f64 {
        self.recordCall(.beatsToTime);
        const beats_per_second = self.bpm / 60.0;
        return beats / beats_per_second;
    }

    pub fn barBeatToTime(self: anytype, bar: c_int, beat: f64) f64 {
        self.recordCall(.barBeatToTime);
        const beats_per_bar: f64 = @floatFromInt(self.timesig_num);
        const total_beats = @as(f64, @floatFromInt(bar - 1)) * beats_per_bar + (beat - 1.0);
        const beats_per_second = self.bpm / 60.0;
        return total_beats / beats_per_second;
    }

    // =========================================================================
    // Tempo / Time signature
    // =========================================================================

    pub fn timeSignature(self: anytype) types.TimeSignature {
        self.recordCall(.timeSignature);
        return .{ .bpm = self.bpm, .num = @floatFromInt(self.timesig_num) };
    }

    pub fn getTempoAtPosition(self: anytype, _: f64) types.TempoAtPosition {
        self.recordCall(.getTempoAtPosition);
        return .{
            .bpm = self.bpm,
            .timesig_num = self.timesig_num,
            .timesig_denom = self.timesig_denom,
        };
    }

    pub fn tempoMarkerCount(self: anytype) c_int {
        self.recordCall(.tempoMarkerCount);
        return self.tempo_marker_count;
    }

    pub fn getTempoMarker(self: anytype, idx: c_int) ?types.TempoMarker {
        self.recordCall(.getTempoMarker);
        if (idx < 0 or idx >= self.tempo_marker_count) return null;
        return self.tempo_markers[@intCast(idx)];
    }

    pub fn getBarOffset(self: anytype) c_int {
        self.recordCall(.getBarOffset);
        return self.bar_offset;
    }

    pub fn getTimeSignatureNumerator(self: anytype) c_int {
        self.recordCall(.getTimeSignatureNumerator);
        return self.timesig_num;
    }

    pub fn getTimeSignatureDenominator(self: anytype) c_int {
        self.recordCall(.getTimeSignatureDenominator);
        return self.timesig_denom;
    }

    pub fn setTempo(self: anytype, new_bpm: f64) void {
        self.recordCall(.setTempo);
        self.bpm = new_bpm;
    }

    pub fn setTimeSignature(self: anytype, num: c_int, denom: c_int) bool {
        self.recordCall(.setTimeSignature);
        self.timesig_num = num;
        self.timesig_denom = denom;
        return true;
    }

    // =========================================================================
    // Time selection
    // =========================================================================

    pub fn timeSelection(self: anytype) types.TimeSelection {
        self.recordCall(.timeSelection);
        return .{ .start = self.time_sel_start, .end = self.time_sel_end };
    }

    pub fn setTimeSelection(self: anytype, start: f64, end: f64) void {
        self.recordCall(.setTimeSelection);
        self.time_sel_start = start;
        self.time_sel_end = end;
    }

    pub fn clearTimeSelection(self: anytype) void {
        self.recordCall(.clearTimeSelection);
        self.time_sel_start = 0;
        self.time_sel_end = 0;
    }

    // =========================================================================
    // Loop points (for native looping with repeat mode)
    // =========================================================================

    pub fn getLoopPoints(self: anytype) types.TimeSelection {
        self.recordCall(.getLoopPoints);
        return .{ .start = self.loop_start, .end = self.loop_end };
    }

    pub fn setLoopPoints(self: anytype, start: f64, end: f64) void {
        self.recordCall(.setLoopPoints);
        self.loop_start = start;
        self.loop_end = end;
    }

    pub fn clearLoopPoints(self: anytype) void {
        self.recordCall(.clearLoopPoints);
        self.loop_start = 0;
        self.loop_end = 0;
    }

    // =========================================================================
    // Repeat
    // =========================================================================

    pub fn getRepeat(self: anytype) bool {
        self.recordCall(.getRepeat);
        return self.repeat_enabled;
    }

    pub fn setRepeat(self: anytype, enabled: bool) void {
        self.recordCall(.setRepeat);
        self.repeat_enabled = enabled;
    }

};
