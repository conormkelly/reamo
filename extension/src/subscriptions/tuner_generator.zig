/// Tuner Generator - Generates JSON events for tuner subscription broadcasts.
///
/// Produces "tuner" events containing pitch detection data for subscribed
/// clients: a reading of the native analyser (the master tuner, and track
/// tuners on their inputs).
const std = @import("std");
const protocol = @import("../core/protocol.zig");
const pitch = @import("../tuner/pitch.zig");
const tuner_subscriptions = @import("tuner_subscriptions.zig");

const Allocator = std.mem.Allocator;

/// Note names for computing from MIDI note number
const NOTE_NAMES = [_][]const u8{ "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" };

/// What a tuner event says, from whichever source.
pub const Event = struct {
    freq: f64, // Detected frequency in Hz, 0 for no pitch
    note: i32, // MIDI note number (69 = A4)
    cents: f64, // Deviation from note (-50 to +50)
    clarity: f64, // How periodic the input is at the period, 0-1
    reference_hz: f64,
    threshold_db: f64,
    flags: Flags,
    /// What the tuner can hear.
    state: State,

    pub const Flags = struct { settling: bool, stable: bool, multiple: bool, starting: bool };
};

/// Whether the tuner hears anything, and if not, why.
pub const State = union(enum) {
    /// Audio arrives; the reading is what it holds (silence included).
    listening,
    /// REAPER's audio device isn't running (Audio_IsRunning is 0): REAPER
    /// closed it while stopped, as Preferences > Audio can say to, and play
    /// reopens it; or the device failed or was unplugged. No audio arrives
    /// either way.
    device_closed,
    /// The track's record input can't be tuned now.
    cant_tune: struct { code: []const u8, message: []const u8 },
};

/// The longest event: a 40-byte GUID, a cant_tune message, every field.
pub const event_capacity = 1024;

/// The event JSON. `conf` repeats `clarity` (the same measure under its
/// older name) for pages that read only that. `inTune` needs a pitch.
pub fn writeEvent(w: anytype, track_guid: []const u8, ev: Event) !void {
    const note_idx: usize = @intCast(@mod(ev.note, 12));
    const octave = @divFloor(ev.note, 12) - 1; // MIDI note 0 = C-1
    const in_tune = ev.freq > 0 and @abs(ev.cents) < 2.0;

    try w.writeAll("{\"type\":\"event\",\"event\":\"tuner\",\"payload\":{\"trackGuid\":\"");
    try protocol.writeJsonString(w, track_guid);
    try w.print("\",\"freq\":{d:.2},\"note\":{d},\"noteName\":\"{s}\",\"octave\":{d}", .{ ev.freq, ev.note, NOTE_NAMES[note_idx], octave });
    try w.print(",\"cents\":{d:.2},\"conf\":{d:.3},\"clarity\":{d:.3}", .{ ev.cents, ev.clarity, ev.clarity });
    try w.writeAll(if (in_tune) ",\"inTune\":true" else ",\"inTune\":false");
    const f = ev.flags;
    try w.print(",\"settling\":{},\"stable\":{},\"multiple\":{},\"starting\":{}", .{ f.settling, f.stable, f.multiple, f.starting });
    switch (ev.state) {
        .listening => try w.writeAll(",\"state\":\"listening\""),
        .device_closed => try w.writeAll(",\"state\":\"deviceClosed\""),
        .cant_tune => |c| {
            try w.writeAll(",\"state\":\"cantTune\",\"code\":\"");
            try protocol.writeJsonString(w, c.code);
            try w.writeAll("\",\"message\":\"");
            try protocol.writeJsonString(w, c.message);
            try w.writeAll("\"");
        },
    }
    // Settings (for multi-client sync - other clients can see if someone changed them)
    try w.print(",\"referenceHz\":{d:.1},\"thresholdDb\":{d:.0}}}}}", .{ ev.reference_hz, ev.threshold_db });
}

/// The longest tunerError: a code and a GUID of GUID_LEN bytes, each
/// escaped to at most 6.
pub const error_capacity = 512;

/// The tunerError event, about the phone's tuner on `track_guid` (a track's
/// GUID, or "master"): a phone that has since chosen another source ignores
/// it. The code is in the payload, where pages read it, and beside it, for
/// pages that read it there.
pub fn writeError(w: anytype, comptime code: []const u8, track_guid: []const u8) !void {
    try w.writeAll("{\"type\":\"event\",\"event\":\"tunerError\",\"error\":\"" ++ code ++
        "\",\"payload\":{\"error\":\"" ++ code ++ "\",\"trackGuid\":\"");
    try protocol.writeJsonString(w, track_guid);
    try w.writeAll("\"}}");
}

fn render(allocator: Allocator, track_guid: []const u8, ev: Event) ?[]const u8 {
    const buf = allocator.alloc(u8, event_capacity) catch return null;
    var stream = std.io.fixedBufferStream(buf);
    writeEvent(stream.writer(), track_guid, ev) catch return null;
    return stream.getWritten();
}

/// The event for a reading of the native analyser, in `state`.
pub fn generateReadingEvent(
    allocator: Allocator,
    track_guid: []const u8,
    reading: pitch.Reading,
    settings: pitch.Settings,
    state: State,
) ?[]const u8 {
    return render(allocator, track_guid, .{
        .freq = reading.freq_hz,
        .note = reading.note,
        .cents = reading.cents,
        .clarity = reading.clarity,
        .reference_hz = settings.reference_hz,
        .threshold_db = settings.silence_db,
        .flags = .{ .settling = reading.settling, .stable = reading.stable, .multiple = reading.multiple, .starting = reading.starting },
        .state = state,
    });
}

/// What a poll has for a phone on the native analyser.
pub const AnalyserOutcome = union(enum) {
    event: []const u8,
    /// The phone's track can't be found.
    gone,
    /// No event: it couldn't be built (out of scratch memory), or the
    /// analysis thread has stopped publishing.
    none,
};

/// The poll's event for a phone on the master tuner, or on a track tuner on
/// its input (after following the track to its record input now:
/// TunerSubscriptions.refreshTrack). With the device closed no reading is
/// shown, as none can be true. A reading the analysis thread published
/// longer ago than subs.worker_stall_ns isn't sent at all (`none`): its
/// thread has stopped, and the phone, sent nothing, stops showing it.
/// `device_open` is api.isAudioRunning(), once per poll. Main thread.
pub fn analyserEvent(
    allocator: Allocator,
    subs: *tuner_subscriptions.TunerSubscriptions,
    slot: usize,
    guid_cache: anytype,
    api: anytype,
    device_open: bool,
) AnalyserOutcome {
    const client = &subs.clients[slot];
    const track_guid = client.getTrackGuid() orelse return .none;
    const heard: State = if (device_open) .listening else .device_closed;
    const snap = if (tuner_subscriptions.isMaster(track_guid))
        subs.masterSnapshot()
    else switch (subs.refreshTrack(slot, guid_cache, api, device_open)) {
        .gone => return .gone,
        .cant => |why| return outcome(generateReadingEvent(allocator, track_guid, pitch.Reading.none, client.settings, .{
            .cant_tune = .{ .code = why.code(), .message = why.message() },
        })),
        .source => |index| s: {
            const got = subs.sourceSnapshot(index);
            client.settings = got.settings;
            break :s got;
        },
    };
    if (device_open and snap.olderThan(std.time.Instant.now() catch null, subs.worker_stall_ns)) return .none;
    const reading = if (device_open) snap.reading else pitch.Reading.none;
    return outcome(generateReadingEvent(allocator, track_guid, reading, snap.settings, heard));
}

fn outcome(json: ?[]const u8) AnalyserOutcome {
    return if (json) |j| .{ .event = j } else .none;
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

fn renderTest(ev: Event) ![]const u8 {
    const json = render(std.testing.allocator, "{GUID}", ev) orelse return error.RenderFailed;
    return json;
}

test "a reading's event carries clarity under both names and the analyser's flags" {
    const json = generateReadingEvent(std.testing.allocator, "master", .{
        .freq_hz = 220.004,
        .note = 57,
        .cents = 0.03,
        .clarity = 0.987,
        .settling = false,
        .stable = true,
        .multiple = false,
        .starting = false,
    }, .{ .reference_hz = 442, .silence_db = -90 }, .listening) orelse return error.RenderFailed;
    defer std.testing.allocator.free(json.ptr[0..event_capacity]);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const p = parsed.value.object.get("payload").?.object;
    try std.testing.expectEqualStrings("master", p.get("trackGuid").?.string);
    try std.testing.expectEqual(@as(f64, 220.0), p.get("freq").?.float);
    try std.testing.expectEqual(@as(i64, 57), p.get("note").?.integer);
    try std.testing.expectEqualStrings("A", p.get("noteName").?.string);
    try std.testing.expectEqual(@as(i64, 3), p.get("octave").?.integer);
    try std.testing.expectEqual(@as(f64, 0.987), p.get("clarity").?.float);
    try std.testing.expectEqual(@as(f64, 0.987), p.get("conf").?.float);
    try std.testing.expect(p.get("inTune").?.bool);
    try std.testing.expect(!p.get("settling").?.bool);
    try std.testing.expect(p.get("stable").?.bool);
    try std.testing.expect(!p.get("multiple").?.bool);
    try std.testing.expect(!p.get("starting").?.bool);
    try std.testing.expectEqualStrings("listening", p.get("state").?.string);
    try std.testing.expectEqual(@as(f64, 442.0), p.get("referenceHz").?.float);
    try std.testing.expectEqual(@as(i64, -90), p.get("thresholdDb").?.integer);
}

test "no pitch is never in tune, though its cents are 0" {
    const json = try renderTest(.{ .freq = 0, .note = 0, .cents = 0, .clarity = 0, .reference_hz = 440, .threshold_db = -90, .flags = .{ .settling = false, .stable = false, .multiple = false, .starting = false }, .state = .listening });
    defer std.testing.allocator.free(json.ptr[0..event_capacity]);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"inTune\":false") != null);
}

test "a reading held back as a note starts says so, with no pitch yet" {
    var r = pitch.Reading.none;
    r.starting = true;
    const json = generateReadingEvent(std.testing.allocator, "master", r, .{}, .listening) orelse return error.RenderFailed;
    defer std.testing.allocator.free(json.ptr[0..event_capacity]);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const p = parsed.value.object.get("payload").?.object;
    try std.testing.expect(p.get("starting").?.bool);
    try std.testing.expectEqual(@as(f64, 0), p.get("freq").?.float);
}

test "a closed device and an input that can't be tuned say so, with the code and message" {
    const closed = generateReadingEvent(std.testing.allocator, "{T}", pitch.Reading.none, .{}, .device_closed) orelse return error.RenderFailed;
    defer std.testing.allocator.free(closed.ptr[0..event_capacity]);
    try std.testing.expect(std.mem.indexOf(u8, closed, "\"state\":\"deviceClosed\"") != null);

    const msg = "This track records MIDI. Choose an audio input for it in REAPER to tune it.";
    // The longest GUID a client can send, and a message: still one valid event.
    const guid = "{" ++ "A" ** 38 ++ "}";
    const cant = generateReadingEvent(std.testing.allocator, guid, pitch.Reading.none, .{}, .{ .cant_tune = .{ .code = "INPUT_MIDI", .message = msg } }) orelse return error.RenderFailed;
    defer std.testing.allocator.free(cant.ptr[0..event_capacity]);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, cant, .{});
    defer parsed.deinit();
    const p = parsed.value.object.get("payload").?.object;
    try std.testing.expectEqualStrings("cantTune", p.get("state").?.string);
    try std.testing.expectEqualStrings("INPUT_MIDI", p.get("code").?.string);
    try std.testing.expectEqualStrings(msg, p.get("message").?.string);
    try std.testing.expectEqual(@as(f64, 0), p.get("freq").?.float);
}

test "a tunerError names the source it is about, for a phone that has moved on to ignore" {
    var buf: [error_capacity]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeError(stream.writer(), "TUNER_NOT_FOUND", "{A\"B}");
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, stream.getWritten(), .{});
    defer parsed.deinit();
    const msg = parsed.value.object;
    try std.testing.expectEqualStrings("tunerError", msg.get("event").?.string);
    // Beside the payload too, for pages that read it there.
    try std.testing.expectEqualStrings("TUNER_NOT_FOUND", msg.get("error").?.string);
    const p = msg.get("payload").?.object;
    try std.testing.expectEqualStrings("TUNER_NOT_FOUND", p.get("error").?.string);
    try std.testing.expectEqualStrings("{A\"B}", p.get("trackGuid").?.string);
}

test "a tunerError for the longest GUID a client can send fits" {
    var buf: [error_capacity]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    // Every character escaped as \u00XX: the most a 40-byte GUID can take.
    try writeError(stream.writer(), "TUNER_NOT_FOUND", "\x01" ** tuner_subscriptions.GUID_LEN);
}
