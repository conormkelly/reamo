/// Audio monitoring command handlers.
/// Commands: audio/startStream, audio/stopStream, audio/status
const std = @import("std");
const protocol = @import("../core/protocol.zig");
const mod = @import("../commands/mod.zig");
const audio_hook = @import("audio_hook.zig");

/// Handle audio/startStream — subscribe the requesting client to receive binary audio frames.
/// Response includes the current sample rate for frontend AudioContext creation.
pub fn handleStartStream(api: anytype, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const manager = mod.g_ctx.audio_stream orelse {
        response.err("NOT_INITIALIZED", "Audio streaming not initialized");
        return;
    };

    if (!manager.subscribe(response.client_id)) {
        response.err("STREAM_FAILED", "Failed to start audio stream (hook registration or thread spawn failed)");
        return;
    }

    // The rate the frames are captured at, which the phone plays them at: the
    // open device's. Not the project's rate setting, which a device may not
    // follow (JACK can't). Read from REAPER, not from the ring, whose rate is
    // the last block the hook saw and can predate a project switch that
    // changed the device's rate.
    const device_rate = api.audioDeviceSampleRate();
    const sample_rate: u32 = if (device_rate > 0) device_rate else manager.getSampleRate();

    var buf: [64]u8 = undefined;
    const payload = std.fmt.bufPrint(&buf, "{{\"sampleRate\":{d}}}", .{sample_rate}) catch {
        response.err("FORMAT_ERROR", "Failed to format response");
        return;
    };
    response.success(payload);
}

/// Handle audio/stopStream — unsubscribe the requesting client from audio streaming.
pub fn handleStopStream(_: anytype, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const manager = mod.g_ctx.audio_stream orelse {
        response.err("NOT_INITIALIZED", "Audio streaming not initialized");
        return;
    };

    manager.unsubscribe(response.client_id);
    response.success(null);
}

/// Handle audio/status — diagnostic command reporting audio stream state.
pub fn handleStatus(_: anytype, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const manager = mod.g_ctx.audio_stream orelse {
        response.err("NOT_INITIALIZED", "Audio streaming not initialized");
        return;
    };

    const rb = audio_hook.getRingBuffer();
    const hook_registered = audio_hook.isRegistered();
    const hook = audio_hook.instance();
    const held_stream = hook.holds(.stream);
    const held_tuner = hook.holds(.tuner);
    const held_inputs = hook.holds(.inputs);
    const input_taps = hook.openTaps();
    const missing_1 = hook.missing_output_1.load(.acquire);
    const missing_2 = hook.missing_output_2.load(.acquire);
    const has_api = manager.api != null;
    const has_fn = if (manager.api) |api| api.audioRegHardwareHook != null else false;
    const has_shared = manager.shared_state != null;
    const has_thread = manager.thread != null;
    const client_count = manager.client_count.load(.acquire);
    const rb_avail = rb.available();
    const rb_sr = rb.sample_rate.load(.acquire);
    const rb_overflows = rb.overflow_count.load(.acquire);

    // Diagnostic counters from the audio callback
    const cb_count = audio_hook.diag_callback_count.load(.monotonic);
    const post_count = audio_hook.diag_post_count.load(.monotonic);
    const no_getbuf = audio_hook.diag_no_getbuffer.load(.monotonic);
    const low_nch = audio_hook.diag_low_nch.load(.monotonic);
    const no_left = audio_hook.diag_no_left.load(.monotonic);
    const write_count = audio_hook.diag_write_count.load(.monotonic);
    const last_nch = audio_hook.diag_last_nch.load(.monotonic);

    var buf: [1024]u8 = undefined;
    const payload = std.fmt.bufPrint(&buf,
        "{{\"hookRegistered\":{},\"hookUsers\":{{\"stream\":{},\"tuner\":{},\"inputs\":{}}},\"inputTaps\":{d},\"missingOutput1\":{d},\"missingOutput2\":{d},\"hasApi\":{},\"hasApiFn\":{},\"hasSharedState\":{},\"hasThread\":{},\"clientCount\":{d},\"ringBufferAvail\":{d},\"sampleRate\":{d},\"overflows\":{d},\"cbCount\":{d},\"postCount\":{d},\"noGetBuf\":{d},\"lowNch\":{d},\"noLeft\":{d},\"writeCount\":{d},\"lastNch\":{d}}}",
        .{ hook_registered, held_stream, held_tuner, held_inputs, input_taps, missing_1, missing_2, has_api, has_fn, has_shared, has_thread, client_count, rb_avail, rb_sr, rb_overflows, cb_count, post_count, no_getbuf, low_nch, no_left, write_count, last_nch },
    ) catch {
        response.err("FORMAT_ERROR", "Failed to format status");
        return;
    };
    response.success(payload);
}
