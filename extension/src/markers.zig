const std = @import("std");
const reaper = @import("reaper.zig");
const protocol = @import("protocol.zig");

// Maximum markers/regions we track (matches frontend reasonable limits)
pub const MAX_MARKERS = 256;
pub const MAX_REGIONS = 256;

// Marker data - matches frontend types.ts Marker interface
pub const Marker = struct {
    id: c_int,
    position: f64,
    name: [64]u8 = undefined,
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
    name: [64]u8 = undefined,
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

    // Poll current state from REAPER
    pub fn poll(api: *const reaper.Api) State {
        var state = State{};

        var idx: c_int = 0;
        while (api.enumMarker(idx)) |info| : (idx += 1) {
            if (info.is_region) {
                if (state.region_count < MAX_REGIONS) {
                    var region = &state.regions[state.region_count];
                    region.id = info.id;
                    region.start = info.pos;
                    region.end = info.end;
                    region.color = info.color;

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

    // Generate JSON for markers event
    pub fn markersToJson(self: *const State, buf: []u8) ?[]const u8 {
        var stream = std.io.fixedBufferStream(buf);
        var w = stream.writer();

        w.writeAll("{\"type\":\"event\",\"event\":\"markers\",\"payload\":{\"markers\":[") catch return null;

        for (0..self.marker_count) |i| {
            if (i > 0) w.writeByte(',') catch return null;
            const m = &self.markers[i];
            w.print("{{\"id\":{d},\"position\":{d:.3},\"name\":\"", .{ m.id, m.position }) catch return null;
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
            w.print("{{\"id\":{d},\"start\":{d:.3},\"end\":{d:.3},\"name\":\"", .{ r.id, r.start, r.end }) catch return null;
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

    // Add test marker
    state.markers[0] = .{ .id = 1, .position = 10.5, .color = 16711680 };
    state.markers[0].name[0..5].* = "Verse".*;
    state.markers[0].name_len = 5;
    state.marker_count = 1;

    var buf: [1024]u8 = undefined;
    const json = state.markersToJson(&buf).?;

    try std.testing.expectEqualStrings(
        "{\"type\":\"event\",\"event\":\"markers\",\"payload\":{\"markers\":[{\"id\":1,\"position\":10.500,\"name\":\"Verse\",\"color\":16711680}]}}",
        json,
    );
}

test "State regions JSON output" {
    var state = State{};

    // Add test region
    state.regions[0] = .{ .id = 2, .start = 0.0, .end = 30.0, .color = 255 };
    state.regions[0].name[0..5].* = "Intro".*;
    state.regions[0].name_len = 5;
    state.region_count = 1;

    var buf: [1024]u8 = undefined;
    const json = state.regionsToJson(&buf).?;

    try std.testing.expectEqualStrings(
        "{\"type\":\"event\",\"event\":\"regions\",\"payload\":{\"regions\":[{\"id\":2,\"start\":0.000,\"end\":30.000,\"name\":\"Intro\",\"color\":255}]}}",
        json,
    );
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
