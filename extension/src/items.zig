const std = @import("std");
const reaper = @import("reaper.zig");
const protocol = @import("protocol.zig");
const ApiInterface = reaper.api.ApiInterface;

// Maximum items/takes we track
pub const MAX_ITEMS = 512;
pub const MAX_TAKES_PER_ITEM = 8;
pub const MAX_NAME_LEN = 128;
pub const GUID_LEN = 38; // {XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}

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

    // Properties
    color: c_int = 0,
    locked: bool = false,
    selected: bool = false,
    active_take_idx: c_int = 0,

    // Notes (truncated to fit)
    notes: [1024]u8 = undefined,
    notes_len: usize = 0,

    // Takes
    takes: [MAX_TAKES_PER_ITEM]Take = undefined,
    take_count: usize = 0,

    pub fn getGUID(self: *const Item) []const u8 {
        return self.guid[0..self.guid_len];
    }

    pub fn getNotes(self: *const Item) []const u8 {
        return self.notes[0..self.notes_len];
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
        if (self.notes_len != other.notes_len) return false;
        if (!std.mem.eql(u8, self.getNotes(), other.getNotes())) return false;
        if (self.take_count != other.take_count) return false;

        for (0..self.take_count) |i| {
            if (!self.takes[i].eql(&other.takes[i])) return false;
        }
        return true;
    }
};

// Cached state for change detection
pub const State = struct {
    items: [MAX_ITEMS]Item = undefined,
    item_count: usize = 0,

    /// Poll current state from REAPER using abstract interface.
    /// Enables unit testing without REAPER running.
    /// Returns ALL items in the project (frontend filters by time selection as needed)
    pub fn poll(api: ApiInterface) State {
        var state = State{};

        // Enumerate all tracks
        const track_count = api.trackCount();
        var track_idx: c_int = 0;
        while (track_idx < track_count) : (track_idx += 1) {
            const track = api.getTrackByIdx(track_idx) orelse continue;

            // Enumerate items on this track
            const item_count = api.trackItemCount(track);
            var item_idx: c_int = 0;
            while (item_idx < item_count) : (item_idx += 1) {
                if (state.item_count >= MAX_ITEMS) break;

                const item_ptr = api.getItemByIdx(track, item_idx) orelse continue;

                var item = &state.items[state.item_count];

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
                item.color = api.getItemColor(item_ptr);
                item.locked = api.getItemLocked(item_ptr);
                item.selected = api.getItemSelected(item_ptr);
                item.active_take_idx = api.getItemActiveTakeIdx(item_ptr);

                // Get notes
                var notes_buf: [1024]u8 = undefined;
                const notes = api.getItemNotes(item_ptr, &notes_buf);
                const notes_copy_len = @min(notes.len, item.notes.len);
                @memcpy(item.notes[0..notes_copy_len], notes[0..notes_copy_len]);
                item.notes_len = notes_copy_len;

                // Enumerate takes
                const take_count: usize = @intCast(@max(0, api.itemTakeCount(item_ptr)));
                item.take_count = @min(take_count, MAX_TAKES_PER_ITEM);

                for (0..item.take_count) |take_idx| {
                    const take_ptr = api.getTakeByIdx(item_ptr, @intCast(take_idx)) orelse continue;
                    var take = &item.takes[take_idx];

                    // Get take GUID
                    var take_guid_buf: [64]u8 = undefined;
                    const take_guid = api.getTakeGUID(take_ptr, &take_guid_buf);
                    const take_guid_copy_len = @min(take_guid.len, take.guid.len);
                    @memcpy(take.guid[0..take_guid_copy_len], take_guid[0..take_guid_copy_len]);
                    take.guid_len = take_guid_copy_len;

                    const take_name = api.getTakeNameStr(take_ptr);
                    const name_copy_len = @min(take_name.len, take.name.len);
                    @memcpy(take.name[0..name_copy_len], take_name[0..name_copy_len]);
                    take.name_len = name_copy_len;
                    take.is_active = (take_idx == @as(usize, @intCast(item.active_take_idx)));
                    take.is_midi = api.isTakeMIDI(take_ptr);
                }

                state.item_count += 1;
            }

            if (state.item_count >= MAX_ITEMS) break;
        }

        return state;
    }

    // Check if items have changed
    pub fn itemsChanged(self: *const State, other: *const State) bool {
        if (self.item_count != other.item_count) return true;

        for (0..self.item_count) |i| {
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

        for (0..self.item_count) |i| {
            if (i > 0) w.writeByte(',') catch return null;
            const item = &self.items[i];

            w.writeAll("{\"guid\":\"") catch return null;
            w.writeAll(item.getGUID()) catch return null;
            // Output unified trackIdx (0 = master, 1+ = user tracks)
            w.print("\",\"trackIdx\":{d},\"itemIdx\":{d},\"position\":{d:.3},\"length\":{d:.3},", .{
                item.track_idx + 1, item.item_idx, item.position, item.length,
            }) catch return null;
            w.print("\"color\":{d},\"locked\":{},\"selected\":{},\"activeTakeIdx\":{d},\"notes\":\"", .{
                item.color, item.locked, item.selected, item.active_take_idx,
            }) catch return null;
            protocol.writeJsonString(w, item.getNotes()) catch return null;
            w.writeAll("\",\"takes\":[") catch return null;

            for (0..item.take_count) |t| {
                if (t > 0) w.writeByte(',') catch return null;
                const take = &item.takes[t];
                w.writeAll("{\"guid\":\"") catch return null;
                w.writeAll(take.getGUID()) catch return null;
                w.writeAll("\",\"name\":\"") catch return null;
                protocol.writeJsonString(w, take.getName()) catch return null;
                w.print("\",\"isActive\":{},\"isMIDI\":{}}}", .{ take.is_active, take.is_midi }) catch return null;
            }

            w.writeAll("]}") catch return null;
        }

        w.writeAll("]}}") catch return null;
        return stream.getWritten();
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
    const take_guid = "{11111111-2222-3333-4444-555555555555}";

    var item1 = Item{
        .track_idx = 0,
        .item_idx = 0,
        .position = 10.0,
        .length = 5.0,
        .color = 0,
        .locked = false,
        .active_take_idx = 0,
    };
    item1.guid[0..item_guid.len].* = item_guid.*;
    item1.guid_len = item_guid.len;
    item1.take_count = 1;
    item1.takes[0].guid[0..take_guid.len].* = take_guid.*;
    item1.takes[0].guid_len = take_guid.len;
    item1.takes[0].name[0..6].* = "Take 1".*;
    item1.takes[0].name_len = 6;
    item1.takes[0].is_active = true;

    var item2 = Item{
        .track_idx = 0,
        .item_idx = 0,
        .position = 10.0,
        .length = 5.0,
        .color = 0,
        .locked = false,
        .active_take_idx = 0,
    };
    item2.guid[0..item_guid.len].* = item_guid.*;
    item2.guid_len = item_guid.len;
    item2.take_count = 1;
    item2.takes[0].guid[0..take_guid.len].* = take_guid.*;
    item2.takes[0].guid_len = take_guid.len;
    item2.takes[0].name[0..6].* = "Take 1".*;
    item2.takes[0].name_len = 6;
    item2.takes[0].is_active = true;

    try std.testing.expect(item1.eql(&item2));

    item2.position = 15.0;
    try std.testing.expect(!item1.eql(&item2));
}

test "State items JSON output" {
    const item_guid = "{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}";
    const take_guid = "{11111111-2222-3333-4444-555555555555}";

    var state = State{};

    // Add test item
    state.items[0] = .{
        .track_idx = 0,
        .item_idx = 0,
        .position = 10.0,
        .length = 5.0,
        .color = 16711680,
        .locked = false,
        .active_take_idx = 0,
    };
    state.items[0].guid[0..item_guid.len].* = item_guid.*;
    state.items[0].guid_len = item_guid.len;
    state.items[0].take_count = 1;
    state.items[0].takes[0].guid[0..take_guid.len].* = take_guid.*;
    state.items[0].takes[0].guid_len = take_guid.len;
    state.items[0].takes[0].name[0..4].* = "Main".*;
    state.items[0].takes[0].name_len = 4;
    state.items[0].takes[0].is_active = true;
    state.items[0].takes[0].is_midi = false;
    state.item_count = 1;

    var buf: [2048]u8 = undefined;
    const json = state.itemsToJson(&buf).?;

    // trackIdx is unified: internal track_idx 0 becomes trackIdx 1 (0 = master, 1+ = user tracks)
    try std.testing.expectEqualStrings(
        "{\"type\":\"event\",\"event\":\"items\",\"payload\":{\"items\":[{\"guid\":\"{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}\",\"trackIdx\":1,\"itemIdx\":0,\"position\":10.000,\"length\":5.000,\"color\":16711680,\"locked\":false,\"selected\":false,\"activeTakeIdx\":0,\"notes\":\"\",\"takes\":[{\"guid\":\"{11111111-2222-3333-4444-555555555555}\",\"name\":\"Main\",\"isActive\":true,\"isMIDI\":false}]}]}}",
        json,
    );
}

test "items changed detection" {
    const item_guid = "{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}";

    var state1 = State{};
    state1.items[0] = .{
        .track_idx = 0,
        .item_idx = 0,
        .position = 10.0,
        .length = 5.0,
        .color = 0,
        .locked = false,
        .active_take_idx = 0,
    };
    state1.items[0].guid[0..item_guid.len].* = item_guid.*;
    state1.items[0].guid_len = item_guid.len;
    state1.item_count = 1;

    var state2 = State{};
    state2.items[0] = .{
        .track_idx = 0,
        .item_idx = 0,
        .position = 10.0,
        .length = 5.0,
        .color = 0,
        .locked = false,
        .active_take_idx = 0,
    };
    state2.items[0].guid[0..item_guid.len].* = item_guid.*;
    state2.items[0].guid_len = item_guid.len;
    state2.item_count = 1;

    try std.testing.expect(!state1.itemsChanged(&state2));

    state2.items[0].locked = true;
    try std.testing.expect(state1.itemsChanged(&state2));
}

// =============================================================================
// MockApi-based tests (Phase 8.4)
// =============================================================================

const MockApi = reaper.mock.MockApi;

test "poll with MockApi returns empty state for no tracks" {
    var mock = MockApi{
        .track_count = 0,
    };

    const state = State.poll(mock.interface());

    try std.testing.expectEqual(@as(usize, 0), state.item_count);
}

test "poll with MockApi returns items from tracks" {
    var mock = MockApi{
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
        .take_count = 1,
    };
    mock.tracks[0].items[0].setNotes("Test note");
    mock.tracks[0].items[0].takes[0].setName("Audio Take");
    mock.tracks[0].items[0].takes[0].is_midi = false;

    const state = State.poll(mock.interface());

    try std.testing.expectEqual(@as(usize, 1), state.item_count);
    try std.testing.expect(@abs(state.items[0].position - 5.0) < 0.001);
    try std.testing.expect(@abs(state.items[0].length - 2.5) < 0.001);
    try std.testing.expectEqual(@as(c_int, 16711680), state.items[0].color);
    try std.testing.expect(state.items[0].locked);
    try std.testing.expectEqual(@as(usize, 1), state.items[0].take_count);
    try std.testing.expectEqualStrings("Audio Take", state.items[0].takes[0].getName());
}

test "poll tracks API calls correctly" {
    var mock = MockApi{
        .track_count = 1,
    };
    mock.tracks[0].item_count = 1;
    mock.tracks[0].items[0] = .{
        .position = 0.0,
        .length = 1.0,
        .take_count = 1,
    };

    _ = State.poll(mock.interface());

    // Verify key API calls were made
    try std.testing.expect(mock.getCallCount(.trackCount) >= 1);
    try std.testing.expect(mock.getCallCount(.getTrackByIdx) >= 1);
    try std.testing.expect(mock.getCallCount(.trackItemCount) >= 1);
}
