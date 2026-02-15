/// Mock input enumeration methods for testing.
const std = @import("std");

/// Input method implementations for MockBackend.
/// Called via duck typing from the main MockBackend struct.
pub const InputsMethods = struct {
    // =========================================================================
    // Audio input enumeration
    // =========================================================================

    pub fn numAudioInputs(self: anytype) c_int {
        self.recordCall(.numAudioInputs);
        return self.audio_input_count;
    }

    pub fn audioInputName(self: anytype, channel: c_int) ?[*:0]const u8 {
        self.recordCall(.audioInputName);
        if (channel < 0 or channel >= self.audio_input_count) return null;

        // Return static names for testing
        const names = [_][*:0]const u8{
            "Input 1",  "Input 2",  "Input 3",  "Input 4",
            "Input 5",  "Input 6",  "Input 7",  "Input 8",
            "Input 9",  "Input 10", "Input 11", "Input 12",
            "Input 13", "Input 14", "Input 15", "Input 16",
        };
        const idx: usize = @intCast(channel);
        if (idx >= names.len) return null;
        return names[idx];
    }

    // =========================================================================
    // Audio output enumeration
    // =========================================================================

    pub fn numAudioOutputs(self: anytype) c_int {
        self.recordCall(.numAudioOutputs);
        return self.audio_output_count;
    }

    pub fn audioOutputName(self: anytype, channel: c_int) ?[*:0]const u8 {
        self.recordCall(.audioOutputName);
        if (channel < 0 or channel >= self.audio_output_count) return null;

        const names = [_][*:0]const u8{
            "Output 1",  "Output 2",  "Output 3",  "Output 4",
            "Output 5",  "Output 6",  "Output 7",  "Output 8",
            "Output 9",  "Output 10", "Output 11", "Output 12",
            "Output 13", "Output 14", "Output 15", "Output 16",
        };
        const idx: usize = @intCast(channel);
        if (idx >= names.len) return null;
        return names[idx];
    }

    // =========================================================================
    // MIDI input enumeration
    // =========================================================================

    pub fn maxMidiInputs(self: anytype) c_int {
        self.recordCall(.maxMidiInputs);
        return self.midi_input_count;
    }

    pub fn midiInputName(self: anytype, dev: c_int, name_buf: [*]u8, buf_size: c_int) bool {
        self.recordCall(.midiInputName);
        if (dev < 0 or dev >= self.midi_input_count) return false;

        // Return static names for testing
        const names = [_][]const u8{
            "MIDI Device 1",
            "MIDI Device 2",
            "IAC Driver Bus 1",
            "Virtual MIDI",
        };

        const idx: usize = @intCast(dev);
        if (idx >= names.len) return false;

        const name = names[idx];
        const len = @min(name.len, @as(usize, @intCast(buf_size - 1)));
        @memcpy(name_buf[0..len], name[0..len]);
        name_buf[len] = 0;
        return true;
    }

    // =========================================================================
    // Track input (I_RECINPUT)
    // =========================================================================

    pub fn getTrackRecInput(self: anytype, track: *anyopaque) c_int {
        self.recordCall(.getTrackRecInput);
        const idx = trackPtrToIdx(track);
        if (idx < 0 or idx >= @as(c_int, @intCast(self.tracks.len))) return -1;
        return self.tracks[@intCast(idx)].rec_input;
    }

    pub fn setTrackRecInput(self: anytype, track: *anyopaque, value: c_int) bool {
        self.recordCall(.setTrackRecInput);
        const idx = trackPtrToIdx(track);
        if (idx < 0 or idx >= @as(c_int, @intCast(self.tracks.len))) return false;
        self.tracks[@intCast(idx)].rec_input = value;
        return true;
    }
};

// Helper to decode track pointer (index-as-pointer pattern used by mock)
fn trackPtrToIdx(ptr: *anyopaque) c_int {
    return @intCast(@intFromPtr(ptr));
}
