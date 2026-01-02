/// Mock marker and region methods.
const std = @import("std");
const types = @import("../types.zig");
const state = @import("state.zig");
const MockMarkerInfo = state.MockMarkerInfo;

/// Marker method implementations for MockBackend.
/// Called via @fieldParentPtr from the main MockBackend struct.
pub const MarkersMethods = struct {
    // =========================================================================
    // Marker queries
    // =========================================================================

    pub fn markerCount(self: anytype) types.MarkerCount {
        self.recordCall(.markerCount);
        return .{
            .total = self.marker_count + self.region_count,
            .markers = self.marker_count,
            .regions = self.region_count,
        };
    }

    pub fn enumMarker(self: anytype, idx: c_int) ?types.MarkerInfo {
        self.recordCall(.enumMarker);
        const total = self.marker_count + self.region_count;
        if (idx < 0 or idx >= total) return null;
        // Convert MockMarkerInfo to types.MarkerInfo
        return self.markers[@intCast(idx)].toMarkerInfo();
    }

    // =========================================================================
    // Marker mutations
    // =========================================================================

    pub fn addMarker(self: anytype, pos: f64, name: ?[*:0]const u8) c_int {
        self.recordCall(.addMarker);
        return self.addMarkerInternal(false, pos, name, 0);
    }

    pub fn addMarkerWithId(self: anytype, pos: f64, name: ?[*:0]const u8, id: c_int) c_int {
        self.recordCall(.addMarkerWithId);
        return self.addMarkerInternal(false, pos, name, id);
    }

    pub fn addRegion(self: anytype, start: f64, end: f64, name: ?[*:0]const u8) c_int {
        self.recordCall(.addRegion);
        return self.addRegionInternal(start, end, name, 0);
    }

    pub fn addRegionWithId(self: anytype, start: f64, end: f64, name: ?[*:0]const u8, id: c_int) c_int {
        self.recordCall(.addRegionWithId);
        return self.addRegionInternal(start, end, name, id);
    }

    pub fn updateMarker(self: anytype, idx: c_int, pos: f64, name: ?[*:0]const u8) bool {
        self.recordCall(.updateMarker);
        return self.updateMarkerInternal(idx, pos, pos, name, false);
    }

    pub fn updateRegion(self: anytype, idx: c_int, start: f64, end: f64, name: ?[*:0]const u8) bool {
        self.recordCall(.updateRegion);
        return self.updateMarkerInternal(idx, start, end, name, true);
    }

    pub fn deleteMarker(self: anytype, idx: c_int) bool {
        self.recordCall(.deleteMarker);
        return self.deleteMarkerInternal(idx, false);
    }

    pub fn deleteRegion(self: anytype, idx: c_int) bool {
        self.recordCall(.deleteRegion);
        return self.deleteMarkerInternal(idx, true);
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    fn addMarkerInternal(self: anytype, is_region: bool, pos_time: f64, name: ?[*:0]const u8, requested_id: c_int) c_int {
        const total: usize = @intCast(self.marker_count + self.region_count);
        if (total >= state.MAX_MARKERS) return -1;

        // Determine ID to use
        const id: c_int = if (requested_id > 0) requested_id else blk: {
            var max_id: c_int = 0;
            for (self.markers[0..total]) |m| {
                if (m.id > max_id) max_id = m.id;
            }
            break :blk max_id + 1;
        };

        // Create marker info
        var info = MockMarkerInfo{
            .idx = @intCast(total),
            .id = id,
            .is_region = is_region,
            .pos = pos_time,
            .end = pos_time,
            .color = 0,
        };

        // Copy name if provided
        if (name) |n| {
            info.setName(std.mem.sliceTo(n, 0));
        }

        self.markers[total] = info;
        if (is_region) {
            self.region_count += 1;
        } else {
            self.marker_count += 1;
        }

        return id;
    }

    fn addRegionInternal(self: anytype, start: f64, end_pos: f64, name: ?[*:0]const u8, requested_id: c_int) c_int {
        const total: usize = @intCast(self.marker_count + self.region_count);
        if (total >= state.MAX_MARKERS) return -1;

        const id: c_int = if (requested_id > 0) requested_id else blk: {
            var max_id: c_int = 0;
            for (self.markers[0..total]) |m| {
                if (m.id > max_id) max_id = m.id;
            }
            break :blk max_id + 1;
        };

        var info = MockMarkerInfo{
            .idx = @intCast(total),
            .id = id,
            .is_region = true,
            .pos = start,
            .end = end_pos,
            .color = 0,
        };

        if (name) |n| {
            info.setName(std.mem.sliceTo(n, 0));
        }

        self.markers[total] = info;
        self.region_count += 1;

        return id;
    }

    fn updateMarkerInternal(self: anytype, idx: c_int, start: f64, end_pos: f64, name: ?[*:0]const u8, is_region: bool) bool {
        const total = self.marker_count + self.region_count;
        if (idx < 0 or idx >= total) return false;

        const i: usize = @intCast(idx);
        if (self.markers[i].is_region != is_region) return false;

        self.markers[i].pos = start;
        self.markers[i].end = end_pos;

        if (name) |n| {
            self.markers[i].setName(std.mem.sliceTo(n, 0));
        }

        return true;
    }

    fn deleteMarkerInternal(self: anytype, idx: c_int, is_region: bool) bool {
        const total = self.marker_count + self.region_count;
        if (idx < 0 or idx >= total) return false;

        const i: usize = @intCast(idx);
        if (self.markers[i].is_region != is_region) return false;

        // Shift remaining markers down
        const total_usize: usize = @intCast(total);
        if (i + 1 < total_usize) {
            for (i..total_usize - 1) |j| {
                self.markers[j] = self.markers[j + 1];
            }
        }

        if (is_region) {
            self.region_count -= 1;
        } else {
            self.marker_count -= 1;
        }

        return true;
    }
};
