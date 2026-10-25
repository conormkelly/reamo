const std = @import("std");
const utf8 = @import("../core/utf8.zig");
const reaper = @import("../reaper.zig");
const protocol = @import("../core/protocol.zig");

/// Which project is open, as far as telling one project from another needs.
pub const Identity = struct {
    pointer: ?*anyopaque = null,
    loads: u32 = 0, // project loads seen (platform/project_load)
    has_path: bool = false,

    pub fn current(api: anytype) Identity {
        var path_buf: [512]u8 = undefined;
        const info = api.enumCurrentProject(&path_buf);
        return .{
            .pointer = if (info) |i| i.project else null,
            .loads = api.projectLoadCount(),
            .has_path = if (info) |i| i.path.len > 0 else false,
        };
    }

    /// Whether `now` is a different project from `self`, as opposed to the
    /// same project edited or saved:
    /// - another tab: the ReaProject* differs;
    /// - a project opened in this tab: a project load happened in between
    ///   (the pointer stays the same and REAPER's state-change count only
    ///   rises, so neither tells);
    /// - File > New in this tab: the saved project's path becomes empty.
    /// Save As changes the path but is the same project; undo reloads state
    /// but is not counted as a load.
    pub fn isDifferentFrom(self: Identity, now: Identity) bool {
        if (self.pointer != now.pointer) return true;
        if (self.loads != now.loads) return true;
        return self.has_path and !now.has_path;
    }

    /// Whether `now` replaced this project in the same tab, so this project
    /// is gone and its pointer names the new one.
    pub fn replacedBy(self: Identity, now: Identity) bool {
        return self.pointer == now.pointer and self.isDifferentFrom(now);
    }
};

// Project state snapshot
// Contains: undo/redo state + project-level settings (moved from transport for efficiency)
pub const State = struct {
    load_count: u32 = 0, // project loads seen (see projectChanged)
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
    count_in_playback: bool = false,
    count_in_record: bool = false,
    pre_roll_play: bool = false,
    pre_roll_record: bool = false,
    bar_offset: c_int = 0, // Project bar offset (e.g., -4 means time 0 = bar 1, display starts at -4)
    master_stereo: bool = true, // Master track stereo mode (false = mono L+R summed)
    is_dirty: bool = false, // Project has unsaved changes
    frame_rate: f64 = 30.0, // Project frame rate (e.g., 29.97, 24, 25)
    drop_frame: bool = false, // True for drop-frame timecode (29.97/59.94)
    record_mode: u8 = 0, // 0=normal, 1=time selection auto-punch, 2=selected items auto-punch
    sample_rate: u32 = 48000, // Audio engine sample rate (Hz)

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

    pub fn identity(self: *const State) Identity {
        return .{ .pointer = self.project_pointer, .loads = self.load_count, .has_path = self.project_path_len > 0 };
    }

    /// Whether `other` (just polled) is a different project from `self`.
    pub fn projectChanged(self: *const State, other: *const State) bool {
        return self.identity().isDifferentFrom(other.identity());
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
        if (self.count_in_playback != other.count_in_playback) return false;
        if (self.count_in_record != other.count_in_record) return false;
        if (self.pre_roll_play != other.pre_roll_play) return false;
        if (self.pre_roll_record != other.pre_roll_record) return false;
        if (@abs(self.project_length - other.project_length) > 0.001) return false;
        if (self.bar_offset != other.bar_offset) return false;
        if (self.master_stereo != other.master_stereo) return false;
        if (self.is_dirty != other.is_dirty) return false;
        if (@abs(self.frame_rate - other.frame_rate) > 0.001) return false;
        if (self.drop_frame != other.drop_frame) return false;
        if (self.record_mode != other.record_mode) return false;
        if (self.sample_rate != other.sample_rate) return false;
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

        // Record mode: check toggle states for auto-punch actions
        // 40076 = time selection auto-punch, 40253 = selected items auto-punch
        const record_mode: u8 = if (api.getCommandStateEx(0, 40253) == 1)
            2 // selected items auto-punch
        else if (api.getCommandStateEx(0, 40076) == 1)
            1 // time selection auto-punch
        else
            0; // normal

        const api_rate = api.getSampleRate();

        var state = State{
            .load_count = api.projectLoadCount(),
            .state_change_count = api.projectStateChangeCount(),
            .project_length = api.projectLength(),
            .sample_rate = if (api_rate > 0) api_rate else 48000,
            .repeat = api.getRepeat(),
            .metronome_enabled = api.isMetronomeEnabled(),
            .metronome_volume = api.getMetronomeVolume(),
            .count_in_playback = api.getCountInPlayback(),
            .count_in_record = api.getCountInRecord(),
            .pre_roll_play = api.isPreRollPlay(),
            .pre_roll_record = api.isPreRollRecord(),
            .bar_offset = api.getBarOffset(),
            .master_stereo = master_mono_state != 1, // 1 = mono, so stereo = not mono
            .is_dirty = api.isDirty(),
            .frame_rate = frame_info.frame_rate,
            .drop_frame = frame_info.drop_frame,
            .record_mode = record_mode,
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
            const len = utf8.copyPrefix(state.undo_buf[0 .. state.undo_buf.len - 1], desc);
            state.undo_buf[len] = 0;
            state.undo_len = len;
        }

        // Copy redo description if available
        if (api.canRedo()) |desc| {
            const len = utf8.copyPrefix(state.redo_buf[0 .. state.redo_buf.len - 1], desc);
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
        writer.print(",\"stateChangeCount\":{d},\"repeat\":{s},\"metronome\":{{\"enabled\":{s},\"volume\":{d:.4},\"volumeDb\":{d:.2}}},\"countIn\":{{\"playback\":{s},\"recording\":{s}}},\"preRoll\":{{\"playback\":{s},\"recording\":{s}}},\"master\":{{\"stereoEnabled\":{s}}},\"projectLength\":{d:.3},\"barOffset\":{d},\"isDirty\":{s},\"frameRate\":{d:.4},\"dropFrame\":{s},\"recordMode\":{d},\"sampleRate\":{d},\"memoryWarning\":{s}}}}}", .{
            self.state_change_count,
            if (self.repeat) "true" else "false",
            if (self.metronome_enabled) "true" else "false",
            self.metronome_volume,
            metro_vol_db,
            if (self.count_in_playback) "true" else "false",
            if (self.count_in_record) "true" else "false",
            if (self.pre_roll_play) "true" else "false",
            if (self.pre_roll_record) "true" else "false",
            if (self.master_stereo) "true" else "false",
            project_length,
            self.bar_offset,
            if (self.is_dirty) "true" else "false",
            self.frame_rate,
            if (self.drop_frame) "true" else "false",
            self.record_mode,
            self.sample_rate,
            if (self.memory_warning) "true" else "false",
        }) catch return null;

        return stream.getWritten();
    }

    // Allocator-based version - returns owned slice from allocator
    /// Sized to fit: the undo/redo descriptions, project name and path have
    /// no fixed total, and a dropped project event freezes every client's
    /// undo, redo, repeat and metronome state.
    pub fn toJsonAlloc(self: *const State, allocator: std.mem.Allocator) ![]const u8 {
        return protocol.serializeAlloc(allocator, 1024, self, toJson);
    }
};

// Tests
test "toJsonAlloc keeps the event whatever the undo, redo and path lengths" {
    // REAmo's own undo names ("REAmo: FX bypass toggle: Track 3 <name>: <fx>")
    // plus a project in a deep folder pass 1 KB easily.
    var state = State{};
    @memset(state.undo_buf[0..255], 'u');
    state.undo_len = 255;
    @memset(state.redo_buf[0..255], 'r');
    state.redo_len = 255;
    @memset(state.project_path_buf[0..511], 'p');
    state.project_path_len = 511;
    @memset(state.project_name_buf[0..127], 'n');
    state.project_name_len = 127;

    const json = try state.toJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expect(json.len > 1024);
    try std.testing.expect(std.mem.endsWith(u8, json, "}}"));
}

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

fn projectState(pointer: usize, loads: u32, path: []const u8) State {
    var state = State{ .load_count = loads, .state_change_count = 100 };
    state.project_pointer = @ptrFromInt(pointer);
    @memcpy(state.project_path_buf[0..path.len], path);
    state.project_path_len = path.len;
    return state;
}

test "projectChanged: switching to another tab is a change" {
    const prev = projectState(0x1000, 3, "/songs/a.rpp");
    try std.testing.expect(prev.projectChanged(&projectState(0x2000, 3, "/songs/b.rpp")));
    try std.testing.expect(!prev.identity().replacedBy(projectState(0x2000, 3, "/songs/b.rpp").identity()));
}

test "projectChanged: opening a project in the same tab is a change, even though REAPER's state count rises" {
    const prev = projectState(0x1000, 3, "/songs/gig.rpp");
    const curr = projectState(0x1000, 4, "/songs/other.rpp");
    try std.testing.expect(prev.projectChanged(&curr));
    try std.testing.expect(prev.identity().replacedBy(curr.identity()));
    // Reopening the same file is a load too.
    try std.testing.expect(prev.projectChanged(&projectState(0x1000, 4, "/songs/gig.rpp")));
}

test "projectChanged: File > New in the same tab is a change" {
    const prev = projectState(0x1000, 3, "/songs/gig.rpp");
    try std.testing.expect(prev.projectChanged(&projectState(0x1000, 3, "")));
}

test "projectChanged: editing, saving, Save As and undo are not" {
    const prev = projectState(0x1000, 3, "/songs/gig.rpp");
    try std.testing.expect(!prev.projectChanged(&projectState(0x1000, 3, "/songs/gig.rpp")));
    try std.testing.expect(!prev.projectChanged(&projectState(0x1000, 3, "/songs/gig-v2.rpp")));
    try std.testing.expect(!projectState(0x1000, 3, "").projectChanged(&projectState(0x1000, 3, "/songs/new.rpp")));
}
