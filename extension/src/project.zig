const std = @import("std");
const reaper = @import("reaper.zig");
const protocol = @import("protocol.zig");

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

    // Project identity (for project switch detection and frontend display)
    project_pointer: ?*anyopaque = null, // ReaProject* (identifies tab, not file!)
    project_path_buf: [512]u8 = undefined, // Full path to .rpp file
    project_path_len: usize = 0,
    project_name_buf: [128]u8 = undefined, // Filename only
    project_name_len: usize = 0,

    // Project-level settings (low-frequency, moved from transport event)
    project_length: f64 = 0, // Project length in seconds
    repeat: bool = false,
    metronome_enabled: bool = false,
    metronome_volume: f64 = 1.0, // Linear amplitude (0.0-4.0)
    bar_offset: c_int = 0, // Project bar offset (e.g., -4 means time 0 = bar 1, display starts at -4)
    master_stereo: bool = true, // Master track stereo mode (false = mono L+R summed)
    is_dirty: bool = false, // Project has unsaved changes
    frame_rate: f64 = 30.0, // Project frame rate (e.g., 29.97, 24, 25)
    drop_frame: bool = false, // True for drop-frame timecode (29.97/59.94)

    // Memory warning flag - set externally from tiered arena usage monitoring
    // When true, frontend should warn user about high memory utilization
    memory_warning: bool = false,

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

    // Get project name (empty string for unsaved projects)
    pub fn projectName(self: *const State) []const u8 {
        return self.project_name_buf[0..self.project_name_len];
    }

    // Get project path (empty string for unsaved projects)
    pub fn projectPath(self: *const State) []const u8 {
        return self.project_path_buf[0..self.project_path_len];
    }

    /// Check if project changed (for resetting playlist engine state).
    ///
    /// Handles these scenarios while REAPER is running:
    /// - Tab switch: pointer differs → change
    /// - Open file in same tab: state count decreases (resets on load) → change
    /// - Save As: pointer same, count increases → NO change
    /// - Normal editing: pointer same, count increases → NO change
    ///
    /// Note: REAPER restart is a non-issue - extension restarts too, so there's
    /// no prior state to compare against. We start fresh.
    ///
    /// Parameters:
    /// - self: the PREVIOUS state (what we had before)
    /// - other: the CURRENT state (what we just polled)
    pub fn projectChanged(self: *const State, other: *const State) bool {
        // Different pointer = different tab
        if (self.project_pointer != other.project_pointer) return true;

        // Same pointer but state count decreased = project replaced in this tab
        // (state count increases monotonically during editing, resets on project load)
        if (other.state_change_count < self.state_change_count) return true;

        return false;
    }

    // Compare for change detection
    pub fn eql(self: *const State, other: *const State) bool {
        // Project identity (pointer AND path for reliable switch detection)
        if (self.project_pointer != other.project_pointer) return false;
        if (!std.mem.eql(u8, self.projectPath(), other.projectPath())) return false;
        if (self.state_change_count != other.state_change_count) return false;
        if (self.repeat != other.repeat) return false;
        if (self.metronome_enabled != other.metronome_enabled) return false;
        if (@abs(self.metronome_volume - other.metronome_volume) > 0.001) return false;
        if (@abs(self.project_length - other.project_length) > 0.001) return false;
        if (self.bar_offset != other.bar_offset) return false;
        if (self.master_stereo != other.master_stereo) return false;
        if (self.is_dirty != other.is_dirty) return false;
        if (@abs(self.frame_rate - other.frame_rate) > 0.001) return false;
        if (self.drop_frame != other.drop_frame) return false;
        if (self.memory_warning != other.memory_warning) return false;
        return true;
    }

    // Truncate to 3 decimal places (matching REAPER's display behavior)
    fn truncateMs(val: f64) f64 {
        return @trunc(val * 1000.0) / 1000.0;
    }

    /// Poll current state from REAPER.
    /// Accepts any backend type (RealBackend, MockBackend, or test doubles).
    pub fn poll(api: anytype) State {
        // Master mono toggle: action 40917, state 1 = mono, 0 = stereo
        const master_mono_state = api.getCommandState(40917);
        const frame_info = api.getFrameRate();

        var state = State{
            .state_change_count = api.projectStateChangeCount(),
            .project_length = api.projectLength(),
            .repeat = api.getRepeat(),
            .metronome_enabled = api.isMetronomeEnabled(),
            .metronome_volume = api.getMetronomeVolume(),
            .bar_offset = api.getBarOffset(),
            .master_stereo = master_mono_state != 1, // 1 = mono, so stereo = not mono
            .is_dirty = api.isDirty(),
            .frame_rate = frame_info.frame_rate,
            .drop_frame = frame_info.drop_frame,
        };

        // Get project identity (pointer + path)
        if (api.enumCurrentProject(&state.project_path_buf)) |info| {
            state.project_pointer = info.project;
            state.project_path_len = info.path.len;
        }

        // Get project name (filename only)
        const name = api.getProjectName(state.project_pointer, &state.project_name_buf);
        state.project_name_len = name.len;

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

        // Write project name (escaped, or null for unsaved)
        writer.writeAll(",\"projectName\":") catch return null;
        const name = self.projectName();
        if (name.len > 0) {
            writer.writeByte('"') catch return null;
            protocol.writeJsonString(writer, name) catch return null;
            writer.writeByte('"') catch return null;
        } else {
            writer.writeAll("null") catch return null;
        }

        // Write project path (escaped, or null for unsaved)
        writer.writeAll(",\"projectPath\":") catch return null;
        const path = self.projectPath();
        if (path.len > 0) {
            writer.writeByte('"') catch return null;
            protocol.writeJsonString(writer, path) catch return null;
            writer.writeByte('"') catch return null;
        } else {
            writer.writeAll("null") catch return null;
        }

        // Write remaining fields
        writer.print(",\"stateChangeCount\":{d},\"repeat\":{s},\"metronome\":{{\"enabled\":{s},\"volume\":{d:.4},\"volumeDb\":{d:.2}}},\"master\":{{\"stereoEnabled\":{s}}},\"projectLength\":{d:.3},\"barOffset\":{d},\"isDirty\":{s},\"frameRate\":{d:.4},\"dropFrame\":{s},\"memoryWarning\":{s}}}}}", .{
            self.state_change_count,
            if (self.repeat) "true" else "false",
            if (self.metronome_enabled) "true" else "false",
            self.metronome_volume,
            metro_vol_db,
            if (self.master_stereo) "true" else "false",
            project_length,
            self.bar_offset,
            if (self.is_dirty) "true" else "false",
            self.frame_rate,
            if (self.drop_frame) "true" else "false",
            if (self.memory_warning) "true" else "false",
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
        .frame_rate = 29.97,
        .drop_frame = true,
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
    try std.testing.expect(std.mem.indexOf(u8, json, "\"frameRate\":29.97") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"dropFrame\":true") != null);
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
// MockBackend-based tests
// =============================================================================

const MockBackend = reaper.MockBackend;

test "poll with MockBackend returns configured values" {
    var mock = MockBackend{
        .project_state_change_count = 42,
        .project_length = 180.5,
        .repeat_enabled = true,
        .metronome_enabled = true,
        .metronome_volume = 0.5,
        .bar_offset = -4,
        .project_dirty = true,
        .frame_rate = 29.97,
        .drop_frame = true,
    };
    // Set master mono state (command 40917): 0 = stereo, 1 = mono
    mock.setCommandState(40917, 0); // stereo

    const state = State.poll(&mock);

    try std.testing.expectEqual(@as(c_int, 42), state.state_change_count);
    try std.testing.expect(@abs(state.project_length - 180.5) < 0.001);
    try std.testing.expect(state.repeat);
    try std.testing.expect(state.metronome_enabled);
    try std.testing.expect(@abs(state.metronome_volume - 0.5) < 0.001);
    try std.testing.expectEqual(@as(c_int, -4), state.bar_offset);
    try std.testing.expect(state.master_stereo);
    try std.testing.expect(state.is_dirty);
    try std.testing.expect(@abs(state.frame_rate - 29.97) < 0.001);
    try std.testing.expect(state.drop_frame);
}

test "poll with MockBackend returns undo/redo descriptions" {
    var mock = MockBackend{
        .project_state_change_count = 10,
    };
    mock.setUndoDesc("Add marker");
    mock.setRedoDesc("Delete region");

    const state = State.poll(&mock);

    try std.testing.expectEqualStrings("Add marker", state.canUndo().?);
    try std.testing.expectEqualStrings("Delete region", state.canRedo().?);
}

test "poll with MockBackend handles no undo/redo" {
    var mock = MockBackend{
        .project_state_change_count = 0,
    };
    // Don't set any undo/redo descriptions

    const state = State.poll(&mock);

    try std.testing.expect(state.canUndo() == null);
    try std.testing.expect(state.canRedo() == null);
}

test "poll with MockBackend detects master mono mode" {
    var mock = MockBackend{};
    // Set master mono state (command 40917): 1 = mono
    mock.setCommandState(40917, 1);

    const state = State.poll(&mock);

    // master_stereo should be false when mono is enabled
    try std.testing.expect(!state.master_stereo);
}

test "poll tracks API calls correctly" {
    var mock = MockBackend{};
    _ = State.poll(&mock);

    // Verify key API calls were made
    try std.testing.expect(mock.getCallCount(.projectStateChangeCount) >= 1);
    try std.testing.expect(mock.getCallCount(.projectLength) >= 1);
    try std.testing.expect(mock.getCallCount(.getRepeat) >= 1);
    try std.testing.expect(mock.getCallCount(.isMetronomeEnabled) >= 1);
    try std.testing.expect(mock.getCallCount(.getMetronomeVolume) >= 1);
    try std.testing.expect(mock.getCallCount(.getBarOffset) >= 1);
    try std.testing.expect(mock.getCallCount(.isDirty) >= 1);
    try std.testing.expect(mock.getCallCount(.getFrameRate) >= 1);
    try std.testing.expect(mock.getCallCount(.getCommandState) >= 1);
    try std.testing.expect(mock.getCallCount(.canUndo) >= 1);
    try std.testing.expect(mock.getCallCount(.canRedo) >= 1);
}

// =============================================================================
// projectChanged() tests
// =============================================================================

fn makeStateWithPointerAndCount(pointer: ?*anyopaque, state_count: c_int) State {
    var state = State{ .state_change_count = state_count };
    state.project_pointer = pointer;
    return state;
}

test "projectChanged: tab switch (different pointer) → change" {
    const ptr1: *anyopaque = @ptrFromInt(0x1000);
    const ptr2: *anyopaque = @ptrFromInt(0x2000);
    const prev = makeStateWithPointerAndCount(ptr1, 100);
    const curr = makeStateWithPointerAndCount(ptr2, 50);

    try std.testing.expect(prev.projectChanged(&curr));
}

test "projectChanged: open file in same tab (state count decreases) → change" {
    const ptr: *anyopaque = @ptrFromInt(0x1000);
    const prev = makeStateWithPointerAndCount(ptr, 100);
    const curr = makeStateWithPointerAndCount(ptr, 5); // Reset to low value on load

    try std.testing.expect(prev.projectChanged(&curr));
}

test "projectChanged: Save As (same pointer, state count increases) → NO change" {
    const ptr: *anyopaque = @ptrFromInt(0x1000);
    const prev = makeStateWithPointerAndCount(ptr, 100);
    const curr = makeStateWithPointerAndCount(ptr, 101); // Increased

    try std.testing.expect(!prev.projectChanged(&curr));
}

test "projectChanged: normal editing (same pointer, state count increases) → NO change" {
    const ptr: *anyopaque = @ptrFromInt(0x1000);
    const prev = makeStateWithPointerAndCount(ptr, 100);
    const curr = makeStateWithPointerAndCount(ptr, 150);

    try std.testing.expect(!prev.projectChanged(&curr));
}

test "projectChanged: undo (same pointer, state count same) → NO change" {
    const ptr: *anyopaque = @ptrFromInt(0x1000);
    const prev = makeStateWithPointerAndCount(ptr, 100);
    const curr = makeStateWithPointerAndCount(ptr, 100);

    try std.testing.expect(!prev.projectChanged(&curr));
}
