/// Track Skeleton - Lightweight track list for viewport-driven subscriptions.
///
/// Polled at LOW tier (1Hz) to detect track add/delete/reorder/rename.
/// Broadcasts "trackSkeleton" event when structure changes.
/// Clients use this to know available tracks and subscribe by GUID or range.
///
/// Design:
/// - Each track has name + GUID + filter fields for client-side bank filtering
/// - Master track uses "master" as GUID (REAPER's master GUID is unreliable)
/// - Arena allocation - no fixed size limit
/// - Compact JSON output with short keys to minimize bandwidth
///
/// Filter fields enable built-in banks (Muted, Soloed, Armed, Selected, Folders, With Sends)
/// without requiring full track subscriptions. Polled in same loop - no extra overhead.
const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("../core/protocol.zig");
const constants = @import("../core/constants.zig");

// Re-export shared constants for backward compatibility
pub const MAX_NAME_LEN = constants.MAX_NAME_LEN;
pub const MAX_GUID_LEN = constants.MAX_GUID_LEN;

/// Single track skeleton entry with filter fields for built-in banks.
pub const SkeletonTrack = struct {
    name: [MAX_NAME_LEN]u8 = undefined,
    name_len: usize = 0,
    guid: [MAX_GUID_LEN]u8 = undefined,
    guid_len: usize = 0,

    // Filter fields for built-in banks (polled in same loop, no extra overhead)
    mute: bool = false,
    solo: ?c_int = null, // null=off, 0=solo, 2=solo-in-place
    selected: bool = false,
    rec_arm: bool = false,
    folder_depth: c_int = 0, // 1=folder parent, 0=normal, -N=closes N folders
    send_count: u16 = 0,
    hw_output_count: u16 = 0,
    clipped: bool = false, // Sticky clip flag (L or R channel exceeded 0dB)
    item_count: u16 = 0, // Number of media items on track
    input_type: u8 = 0, // 0=none, 1=audio, 2=midi (from I_RECINPUT)
    free_mode: u8 = 0, // 0=normal, 1=free positioning, 2=fixed lanes (for comping)
    color: c_int = 0, // Native OS color (0x01rrggbb), 0 = theme default

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
        // Compare filter fields
        if (self.mute != other.mute) return false;
        if (self.solo != other.solo) return false;
        if (self.selected != other.selected) return false;
        if (self.rec_arm != other.rec_arm) return false;
        if (self.folder_depth != other.folder_depth) return false;
        if (self.send_count != other.send_count) return false;
        if (self.hw_output_count != other.hw_output_count) return false;
        if (self.clipped != other.clipped) return false;
        if (self.item_count != other.item_count) return false;
        if (self.input_type != other.input_type) return false;
        if (self.free_mode != other.free_mode) return false;
        if (self.color != other.color) return false;
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

                // Filter fields for built-in banks (read in same loop - no extra overhead)
                // Master track uses special API calls for mute/solo
                if (idx == 0) {
                    t.mute = api.isMasterMuted();
                    t.solo = if (api.isMasterSoloed()) @as(?c_int, 1) else null;
                } else {
                    t.mute = api.getTrackMute(track);
                    t.solo = api.getTrackSolo(track) catch null;
                }
                t.selected = api.getTrackSelected(track);
                t.rec_arm = api.getTrackRecArm(track);
                t.folder_depth = api.getTrackFolderDepth(track) catch 0;
                const send_c = api.trackSendCount(track);
                t.send_count = if (send_c >= 0) @intCast(send_c) else 0;
                const hw_c = api.trackHwOutputCount(track);
                t.hw_output_count = if (hw_c >= 0) @intCast(hw_c) else 0;

                // Clipped: check peak hold on L/R channels (sticky until cleared, use clear=false)
                const hold_l = api.getTrackPeakHoldDB(track, 0, false);
                const hold_r = api.getTrackPeakHoldDB(track, 1, false);
                t.clipped = hold_l > 0.0 or hold_r > 0.0;

                // Item count (master track can have items too)
                const item_c = api.trackItemCount(track);
                t.item_count = if (item_c >= 0) @intCast(item_c) else 0;

                // Free mode: 0=normal, 1=free positioning, 2=fixed lanes
                // Master track (idx 0) doesn't support free mode
                if (idx == 0) {
                    t.free_mode = 0;
                } else {
                    const free_mode = api.getTrackFreeMode(track) catch 0;
                    t.free_mode = if (free_mode >= 0 and free_mode <= 2) @intCast(free_mode) else 0;
                }

                // Color: 0x01rrggbb format, 0 = theme default
                t.color = api.getTrackColor(track) catch 0;

                // Input type: 0=none, 1=audio, 2=midi (from I_RECINPUT)
                // Master track (idx 0) has no record input
                if (idx == 0) {
                    t.input_type = 0; // Master track has no input
                } else {
                    const rec_input = api.getTrackRecInput(track);
                    if (rec_input < 0) {
                        t.input_type = 0; // No input
                    } else if ((rec_input & 0x1000) != 0) {
                        t.input_type = 2; // MIDI (bit 12 set)
                    } else {
                        t.input_type = 1; // Audio
                    }
                }
            }
            // If track disappeared, we keep default empty entry (will be filtered by len=0)
        }

        return .{ .tracks = tracks };
    }

    /// Serialize to JSON event.
    /// Format: {"type":"event","event":"trackSkeleton","payload":{"tracks":[{...},...]}}
    /// Keys: n=name, g=guid, m=mute, sl=solo, sel=selected, r=rec_arm, fd=folder_depth, sc=send_count, hc=hw_output_count, cl=clipped, ic=item_count, it=input_type, fm=free_mode
    pub fn toJson(self: *const State, buf: []u8) ?[]const u8 {
        var stream = std.io.fixedBufferStream(buf);
        const writer = stream.writer();

        writer.writeAll("{\"type\":\"event\",\"event\":\"trackSkeleton\",\"payload\":{\"tracks\":[") catch return null;

        var first = true;
        for (self.tracks) |*t| {
            // Skip tracks with empty GUID (shouldn't happen, but defensive)
            if (t.guid_len == 0) continue;

            if (!first) {
                writer.writeByte(',') catch return null;
            }
            first = false;

            // Name and GUID
            writer.writeAll("{\"n\":\"") catch return null;
            protocol.writeJsonString(writer, t.getName()) catch return null;
            writer.writeAll("\",\"g\":\"") catch return null;
            protocol.writeJsonString(writer, t.getGuid()) catch return null;

            // Filter fields (short keys to minimize bandwidth)
            // m=mute (bool)
            writer.writeAll(if (t.mute) "\",\"m\":true" else "\",\"m\":false") catch return null;

            // sl=solo (null or int)
            if (t.solo) |s| {
                writer.print(",\"sl\":{d}", .{s}) catch return null;
            } else {
                writer.writeAll(",\"sl\":null") catch return null;
            }

            // sel=selected (bool)
            writer.writeAll(if (t.selected) ",\"sel\":true" else ",\"sel\":false") catch return null;

            // r=rec_arm (bool)
            writer.writeAll(if (t.rec_arm) ",\"r\":true" else ",\"r\":false") catch return null;

            // fd=folder_depth (int)
            writer.print(",\"fd\":{d}", .{t.folder_depth}) catch return null;

            // sc=send_count (int)
            writer.print(",\"sc\":{d}", .{t.send_count}) catch return null;

            // hc=hw_output_count (int)
            writer.print(",\"hc\":{d}", .{t.hw_output_count}) catch return null;

            // cl=clipped (bool)
            writer.writeAll(if (t.clipped) ",\"cl\":true" else ",\"cl\":false") catch return null;

            // ic=item_count (int)
            writer.print(",\"ic\":{d}", .{t.item_count}) catch return null;

            // it=input_type (int: 0=none, 1=audio, 2=midi)
            writer.print(",\"it\":{d}", .{t.input_type}) catch return null;

            // fm=free_mode (int: 0=normal, 1=free positioning, 2=fixed lanes)
            writer.print(",\"fm\":{d}", .{t.free_mode}) catch return null;

            // c=color (int: 0x01rrggbb, 0=theme default)
            writer.print(",\"c\":{d}", .{t.color}) catch return null;

            writer.writeByte('}') catch return null;
        }

        writer.writeAll("]}}") catch return null;

        return buf[0..stream.pos];
    }

    /// Allocator-based version - dynamically sized, supports extreme projects.
    /// Estimates buffer size based on track count, allocates from arena, returns trimmed slice.
    pub fn toJsonAlloc(self: *const State, allocator: Allocator) ![]const u8 {
        // Estimate: ~250 bytes per track (name + GUID + filter fields + JSON overhead) + 100 base
        const estimated_size = 100 + (self.tracks.len * 250);
        const buf = try allocator.alloc(u8, estimated_size);
        const json = self.toJson(buf) orelse return error.JsonSerializationFailed;
        return json; // Return slice of allocated buffer (no copy needed, arena-owned)
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
    const reaper = @import("../reaper.zig");
    var mock = reaper.MockBackend{ .track_count = 2 };

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
    const reaper = @import("../reaper.zig");
    var mock = reaper.MockBackend{ .track_count = 2 };

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
    const reaper = @import("../reaper.zig");
    var mock = reaper.MockBackend{ .track_count = 1 };

    const state = try State.poll(std.testing.allocator, &mock);
    defer std.testing.allocator.free(state.tracks);

    var buf: [1024]u8 = undefined;
    const json = state.toJson(&buf) orelse unreachable;

    // Should contain skeleton event structure with payload wrapper
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"event\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"event\":\"trackSkeleton\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"payload\":{\"tracks\":[") != null);

    // Should have master track with "master" GUID
    try std.testing.expect(std.mem.indexOf(u8, json, "\"g\":\"master\"") != null);

    // Should have user track with formatted GUID
    try std.testing.expect(std.mem.indexOf(u8, json, "\"g\":\"{00000000-0000-0000-0000-000000000001}\"") != null);
}

test "State toJson buffer overflow returns null" {
    const reaper = @import("../reaper.zig");
    var mock = reaper.MockBackend{ .track_count = 1 };

    const state = try State.poll(std.testing.allocator, &mock);
    defer std.testing.allocator.free(state.tracks);

    // Tiny buffer should fail
    var buf: [10]u8 = undefined;
    try std.testing.expect(state.toJson(&buf) == null);
}

test "State toJsonAlloc dynamically sizes buffer" {
    const reaper = @import("../reaper.zig");
    var mock = reaper.MockBackend{ .track_count = 5 };

    const state = try State.poll(std.testing.allocator, &mock);
    defer std.testing.allocator.free(state.tracks);

    // toJsonAlloc is designed for arena allocators (returns trimmed slice)
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // toJsonAlloc should succeed by dynamically sizing buffer
    const json = try state.toJsonAlloc(arena.allocator());

    // Should contain expected structure
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"event\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"event\":\"trackSkeleton\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"g\":\"master\"") != null);
}
