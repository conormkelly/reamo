const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../core/protocol.zig");
const mod = @import("mod.zig");
const logging = @import("../core/logging.zig");
const item_guid_cache = @import("../state/item_guid_cache.zig");

/// Helper to get item by track and item index from command
/// Uses unified indexing: 0 = master, 1+ = user tracks
const ItemLocation = struct { track: *anyopaque, item: *anyopaque };

/// The item a command names: by `itemGuid` when given, which stays on the
/// same item however REAPER re-sorts the track, else by `trackIdx` and
/// `itemIdx`. A GUID that no longer resolves finds nothing; the item now at
/// the old index is someone else's.
fn getItemFromCmd(api: anytype, cmd: protocol.CommandMessage) ?ItemLocation {
    if (cmd.getString("itemGuid")) |guid| return findItemLocation(api, mod.g_ctx.item_cache, guid);

    const track_idx = cmd.getInt("trackIdx") orelse return null;
    const item_idx = cmd.getInt("itemIdx") orelse return null;

    const track = api.getTrackByUnifiedIdx(track_idx) orelse return null;
    const item = api.getItemByIdx(track, item_idx) orelse return null;

    return .{ .track = track, .item = item };
}

pub fn handleItemSetActiveTake(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const item_info = getItemFromCmd(api, cmd) orelse {
        response.err("NOT_FOUND", "Item not found");
        return;
    };
    if (!refuseIfLocked(api, item_info.item, response)) return;
    const take_idx = cmd.getInt("takeIdx") orelse {
        response.err("MISSING_TAKE_IDX", "Take index is required");
        return;
    };

    // Bounds check: verify take index is valid
    const num_takes = api.itemTakeCount(item_info.item);
    if (take_idx < 0 or take_idx >= num_takes) {
        logging.warn("Invalid take index {d} (item has {d} takes)", .{ take_idx, num_takes });
        response.err("INVALID_TAKE_INDEX", "Take index out of range");
        return;
    }

    api.undoBeginBlock();
    if (api.setItemActiveTake(item_info.item, take_idx)) {
        logging.debug("Set active take to {d}", .{take_idx});
    }
    api.undoEndBlock("REAmo: Set active take");
    api.updateTimeline();
}

/// REAPER doesn't move, delete or switch the take of a locked item (its
/// nudge, drag, remove, cut, split and take actions all leave it alone), and
/// neither does a phone. Refuses the command when `item` is locked or its
/// lock can't be read; returns whether the edit may go ahead.
fn refuseIfLocked(api: anytype, item: *anyopaque, response: *mod.ResponseWriter) bool {
    const locked = api.getItemLocked(item) catch {
        response.err("READ_FAILED", "Could not read the item's lock");
        return false;
    };
    if (locked) {
        response.err("ITEM_LOCKED", "Item is locked");
        return false;
    }
    return true;
}

pub fn handleItemMove(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const item_info = getItemFromCmd(api, cmd) orelse {
        response.err("NOT_FOUND", "Item not found");
        return;
    };
    const position = mod.validatePosition(cmd.getFloat("position")) orelse {
        response.err("INVALID_POSITION", "Position must be a non-negative number");
        return;
    };
    if (!refuseIfLocked(api, item_info.item, response)) return;

    api.undoBeginBlock();
    if (api.setItemPosition(item_info.item, position)) {
        logging.debug("Moved item to {d:.2}", .{position});
    }
    api.undoEndBlock("REAmo: Move item");
    api.updateTimeline();
}

/// Move item by GUID — stable across reordering.
/// Params: { guid: string, position?: number, destTrackGuid?: string }
/// At least one of position or destTrackGuid must be provided.
pub fn handleItemMoveByGuid(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const guid = cmd.getString("guid") orelse {
        response.err("MISSING_GUID", "Item GUID is required");
        return;
    };

    // Validate: at least one action. Everything is resolved before the undo
    // block opens, so a refused move changes nothing.
    const raw_position = cmd.getFloat("position");
    const position = mod.validatePosition(raw_position);
    if (raw_position != null and position == null) {
        response.err("INVALID_POSITION", "Position must be a non-negative number");
        return;
    }
    const dest_track_guid = cmd.getString("destTrackGuid");
    if (position == null and dest_track_guid == null) {
        response.err("MISSING_PARAMS", "At least one of position or destTrackGuid required");
        return;
    }

    const item = findItemByGuid(api, mod.g_ctx.item_cache, guid) orelse {
        response.err("NOT_FOUND", "Item not found (may have been deleted)");
        return;
    };
    if (!refuseIfLocked(api, item, response)) return;

    var dest_track: ?*anyopaque = null;
    if (dest_track_guid) |dest_guid| {
        const guid_cache = mod.g_ctx.guid_cache orelse {
            response.err("NOT_INITIALIZED", "GUID cache not initialized");
            return;
        };
        dest_track = guid_cache.resolve(api, dest_guid) orelse {
            response.err("NOT_FOUND", "Destination track not found");
            return;
        };
        // REAPER holds no items on the master track
        if (dest_track == api.masterTrack()) {
            response.err("INVALID_PARAM", "Items can't go on the master track");
            return;
        }
    }

    // The track move goes first: if REAPER refuses it, nothing has changed.
    api.undoBeginBlock();
    if (dest_track) |dest| {
        if (!api.moveItemToTrack(item, dest)) {
            api.undoEndBlock("REAmo: Move item");
            response.err("MOVE_FAILED", "REAPER didn't move the item to that track");
            return;
        }
    }
    if (position) |pos| {
        if (api.setItemPosition(item, pos)) {
            logging.debug("Moved item to {d:.2}", .{pos});
        }
    }
    api.undoEndBlock("REAmo: Move item");
    api.updateTimeline();
    response.success(null);
}

pub fn handleItemColor(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const item_info = getItemFromCmd(api, cmd) orelse {
        response.err("NOT_FOUND", "Item not found");
        return;
    };
    const color = cmd.getInt("color") orelse {
        response.err("MISSING_COLOR", "Color is required");
        return;
    };

    api.undoBeginBlock();
    if (api.setItemColor(item_info.item, color)) {
        logging.debug("Set item color to {d}", .{color});
    }
    api.undoEndBlock("REAmo: Set item color");
    api.updateTimeline();
}

pub fn handleItemLock(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const item_info = getItemFromCmd(api, cmd) orelse {
        response.err("NOT_FOUND", "Item not found");
        return;
    };

    // Toggle lock state if no explicit value provided
    const locked = cmd.getFlag("locked") orelse blk: {
        const current = api.getItemLocked(item_info.item) catch {
            response.err("CORRUPT_DATA", "Cannot read item lock state");
            return;
        };
        break :blk !current;
    };

    api.undoBeginBlock();
    if (api.setItemLocked(item_info.item, locked)) {
        logging.debug("Set item locked to {}", .{locked});
    }
    api.undoEndBlock("REAmo: Lock item");
    api.updateTimeline();
}

pub fn handleItemNotes(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const item_info = getItemFromCmd(api, cmd) orelse {
        response.err("NOT_FOUND", "Item not found");
        return;
    };
    // Unescaped text (real newlines, quotes), NUL-terminated for REAPER. The
    // raw JSON value is never shorter than its unescaped form.
    const raw = cmd.getString("notes") orelse "";
    const scratch = (mod.g_ctx.tiered orelse {
        response.err("NOT_INITIALIZED", "Tiered arenas not initialized");
        return;
    }).scratchAllocator();
    const notes_buf = scratch.alloc(u8, raw.len + 1) catch {
        response.err("ALLOC_FAILED", "Failed to allocate notes buffer");
        return;
    };
    const notes = cmd.getStringUnescaped("notes", notes_buf[0..raw.len]) orelse "";
    notes_buf[notes.len] = 0;

    api.undoBeginBlock();
    const ok = api.setItemNotes(item_info.item, notes_buf[0..notes.len :0]);
    api.undoEndBlock("REAmo: Set item notes");
    // Notes don't need visual refresh (not displayed in arrange view)
    if (!ok) {
        response.err("SET_FAILED", "Failed to set item notes");
        return;
    }
    response.success(null);
}

pub fn handleItemDelete(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const item_info = getItemFromCmd(api, cmd) orelse {
        response.err("NOT_FOUND", "Item not found");
        return;
    };
    if (!refuseIfLocked(api, item_info.item, response)) return;

    api.undoBeginBlock();
    if (api.deleteItem(item_info.track, item_info.item)) {
        logging.debug("Deleted item", .{});
    }
    api.undoEndBlock("REAmo: Delete item");
    api.updateTimeline();
}

pub fn handleItemGoto(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const item_info = getItemFromCmd(api, cmd) orelse {
        response.err("NOT_FOUND", "Item not found");
        return;
    };
    const position = api.getItemPosition(item_info.item);
    api.setCursorPos(position);
}

/// Select a single item (deselects all others first)
pub fn handleItemSelect(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const item_info = getItemFromCmd(api, cmd) orelse {
        response.err("NOT_FOUND", "Item not found");
        return;
    };

    selectOnly(api, item_info.item);
    logging.debug("Selected item", .{});
}

const ITEM_SELECTION_UNDO = "REAmo: Change item selection";

/// Make `item` the only selected item, as one undo step. REAPER keeps a step
/// that only changes item selection when the user's undo settings include
/// item selection, as for a click on an item, and drops it otherwise.
fn selectOnly(api: anytype, item: *anyopaque) void {
    api.undoBeginBlock();
    api.runCommand(reaper.Command.UNSELECT_ALL_ITEMS);
    _ = api.setItemSelected(item, true);
    api.undoEndBlock(ITEM_SELECTION_UNDO);
}

/// Select all items within time selection (on selected tracks)
pub fn handleSelectInTimeSel(api: anytype, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.SELECT_ALL_ITEMS_IN_TIME_SEL);
    logging.debug("Selected items in time selection", .{});
}

/// Deselect all items
pub fn handleUnselectAll(api: anytype, _: protocol.CommandMessage, _: *mod.ResponseWriter) void {
    api.runCommand(reaper.Command.UNSELECT_ALL_ITEMS);
    logging.debug("Unselected all items", .{});
}

/// Toggle selection of a single item (does NOT affect other items' selection)
/// Uses GUID for stable item identification across reordering.
/// Params: { guid: string }
pub fn handleItemToggleSelect(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const guid = cmd.getString("guid") orelse {
        response.err("MISSING_GUID", "Item GUID is required");
        return;
    };

    const item = findItemByGuid(api, mod.g_ctx.item_cache, guid) orelse {
        response.err("NOT_FOUND", "Item not found (may have been deleted)");
        return;
    };

    // Read current selection state and toggle
    const current_selected = api.getItemSelected(item) catch {
        response.err("CORRUPT_DATA", "Cannot read item selection state");
        return;
    };

    const new_selected = !current_selected;

    // One undo step, kept only if the user's undo settings include item
    // selection (see selectOnly).
    api.undoBeginBlock();
    if (api.setItemSelected(item, new_selected)) {
        logging.debug("Toggled item selection: {s} -> {}", .{ guid, new_selected });
    }
    api.undoEndBlock(ITEM_SELECTION_UNDO);

    // Response confirms success
    response.success(null);
}

// Maximum items to consider for navigation (stack limit)
const MAX_NAV_ITEMS = 1024;

/// Select next item on same track (by position order)
/// Params: trackIdx, itemIdx, wrap (optional, default false)
/// Returns: { trackIdx, itemIdx } of newly selected item
pub fn handleItemSelectNext(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track_idx = cmd.getInt("trackIdx") orelse {
        response.err("MISSING_TRACK_IDX", "Track index required");
        return;
    };
    const item_idx = cmd.getInt("itemIdx") orelse {
        response.err("MISSING_ITEM_IDX", "Item index required");
        return;
    };
    const wrap = cmd.getFlag("wrap") orelse false;

    const track = api.getTrackByUnifiedIdx(track_idx) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };

    // Get current item position
    const current_item = api.getItemByIdx(track, item_idx) orelse {
        response.err("NOT_FOUND", "Current item not found");
        return;
    };
    const current_pos = api.getItemPosition(current_item);

    // Get item count
    const item_count_raw = api.trackItemCount(track);
    if (item_count_raw <= 1) {
        response.err("NO_NEXT", "No next item (only one item on track)");
        return;
    }
    const item_count: usize = @min(@as(usize, @intCast(item_count_raw)), MAX_NAV_ITEMS);

    // Find next item: smallest position > current
    var next_idx: ?c_int = null;
    var next_pos: f64 = std.math.inf(f64);
    var first_idx: c_int = 0;
    var first_pos: f64 = std.math.inf(f64);

    for (0..item_count) |i| {
        const idx: c_int = @intCast(i);
        const item = api.getItemByIdx(track, idx) orelse continue;
        const pos = api.getItemPosition(item);

        // Track first item (for wrap-around)
        if (pos < first_pos) {
            first_pos = pos;
            first_idx = idx;
        }

        // Track next item (smallest position > current)
        if (pos > current_pos and pos < next_pos) {
            next_pos = pos;
            next_idx = idx;
        }
    }

    const target_idx = if (next_idx) |idx| idx else if (wrap) first_idx else {
        response.err("NO_NEXT", "Already at last item");
        return;
    };

    const target_item = api.getItemByIdx(track, target_idx) orelse {
        response.err("NOT_FOUND", "Target item not found");
        return;
    };
    selectOnly(api, target_item);

    // Return new selection
    var buf: [128]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"trackIdx\":{d},\"itemIdx\":{d}}}", .{ track_idx, target_idx }) catch {
        response.err("SERIALIZE_ERROR", "Buffer overflow");
        return;
    };
    response.success(json);
    logging.debug("Selected next item: {d}", .{target_idx});
}

/// Select previous item on same track (by position order)
/// Params: trackIdx, itemIdx, wrap (optional, default false)
/// Returns: { trackIdx, itemIdx } of newly selected item
pub fn handleItemSelectPrev(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const track_idx = cmd.getInt("trackIdx") orelse {
        response.err("MISSING_TRACK_IDX", "Track index required");
        return;
    };
    const item_idx = cmd.getInt("itemIdx") orelse {
        response.err("MISSING_ITEM_IDX", "Item index required");
        return;
    };
    const wrap = cmd.getFlag("wrap") orelse false;

    const track = api.getTrackByUnifiedIdx(track_idx) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };

    // Get current item position
    const current_item = api.getItemByIdx(track, item_idx) orelse {
        response.err("NOT_FOUND", "Current item not found");
        return;
    };
    const current_pos = api.getItemPosition(current_item);

    // Get item count
    const item_count_raw = api.trackItemCount(track);
    if (item_count_raw <= 1) {
        response.err("NO_PREV", "No previous item (only one item on track)");
        return;
    }
    const item_count: usize = @min(@as(usize, @intCast(item_count_raw)), MAX_NAV_ITEMS);

    // Find previous item: largest position < current
    var prev_idx: ?c_int = null;
    var prev_pos: f64 = -std.math.inf(f64);
    var last_idx: c_int = 0;
    var last_pos: f64 = -std.math.inf(f64);

    for (0..item_count) |i| {
        const idx: c_int = @intCast(i);
        const item = api.getItemByIdx(track, idx) orelse continue;
        const pos = api.getItemPosition(item);

        // Track last item (for wrap-around)
        if (pos > last_pos) {
            last_pos = pos;
            last_idx = idx;
        }

        // Track previous item (largest position < current)
        if (pos < current_pos and pos > prev_pos) {
            prev_pos = pos;
            prev_idx = idx;
        }
    }

    const target_idx = if (prev_idx) |idx| idx else if (wrap) last_idx else {
        response.err("NO_PREV", "Already at first item");
        return;
    };

    const target_item = api.getItemByIdx(track, target_idx) orelse {
        response.err("NOT_FOUND", "Target item not found");
        return;
    };
    selectOnly(api, target_item);

    // Return new selection
    var buf: [128]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"trackIdx\":{d},\"itemIdx\":{d}}}", .{ track_idx, target_idx }) catch {
        response.err("SERIALIZE_ERROR", "Buffer overflow");
        return;
    };
    response.success(json);
    logging.debug("Selected previous item: {d}", .{target_idx});
}

// =============================================================================
// On-Demand Data Commands
// =============================================================================
// These commands fetch full detail data that is NOT included in the regular
// item polling events (which only contain sparse hints like has_notes, take_count).
// Frontend calls these when user opens item notes or take details.

// GUID buffer size
const GUID_BUF_SIZE = 64;

/// Get notes content for a single item.
/// Input: { trackIdx: number, itemIdx: number }
/// Response: { notes: string }
pub fn handleItemGetNotes(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const item_info = getItemFromCmd(api, cmd) orelse {
        response.err("NOT_FOUND", "Item not found");
        return;
    };
    const scratch = (mod.g_ctx.tiered orelse {
        response.err("NOT_INITIALIZED", "Tiered arenas not initialized");
        return;
    }).scratchAllocator();

    // REAPER's own string, any length; serialized before anything can change it.
    const notes = NotesPayload{ .notes = api.itemNotes(item_info.item) };
    const payload = protocol.serializeAlloc(scratch, notes.notes.len + 32, &notes, NotesPayload.toJson) catch {
        response.err("NOTES_TOO_LARGE", "Item notes exceed the response buffer");
        return;
    };
    response.success(payload);
    logging.debug("Returned notes for item", .{});
}

const NotesPayload = struct {
    notes: []const u8,

    fn toJson(self: *const NotesPayload, buf: []u8) ?[]const u8 {
        var stream = std.io.fixedBufferStream(buf);
        var w = stream.writer();
        w.writeAll("{\"notes\":\"") catch return null;
        protocol.writeJsonString(w, self.notes) catch return null;
        w.writeAll("\"}") catch return null;
        return stream.getWritten();
    }
};

/// Get full take list for a single item.
/// Input: { trackIdx: number, itemIdx: number }
/// Response: { takes: [{ takeIdx, guid, name, isActive, isMidi, startOffset, playrate }, ...] }
pub fn handleItemGetTakes(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const item_info = getItemFromCmd(api, cmd) orelse {
        response.err("NOT_FOUND", "Item not found");
        return;
    };

    const take_count_raw = api.itemTakeCount(item_info.item);
    const take_count: usize = if (take_count_raw > 0) @intCast(@min(take_count_raw, 64)) else 0;

    // Get active take index for comparison
    const active_take_idx = api.getItemActiveTakeIdx(item_info.item) catch null;

    // Serialize to scratch arena buffer (16KB — too large for stack per §1)
    const tiered = mod.g_ctx.tiered orelse {
        response.err("NOT_INITIALIZED", "Tiered arenas not initialized");
        return;
    };
    const scratch = tiered.scratchAllocator();
    const buf = scratch.alloc(u8, 16384) catch {
        response.err("ALLOC_FAILED", "Failed to allocate buffer");
        return;
    };
    var stream = std.io.fixedBufferStream(buf);
    var w = stream.writer();

    w.writeAll("{\"takes\":[") catch {
        response.err("SERIALIZE_ERROR", "Buffer overflow");
        return;
    };

    var i: usize = 0;
    while (i < take_count) : (i += 1) {
        const take_idx: c_int = @intCast(i);
        const take = api.getTakeByIdx(item_info.item, take_idx) orelse continue;

        // Get take properties
        const name = api.getTakeNameStr(take);

        var guid_buf: [GUID_BUF_SIZE]u8 = undefined;
        const guid = api.getTakeGUID(take, &guid_buf);

        const is_midi = api.isTakeMIDI(take);
        const start_offset = api.getTakeStartOffset(take);
        const playrate = api.getTakePlayrate(take);

        const is_active = if (active_take_idx) |active_idx| (take_idx == active_idx) else false;

        // Write JSON object
        if (i > 0) w.writeByte(',') catch {
            response.err("SERIALIZE_ERROR", "Buffer overflow");
            return;
        };

        w.print("{{\"takeIdx\":{d},\"guid\":\"", .{take_idx}) catch {
            response.err("SERIALIZE_ERROR", "Buffer overflow");
            return;
        };
        w.writeAll(guid) catch {
            response.err("SERIALIZE_ERROR", "Buffer overflow");
            return;
        };
        w.writeAll("\",\"name\":\"") catch {
            response.err("SERIALIZE_ERROR", "Buffer overflow");
            return;
        };
        protocol.writeJsonString(w, name) catch {
            response.err("SERIALIZE_ERROR", "Buffer overflow");
            return;
        };
        w.print("\",\"isActive\":{s},\"isMidi\":{s},\"startOffset\":{d:.6},\"playrate\":{d:.6}}}", .{
            if (is_active) "true" else "false",
            if (is_midi) "true" else "false",
            start_offset,
            playrate,
        }) catch {
            response.err("SERIALIZE_ERROR", "Buffer overflow");
            return;
        };
    }

    w.writeAll("]}") catch {
        response.err("SERIALIZE_ERROR", "Buffer overflow");
        return;
    };

    response.success(stream.getWritten());
    logging.debug("Returned {d} takes for item", .{take_count});
}

/// The item with this GUID, wherever it is now. The cache is rebuilt by the
/// 5 Hz item poll, but REAPER re-sorts a track's items as soon as one moves,
/// so between polls a cached index can name a different item: the cached
/// location is a hint, used only once the item there has this GUID. On a
/// miss the cached track, then the whole project, is searched (that also
/// finds items past the poll's item cap, which the cache never holds).
pub fn findItemByGuid(api: anytype, cache: ?*const item_guid_cache.ItemGuidCache, guid: []const u8) ?*anyopaque {
    const loc = findItemLocation(api, cache, guid) orelse return null;
    return loc.item;
}

/// findItemByGuid, with the track the item is on.
fn findItemLocation(api: anytype, cache: ?*const item_guid_cache.ItemGuidCache, guid: []const u8) ?ItemLocation {
    var hinted_track: ?*anyopaque = null;
    if (cache) |c| {
        if (c.resolve(guid)) |loc| {
            if (api.getTrackByUnifiedIdx(loc.track_idx)) |track| {
                hinted_track = track;
                if (api.getItemByIdx(track, loc.item_idx)) |item| {
                    if (itemHasGuid(api, item, guid)) return .{ .track = track, .item = item };
                }
                if (findItemOnTrack(api, track, guid)) |item| return .{ .track = track, .item = item };
            }
        }
    }
    var t: c_int = 1;
    while (t <= api.trackCount()) : (t += 1) {
        const track = api.getTrackByUnifiedIdx(t) orelse continue;
        if (track == hinted_track) continue;
        if (findItemOnTrack(api, track, guid)) |item| return .{ .track = track, .item = item };
    }
    return null;
}

fn findItemOnTrack(api: anytype, track: *anyopaque, guid: []const u8) ?*anyopaque {
    var i: c_int = 0;
    while (i < api.trackItemCount(track)) : (i += 1) {
        const item = api.getItemByIdx(track, i) orelse continue;
        if (itemHasGuid(api, item, guid)) return item;
    }
    return null;
}

fn itemHasGuid(api: anytype, item: *anyopaque, guid: []const u8) bool {
    var buf: [64]u8 = undefined;
    return std.ascii.eqlIgnoreCase(api.getItemGUID(item, &buf), guid);
}

fn setMockItem(m: anytype, track: usize, idx: usize, guid: []const u8) void {
    const it = &m.tracks[track].items[idx];
    @memcpy(it.guid[0..guid.len], guid);
    it.guid_len = guid.len;
}

const GUID_A = "{AAAAAAAA-0000-0000-0000-000000000000}";
const GUID_B = "{BBBBBBBB-0000-0000-0000-000000000000}";
const GUID_C = "{CCCCCCCC-0000-0000-0000-000000000000}";

test "findItemByGuid finds the item REAPER re-sorted after the last poll, not its neighbour" {
    const mock = @import("../reaper/mock/mod.zig");
    var m = mock.MockBackend{ .track_count = 1 };
    m.tracks[1].item_count = 2;
    // The poll saw A at index 0; then A moved past B and REAPER re-sorted.
    setMockItem(&m, 1, 0, GUID_B);
    setMockItem(&m, 1, 1, GUID_A);
    var cache = item_guid_cache.ItemGuidCache.init(std.testing.allocator);
    defer cache.deinit();
    try cache.put(GUID_A, .{ .track_idx = 1, .item_idx = 0 });
    try cache.put(GUID_B, .{ .track_idx = 1, .item_idx = 1 });

    try std.testing.expectEqual(m.getItemByIdx(m.getTrackByUnifiedIdx(1).?, 1), findItemByGuid(&m, &cache, GUID_A));
    try std.testing.expectEqual(m.getItemByIdx(m.getTrackByUnifiedIdx(1).?, 0), findItemByGuid(&m, &cache, GUID_B));
}

test "findItemByGuid finds items the cache does not hold, and nothing for a deleted item" {
    const mock = @import("../reaper/mock/mod.zig");
    var m = mock.MockBackend{ .track_count = 2 };
    m.tracks[2].item_count = 1;
    setMockItem(&m, 2, 0, GUID_C);
    var cache = item_guid_cache.ItemGuidCache.init(std.testing.allocator);
    defer cache.deinit();

    try std.testing.expectEqual(m.getItemByIdx(m.getTrackByUnifiedIdx(2).?, 0), findItemByGuid(&m, &cache, GUID_C));
    try std.testing.expectEqual(m.getItemByIdx(m.getTrackByUnifiedIdx(2).?, 0), findItemByGuid(&m, null, "{cccccccc-0000-0000-0000-000000000000}"));
    try std.testing.expectEqual(@as(?*anyopaque, null), findItemByGuid(&m, &cache, GUID_A));
}

test "an item command naming itemGuid acts on that item after REAPER re-sorts the track" {
    const mock = @import("../reaper/mock/mod.zig");
    var m = mock.MockBackend{ .track_count = 2 };
    m.tracks[2].item_count = 2;
    // The phone saw A at index 0; another item moved before it since.
    setMockItem(&m, 2, 0, GUID_B);
    setMockItem(&m, 2, 1, GUID_A);
    const cmd = protocol.CommandMessage.parse(
        \\{"type":"command","command":"item/setNotes","itemGuid":"{AAAAAAAA-0000-0000-0000-000000000000}","trackIdx":2,"itemIdx":0}
    ).?;
    const found = getItemFromCmd(&m, cmd).?;
    try std.testing.expectEqual(m.getTrackByUnifiedIdx(2).?, found.track);
    try std.testing.expectEqual(m.getItemByIdx(m.getTrackByUnifiedIdx(2).?, 1).?, found.item);
}

test "an item command naming a deleted itemGuid finds nothing, not the item at its old index" {
    const mock = @import("../reaper/mock/mod.zig");
    var m = mock.MockBackend{ .track_count = 1 };
    m.tracks[1].item_count = 1;
    setMockItem(&m, 1, 0, GUID_B);
    const cmd = protocol.CommandMessage.parse(
        \\{"type":"command","command":"item/delete","itemGuid":"{AAAAAAAA-0000-0000-0000-000000000000}","trackIdx":1,"itemIdx":0}
    ).?;
    try std.testing.expect(getItemFromCmd(&m, cmd) == null);
}
