/// Mock project, undo, and extstate methods.
const std = @import("std");
const state = @import("state.zig");
const types = @import("../types.zig");

/// Project method implementations for MockBackend.
/// Called via @fieldParentPtr from the main MockBackend struct.
pub const ProjectMethods = struct {
    // =========================================================================
    // Project info
    // =========================================================================

    pub fn projectLength(self: anytype) f64 {
        self.recordCall(.projectLength);
        return self.project_length;
    }

    pub fn projectStateChangeCount(self: anytype) c_int {
        self.recordCall(.projectStateChangeCount);
        return self.project_state_change_count;
    }

    pub fn isDirty(self: anytype) bool {
        self.recordCall(.isDirty);
        return self.project_dirty;
    }

    pub fn markDirty(self: anytype) void {
        self.recordCall(.markDirty);
        self.project_dirty = true;
    }

    pub fn getFrameRate(self: anytype) types.FrameRateInfo {
        self.recordCall(.getFrameRate);
        return .{ .frame_rate = self.frame_rate, .drop_frame = self.drop_frame };
    }

    // =========================================================================
    // Command state
    // =========================================================================

    pub fn getCommandState(self: anytype, cmd: c_int) c_int {
        self.recordCall(.getCommandState);
        for (self.command_states[0..self.command_state_count]) |entry| {
            if (entry.cmd == cmd) return entry.state;
        }
        return -1;
    }

    pub fn isMetronomeEnabled(self: anytype) bool {
        self.recordCall(.isMetronomeEnabled);
        return self.metronome_enabled;
    }

    pub fn getMetronomeVolume(self: anytype) f64 {
        self.recordCall(.getMetronomeVolume);
        return self.metronome_volume;
    }

    pub fn setMetronomeVolume(self: anytype, vol: f64) void {
        self.recordCall(.setMetronomeVolume);
        self.metronome_volume = vol;
    }

    // =========================================================================
    // Undo/Redo
    // =========================================================================

    pub fn canUndo(self: anytype) ?[]const u8 {
        self.recordCall(.canUndo);
        if (self.undo_desc_len == 0) return null;
        return self.undo_desc[0..self.undo_desc_len];
    }

    pub fn canRedo(self: anytype) ?[]const u8 {
        self.recordCall(.canRedo);
        if (self.redo_desc_len == 0) return null;
        return self.redo_desc[0..self.redo_desc_len];
    }

    pub fn doUndo(self: anytype) bool {
        self.recordCall(.doUndo);
        if (self.undo_desc_len == 0) return false;
        // In mock, just clear undo and set redo
        @memcpy(self.redo_desc[0..self.undo_desc_len], self.undo_desc[0..self.undo_desc_len]);
        self.redo_desc_len = self.undo_desc_len;
        self.undo_desc_len = 0;
        return true;
    }

    pub fn doRedo(self: anytype) bool {
        self.recordCall(.doRedo);
        if (self.redo_desc_len == 0) return false;
        // In mock, just clear redo and set undo
        @memcpy(self.undo_desc[0..self.redo_desc_len], self.redo_desc[0..self.redo_desc_len]);
        self.undo_desc_len = self.redo_desc_len;
        self.redo_desc_len = 0;
        return true;
    }

    pub fn undoBeginBlock(self: anytype) void {
        self.recordCall(.undoBeginBlock);
        self.undo_block_active = true;
    }

    pub fn undoEndBlock(self: anytype, desc: [*:0]const u8, _: c_int) void {
        self.recordCall(.undoEndBlock);
        self.undo_block_active = false;
        // Set undo description from the block
        const desc_slice = std.mem.sliceTo(desc, 0);
        const len = @min(desc_slice.len, self.undo_desc.len);
        @memcpy(self.undo_desc[0..len], desc_slice[0..len]);
        self.undo_desc_len = len;
    }

    // =========================================================================
    // ExtState (global)
    // =========================================================================

    pub fn getExtStateValue(self: anytype, section: [*:0]const u8, key: [*:0]const u8) ?[]const u8 {
        self.recordCall(.getExtStateValue);
        const section_slice = std.mem.sliceTo(section, 0);
        const key_slice = std.mem.sliceTo(key, 0);
        for (self.ext_states[0..self.ext_state_count]) |entry| {
            if (std.mem.eql(u8, entry.section[0..entry.section_len], section_slice) and
                std.mem.eql(u8, entry.key[0..entry.key_len], key_slice))
            {
                return entry.value[0..entry.value_len];
            }
        }
        return null;
    }

    pub fn setExtStateValue(self: anytype, section: [*:0]const u8, key: [*:0]const u8, value: [*:0]const u8, persist: bool) void {
        self.recordCall(.setExtStateValue);
        _ = persist; // Mock doesn't differentiate persistence
        const section_slice = std.mem.sliceTo(section, 0);
        const key_slice = std.mem.sliceTo(key, 0);
        const value_slice = std.mem.sliceTo(value, 0);

        // Check if entry exists
        for (self.ext_states[0..self.ext_state_count]) |*entry| {
            if (std.mem.eql(u8, entry.section[0..entry.section_len], section_slice) and
                std.mem.eql(u8, entry.key[0..entry.key_len], key_slice))
            {
                // Update existing
                const vlen = @min(value_slice.len, entry.value.len);
                @memcpy(entry.value[0..vlen], value_slice[0..vlen]);
                entry.value_len = vlen;
                return;
            }
        }

        // Add new entry
        if (self.ext_state_count < self.ext_states.len) {
            var entry = &self.ext_states[self.ext_state_count];
            const slen = @min(section_slice.len, entry.section.len);
            @memcpy(entry.section[0..slen], section_slice[0..slen]);
            entry.section_len = slen;
            const klen = @min(key_slice.len, entry.key.len);
            @memcpy(entry.key[0..klen], key_slice[0..klen]);
            entry.key_len = klen;
            const vlen = @min(value_slice.len, entry.value.len);
            @memcpy(entry.value[0..vlen], value_slice[0..vlen]);
            entry.value_len = vlen;
            self.ext_state_count += 1;
        }
    }

    // =========================================================================
    // Project ExtState
    // =========================================================================

    pub fn getProjExtStateValue(self: anytype, extname: [*:0]const u8, key: [*:0]const u8, buf: []u8) ?[]const u8 {
        self.recordCall(.getProjExtStateValue);
        // Same as getExtStateValue for mock
        const section_slice = std.mem.sliceTo(extname, 0);
        const key_slice = std.mem.sliceTo(key, 0);
        for (self.ext_states[0..self.ext_state_count]) |entry| {
            if (std.mem.eql(u8, entry.section[0..entry.section_len], section_slice) and
                std.mem.eql(u8, entry.key[0..entry.key_len], key_slice))
            {
                const len = @min(entry.value_len, buf.len);
                @memcpy(buf[0..len], entry.value[0..len]);
                return buf[0..len];
            }
        }
        return null;
    }

    pub fn setProjExtStateValue(self: anytype, extname: [*:0]const u8, key: [*:0]const u8, value: [*:0]const u8) void {
        self.recordCall(.setProjExtStateValue);
        // Delegate to setExtStateValue (mock doesn't differentiate project vs global)
        self.setExtStateValue(extname, key, value, false);
    }

    // =========================================================================
    // Project notes
    // =========================================================================

    pub fn getProjectNotes(self: anytype, buf: []u8) []const u8 {
        self.recordCall(.getProjectNotes);
        const len = @min(self.project_notes_len, buf.len);
        @memcpy(buf[0..len], self.project_notes[0..len]);
        return buf[0..len];
    }

    pub fn setProjectNotes(self: anytype, notes: [*:0]const u8) void {
        self.recordCall(.setProjectNotes);
        const notes_slice = std.mem.sliceTo(notes, 0);
        const len = @min(notes_slice.len, self.project_notes.len);
        @memcpy(self.project_notes[0..len], notes_slice[0..len]);
        self.project_notes_len = len;
    }

    // =========================================================================
    // Named command lookup
    // =========================================================================

    pub fn namedCommandLookup(self: anytype, name: [*:0]const u8) c_int {
        self.recordCall(.namedCommandLookup);
        const name_slice = std.mem.sliceTo(name, 0);
        // Simple mock: return hash of name as command ID
        var hash: c_int = 0;
        for (name_slice) |c| {
            hash = hash *% 31 +% @as(c_int, c);
        }
        return if (hash < 0) -hash else hash;
    }

    // =========================================================================
    // MIDI
    // =========================================================================

    pub fn sendMidiCC(self: anytype, channel: c_int, cc: c_int, value: c_int) void {
        self.recordCall(.sendMidiCC);
        self.last_midi_channel = channel;
        self.last_midi_cc = cc;
        self.last_midi_value = value;
    }

    pub fn sendMidiPC(self: anytype, channel: c_int, program: c_int) void {
        self.recordCall(.sendMidiPC);
        self.last_midi_channel = channel;
        self.last_midi_program = program;
    }

    // =========================================================================
    // UI
    // =========================================================================

    pub fn updateTimeline(self: anytype) void {
        self.recordCall(.updateTimeline);
        self.timeline_updated = true;
    }
};
