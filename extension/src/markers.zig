const std = @import("std");
const reaper = @import("reaper.zig");
const protocol = @import("protocol.zig");
const ApiInterface = reaper.api.ApiInterface;

// Maximum markers/regions we track (matches frontend reasonable limits)
pub const MAX_MARKERS = 256;
pub const MAX_REGIONS = 256;

// Marker data - matches frontend types.ts Marker interface
pub const Marker = struct {
    id: c_int,
    position: f64,
    position_beats: f64 = 0,
    position_bar: c_int = 1,
    position_beat_in_bar: f64 = 0, // 0-indexed beat within bar
    name: [128]u8 = undefined,
    name_len: usize = 0,
    color: c_int,

    pub fn getName(self: *const Marker) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn eql(self: *const Marker, other: *const Marker) bool {
        if (self.id != other.id) return false;
        if (@abs(self.position - other.position) > 0.001) return false;
        if (self.color != other.color) return false;
        if (self.name_len != other.name_len) return false;
        return std.mem.eql(u8, self.getName(), other.getName());
    }
};

// Region data - matches frontend types.ts Region interface
pub const Region = struct {
    id: c_int,
    start: f64,
    end: f64,
    start_beats: f64 = 0,
    end_beats: f64 = 0,
    start_bar: c_int = 1,
    start_beat_in_bar: f64 = 0, // 0-indexed beat within bar
    end_bar: c_int = 1,
    end_beat_in_bar: f64 = 0, // 0-indexed beat within bar
    start_beats_per_bar: c_int = 4, // Time sig numerator at start (for length borrowing)
    name: [128]u8 = undefined,
    name_len: usize = 0,
    color: c_int,

    pub fn getName(self: *const Region) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn eql(self: *const Region, other: *const Region) bool {
        if (self.id != other.id) return false;
        if (@abs(self.start - other.start) > 0.001) return false;
        if (@abs(self.end - other.end) > 0.001) return false;
        if (self.color != other.color) return false;
        if (self.name_len != other.name_len) return false;
        return std.mem.eql(u8, self.getName(), other.getName());
    }
};

// Cached state for change detection
pub const State = struct {
    markers: [MAX_MARKERS]Marker = undefined,
    marker_count: usize = 0,
    regions: [MAX_REGIONS]Region = undefined,
    region_count: usize = 0,
    bar_offset: c_int = 0, // For bar string formatting

    /// Poll current state from REAPER using abstract interface.
    /// Enables unit testing without REAPER running.
    pub fn poll(api: ApiInterface) State {
        var state = State{};
        state.bar_offset = api.getBarOffset();

        var idx: c_int = 0;
        while (api.enumMarker(idx)) |info| : (idx += 1) {
            if (info.is_region) {
                if (state.region_count < MAX_REGIONS) {
                    var region = &state.regions[state.region_count];
                    region.id = info.id;
                    region.start = info.pos;
                    region.end = info.end;
                    region.color = info.color;

                    // Compute beat positions
                    const start_beats = api.timeToBeats(info.pos);
                    region.start_beats = start_beats.beats;
                    region.start_bar = start_beats.measures;
                    region.start_beat_in_bar = start_beats.beats_in_measure;

                    const end_beats = api.timeToBeats(info.end);
                    region.end_beats = end_beats.beats;
                    region.end_bar = end_beats.measures;
                    region.end_beat_in_bar = end_beats.beats_in_measure;

                    // Get time sig at start for length borrowing calculation
                    // When borrowing beats, we use the time signature of the bar we're borrowing FROM
                    const start_timesig = api.getTempoAtPosition(info.pos);
                    region.start_beats_per_bar = start_timesig.timesig_num;

                    const copy_len = @min(info.name.len, region.name.len);
                    @memcpy(region.name[0..copy_len], info.name[0..copy_len]);
                    region.name_len = copy_len;

                    state.region_count += 1;
                }
            } else {
                if (state.marker_count < MAX_MARKERS) {
                    var marker = &state.markers[state.marker_count];
                    marker.id = info.id;
                    marker.position = info.pos;
                    marker.color = info.color;

                    // Compute beat position
                    const beats_info = api.timeToBeats(info.pos);
                    marker.position_beats = beats_info.beats;
                    marker.position_bar = beats_info.measures;
                    marker.position_beat_in_bar = beats_info.beats_in_measure;

                    const copy_len = @min(info.name.len, marker.name.len);
                    @memcpy(marker.name[0..copy_len], info.name[0..copy_len]);
                    marker.name_len = copy_len;

                    state.marker_count += 1;
                }
            }
        }

        return state;
    }

    // Check if markers have changed
    pub fn markersChanged(self: *const State, other: *const State) bool {
        if (self.marker_count != other.marker_count) return true;

        for (0..self.marker_count) |i| {
            if (!self.markers[i].eql(&other.markers[i])) return true;
        }
        return false;
    }

    // Check if regions have changed
    pub fn regionsChanged(self: *const State, other: *const State) bool {
        if (self.region_count != other.region_count) return true;

        for (0..self.region_count) |i| {
            if (!self.regions[i].eql(&other.regions[i])) return true;
        }
        return false;
    }

    // Format bar.beat.ticks string (e.g., "5.2.50")
    // bar: measure number from timeToBeats (before offset applied)
    // beat_in_bar: 0-indexed beat within measure (from timeToBeats)
    // bar_offset: project bar offset to apply
    fn formatBars(w: anytype, bar: c_int, beat_in_bar: f64, bar_offset: c_int) !void {
        const display_bar = bar + bar_offset;
        // Convert 0-indexed to 1-indexed and extract ticks
        // Use integer arithmetic to avoid floating-point precision issues
        const scaled: u32 = @intFromFloat(@round((beat_in_bar + 1.0) * 100.0));
        const beat_int: u32 = @max(1, scaled / 100);
        const ticks: u32 = scaled % 100;
        try w.print("{d}.{d}.{d:0>2}", .{ display_bar, beat_int, ticks });
    }

    // Format length as bar.beat.ticks string (e.g., "10.1.50")
    // Computes the difference between end and start positions with borrowing.
    // Uses time sig numerator at START position for beat borrowing (you borrow from the start bar).
    fn formatLengthBars(
        w: anytype,
        start_bar: c_int,
        start_beat_in_bar: f64,
        end_bar: c_int,
        end_beat_in_bar: f64,
        start_beats_per_bar: c_int,
    ) !void {
        // Convert beat_in_bar (0-indexed with fraction) to scaled integers (ticks = fraction * 100)
        // start_beat_in_bar=0.0 means beat 1.00, start_beat_in_bar=1.5 means beat 2.50
        const start_scaled: i32 = @intFromFloat(@round(start_beat_in_bar * 100.0));
        const end_scaled: i32 = @intFromFloat(@round(end_beat_in_bar * 100.0));

        var bar_diff: i32 = end_bar - start_bar;
        var beat_diff: i32 = end_scaled - start_scaled;

        // Handle borrowing: if beat_diff is negative, borrow from bars
        // Use time signature at START - when borrowing a bar, you're taking beats from the start position's bar
        if (beat_diff < 0) {
            bar_diff -= 1;
            // Add one full bar worth of beats (in scaled units: beats_per_bar * 100)
            beat_diff += start_beats_per_bar * 100;
        }

        // Extract beat and ticks from the scaled difference
        // beat_diff is now the total scaled difference (whole beats * 100 + ticks)
        const beat_int: u32 = @intCast(@divFloor(beat_diff, 100));
        const ticks: u32 = @intCast(@mod(beat_diff, 100));

        // Display as bar.beat.ticks (NOT 1-indexed for lengths - 0 beats = "0.0.00")
        try w.print("{d}.{d}.{d:0>2}", .{ bar_diff, beat_int, ticks });
    }

    // Generate JSON for markers event
    pub fn markersToJson(self: *const State, buf: []u8) ?[]const u8 {
        var stream = std.io.fixedBufferStream(buf);
        var w = stream.writer();

        w.writeAll("{\"type\":\"event\",\"event\":\"markers\",\"payload\":{\"markers\":[") catch return null;

        for (0..self.marker_count) |i| {
            if (i > 0) w.writeByte(',') catch return null;
            const m = &self.markers[i];
            w.print("{{\"id\":{d},\"position\":{d:.15},\"positionBeats\":{d:.6},\"positionBars\":\"", .{
                m.id,
                m.position,
                m.position_beats,
            }) catch return null;
            formatBars(w, m.position_bar, m.position_beat_in_bar, self.bar_offset) catch return null;
            w.writeAll("\",\"name\":\"") catch return null;
            protocol.writeJsonString(w, m.getName()) catch return null;
            w.print("\",\"color\":{d}}}", .{m.color}) catch return null;
        }

        w.writeAll("]}}") catch return null;
        return stream.getWritten();
    }

    // Generate JSON for regions event
    pub fn regionsToJson(self: *const State, buf: []u8) ?[]const u8 {
        var stream = std.io.fixedBufferStream(buf);
        var w = stream.writer();

        w.writeAll("{\"type\":\"event\",\"event\":\"regions\",\"payload\":{\"regions\":[") catch return null;

        for (0..self.region_count) |i| {
            if (i > 0) w.writeByte(',') catch return null;
            const r = &self.regions[i];
            w.print("{{\"id\":{d},\"start\":{d:.15},\"end\":{d:.15},\"startBeats\":{d:.6},\"endBeats\":{d:.6},\"startBars\":\"", .{
                r.id,
                r.start,
                r.end,
                r.start_beats,
                r.end_beats,
            }) catch return null;
            formatBars(w, r.start_bar, r.start_beat_in_bar, self.bar_offset) catch return null;
            w.writeAll("\",\"endBars\":\"") catch return null;
            formatBars(w, r.end_bar, r.end_beat_in_bar, self.bar_offset) catch return null;
            w.writeAll("\",\"lengthBars\":\"") catch return null;
            formatLengthBars(w, r.start_bar, r.start_beat_in_bar, r.end_bar, r.end_beat_in_bar, r.start_beats_per_bar) catch return null;
            w.writeAll("\",\"name\":\"") catch return null;
            protocol.writeJsonString(w, r.getName()) catch return null;
            w.print("\",\"color\":{d}}}", .{r.color}) catch return null;
        }

        w.writeAll("]}}") catch return null;
        return stream.getWritten();
    }
};

// Tests
test "Marker equality" {
    var m1 = Marker{ .id = 1, .position = 10.5, .color = 0 };
    m1.name[0..5].* = "verse".*;
    m1.name_len = 5;

    var m2 = Marker{ .id = 1, .position = 10.5, .color = 0 };
    m2.name[0..5].* = "verse".*;
    m2.name_len = 5;

    try std.testing.expect(m1.eql(&m2));

    m2.position = 11.0;
    try std.testing.expect(!m1.eql(&m2));
}

test "Region equality" {
    var r1 = Region{ .id = 1, .start = 10.0, .end = 20.0, .color = 0 };
    r1.name[0..6].* = "chorus".*;
    r1.name_len = 6;

    var r2 = Region{ .id = 1, .start = 10.0, .end = 20.0, .color = 0 };
    r2.name[0..6].* = "chorus".*;
    r2.name_len = 6;

    try std.testing.expect(r1.eql(&r2));

    r2.end = 25.0;
    try std.testing.expect(!r1.eql(&r2));
}

test "State markers JSON output" {
    var state = State{};
    state.bar_offset = 0;

    // Add test marker at bar 3, beat 2 (0-indexed: 1.0), 50 ticks
    state.markers[0] = .{
        .id = 1,
        .position = 10.5,
        .position_beats = 21.5,
        .position_bar = 3,
        .position_beat_in_bar = 1.5, // 0-indexed, so beat 2 + 50 ticks
        .color = 16711680,
    };
    state.markers[0].name[0..5].* = "Verse".*;
    state.markers[0].name_len = 5;
    state.marker_count = 1;

    var buf: [1024]u8 = undefined;
    const json = state.markersToJson(&buf).?;

    // Check for expected fields
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"position\":10.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"positionBeats\":21.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"positionBars\":\"3.2.50\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"Verse\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"color\":16711680") != null);
}

test "State regions JSON output" {
    var state = State{};
    state.bar_offset = -4; // Test with negative offset (common in REAPER)

    // Add test region from bar 1 to bar 9 (display: -3 to 5 with offset -4)
    state.regions[0] = .{
        .id = 2,
        .start = 0.0,
        .end = 30.0,
        .start_beats = 0.0,
        .end_beats = 60.0,
        .start_bar = 1,
        .start_beat_in_bar = 0.0, // Beat 1 (0-indexed)
        .end_bar = 9,
        .end_beat_in_bar = 0.0, // Beat 1 (0-indexed)
        .color = 255,
    };
    state.regions[0].name[0..5].* = "Intro".*;
    state.regions[0].name_len = 5;
    state.region_count = 1;

    var buf: [1024]u8 = undefined;
    const json = state.regionsToJson(&buf).?;

    // Check for expected fields
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"start\":0.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"end\":30.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"startBeats\":0.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"endBeats\":60.0") != null);
    // Bar 1 + offset -4 = display bar -3
    try std.testing.expect(std.mem.indexOf(u8, json, "\"startBars\":\"-3.1.00\"") != null);
    // Bar 9 + offset -4 = display bar 5
    try std.testing.expect(std.mem.indexOf(u8, json, "\"endBars\":\"5.1.00\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"Intro\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"color\":255") != null);
}

test "markers changed detection" {
    var state1 = State{};
    state1.markers[0] = .{ .id = 1, .position = 10.0, .color = 0 };
    state1.marker_count = 1;

    var state2 = State{};
    state2.markers[0] = .{ .id = 1, .position = 10.0, .color = 0 };
    state2.marker_count = 1;

    try std.testing.expect(!state1.markersChanged(&state2));

    state2.markers[0].position = 15.0;
    try std.testing.expect(state1.markersChanged(&state2));
}

test "marker position preserves sub-millisecond precision" {
    // Regression test: Position 17.333333... must not be truncated to 17.333
    // because that causes beat display errors (4.4.99 instead of 4.5.00)
    // at 90 BPM in 6/8 time.
    var state = State{};
    state.markers[0] = .{ .id = 1, .position = 17.333333333333329, .color = 0 };
    state.markers[0].name[0..2].* = "m1".*;
    state.markers[0].name_len = 2;
    state.marker_count = 1;

    var buf: [1024]u8 = undefined;
    const json = state.markersToJson(&buf).?;

    // Position should preserve enough precision to distinguish 17.333333... from 17.333
    // The JSON should contain "17.333333" (6 decimal places minimum)
    try std.testing.expect(std.mem.indexOf(u8, json, "17.333333") != null);
}

test "region position preserves sub-millisecond precision" {
    // Same precision requirement for regions
    var state = State{};
    state.regions[0] = .{ .id = 1, .start = 0.0, .end = 17.333333333333329, .color = 0 };
    state.regions[0].name[0..4].* = "Test".*;
    state.regions[0].name_len = 4;
    state.region_count = 1;

    var buf: [1024]u8 = undefined;
    const json = state.regionsToJson(&buf).?;

    // End position should preserve precision
    try std.testing.expect(std.mem.indexOf(u8, json, "17.333333") != null);
}

// =============================================================================
// MockApi-based tests (Phase 8.4)
// =============================================================================

const MockApi = reaper.mock.MockApi;

test "poll with MockApi returns markers and regions" {
    var mock = MockApi{
        .bar_offset = -4,
        .marker_count = 1,
        .region_count = 1,
    };
    // Set up a marker
    mock.markers[0] = .{
        .idx = 0,
        .id = 1,
        .pos = 10.5,
        .end = 0.0,
        .is_region = false,
        .name = "Verse",
        .color = 16711680,
    };

    // Set up a region
    mock.markers[1] = .{
        .idx = 1,
        .id = 2,
        .pos = 0.0,
        .end = 30.0,
        .is_region = true,
        .name = "Intro",
        .color = 255,
    };

    const state = State.poll(mock.interface());

    try std.testing.expectEqual(@as(c_int, -4), state.bar_offset);
    try std.testing.expectEqual(@as(usize, 1), state.marker_count);
    try std.testing.expectEqual(@as(usize, 1), state.region_count);

    // Verify marker
    try std.testing.expectEqual(@as(c_int, 1), state.markers[0].id);
    try std.testing.expect(@abs(state.markers[0].position - 10.5) < 0.001);
    try std.testing.expectEqualStrings("Verse", state.markers[0].getName());

    // Verify region
    try std.testing.expectEqual(@as(c_int, 2), state.regions[0].id);
    try std.testing.expect(@abs(state.regions[0].start - 0.0) < 0.001);
    try std.testing.expect(@abs(state.regions[0].end - 30.0) < 0.001);
    try std.testing.expectEqualStrings("Intro", state.regions[0].getName());
}

test "poll with MockApi returns empty state when no markers" {
    var mock = MockApi{
        .marker_count = 0,
        .region_count = 0,
    };

    const state = State.poll(mock.interface());

    try std.testing.expectEqual(@as(usize, 0), state.marker_count);
    try std.testing.expectEqual(@as(usize, 0), state.region_count);
}

test "poll tracks API calls correctly" {
    var mock = MockApi{
        .marker_count = 1,
        .region_count = 0,
    };
    mock.markers[0] = .{
        .idx = 0,
        .id = 1,
        .pos = 5.0,
        .end = 0.0,
        .is_region = false,
        .name = "Test",
        .color = 0,
    };

    _ = State.poll(mock.interface());

    // Verify key API calls were made
    try std.testing.expect(mock.getCallCount(.getBarOffset) >= 1);
    try std.testing.expect(mock.getCallCount(.enumMarker) >= 1);
    try std.testing.expect(mock.getCallCount(.timeToBeats) >= 1);
}
