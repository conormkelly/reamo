const std = @import("std");
const Allocator = std.mem.Allocator;
const reaper = @import("../reaper.zig");
const protocol = @import("../core/protocol.zig");
const constants = @import("../core/constants.zig");

// Re-export shared constant for backward compatibility
pub const MAX_SEND_NAME_LEN = constants.MAX_SEND_NAME_LEN;

// Maximum sends per project (soft limit for arena sizing)
pub const MAX_SENDS: usize = 3000;

/// Single send slot state in flattened model.
/// Each send instance is a separate entry with src_track_idx reference.
pub const SendSlot = struct {
    src_track_idx: c_int = 0, // Source track index (unified: 0=master, 1+=user tracks)
    dest_track_idx: c_int = 0, // Destination track index
    send_index: u16 = 0, // Position in send list (0-based)
    dest_name: [MAX_SEND_NAME_LEN]u8 = undefined,
    dest_name_len: usize = 0,
    volume: f64 = 1.0, // Linear, 1.0 = 0dB
    pan: f64 = 0.0, // -1.0..1.0
    muted: bool = false,
    mode: c_int = 0, // 0=post-fader, 1=pre-FX, 3=post-FX

    pub fn getDestName(self: *const SendSlot) []const u8 {
        return self.dest_name[0..self.dest_name_len];
    }

    pub fn eql(self: SendSlot, other: SendSlot) bool {
        if (self.src_track_idx != other.src_track_idx) return false;
        if (self.dest_track_idx != other.dest_track_idx) return false;
        if (self.send_index != other.send_index) return false;
        if (self.dest_name_len != other.dest_name_len) return false;
        if (!std.mem.eql(u8, self.dest_name[0..self.dest_name_len], other.dest_name[0..other.dest_name_len])) return false;
        if (@abs(self.volume - other.volume) > 0.001) return false;
        if (@abs(self.pan - other.pan) > 0.001) return false;
        if (self.muted != other.muted) return false;
        if (self.mode != other.mode) return false;
        return true;
    }
};

/// Hardware output slot state.
/// Represents a track's routing to a physical output.
pub const HwOutputSlot = struct {
    src_track_idx: c_int = 0, // Source track index (unified: 0=master, 1+=user tracks)
    hw_output_idx: u16 = 0, // Position in hw output list (0-based)
    output_name: [MAX_SEND_NAME_LEN]u8 = undefined,
    output_name_len: usize = 0,
    volume: f64 = 1.0, // Linear, 1.0 = 0dB
    pan: f64 = 0.0, // -1.0..1.0
    muted: bool = false,
    mode: c_int = 0, // 0=post-fader, 1=pre-FX, 3=post-FX

    pub fn getOutputName(self: *const HwOutputSlot) []const u8 {
        return self.output_name[0..self.output_name_len];
    }

    pub fn eql(self: HwOutputSlot, other: HwOutputSlot) bool {
        if (self.src_track_idx != other.src_track_idx) return false;
        if (self.hw_output_idx != other.hw_output_idx) return false;
        if (self.output_name_len != other.output_name_len) return false;
        if (!std.mem.eql(u8, self.output_name[0..self.output_name_len], other.output_name[0..other.output_name_len])) return false;
        if (@abs(self.volume - other.volume) > 0.001) return false;
        if (@abs(self.pan - other.pan) > 0.001) return false;
        if (self.muted != other.muted) return false;
        if (self.mode != other.mode) return false;
        return true;
    }
};

/// Sends state snapshot (all sends across all tracks)
/// Uses slice for arena-based allocation - no fixed size limit.
pub const State = struct {
    sends: []SendSlot = &.{},

    /// Return an empty state (for initialization)
    pub fn empty() State {
        return .{ .sends = &.{} };
    }

    /// Number of sends in this state
    pub fn count(self: *const State) usize {
        return self.sends.len;
    }

    /// Compare for change detection
    pub fn eql(self: *const State, other: *const State) bool {
        if (self.sends.len != other.sends.len) return false;
        for (self.sends, other.sends) |*a, *b| {
            if (!a.eql(b.*)) return false;
        }
        return true;
    }

    /// Poll current sends state from REAPER, allocating from the provided allocator.
    /// Iterates all tracks and collects all sends into a flat array.
    pub fn poll(allocator: Allocator, api: anytype) Allocator.Error!State {
        // First pass: count total sends across all tracks
        const track_count: usize = @intCast(@max(0, api.trackCount()) + 1); // +1 for master
        var total_sends: usize = 0;

        for (0..track_count) |i| {
            const track_idx: c_int = @intCast(i);
            if (api.getTrackByUnifiedIdx(track_idx)) |track| {
                const send_count_raw = api.trackSendCount(track);
                const send_count: usize = @intCast(@max(0, send_count_raw));
                total_sends += send_count;
            }
        }

        if (total_sends == 0) {
            return .{ .sends = &.{} };
        }

        // Allocate flat array
        const send_slots = try allocator.alloc(SendSlot, total_sends);
        var slot_idx: usize = 0;

        // Second pass: populate send data
        for (0..track_count) |i| {
            const track_idx: c_int = @intCast(i);
            if (api.getTrackByUnifiedIdx(track_idx)) |track| {
                const send_count_raw = api.trackSendCount(track);
                const send_count: usize = @intCast(@max(0, send_count_raw));

                for (0..send_count) |send_i| {
                    const send_idx: c_int = @intCast(send_i);
                    var slot = &send_slots[slot_idx];
                    slot.* = SendSlot{}; // Initialize with defaults

                    slot.src_track_idx = track_idx;
                    slot.send_index = @intCast(send_i);

                    // Get destination name
                    var name_buf: [MAX_SEND_NAME_LEN]u8 = undefined;
                    const dest_name = api.trackSendGetDestName(track, send_idx, &name_buf);
                    const name_len = @min(dest_name.len, MAX_SEND_NAME_LEN);
                    @memcpy(slot.dest_name[0..name_len], dest_name[0..name_len]);
                    slot.dest_name_len = name_len;

                    // Get send parameters
                    slot.volume = api.trackSendGetVolume(track, send_idx);
                    slot.pan = api.trackSendGetPan(track, send_idx);
                    slot.muted = api.trackSendGetMute(track, send_idx);
                    slot.mode = api.trackSendGetMode(track, send_idx) catch 0;

                    // Note: dest_track_idx would require additional API calls
                    // For now, we leave it at default (can be enhanced later)

                    slot_idx += 1;
                }
            }
        }

        return .{ .sends = send_slots };
    }

    /// Build JSON event for sends_state
    /// Format: {"type":"event","event":"sends_state","payload":{"sends":[...]}}
    pub fn toJson(self: *const State, buf: []u8) ?[]const u8 {
        var stream = std.io.fixedBufferStream(buf);
        const writer = stream.writer();

        writer.writeAll("{\"type\":\"event\",\"event\":\"sends_state\",\"payload\":{\"sends\":[") catch return null;

        for (self.sends, 0..) |*slot, i| {
            if (i > 0) writer.writeByte(',') catch return null;
            writer.print("{{\"srcTrackIdx\":{d},\"sendIndex\":{d},\"destName\":\"", .{
                slot.src_track_idx,
                slot.send_index,
            }) catch return null;
            protocol.writeJsonString(writer, slot.getDestName()) catch return null;
            writer.print("\",\"volume\":{d:.6},\"pan\":{d:.6},\"muted\":{s},\"mode\":{d}}}", .{
                slot.volume,
                slot.pan,
                if (slot.muted) "true" else "false",
                slot.mode,
            }) catch return null;
        }

        writer.writeAll("]}}") catch return null;
        return stream.getWritten();
    }

    /// Allocator-based version - dynamically sized, supports extreme projects.
    /// Estimates buffer size based on send count, allocates from arena, returns trimmed slice.
    pub fn toJsonAlloc(self: *const State, allocator: std.mem.Allocator) ![]const u8 {
        // Estimate: ~200 bytes per send (name + volume + pan + mode + JSON overhead) + 100 base
        const estimated_size = 100 + (self.sends.len * 200);
        const buf = try allocator.alloc(u8, estimated_size);
        const json = self.toJson(buf) orelse return error.JsonSerializationFailed;
        return json; // Return slice of allocated buffer (no copy needed, arena-owned)
    }
};

/// Hardware outputs state snapshot (all HW outputs across all tracks)
/// Uses slice for arena-based allocation - no fixed size limit.
pub const HwOutputsState = struct {
    hw_outputs: []HwOutputSlot = &.{},

    /// Return an empty state (for initialization)
    pub fn empty() HwOutputsState {
        return .{ .hw_outputs = &.{} };
    }

    /// Number of hw outputs in this state
    pub fn count(self: *const HwOutputsState) usize {
        return self.hw_outputs.len;
    }

    /// Compare for change detection
    pub fn eql(self: *const HwOutputsState, other: *const HwOutputsState) bool {
        if (self.hw_outputs.len != other.hw_outputs.len) return false;
        for (self.hw_outputs, other.hw_outputs) |*a, *b| {
            if (!a.eql(b.*)) return false;
        }
        return true;
    }

    /// Poll current HW outputs state from REAPER, allocating from the provided allocator.
    /// Iterates all tracks and collects all HW outputs into a flat array.
    pub fn poll(allocator: Allocator, api: anytype) Allocator.Error!HwOutputsState {
        // First pass: count total HW outputs across all tracks
        const track_count: usize = @intCast(@max(0, api.trackCount()) + 1); // +1 for master
        var total_hw_outputs: usize = 0;

        for (0..track_count) |i| {
            const track_idx: c_int = @intCast(i);
            if (api.getTrackByUnifiedIdx(track_idx)) |track| {
                const hw_count_raw = api.trackHwOutputCount(track);
                const hw_count: usize = @intCast(@max(0, hw_count_raw));
                total_hw_outputs += hw_count;
            }
        }

        if (total_hw_outputs == 0) {
            return .{ .hw_outputs = &.{} };
        }

        // Allocate flat array
        const hw_slots = try allocator.alloc(HwOutputSlot, total_hw_outputs);
        var slot_idx: usize = 0;

        // Second pass: populate HW output data
        for (0..track_count) |i| {
            const track_idx: c_int = @intCast(i);
            if (api.getTrackByUnifiedIdx(track_idx)) |track| {
                const hw_count_raw = api.trackHwOutputCount(track);
                const hw_count: usize = @intCast(@max(0, hw_count_raw));

                for (0..hw_count) |hw_i| {
                    const hw_idx: c_int = @intCast(hw_i);
                    var slot = &hw_slots[slot_idx];
                    slot.* = HwOutputSlot{}; // Initialize with defaults

                    slot.src_track_idx = track_idx;
                    slot.hw_output_idx = @intCast(hw_i);

                    // Note: output_name would require additional API lookup
                    // For now, we leave it empty (can be enhanced later)

                    // Get HW output parameters
                    slot.volume = api.trackHwOutputGetVolume(track, hw_idx);
                    slot.pan = api.trackHwOutputGetPan(track, hw_idx);
                    slot.muted = api.trackHwOutputGetMute(track, hw_idx);
                    slot.mode = api.trackHwOutputGetMode(track, hw_idx) catch 0;

                    slot_idx += 1;
                }
            }
        }

        return .{ .hw_outputs = hw_slots };
    }

    /// Build JSON event for hw_outputs_state
    /// Format: {"type":"event","event":"hw_outputs_state","payload":{"hwOutputs":[...]}}
    pub fn toJson(self: *const HwOutputsState, buf: []u8) ?[]const u8 {
        var stream = std.io.fixedBufferStream(buf);
        const writer = stream.writer();

        writer.writeAll("{\"type\":\"event\",\"event\":\"hw_outputs_state\",\"payload\":{\"hwOutputs\":[") catch return null;

        for (self.hw_outputs, 0..) |*slot, i| {
            if (i > 0) writer.writeByte(',') catch return null;
            writer.print("{{\"srcTrackIdx\":{d},\"hwOutputIdx\":{d},\"outputName\":\"", .{
                slot.src_track_idx,
                slot.hw_output_idx,
            }) catch return null;
            protocol.writeJsonString(writer, slot.getOutputName()) catch return null;
            writer.print("\",\"volume\":{d:.6},\"pan\":{d:.6},\"muted\":{s},\"mode\":{d}}}", .{
                slot.volume,
                slot.pan,
                if (slot.muted) "true" else "false",
                slot.mode,
            }) catch return null;
        }

        writer.writeAll("]}}") catch return null;
        return stream.getWritten();
    }

    /// Allocator-based version - dynamically sized, supports extreme projects.
    /// Estimates buffer size based on hw output count, allocates from arena, returns trimmed slice.
    pub fn toJsonAlloc(self: *const HwOutputsState, allocator: std.mem.Allocator) ![]const u8 {
        // Estimate: ~150 bytes per hw output (name + volume + pan + channel + JSON overhead) + 100 base
        const estimated_size = 100 + (self.hw_outputs.len * 150);
        const buf = try allocator.alloc(u8, estimated_size);
        const json = self.toJson(buf) orelse return error.JsonSerializationFailed;
        return json; // Return slice of allocated buffer (no copy needed, arena-owned)
    }
};

// =============================================================================
// Tests
// =============================================================================

test "SendSlot.eql detects changes" {
    var a = SendSlot{ .src_track_idx = 1, .send_index = 0, .muted = false };
    var b = SendSlot{ .src_track_idx = 1, .send_index = 0, .muted = true };
    try std.testing.expect(!a.eql(b));

    b.muted = false;
    try std.testing.expect(a.eql(b));
}

test "SendSlot.eql detects volume changes" {
    const a = SendSlot{ .src_track_idx = 1, .send_index = 0, .volume = 1.0 };
    const b = SendSlot{ .src_track_idx = 1, .send_index = 0, .volume = 0.5 };
    try std.testing.expect(!a.eql(b));
}

test "State.empty returns empty slice" {
    const state = State.empty();
    try std.testing.expectEqual(@as(usize, 0), state.sends.len);
}

test "State.count returns slice length" {
    var sends_buf: [5]SendSlot = undefined;
    const state = State{ .sends = sends_buf[0..5] };
    try std.testing.expectEqual(@as(usize, 5), state.count());
}

test "State.eql detects changes" {
    var sends_a: [2]SendSlot = undefined;
    var sends_b: [3]SendSlot = undefined;
    const a = State{ .sends = sends_a[0..2] };
    const b = State{ .sends = sends_b[0..3] };
    try std.testing.expect(!a.eql(&b));
}

test "State.toJson produces valid JSON" {
    var sends_buf: [2]SendSlot = undefined;
    sends_buf[0] = SendSlot{
        .src_track_idx = 1,
        .send_index = 0,
        .volume = 0.8,
        .pan = 0.25,
        .muted = false,
        .mode = 0,
    };
    sends_buf[0].dest_name[0..5].* = "Drums".*;
    sends_buf[0].dest_name_len = 5;

    sends_buf[1] = SendSlot{
        .src_track_idx = 2,
        .send_index = 0,
        .volume = 0.5,
        .pan = -0.5,
        .muted = true,
        .mode = 1,
    };
    sends_buf[1].dest_name[0..4].* = "Bass".*;
    sends_buf[1].dest_name_len = 4;

    var state = State{ .sends = &sends_buf };
    var buf: [2048]u8 = undefined;
    const json = state.toJson(&buf).?;

    // Verify structure
    try std.testing.expect(std.mem.indexOf(u8, json, "\"event\":\"sends_state\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"srcTrackIdx\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"srcTrackIdx\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"destName\":\"Drums\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"destName\":\"Bass\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"pan\":0.25") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"pan\":-0.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"muted\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"muted\":true") != null);
}

// =============================================================================
// MockBackend-based tests
// =============================================================================

const MockBackend = reaper.MockBackend;

test "poll with MockBackend returns configured sends" {
    var mock = MockBackend{
        .track_count = 2, // 2 user tracks + master = 3 total
    };
    // Master track with 0 sends
    mock.tracks[0].setName("MASTER");
    mock.tracks[0].send_count = 0;

    // Track 1 with 2 sends
    mock.tracks[1].setName("Drums");
    mock.tracks[1].send_count = 2;
    mock.tracks[1].sends[0].setDestName("Bus A");
    mock.tracks[1].sends[0].volume = 0.8;
    mock.tracks[1].sends[0].pan = 0.25;
    mock.tracks[1].sends[1].setDestName("Reverb");
    mock.tracks[1].sends[1].volume = 0.3;
    mock.tracks[1].sends[1].pan = -0.5;
    mock.tracks[1].sends[1].muted = true;

    // Track 2 with 1 send
    mock.tracks[2].setName("Bass");
    mock.tracks[2].send_count = 1;
    mock.tracks[2].sends[0].setDestName("Bus B");

    const state = try State.poll(std.testing.allocator, &mock);
    defer std.testing.allocator.free(state.sends);

    try std.testing.expectEqual(@as(usize, 3), state.sends.len);

    // Verify track indices
    try std.testing.expectEqual(@as(c_int, 1), state.sends[0].src_track_idx);
    try std.testing.expectEqual(@as(c_int, 1), state.sends[1].src_track_idx);
    try std.testing.expectEqual(@as(c_int, 2), state.sends[2].src_track_idx);

    // Verify send indices
    try std.testing.expectEqual(@as(u16, 0), state.sends[0].send_index);
    try std.testing.expectEqual(@as(u16, 1), state.sends[1].send_index);
    try std.testing.expectEqual(@as(u16, 0), state.sends[2].send_index);

    // Verify names
    try std.testing.expectEqualStrings("Bus A", state.sends[0].getDestName());
    try std.testing.expectEqualStrings("Reverb", state.sends[1].getDestName());
    try std.testing.expectEqualStrings("Bus B", state.sends[2].getDestName());

    // Verify pan values
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), state.sends[0].pan, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, -0.5), state.sends[1].pan, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), state.sends[2].pan, 0.001); // default

    // Verify mute state
    try std.testing.expect(!state.sends[0].muted);
    try std.testing.expect(state.sends[1].muted);
}

test "poll with no sends returns empty state" {
    var mock = MockBackend{
        .track_count = 2,
    };
    // All tracks have 0 sends (default)

    const state = try State.poll(std.testing.allocator, &mock);
    // No defer needed - empty slice doesn't need freeing

    try std.testing.expectEqual(@as(usize, 0), state.sends.len);
}
