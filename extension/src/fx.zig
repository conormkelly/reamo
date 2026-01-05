const std = @import("std");
const Allocator = std.mem.Allocator;
const reaper = @import("reaper.zig");
const protocol = @import("protocol.zig");

// Maximum FX name length
pub const MAX_FX_NAME_LEN: usize = 128;

// Maximum FX per project (soft limit for arena sizing)
pub const MAX_FX: usize = 5000;

/// Single FX slot state in flattened model.
/// Each FX instance is a separate entry with track_idx reference.
pub const FxSlot = struct {
    track_idx: c_int = 0, // Parent track index (unified: 0=master, 1+=user tracks)
    fx_index: u16 = 0, // Position in FX chain (0-based)
    name: [MAX_FX_NAME_LEN]u8 = undefined,
    name_len: usize = 0,
    preset_name: [MAX_FX_NAME_LEN]u8 = undefined,
    preset_name_len: usize = 0,
    preset_index: c_int = -1, // -1 = no preset selected
    preset_count: c_int = 0,
    modified: bool = false, // True if params DON'T match preset
    enabled: bool = true, // FX bypass state

    pub fn getName(self: *const FxSlot) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn getPresetName(self: *const FxSlot) []const u8 {
        return self.preset_name[0..self.preset_name_len];
    }

    pub fn eql(self: FxSlot, other: FxSlot) bool {
        if (self.track_idx != other.track_idx) return false;
        if (self.fx_index != other.fx_index) return false;
        if (self.name_len != other.name_len) return false;
        if (!std.mem.eql(u8, self.name[0..self.name_len], other.name[0..other.name_len])) return false;
        if (self.preset_name_len != other.preset_name_len) return false;
        if (!std.mem.eql(u8, self.preset_name[0..self.preset_name_len], other.preset_name[0..other.preset_name_len])) return false;
        if (self.preset_index != other.preset_index) return false;
        if (self.preset_count != other.preset_count) return false;
        if (self.modified != other.modified) return false;
        if (self.enabled != other.enabled) return false;
        return true;
    }
};

/// FX state snapshot (all FX across all tracks)
/// Uses slice for arena-based allocation - no fixed size limit.
pub const State = struct {
    fx: []FxSlot = &.{},

    /// Return an empty state (for initialization)
    pub fn empty() State {
        return .{ .fx = &.{} };
    }

    /// Number of FX in this state
    pub fn count(self: *const State) usize {
        return self.fx.len;
    }

    /// Compare for change detection
    pub fn eql(self: *const State, other: *const State) bool {
        if (self.fx.len != other.fx.len) return false;
        for (self.fx, other.fx) |*a, *b| {
            if (!a.eql(b.*)) return false;
        }
        return true;
    }

    /// Poll current FX state from REAPER, allocating from the provided allocator.
    /// Iterates all tracks and collects all FX into a flat array.
    pub fn poll(allocator: Allocator, api: anytype) Allocator.Error!State {
        // First pass: count total FX across all tracks
        const track_count: usize = @intCast(@max(0, api.trackCount()) + 1); // +1 for master
        var total_fx: usize = 0;

        for (0..track_count) |i| {
            const track_idx: c_int = @intCast(i);
            if (api.getTrackByUnifiedIdx(track_idx)) |track| {
                const fx_count_raw = api.trackFxCount(track);
                const fx_count: usize = @intCast(@max(0, fx_count_raw));
                total_fx += fx_count;
            }
        }

        if (total_fx == 0) {
            return .{ .fx = &.{} };
        }

        // Allocate flat array
        const fx_slots = try allocator.alloc(FxSlot, total_fx);
        var slot_idx: usize = 0;

        // Second pass: populate FX data
        for (0..track_count) |i| {
            const track_idx: c_int = @intCast(i);
            if (api.getTrackByUnifiedIdx(track_idx)) |track| {
                const fx_count_raw = api.trackFxCount(track);
                const fx_count: usize = @intCast(@max(0, fx_count_raw));

                for (0..fx_count) |fx_i| {
                    const fx_idx: c_int = @intCast(fx_i);
                    var slot = &fx_slots[slot_idx];
                    slot.* = FxSlot{}; // Initialize with defaults

                    slot.track_idx = track_idx;
                    slot.fx_index = @intCast(fx_i);

                    // Get FX name
                    var name_buf: [MAX_FX_NAME_LEN]u8 = undefined;
                    const name = api.trackFxGetName(track, fx_idx, &name_buf);
                    const name_len = @min(name.len, MAX_FX_NAME_LEN);
                    @memcpy(slot.name[0..name_len], name[0..name_len]);
                    slot.name_len = name_len;

                    // Get preset index and count
                    var preset_count: c_int = 0;
                    slot.preset_index = api.trackFxGetPresetIndex(track, fx_idx, &preset_count);
                    slot.preset_count = preset_count;

                    // Get preset name and modified state
                    var preset_buf: [MAX_FX_NAME_LEN]u8 = undefined;
                    const preset_info = api.trackFxGetPreset(track, fx_idx, &preset_buf);
                    const preset_len = @min(preset_info.name.len, MAX_FX_NAME_LEN);
                    @memcpy(slot.preset_name[0..preset_len], preset_info.name[0..preset_len]);
                    slot.preset_name_len = preset_len;
                    slot.modified = !preset_info.matches_preset;

                    // Get enabled state (FX bypass)
                    slot.enabled = api.trackFxGetEnabled(track, fx_idx);

                    slot_idx += 1;
                }
            }
        }

        return .{ .fx = fx_slots };
    }

    /// Build JSON event for fx_state
    /// Format: {"type":"event","event":"fx_state","payload":{"fx":[...]}}
    pub fn toJson(self: *const State, buf: []u8) ?[]const u8 {
        var stream = std.io.fixedBufferStream(buf);
        const writer = stream.writer();

        writer.writeAll("{\"type\":\"event\",\"event\":\"fx_state\",\"payload\":{\"fx\":[") catch return null;

        for (self.fx, 0..) |*slot, i| {
            if (i > 0) writer.writeByte(',') catch return null;
            writer.print("{{\"trackIdx\":{d},\"fxIndex\":{d},\"name\":\"", .{
                slot.track_idx,
                slot.fx_index,
            }) catch return null;
            protocol.writeJsonString(writer, slot.getName()) catch return null;
            writer.writeAll("\",\"presetName\":\"") catch return null;
            protocol.writeJsonString(writer, slot.getPresetName()) catch return null;
            writer.print("\",\"presetIndex\":{d},\"presetCount\":{d},\"modified\":{s},\"enabled\":{s}}}", .{
                slot.preset_index,
                slot.preset_count,
                if (slot.modified) "true" else "false",
                if (slot.enabled) "true" else "false",
            }) catch return null;
        }

        writer.writeAll("]}}") catch return null;
        return stream.getWritten();
    }

    // Allocator-based version - returns owned slice from allocator
    pub fn toJsonAlloc(self: *const State, allocator: std.mem.Allocator) ![]const u8 {
        var buf: [32768]u8 = undefined;
        const json = self.toJson(&buf) orelse return error.JsonSerializationFailed;
        return allocator.dupe(u8, json);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "FxSlot.eql detects changes" {
    var a = FxSlot{ .track_idx = 1, .fx_index = 0, .enabled = true };
    var b = FxSlot{ .track_idx = 1, .fx_index = 0, .enabled = false };
    try std.testing.expect(!a.eql(b));

    b.enabled = true;
    try std.testing.expect(a.eql(b));
}

test "State.empty returns empty slice" {
    const state = State.empty();
    try std.testing.expectEqual(@as(usize, 0), state.fx.len);
}

test "State.count returns slice length" {
    var fx_buf: [5]FxSlot = undefined;
    const state = State{ .fx = fx_buf[0..5] };
    try std.testing.expectEqual(@as(usize, 5), state.count());
}

test "State.eql detects changes" {
    var fx_a: [2]FxSlot = undefined;
    var fx_b: [3]FxSlot = undefined;
    const a = State{ .fx = fx_a[0..2] };
    const b = State{ .fx = fx_b[0..3] };
    try std.testing.expect(!a.eql(&b));
}

test "State.toJson produces valid JSON" {
    var fx_buf: [2]FxSlot = undefined;
    fx_buf[0] = FxSlot{
        .track_idx = 1,
        .fx_index = 0,
        .preset_index = 5,
        .preset_count = 10,
        .modified = false,
        .enabled = true,
    };
    fx_buf[0].name[0..6].* = "Pro-Q3".*;
    fx_buf[0].name_len = 6;
    fx_buf[0].preset_name[0..7].* = "Default".*;
    fx_buf[0].preset_name_len = 7;

    fx_buf[1] = FxSlot{
        .track_idx = 1,
        .fx_index = 1,
        .preset_index = -1,
        .preset_count = 0,
        .modified = true,
        .enabled = false,
    };
    fx_buf[1].name[0..5].* = "LA-2A".*;
    fx_buf[1].name_len = 5;
    fx_buf[1].preset_name_len = 0;

    var state = State{ .fx = &fx_buf };
    var buf: [2048]u8 = undefined;
    const json = state.toJson(&buf).?;

    // Verify structure
    try std.testing.expect(std.mem.indexOf(u8, json, "\"event\":\"fx_state\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"trackIdx\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"fxIndex\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"fxIndex\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"Pro-Q3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"LA-2A\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"enabled\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"enabled\":false") != null);
}

// =============================================================================
// MockBackend-based tests
// =============================================================================

const MockBackend = reaper.MockBackend;

test "poll with MockBackend returns configured FX" {
    var mock = MockBackend{
        .track_count = 1, // 1 user track + master = 2 total
    };
    // Master track with 1 FX
    mock.tracks[0].setName("MASTER");
    mock.tracks[0].fx_count = 1;
    mock.tracks[0].fx[0].setName("Limiter");

    // Track 1 with 2 FX
    mock.tracks[1].setName("Drums");
    mock.tracks[1].fx_count = 2;
    mock.tracks[1].fx[0].setName("EQ");
    mock.tracks[1].fx[1].setName("Compressor");

    const state = try State.poll(std.testing.allocator, &mock);
    defer std.testing.allocator.free(state.fx);

    try std.testing.expectEqual(@as(usize, 3), state.fx.len);

    // Verify track indices
    try std.testing.expectEqual(@as(c_int, 0), state.fx[0].track_idx);
    try std.testing.expectEqual(@as(c_int, 1), state.fx[1].track_idx);
    try std.testing.expectEqual(@as(c_int, 1), state.fx[2].track_idx);

    // Verify FX indices
    try std.testing.expectEqual(@as(u16, 0), state.fx[0].fx_index);
    try std.testing.expectEqual(@as(u16, 0), state.fx[1].fx_index);
    try std.testing.expectEqual(@as(u16, 1), state.fx[2].fx_index);

    // Verify names
    try std.testing.expectEqualStrings("Limiter", state.fx[0].getName());
    try std.testing.expectEqualStrings("EQ", state.fx[1].getName());
    try std.testing.expectEqualStrings("Compressor", state.fx[2].getName());
}

test "poll with no FX returns empty state" {
    var mock = MockBackend{
        .track_count = 2,
    };
    // All tracks have 0 FX (default)

    const state = try State.poll(std.testing.allocator, &mock);
    // No defer needed - empty slice doesn't need freeing

    try std.testing.expectEqual(@as(usize, 0), state.fx.len);
}
