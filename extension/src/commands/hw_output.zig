const std = @import("std");
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

    // No undo block here - continuous control uses gesture-based undo coalescing
    // (undoBeginBlock on gesture/start, undoEndBlock on gesture/end)
    const success = api.trackHwOutputSetVolume(track, hw_idx, volume);
    if (!success) {
        response.err("SET_FAILED", "Failed to set HW output volume");
        return;
    }

    // Record activity for gesture timeout tracking
    if (response.gestures) |gestures| {
        gestures.recordActivity(gesture_state.ControlId.hwOutputVolume(track_idx, hw_idx));
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

    // Clamp pan to valid range
    const clamped = @max(-1.0, @min(1.0, pan));

    // No undo block here - continuous control uses gesture-based undo coalescing
    // (undoBeginBlock on gesture/start, undoEndBlock on gesture/end)
    const success = api.trackHwOutputSetPan(track, hw_idx, clamped);
    if (!success) {
        response.err("SET_FAILED", "Failed to set HW output pan");
        return;
    }

    // Record activity for gesture timeout tracking
    if (response.gestures) |gestures| {
        gestures.recordActivity(gesture_state.ControlId.hwOutputPan(track_idx, hw_idx));
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

    // category > 0 = hw outputs
    api.undoBeginBlock();
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
    const allocator = tiered.scratchAllocator();

    const estimated_size: usize = @intCast(@max(4096, @as(c_int, @intCast(count)) * 120 + 200));
    const buf = allocator.alloc(u8, estimated_size) catch {
        response.err("ALLOC_FAILED", "Failed to allocate response buffer");
        return;
    };

    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    writer.writeAll("{\"outputs\":[") catch {
        response.err("SERIALIZE_ERROR", "Failed to write response");
        return;
    };

    var first = true;

    // GetOutputChannelName returns a pointer to a static internal buffer that is
    // overwritten on each call. We must copy the first name before fetching the second.
    var name_copy_buf: [128]u8 = undefined;

    // --- Stereo pairs (channels 0+1, 2+3, 4+5, ...) ---
    {
        var ch: c_int = 0;
        while (ch + 1 < count) : (ch += 2) {
            if (!first) writer.writeAll(",") catch {};
            first = false;

            // Get first name and copy it before the second call overwrites the static buffer
            const raw1 = if (api.audioOutputName(ch)) |n| std.mem.sliceTo(n, 0) else "Unknown";
            const len1 = @min(raw1.len, name_copy_buf.len);
            @memcpy(name_copy_buf[0..len1], raw1[0..len1]);
            const s1 = name_copy_buf[0..len1];

            // Now safe to call again — s1 is in our local buffer
            const s2 = if (api.audioOutputName(ch + 1)) |n| std.mem.sliceTo(n, 0) else "Unknown";

            // I_DSTCHAN for stereo: just the channel index
            const dest_chan = ch;

            writer.print("{{\"destChan\":{d},\"name\":\"", .{dest_chan}) catch continue;
            writeJsonEscaped(writer, s1);
            writer.writeAll(" / ") catch {};
            writeJsonEscaped(writer, s2);
            writer.writeAll("\",\"stereo\":true}") catch {};
        }
    }

    // --- Mono outputs (each individual channel) ---
    {
        var ch: c_int = 0;
        while (ch < count) : (ch += 1) {
            if (!first) writer.writeAll(",") catch {};
            first = false;

            const name = if (api.audioOutputName(ch)) |n| std.mem.sliceTo(n, 0) else "Unknown";
            // I_DSTCHAN for mono: channel index | 1024
            const dest_chan = ch | 1024;

            writer.print("{{\"destChan\":{d},\"name\":\"", .{dest_chan}) catch continue;
            writeJsonEscaped(writer, name);
            writer.writeAll("\",\"stereo\":false}") catch {};
        }
    }

    writer.writeAll("]}") catch {};
    response.successLargePayload(stream.getWritten());
}

/// Write a string with JSON escaping (quotes and backslashes)
fn writeJsonEscaped(writer: anytype, s: []const u8) void {
    for (s) |c| {
        switch (c) {
            '"' => writer.writeAll("\\\"") catch {},
            '\\' => writer.writeAll("\\\\") catch {},
            else => writer.writeByte(c) catch {},
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "writeJsonEscaped passes plain text through unchanged" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    writeJsonEscaped(stream.writer(), "Speakers L/R");
    try std.testing.expectEqualStrings("Speakers L/R", stream.getWritten());
}

test "writeJsonEscaped escapes quotes and backslashes" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    writeJsonEscaped(stream.writer(), "Output \"1\" \\ 2");
    try std.testing.expectEqualStrings("Output \\\"1\\\" \\\\ 2", stream.getWritten());
}

test "hw output handlers compile" {
    // Command handlers require ResponseWriter with SharedState.
    // Integration tests via websocat verify full behavior.
}
