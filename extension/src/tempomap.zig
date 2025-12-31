const std = @import("std");
const reaper = @import("reaper.zig");

/// Maximum number of tempo markers to track
const MAX_MARKERS: usize = 64;

/// Tempo map state - polls tempo markers from REAPER
pub const State = struct {
    count: c_int = 0,
    markers: [MAX_MARKERS]reaper.Api.TempoMarker = undefined,
    // For change detection, we track a simple hash of positions + BPMs
    hash: u64 = 0,

    /// Poll current tempo markers from REAPER
    pub fn poll(api: *const reaper.Api) State {
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
