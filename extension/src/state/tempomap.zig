const std = @import("std");
const protocol = @import("../core/protocol.zig");
const reaper = @import("../reaper.zig");

const Allocator = std.mem.Allocator;

/// What change detection keeps between polls. The markers themselves live
/// only as long as the frame that serializes them.
pub const Summary = struct {
    count: usize = 0,
    hash: u64 = 0,
};

/// Every tempo/time signature marker in the project.
pub const State = struct {
    markers: []const reaper.TempoMarker = &.{},
    hash: u64 = 0,

    /// Poll every tempo marker, however many the project has, into
    /// `allocator` (the frame's scratch arena; free with deinit otherwise).
    /// Accepts any backend type (RealBackend, MockBackend, or test doubles).
    pub fn poll(allocator: Allocator, api: anytype) Allocator.Error!State {
        const reported = api.tempoMarkerCount();
        // A negative count from REAPER means none.
        const n: usize = if (reported > 0) @intCast(reported) else 0;
        var buf = try allocator.alloc(reaper.TempoMarker, n);

        var len: usize = 0;
        var hasher = std.hash.Wyhash.init(0);
        for (0..n) |i| {
            // A marker REAPER can't return is left out rather than sent as
            // whatever the buffer held.
            const m = api.getTempoMarker(@intCast(i)) orelse continue;
            buf[len] = m;
            len += 1;
            hashMarker(&hasher, m);
        }
        if (len < n) buf = try allocator.realloc(buf, len);
        return .{ .markers = buf, .hash = hasher.final() };
    }

    pub fn deinit(self: State, allocator: Allocator) void {
        allocator.free(self.markers);
    }

    pub fn summary(self: *const State) Summary {
        return .{ .count = self.markers.len, .hash = self.hash };
    }

    /// Whether the map differs from the one summarized by `prev`.
    pub fn changed(self: *const State, prev: Summary) bool {
        return self.markers.len != prev.count or self.hash != prev.hash;
    }

    /// Build JSON event for tempo markers
    /// Format: {"type":"event","event":"tempoMap","payload":{"markers":[...]}}
    pub fn toJson(self: *const State, buf: []u8) ?[]const u8 {
        var stream = std.io.fixedBufferStream(buf);
        var writer = stream.writer();

        writer.writeAll("{\"type\":\"event\",\"event\":\"tempoMap\",\"payload\":{\"markers\":[") catch return null;

        for (self.markers, 0..) |m, i| {
            if (i > 0) writer.writeAll(",") catch return null;
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

    /// Sized to fit the whole map (~100 bytes per marker).
    pub fn toJsonAlloc(self: *const State, allocator: Allocator) ![]const u8 {
        return protocol.serializeAlloc(allocator, 256 + self.markers.len * 128, self, toJson);
    }
};

/// Every field a client shows feeds the hash, so any edit (a gradual tempo
/// toggled, two markers trading tempos) is a change.
fn hashMarker(hasher: *std.hash.Wyhash, m: reaper.TempoMarker) void {
    hasher.update(std.mem.asBytes(&m.position));
    hasher.update(std.mem.asBytes(&m.position_beats));
    hasher.update(std.mem.asBytes(&m.bpm));
    hasher.update(std.mem.asBytes(&m.timesig_num));
    hasher.update(std.mem.asBytes(&m.timesig_denom));
    hasher.update(&[_]u8{@intFromBool(m.linear_tempo)});
}

// Tests

/// A backend with `n` generated tempo markers (the mock holds only 8).
const Generated = struct {
    n: c_int,
    linear_at: ?c_int = null,
    swap_bpm: bool = false,
    null_at: ?c_int = null,

    pub fn tempoMarkerCount(self: *const Generated) c_int {
        return self.n;
    }

    pub fn getTempoMarker(self: *const Generated, idx: c_int) ?reaper.TempoMarker {
        if (idx < 0 or idx >= self.n) return null;
        if (self.null_at == idx) return null;
        var bpm: f64 = if (@mod(idx, 2) == 0) 120.0 else 90.0;
        if (self.swap_bpm and idx < 2) bpm = if (idx == 0) 90.0 else 120.0;
        return .{
            .position = @as(f64, @floatFromInt(idx)) * 0.5,
            .position_beats = @as(f64, @floatFromInt(idx)),
            .bpm = bpm,
            .timesig_num = 4,
            .timesig_denom = 4,
            .linear_tempo = self.linear_at == idx,
        };
    }
};

test "a tempo map of hundreds of markers reaches clients whole" {
    const state = try State.poll(std.testing.allocator, &Generated{ .n = 300 });
    defer state.deinit(std.testing.allocator);
    const json = try state.toJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqual(@as(usize, 300), std.mem.count(u8, json, "\"bpm\":"));
    try std.testing.expect(std.mem.endsWith(u8, json, "]}}"));
}

test "making a tempo change gradual is a tempo map change" {
    const a = try State.poll(std.testing.allocator, &Generated{ .n = 4 });
    defer a.deinit(std.testing.allocator);
    const b = try State.poll(std.testing.allocator, &Generated{ .n = 4, .linear_at = 2 });
    defer b.deinit(std.testing.allocator);
    try std.testing.expect(b.changed(a.summary()));
}

test "two markers trading tempos is a tempo map change" {
    const a = try State.poll(std.testing.allocator, &Generated{ .n = 4 });
    defer a.deinit(std.testing.allocator);
    const b = try State.poll(std.testing.allocator, &Generated{ .n = 4, .swap_bpm = true });
    defer b.deinit(std.testing.allocator);
    try std.testing.expect(b.changed(a.summary()));
}

test "an unchanged tempo map is not a change" {
    const a = try State.poll(std.testing.allocator, &Generated{ .n = 4 });
    defer a.deinit(std.testing.allocator);
    const b = try State.poll(std.testing.allocator, &Generated{ .n = 4 });
    defer b.deinit(std.testing.allocator);
    try std.testing.expect(!b.changed(a.summary()));
}

test "a marker REAPER can't return is left out, not sent as garbage" {
    const state = try State.poll(std.testing.allocator, &Generated{ .n = 3, .null_at = 1 });
    defer state.deinit(std.testing.allocator);
    const json = try state.toJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, json, "\"bpm\":"));
}

test "State.toJson empty markers" {
    const state = State{};
    var buf: [256]u8 = undefined;
    const json = state.toJson(&buf).?;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"markers\":[]") != null);
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

    const state = try State.poll(std.testing.allocator, &mock);
    defer state.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), state.markers.len);
    try std.testing.expect(@abs(state.markers[0].bpm - 120.0) < 0.01);
    try std.testing.expect(@abs(state.markers[1].bpm - 140.0) < 0.01);
    try std.testing.expectEqual(@as(c_int, 4), state.markers[0].timesig_num);
    try std.testing.expectEqual(@as(c_int, 3), state.markers[1].timesig_num);
}

test "poll with MockBackend returns empty state for no markers" {
    var mock = MockBackend{
        .tempo_marker_count = 0,
    };

    const state = try State.poll(std.testing.allocator, &mock);
    defer state.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), state.markers.len);
}

test "poll handles negative tempo_marker_count without panic" {
    var mock = MockBackend{
        .tempo_marker_count = -1,
    };

    const state = try State.poll(std.testing.allocator, &mock);
    defer state.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), state.markers.len);
    var buf: [256]u8 = undefined;
    const json = state.toJson(&buf).?;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"markers\":[]") != null);
}
