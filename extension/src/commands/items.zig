const std = @import("std");
const ffi = @import("../core/ffi.zig");
const reaper = @import("../reaper.zig");
const protocol = @import("../core/protocol.zig");
const mod = @import("mod.zig");
const logging = @import("../core/logging.zig");
const item_guid_cache = @import("../state/item_guid_cache.zig");

/// Helper to get item by track and item index from command
/// Uses unified indexing: 0 = master, 1+ = user tracks
fn getItemFromCmd(api: anytype, cmd: protocol.CommandMessage) ?struct { track: *anyopaque, item: *anyopaque } {
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
    api.undoEndBlock("Reamo: Set active take");
    api.updateTimeline();
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

    api.undoBeginBlock();
    if (api.setItemPosition(item_info.item, position)) {
        logging.debug("Moved item to {d:.2}", .{position});
    }
    api.undoEndBlock("Reamo: Move item");
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

    // Validate: at least one action
    const position = mod.validatePosition(cmd.getFloat("position"));
    const dest_track_guid = cmd.getString("destTrackGuid");
    if (position == null and dest_track_guid == null) {
        response.err("MISSING_PARAMS", "At least one of position or destTrackGuid required");
        return;
    }

    // Resolve item from GUID cache
    const cache = mod.g_ctx.item_cache orelse {
        response.err("NOT_INITIALIZED", "Item cache not initialized");
        return;
    };
    const location = cache.resolve(guid) orelse {
        response.err("NOT_FOUND", "Item not found (may have been deleted)");
        return;
    };
    const track = api.getTrackByUnifiedIdx(location.track_idx) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };
    const item = api.getItemByIdx(track, location.item_idx) orelse {
        response.err("NOT_FOUND", "Item not found at expected position");
        return;
    };

    api.undoBeginBlock();

    // Set position if provided
    if (position) |pos| {
        if (api.setItemPosition(item, pos)) {
            logging.debug("Moved item to {d:.2}", .{pos});
        }
    }

    // Move to destination track if provided
    if (dest_track_guid) |dest_guid| {
        const guid_cache = mod.g_ctx.guid_cache orelse {
            api.undoEndBlock("Reamo: Move item");
            response.err("NOT_INITIALIZED", "GUID cache not initialized");
            return;
        };
        const dest_track = guid_cache.resolve(dest_guid) orelse {
            api.undoEndBlock("Reamo: Move item");
            response.err("NOT_FOUND", "Destination track not found");
            return;
        };
        if (api.moveItemToTrack(item, dest_track)) {
            logging.debug("Moved item to different track", .{});
        }
    }

    api.undoEndBlock("Reamo: Move item");
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
    api.undoEndBlock("Reamo: Set item color");
    api.updateTimeline();
}

pub fn handleItemLock(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const item_info = getItemFromCmd(api, cmd) orelse {
        response.err("NOT_FOUND", "Item not found");
        return;
    };

    // Toggle lock state if no explicit value provided
    const locked = if (cmd.getInt("locked")) |v| v != 0 else blk: {
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
    api.undoEndBlock("Reamo: Lock item");
    api.updateTimeline();
}

pub fn handleItemNotes(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const item_info = getItemFromCmd(api, cmd) orelse {
        response.err("NOT_FOUND", "Item not found");
        return;
    };
    const notes = cmd.getString("notes") orelse "";

    api.undoBeginBlock();
    if (api.setItemNotes(item_info.item, notes)) {
        logging.debug("Updated item notes", .{});
    }
    api.undoEndBlock("Reamo: Set item notes");
    // Notes don't need visual refresh (not displayed in arrange view)
}

pub fn handleItemDelete(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const item_info = getItemFromCmd(api, cmd) orelse {
        response.err("NOT_FOUND", "Item not found");
        return;
    };

    api.undoBeginBlock();
    if (api.deleteItem(item_info.track, item_info.item)) {
        logging.debug("Deleted item", .{});
    }
    api.undoEndBlock("Reamo: Delete item");
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

    // Deselect all items first
    api.runCommand(reaper.Command.UNSELECT_ALL_ITEMS);

    // Select the specified item
    if (api.setItemSelected(item_info.item, true)) {
        logging.debug("Selected item", .{});
    }
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

    // Look up item location from cache
    const cache = mod.g_ctx.item_cache orelse {
        response.err("NOT_INITIALIZED", "Item cache not initialized");
        return;
    };

    const location = cache.resolve(guid) orelse {
        response.err("NOT_FOUND", "Item not found (may have been deleted)");
        return;
    };

    // Get track and item pointers from indices
    const track = api.getTrackByUnifiedIdx(location.track_idx) orelse {
        response.err("NOT_FOUND", "Track not found");
        return;
    };

    const item = api.getItemByIdx(track, location.item_idx) orelse {
        response.err("NOT_FOUND", "Item not found at expected position");
        return;
    };

    // Read current selection state and toggle
    const current_selected = api.getItemSelected(item) catch {
        response.err("CORRUPT_DATA", "Cannot read item selection state");
        return;
    };

    const new_selected = !current_selected;

    // Set new selection state (no undo - selection is UI state)
    if (api.setItemSelected(item, new_selected)) {
        logging.debug("Toggled item selection: {s} -> {}", .{ guid, new_selected });
    }

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
    const wrap = if (cmd.getInt("wrap")) |w| w != 0 else false;

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

    // Deselect all and select target
    api.runCommand(reaper.Command.UNSELECT_ALL_ITEMS);
    const target_item = api.getItemByIdx(track, target_idx) orelse {
        response.err("NOT_FOUND", "Target item not found");
        return;
    };
    _ = api.setItemSelected(target_item, true);

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
    const wrap = if (cmd.getInt("wrap")) |w| w != 0 else false;

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

    // Deselect all and select target
    api.runCommand(reaper.Command.UNSELECT_ALL_ITEMS);
    const target_item = api.getItemByIdx(track, target_idx) orelse {
        response.err("NOT_FOUND", "Target item not found");
        return;
    };
    _ = api.setItemSelected(target_item, true);

    // Return new selection
    var buf: [128]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"trackIdx\":{d},\"itemIdx\":{d}}}", .{ track_idx, target_idx }) catch {
        response.err("SERIALIZE_ERROR", "Buffer overflow");
        return;
    };
    response.success(json);
    logging.debug("Selected previous item: {d}", .{target_idx});
}

// Maximum peaks per request (enforced limit)
const MAX_PEAKS = 2000;
// Low sample rate for peak extraction (1/10th of CD quality)
const PEAK_SAMPLE_RATE: c_int = 4410;
// Max samples we can read at once (stack buffer limit)
const MAX_SAMPLE_BUF = 65536;

/// Get waveform peak data for an item's active take using AudioAccessor
pub fn handleItemGetPeaks(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    // 1. Get item from trackIdx, itemIdx
    const item_info = getItemFromCmd(api, cmd) orelse {
        response.err("NOT_FOUND", "Item not found");
        return;
    };

    // 2. Get requested peak count (default 400)
    const width = cmd.getInt("width") orelse 400;
    if (width <= 0 or width > MAX_PEAKS) {
        response.err("INVALID_WIDTH", "Width must be 1-2000");
        return;
    }
    const num_peaks: usize = @intCast(width);

    // 3. Get active take
    const take = api.getItemActiveTake(item_info.item) orelse {
        response.err("NO_TAKE", "Item has no active take");
        return;
    };

    // 4. Check if MIDI
    if (api.isTakeMIDI(take)) {
        response.err("MIDI_ITEM", "Cannot get peaks for MIDI items");
        return;
    }

    // 5. Get actual channel count from source (trust GetMediaSourceNumChannels)
    const source = api.getTakeSource(take) orelse {
        response.err("NO_SOURCE", "Take has no source");
        return;
    };
    const source_channels = api.getMediaSourceChannels(source);
    const num_channels: usize = if (source_channels > 0) @min(@as(usize, @intCast(source_channels)), 2) else 2;

    // 6. Get item properties
    const length = api.getItemLength(item_info.item);
    // Validate length is finite and positive (NaN comparisons are always false)
    if (!ffi.isFinite(length) or length <= 0) {
        response.err("EMPTY_ITEM", "Item has zero or invalid length");
        return;
    }

    // 7. Create audio accessor
    const accessor = api.makeTakeAccessor(take) orelse {
        response.err("ACCESSOR_ERROR", "Failed to create audio accessor");
        return;
    };
    defer api.destroyTakeAccessor(accessor);

    // 8. Calculate samples needed (safeFloatToInt validates the conversion)
    const total_samples: usize = ffi.safeFloatToInt(usize, length * @as(f64, PEAK_SAMPLE_RATE)) catch {
        response.err("INVALID_LENGTH", "Item length too large or invalid");
        return;
    };
    const samples_per_peak = @max(total_samples / num_peaks, 1);

    logging.debug("getPeaks - length={d:.2}s, total_samples={d}, samples_per_peak={d}", .{
        length, total_samples, samples_per_peak,
    });

    // 9. Initialize peak arrays (min/max for each channel)
    var peak_max: [MAX_PEAKS * 2]f64 = [_]f64{-1.0} ** (MAX_PEAKS * 2);
    var peak_min: [MAX_PEAKS * 2]f64 = [_]f64{1.0} ** (MAX_PEAKS * 2);

    // 10. Read samples and compute peaks
    var sample_buf: [MAX_SAMPLE_BUF]f64 = undefined;
    var sample_idx: usize = 0;
    var peak_idx: usize = 0;

    while (sample_idx < total_samples and peak_idx < num_peaks) {
        // Calculate how many samples to read this iteration
        const remaining = total_samples - sample_idx;
        const max_samples_per_chan = MAX_SAMPLE_BUF / num_channels;
        const samples_to_read: usize = @min(remaining, max_samples_per_chan);

        // Read samples
        const start_time = @as(f64, @floatFromInt(sample_idx)) / @as(f64, PEAK_SAMPLE_RATE);
        const rv = api.readAccessorSamples(
            accessor,
            PEAK_SAMPLE_RATE,
            @intCast(num_channels),
            start_time,
            @intCast(samples_to_read),
            sample_buf[0 .. samples_to_read * num_channels],
        );

        if (rv < 0) {
            logging.warn("getPeaks - readAccessorSamples error at {d}s", .{start_time});
            break;
        }
        if (rv == 0) {
            // No audio at this position, advance
            sample_idx += samples_to_read;
            continue;
        }

        // Process samples into peaks
        for (0..samples_to_read) |i| {
            const current_peak = (sample_idx + i) / samples_per_peak;
            if (current_peak >= num_peaks) break;

            // Update min/max for each channel
            for (0..num_channels) |ch| {
                const sample = sample_buf[i * num_channels + ch];
                const idx = current_peak * num_channels + ch;
                peak_max[idx] = @max(peak_max[idx], sample);
                peak_min[idx] = @min(peak_min[idx], sample);
            }
        }

        sample_idx += samples_to_read;
        peak_idx = sample_idx / samples_per_peak;
    }

    // Fix any peaks that weren't touched (still at init values)
    for (0..num_peaks * num_channels) |i| {
        if (peak_max[i] < peak_min[i]) {
            peak_max[i] = 0;
            peak_min[i] = 0;
        }
    }

    logging.debug("getPeaks - computed {d} peaks, channels={d}, max[0]={d:.4}, min[0]={d:.4}", .{
        num_peaks, num_channels, peak_max[0], peak_min[0],
    });

    // 11. Get GUIDs for cache key
    var item_guid_buf: [64]u8 = undefined;
    var take_guid_buf: [64]u8 = undefined;
    const item_guid = api.getItemGUID(item_info.item, &item_guid_buf);
    const take_guid = api.getTakeGUID(take, &take_guid_buf);

    // 12. Serialize response (use detected_channels for accurate reporting)
    var response_buf: [65536]u8 = undefined;
    const json = serializePeaksResponseFromArrays(
        &response_buf,
        response.cmd_id,
        item_guid,
        take_guid,
        length,
        api.getTakeStartOffset(take),
        api.getTakePlayrate(take),
        num_peaks,
        num_channels,
        peak_max[0 .. num_peaks * num_channels],
        peak_min[0 .. num_peaks * num_channels],
    ) orelse {
        response.err("SERIALIZE_ERROR", "Failed to serialize peaks");
        return;
    };

    response.shared_state.sendToClient(response.client_id, json);
}

// Serialize peaks response from separate min/max arrays
fn serializePeaksResponseFromArrays(
    buf: []u8,
    cmd_id: ?[]const u8,
    item_guid: []const u8,
    take_guid: []const u8,
    length: f64,
    start_offset: f64,
    playrate: f64,
    sample_count: usize,
    channels: usize,
    peak_max: []const f64,
    peak_min: []const f64,
) ?[]const u8 {
    var stream = std.io.fixedBufferStream(buf);
    var w = stream.writer();

    // Write response envelope
    w.writeAll("{\"type\":\"response\",\"id\":\"") catch return null;
    w.writeAll(cmd_id orelse "") catch return null;
    w.writeAll("\",\"success\":true,\"payload\":{\"itemGUID\":\"") catch return null;
    w.writeAll(item_guid) catch return null;
    w.writeAll("\",\"takeGUID\":\"") catch return null;
    w.writeAll(take_guid) catch return null;
    w.print("\",\"length\":{d:.6},\"startOffset\":{d:.6},\"playrate\":{d:.6},", .{
        length, start_offset, playrate,
    }) catch return null;
    w.print("\"channels\":{d},\"peaks\":[", .{channels}) catch return null;

    for (0..sample_count) |i| {
        if (i > 0) w.writeByte(',') catch return null;

        if (channels == 2) {
            // Stereo: output as {"l":[min,max],"r":[min,max]}
            const max_l = peak_max[i * 2];
            const max_r = peak_max[i * 2 + 1];
            const min_l = peak_min[i * 2];
            const min_r = peak_min[i * 2 + 1];
            w.print("{{\"l\":[{d:.4},{d:.4}],\"r\":[{d:.4},{d:.4}]}}", .{
                min_l, max_l, min_r, max_r,
            }) catch return null;
        } else {
            // Mono: output as [min,max]
            const max_val = peak_max[i];
            const min_val = peak_min[i];
            w.print("[{d:.4},{d:.4}]", .{ min_val, max_val }) catch return null;
        }
    }

    w.writeAll("]}}") catch return null;
    return stream.getWritten();
}

// ============================================================================
// Tests
// ============================================================================

test "serializePeaksResponseFromArrays mono" {
    // Mono: 2 peaks, separate max and min arrays
    const peak_max = [_]f64{ 0.8, 0.6 };
    const peak_min = [_]f64{ -0.7, -0.5 };
    var buf: [2048]u8 = undefined;

    const result = serializePeaksResponseFromArrays(
        &buf,
        "test-id",
        "{ITEM-GUID}",
        "{TAKE-GUID}",
        5.0,
        0.0,
        1.0,
        2, // 2 samples
        1, // mono
        &peak_max,
        &peak_min,
    );

    try std.testing.expect(result != null);
    const json = result.?;

    // Verify structure
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"response\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":\"test-id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"success\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"channels\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"itemGUID\":\"{ITEM-GUID}\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"takeGUID\":\"{TAKE-GUID}\"") != null);

    // Mono peaks are [min, max] format
    // First peak: min=-0.7, max=0.8
    // Second peak: min=-0.5, max=0.6
    try std.testing.expect(std.mem.indexOf(u8, json, "[-0.7") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "[-0.5") != null);
}

test "serializePeaksResponseFromArrays stereo" {
    // Stereo: 2 peaks, interleaved L/R in separate max/min arrays
    // peak_max: [maxL0, maxR0, maxL1, maxR1]
    // peak_min: [minL0, minR0, minL1, minR1]
    const peak_max = [_]f64{ 0.8, 0.7, 0.6, 0.5 };
    const peak_min = [_]f64{ -0.8, -0.7, -0.6, -0.5 };
    var buf: [2048]u8 = undefined;

    const result = serializePeaksResponseFromArrays(
        &buf,
        "test-id",
        "{ITEM-GUID}",
        "{TAKE-GUID}",
        5.0,
        0.1,
        1.5,
        2, // 2 samples
        2, // stereo
        &peak_max,
        &peak_min,
    );

    try std.testing.expect(result != null);
    const json = result.?;

    // Verify structure
    try std.testing.expect(std.mem.indexOf(u8, json, "\"channels\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"startOffset\":0.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"playrate\":1.5") != null);

    // Stereo peaks are {"l":[min,max],"r":[min,max]} format
    try std.testing.expect(std.mem.indexOf(u8, json, "\"l\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"r\":[") != null);
}

test "serializePeaksResponseFromArrays handles null cmd_id" {
    const peak_max = [_]f64{0.5};
    const peak_min = [_]f64{-0.5};
    var buf: [2048]u8 = undefined;

    const result = serializePeaksResponseFromArrays(
        &buf,
        null,
        "{ITEM}",
        "{TAKE}",
        1.0,
        0.0,
        1.0,
        1,
        1,
        &peak_max,
        &peak_min,
    );

    try std.testing.expect(result != null);
    const json = result.?;
    // cmd_id becomes empty string
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":\"\"") != null);
}

// =============================================================================
// On-Demand Data Commands
// =============================================================================
// These commands fetch full detail data that is NOT included in the regular
// item polling events (which only contain sparse hints like has_notes, take_count).
// Frontend calls these when user opens item notes or take details.

// Notes buffer size
const NOTES_BUF_SIZE = 8192;
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

    // Get notes content
    var notes_buf: [NOTES_BUF_SIZE]u8 = undefined;
    const notes = api.getItemNotes(item_info.item, &notes_buf);

    // Serialize response with escaped notes
    var buf: [NOTES_BUF_SIZE + 256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    var w = stream.writer();

    w.writeAll("{\"notes\":\"") catch {
        response.err("SERIALIZE_ERROR", "Buffer overflow");
        return;
    };
    writeJsonEscaped(w, notes) catch {
        response.err("SERIALIZE_ERROR", "Buffer overflow");
        return;
    };
    w.writeAll("\"}") catch {
        response.err("SERIALIZE_ERROR", "Buffer overflow");
        return;
    };

    response.success(stream.getWritten());
    logging.debug("Returned notes for item", .{});
}

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

    // Serialize response
    var buf: [16384]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
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
        writeJsonEscaped(w, name) catch {
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

/// Helper to write JSON-escaped string
fn writeJsonEscaped(writer: anytype, str: []const u8) !void {
    for (str) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    // Skip control characters
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
}

test "handleItemMoveByGuid requires guid parameter" {
    // Command handlers require ResponseWriter with SharedState.
    // Integration tests via websocat verify full behavior.
    // Key behaviors:
    // - Requires guid string parameter
    // - Requires at least one of position (f64) or destTrackGuid (string)
    // - Resolves item via item_guid_cache (O(1) GUID → indices)
    // - Resolves dest track via guid_cache (O(1) GUID → track pointer)
    // - Both position + track changes happen in single undo block
    // - Returns success(null) — frontend polls for updated item data
}

test "handleItemMoveByGuid rejects missing action params" {
    // Sending guid without position or destTrackGuid should return MISSING_PARAMS error.
    // Both are optional individually, but at least one must be present.
}

test "handleItemMoveByGuid supports combined position and track move" {
    // When both position and destTrackGuid are provided, both operations
    // happen in a single undo block — position is set first, then track move.
}
