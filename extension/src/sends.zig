const std = @import("std");
const Allocator = std.mem.Allocator;
const reaper = @import("reaper.zig");
const protocol = @import("protocol.zig");

// Maximum send destination name length
pub const MAX_SEND_NAME_LEN: usize = 128;

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
                    slot.muted = api.trackSendGetMute(track, send_idx);
                    slot.mode = api.trackSendGetMode(track, send_idx);

                    // Note: dest_track_idx and pan would require additional API calls
                    // For now, we leave them at defaults (can be enhanced later)

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
            writer.print("\",\"volume\":{d:.6},\"muted\":{s},\"mode\":{d}}}", .{
                slot.volume,
                if (slot.muted) "true" else "false",
                slot.mode,
            }) catch return null;
        }

        writer.writeAll("]}}") catch return null;
        return stream.getWritten();
    }

    // Allocator-based version - returns owned slice from allocator
    pub fn toJsonAlloc(self: *const State, allocator: std.mem.Allocator) ![]const u8 {
        var buf: [16384]u8 = undefined;
        const json = self.toJson(&buf) orelse return error.JsonSerializationFailed;
        return allocator.dupe(u8, json);
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
        .muted = false,
        .mode = 0,
    };
    sends_buf[0].dest_name[0..5].* = "Drums".*;
    sends_buf[0].dest_name_len = 5;

    sends_buf[1] = SendSlot{
        .src_track_idx = 2,
        .send_index = 0,
        .volume = 0.5,
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
    mock.tracks[1].sends[1].setDestName("Reverb");
    mock.tracks[1].sends[1].volume = 0.3;
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
