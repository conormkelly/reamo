const std = @import("std");
const reaper = @import("reaper.zig");

/// Maximum number of tempo markers to track
const MAX_MARKERS: usize = 64;

/// Tempo map state - polls tempo markers from REAPER
pub const State = struct {
    count: c_int = 0,
    markers: [MAX_MARKERS]reaper.TempoMarker = undefined,
    // For change detection, we track a simple hash of positions + BPMs
    hash: u64 = 0,

    /// Poll current tempo markers from REAPER.
    /// Accepts any backend type (RealBackend, MockBackend, or test doubles).
    pub fn poll(api: anytype) State {
        var state = State{};
        state.count = api.tempoMarkerCount();

        // Limit to MAX_MARKERS
        const count: usize = @intCast(@min(state.count, MAX_MARKERS));

        var hash: u64 = 0;
        for (0..count) |i| {
            if (api.getTempoMarker(@intCast(i))) |marker| {
                state.markers[i] = marker;
                // Simple hash: XOR position bits and BPM bits
                hash ^= @bitCast(marker.position);
                hash ^= @bitCast(marker.bpm);
                hash ^= @as(u64, @intCast(marker.timesig_num)) << 32;
                hash ^= @as(u64, @intCast(marker.timesig_denom)) << 40;
            }
        }
        state.hash = hash;

        return state;
    }

    /// Check if tempo map changed from another state
    pub fn changed(self: *const State, other: *const State) bool {
        return self.count != other.count or self.hash != other.hash;
    }

    /// Build JSON event for tempo markers
    /// Format: {"type":"event","event":"tempoMap","payload":{"markers":[...]}}
    pub fn toJson(self: *const State, buf: []u8) ?[]const u8 {
        var stream = std.io.fixedBufferStream(buf);
        var writer = stream.writer();

        writer.writeAll("{\"type\":\"event\",\"event\":\"tempoMap\",\"payload\":{\"markers\":[") catch return null;

        const count: usize = @intCast(@min(self.count, MAX_MARKERS));
        for (0..count) |i| {
            if (i > 0) writer.writeAll(",") catch return null;

            const m = self.markers[i];
            writer.print("{{\"position\":{d:.15},\"positionBeats\":{d:.6},\"bpm\":{d:.2},\"timesigNum\":{d},\"timesigDenom\":{d},\"linear\":{s}}}", .{
                m.position,
                m.position_beats,
                m.bpm,
                m.timesig_num,
                m.timesig_denom,
                if (m.linear_tempo) "true" else "false",
            }) catch return null;
        }

        writer.writeAll("]}}") catch return null;

        return stream.getWritten();
    }
};

// Tests
test "State.poll returns empty for no markers" {
    // Can't test without REAPER API, but verify struct compiles
    const state = State{};
    try std.testing.expectEqual(@as(c_int, 0), state.count);
}

test "State.toJson empty markers" {
    const state = State{};
    var buf: [256]u8 = undefined;
    const json = state.toJson(&buf).?;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"markers\":[]") != null);
}

test "State.changed detects count change" {
    var a = State{ .count = 0, .hash = 0 };
    var b = State{ .count = 1, .hash = 0 };
    try std.testing.expect(a.changed(&b));
}

test "State.changed detects hash change" {
    var a = State{ .count = 1, .hash = 123 };
    var b = State{ .count = 1, .hash = 456 };
    try std.testing.expect(a.changed(&b));
}

// =============================================================================
// MockBackend-based tests
// =============================================================================

const MockBackend = reaper.MockBackend;

test "poll with MockBackend returns tempo markers" {
    var mock = MockBackend{
        .tempo_marker_count = 2,
    };
    mock.tempo_markers[0] = .{
        .position = 0.0,
        .position_beats = 0.0,
        .bpm = 120.0,
        .timesig_num = 4,
        .timesig_denom = 4,
        .linear_tempo = false,
    };
    mock.tempo_markers[1] = .{
        .position = 10.0,
        .position_beats = 20.0,
        .bpm = 140.0,
        .timesig_num = 3,
        .timesig_denom = 4,
        .linear_tempo = true,
    };

    const state = State.poll(&mock);

    try std.testing.expectEqual(@as(c_int, 2), state.count);
    try std.testing.expect(@abs(state.markers[0].bpm - 120.0) < 0.01);
    try std.testing.expect(@abs(state.markers[1].bpm - 140.0) < 0.01);
    try std.testing.expectEqual(@as(c_int, 4), state.markers[0].timesig_num);
    try std.testing.expectEqual(@as(c_int, 3), state.markers[1].timesig_num);
}

test "poll with MockBackend returns empty state for no markers" {
    var mock = MockBackend{
        .tempo_marker_count = 0,
    };

    const state = State.poll(&mock);

    try std.testing.expectEqual(@as(c_int, 0), state.count);
}

test "poll tracks API calls correctly" {
    var mock = MockBackend{
        .tempo_marker_count = 1,
    };
    mock.tempo_markers[0] = .{
        .position = 0.0,
        .position_beats = 0.0,
        .bpm = 120.0,
        .timesig_num = 4,
        .timesig_denom = 4,
        .linear_tempo = false,
    };

    _ = State.poll(&mock);

    // Verify key API calls were made
    try std.testing.expect(mock.getCallCount(.tempoMarkerCount) >= 1);
    try std.testing.expect(mock.getCallCount(.getTempoMarker) >= 1);
}
