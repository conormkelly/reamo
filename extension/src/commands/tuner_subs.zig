/// Tuner subscription command handlers.
///
/// Commands:
/// - tuner/subscribe: Subscribe to tuner on a track (the native analyser on
///   the track's hardware input, opened by the first phone on that input) or
///   on the master (the analyser on the post-master output)
/// - tuner/unsubscribe: Unsubscribe from tuner (the last phone on a source
///   closes its analyser)
/// - tuner/setParam: Set tuner parameter (reference Hz or threshold dB)
///
/// Single track per client - subscribing auto-unsubscribes from previous track.
const std = @import("std");
const logging = @import("../core/logging.zig");
const protocol = @import("../core/protocol.zig");
const mod = @import("mod.zig");
const tuner_subscriptions = @import("../subscriptions/tuner_subscriptions.zig");

/// Subscribe to tuner on a track.
///
/// Command format:
/// { "command": "tuner/subscribe", "trackGuid": "{AAA...}", "id": "1" }
///
/// Response:
/// { "type": "response", "id": "1", "success": true, "payload": {
///     "trackGuid": "{AAA...}",
///     "fxGuid": "",
///     "trackName": "Guitar",
///     "reference": 440.0,
///     "threshold": -90.0
/// }}
///
/// fxGuid is "": no plugin is inserted. A track tuner reads the hardware
/// input the track's record input names, armed or not
/// (subscriptions/input_tuners.zig); phones on tracks on the same input
/// share its analyser and settings. A track whose record input can't be
/// tuned is refused with INPUT_NONE, INPUT_MIDI, INPUT_NOT_ON_DEVICE or
/// INPUT_NOT_SUPPORTED (ReaRoute, loopback, multichannel), each with a
/// message for the phone to show; the phone still follows the track, and
/// its events start reading once the input can be tuned. The master ("master") hears the device's
/// hardware outputs 1/2, post master fader and mute
/// (subscriptions/master_tuner.zig): a muted or faded-down master reads as
/// silence.
///
/// After subscribing, the client receives "tuner" events at 30Hz
/// containing pitch detection data, with settling, stable, multiple and
/// starting (a new note's name is held back for its first ~0.1 s), and
/// state: "listening", "deviceClosed" (REAPER's audio device isn't running:
/// closed while stopped, which play reopens, or failed or unplugged; no
/// audio either way), or "cantTune" with code and
/// message, when a track's record input changes to one that can't be tuned
/// (the phone stays on the track, and tuning resumes when it can).
pub fn handleSubscribe(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const subs = mod.g_ctx.tuner_subs orelse {
        response.err("NOT_INITIALIZED", "Tuner subscriptions not initialized");
        return;
    };

    const guid_cache = mod.g_ctx.guid_cache orelse {
        response.err("NOT_INITIALIZED", "GUID cache not initialized");
        return;
    };

    // Get required parameter
    const track_guid = cmd.getString("trackGuid") orelse {
        response.err("MISSING_PARAM", "trackGuid is required");
        return;
    };

    // Subscribe to tuner
    const result = subs.subscribe(response.client_id, track_guid, guid_cache, api) catch |err| {
        switch (err) {
            error.TooManyClients => response.err("TOO_MANY_CLIENTS", "Maximum client limit reached"),
            error.TrackNotFound => response.err("TRACK_NOT_FOUND", "Track GUID not found in cache"),
            error.TooManyTuners => response.err("TOO_MANY_TUNERS", "Every input the tuner can read at once is in use"),
            error.OutOfMemory => response.err("OUT_OF_MEMORY", "Not enough memory for the tuner"),
            error.ThreadFailed => response.err("THREAD_FAILED", "Couldn't start the tuner's thread"),
            error.AudioHookFailed => {
                logging.warn("tuner: REAPER refused the audio hook the tuner reads", .{});
                response.err("AUDIO_HOOK_FAILED", "REAPER refused the audio hook the tuner reads");
            },
            error.InputNone, error.InputMidi, error.InputNotOnDevice, error.InputReaRoute, error.InputMultichannel => {
                const why = tuner_subscriptions.cantTuneOf(err).?;
                logging.debug("tuner: track {f} can't be tuned: {s}", .{ logging.untrusted(track_guid), why.code() });
                response.err(why.code(), why.message());
            },
        }
        return;
    };

    // Build success response with subscribe result
    var payload_buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&payload_buf);
    writeSubscribeResult(stream.writer(), &result) catch {
        response.err("INTERNAL_ERROR", "Failed to format response");
        return;
    };
    response.success(stream.getWritten());
}

/// fxGuid is always "": no plugin is inserted. It stays for pages that read it.
fn writeSubscribeResult(w: anytype, result: *const tuner_subscriptions.SubscribeResult) !void {
    try w.writeAll("{\"trackGuid\":\"");
    try protocol.writeJsonString(w, result.track_guid);
    try w.writeAll("\",\"fxGuid\":\"\",\"trackName\":\"");
    try protocol.writeJsonString(w, result.trackName());
    try w.print("\",\"reference\":{d:.1},\"threshold\":{d:.1}}}", .{ result.reference_hz, result.threshold_db });
}

/// Unsubscribe from tuner.
///
/// Command format:
/// { "command": "tuner/unsubscribe", "id": "1" }
///
/// Response:
/// { "type": "response", "id": "1", "success": true }
pub fn handleUnsubscribe(api: anytype, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const subs = mod.g_ctx.tuner_subs orelse {
        response.err("NOT_INITIALIZED", "Tuner subscriptions not initialized");
        return;
    };

    subs.unsubscribe(response.client_id, api);
    response.success(null);
}

/// Set tuner parameter.
///
/// Command format:
/// { "command": "tuner/setParam", "trackGuid": "{AAA...}", "param": "reference", "value": 442.0, "id": "1" }
///
/// Parameters:
/// - param: "reference" (A4 Hz, 400-480) or "threshold" (silence dB, -90 to -30);
///   values outside are held to the range, on a track tuner and the master
///   alike, so what other phones are told matches what the tuner uses
/// - value: float value for the parameter
///
/// Response:
/// { "type": "response", "id": "1", "success": true }
pub fn handleSetParam(_: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const subs = mod.g_ctx.tuner_subs orelse {
        response.err("NOT_INITIALIZED", "Tuner subscriptions not initialized");
        return;
    };

    // Get required parameters
    const track_guid = cmd.getString("trackGuid") orelse {
        response.err("MISSING_PARAM", "trackGuid is required");
        return;
    };

    const param_name = cmd.getString("param") orelse {
        response.err("MISSING_PARAM", "param is required");
        return;
    };

    const value = cmd.getFloat("value") orelse {
        response.err("MISSING_PARAM", "value is required");
        return;
    };

    // Map param name to enum
    const param: tuner_subscriptions.TunerParam = if (std.mem.eql(u8, param_name, "reference"))
        .reference
    else if (std.mem.eql(u8, param_name, "threshold"))
        .threshold
    else {
        response.err("INVALID_PARAM", "param must be 'reference' or 'threshold'");
        return;
    };

    // Set the parameter
    subs.setParam(track_guid, param, @floatCast(value)) catch |err| {
        switch (err) {
            error.NotSubscribed => response.err("NOT_SUBSCRIBED", "No active tuner for this track"),
            error.InvalidParam => response.err("INVALID_PARAM", "Invalid parameter"),
        }
        return;
    };

    response.success(null);
}

// =============================================================================
// Tests
// =============================================================================

test "handleSubscribe, handleUnsubscribe, handleSetParam compile" {
    // Just verify the module compiles - full tests need mock ResponseWriter
}

test "the subscribe response keeps fxGuid, empty, for pages that read it" {
    var result = tuner_subscriptions.SubscribeResult{ .track_guid = "{T1}", .reference_hz = 442, .threshold_db = -90 };
    const name = "Guitar \"Lead\"";
    @memcpy(result.track_name_buf[0..name.len], name);
    result.track_name_len = name.len;
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeSubscribeResult(stream.writer(), &result);
    try std.testing.expectEqualStrings(
        "{\"trackGuid\":\"{T1}\",\"fxGuid\":\"\",\"trackName\":\"Guitar \\\"Lead\\\"\",\"reference\":442.0,\"threshold\":-90.0}",
        stream.getWritten(),
    );
}
