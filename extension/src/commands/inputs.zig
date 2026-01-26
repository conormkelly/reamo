const std = @import("std");
const protocol = @import("../core/protocol.zig");
const mod = @import("mod.zig");
const tracks = @import("tracks.zig");
const logging = @import("../core/logging.zig");

// ============================================================================
// I_RECINPUT Encoding/Decoding Constants
// ============================================================================

const MIDI_FLAG: c_int = 4096; // Bit 12 - indicates MIDI input
const STEREO_FLAG: c_int = 1024; // Bit 10 - stereo audio
const MULTI_FLAG: c_int = 2048; // Bit 11 - multichannel audio
const REAROUTE_OFFSET: c_int = 512; // ReaRoute channels start here
const MIDI_CHANNEL_MASK: c_int = 0x1F; // Bits 0-4
const MIDI_DEVICE_MASK: c_int = 0x3F; // Bits 5-10 (6 bits)
const AUDIO_CHANNEL_MASK: c_int = 0x3FF; // Bits 0-9 (10 bits)

// Special MIDI device indices
const MIDI_DEVICE_VKB: c_int = 62;
const MIDI_DEVICE_ALL: c_int = 63;

// ============================================================================
// input/enumerateAudio
// ============================================================================

pub fn handleEnumerateAudio(api: anytype, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const count = api.numAudioInputs();

    // Use scratch arena for dynamic-sized response
    const tiered = mod.g_ctx.tiered orelse {
        response.err("NOT_INITIALIZED", "Tiered arenas not initialized");
        return;
    };
    const allocator = tiered.scratchAllocator();

    // Estimate: ~60 bytes per input (JSON overhead + name)
    const estimated_size: usize = @intCast(@max(2048, @as(c_int, @intCast(count)) * 60 + 100));
    const buf = allocator.alloc(u8, estimated_size) catch {
        response.err("ALLOC_FAILED", "Failed to allocate response buffer");
        return;
    };

    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    writer.writeAll("{\"inputs\":[") catch {
        response.err("SERIALIZE_ERROR", "Failed to write response");
        return;
    };

    var first = true;
    var i: c_int = 0;
    while (i < count) : (i += 1) {
        const name_ptr = api.audioInputName(i);
        const name_str = if (name_ptr) |n| std.mem.span(n) else "Unknown";

        if (!first) writer.writeAll(",") catch {};
        first = false;

        // Escape quotes in name for JSON safety
        writer.print("{{\"idx\":{d},\"name\":\"", .{i}) catch continue;
        for (name_str) |c| {
            switch (c) {
                '"' => writer.writeAll("\\\"") catch {},
                '\\' => writer.writeAll("\\\\") catch {},
                else => writer.writeByte(c) catch {},
            }
        }
        writer.writeAll("\"}") catch {};
    }

    writer.writeAll("]}") catch {};

    // Use large payload - input list can exceed 512-byte response buffer
    const payload = stream.getWritten();
    response.successLargePayload(payload);
}

// ============================================================================
// input/enumerateMidi
// ============================================================================

pub fn handleEnumerateMidi(api: anytype, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const max_devices = api.maxMidiInputs();

    const tiered = mod.g_ctx.tiered orelse {
        response.err("NOT_INITIALIZED", "Tiered arenas not initialized");
        return;
    };
    const allocator = tiered.scratchAllocator();

    // Estimate: ~80 bytes per device (including name)
    const estimated_size: usize = @intCast(@max(4096, @as(c_int, @intCast(max_devices)) * 80 + 300));
    const buf = allocator.alloc(u8, estimated_size) catch {
        response.err("ALLOC_FAILED", "Failed to allocate response buffer");
        return;
    };

    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    writer.writeAll("{\"devices\":[") catch {
        response.err("SERIALIZE_ERROR", "Failed to write response");
        return;
    };

    var first = true;
    var name_buf: [256]u8 = undefined;

    // Enumerate hardware devices (skip 62, 63 - added as virtual entries below)
    var i: c_int = 0;
    while (i < max_devices) : (i += 1) {
        if (i == 62 or i == 63) continue;
        if (api.midiInputName(i, &name_buf, 256)) {
            if (!first) writer.writeAll(",") catch {};
            first = false;

            const name_len = std.mem.indexOfScalar(u8, &name_buf, 0) orelse 255;

            // Escape quotes in name for JSON safety
            writer.print("{{\"idx\":{d},\"name\":\"", .{i}) catch continue;
            for (name_buf[0..name_len]) |c| {
                switch (c) {
                    '"' => writer.writeAll("\\\"") catch {},
                    '\\' => writer.writeAll("\\\\") catch {},
                    else => writer.writeByte(c) catch {},
                }
            }
            writer.writeAll("\"}") catch {};
        }
    }

    // Add special virtual entries (always present)
    if (!first) writer.writeAll(",") catch {};
    writer.writeAll("{\"idx\":62,\"name\":\"Virtual MIDI Keyboard\"}") catch {};
    writer.writeAll(",{\"idx\":63,\"name\":\"All MIDI Inputs\"}") catch {};

    writer.writeAll("]}") catch {};

    // Use large payload - device list can exceed 512-byte response buffer
    response.successLargePayload(stream.getWritten());
}

// ============================================================================
// track/getInput
// ============================================================================

pub fn handleGetInput(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const resolution = tracks.resolveTrack(api, cmd) orelse {
        response.err("NOT_FOUND", "trackIdx or trackGuid required, or track not found");
        return;
    };

    const raw_value = api.getTrackRecInput(resolution.track);

    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    if (raw_value < 0) {
        // No input
        writer.writeAll("{\"type\":\"none\",\"raw\":-1}") catch {
            response.err("SERIALIZE_ERROR", "Failed to format response");
            return;
        };
    } else if ((raw_value & MIDI_FLAG) != 0) {
        // MIDI input
        const channel = raw_value & MIDI_CHANNEL_MASK;
        const device = (raw_value >> 5) & MIDI_DEVICE_MASK;
        writer.print("{{\"type\":\"midi\",\"raw\":{d},\"device\":{d},\"channel\":{d},\"isVKB\":{},\"isAll\":{}}}", .{
            raw_value,
            device,
            channel,
            device == MIDI_DEVICE_VKB,
            device == MIDI_DEVICE_ALL,
        }) catch {
            response.err("SERIALIZE_ERROR", "Failed to format response");
            return;
        };
    } else {
        // Audio input
        const channel_idx = raw_value & AUDIO_CHANNEL_MASK;
        const is_stereo = (raw_value & STEREO_FLAG) != 0;
        const is_multi = (raw_value & MULTI_FLAG) != 0;
        const is_rearoute = channel_idx >= REAROUTE_OFFSET;
        const actual_channel = if (is_rearoute) channel_idx - REAROUTE_OFFSET else channel_idx;

        writer.print("{{\"type\":\"audio\",\"raw\":{d},\"channel\":{d},\"stereo\":{},\"multi\":{},\"rearoute\":{}}}", .{
            raw_value,
            actual_channel,
            is_stereo,
            is_multi,
            is_rearoute,
        }) catch {
            response.err("SERIALIZE_ERROR", "Failed to format response");
            return;
        };
    }

    response.success(stream.getWritten());
}

// ============================================================================
// track/setInput
// ============================================================================

pub fn handleSetInput(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const resolution = tracks.resolveTrack(api, cmd) orelse {
        response.err("NOT_FOUND", "trackIdx or trackGuid required, or track not found");
        return;
    };

    // Check if raw value provided (bypass encoding)
    if (cmd.getInt("raw")) |raw_value| {
        if (!api.setTrackRecInput(resolution.track, raw_value)) {
            response.err("SET_FAILED", "Failed to set track input");
            return;
        }
        logging.debug("Set track {d} input to raw={d}", .{ resolution.idx, raw_value });
        response.success(null);
        return;
    }

    // Otherwise, encode from parameters
    const input_type = cmd.getString("inputType") orelse {
        response.err("INVALID_PARAMS", "inputType required (none, audio, midi)");
        return;
    };

    var value: c_int = -1;

    if (std.mem.eql(u8, input_type, "none")) {
        value = -1;
    } else if (std.mem.eql(u8, input_type, "audio")) {
        const channel = cmd.getInt("channel") orelse {
            response.err("INVALID_PARAMS", "channel required for audio input");
            return;
        };
        const stereo = if (cmd.getInt("stereo")) |v| v != 0 else false;
        const multi = if (cmd.getInt("multi")) |v| v != 0 else false;
        const rearoute = if (cmd.getInt("rearoute")) |v| v != 0 else false;

        value = channel;
        if (rearoute) value += REAROUTE_OFFSET;
        if (multi) {
            value |= MULTI_FLAG;
        } else if (stereo) {
            value |= STEREO_FLAG;
        }
    } else if (std.mem.eql(u8, input_type, "midi")) {
        const device = cmd.getInt("device") orelse {
            response.err("INVALID_PARAMS", "device required for MIDI input (0-61, 62=VKB, 63=all)");
            return;
        };
        const channel = cmd.getInt("channel") orelse 0; // 0 = all channels

        if (device < 0 or device > 63) {
            response.err("INVALID_PARAMS", "MIDI device must be 0-63");
            return;
        }
        if (channel < 0 or channel > 16) {
            response.err("INVALID_PARAMS", "MIDI channel must be 0-16 (0=all)");
            return;
        }

        value = MIDI_FLAG + channel + (device << 5);
    } else {
        response.err("INVALID_PARAMS", "inputType must be none, audio, or midi");
        return;
    }

    if (!api.setTrackRecInput(resolution.track, value)) {
        response.err("SET_FAILED", "Failed to set track input");
        return;
    }

    logging.debug("Set track {d} input to {d}", .{ resolution.idx, value });
    response.success(null);
}

// ============================================================================
// Encoding/Decoding Helper Functions (for testing)
// ============================================================================

/// Encode audio input to I_RECINPUT value
fn encodeAudioInput(channel: c_int, stereo: bool, multi: bool, rearoute: bool) c_int {
    var value = channel;
    if (rearoute) value += REAROUTE_OFFSET;
    if (multi) {
        value |= MULTI_FLAG;
    } else if (stereo) {
        value |= STEREO_FLAG;
    }
    return value;
}

/// Encode MIDI input to I_RECINPUT value
fn encodeMidiInput(device: c_int, channel: c_int) c_int {
    return MIDI_FLAG + channel + (device << 5);
}

/// Decoded audio input result
const DecodedAudio = struct {
    channel: c_int,
    stereo: bool,
    multi: bool,
    rearoute: bool,
};

/// Decoded MIDI input result
const DecodedMidi = struct {
    device: c_int,
    channel: c_int,
    is_vkb: bool,
    is_all: bool,
};

/// Decode I_RECINPUT value - returns null for "none", audio, or midi
fn decodeRecInput(value: c_int) union(enum) { none, audio: DecodedAudio, midi: DecodedMidi } {
    if (value < 0) return .none;

    if ((value & MIDI_FLAG) != 0) {
        const channel = value & MIDI_CHANNEL_MASK;
        const device = (value >> 5) & MIDI_DEVICE_MASK;
        return .{ .midi = .{
            .device = device,
            .channel = channel,
            .is_vkb = device == MIDI_DEVICE_VKB,
            .is_all = device == MIDI_DEVICE_ALL,
        } };
    }

    const channel_idx = value & AUDIO_CHANNEL_MASK;
    const is_rearoute = channel_idx >= REAROUTE_OFFSET;
    return .{ .audio = .{
        .channel = if (is_rearoute) channel_idx - REAROUTE_OFFSET else channel_idx,
        .stereo = (value & STEREO_FLAG) != 0,
        .multi = (value & MULTI_FLAG) != 0,
        .rearoute = is_rearoute,
    } };
}

// ============================================================================
// Tests - I_RECINPUT Encoding (from research/REC_INPUT_SELECTION.md)
// ============================================================================

test "audio encoding - mono channel 1" {
    // First mono audio channel (ch 1) = index 0
    try std.testing.expectEqual(@as(c_int, 0), encodeAudioInput(0, false, false, false));
}

test "audio encoding - mono channel 8" {
    // 8th mono channel (index 7)
    try std.testing.expectEqual(@as(c_int, 7), encodeAudioInput(7, false, false, false));
}

test "audio encoding - stereo 1+2" {
    // First stereo pair (ch 1+2) = 0 + 1024 = 1024
    try std.testing.expectEqual(@as(c_int, 1024), encodeAudioInput(0, true, false, false));
}

test "audio encoding - stereo 3+4" {
    // Stereo 3+4 = 2 + 1024 = 1026
    try std.testing.expectEqual(@as(c_int, 1026), encodeAudioInput(2, true, false, false));
}

test "audio encoding - stereo 7+8" {
    // Stereo 7+8 = 6 + 1024 = 1030
    try std.testing.expectEqual(@as(c_int, 1030), encodeAudioInput(6, true, false, false));
}

test "audio encoding - multichannel from ch 1" {
    // Multichannel from ch 1 = 0 + 2048 = 2048
    try std.testing.expectEqual(@as(c_int, 2048), encodeAudioInput(0, false, true, false));
}

test "audio encoding - ReaRoute mono ch 1" {
    // ReaRoute mono ch 1 = 512 + 0 = 512
    try std.testing.expectEqual(@as(c_int, 512), encodeAudioInput(0, false, false, true));
}

test "audio encoding - ReaRoute stereo 1+2" {
    // ReaRoute stereo 1+2 = 512 + 0 + 1024 = 1536
    try std.testing.expectEqual(@as(c_int, 1536), encodeAudioInput(0, true, false, true));
}

test "audio encoding - ReaRoute stereo 3+4" {
    // ReaRoute stereo 3+4 = 512 + 2 + 1024 = 1538
    try std.testing.expectEqual(@as(c_int, 1538), encodeAudioInput(2, true, false, true));
}

// ============================================================================
// Tests - MIDI Encoding
// ============================================================================

test "midi encoding - device 0, all channels" {
    // Device 0, all channels = 4096 + 0 + (0 << 5) = 4096
    try std.testing.expectEqual(@as(c_int, 4096), encodeMidiInput(0, 0));
}

test "midi encoding - device 0, channel 1" {
    // Device 0, channel 1 = 4096 + 1 + (0 << 5) = 4097
    try std.testing.expectEqual(@as(c_int, 4097), encodeMidiInput(0, 1));
}

test "midi encoding - device 1, all channels" {
    // Device 1, all channels = 4096 + 0 + (1 << 5) = 4096 + 32 = 4128
    try std.testing.expectEqual(@as(c_int, 4128), encodeMidiInput(1, 0));
}

test "midi encoding - device 0, channel 10" {
    // First MIDI device, channel 10 = 4096 + 10 + 0 = 4106
    try std.testing.expectEqual(@as(c_int, 4106), encodeMidiInput(0, 10));
}

test "midi encoding - all inputs, all channels" {
    // All inputs (63), all channels = 4096 + 0 + (63 << 5) = 4096 + 2016 = 6112
    try std.testing.expectEqual(@as(c_int, 6112), encodeMidiInput(63, 0));
}

test "midi encoding - all inputs, channel 10" {
    // All inputs, channel 10 = 4096 + 10 + (63 << 5) = 4096 + 10 + 2016 = 6122
    try std.testing.expectEqual(@as(c_int, 6122), encodeMidiInput(63, 10));
}

test "midi encoding - virtual keyboard, all channels" {
    // Virtual keyboard (62), all channels = 4096 + 0 + (62 << 5) = 4096 + 1984 = 6080
    try std.testing.expectEqual(@as(c_int, 6080), encodeMidiInput(62, 0));
}

test "midi encoding - virtual keyboard, channel 1" {
    // Virtual keyboard, channel 1 = 4096 + 1 + (62 << 5) = 6081
    try std.testing.expectEqual(@as(c_int, 6081), encodeMidiInput(62, 1));
}

// ============================================================================
// Tests - Decoding
// ============================================================================

test "decode - no input" {
    const result = decodeRecInput(-1);
    try std.testing.expect(result == .none);
}

test "decode - mono audio" {
    const result = decodeRecInput(7);
    try std.testing.expect(result == .audio);
    try std.testing.expectEqual(@as(c_int, 7), result.audio.channel);
    try std.testing.expect(!result.audio.stereo);
    try std.testing.expect(!result.audio.multi);
    try std.testing.expect(!result.audio.rearoute);
}

test "decode - stereo audio" {
    const result = decodeRecInput(1024); // stereo 1+2
    try std.testing.expect(result == .audio);
    try std.testing.expectEqual(@as(c_int, 0), result.audio.channel);
    try std.testing.expect(result.audio.stereo);
    try std.testing.expect(!result.audio.multi);
}

test "decode - ReaRoute stereo" {
    const result = decodeRecInput(1536); // ReaRoute stereo 1+2
    try std.testing.expect(result == .audio);
    try std.testing.expectEqual(@as(c_int, 0), result.audio.channel);
    try std.testing.expect(result.audio.stereo);
    try std.testing.expect(result.audio.rearoute);
}

test "decode - MIDI device 0" {
    const result = decodeRecInput(4096);
    try std.testing.expect(result == .midi);
    try std.testing.expectEqual(@as(c_int, 0), result.midi.device);
    try std.testing.expectEqual(@as(c_int, 0), result.midi.channel);
    try std.testing.expect(!result.midi.is_vkb);
    try std.testing.expect(!result.midi.is_all);
}

test "decode - MIDI all inputs" {
    const result = decodeRecInput(6112);
    try std.testing.expect(result == .midi);
    try std.testing.expectEqual(@as(c_int, 63), result.midi.device);
    try std.testing.expectEqual(@as(c_int, 0), result.midi.channel);
    try std.testing.expect(result.midi.is_all);
}

test "decode - MIDI virtual keyboard" {
    const result = decodeRecInput(6080);
    try std.testing.expect(result == .midi);
    try std.testing.expectEqual(@as(c_int, 62), result.midi.device);
    try std.testing.expect(result.midi.is_vkb);
}

test "decode - MIDI with specific channel" {
    const result = decodeRecInput(4106); // device 0, channel 10
    try std.testing.expect(result == .midi);
    try std.testing.expectEqual(@as(c_int, 0), result.midi.device);
    try std.testing.expectEqual(@as(c_int, 10), result.midi.channel);
}

// ============================================================================
// Tests - Round-trip (encode then decode)
// ============================================================================

test "roundtrip - audio stereo" {
    const encoded = encodeAudioInput(2, true, false, false);
    const decoded = decodeRecInput(encoded);
    try std.testing.expect(decoded == .audio);
    try std.testing.expectEqual(@as(c_int, 2), decoded.audio.channel);
    try std.testing.expect(decoded.audio.stereo);
    try std.testing.expect(!decoded.audio.rearoute);
}

test "roundtrip - ReaRoute multichannel" {
    const encoded = encodeAudioInput(4, false, true, true);
    const decoded = decodeRecInput(encoded);
    try std.testing.expect(decoded == .audio);
    try std.testing.expectEqual(@as(c_int, 4), decoded.audio.channel);
    try std.testing.expect(decoded.audio.multi);
    try std.testing.expect(decoded.audio.rearoute);
}

test "roundtrip - MIDI device with channel" {
    const encoded = encodeMidiInput(5, 16);
    const decoded = decodeRecInput(encoded);
    try std.testing.expect(decoded == .midi);
    try std.testing.expectEqual(@as(c_int, 5), decoded.midi.device);
    try std.testing.expectEqual(@as(c_int, 16), decoded.midi.channel);
}
