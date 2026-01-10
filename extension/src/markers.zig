const std = @import("std");
const ffi = @import("ffi.zig");
const reaper = @import("reaper.zig");
const protocol = @import("protocol.zig");
const constants = @import("constants.zig");

// Re-export shared constants for backward compatibility
pub const MAX_MARKERS = constants.MAX_MARKERS;
pub const MAX_REGIONS = constants.MAX_REGIONS;

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
    markers: []Marker = &.{},
    regions: []Region = &.{},
    bar_offset: c_int = 0, // For bar string formatting

    const Allocator = std.mem.Allocator;

    /// Returns an empty state (for initialization).
    pub fn empty() State {
        return .{ .markers = &.{}, .regions = &.{}, .bar_offset = 0 };
    }

    /// Returns the number of markers.
    pub fn markerCount(self: *const State) usize {
        return self.markers.len;
    }

    /// Returns the number of regions.
    pub fn regionCount(self: *const State) usize {
        return self.regions.len;
    }

    /// Poll current state from REAPER, allocating from the provided allocator.
    /// Use this with arena allocation for frame-based lifetimes.
    pub fn poll(allocator: Allocator, api: anytype) Allocator.Error!State {
        return pollWithLimit(allocator, api, MAX_MARKERS, MAX_REGIONS);
    }

    /// Poll with configurable limits.
    pub fn pollWithLimit(allocator: Allocator, api: anytype, max_markers: usize, max_regions: usize) Allocator.Error!State {
        // First pass: count markers and regions
        var total_markers: usize = 0;
        var total_regions: usize = 0;
        var idx: c_int = 0;
        while (api.enumMarker(idx)) |info| : (idx += 1) {
            if (info.is_region) {
                if (total_regions < max_regions) total_regions += 1;
            } else {
                if (total_markers < max_markers) total_markers += 1;
            }
        }

        // Always allocate - 0-length alloc is valid and has no overhead
        const marker_buf = try allocator.alloc(Marker, total_markers);
        const region_buf = try allocator.alloc(Region, total_regions);

        var state = State{
            .markers = marker_buf,
            .regions = region_buf,
            .bar_offset = api.getBarOffset(),
        };

        // Second pass: populate (reuse pollIntoBuffers logic)
        state.pollIntoBuffers(marker_buf, region_buf, api);
        return state;
    }

    /// Poll current state from REAPER into an existing State struct with static buffers.
    /// Accepts any backend type (RealBackend, MockBackend, or test doubles).
    /// NOTE: Uses output pointer to avoid ~95KB stack allocation.
    pub fn pollInto(self: *State, marker_buffer: []Marker, region_buffer: []Region, api: anytype) void {
        self.pollIntoBuffers(marker_buffer, region_buffer, api);
    }

    /// Internal: populate markers and regions into the provided buffers.
    fn pollIntoBuffers(self: *State, marker_buffer: []Marker, region_buffer: []Region, api: anytype) void {
        var marker_count: usize = 0;
        var region_count: usize = 0;
        self.bar_offset = api.getBarOffset();

        var idx: c_int = 0;
        while (api.enumMarker(idx)) |info| : (idx += 1) {
            if (info.is_region) {
                if (region_count < region_buffer.len) {
                    var region = &region_buffer[region_count];
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

                    region_count += 1;
                }
            } else {
                if (marker_count < marker_buffer.len) {
                    var marker = &marker_buffer[marker_count];
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

                    marker_count += 1;
                }
            }
        }

        self.markers = marker_buffer[0..marker_count];
        self.regions = region_buffer[0..region_count];
    }

    /// Convenience wrapper that returns State using static buffers (for tests).
    /// WARNING: Uses static buffers - NOT thread-safe, do NOT use in production!
    pub fn pollStatic(api: anytype) State {
        const S = struct {
            var marker_buffer: [MAX_MARKERS]Marker = undefined;
            var region_buffer: [MAX_REGIONS]Region = undefined;
        };
        var state = State{};
        state.pollInto(&S.marker_buffer, &S.region_buffer, api);
        return state;
    }

    // Check if markers have changed
    pub fn markersChanged(self: *const State, other: *const State) bool {
        if (self.markers.len != other.markers.len) return true;

        for (0..self.markers.len) |i| {
            if (!self.markers[i].eql(&other.markers[i])) return true;
        }
        return false;
    }

    // Check if regions have changed
    pub fn regionsChanged(self: *const State, other: *const State) bool {
        if (self.regions.len != other.regions.len) return true;

        for (0..self.regions.len) |i| {
            if (!self.regions[i].eql(&other.regions[i])) return true;
        }
        return false;
    }

    // Format bar.beat.ticks string (e.g., "5.2.50")
    // bar: measure number from timeToBeats (before offset applied)
    // beat_in_bar: 0-indexed beat within measure (from timeToBeats)
    // bar_offset: project bar offset to apply
    pub fn formatBars(w: anytype, bar: c_int, beat_in_bar: f64, bar_offset: c_int) !void {
        const display_bar = bar + bar_offset;
        // Convert 0-indexed to 1-indexed and extract ticks
        // Use integer arithmetic to avoid floating-point precision issues
        // roundFloatToInt validates NaN/Inf from corrupt project data
        const scaled: u32 = ffi.roundFloatToInt(u32, (beat_in_bar + 1.0) * 100.0) catch return error.InvalidBeatValue;
        const beat_int: u32 = @max(1, scaled / 100);
        const ticks: u32 = scaled % 100;
        try w.print("{d}.{d}.{d:0>2}", .{ display_bar, beat_int, ticks });
    }

    // Format length as bar.beat.ticks string (e.g., "10.1.50")
    // Computes the difference between end and start positions with borrowing.
    // Uses time sig numerator at START position for beat borrowing (you borrow from the start bar).
    pub fn formatLengthBars(
        w: anytype,
        start_bar: c_int,
        start_beat_in_bar: f64,
        end_bar: c_int,
        end_beat_in_bar: f64,
        start_beats_per_bar: c_int,
    ) !void {
        // Convert beat_in_bar (0-indexed with fraction) to scaled integers (ticks = fraction * 100)
        // start_beat_in_bar=0.0 means beat 1.00, start_beat_in_bar=1.5 means beat 2.50
        // roundFloatToInt validates NaN/Inf from corrupt project data
        const start_scaled: i32 = ffi.roundFloatToInt(i32, start_beat_in_bar * 100.0) catch return error.InvalidBeatValue;
        const end_scaled: i32 = ffi.roundFloatToInt(i32, end_beat_in_bar * 100.0) catch return error.InvalidBeatValue;

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

        for (0..self.markers.len) |i| {
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

        for (0..self.regions.len) |i| {
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

    // Allocator-based versions - return owned slice from allocator
    pub fn markersToJsonAlloc(self: *const State, allocator: std.mem.Allocator) ![]const u8 {
        var buf: [8192]u8 = undefined;
        const json = self.markersToJson(&buf) orelse return error.JsonSerializationFailed;
        return allocator.dupe(u8, json);
    }

    pub fn regionsToJsonAlloc(self: *const State, allocator: std.mem.Allocator) ![]const u8 {
        var buf: [8192]u8 = undefined;
        const json = self.regionsToJson(&buf) orelse return error.JsonSerializationFailed;
        return allocator.dupe(u8, json);
    }

    /// Poll markers within a time range (for timeline subscriptions).
    /// Filters to only markers within [range_start, range_end].
    pub fn pollMarkersTimeRange(allocator: Allocator, api: anytype, range_start: f64, range_end: f64) Allocator.Error!MarkersOnlyState {
        return pollMarkersTimeRangeWithLimit(allocator, api, range_start, range_end, MAX_MARKERS);
    }

    /// Poll markers within time range with configurable limit.
    pub fn pollMarkersTimeRangeWithLimit(allocator: Allocator, api: anytype, range_start: f64, range_end: f64, max_markers: usize) Allocator.Error!MarkersOnlyState {
        // First pass: count markers in range
        var total_markers: usize = 0;
        var idx: c_int = 0;
        while (api.enumMarker(idx)) |info| : (idx += 1) {
            if (!info.is_region and info.pos >= range_start and info.pos <= range_end) {
                total_markers += 1;
                if (total_markers >= max_markers) break;
            }
        }

        const marker_buf = try allocator.alloc(Marker, total_markers);
        const bar_offset = api.getBarOffset();

        // Second pass: populate
        var write_idx: usize = 0;
        idx = 0;
        while (api.enumMarker(idx)) |info| : (idx += 1) {
            if (write_idx >= marker_buf.len) break;
            if (info.is_region) continue;
            if (info.pos < range_start or info.pos > range_end) continue;

            var marker = &marker_buf[write_idx];
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

            write_idx += 1;
        }

        return .{ .markers = marker_buf[0..write_idx], .bar_offset = bar_offset };
    }

    /// Poll regions within a time range (for timeline subscriptions).
    /// Filters to only regions that overlap [range_start, range_end].
    pub fn pollRegionsTimeRange(allocator: Allocator, api: anytype, range_start: f64, range_end: f64) Allocator.Error!RegionsOnlyState {
        return pollRegionsTimeRangeWithLimit(allocator, api, range_start, range_end, MAX_REGIONS);
    }

    /// Poll regions within time range with configurable limit.
    pub fn pollRegionsTimeRangeWithLimit(allocator: Allocator, api: anytype, range_start: f64, range_end: f64, max_regions: usize) Allocator.Error!RegionsOnlyState {
        // First pass: count regions in range
        var total_regions: usize = 0;
        var idx: c_int = 0;
        while (api.enumMarker(idx)) |info| : (idx += 1) {
            if (info.is_region and regionOverlapsRange(info.pos, info.end, range_start, range_end)) {
                total_regions += 1;
                if (total_regions >= max_regions) break;
            }
        }

        const region_buf = try allocator.alloc(Region, total_regions);
        const bar_offset = api.getBarOffset();

        // Second pass: populate
        var write_idx: usize = 0;
        idx = 0;
        while (api.enumMarker(idx)) |info| : (idx += 1) {
            if (write_idx >= region_buf.len) break;
            if (!info.is_region) continue;
            if (!regionOverlapsRange(info.pos, info.end, range_start, range_end)) continue;

            var region = &region_buf[write_idx];
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
            const start_timesig = api.getTempoAtPosition(info.pos);
            region.start_beats_per_bar = start_timesig.timesig_num;

            const copy_len = @min(info.name.len, region.name.len);
            @memcpy(region.name[0..copy_len], info.name[0..copy_len]);
            region.name_len = copy_len;

            write_idx += 1;
        }

        return .{ .regions = region_buf[0..write_idx], .bar_offset = bar_offset };
    }

    /// Compute a hash of the markers state for change detection.
    pub fn computeMarkersHash(self: *const State) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&self.markers.len));
        for (self.markers) |m| {
            hasher.update(std.mem.asBytes(&m.id));
            hasher.update(std.mem.asBytes(&m.position));
            hasher.update(std.mem.asBytes(&m.color));
            hasher.update(m.name[0..m.name_len]);
        }
        return hasher.final();
    }

    /// Compute a hash of the regions state for change detection.
    pub fn computeRegionsHash(self: *const State) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&self.regions.len));
        for (self.regions) |r| {
            hasher.update(std.mem.asBytes(&r.id));
            hasher.update(std.mem.asBytes(&r.start));
            hasher.update(std.mem.asBytes(&r.end));
            hasher.update(std.mem.asBytes(&r.color));
            hasher.update(r.name[0..r.name_len]);
        }
        return hasher.final();
    }
};

/// State for markers-only polling (for timeline subscriptions).
pub const MarkersOnlyState = struct {
    markers: []Marker = &.{},
    bar_offset: c_int = 0,

    /// Generate JSON for markers event.
    pub fn markersToJson(self: *const MarkersOnlyState, buf: []u8) ?[]const u8 {
        var stream = std.io.fixedBufferStream(buf);
        var w = stream.writer();

        w.writeAll("{\"type\":\"event\",\"event\":\"markers\",\"payload\":{\"markers\":[") catch return null;

        for (0..self.markers.len) |i| {
            if (i > 0) w.writeByte(',') catch return null;
            const m = &self.markers[i];
            w.print("{{\"id\":{d},\"position\":{d:.15},\"positionBeats\":{d:.6},\"positionBars\":\"", .{
                m.id,
                m.position,
                m.position_beats,
            }) catch return null;
            State.formatBars(w, m.position_bar, m.position_beat_in_bar, self.bar_offset) catch return null;
            w.writeAll("\",\"name\":\"") catch return null;
            protocol.writeJsonString(w, m.getName()) catch return null;
            w.print("\",\"color\":{d}}}", .{m.color}) catch return null;
        }

        w.writeAll("]}}") catch return null;
        return stream.getWritten();
    }

    pub fn markersToJsonAlloc(self: *const MarkersOnlyState, allocator: std.mem.Allocator) ![]const u8 {
        var buf: [8192]u8 = undefined;
        const json = self.markersToJson(&buf) orelse return error.JsonSerializationFailed;
        return allocator.dupe(u8, json);
    }

    /// Compute a hash for change detection.
    pub fn computeHash(self: *const MarkersOnlyState) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&self.markers.len));
        for (self.markers) |m| {
            hasher.update(std.mem.asBytes(&m.id));
            hasher.update(std.mem.asBytes(&m.position));
            hasher.update(std.mem.asBytes(&m.color));
            hasher.update(m.name[0..m.name_len]);
        }
        return hasher.final();
    }
};

/// State for regions-only polling (for timeline subscriptions).
pub const RegionsOnlyState = struct {
    regions: []Region = &.{},
    bar_offset: c_int = 0,

    /// Generate JSON for regions event.
    pub fn regionsToJson(self: *const RegionsOnlyState, buf: []u8) ?[]const u8 {
        var stream = std.io.fixedBufferStream(buf);
        var w = stream.writer();

        w.writeAll("{\"type\":\"event\",\"event\":\"regions\",\"payload\":{\"regions\":[") catch return null;

        for (0..self.regions.len) |i| {
            if (i > 0) w.writeByte(',') catch return null;
            const r = &self.regions[i];
            w.print("{{\"id\":{d},\"start\":{d:.15},\"end\":{d:.15},\"startBeats\":{d:.6},\"endBeats\":{d:.6},\"startBars\":\"", .{
                r.id,
                r.start,
                r.end,
                r.start_beats,
                r.end_beats,
            }) catch return null;
            State.formatBars(w, r.start_bar, r.start_beat_in_bar, self.bar_offset) catch return null;
            w.writeAll("\",\"endBars\":\"") catch return null;
            State.formatBars(w, r.end_bar, r.end_beat_in_bar, self.bar_offset) catch return null;
            w.writeAll("\",\"lengthBars\":\"") catch return null;
            State.formatLengthBars(w, r.start_bar, r.start_beat_in_bar, r.end_bar, r.end_beat_in_bar, r.start_beats_per_bar) catch return null;
            w.writeAll("\",\"name\":\"") catch return null;
            protocol.writeJsonString(w, r.getName()) catch return null;
            w.print("\",\"color\":{d}}}", .{r.color}) catch return null;
        }

        w.writeAll("]}}") catch return null;
        return stream.getWritten();
    }

    pub fn regionsToJsonAlloc(self: *const RegionsOnlyState, allocator: std.mem.Allocator) ![]const u8 {
        var buf: [8192]u8 = undefined;
        const json = self.regionsToJson(&buf) orelse return error.JsonSerializationFailed;
        return allocator.dupe(u8, json);
    }

    /// Compute a hash for change detection.
    pub fn computeHash(self: *const RegionsOnlyState) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&self.regions.len));
        for (self.regions) |r| {
            hasher.update(std.mem.asBytes(&r.id));
            hasher.update(std.mem.asBytes(&r.start));
            hasher.update(std.mem.asBytes(&r.end));
            hasher.update(std.mem.asBytes(&r.color));
            hasher.update(r.name[0..r.name_len]);
        }
        return hasher.final();
    }
};

/// Check if region overlaps time range.
/// Region overlaps if: region.start < range_end AND region.end > range_start
fn regionOverlapsRange(region_start: f64, region_end: f64, range_start: f64, range_end: f64) bool {
    return region_start < range_end and region_end > range_start;
}

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
    // Use a static buffer for testing
    var marker_buffer: [1]Marker = undefined;
    marker_buffer[0] = .{
        .id = 1,
        .position = 10.5,
        .position_beats = 21.5,
        .position_bar = 3,
        .position_beat_in_bar = 1.5, // 0-indexed, so beat 2 + 50 ticks
        .color = 16711680,
    };
    marker_buffer[0].name[0..5].* = "Verse".*;
    marker_buffer[0].name_len = 5;

    const state = State{ .markers = &marker_buffer, .regions = &.{}, .bar_offset = 0 };

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
    // Use a static buffer for testing
    var region_buffer: [1]Region = undefined;
    region_buffer[0] = .{
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
    region_buffer[0].name[0..5].* = "Intro".*;
    region_buffer[0].name_len = 5;

    const state = State{ .markers = &.{}, .regions = &region_buffer, .bar_offset = -4 };

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
    var buffer1: [1]Marker = undefined;
    buffer1[0] = .{ .id = 1, .position = 10.0, .color = 0 };

    var buffer2: [1]Marker = undefined;
    buffer2[0] = .{ .id = 1, .position = 10.0, .color = 0 };

    const state1 = State{ .markers = &buffer1, .regions = &.{} };
    var state2 = State{ .markers = &buffer2, .regions = &.{} };

    try std.testing.expect(!state1.markersChanged(&state2));

    buffer2[0].position = 15.0;
    try std.testing.expect(state1.markersChanged(&state2));
}

test "marker position preserves sub-millisecond precision" {
    // Regression test: Position 17.333333... must not be truncated to 17.333
    // because that causes beat display errors (4.4.99 instead of 4.5.00)
    // at 90 BPM in 6/8 time.
    var marker_buffer: [1]Marker = undefined;
    marker_buffer[0] = .{ .id = 1, .position = 17.333333333333329, .color = 0 };
    marker_buffer[0].name[0..2].* = "m1".*;
    marker_buffer[0].name_len = 2;

    const state = State{ .markers = &marker_buffer, .regions = &.{} };

    var buf: [1024]u8 = undefined;
    const json = state.markersToJson(&buf).?;

    // Position should preserve enough precision to distinguish 17.333333... from 17.333
    // The JSON should contain "17.333333" (6 decimal places minimum)
    try std.testing.expect(std.mem.indexOf(u8, json, "17.333333") != null);
}

test "region position preserves sub-millisecond precision" {
    // Same precision requirement for regions
    var region_buffer: [1]Region = undefined;
    region_buffer[0] = .{ .id = 1, .start = 0.0, .end = 17.333333333333329, .color = 0 };
    region_buffer[0].name[0..4].* = "Test".*;
    region_buffer[0].name_len = 4;

    const state = State{ .markers = &.{}, .regions = &region_buffer };

    var buf: [1024]u8 = undefined;
    const json = state.regionsToJson(&buf).?;

    // End position should preserve precision
    try std.testing.expect(std.mem.indexOf(u8, json, "17.333333") != null);
}

// =============================================================================
// MockBackend-based tests
// =============================================================================

const MockBackend = reaper.MockBackend;

test "poll with MockBackend returns markers and regions" {
    var mock = MockBackend{
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
        .color = 16711680,
    };
    mock.markers[0].setName("Verse");

    // Set up a region
    mock.markers[1] = .{
        .idx = 1,
        .id = 2,
        .pos = 0.0,
        .end = 30.0,
        .is_region = true,
        .color = 255,
    };
    mock.markers[1].setName("Intro");

    const state = State.pollStatic(&mock);

    try std.testing.expectEqual(@as(c_int, -4), state.bar_offset);
    try std.testing.expectEqual(@as(usize, 1), state.markers.len);
    try std.testing.expectEqual(@as(usize, 1), state.regions.len);

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

test "poll with MockBackend returns empty state when no markers" {
    var mock = MockBackend{
        .marker_count = 0,
        .region_count = 0,
    };

    const state = State.pollStatic(&mock);

    try std.testing.expectEqual(@as(usize, 0), state.markers.len);
    try std.testing.expectEqual(@as(usize, 0), state.regions.len);
}

test "poll tracks API calls correctly" {
    var mock = MockBackend{
        .marker_count = 1,
        .region_count = 0,
    };
    mock.markers[0] = .{
        .idx = 0,
        .id = 1,
        .pos = 5.0,
        .end = 0.0,
        .is_region = false,
        .color = 0,
    };
    mock.markers[0].setName("Test");

    _ = State.pollStatic(&mock);

    // Verify key API calls were made
    try std.testing.expect(mock.getCallCount(.getBarOffset) >= 1);
    try std.testing.expect(mock.getCallCount(.enumMarker) >= 1);
    try std.testing.expect(mock.getCallCount(.timeToBeats) >= 1);
}

test "pollMarkersTimeRange filters markers by time range" {
    var mock = MockBackend{
        .marker_count = 3,
        .region_count = 0,
    };
    // Create 3 markers at positions 5, 25, 50
    mock.markers[0] = .{ .idx = 0, .id = 1, .pos = 5.0, .end = 0.0, .is_region = false, .color = 0 };
    mock.markers[0].setName("M1");
    mock.markers[1] = .{ .idx = 1, .id = 2, .pos = 25.0, .end = 0.0, .is_region = false, .color = 0 };
    mock.markers[1].setName("M2");
    mock.markers[2] = .{ .idx = 2, .id = 3, .pos = 50.0, .end = 0.0, .is_region = false, .color = 0 };
    mock.markers[2].setName("M3");

    const allocator = std.testing.allocator;

    // Range 10-40 should include marker at 25 only
    const state = try State.pollMarkersTimeRange(allocator, &mock, 10.0, 40.0);
    defer allocator.free(state.markers);

    try std.testing.expectEqual(@as(usize, 1), state.markers.len);
    try std.testing.expect(@abs(state.markers[0].position - 25.0) < 0.001);
}

test "pollRegionsTimeRange filters regions by time range" {
    var mock = MockBackend{
        .marker_count = 0,
        .region_count = 3,
    };
    // Create 3 regions: 0-10, 20-30, 50-60
    mock.markers[0] = .{ .idx = 0, .id = 1, .pos = 0.0, .end = 10.0, .is_region = true, .color = 0 };
    mock.markers[0].setName("R1");
    mock.markers[1] = .{ .idx = 1, .id = 2, .pos = 20.0, .end = 30.0, .is_region = true, .color = 0 };
    mock.markers[1].setName("R2");
    mock.markers[2] = .{ .idx = 2, .id = 3, .pos = 50.0, .end = 60.0, .is_region = true, .color = 0 };
    mock.markers[2].setName("R3");

    const allocator = std.testing.allocator;

    // Range 15-35 should include region at 20-30 only
    const state = try State.pollRegionsTimeRange(allocator, &mock, 15.0, 35.0);
    defer allocator.free(state.regions);

    try std.testing.expectEqual(@as(usize, 1), state.regions.len);
    try std.testing.expect(@abs(state.regions[0].start - 20.0) < 0.001);
}

test "pollRegionsTimeRange includes partially overlapping regions" {
    var mock = MockBackend{
        .marker_count = 0,
        .region_count = 1,
    };
    mock.markers[0] = .{ .idx = 0, .id = 1, .pos = 5.0, .end = 15.0, .is_region = true, .color = 0 }; // 5-15
    mock.markers[0].setName("R1");

    const allocator = std.testing.allocator;

    // Range 10-20 overlaps with region at 5-15 (region_end=15 > range_start=10)
    const state = try State.pollRegionsTimeRange(allocator, &mock, 10.0, 20.0);
    defer allocator.free(state.regions);

    try std.testing.expectEqual(@as(usize, 1), state.regions.len);
}

test "regionOverlapsRange" {
    // Region fully inside range
    try std.testing.expect(regionOverlapsRange(15.0, 25.0, 10.0, 30.0));

    // Region starts before, ends inside
    try std.testing.expect(regionOverlapsRange(5.0, 15.0, 10.0, 30.0));

    // Region starts inside, ends after
    try std.testing.expect(regionOverlapsRange(25.0, 35.0, 10.0, 30.0));

    // Region contains range
    try std.testing.expect(regionOverlapsRange(0.0, 100.0, 10.0, 30.0));

    // Region completely before range
    try std.testing.expect(!regionOverlapsRange(0.0, 5.0, 10.0, 30.0));

    // Region completely after range
    try std.testing.expect(!regionOverlapsRange(35.0, 40.0, 10.0, 30.0));

    // Region ends exactly at range start (no overlap)
    try std.testing.expect(!regionOverlapsRange(0.0, 10.0, 10.0, 30.0));

    // Region starts exactly at range end (no overlap)
    try std.testing.expect(!regionOverlapsRange(30.0, 40.0, 10.0, 30.0));
}
