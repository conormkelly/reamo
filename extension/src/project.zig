const std = @import("std");
const reaper = @import("reaper.zig");

// Project state snapshot
// Contains: undo/redo state + project-level settings (moved from transport for efficiency)
pub const State = struct {
    state_change_count: c_int = 0,

    // Storage for string copies (REAPER returns temporary pointers)
    // Null-terminated, length tracked separately to avoid self-referential slices
    undo_buf: [256]u8 = undefined,
    redo_buf: [256]u8 = undefined,
    undo_len: usize = 0,
    redo_len: usize = 0,

    // Project-level settings (low-frequency, moved from transport event)
    project_length: f64 = 0, // Project length in seconds
    repeat: bool = false,
    metronome_enabled: bool = false,
    metronome_volume: f64 = 1.0, // Linear amplitude (0.0-4.0)
    bar_offset: c_int = 0, // Project bar offset (e.g., -4 means time 0 = bar 1, display starts at -4)
    master_stereo: bool = true, // Master track stereo mode (false = mono L+R summed)

    // Get undo string (returns null if none)
    pub fn canUndo(self: *const State) ?[]const u8 {
        if (self.undo_len == 0) return null;
        return self.undo_buf[0..self.undo_len];
    }

    // Get redo string (returns null if none)
    pub fn canRedo(self: *const State) ?[]const u8 {
        if (self.redo_len == 0) return null;
        return self.redo_buf[0..self.redo_len];
    }

    // Compare for change detection
    pub fn eql(self: *const State, other: *const State) bool {
        if (self.state_change_count != other.state_change_count) return false;
        if (self.repeat != other.repeat) return false;
        if (self.metronome_enabled != other.metronome_enabled) return false;
        if (@abs(self.metronome_volume - other.metronome_volume) > 0.001) return false;
        if (@abs(self.project_length - other.project_length) > 0.001) return false;
        if (self.bar_offset != other.bar_offset) return false;
        if (self.master_stereo != other.master_stereo) return false;
        return true;
    }

    // Truncate to 3 decimal places (matching REAPER's display behavior)
    fn truncateMs(val: f64) f64 {
        return @trunc(val * 1000.0) / 1000.0;
    }

    // Poll current state from REAPER
    pub fn poll(api: *const reaper.Api) State {
        // Master mono toggle: action 40917, state 1 = mono, 0 = stereo
        const master_mono_state = api.getCommandState(40917);

        var state = State{
            .state_change_count = api.projectStateChangeCount(),
            .project_length = api.projectLength(),
            .repeat = api.getRepeat(),
            .metronome_enabled = api.isMetronomeEnabled(),
            .metronome_volume = api.getMetronomeVolume(),
            .bar_offset = api.getBarOffset(),
            .master_stereo = master_mono_state != 1, // 1 = mono, so stereo = not mono
        };

        // Copy undo description if available
        if (api.canUndo()) |desc| {
            const len = @min(desc.len, state.undo_buf.len - 1);
            @memcpy(state.undo_buf[0..len], desc[0..len]);
            state.undo_buf[len] = 0;
            state.undo_len = len;
        }

        // Copy redo description if available
        if (api.canRedo()) |desc| {
            const len = @min(desc.len, state.redo_buf.len - 1);
            @memcpy(state.redo_buf[0..len], desc[0..len]);
            state.redo_buf[len] = 0;
            state.redo_len = len;
        }

        return state;
    }

    // Build JSON event for this state
    pub fn toJson(self: *const State, buf: []u8) ?[]const u8 {
        const metro_vol_db = reaper.Api.linearToDb(self.metronome_volume);
        const project_length = truncateMs(self.project_length);

        // Escape JSON strings
        var undo_escaped: [512]u8 = undefined;
        var redo_escaped: [512]u8 = undefined;

        const undo_desc = self.canUndo();
        const redo_desc = self.canRedo();

        const undo_str = if (undo_desc) |desc|
            escapeJson(desc, &undo_escaped) orelse "null"
        else
            "null";

        const redo_str = if (redo_desc) |desc|
            escapeJson(desc, &redo_escaped) orelse "null"
        else
            "null";

        // Format: canUndo/canRedo are either "string" or null
        // Now includes project-level settings: repeat, metronome, master, projectLength, barOffset
        const master_stereo_str = if (self.master_stereo) "true" else "false";
        const result = if (undo_desc != null and redo_desc != null)
            std.fmt.bufPrint(buf,
                \\{{"type":"event","event":"project","payload":{{"canUndo":"{s}","canRedo":"{s}","stateChangeCount":{d},"repeat":{s},"metronome":{{"enabled":{s},"volume":{d:.4},"volumeDb":{d:.2}}},"master":{{"stereoEnabled":{s}}},"projectLength":{d:.3},"barOffset":{d}}}}}
            , .{ undo_str, redo_str, self.state_change_count, if (self.repeat) "true" else "false", if (self.metronome_enabled) "true" else "false", self.metronome_volume, metro_vol_db, master_stereo_str, project_length, self.bar_offset })
        else if (undo_desc != null)
            std.fmt.bufPrint(buf,
                \\{{"type":"event","event":"project","payload":{{"canUndo":"{s}","canRedo":null,"stateChangeCount":{d},"repeat":{s},"metronome":{{"enabled":{s},"volume":{d:.4},"volumeDb":{d:.2}}},"master":{{"stereoEnabled":{s}}},"projectLength":{d:.3},"barOffset":{d}}}}}
            , .{ undo_str, self.state_change_count, if (self.repeat) "true" else "false", if (self.metronome_enabled) "true" else "false", self.metronome_volume, metro_vol_db, master_stereo_str, project_length, self.bar_offset })
        else if (redo_desc != null)
            std.fmt.bufPrint(buf,
                \\{{"type":"event","event":"project","payload":{{"canUndo":null,"canRedo":"{s}","stateChangeCount":{d},"repeat":{s},"metronome":{{"enabled":{s},"volume":{d:.4},"volumeDb":{d:.2}}},"master":{{"stereoEnabled":{s}}},"projectLength":{d:.3},"barOffset":{d}}}}}
            , .{ redo_str, self.state_change_count, if (self.repeat) "true" else "false", if (self.metronome_enabled) "true" else "false", self.metronome_volume, metro_vol_db, master_stereo_str, project_length, self.bar_offset })
        else
            std.fmt.bufPrint(buf,
                \\{{"type":"event","event":"project","payload":{{"canUndo":null,"canRedo":null,"stateChangeCount":{d},"repeat":{s},"metronome":{{"enabled":{s},"volume":{d:.4},"volumeDb":{d:.2}}},"master":{{"stereoEnabled":{s}}},"projectLength":{d:.3},"barOffset":{d}}}}}
            , .{ self.state_change_count, if (self.repeat) "true" else "false", if (self.metronome_enabled) "true" else "false", self.metronome_volume, metro_vol_db, master_stereo_str, project_length, self.bar_offset });

        return result catch null;
    }
};

// Escape a string for JSON (handles quotes, backslashes, control chars)
// Also strips non-ASCII bytes to ensure valid UTF-8 output
fn escapeJson(input: []const u8, buf: []u8) ?[]const u8 {
    var i: usize = 0;
    for (input) |c| {
        if (i + 2 > buf.len) return null; // Need room for escape + char
        switch (c) {
            '"' => {
                buf[i] = '\\';
                buf[i + 1] = '"';
                i += 2;
            },
            '\\' => {
                buf[i] = '\\';
                buf[i + 1] = '\\';
                i += 2;
            },
            '\n' => {
                buf[i] = '\\';
                buf[i + 1] = 'n';
                i += 2;
            },
            '\r' => {
                buf[i] = '\\';
                buf[i + 1] = 'r';
                i += 2;
            },
            '\t' => {
                buf[i] = '\\';
                buf[i + 1] = 't';
                i += 2;
            },
            else => {
                // Skip control characters and non-ASCII bytes
                // (non-ASCII may be invalid UTF-8 from legacy REAPER strings)
                if (c < 0x20 or c >= 0x80) {
                    continue;
                }
                buf[i] = c;
                i += 1;
            },
        }
    }
    return buf[0..i];
}

// Tests
test "State.eql compares all fields" {
    const a = State{ .state_change_count = 1 };
    const b = State{ .state_change_count = 1 };
    const c = State{ .state_change_count = 2 };

    try std.testing.expect(a.eql(&b));
    try std.testing.expect(!a.eql(&c));

    // Test project-level settings affect equality
    const d = State{ .repeat = true };
    const e = State{ .repeat = false };
    try std.testing.expect(!d.eql(&e));

    const f = State{ .metronome_enabled = true };
    const g = State{ .metronome_enabled = false };
    try std.testing.expect(!f.eql(&g));
}

test "State.toJson with both undo and redo" {
    var state = State{
        .state_change_count = 42,
        .repeat = true,
        .metronome_enabled = true,
        .metronome_volume = 0.5,
        .project_length = 180.5,
        .bar_offset = -4,
    };
    const undo_desc = "Add region";
    const redo_desc = "Delete marker";
    @memcpy(state.undo_buf[0..undo_desc.len], undo_desc);
    @memcpy(state.redo_buf[0..redo_desc.len], redo_desc);
    state.undo_len = undo_desc.len;
    state.redo_len = redo_desc.len;

    var buf: [1024]u8 = undefined;
    const json = state.toJson(&buf).?;

    try std.testing.expect(std.mem.indexOf(u8, json, "\"event\":\"project\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"canUndo\":\"Add region\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"canRedo\":\"Delete marker\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"stateChangeCount\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"repeat\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"metronome\":{\"enabled\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"volume\":0.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"projectLength\":180.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"barOffset\":-4") != null);
}

test "State.toJson with only undo" {
    var state = State{
        .state_change_count = 10,
    };
    const undo_desc = "Move item";
    @memcpy(state.undo_buf[0..undo_desc.len], undo_desc);
    state.undo_len = undo_desc.len;

    var buf: [1024]u8 = undefined;
    const json = state.toJson(&buf).?;

    try std.testing.expect(std.mem.indexOf(u8, json, "\"canUndo\":\"Move item\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"canRedo\":null") != null);
}

test "State.toJson with neither" {
    const state = State{
        .state_change_count = 0,
    };

    var buf: [1024]u8 = undefined;
    const json = state.toJson(&buf).?;

    try std.testing.expect(std.mem.indexOf(u8, json, "\"canUndo\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"canRedo\":null") != null);
}

test "escapeJson handles special characters" {
    var buf: [64]u8 = undefined;

    // Quotes
    const result1 = escapeJson("say \"hello\"", &buf).?;
    try std.testing.expectEqualStrings("say \\\"hello\\\"", result1);

    // Backslash
    const result2 = escapeJson("path\\file", &buf).?;
    try std.testing.expectEqualStrings("path\\\\file", result2);

    // Newline
    const result3 = escapeJson("line1\nline2", &buf).?;
    try std.testing.expectEqualStrings("line1\\nline2", result3);
}
