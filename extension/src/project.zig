const std = @import("std");
const reaper = @import("reaper.zig");

// Project state snapshot (undo/redo availability)
pub const State = struct {
    state_change_count: c_int = 0,

    // Storage for string copies (REAPER returns temporary pointers)
    // Null-terminated, length tracked separately to avoid self-referential slices
    undo_buf: [256]u8 = undefined,
    redo_buf: [256]u8 = undefined,
    undo_len: usize = 0,
    redo_len: usize = 0,

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

    // Compare for change detection (only uses state_change_count for efficiency)
    pub fn eql(self: *const State, other: *const State) bool {
        return self.state_change_count == other.state_change_count;
    }

    // Poll current state from REAPER
    pub fn poll(api: *const reaper.Api) State {
        var state = State{
            .state_change_count = api.projectStateChangeCount(),
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
        const result = if (undo_desc != null and redo_desc != null)
            std.fmt.bufPrint(buf,
                \\{{"type":"event","event":"project","payload":{{"canUndo":"{s}","canRedo":"{s}","stateChangeCount":{d}}}}}
            , .{ undo_str, redo_str, self.state_change_count })
        else if (undo_desc != null)
            std.fmt.bufPrint(buf,
                \\{{"type":"event","event":"project","payload":{{"canUndo":"{s}","canRedo":null,"stateChangeCount":{d}}}}}
            , .{ undo_str, self.state_change_count })
        else if (redo_desc != null)
            std.fmt.bufPrint(buf,
                \\{{"type":"event","event":"project","payload":{{"canUndo":null,"canRedo":"{s}","stateChangeCount":{d}}}}}
            , .{ redo_str, self.state_change_count })
        else
            std.fmt.bufPrint(buf,
                \\{{"type":"event","event":"project","payload":{{"canUndo":null,"canRedo":null,"stateChangeCount":{d}}}}}
            , .{self.state_change_count});

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
test "State.eql compares state change count" {
    const a = State{ .state_change_count = 1 };
    const b = State{ .state_change_count = 1 };
    const c = State{ .state_change_count = 2 };

    try std.testing.expect(a.eql(&b));
    try std.testing.expect(!a.eql(&c));
}

test "State.toJson with both undo and redo" {
    var state = State{
        .state_change_count = 42,
    };
    const undo_desc = "Add region";
    const redo_desc = "Delete marker";
    @memcpy(state.undo_buf[0..undo_desc.len], undo_desc);
    @memcpy(state.redo_buf[0..redo_desc.len], redo_desc);
    state.undo_len = undo_desc.len;
    state.redo_len = redo_desc.len;

    var buf: [512]u8 = undefined;
    const json = state.toJson(&buf).?;

    try std.testing.expect(std.mem.indexOf(u8, json, "\"event\":\"project\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"canUndo\":\"Add region\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"canRedo\":\"Delete marker\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"stateChangeCount\":42") != null);
}

test "State.toJson with only undo" {
    var state = State{
        .state_change_count = 10,
    };
    const undo_desc = "Move item";
    @memcpy(state.undo_buf[0..undo_desc.len], undo_desc);
    state.undo_len = undo_desc.len;

    var buf: [512]u8 = undefined;
    const json = state.toJson(&buf).?;

    try std.testing.expect(std.mem.indexOf(u8, json, "\"canUndo\":\"Move item\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"canRedo\":null") != null);
}

test "State.toJson with neither" {
    const state = State{
        .state_change_count = 0,
    };

    var buf: [512]u8 = undefined;
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
