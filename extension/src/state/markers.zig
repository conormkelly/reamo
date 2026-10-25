const std = @import("std");
const utf8 = @import("../core/utf8.zig");
const ffi = @import("../core/ffi.zig");
const bar_beat = @import("bar_beat.zig");
const reaper = @import("../reaper.zig");
const protocol = @import("../core/protocol.zig");
const constants = @import("../core/constants.zig");

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
    position_beats_per_bar: c_int = 4, // Time sig numerator at the position
    name: [128]u8 = undefined,
    name_len: usize = 0,
    color: c_int,

    pub fn getName(self: *const Marker) []const u8 {
        return self.name[0..self.name_len];
    }

    /// True when a client would see the same marker. Covers the
    /// beat-derived fields too: a tempo or meter change moves a marker's
    /// bar label without moving its time.
    pub fn eql(self: *const Marker, other: *const Marker) bool {
        if (self.id != other.id) return false;
        if (@abs(self.position - other.position) > constants.TIME_EPSILON) return false;
        if (@abs(self.position_beats - other.position_beats) > constants.TIME_EPSILON) return false;
        if (self.position_bar != other.position_bar) return false;
        if (@abs(self.position_beat_in_bar - other.position_beat_in_bar) > constants.TIME_EPSILON) return false;
        if (self.position_beats_per_bar != other.position_beats_per_bar) return false;
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
    end_beats_per_bar: c_int = 4, // Time sig numerator at end (for its label)
    name: [128]u8 = undefined,
    name_len: usize = 0,
    color: c_int,

    pub fn getName(self: *const Region) []const u8 {
        return self.name[0..self.name_len];
    }

    /// True when a client would see the same region, including the
    /// beat-derived bar labels and length (see Marker.eql).
    pub fn eql(self: *const Region, other: *const Region) bool {
        if (self.id != other.id) return false;
        if (@abs(self.start - other.start) > constants.TIME_EPSILON) return false;
        if (@abs(self.end - other.end) > constants.TIME_EPSILON) return false;
        if (@abs(self.start_beats - other.start_beats) > constants.TIME_EPSILON) return false;
        if (@abs(self.end_beats - other.end_beats) > constants.TIME_EPSILON) return false;
        if (self.start_bar != other.start_bar) return false;
        if (self.end_bar != other.end_bar) return false;
        if (@abs(self.start_beat_in_bar - other.start_beat_in_bar) > constants.TIME_EPSILON) return false;
        if (@abs(self.end_beat_in_bar - other.end_beat_in_bar) > constants.TIME_EPSILON) return false;
        if (self.start_beats_per_bar != other.start_beats_per_bar) return false;
        if (self.end_beats_per_bar != other.end_beats_per_bar) return false;
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
                    region.color = shownColor(info.color);

                    // Compute beat positions
                    const start_beats = api.timeToBeats(info.pos);
                    region.start_beats = start_beats.beats;
                    region.start_bar = start_beats.measures;
                    region.start_beat_in_bar = start_beats.beats_in_measure;

                    const end_beats = api.timeToBeats(info.end);
                    region.end_beats = end_beats.beats;
                    region.end_bar = end_beats.measures;
                    region.end_beat_in_bar = end_beats.beats_in_measure;
                    region.end_beats_per_bar = end_beats.time_sig_num;

                    // Get time sig at start for length borrowing calculation
                    // When borrowing beats, we use the time signature of the bar we're borrowing FROM
                    const start_timesig = api.getTempoAtPosition(info.pos);
                    region.start_beats_per_bar = start_timesig.timesig_num;

                    const copy_len = utf8.copyPrefix(&region.name, info.name);
                    region.name_len = copy_len;

                    region_count += 1;
                }
            } else {
                if (marker_count < marker_buffer.len) {
                    var marker = &marker_buffer[marker_count];
                    marker.id = info.id;
                    marker.position = info.pos;
                    marker.color = shownColor(info.color);

                    // Compute beat position
                    const beats_info = api.timeToBeats(info.pos);
                    marker.position_beats = beats_info.beats;
                    marker.position_bar = beats_info.measures;
                    marker.position_beat_in_bar = beats_info.beats_in_measure;
                    marker.position_beats_per_bar = beats_info.time_sig_num;

                    const copy_len = utf8.copyPrefix(&marker.name, info.name);
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

    /// True when the markers event clients hold is out of date. The
    /// project start measure (bar_offset) shifts every bar label.
    pub fn markersChanged(self: *const State, other: *const State) bool {
        if (self.markers.len != other.markers.len) return true;
        if (self.markers.len > 0 and self.bar_offset != other.bar_offset) return true;

        for (0..self.markers.len) |i| {
            if (!self.markers[i].eql(&other.markers[i])) return true;
        }
        return false;
    }

    /// True when the regions event clients hold is out of date (see markersChanged).
    pub fn regionsChanged(self: *const State, other: *const State) bool {
        if (self.regions.len != other.regions.len) return true;
        if (self.regions.len > 0 and self.bar_offset != other.bar_offset) return true;

        for (0..self.regions.len) |i| {
            if (!self.regions[i].eql(&other.regions[i])) return true;
        }
        return false;
    }

    // Format bar.beat.ticks string (e.g., "5.2.50")
    // bar: measure number from timeToBeats (before offset applied)
    // beat_in_bar: 0-indexed beat within measure (from timeToBeats)
    // beats_per_bar: time sig numerator at the position (rounding can carry a bar)
    // bar_offset: project bar offset to apply
    // A position REAPER reports that can't be formatted (NaN, or a bar out of
    // range in a corrupt project) is written as nothing: failing would read
    // to serializeAlloc as "buffer too small" and drop every marker.
    pub fn formatBars(w: anytype, bar: c_int, beat_in_bar: f64, beats_per_bar: c_int, bar_offset: c_int) !void {
        bar_beat.write(w, bar, beat_in_bar, beats_per_bar, bar_offset) catch |e| switch (e) {
            error.InvalidBeatValue => {},
            else => |write_err| return write_err,
        };
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
        // Unformattable positions write nothing (see formatBars).
        const start_scaled: i32 = ffi.roundFloatToInt(i32, start_beat_in_bar * 100.0) catch return;
        const end_scaled: i32 = ffi.roundFloatToInt(i32, end_beat_in_bar * 100.0) catch return;

        var bar_diff: i32 = std.math.sub(i32, end_bar, start_bar) catch return;
        var beat_diff: i32 = std.math.sub(i32, end_scaled, start_scaled) catch return;

        // Handle borrowing: if beat_diff is negative, borrow from bars
        // Use time signature at START - when borrowing a bar, you're taking beats from the start position's bar
        if (beat_diff < 0) {
            bar_diff = std.math.sub(i32, bar_diff, 1) catch return;
            // Add one full bar worth of beats (in scaled units: beats_per_bar * 100)
            const bar_beats = std.math.mul(i32, start_beats_per_bar, 100) catch return;
            beat_diff = std.math.add(i32, beat_diff, bar_beats) catch return;
        }

        // Extract beat and ticks from the scaled difference
        // beat_diff is now the total scaled difference (whole beats * 100 + ticks)
        // A region ending before it starts (never from REAPER, but the data is
        // REAPER's) still has a negative difference after one borrow.
        const beat_int = std.math.cast(u32, @divFloor(beat_diff, 100)) orelse return;
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
            formatBars(w, m.position_bar, m.position_beat_in_bar, m.position_beats_per_bar, self.bar_offset) catch return null;
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
            formatBars(w, r.start_bar, r.start_beat_in_bar, r.start_beats_per_bar, self.bar_offset) catch return null;
            w.writeAll("\",\"endBars\":\"") catch return null;
            formatBars(w, r.end_bar, r.end_beat_in_bar, r.end_beats_per_bar, self.bar_offset) catch return null;
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
    // Allocates from arena instead of stack to avoid stack overflow in timer callbacks
    pub fn markersToJsonAlloc(self: *const State, allocator: std.mem.Allocator) ![]const u8 {
        return protocol.serializeAlloc(allocator, 256 + self.markers.len * 224, self, markersToJson);
    }

    pub fn regionsToJsonAlloc(self: *const State, allocator: std.mem.Allocator) ![]const u8 {
        return protocol.serializeAlloc(allocator, 256 + self.regions.len * 320, self, regionsToJson);
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
            marker.color = shownColor(info.color);

            // Compute beat position
            const beats_info = api.timeToBeats(info.pos);
            marker.position_beats = beats_info.beats;
            marker.position_bar = beats_info.measures;
            marker.position_beat_in_bar = beats_info.beats_in_measure;
            marker.position_beats_per_bar = beats_info.time_sig_num;

            const copy_len = utf8.copyPrefix(&marker.name, info.name);
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
            region.color = shownColor(info.color);

            // Compute beat positions
            const start_beats = api.timeToBeats(info.pos);
            region.start_beats = start_beats.beats;
            region.start_bar = start_beats.measures;
            region.start_beat_in_bar = start_beats.beats_in_measure;

            const end_beats = api.timeToBeats(info.end);
            region.end_beats = end_beats.beats;
            region.end_bar = end_beats.measures;
            region.end_beat_in_bar = end_beats.beats_in_measure;
            region.end_beats_per_bar = end_beats.time_sig_num;

            // Get time sig at start for length borrowing calculation
            const start_timesig = api.getTempoAtPosition(info.pos);
            region.start_beats_per_bar = start_timesig.timesig_num;

            const copy_len = utf8.copyPrefix(&region.name, info.name);
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
            State.formatBars(w, m.position_bar, m.position_beat_in_bar, m.position_beats_per_bar, self.bar_offset) catch return null;
            w.writeAll("\",\"name\":\"") catch return null;
            protocol.writeJsonString(w, m.getName()) catch return null;
            w.print("\",\"color\":{d}}}", .{m.color}) catch return null;
        }

        w.writeAll("]}}") catch return null;
        return stream.getWritten();
    }

    pub fn markersToJsonAlloc(self: *const MarkersOnlyState, allocator: std.mem.Allocator) ![]const u8 {
        return protocol.serializeAlloc(allocator, 256 + self.markers.len * 224, self, markersToJson);
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
            State.formatBars(w, r.start_bar, r.start_beat_in_bar, r.start_beats_per_bar, self.bar_offset) catch return null;
            w.writeAll("\",\"endBars\":\"") catch return null;
            State.formatBars(w, r.end_bar, r.end_beat_in_bar, r.end_beats_per_bar, self.bar_offset) catch return null;
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
        return protocol.serializeAlloc(allocator, 256 + self.regions.len * 320, self, regionsToJson);
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

test "a marker whose bar position can't be formatted doesn't take the other markers with it" {
    var marker_buffer: [2]Marker = undefined;
    marker_buffer[0] = .{ .id = 1, .position = 1, .position_beat_in_bar = std.math.nan(f64), .color = 0 };
    marker_buffer[1] = .{ .id = 2, .position = 2, .position_bar = 2, .color = 0 };
    var region_buffer: [1]Region = undefined;
    region_buffer[0] = .{ .id = 3, .start = 0, .end = 4, .start_beat_in_bar = std.math.inf(f64), .color = 0 };
    const state = State{ .markers = &marker_buffer, .regions = &region_buffer };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const markers_json = try state.markersToJsonAlloc(arena.allocator());
    try std.testing.expect(try std.json.validate(std.testing.allocator, markers_json));
    try std.testing.expect(std.mem.indexOf(u8, markers_json, "\"id\":1,") != null);
    try std.testing.expect(std.mem.indexOf(u8, markers_json, "\"positionBars\":\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, markers_json, "\"positionBars\":\"2.1.00\"") != null);
    const regions_json = try state.regionsToJsonAlloc(arena.allocator());
    try std.testing.expect(try std.json.validate(std.testing.allocator, regions_json));
    try std.testing.expect(std.mem.indexOf(u8, regions_json, "\"id\":3,") != null);
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

test "a tempo change that keeps marker times still counts as a change" {
    // 4 s is bar 3.1.00 at 120 BPM and bar 2.1.00 at 60 BPM.
    var at_120: [1]Marker = .{.{ .id = 1, .position = 4.0, .position_beats = 8, .position_bar = 2, .color = 0 }};
    var at_60: [1]Marker = .{.{ .id = 1, .position = 4.0, .position_beats = 4, .position_bar = 1, .color = 0 }};
    at_120[0].name_len = 0;
    at_60[0].name_len = 0;

    const before = State{ .markers = &at_120, .regions = &.{} };
    const after = State{ .markers = &at_60, .regions = &.{} };
    try std.testing.expect(after.markersChanged(&before));

    // The meter and the beat within the bar feed the label on their own as well.
    var meter: [1]Marker = at_120;
    meter[0].position_beats_per_bar = 3;
    try std.testing.expect((State{ .markers = &meter, .regions = &.{} }).markersChanged(&before));

    var beat: [1]Marker = at_120;
    beat[0].position_beat_in_bar = 0.5;
    try std.testing.expect((State{ .markers = &beat, .regions = &.{} }).markersChanged(&before));
}

test "a tempo change that keeps region times still counts as a change" {
    var at_120: [1]Region = .{.{ .id = 1, .start = 4, .end = 12, .start_beats = 8, .end_beats = 24, .start_bar = 2, .end_bar = 6, .color = 0 }};
    at_120[0].name_len = 0;
    const before = State{ .markers = &.{}, .regions = &at_120 };

    var end_moved: [1]Region = at_120;
    end_moved[0].end_beats = 12;
    end_moved[0].end_bar = 3;
    try std.testing.expect((State{ .markers = &.{}, .regions = &end_moved }).regionsChanged(&before));

    var start_meter: [1]Region = at_120;
    start_meter[0].start_beats_per_bar = 7; // changes lengthBars borrowing
    try std.testing.expect((State{ .markers = &.{}, .regions = &start_meter }).regionsChanged(&before));
}

test "changing the project start measure counts as a change for every label" {
    var m: [1]Marker = .{.{ .id = 1, .position = 4.0, .color = 0 }};
    m[0].name_len = 0;
    var r: [1]Region = .{.{ .id = 1, .start = 4, .end = 12, .color = 0 }};
    r[0].name_len = 0;

    const before = State{ .markers = &m, .regions = &r, .bar_offset = 0 };
    const after = State{ .markers = &m, .regions = &r, .bar_offset = -5 };
    try std.testing.expect(after.markersChanged(&before));
    try std.testing.expect(after.regionsChanged(&before));
    try std.testing.expect(!before.markersChanged(&before));
    try std.testing.expect(!before.regionsChanged(&before));
}

test "empty marker lists do not change when only the start measure does" {
    // Nothing on the wire depends on bar_offset when there is nothing to label.
    const before = State{ .markers = &.{}, .regions = &.{}, .bar_offset = 0 };
    const after = State{ .markers = &.{}, .regions = &.{}, .bar_offset = 3 };
    try std.testing.expect(!after.markersChanged(&before));
    try std.testing.expect(!after.regionsChanged(&before));
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

/// The colour phones show for a marker or region: 0 (the theme's) unless
/// REAPER's custom flag is set. Resetting to the theme's colour, in REAPER or
/// from a phone, clears only the flag and leaves the RGB behind.
fn shownColor(raw: c_int) c_int {
    return if (raw & constants.CUSTOM_COLOR_FLAG != 0) raw else 0;
}

const MockBackend = reaper.MockBackend;

test "a marker or region reset to the theme's colour shows as 0, whatever RGB is left" {
    var mock = MockBackend{ .marker_count = 1, .region_count = 1 };
    mock.markers[0] = .{ .idx = 0, .id = 1, .pos = 2.0, .end = 0.0, .is_region = false, .color = 0x2828DC };
    mock.markers[0].setName("Verse");
    mock.markers[1] = .{ .idx = 1, .id = 2, .pos = 0.0, .end = 8.0, .is_region = true, .color = 0x2828DC | constants.CUSTOM_COLOR_FLAG };
    mock.markers[1].setName("Intro");

    const state = State.pollStatic(&mock);
    try std.testing.expectEqual(@as(c_int, 0), state.markers[0].color);
    try std.testing.expectEqual(@as(c_int, 0x2828DC | constants.CUSTOM_COLOR_FLAG), state.regions[0].color);
}

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

test "marker and region JSON serializes projects larger than one fixed buffer" {
    // Fixed 8 KB buffers held ~58 markers / ~36 regions; broadcasts were dropped.
    var backing: [1 << 20]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    var ms: [300]Marker = undefined;
    var rs: [300]Region = undefined;
    const name = "Verse 2 (double-tracked vocals, alt take)";
    for (&ms, &rs, 0..) |*m, *r, i| {
        m.* = .{ .id = @intCast(i), .position = @floatFromInt(i), .color = 0 };
        @memcpy(m.name[0..name.len], name);
        m.name_len = name.len;
        r.* = .{ .id = @intCast(i), .start = @floatFromInt(i), .end = @floatFromInt(i + 1), .color = 0 };
        @memcpy(r.name[0..name.len], name);
        r.name_len = name.len;
    }
    const alloc = fba.allocator();
    const full = State{ .markers = &ms, .regions = &rs };
    try std.testing.expect(try std.json.validate(std.testing.allocator, try full.markersToJsonAlloc(alloc)));
    try std.testing.expect(try std.json.validate(std.testing.allocator, try full.regionsToJsonAlloc(alloc)));
    const mo = MarkersOnlyState{ .markers = &ms };
    try std.testing.expect(try std.json.validate(std.testing.allocator, try mo.markersToJsonAlloc(alloc)));
    const ro = RegionsOnlyState{ .regions = &rs };
    try std.testing.expect(try std.json.validate(std.testing.allocator, try ro.regionsToJsonAlloc(alloc)));
}
