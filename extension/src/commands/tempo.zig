const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../core/protocol.zig");
const mod = @import("mod.zig");
const logging = @import("../core/logging.zig");
const bar_beat = @import("../state/bar_beat.zig");

// Set tempo (BPM)
pub fn handleSet(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const bpm = cmd.getFloat("bpm") orelse {
        response.err("MISSING_BPM", "bpm is required");
        return;
    };

    // REAPER's tempo range (SetCurrentBPM clamps to 1-960)
    if (bpm < 1.0 or bpm > 960.0) {
        response.err("INVALID_BPM", "bpm must be between 1 and 960");
        return;
    }

    api.setTempo(bpm);
    logging.debug("Set tempo to {d:.2} BPM", .{bpm});
}

// Tap tempo (uses REAPER's built-in command)
pub fn handleTap(api: anytype, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.TAP_TEMPO);
}

// Snap time to beat grid (tempo-aware)
// Request: { "time": 15.7, "subdivision": 1 }
// Response: { "snappedTime": 16.0, "snappedBeats": 32.0 }
pub fn handleSnap(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const time = cmd.getFloat("time") orelse {
        response.err("MISSING_TIME", "time is required");
        return;
    };

    // Subdivision: 1 = beat, 2 = 8th note, 4 = 16th note
    const subdivision = cmd.getInt("subdivision") orelse 1;
    if (subdivision < 1 or subdivision > 16) {
        response.err("INVALID_SUBDIVISION", "subdivision must be between 1 and 16");
        return;
    }

    // Convert time to beats
    const beats_info = api.timeToBeats(time);
    const beats = beats_info.beats;

    // Snap to nearest subdivision
    const subdiv_f: f64 = @floatFromInt(subdivision);
    const snapped_beats = @round(beats * subdiv_f) / subdiv_f;

    // Convert back to time
    const snapped_time = api.beatsToTime(snapped_beats);

    var buf: [128]u8 = undefined;
    const payload = std.fmt.bufPrint(&buf, "{{\"snappedTime\":{d:.15},\"snappedBeats\":{d:.6}}}", .{ snapped_time, snapped_beats }) catch {
        logging.warn("tempo: snap response format failed", .{});
        return;
    };
    response.success(payload);
}

// Get bar duration at a specific position (for minimum region length, etc.)
// Request: { "time": 10.5 }
// Response: { "duration": 2.0, "durationBeats": 4.0, "bpm": 120.0, "timesigNum": 4, "timesigDenom": 4 }
pub fn handleGetBarDuration(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const time = cmd.getFloat("time") orelse 0.0;

    const tempo = api.getTempoAtPosition(time);
    const beats_per_bar: f64 = @floatFromInt(tempo.timesig_num);
    const duration = barDurationSeconds(tempo);

    var buf: [192]u8 = undefined;
    const payload = std.fmt.bufPrint(&buf, "{{\"duration\":{d:.15},\"durationBeats\":{d:.6},\"bpm\":{d:.2},\"timesigNum\":{d},\"timesigDenom\":{d}}}", .{
        duration,
        beats_per_bar,
        tempo.bpm,
        tempo.timesig_num,
        tempo.timesig_denom,
    }) catch {
        logging.warn("tempo: getBarDuration response format failed", .{});
        return;
    };
    response.success(payload);
}

/// A bar's length: `timesig_num` beats of 1/`timesig_denom` notes, while
/// REAPER's BPM counts quarter notes (a 6/8 bar at 90 BPM is 2 s, not 4 s).
fn barDurationSeconds(tempo: anytype) f64 {
    const num: f64 = @floatFromInt(tempo.timesig_num);
    const denom: f64 = @floatFromInt(@max(tempo.timesig_denom, 1));
    return num * (4.0 / denom) * 60.0 / tempo.bpm;
}

// Convert time to beats with formatted bar string
// Request: { "time": 16.0 }
// Response: { "beats": 32.0, "bars": "9.1.00" }
pub fn handleTimeToBeats(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const time = cmd.getFloat("time") orelse {
        response.err("MISSING_TIME", "time is required");
        return;
    };

    // Get beat info
    const beats_info = api.timeToBeats(time);
    const bar_offset = api.getBarOffset();

    // Same bar.beat.ticks label as markers and regions
    var bars_buf: [48]u8 = undefined;
    var bars_stream = std.io.fixedBufferStream(&bars_buf);
    bar_beat.write(bars_stream.writer(), beats_info.measures, beats_info.beats_in_measure, beats_info.time_sig_num, bar_offset) catch {
        response.err("INVALID_BEAT", "Invalid beat position value");
        return;
    };

    var buf: [192]u8 = undefined;
    const payload = std.fmt.bufPrint(&buf, "{{\"beats\":{d:.6},\"bars\":\"{s}\"}}", .{
        beats_info.beats,
        bars_stream.getWritten(),
    }) catch {
        logging.warn("tempo: timeToBeats response format failed", .{});
        return;
    };
    response.success(payload);
}

// Convert bar.beat.ticks to time in seconds (tempo-aware)
// Request: { "bar": 15, "beat": 1, "ticks": 0 }
// Response: { "time": 28.0 }
// bar.beat.ticks as displayed: beat in the meter's own beats, ticks hundredths of a beat.
pub fn handleBarsToTime(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const bar = cmd.getInt("bar") orelse {
        response.err("MISSING_BAR", "bar is required");
        return;
    };
    if (mod.validateBar(bar) == null) {
        response.err("INVALID_BAR", "bar is out of range");
        return;
    }

    // Beat is 1-indexed in the input (like display), default to 1
    const beat_input = cmd.getInt("beat") orelse 1;
    // Ticks are 0-99, default to 0
    const ticks_input = cmd.getInt("ticks") orelse 0;
    if (beat_input < 1 or ticks_input < 0 or ticks_input > 99) {
        response.err("INVALID_BEAT", "beat must be >= 1 and ticks 0-99");
        return;
    }

    const beat: f64 = @as(f64, @floatFromInt(beat_input)) + @as(f64, @floatFromInt(ticks_input)) / 100.0;
    const time = mod.displayedBarBeatToTime(api, bar, beat) orelse {
        response.err("INVALID_BAR", "bar is out of range");
        return;
    };

    var buf: [64]u8 = undefined;
    const payload = std.fmt.bufPrint(&buf, "{{\"time\":{d:.15}}}", .{time}) catch {
        logging.warn("tempo: barsToTime response format failed", .{});
        return;
    };
    response.success(payload);
}

// ============================================================================
// Tests
// ============================================================================

test "bar.beat counts the meter's own beats in compound meters" {
    const mock = @import("../reaper/mock/mod.zig");
    // 6/8 at 90 BPM (quarter notes): an eighth is 1/3 s, a bar 2 s.
    var m = mock.MockBackend{ .bpm = 90, .timesig_num = 6, .timesig_denom = 8 };
    try std.testing.expectApproxEqAbs(@as(f64, 2.0 + 1.0), mod.displayedBarBeatToTime(&m, 2, 4.0).?, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), barDurationSeconds(m.getTempoAtPosition(0)), 1e-9);
}

test "tempo/barsToTime rejects bar, beat and ticks that would overflow before converting" {
    const mock = @import("../reaper/mock/mod.zig");
    var m = mock.MockBackend{};
    const rejected = [_][]const u8{
        \\{"type":"command","command":"tempo/barsToTime","bar":-2147483648}
        ,
        \\{"type":"command","command":"tempo/barsToTime","bar":1,"beat":-2147483648}
        ,
        \\{"type":"command","command":"tempo/barsToTime","bar":1,"beat":0}
        ,
        \\{"type":"command","command":"tempo/barsToTime","bar":1,"ticks":100}
        ,
    };
    for (rejected) |json| mod.testRunHandler(&m, handleBarsToTime, json);
    try std.testing.expectEqual(@as(usize, 0), m.getCallCount(.barBeatToTime));

    mod.testRunHandler(&m, handleBarsToTime,
        \\{"type":"command","command":"tempo/barsToTime","bar":2,"beat":3,"ticks":50}
    );
    try std.testing.expect(m.getCallCount(.barBeatToTime) > 0);
}
