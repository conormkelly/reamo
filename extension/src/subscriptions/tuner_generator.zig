/// Tuner Generator - Generates JSON events for tuner subscription broadcasts.
///
/// Produces "tuner" events containing pitch detection data for subscribed clients.
/// Reads slider values from the PitchDetect JSFX and validates using FFI utilities.
const std = @import("std");
const logging = @import("../core/logging.zig");
const protocol = @import("../core/protocol.zig");
const ffi = @import("../core/ffi.zig");
const tuner_subscriptions = @import("tuner_subscriptions.zig");

const Allocator = std.mem.Allocator;
const INPUT_FX_OFFSET = tuner_subscriptions.INPUT_FX_OFFSET;
const TunerParam = tuner_subscriptions.TunerParam;

/// Note names for computing from MIDI note number
const NOTE_NAMES = [_][]const u8{ "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" };

/// Tuner data parsed from JSFX sliders
pub const TunerData = struct {
    freq: f64, // Detected frequency in Hz
    note: i32, // MIDI note number (69 = A4)
    cents: f64, // Deviation from note (-50 to +50)
    conf: f64, // Confidence 0-1
    note_name: []const u8, // "A", "C#", etc.
    octave: i32, // Octave number (4 for A4)
    in_tune: bool, // |cents| < 2
};

/// Generate tuner event JSON for a subscription.
/// Returns null on error (track not found, FX not found, invalid slider values).
/// Searches for FX by GUID each call to handle user reordering the chain.
pub fn generateTunerEvent(
    allocator: Allocator,
    api: anytype,
    guid_cache: anytype,
    track_guid: []const u8,
    fx_guid: []const u8,
    reference_hz: f32,
) ?[]const u8 {
    _ = reference_hz; // Not used in event generation, only in JSFX config

    // Resolve track GUID to track pointer
    const track = guid_cache.resolve(track_guid) orelse {
        logging.debug("tuner_generator: Track GUID not found: {s}", .{track_guid});
        return null;
    };

    // Search Input FX chain by GUID to find current index
    // This handles when user has reordered the FX chain
    const input_fx_count = api.trackFxRecCount(track);
    var api_fx_idx: c_int = -1;
    var fx_idx: c_int = 0;
    while (fx_idx < input_fx_count) : (fx_idx += 1) {
        var guid_buf: [64]u8 = undefined;
        const current_guid = api.trackFxGetGuid(track, fx_idx + INPUT_FX_OFFSET, &guid_buf);
        if (current_guid.len > 0 and std.mem.eql(u8, current_guid, fx_guid)) {
            api_fx_idx = fx_idx + INPUT_FX_OFFSET;
            break;
        }
    }

    if (api_fx_idx < 0) {
        logging.debug("tuner_generator: FX GUID not found in Input FX chain: {s}", .{fx_guid});
        return null;
    }

    // Read sliders 0-3 from Input FX using GetParam (actual values, not normalized)
    // REAPER can return NaN/Inf from slider reads - must validate
    const freq = api.trackFxGetParam(track, api_fx_idx, @intFromEnum(TunerParam.frequency));
    const note_f = api.trackFxGetParam(track, api_fx_idx, @intFromEnum(TunerParam.note));
    const cents = api.trackFxGetParam(track, api_fx_idx, @intFromEnum(TunerParam.cents));
    const conf = api.trackFxGetParam(track, api_fx_idx, @intFromEnum(TunerParam.confidence));

    // Validate all values are finite (not NaN or Inf)
    if (!ffi.isFinite(freq) or !ffi.isFinite(note_f) or
        !ffi.isFinite(cents) or !ffi.isFinite(conf))
    {
        logging.debug("tuner_generator: Non-finite slider values from FX", .{});
        return null;
    }

    // Convert note to integer (JSFX stores as float but represents integer 0-127)
    const note = ffi.safeFloatToInt(i32, note_f) catch {
        logging.debug("tuner_generator: Invalid note value", .{});
        return null;
    };

    // Compute note name and octave from MIDI note number
    const note_idx: usize = @intCast(@mod(note, 12));
    const note_name = NOTE_NAMES[note_idx];
    const octave = @divFloor(note, 12) - 1; // MIDI note 0 = C-1
    const in_tune = @abs(cents) < 2.0;

    // Build JSON
    const buf = allocator.alloc(u8, 512) catch return null;
    var stream = std.io.fixedBufferStream(buf);
    var w = stream.writer();

    // Event envelope
    w.writeAll("{\"type\":\"event\",\"event\":\"tuner\",\"payload\":{") catch return null;

    // Track GUID
    w.writeAll("\"trackGuid\":\"") catch return null;
    protocol.writeJsonString(w, track_guid) catch return null;

    // Frequency
    w.print("\",\"freq\":{d:.2}", .{freq}) catch return null;

    // Note number
    w.print(",\"note\":{d}", .{note}) catch return null;

    // Note name
    w.writeAll(",\"noteName\":\"") catch return null;
    w.writeAll(note_name) catch return null;

    // Octave
    w.print("\",\"octave\":{d}", .{octave}) catch return null;

    // Cents
    w.print(",\"cents\":{d:.2}", .{cents}) catch return null;

    // Confidence
    w.print(",\"conf\":{d:.3}", .{conf}) catch return null;

    // In tune
    w.writeAll(if (in_tune) ",\"inTune\":true" else ",\"inTune\":false") catch return null;

    w.writeAll("}}") catch return null;

    return stream.getWritten();
}

/// Compute hash of tuner event JSON for change detection.
pub fn hashTunerEvent(json: []const u8) u64 {
    return std.hash.Wyhash.hash(0, json);
}

// =============================================================================
// Tests
// =============================================================================

test "hashTunerEvent produces consistent results" {
    const json = "{\"type\":\"event\",\"event\":\"tuner\",\"payload\":{}}";
    const h1 = hashTunerEvent(json);
    const h2 = hashTunerEvent(json);
    try std.testing.expectEqual(h1, h2);
}

test "hashTunerEvent produces different results for different content" {
    const json1 = "{\"freq\":440.0}";
    const json2 = "{\"freq\":442.0}";
    const h1 = hashTunerEvent(json1);
    const h2 = hashTunerEvent(json2);
    try std.testing.expect(h1 != h2);
}

test "NOTE_NAMES has 12 entries" {
    try std.testing.expectEqual(@as(usize, 12), NOTE_NAMES.len);
}

test "NOTE_NAMES contains expected values" {
    try std.testing.expectEqualStrings("C", NOTE_NAMES[0]);
    try std.testing.expectEqualStrings("A", NOTE_NAMES[9]);
    try std.testing.expectEqualStrings("B", NOTE_NAMES[11]);
}
