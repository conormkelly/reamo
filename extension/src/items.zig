const std = @import("std");
const reaper = @import("reaper.zig");
const constants = @import("constants.zig");

// Re-export shared constants for backward compatibility
pub const MAX_ITEMS = constants.MAX_ITEMS;
pub const MAX_TAKES_PER_ITEM = constants.MAX_TAKES_PER_ITEM;
pub const MAX_NAME_LEN = constants.MAX_NAME_LEN;
pub const GUID_LEN = 38; // {XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX} (exact length, no padding)

// Take data
pub const Take = struct {
    guid: [GUID_LEN]u8 = undefined,
    guid_len: usize = 0,
    name: [MAX_NAME_LEN]u8 = undefined,
    name_len: usize = 0,
    is_active: bool = false,
    is_midi: bool = false,

    pub fn getGUID(self: *const Take) []const u8 {
        return self.guid[0..self.guid_len];
    }

    pub fn getName(self: *const Take) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn eql(self: *const Take, other: *const Take) bool {
        if (self.is_active != other.is_active) return false;
        if (self.is_midi != other.is_midi) return false;
        if (self.guid_len != other.guid_len) return false;
        if (!std.mem.eql(u8, self.getGUID(), other.getGUID())) return false;
        if (self.name_len != other.name_len) return false;
        return std.mem.eql(u8, self.getName(), other.getName());
    }
};

// Item data - matches frontend types.ts Item interface
pub const Item = struct {
    // Identity
    guid: [GUID_LEN]u8 = undefined,
    guid_len: usize = 0,
    track_idx: c_int = 0,
    item_idx: c_int = 0, // index within track

    // Position and length
    position: f64 = 0,
    length: f64 = 0,

    // Properties (nullable = corrupt data from REAPER)
    color: ?c_int = 0,
    locked: ?bool = false,
    selected: ?bool = false,
    active_take_idx: ?c_int = 0,

    // Sparse fields - full data fetched on-demand via item/getNotes, item/getTakes commands
    has_notes: bool = false,
    take_count: u8 = 0,

    pub fn getGUID(self: *const Item) []const u8 {
        return self.guid[0..self.guid_len];
    }

    pub fn eql(self: *const Item, other: *const Item) bool {
        if (self.guid_len != other.guid_len) return false;
        if (!std.mem.eql(u8, self.getGUID(), other.getGUID())) return false;
        if (self.track_idx != other.track_idx) return false;
        if (self.item_idx != other.item_idx) return false;
        if (@abs(self.position - other.position) > 0.001) return false;
        if (@abs(self.length - other.length) > 0.001) return false;
        if (self.color != other.color) return false;
        if (self.locked != other.locked) return false;
        if (self.selected != other.selected) return false;
        if (self.active_take_idx != other.active_take_idx) return false;
        // Sparse fields
        if (self.has_notes != other.has_notes) return false;
        if (self.take_count != other.take_count) return false;
        return true;
    }
};

// Cached state for change detection
pub const State = struct {
    items: []Item = &.{},

    const Allocator = std.mem.Allocator;

    /// Returns an empty state (for initialization).
    pub fn empty() State {
        return .{ .items = &.{} };
    }

    /// Returns the number of items.
    pub fn count(self: *const State) usize {
        return self.items.len;
    }

    /// Poll current state from REAPER, allocating from the provided allocator.
    /// Use this with arena allocation for frame-based lifetimes.
    pub fn poll(allocator: Allocator, api: anytype) Allocator.Error!State {
        return pollWithLimit(allocator, api, MAX_ITEMS);
    }

    /// Poll with configurable item limit.
    pub fn pollWithLimit(allocator: Allocator, api: anytype, max_items: usize) Allocator.Error!State {
        // First pass: count total items
        var total_items: usize = 0;
        const track_count = api.trackCount();
        var track_idx: c_int = 0;
        while (track_idx < track_count) : (track_idx += 1) {
            const track = api.getTrackByIdx(track_idx) orelse continue;

            // Validate track pointer (track could be deleted mid-enumeration)
            if (!api.validateTrackPtr(track)) continue;

            const item_count_on_track: usize = @intCast(@max(0, api.trackItemCount(track)));
            total_items += item_count_on_track;
            if (total_items >= max_items) {
                total_items = max_items;
                break;
            }
        }

        if (total_items == 0) {
            return .{ .items = &.{} };
        }

        const items = try allocator.alloc(Item, total_items);
        var state = State{ .items = items };

        // Second pass: populate (reuse pollInto logic with our allocated buffer)
        state.pollIntoBuffer(items, api);
        return state;
    }

    /// Poll current state from REAPER into an existing State struct with static buffer.
    /// Accepts any backend type (RealBackend, MockBackend, or test doubles).
    /// Returns ALL items in the project (frontend filters by time selection as needed)
    /// NOTE: Uses output pointer to avoid ~600KB stack allocation.
    pub fn pollInto(self: *State, static_buffer: []Item, api: anytype) void {
        self.pollIntoBuffer(static_buffer, api);
    }

    /// Internal: populate items into the provided buffer.
    fn pollIntoBuffer(self: *State, buffer: []Item, api: anytype) void {
        var total_count: usize = 0;

        // Enumerate all tracks
        const track_count = api.trackCount();
        var track_idx: c_int = 0;
        while (track_idx < track_count) : (track_idx += 1) {
            const track = api.getTrackByIdx(track_idx) orelse continue;

            // Validate track pointer (track could be deleted mid-enumeration)
            if (!api.validateTrackPtr(track)) continue;

            // Enumerate items on this track
            const items_on_track = api.trackItemCount(track);
            var item_idx: c_int = 0;
            while (item_idx < items_on_track) : (item_idx += 1) {
                if (total_count >= buffer.len) break;

                const item_ptr = api.getItemByIdx(track, item_idx) orelse continue;

                // Validate item pointer (item could be deleted mid-enumeration)
                if (!api.validateItemPtr(item_ptr)) continue;

                var item = &buffer[total_count];

                // Get item GUID
                var guid_buf: [64]u8 = undefined;
                const item_guid = api.getItemGUID(item_ptr, &guid_buf);
                const guid_copy_len = @min(item_guid.len, item.guid.len);
                @memcpy(item.guid[0..guid_copy_len], item_guid[0..guid_copy_len]);
                item.guid_len = guid_copy_len;

                item.track_idx = track_idx;
                item.item_idx = item_idx;
                item.position = api.getItemPosition(item_ptr);
                item.length = api.getItemLength(item_ptr);
                // These return error on NaN/Inf - propagate as null to client
                item.color = api.getItemColor(item_ptr) catch null;
                item.locked = api.getItemLocked(item_ptr) catch null;
                item.selected = api.getItemSelected(item_ptr) catch null;
                item.active_take_idx = api.getItemActiveTakeIdx(item_ptr) catch null;

                // Sparse fields - check if notes exist (non-empty), count takes
                // Full data fetched on-demand via item/getNotes, item/getTakes commands
                var notes_buf: [1024]u8 = undefined;
                const notes = api.getItemNotes(item_ptr, &notes_buf);
                item.has_notes = notes.len > 0;

                const take_count_raw = api.itemTakeCount(item_ptr);
                item.take_count = if (take_count_raw >= 0) @intCast(@min(take_count_raw, 255)) else 0;

                total_count += 1;
            }

            if (total_count >= buffer.len) break;
        }

        self.items = buffer[0..total_count];
    }

    /// Convenience wrapper that returns State using static buffer (for tests).
    /// WARNING: Uses static buffer - NOT thread-safe, do NOT use in production!
    pub fn pollStatic(api: anytype) State {
        const S = struct {
            var static_buffer: [MAX_ITEMS]Item = undefined;
        };
        var state = State{};
        state.pollInto(&S.static_buffer, api);
        return state;
    }

    // Check if items have changed
    pub fn itemsChanged(self: *const State, other: *const State) bool {
        if (self.items.len != other.items.len) return true;

        for (0..self.items.len) |i| {
            if (!self.items[i].eql(&other.items[i])) return true;
        }
        return false;
    }

    // Generate JSON for items event
    pub fn itemsToJson(self: *const State, buf: []u8) ?[]const u8 {
        var stream = std.io.fixedBufferStream(buf);
        var w = stream.writer();

        w.writeAll("{\"type\":\"event\",\"event\":\"items\",\"payload\":{") catch return null;
        w.writeAll("\"items\":[") catch return null;

        for (0..self.items.len) |i| {
            if (i > 0) w.writeByte(',') catch return null;
            const item = &self.items[i];

            w.writeAll("{\"guid\":\"") catch return null;
            w.writeAll(item.getGUID()) catch return null;
            // Output unified trackIdx (0 = master, 1+ = user tracks)
            w.print("\",\"trackIdx\":{d},\"itemIdx\":{d},\"position\":{d:.3},\"length\":{d:.3},", .{
                item.track_idx + 1, item.item_idx, item.position, item.length,
            }) catch return null;
            // Write nullable fields
            w.writeAll("\"color\":") catch return null;
            if (item.color) |c| {
                w.print("{d}", .{c}) catch return null;
            } else {
                w.writeAll("null") catch return null;
            }

            w.writeAll(",\"locked\":") catch return null;
            if (item.locked) |l| {
                w.writeAll(if (l) "true" else "false") catch return null;
            } else {
                w.writeAll("null") catch return null;
            }

            w.writeAll(",\"selected\":") catch return null;
            if (item.selected) |s| {
                w.writeAll(if (s) "true" else "false") catch return null;
            } else {
                w.writeAll("null") catch return null;
            }

            w.writeAll(",\"activeTakeIdx\":") catch return null;
            if (item.active_take_idx) |idx| {
                w.print("{d}", .{idx}) catch return null;
            } else {
                w.writeAll("null") catch return null;
            }

            // Sparse fields - full data fetched on-demand via item/getNotes, item/getTakes
            w.print(",\"hasNotes\":{s},\"takeCount\":{d}}}", .{
                if (item.has_notes) "true" else "false",
                item.take_count,
            }) catch return null;
        }

        w.writeAll("]}}") catch return null;
        return stream.getWritten();
    }

    // Allocator-based version - returns owned slice from allocator
    pub fn itemsToJsonAlloc(self: *const State, allocator: std.mem.Allocator) ![]const u8 {
        var buf: [32768]u8 = undefined;
        const json = self.itemsToJson(&buf) orelse return error.JsonSerializationFailed;
        return allocator.dupe(u8, json);
    }
};

// Tests
test "Take equality" {
    const test_guid = "{12345678-1234-1234-1234-123456789ABC}";

    var t1 = Take{ .is_active = true, .is_midi = false };
    t1.guid[0..test_guid.len].* = test_guid.*;
    t1.guid_len = test_guid.len;
    t1.name[0..4].* = "take".*;
    t1.name_len = 4;

    var t2 = Take{ .is_active = true, .is_midi = false };
    t2.guid[0..test_guid.len].* = test_guid.*;
    t2.guid_len = test_guid.len;
    t2.name[0..4].* = "take".*;
    t2.name_len = 4;

    try std.testing.expect(t1.eql(&t2));

    t2.is_active = false;
    try std.testing.expect(!t1.eql(&t2));

    // Reset and test isMIDI difference
    t2.is_active = true;
    t2.is_midi = true;
    try std.testing.expect(!t1.eql(&t2));
}

test "Item equality" {
    const item_guid = "{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}";

    var item1 = Item{
        .track_idx = 0,
        .item_idx = 0,
        .position = 10.0,
        .length = 5.0,
        .color = 0,
        .locked = false,
        .active_take_idx = 0,
        .has_notes = true,
        .take_count = 2,
    };
    item1.guid[0..item_guid.len].* = item_guid.*;
    item1.guid_len = item_guid.len;

    var item2 = Item{
        .track_idx = 0,
        .item_idx = 0,
        .position = 10.0,
        .length = 5.0,
        .color = 0,
        .locked = false,
        .active_take_idx = 0,
        .has_notes = true,
        .take_count = 2,
    };
    item2.guid[0..item_guid.len].* = item_guid.*;
    item2.guid_len = item_guid.len;

    try std.testing.expect(item1.eql(&item2));

    item2.position = 15.0;
    try std.testing.expect(!item1.eql(&item2));

    // Reset and test sparse field differences
    item2.position = 10.0;
    item2.has_notes = false;
    try std.testing.expect(!item1.eql(&item2));

    item2.has_notes = true;
    item2.take_count = 1;
    try std.testing.expect(!item1.eql(&item2));
}

test "State items JSON output" {
    const item_guid = "{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}";

    // Use a static buffer for testing
    var items_buffer: [1]Item = undefined;
    items_buffer[0] = .{
        .track_idx = 0,
        .item_idx = 0,
        .position = 10.0,
        .length = 5.0,
        .color = 16711680,
        .locked = false,
        .active_take_idx = 0,
        .has_notes = true,
        .take_count = 2,
    };
    items_buffer[0].guid[0..item_guid.len].* = item_guid.*;
    items_buffer[0].guid_len = item_guid.len;

    const state = State{ .items = &items_buffer };

    var buf: [2048]u8 = undefined;
    const json = state.itemsToJson(&buf).?;

    // trackIdx is unified: internal track_idx 0 becomes trackIdx 1 (0 = master, 1+ = user tracks)
    // Sparse fields: hasNotes and takeCount instead of full notes/takes arrays
    try std.testing.expectEqualStrings(
        "{\"type\":\"event\",\"event\":\"items\",\"payload\":{\"items\":[{\"guid\":\"{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}\",\"trackIdx\":1,\"itemIdx\":0,\"position\":10.000,\"length\":5.000,\"color\":16711680,\"locked\":false,\"selected\":false,\"activeTakeIdx\":0,\"hasNotes\":true,\"takeCount\":2}]}}",
        json,
    );
}

test "items changed detection" {
    const item_guid = "{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}";

    var buffer1: [1]Item = undefined;
    buffer1[0] = .{
        .track_idx = 0,
        .item_idx = 0,
        .position = 10.0,
        .length = 5.0,
        .color = 0,
        .locked = false,
        .active_take_idx = 0,
    };
    buffer1[0].guid[0..item_guid.len].* = item_guid.*;
    buffer1[0].guid_len = item_guid.len;

    var buffer2: [1]Item = undefined;
    buffer2[0] = .{
        .track_idx = 0,
        .item_idx = 0,
        .position = 10.0,
        .length = 5.0,
        .color = 0,
        .locked = false,
        .active_take_idx = 0,
    };
    buffer2[0].guid[0..item_guid.len].* = item_guid.*;
    buffer2[0].guid_len = item_guid.len;

    const state1 = State{ .items = &buffer1 };
    var state2 = State{ .items = &buffer2 };

    try std.testing.expect(!state1.itemsChanged(&state2));

    buffer2[0].locked = true;
    try std.testing.expect(state1.itemsChanged(&state2));
}

// =============================================================================
// MockBackend-based tests
// =============================================================================

const MockBackend = reaper.MockBackend;

test "poll with MockBackend returns empty state for no tracks" {
    var mock = MockBackend{
        .track_count = 0,
    };

    const state = State.pollStatic(&mock);

    try std.testing.expectEqual(@as(usize, 0), state.items.len);
}

test "poll with MockBackend returns items from tracks" {
    var mock = MockBackend{
        .track_count = 1, // 1 user track
    };
    // Set up track 0 (first user track) with one item
    // Note: getTrackByIdx(0) returns track 0, not track 1
    mock.tracks[0].item_count = 1;
    mock.tracks[0].items[0] = .{
        .position = 5.0,
        .length = 2.5,
        .color = 16711680,
        .locked = true,
        .selected = false,
        .active_take_idx = 0,
        .take_count = 2,
    };
    mock.tracks[0].items[0].setNotes("Test note");

    const state = State.pollStatic(&mock);

    try std.testing.expectEqual(@as(usize, 1), state.items.len);
    try std.testing.expect(@abs(state.items[0].position - 5.0) < 0.001);
    try std.testing.expect(@abs(state.items[0].length - 2.5) < 0.001);
    try std.testing.expectEqual(@as(?c_int, 16711680), state.items[0].color);
    try std.testing.expect(state.items[0].locked.?);
    // Sparse fields
    try std.testing.expect(state.items[0].has_notes);
    try std.testing.expectEqual(@as(u8, 2), state.items[0].take_count);
}

test "poll tracks API calls correctly" {
    var mock = MockBackend{
        .track_count = 1,
    };
    mock.tracks[0].item_count = 1;
    mock.tracks[0].items[0] = .{
        .position = 0.0,
        .length = 1.0,
        .take_count = 1,
    };

    _ = State.pollStatic(&mock);

    // Verify key API calls were made
    try std.testing.expect(mock.getCallCount(.trackCount) >= 1);
    try std.testing.expect(mock.getCallCount(.getTrackByIdx) >= 1);
    try std.testing.expect(mock.getCallCount(.trackItemCount) >= 1);
}
