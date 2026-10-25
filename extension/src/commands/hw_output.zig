const std = @import("std");
const utf8 = @import("../core/utf8.zig");
const protocol = @import("../core/protocol.zig");
const mod = @import("mod.zig");
const tracks = @import("tracks.zig");
const gesture_state = @import("../server/gesture_state.zig");
const logging = @import("../core/logging.zig");

/// Set HW output volume for the specified hardware output
/// Params: trackIdx (unified: 0=master, 1+=user tracks), hwIdx (0-based), volume (linear, 1.0 = 0dB)
pub fn handleSetVolume(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track_idx = cmd.getInt("trackIdx") orelse {
        response.err("MISSING_TRACK_IDX", "trackIdx is required");
        return;
    };
    const hw_idx = cmd.getInt("hwIdx") orelse {
        response.err("MISSING_HW_IDX", "hwIdx is required");
        return;
    };
    const volume = cmd.getFloat("volume") orelse {
        response.err("MISSING_VOLUME", "volume is required (linear, 1.0 = 0dB)");
        return;
    };

    const track = api.getTrackByUnifiedIdx(track_idx) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };

    if (!mod.routeExists(api, track, .hw_output, hw_idx)) {
        response.err("NOT_FOUND", "Hardware output not found");
        return;
    }

    const control = gesture_state.ControlId.hwOutputVolume(track_idx, hw_idx);
    const in_gesture = mod.inGesture(response, control);
    if (!in_gesture) api.undoBeginBlock();
    const success = api.trackHwOutputSetVolume(track, hw_idx, volume);
    if (in_gesture) response.gestures.?.recordActivity(control) else api.undoEndBlock("REAmo: Adjust audio hardware output volume");
    if (!success) {
        response.err("SET_FAILED", "Failed to set HW output volume");
        return;
    }

    logging.debug("HW output volume set: track {} hw {} volume {d:.3}", .{ track_idx, hw_idx, volume });
    response.success(null);
}

/// Set HW output mute state for the specified hardware output
/// Params: trackIdx, hwIdx, muted (boolean)
pub fn handleSetMute(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track_idx = cmd.getInt("trackIdx") orelse {
        response.err("MISSING_TRACK_IDX", "trackIdx is required");
        return;
    };
    const hw_idx = cmd.getInt("hwIdx") orelse {
        response.err("MISSING_HW_IDX", "hwIdx is required");
        return;
    };
    const muted_int = cmd.getInt("muted") orelse {
        response.err("MISSING_MUTED", "muted is required (0 or 1)");
        return;
    };
    const muted = muted_int != 0;

    const track = api.getTrackByUnifiedIdx(track_idx) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };

    if (!mod.routeExists(api, track, .hw_output, hw_idx)) {
        response.err("NOT_FOUND", "Hardware output not found");
        return;
    }

    api.undoBeginBlock();
    const success = api.trackHwOutputSetMute(track, hw_idx, muted);
    api.undoEndBlock("REAmo: Adjust audio hardware output mute");

    if (!success) {
        response.err("SET_FAILED", "Failed to set HW output mute state");
        return;
    }

    logging.debug("HW output mute set: track {} hw {} muted {}", .{ track_idx, hw_idx, muted });
    response.success(null);
}

/// Set HW output pan for the specified hardware output
/// Params: trackIdx, hwIdx, pan (-1.0 to 1.0)
pub fn handleSetPan(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track_idx = cmd.getInt("trackIdx") orelse {
        response.err("MISSING_TRACK_IDX", "trackIdx is required");
        return;
    };
    const hw_idx = cmd.getInt("hwIdx") orelse {
        response.err("MISSING_HW_IDX", "hwIdx is required");
        return;
    };
    const pan = cmd.getFloat("pan") orelse {
        response.err("MISSING_PAN", "pan is required (-1.0 to 1.0)");
        return;
    };

    const track = api.getTrackByUnifiedIdx(track_idx) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };

    if (!mod.routeExists(api, track, .hw_output, hw_idx)) {
        response.err("NOT_FOUND", "Hardware output not found");
        return;
    }

    // Clamp pan to valid range
    const clamped = @max(-1.0, @min(1.0, pan));

    const control = gesture_state.ControlId.hwOutputPan(track_idx, hw_idx);
    const in_gesture = mod.inGesture(response, control);
    if (!in_gesture) api.undoBeginBlock();
    const success = api.trackHwOutputSetPan(track, hw_idx, clamped);
    if (in_gesture) response.gestures.?.recordActivity(control) else api.undoEndBlock("REAmo: Adjust audio hardware output pan");
    if (!success) {
        response.err("SET_FAILED", "Failed to set HW output pan");
        return;
    }

    logging.debug("HW output pan set: track {} hw {} pan {d:.3}", .{ track_idx, hw_idx, clamped });
    response.success(null);
}

/// Set HW output mode for the specified hardware output
/// Params: trackIdx, hwIdx, mode (0=post-fader, 1=pre-FX, 3=post-FX)
pub fn handleSetMode(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track_idx = cmd.getInt("trackIdx") orelse {
        response.err("MISSING_TRACK_IDX", "trackIdx is required");
        return;
    };
    const hw_idx = cmd.getInt("hwIdx") orelse {
        response.err("MISSING_HW_IDX", "hwIdx is required");
        return;
    };
    const mode = cmd.getInt("mode") orelse {
        response.err("MISSING_MODE", "mode is required (0=post-fader, 1=pre-FX, 3=post-FX)");
        return;
    };

    // Validate mode (no mode 2 in REAPER)
    if (mode != 0 and mode != 1 and mode != 3) {
        response.err("INVALID_MODE", "mode must be 0, 1, or 3");
        return;
    }

    const track = api.getTrackByUnifiedIdx(track_idx) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };

    if (!mod.routeExists(api, track, .hw_output, hw_idx)) {
        response.err("NOT_FOUND", "Hardware output not found");
        return;
    }

    api.undoBeginBlock();
    const success = api.trackHwOutputSetMode(track, hw_idx, mode);
    api.undoEndBlock("REAmo: Adjust audio hardware output mode");

    if (!success) {
        response.err("SET_FAILED", "Failed to set HW output mode");
        return;
    }

    logging.debug("HW output mode set: track {} hw {} mode {}", .{ track_idx, hw_idx, mode });
    response.success(null);
}

/// Create a new hardware output on this track.
/// Params: trackGuid (or trackIdx)
/// Response: { "hwIdx": N }
pub fn handleAdd(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const resolution = tracks.resolveTrack(api, cmd) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };

    // CreateTrackSend with null dest = hardware output
    api.undoBeginBlock();
    const hw_idx = api.createSend(resolution.track, null);
    api.undoEndBlock("REAmo: Create hardware output");

    if (hw_idx < 0) {
        response.err("CREATE_FAILED", "Failed to create hardware output");
        return;
    }

    var resp_buf: [64]u8 = undefined;
    const resp_json = std.fmt.bufPrint(&resp_buf, "{{\"hwIdx\":{d}}}", .{hw_idx}) catch {
        logging.warn("hw/add: response buffer overflow", .{});
        response.success(null);
        return;
    };
    logging.debug("HW output created: track {} hw idx {d}", .{ resolution.idx, hw_idx });
    response.success(resp_json);
}

/// Remove a hardware output by index.
/// Params: trackGuid (or trackIdx), hwIdx
pub fn handleRemove(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const resolution = tracks.resolveTrack(api, cmd) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };

    const hw_idx = cmd.getInt("hwIdx") orelse {
        response.err("MISSING_PARAM", "hwIdx is required");
        return;
    };

    if (!mod.routeExists(api, resolution.track, .hw_output, hw_idx)) {
        response.err("NOT_FOUND", "Hardware output not found");
        return;
    }

    api.undoBeginBlock();
    // category > 0 = hw outputs
    const success = api.removeSend(resolution.track, 1, hw_idx);
    api.undoEndBlock("REAmo: Remove hardware output");

    if (!success) {
        response.err("REMOVE_FAILED", "Failed to remove hardware output");
        return;
    }

    logging.debug("HW output removed: track {} hw {}", .{ resolution.idx, hw_idx });
    response.success(null);
}

/// Set the destination channel for a hardware output.
/// Params: trackIdx (or trackGuid), hwIdx, destChannel (I_DSTCHAN encoding)
pub fn handleSetDestChannel(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const resolution = tracks.resolveTrack(api, cmd) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };

    const hw_idx = cmd.getInt("hwIdx") orelse {
        response.err("MISSING_PARAM", "hwIdx is required");
        return;
    };

    const dest_channel = cmd.getInt("destChannel") orelse {
        response.err("MISSING_PARAM", "destChannel is required");
        return;
    };

    if (!mod.routeExists(api, resolution.track, .hw_output, hw_idx)) {
        response.err("NOT_FOUND", "Hardware output not found");
        return;
    }

    api.undoBeginBlock();
    const success = api.trackHwOutputSetDestChannel(resolution.track, hw_idx, dest_channel);
    api.undoEndBlock("REAmo: Set hardware output destination");

    if (!success) {
        response.err("SET_FAILED", "Failed to set HW output destination channel");
        return;
    }

    logging.debug("HW output dest channel set: track {} hw {} dest {}", .{ resolution.idx, hw_idx, dest_channel });
    response.success(null);
}

/// List available audio output channels (stereo pairs + mono).
/// Matches REAPER's own hw output menu: stereo pairs first, then individual mono outputs.
/// Returns: { "outputs": [{"destChan": N, "name": "...", "stereo": true/false}, ...] }
pub fn handleListOutputs(api: anytype, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const count = api.numAudioOutputs();

    const tiered = mod.g_ctx.tiered orelse {
        response.err("NOT_INITIALIZED", "Tiered arenas not initialized");
        return;
    };

    // Grows to fit: a multichannel interface's long channel names can run
    // past any estimate, and the UI awaits this list to open the picker.
    const estimate: usize = 200 + @as(usize, @intCast(@max(count, 0))) * 160;
    const json = protocol.writeAlloc(tiered.scratchAllocator(), estimate, OutputsCtx(@TypeOf(api)){ .api = api, .count = count }, writeOutputs) catch {
        response.err("SERIALIZE_ERROR", "Failed to write response");
        return;
    };
    response.successLargePayload(json);
}

fn OutputsCtx(comptime Api: type) type {
    return struct { api: Api, count: c_int };
}

fn writeOutputs(ctx: anytype, writer: anytype) !void {
    const api = ctx.api;
    const count = ctx.count;

    try writer.writeAll("{\"outputs\":[");
    var first = true;

    // GetOutputChannelName returns a pointer to a static internal buffer that is
    // overwritten on each call. We must copy the first name before fetching the second.
    var name_copy_buf: [128]u8 = undefined;

    // --- Stereo pairs (channels 0+1, 2+3, 4+5, ...) ---
    {
        var ch: c_int = 0;
        while (ch + 1 < count) : (ch += 2) {
            if (!first) try writer.writeAll(",");
            first = false;

            // Get first name and copy it before the second call overwrites the static buffer
            const raw1 = if (api.audioOutputName(ch)) |n| std.mem.sliceTo(n, 0) else "Unknown";
            const s1 = name_copy_buf[0..utf8.copyPrefix(&name_copy_buf, raw1)];

            // Now safe to call again — s1 is in our local buffer
            const s2 = if (api.audioOutputName(ch + 1)) |n| std.mem.sliceTo(n, 0) else "Unknown";

            // I_DSTCHAN for stereo: just the channel index
            try writer.print("{{\"destChan\":{d},\"name\":\"", .{ch});
            try protocol.writeJsonString(writer, s1);
            try writer.writeAll(" / ");
            try protocol.writeJsonString(writer, s2);
            try writer.writeAll("\",\"stereo\":true}");
        }
    }

    // --- Mono outputs (each individual channel) ---
    {
        var ch: c_int = 0;
        while (ch < count) : (ch += 1) {
            if (!first) try writer.writeAll(",");
            first = false;

            const name = if (api.audioOutputName(ch)) |n| std.mem.sliceTo(n, 0) else "Unknown";
            // I_DSTCHAN for mono: channel index | 1024
            try writer.print("{{\"destChan\":{d},\"name\":\"", .{ch | 1024});
            try protocol.writeJsonString(writer, name);
            try writer.writeAll("\",\"stereo\":false}");
        }
    }

    try writer.writeAll("]}");
}

// ============================================================================
// Tests
// ============================================================================

test "hw output handlers compile" {
    // Command handlers require ResponseWriter with SharedState.
    // Integration tests via websocat verify full behavior.
}
