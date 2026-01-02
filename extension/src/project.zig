const std = @import("std");
const reaper = @import("reaper.zig");
const protocol = @import("protocol.zig");
const ApiInterface = reaper.api.ApiInterface;

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
    is_dirty: bool = false, // Project has unsaved changes

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
        if (self.is_dirty != other.is_dirty) return false;
        return true;
    }

    // Truncate to 3 decimal places (matching REAPER's display behavior)
    fn truncateMs(val: f64) f64 {
        return @trunc(val * 1000.0) / 1000.0;
    }

    /// Poll current state from REAPER using abstract interface.
    /// Enables unit testing without REAPER running.
    pub fn poll(api: ApiInterface) State {
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
            .is_dirty = api.isDirty(),
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
    // Uses protocol.writeJsonString() for consistent escaping across all modules
    pub fn toJson(self: *const State, buf: []u8) ?[]const u8 {
        const metro_vol_db = reaper.Api.linearToDb(self.metronome_volume);
        const project_length = truncateMs(self.project_length);

        var stream = std.io.fixedBufferStream(buf);
        const writer = stream.writer();

        writer.writeAll("{\"type\":\"event\",\"event\":\"project\",\"payload\":{\"canUndo\":") catch return null;

        // Write canUndo - either escaped string or null
        if (self.canUndo()) |desc| {
            writer.writeByte('"') catch return null;
            protocol.writeJsonString(writer, desc) catch return null;
            writer.writeByte('"') catch return null;
        } else {
            writer.writeAll("null") catch return null;
        }

        writer.writeAll(",\"canRedo\":") catch return null;

        // Write canRedo - either escaped string or null
        if (self.canRedo()) |desc| {
            writer.writeByte('"') catch return null;
            protocol.writeJsonString(writer, desc) catch return null;
            writer.writeByte('"') catch return null;
        } else {
            writer.writeAll("null") catch return null;
        }

        // Write remaining fields
        writer.print(",\"stateChangeCount\":{d},\"repeat\":{s},\"metronome\":{{\"enabled\":{s},\"volume\":{d:.4},\"volumeDb\":{d:.2}}},\"master\":{{\"stereoEnabled\":{s}}},\"projectLength\":{d:.3},\"barOffset\":{d},\"isDirty\":{s}}}}}", .{
            self.state_change_count,
            if (self.repeat) "true" else "false",
            if (self.metronome_enabled) "true" else "false",
            self.metronome_volume,
            metro_vol_db,
            if (self.master_stereo) "true" else "false",
            project_length,
            self.bar_offset,
            if (self.is_dirty) "true" else "false",
        }) catch return null;

        return stream.getWritten();
    }
};

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

    // Test is_dirty affects equality
    const h = State{ .is_dirty = true };
    const i = State{ .is_dirty = false };
    try std.testing.expect(!h.eql(&i));
}

test "State.toJson with both undo and redo" {
    var state = State{
        .state_change_count = 42,
        .repeat = true,
        .metronome_enabled = true,
        .metronome_volume = 0.5,
        .project_length = 180.5,
        .bar_offset = -4,
        .is_dirty = true,
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
    try std.testing.expect(std.mem.indexOf(u8, json, "\"isDirty\":true") != null);
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
        .is_dirty = false,
    };

    var buf: [1024]u8 = undefined;
    const json = state.toJson(&buf).?;

    try std.testing.expect(std.mem.indexOf(u8, json, "\"canUndo\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"canRedo\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"isDirty\":false") != null);
}

test "State.toJson escapes special characters in undo/redo" {
    var state = State{
        .state_change_count = 1,
    };
    const undo_desc = "Edit \"item\" notes";
    @memcpy(state.undo_buf[0..undo_desc.len], undo_desc);
    state.undo_len = undo_desc.len;

    var buf: [1024]u8 = undefined;
    const json = state.toJson(&buf).?;

    // Verify quotes are escaped
    try std.testing.expect(std.mem.indexOf(u8, json, "Edit \\\"item\\\" notes") != null);
}

// =============================================================================
// MockApi-based tests (Phase 8.4)
// =============================================================================

const MockApi = reaper.mock.MockApi;

test "poll with MockApi returns configured values" {
    var mock = MockApi{
        .project_state_change_count = 42,
        .project_length = 180.5,
        .repeat_enabled = true,
        .metronome_enabled = true,
        .metronome_volume = 0.5,
        .bar_offset = -4,
        .project_dirty = true,
    };
    // Set master mono state (command 40917): 0 = stereo, 1 = mono
    mock.setCommandState(40917, 0); // stereo

    const state = State.poll(mock.interface());

    try std.testing.expectEqual(@as(c_int, 42), state.state_change_count);
    try std.testing.expect(@abs(state.project_length - 180.5) < 0.001);
    try std.testing.expect(state.repeat);
    try std.testing.expect(state.metronome_enabled);
    try std.testing.expect(@abs(state.metronome_volume - 0.5) < 0.001);
    try std.testing.expectEqual(@as(c_int, -4), state.bar_offset);
    try std.testing.expect(state.master_stereo);
    try std.testing.expect(state.is_dirty);
}

test "poll with MockApi returns undo/redo descriptions" {
    var mock = MockApi{
        .project_state_change_count = 10,
    };
    mock.setUndoDesc("Add marker");
    mock.setRedoDesc("Delete region");

    const state = State.poll(mock.interface());

    try std.testing.expectEqualStrings("Add marker", state.canUndo().?);
    try std.testing.expectEqualStrings("Delete region", state.canRedo().?);
}

test "poll with MockApi handles no undo/redo" {
    var mock = MockApi{
        .project_state_change_count = 0,
    };
    // Don't set any undo/redo descriptions

    const state = State.poll(mock.interface());

    try std.testing.expect(state.canUndo() == null);
    try std.testing.expect(state.canRedo() == null);
}

test "poll with MockApi detects master mono mode" {
    var mock = MockApi{};
    // Set master mono state (command 40917): 1 = mono
    mock.setCommandState(40917, 1);

    const state = State.poll(mock.interface());

    // master_stereo should be false when mono is enabled
    try std.testing.expect(!state.master_stereo);
}

test "poll tracks API calls correctly" {
    var mock = MockApi{};
    _ = State.poll(mock.interface());

    // Verify key API calls were made
    try std.testing.expect(mock.getCallCount(.projectStateChangeCount) >= 1);
    try std.testing.expect(mock.getCallCount(.projectLength) >= 1);
    try std.testing.expect(mock.getCallCount(.getRepeat) >= 1);
    try std.testing.expect(mock.getCallCount(.isMetronomeEnabled) >= 1);
    try std.testing.expect(mock.getCallCount(.getMetronomeVolume) >= 1);
    try std.testing.expect(mock.getCallCount(.getBarOffset) >= 1);
    try std.testing.expect(mock.getCallCount(.isDirty) >= 1);
    try std.testing.expect(mock.getCallCount(.getCommandState) >= 1);
    try std.testing.expect(mock.getCallCount(.canUndo) >= 1);
    try std.testing.expect(mock.getCallCount(.canRedo) >= 1);
}
