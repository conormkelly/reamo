/// Track Skeleton - Lightweight track list for viewport-driven subscriptions.
///
/// Polled at LOW tier (1Hz) to detect track add/delete/reorder/rename.
/// Broadcasts "trackSkeleton" event when structure changes.
/// Clients use this to know available tracks and subscribe by GUID or range.
///
/// Design:
/// - Each track has name + GUID only (minimal data for skeleton)
/// - Master track uses "master" as GUID (REAPER's master GUID is unreliable)
/// - Arena allocation - no fixed size limit
/// - Compact JSON output: {"n":"name","g":"guid"} to minimize bandwidth
const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("protocol.zig");

pub const MAX_NAME_LEN: usize = 128;
pub const MAX_GUID_LEN: usize = 40; // {XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX} = 38 + padding

/// Single track skeleton entry (name + GUID only).
pub const SkeletonTrack = struct {
    name: [MAX_NAME_LEN]u8 = undefined,
    name_len: usize = 0,
    guid: [MAX_GUID_LEN]u8 = undefined,
    guid_len: usize = 0,

    pub fn getName(self: *const SkeletonTrack) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn getGuid(self: *const SkeletonTrack) []const u8 {
        return self.guid[0..self.guid_len];
    }

    pub fn eql(self: *const SkeletonTrack, other: *const SkeletonTrack) bool {
        if (self.name_len != other.name_len) return false;
        if (self.guid_len != other.guid_len) return false;
        if (!std.mem.eql(u8, self.name[0..self.name_len], other.name[0..other.name_len])) return false;
        if (!std.mem.eql(u8, self.guid[0..self.guid_len], other.guid[0..other.guid_len])) return false;
        return true;
    }
};

/// Track skeleton state (all tracks, names + GUIDs only).
pub const State = struct {
    tracks: []SkeletonTrack = &.{},

    /// Return an empty state (for initialization).
    pub fn empty() State {
        return .{ .tracks = &.{} };
    }

    /// Number of tracks in this state.
    pub fn count(self: *const State) usize {
        return self.tracks.len;
    }

    /// Compare for change detection.
    pub fn eql(self: *const State, other: *const State) bool {
        if (self.tracks.len != other.tracks.len) return false;
        for (self.tracks, other.tracks) |*a, *b| {
            if (!a.eql(b)) return false;
        }
        return true;
    }

    /// Poll skeleton state from REAPER.
    /// Uses unified indexing: idx 0 = master, idx 1+ = user tracks.
    pub fn poll(allocator: Allocator, api: anytype) Allocator.Error!State {
        const user_track_count: usize = @intCast(@max(0, api.trackCount()));
        // Total = master (1) + user tracks
        const total_count = user_track_count + 1;

        const tracks = try allocator.alloc(SkeletonTrack, total_count);

        for (tracks, 0..) |*t, i| {
            const idx: c_int = @intCast(i);
            t.* = SkeletonTrack{};

            if (api.getTrackByUnifiedIdx(idx)) |track| {
                // Get track name
                var name_buf: [MAX_NAME_LEN]u8 = undefined;
                const name = api.getTrackNameStr(track, &name_buf);
                const name_copy_len = @min(name.len, MAX_NAME_LEN);
                @memcpy(t.name[0..name_copy_len], name[0..name_copy_len]);
                t.name_len = name_copy_len;

                // Get GUID (master uses "master" literal)
                if (idx == 0) {
                    const master_guid = "master";
                    @memcpy(t.guid[0..master_guid.len], master_guid);
                    t.guid_len = master_guid.len;
                } else {
                    var guid_buf: [64]u8 = undefined;
                    const guid = api.formatTrackGuid(track, &guid_buf);
                    const guid_copy_len = @min(guid.len, MAX_GUID_LEN);
                    @memcpy(t.guid[0..guid_copy_len], guid[0..guid_copy_len]);
                    t.guid_len = guid_copy_len;
                }
            }
            // If track disappeared, we keep default empty entry (will be filtered by len=0)
        }

        return .{ .tracks = tracks };
    }

    /// Serialize to JSON event.
    /// Format: {"type":"event","event":"trackSkeleton","tracks":[{"n":"name","g":"guid"},...]}
    pub fn toJson(self: *const State, buf: []u8) ?[]const u8 {
        var stream = std.io.fixedBufferStream(buf);
        const writer = stream.writer();

        writer.writeAll("{\"type\":\"event\",\"event\":\"trackSkeleton\",\"tracks\":[") catch return null;

        var first = true;
        for (self.tracks) |*t| {
            // Skip tracks with empty GUID (shouldn't happen, but defensive)
            if (t.guid_len == 0) continue;

            if (!first) {
                writer.writeByte(',') catch return null;
            }
            first = false;

            writer.writeAll("{\"n\":\"") catch return null;
            protocol.writeJsonString(writer, t.getName()) catch return null;
            writer.writeAll("\",\"g\":\"") catch return null;
            protocol.writeJsonString(writer, t.getGuid()) catch return null;
            writer.writeAll("\"}") catch return null;
        }

        writer.writeAll("]}") catch return null;

        return buf[0..stream.pos];
    }
};

// =============================================================================
// Tests
// =============================================================================

test "SkeletonTrack equality" {
    var a = SkeletonTrack{};
    const name = "Track 1";
    @memcpy(a.name[0..name.len], name);
    a.name_len = name.len;
    const guid = "{00000000-0000-0000-0000-000000000001}";
    @memcpy(a.guid[0..guid.len], guid);
    a.guid_len = guid.len;

    var b = a;
    try std.testing.expect(a.eql(&b));

    // Different name
    b.name[0] = 'X';
    try std.testing.expect(!a.eql(&b));
}

test "State empty" {
    const state = State.empty();
    try std.testing.expectEqual(@as(usize, 0), state.count());
}

test "State poll with mock backend" {
    const reaper = @import("reaper.zig");
    var mock = reaper.mock();
    mock.track_count = 2;

    const state = try State.poll(std.testing.allocator, &mock);
    defer std.testing.allocator.free(state.tracks);

    // Master + 2 user tracks = 3 total
    try std.testing.expectEqual(@as(usize, 3), state.count());

    // Master track should have "master" GUID
    try std.testing.expectEqualStrings("master", state.tracks[0].getGuid());

    // User tracks should have deterministic GUIDs from mock
    try std.testing.expectEqualStrings("{00000000-0000-0000-0000-000000000001}", state.tracks[1].getGuid());
    try std.testing.expectEqualStrings("{00000000-0000-0000-0000-000000000002}", state.tracks[2].getGuid());
}

test "State equality" {
    const reaper = @import("reaper.zig");
    var mock = reaper.mock();
    mock.track_count = 2;

    const state1 = try State.poll(std.testing.allocator, &mock);
    defer std.testing.allocator.free(state1.tracks);

    const state2 = try State.poll(std.testing.allocator, &mock);
    defer std.testing.allocator.free(state2.tracks);

    try std.testing.expect(state1.eql(&state2));

    // Change track count
    mock.track_count = 3;
    const state3 = try State.poll(std.testing.allocator, &mock);
    defer std.testing.allocator.free(state3.tracks);

    try std.testing.expect(!state1.eql(&state3));
}

test "State toJson" {
    const reaper = @import("reaper.zig");
    var mock = reaper.mock();
    mock.track_count = 1;

    const state = try State.poll(std.testing.allocator, &mock);
    defer std.testing.allocator.free(state.tracks);

    var buf: [1024]u8 = undefined;
    const json = state.toJson(&buf) orelse unreachable;

    // Should contain skeleton event structure
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"event\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"event\":\"trackSkeleton\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tracks\":[") != null);

    // Should have master track with "master" GUID
    try std.testing.expect(std.mem.indexOf(u8, json, "\"g\":\"master\"") != null);

    // Should have user track with formatted GUID
    try std.testing.expect(std.mem.indexOf(u8, json, "\"g\":\"{00000000-0000-0000-0000-000000000001}\"") != null);
}

test "State toJson buffer overflow returns null" {
    const reaper = @import("reaper.zig");
    var mock = reaper.mock();
    mock.track_count = 1;

    const state = try State.poll(std.testing.allocator, &mock);
    defer std.testing.allocator.free(state.tracks);

    // Tiny buffer should fail
    var buf: [10]u8 = undefined;
    try std.testing.expect(state.toJson(&buf) == null);
}
