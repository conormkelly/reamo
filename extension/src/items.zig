const std = @import("std");
const reaper = @import("reaper.zig");

// Maximum items/takes we track
pub const MAX_ITEMS = 512;
pub const MAX_TAKES_PER_ITEM = 8;
pub const MAX_NAME_LEN = 64;

// Take data
pub const Take = struct {
    name: [MAX_NAME_LEN]u8 = undefined,
    name_len: usize = 0,
    is_active: bool = false,

    pub fn getName(self: *const Take) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn eql(self: *const Take, other: *const Take) bool {
        if (self.is_active != other.is_active) return false;
        if (self.name_len != other.name_len) return false;
        return std.mem.eql(u8, self.getName(), other.getName());
    }
};

// Item data - matches frontend types.ts Item interface
pub const Item = struct {
    // Identity
    track_idx: c_int = 0,
    item_idx: c_int = 0, // index within track

    // Position and length
    position: f64 = 0,
    length: f64 = 0,

    // Properties
    color: c_int = 0,
    locked: bool = false,
    active_take_idx: c_int = 0,

    // Notes (truncated to fit)
    notes: [256]u8 = undefined,
    notes_len: usize = 0,

    // Takes
    takes: [MAX_TAKES_PER_ITEM]Take = undefined,
    take_count: usize = 0,

    pub fn getNotes(self: *const Item) []const u8 {
        return self.notes[0..self.notes_len];
    }

    pub fn eql(self: *const Item, other: *const Item) bool {
        if (self.track_idx != other.track_idx) return false;
        if (self.item_idx != other.item_idx) return false;
        if (@abs(self.position - other.position) > 0.001) return false;
        if (@abs(self.length - other.length) > 0.001) return false;
        if (self.color != other.color) return false;
        if (self.locked != other.locked) return false;
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

    // Time selection bounds (for filtering)
    time_sel_start: f64 = 0,
    time_sel_end: f64 = 0,

    // Poll current state from REAPER
    // Only returns items that overlap with time selection (if any)
    pub fn poll(api: *const reaper.Api) State {
        var state = State{};

        // Get time selection
        const ts = api.timeSelection();
        state.time_sel_start = ts.start;
        state.time_sel_end = ts.end;
        const has_time_sel = ts.end > ts.start;

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

                const pos = api.getItemPosition(item_ptr);
                const len = api.getItemLength(item_ptr);
                const item_end = pos + len;

                // Filter by time selection if present
                if (has_time_sel) {
                    // Skip items that don't overlap time selection
                    if (item_end < ts.start or pos > ts.end) continue;
                }

                var item = &state.items[state.item_count];
                item.track_idx = track_idx;
                item.item_idx = item_idx;
                item.position = pos;
                item.length = len;
                item.color = api.getItemColor(item_ptr);
                item.locked = api.getItemLocked(item_ptr);
                item.active_take_idx = api.getItemActiveTakeIdx(item_ptr);

                // Get notes
                var notes_buf: [256]u8 = undefined;
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

                    const take_name = api.getTakeNameStr(take_ptr);
                    const name_copy_len = @min(take_name.len, take.name.len);
                    @memcpy(take.name[0..name_copy_len], take_name[0..name_copy_len]);
                    take.name_len = name_copy_len;
                    take.is_active = (take_idx == @as(usize, @intCast(item.active_take_idx)));
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
        w.print("\"timeSelection\":{{\"start\":{d:.3},\"end\":{d:.3}}},", .{ self.time_sel_start, self.time_sel_end }) catch return null;
        w.writeAll("\"items\":[") catch return null;

        for (0..self.item_count) |i| {
            if (i > 0) w.writeByte(',') catch return null;
            const item = &self.items[i];

            w.print("{{\"trackIdx\":{d},\"itemIdx\":{d},\"position\":{d:.3},\"length\":{d:.3},", .{
                item.track_idx, item.item_idx, item.position, item.length
            }) catch return null;
            w.print("\"color\":{d},\"locked\":{},\"activeTakeIdx\":{d},\"notes\":\"", .{
                item.color, item.locked, item.active_take_idx
            }) catch return null;
            writeJsonString(w, item.getNotes()) catch return null;
            w.writeAll("\",\"takes\":[") catch return null;

            for (0..item.take_count) |t| {
                if (t > 0) w.writeByte(',') catch return null;
                const take = &item.takes[t];
                w.writeAll("{\"name\":\"") catch return null;
                writeJsonString(w, take.getName()) catch return null;
                w.print("\",\"isActive\":{}}}", .{take.is_active}) catch return null;
            }

            w.writeAll("]}") catch return null;
        }

        w.writeAll("]}}") catch return null;
        return stream.getWritten();
    }
};

// Helper to escape JSON strings
fn writeJsonString(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
}

// Tests
test "Take equality" {
    var t1 = Take{ .is_active = true };
    t1.name[0..4].* = "take".*;
    t1.name_len = 4;

    var t2 = Take{ .is_active = true };
    t2.name[0..4].* = "take".*;
    t2.name_len = 4;

    try std.testing.expect(t1.eql(&t2));

    t2.is_active = false;
    try std.testing.expect(!t1.eql(&t2));
}

test "Item equality" {
    var item1 = Item{
        .track_idx = 0,
        .item_idx = 0,
        .position = 10.0,
        .length = 5.0,
        .color = 0,
        .locked = false,
        .active_take_idx = 0,
    };
    item1.take_count = 1;
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
    item2.take_count = 1;
    item2.takes[0].name[0..6].* = "Take 1".*;
    item2.takes[0].name_len = 6;
    item2.takes[0].is_active = true;

    try std.testing.expect(item1.eql(&item2));

    item2.position = 15.0;
    try std.testing.expect(!item1.eql(&item2));
}

test "State items JSON output" {
    var state = State{};
    state.time_sel_start = 5.0;
    state.time_sel_end = 20.0;

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
    state.items[0].take_count = 1;
    state.items[0].takes[0].name[0..4].* = "Main".*;
    state.items[0].takes[0].name_len = 4;
    state.items[0].takes[0].is_active = true;
    state.item_count = 1;

    var buf: [2048]u8 = undefined;
    const json = state.itemsToJson(&buf).?;

    try std.testing.expectEqualStrings(
        "{\"type\":\"event\",\"event\":\"items\",\"payload\":{\"timeSelection\":{\"start\":5.000,\"end\":20.000},\"items\":[{\"trackIdx\":0,\"itemIdx\":0,\"position\":10.000,\"length\":5.000,\"color\":16711680,\"locked\":false,\"activeTakeIdx\":0,\"notes\":\"\",\"takes\":[{\"name\":\"Main\",\"isActive\":true}]}]}}",
        json,
    );
}

test "items changed detection" {
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
    state2.item_count = 1;

    try std.testing.expect(!state1.itemsChanged(&state2));

    state2.items[0].locked = true;
    try std.testing.expect(state1.itemsChanged(&state2));
}
