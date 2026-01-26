const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../core/protocol.zig");
const mod = @import("mod.zig");
const logging = @import("../core/logging.zig");
const ffi = @import("../core/ffi.zig");

// Set tempo (BPM)
pub fn handleSet(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const bpm = cmd.getFloat("bpm") orelse {
        response.err("MISSING_BPM", "bpm is required");
        return;
    };

    // Validate range (REAPER supports 2-960 BPM)
    if (bpm < 2.0 or bpm > 960.0) {
        response.err("INVALID_BPM", "bpm must be between 2 and 960");
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

    // Get tempo at position
    const tempo = api.getTempoAtPosition(time);

    // Calculate bar duration in beats (numerator in the time signature's denominator units)
    const beats_per_bar: f64 = @floatFromInt(tempo.timesig_num);

    // Convert beats to seconds: beats / (bpm / 60) = beats * 60 / bpm
    const duration = beats_per_bar * 60.0 / tempo.bpm;

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

    // Format bar string (same logic as markers.zig)
    const display_bar = beats_info.measures + bar_offset;
    // roundFloatToInt validates NaN/Inf from corrupt project data
    const scaled: u32 = ffi.roundFloatToInt(u32, (beats_info.beats_in_measure + 1.0) * 100.0) catch {
        response.err("INVALID_BEAT", "Invalid beat position value");
        return;
    };
    const beat_int: u32 = @max(1, scaled / 100);
    const ticks: u32 = scaled % 100;

    var buf: [192]u8 = undefined;
    const payload = std.fmt.bufPrint(&buf, "{{\"beats\":{d:.6},\"bars\":\"{d}.{d}.{d:0>2}\"}}", .{
        beats_info.beats,
        display_bar,
        beat_int,
        ticks,
    }) catch {
        logging.warn("tempo: timeToBeats response format failed", .{});
        return;
    };
    response.success(payload);
}

// Convert bar.beat.ticks to time in seconds (tempo-aware)
// Request: { "bar": 15, "beat": 1, "ticks": 0 }
// Response: { "time": 28.0 }
//
// IMPORTANT: User input uses "denominator beats" (e.g., beat 2 in 6/8 = second eighth note)
// but REAPER's TimeMap2_beatsToTime expects quarter notes as tpos.
// We must convert: qn_offset = (beat - 1) * (4.0 / denominator)
pub fn handleBarsToTime(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const bar = cmd.getInt("bar") orelse {
        response.err("MISSING_BAR", "bar is required");
        return;
    };

    // Beat is 1-indexed in the input (like display), default to 1
    const beat_input = cmd.getInt("beat") orelse 1;
    // Ticks are 0-99, default to 0
    const ticks_input = cmd.getInt("ticks") orelse 0;

    // Apply bar offset (reverse of what we do in timeToBeats)
    const bar_offset = api.getBarOffset();
    const actual_bar = bar - bar_offset;

    // Step 1: Get time at bar start (beat 1 = 0 QN offset)
    const bar_start_time = api.barBeatToTime(actual_bar, 1.0);

    // Step 2: Get time signature at bar start to know the denominator
    const tempo = api.getTempoAtPosition(bar_start_time);
    const denom: f64 = @floatFromInt(tempo.timesig_denom);

    // Step 3: Convert beat/ticks from denominator units to quarter notes
    // In 6/8: beat 2 = (2-1) * (4/8) = 0.5 QN
    // In 4/4: beat 2 = (2-1) * (4/4) = 1.0 QN
    const beat_f: f64 = @floatFromInt(beat_input - 1);
    const ticks_f: f64 = @as(f64, @floatFromInt(ticks_input)) / 100.0;
    const qn_offset = (beat_f + ticks_f) * (4.0 / denom);

    // Step 4: barBeatToTime expects beat where beat-1.0 = QN offset
    // So beat = qn_offset + 1.0
    const beat_for_api = qn_offset + 1.0;
    const time = api.barBeatToTime(actual_bar, beat_for_api);

    var buf: [64]u8 = undefined;
    const payload = std.fmt.bufPrint(&buf, "{{\"time\":{d:.15}}}", .{time}) catch {
        logging.warn("tempo: barsToTime response format failed", .{});
        return;
    };
    response.success(payload);
}
