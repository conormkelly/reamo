/// Fixed Lanes / Swipe Comping command handlers.
///
/// Implements backend commands for REAPER's fixed lane comping system.
/// See docs/features/SWIPE_COMPING.md for implementation details.
const std = @import("std");
const reaper = @import("../reaper.zig");
const protocol = @import("../core/protocol.zig");
const mod = @import("mod.zig");
const tracks = @import("tracks.zig");
const logging = @import("../core/logging.zig");

// REAPER action IDs for lane comping
const ACTION_CREATE_COMP_AREA: c_int = 42475; // "Razor edit: Create fixed lane comp area"
const ACTION_DELETE_COMP_AREA: c_int = 42642; // "Fixed lane comp area: Delete comp area"
const ACTION_MOVE_COMP_UP: c_int = 42707; // "Fixed lane comp area: Move comp area up"
const ACTION_MOVE_COMP_DOWN: c_int = 42708; // "Fixed lane comp area: Move comp area down"
const ACTION_CREATE_COMP_LANE: c_int = 42797; // "Track lanes: Insert new comp lane"
const ACTION_UNSELECT_ALL_ITEMS: c_int = 40289; // "Item: Unselect all items"

/// Get lane state for a track.
/// Request: { "trackGuid": "{...}" } or { "trackIdx": 1 }
/// Response: { "numLanes": 3, "freeMode": 2, "compTargetLane": 0, "lanes": [...] }
pub fn handleGetState(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    if (!mod.requireLanes(api, response)) return;
    // Use scratch arena for large buffers (timer callback stack safety)
    const tiered = mod.g_ctx.tiered orelse {
        response.err("NOT_INITIALIZED", "Tiered arenas not initialized");
        return;
    };
    const scratch = tiered.scratchAllocator();

    const resolution = tracks.resolveTrack(api, cmd) orelse {
        response.err("NOT_FOUND", "trackIdx or trackGuid required, or track not found");
        return;
    };

    const num_lanes = api.getNumFixedLanes(resolution.track) catch 0;
    const free_mode = api.getTrackFreeMode(resolution.track) catch 0;

    // Get comp target lane from LANEREC in track state chunk
    var comp_target_lane: i32 = 0;
    if (readTrackChunk(api, resolution.track)) |chunk| {
        defer std.heap.c_allocator.free(chunk.buf);
        if (findLanerec(chunk.text)) |line| {
            comp_target_lane = parseLanerec(line.fields)[1];
        }
    }

    // Build JSON response with lane info
    const buf = scratch.alloc(u8, 32768) catch {
        response.err("ALLOC_FAILED", "Failed to allocate response buffer");
        return;
    };
    var offset: usize = 0;

    // Start response object with compTargetLane
    offset += (std.fmt.bufPrint(buf[offset..], "{{\"numLanes\":{d},\"freeMode\":{d},\"compTargetLane\":{d},\"lanes\":[", .{ num_lanes, free_mode, comp_target_lane }) catch {
        response.err("BUFFER_OVERFLOW", "Response too large for buffer");
        return;
    }).len;

    // Add lane info with play states and names
    var i: c_int = 0;
    while (i < num_lanes and i < 32) : (i += 1) {
        const plays = api.getTrackLanePlays(resolution.track, i) catch 0;
        if (i > 0) {
            if (offset < buf.len) {
                buf[offset] = ',';
                offset += 1;
            }
        }

        // Get lane name
        var name_buf: [256]u8 = undefined;
        const lane_name = api.getLaneName(resolution.track, i, &name_buf);

        offset += (std.fmt.bufPrint(buf[offset..], "{{\"lane\":{d},\"plays\":{d},\"name\":\"", .{ i, plays }) catch {
            response.err("BUFFER_OVERFLOW", "Response too large for buffer");
            return;
        }).len;

        // Write escaped lane name
        var stream = std.io.fixedBufferStream(buf[offset..]);
        protocol.writeJsonString(stream.writer(), lane_name) catch {
            response.err("BUFFER_OVERFLOW", "Response too large for buffer");
            return;
        };
        offset += stream.pos;

        offset += (std.fmt.bufPrint(buf[offset..], "\"}}", .{}) catch {
            response.err("BUFFER_OVERFLOW", "Response too large for buffer");
            return;
        }).len;
    }

    // Close arrays and object
    offset += (std.fmt.bufPrint(buf[offset..], "]}}", .{}) catch {
        response.err("BUFFER_OVERFLOW", "Response too large for buffer");
        return;
    }).len;

    response.success(buf[0..offset]);
}

/// Swipe comp: Create a comp area from a source lane.
/// Uses P_RAZOREDITS_EXT + Action 42475 to create proper comp metadata.
/// Request: { "trackGuid": "{...}", "sourceLane": 1, "startTime": 10.0, "endTime": 15.0 }
pub fn handleSwipeComp(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    if (!mod.requireLanes(api, response)) return;
    const resolution = tracks.resolveTrack(api, cmd) orelse {
        response.err("NOT_FOUND", "trackIdx or trackGuid required, or track not found");
        return;
    };

    const source_lane = cmd.getInt("sourceLane") orelse {
        response.err("MISSING_SOURCE_LANE", "sourceLane is required");
        return;
    };

    // Validate times: reject negative, NaN, Inf (consistent with time_sel.zig pattern)
    const raw_start = mod.validatePosition(cmd.getFloat("startTime")) orelse {
        response.err("INVALID_START_TIME", "startTime must be a non-negative number");
        return;
    };

    const raw_end = mod.validatePosition(cmd.getFloat("endTime")) orelse {
        response.err("INVALID_END_TIME", "endTime must be a non-negative number");
        return;
    };

    // Normalize time range: swap if user dragged right-to-left (end < start)
    const start_time = @min(raw_start, raw_end);
    const end_time = @max(raw_start, raw_end);

    if (start_time == end_time) {
        response.err("INVALID_TIME_RANGE", "startTime and endTime cannot be equal");
        return;
    }

    const num_lanes = api.getNumFixedLanes(resolution.track) catch 0;
    if (num_lanes <= 0) {
        response.err("NO_FIXED_LANES", "Track has no fixed lanes enabled");
        return;
    }
    if (source_lane < 0 or source_lane >= num_lanes) {
        response.err("INVALID_LANE", "sourceLane out of range");
        return;
    }

    // Calculate normalized Y bounds for target lane (0.0-1.0 range)
    const num_lanes_f: f64 = @floatFromInt(num_lanes);
    const lane_height = 1.0 / num_lanes_f;
    const lane_f: f64 = @floatFromInt(source_lane);
    const top_y = lane_f * lane_height;
    const btm_y = top_y + lane_height;

    // Create razor edit string: "startTime endTime envelopeGUID topY bottomY"
    // Empty GUID ("") targets media items, not envelopes
    var razor_buf: [256]u8 = undefined;
    const razor_str = std.fmt.bufPrint(&razor_buf, "{d:.15} {d:.15} \"\" {d:.15} {d:.15}", .{
        start_time,
        end_time,
        top_y,
        btm_y,
    }) catch {
        response.err("FORMAT_ERROR", "Failed to format razor string");
        return;
    };

    api.undoBeginBlock();

    // Set razor edit on target lane
    if (!api.setRazorEditsExt(resolution.track, razor_str)) {
        api.undoEndBlock("REAmo: Swipe comp (failed)");
        response.err("RAZOR_EDIT_FAILED", "Failed to set razor edit");
        return;
    }

    // Convert razor to comp area (creates proper metadata!)
    // Note: runCommand returns void; REAPER's Main_OnCommand provides no success indicator.
    // We rely on the razor edit setup succeeding and trust the action.
    api.runCommand(ACTION_CREATE_COMP_AREA);

    // Clear razor edit - warn if cleanup fails but don't fail the operation
    if (!api.clearRazorEdits(resolution.track)) {
        logging.warn("Failed to clear razor edit after comp area creation", .{});
    }

    api.updateTimeline();
    api.undoEndBlock("REAmo: Swipe comp");

    logging.debug("Swipe comp: lane {d}, {d:.2}s - {d:.2}s", .{ source_lane, start_time, end_time });
    response.success(null);
}

/// Set the comp target lane for a track by modifying the LANEREC field in the state chunk.
/// Request: { "trackGuid": "{...}", "laneIndex": 0 }
pub fn handleSetCompTarget(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    if (!mod.requireLanes(api, response)) return;
    const resolution = tracks.resolveTrack(api, cmd) orelse {
        response.err("NOT_FOUND", "trackIdx or trackGuid required, or track not found");
        return;
    };

    const lane_index = cmd.getInt("laneIndex") orelse {
        response.err("MISSING_LANE_INDEX", "laneIndex is required");
        return;
    };
    if (!laneExists(api, resolution.track, lane_index)) {
        response.err("INVALID_LANE", "laneIndex is not a lane of this track");
        return;
    }

    // Get the whole track state chunk: it is written back, and a truncated
    // chunk written back deletes everything past the cut.
    const chunk = readTrackChunk(api, resolution.track) orelse {
        response.err("CHUNK_READ_FAILED", "Failed to read the whole track state chunk");
        return;
    };
    defer std.heap.c_allocator.free(chunk.buf);
    if (!isCompleteChunk(chunk.text)) {
        response.err("CHUNK_READ_FAILED", "Track state chunk is incomplete");
        return;
    }

    const line = findLanerec(chunk.text) orelse {
        response.err("NO_LANEREC", "Track has no LANEREC field (not in fixed lanes mode?)");
        return;
    };
    const parts = parseLanerec(line.fields);

    // Build new LANEREC: v1 unchanged, v2=new target, v3 depends on target, v4=0
    const new_v3: i32 = if (lane_index == 0) 1 else 0;
    var new_lanerec_buf: [64]u8 = undefined;
    const new_lanerec = std.fmt.bufPrint(&new_lanerec_buf, "LANEREC {d} {d} {d} 0", .{
        parts[0],
        lane_index,
        new_v3,
    }) catch {
        response.err("FORMAT_ERROR", "Failed to format new LANEREC");
        return;
    };

    // Replace the LANEREC line; everything else is written back byte for byte.
    const before = chunk.text[0..line.start];
    const after = chunk.text[line.end..];
    const new_chunk = std.mem.concatWithSentinel(std.heap.c_allocator, u8, &.{ before, new_lanerec, after }, 0) catch {
        response.err("ALLOC_FAILED", "Failed to allocate new chunk buffer");
        return;
    };
    defer std.heap.c_allocator.free(new_chunk);

    api.undoBeginBlock();

    if (!api.setTrackStateChunkStr(resolution.track, new_chunk, false)) {
        api.undoEndBlock("REAmo: Set comp target (failed)");
        response.err("CHUNK_SET_FAILED", "Failed to set track state chunk");
        return;
    }

    api.updateTimeline();
    api.undoEndBlock("REAmo: Set comp target lane");

    logging.debug("Set comp target lane to {d}", .{lane_index});
    response.success(null);
}

/// REAPER accepts lane properties for lanes a track doesn't have; refuse them
/// instead of writing settings nothing will ever show.
fn laneExists(api: anytype, track: *anyopaque, lane: c_int) bool {
    const num_lanes = api.getNumFixedLanes(track) catch return false;
    return lane >= 0 and lane < num_lanes;
}

/// The user tracks selected now (free with c_allocator), or null on OOM.
fn selectedTracks(api: anytype) ?[]*anyopaque {
    var list: std.ArrayListUnmanaged(*anyopaque) = .empty;
    var i: c_int = 1;
    while (i <= api.trackCount()) : (i += 1) {
        const track = api.getTrackByUnifiedIdx(i) orelse continue;
        if (!api.getTrackSelected(track)) continue;
        list.append(std.heap.c_allocator, track) catch {
            list.deinit(std.heap.c_allocator);
            return null;
        };
    }
    return list.toOwnedSlice(std.heap.c_allocator) catch null;
}

/// The items selected now, to give the user back after an action that works
/// on the item selection (free with c_allocator); null if out of memory.
fn selectedItems(api: anytype) ?[]*anyopaque {
    var list: std.ArrayListUnmanaged(*anyopaque) = .empty;
    var i: c_int = 1;
    while (i <= api.trackCount()) : (i += 1) {
        const track = api.getTrackByUnifiedIdx(i) orelse continue;
        var j: c_int = 0;
        while (j < api.trackItemCount(track)) : (j += 1) {
            const item = api.getItemByIdx(track, j) orelse continue;
            const selected = api.getItemSelected(item) catch false;
            if (!selected) continue;
            list.append(std.heap.c_allocator, item) catch {
                list.deinit(std.heap.c_allocator);
                return null;
            };
        }
    }
    return list.toOwnedSlice(std.heap.c_allocator) catch null;
}

/// A whole track state chunk, read into `buf` (free with c_allocator).
const TrackChunk = struct { buf: []u8, text: []const u8 };

/// Largest track chunk read; a track this size has hundreds of thousands of items.
const MAX_CHUNK_BYTES: usize = 256 * 1024 * 1024;

/// Read a track's whole state chunk. GetTrackStateChunk reports success even
/// when it cut the chunk to fit the buffer (it keeps one byte for the NUL),
/// so a chunk that fills the buffer is read again into a larger one.
fn readTrackChunk(api: anytype, track: *anyopaque) ?TrackChunk {
    var size: usize = 64 * 1024;
    while (size <= MAX_CHUNK_BYTES) : (size *= 4) {
        const buf = std.heap.c_allocator.alloc(u8, size) catch return null;
        const text = api.getTrackStateChunkStr(track, buf, false);
        if (text.len > 0 and text.len + 1 < buf.len) return .{ .buf = buf, .text = text };
        std.heap.c_allocator.free(buf);
        if (text.len == 0) return null;
    }
    logging.warn("track state chunk larger than {d} bytes; not read", .{MAX_CHUNK_BYTES});
    return null;
}

/// A track chunk as REAPER writes it: "<TRACK ..." through its closing ">".
fn isCompleteChunk(chunk: []const u8) bool {
    const t = std.mem.trim(u8, chunk, " \t\r\n");
    return std.mem.startsWith(u8, t, "<TRACK") and std.mem.endsWith(u8, t, ">");
}

const LanerecLine = struct { start: usize, end: usize, fields: []const u8 };

/// The track's own LANEREC line. Only a line starting with the keyword
/// counts: item notes and other nested text can contain the word.
fn findLanerec(chunk: []const u8) ?LanerecLine {
    var line_start: usize = 0;
    while (line_start < chunk.len) {
        const line_end = std.mem.indexOfScalarPos(u8, chunk, line_start, '\n') orelse chunk.len;
        const line = std.mem.trimRight(u8, chunk[line_start..line_end], "\r");
        if (std.mem.startsWith(u8, line, "LANEREC ")) {
            return .{ .start = line_start, .end = line_start + line.len, .fields = line["LANEREC ".len..] };
        }
        line_start = line_end + 1;
    }
    return null;
}

/// LANEREC's four integer fields; missing or malformed fields read as -1 / 0.
fn parseLanerec(fields: []const u8) [4]i32 {
    var parts: [4]i32 = .{ -1, 0, 0, 0 };
    var iter = std.mem.tokenizeScalar(u8, fields, ' ');
    var i: usize = 0;
    while (iter.next()) |part| : (i += 1) {
        if (i >= parts.len) break;
        parts[i] = std.fmt.parseInt(i32, part, 10) catch |err| blk: {
            logging.warn("Failed to parse LANEREC part {d}: {}", .{ i, err });
            break :blk parts[i];
        };
    }
    return parts;
}

/// Stand-in for REAPER's GetTrackStateChunk: copies what fits and keeps
/// one byte for the NUL, reporting success either way.
const FakeChunkApi = struct {
    chunk: []const u8,
    calls: usize = 0,
    pub fn getTrackStateChunkStr(self: *FakeChunkApi, track: *anyopaque, buf: []u8, isundo: bool) []const u8 {
        _ = track;
        _ = isundo;
        self.calls += 1;
        const n = @min(self.chunk.len, buf.len - 1);
        @memcpy(buf[0..n], self.chunk[0..n]);
        return buf[0..n];
    }
};

test "readTrackChunk reads a chunk larger than its first buffer whole" {
    const big = try std.testing.allocator.alloc(u8, 300 * 1024);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');
    @memcpy(big[0..7], "<TRACK\n");
    big[big.len - 1] = '>';
    var api = FakeChunkApi{ .chunk = big };
    var dummy: u8 = 0;
    const chunk = readTrackChunk(&api, @ptrCast(&dummy)).?;
    defer std.heap.c_allocator.free(chunk.buf);
    try std.testing.expectEqual(big.len, chunk.text.len);
    try std.testing.expect(isCompleteChunk(chunk.text));
    try std.testing.expect(api.calls > 1);
}

test "a truncated chunk is not complete" {
    try std.testing.expect(isCompleteChunk("<TRACK\nNAME x\nLANEREC 1 0 0 0\n>\n"));
    try std.testing.expect(!isCompleteChunk("<TRACK\nNAME x\n<ITEM\nPOSITION 1\n"));
}

test "findLanerec ignores LANEREC text inside item notes" {
    const chunk = "<TRACK\nNAME v\n<ITEM\n<NOTES\n|LANEREC 9 9 9 9\n>\n>\nLANEREC 1 2 0 0\n>\n";
    const line = findLanerec(chunk).?;
    try std.testing.expectEqual([4]i32{ 1, 2, 0, 0 }, parseLanerec(line.fields));
    try std.testing.expectEqualStrings("LANEREC 1 2 0 0", chunk[line.start..line.end]);
}

/// Set lane play state at track level.
/// Request: { "trackGuid": "{...}", "laneIndex": 0, "plays": 1 }
/// plays: 0=off, 1=exclusive, 2=layered
pub fn handleSetLanePlays(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    if (!mod.requireLanes(api, response)) return;
    const resolution = tracks.resolveTrack(api, cmd) orelse {
        response.err("NOT_FOUND", "trackIdx or trackGuid required, or track not found");
        return;
    };

    const lane_index = cmd.getInt("laneIndex") orelse {
        response.err("MISSING_LANE_INDEX", "laneIndex is required");
        return;
    };

    const plays = cmd.getInt("plays") orelse {
        response.err("MISSING_PLAYS", "plays is required (0=off, 1=exclusive, 2=layered)");
        return;
    };
    if (!laneExists(api, resolution.track, lane_index)) {
        response.err("INVALID_LANE", "laneIndex is not a lane of this track");
        return;
    }
    if (plays < 0 or plays > 2) {
        response.err("INVALID_PLAYS", "plays must be 0 (off), 1 (exclusive) or 2 (layered)");
        return;
    }

    api.undoBeginBlock();

    if (!api.setTrackLanePlays(resolution.track, lane_index, plays)) {
        api.undoEndBlock("REAmo: Set lane plays (failed)");
        response.err("SET_LANE_PLAYS_FAILED", "Failed to set lane play state");
        return;
    }

    api.updateTimeline();
    api.undoEndBlock("REAmo: Set lane plays");

    logging.debug("Set lane {d} plays to {d}", .{ lane_index, plays });
    response.success(null);
}

/// Create a new comp lane on the track.
/// Request: { "trackGuid": "{...}" }
pub fn handleCreateCompLane(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    if (!mod.requireLanes(api, response)) return;
    const resolution = tracks.resolveTrack(api, cmd) orelse {
        response.err("NOT_FOUND", "trackIdx or trackGuid required, or track not found");
        return;
    };

    // The action acts on every selected track: make the target the only
    // one, then give the user back the selection they had.
    const saved = selectedTracks(api) orelse {
        response.err("ALLOC_FAILED", "Failed to save track selection");
        return;
    };
    defer std.heap.c_allocator.free(saved);

    api.undoBeginBlock();
    api.runCommand(reaper.Command.UNSELECT_ALL_TRACKS);
    _ = api.setTrackSelected(resolution.track, true);
    api.runCommand(ACTION_CREATE_COMP_LANE);
    api.runCommand(reaper.Command.UNSELECT_ALL_TRACKS);
    for (saved) |track| _ = api.setTrackSelected(track, true);
    api.updateTimeline();
    api.undoEndBlock("REAmo: Create comp lane");

    logging.debug("Created new comp lane", .{});
    response.success(null);
}

/// Move selected comp area up (to previous source lane).
/// Request: { "trackGuid": "{...}" }
pub fn handleMoveCompUp(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    if (!mod.requireLanes(api, response)) return;
    // Track validation is intentional even though the pointer isn't used directly.
    // The REAPER action operates on the current item selection, but we validate the
    // track exists first to ensure the request references a valid track context.
    _ = tracks.resolveTrack(api, cmd) orelse {
        response.err("NOT_FOUND", "trackIdx or trackGuid required, or track not found");
        return;
    };

    api.undoBeginBlock();
    api.runCommand(ACTION_MOVE_COMP_UP);
    api.updateTimeline();
    api.undoEndBlock("REAmo: Move comp up");

    logging.debug("Moved comp area up", .{});
    response.success(null);
}

/// Move selected comp area down (to next source lane).
/// Request: { "trackGuid": "{...}" }
pub fn handleMoveCompDown(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    if (!mod.requireLanes(api, response)) return;
    // Track validation is intentional even though the pointer isn't used directly.
    // The REAPER action operates on the current item selection, but we validate the
    // track exists first to ensure the request references a valid track context.
    _ = tracks.resolveTrack(api, cmd) orelse {
        response.err("NOT_FOUND", "trackIdx or trackGuid required, or track not found");
        return;
    };

    api.undoBeginBlock();
    api.runCommand(ACTION_MOVE_COMP_DOWN);
    api.updateTimeline();
    api.undoEndBlock("REAmo: Move comp down");

    logging.debug("Moved comp area down", .{});
    response.success(null);
}

/// Delete a comp area (preserves source media).
/// Request: { "trackGuid": "{...}", "itemGuid": "{...}" } or { "trackIdx": 1, "itemIdx": 0 }
pub fn handleDeleteCompArea(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    if (!mod.requireLanes(api, response)) return;
    const resolution = tracks.resolveTrack(api, cmd) orelse {
        response.err("NOT_FOUND", "trackIdx or trackGuid required, or track not found");
        return;
    };

    // Need to get the item - either by itemIdx or itemGuid
    const item_idx = cmd.getInt("itemIdx") orelse {
        response.err("MISSING_ITEM", "itemIdx is required");
        return;
    };

    const item = api.getItemByIdx(resolution.track, item_idx) orelse {
        response.err("ITEM_NOT_FOUND", "Item not found at specified index");
        return;
    };

    // The action deletes the selected comp areas: select only this one, then
    // give the user back the rest of their selection.
    const saved = selectedItems(api) orelse {
        response.err("ALLOC_FAILED", "Failed to save item selection");
        return;
    };
    defer std.heap.c_allocator.free(saved);

    api.undoBeginBlock();
    api.runCommand(ACTION_UNSELECT_ALL_ITEMS);
    _ = api.setItemSelected(item, true);
    api.runCommand(ACTION_DELETE_COMP_AREA);
    for (saved) |kept| {
        // The deleted comp area is gone; never hand its pointer back to REAPER.
        if (kept == item or !api.validateItemPtr(kept)) continue;
        _ = api.setItemSelected(kept, true);
    }
    api.updateTimeline();
    api.undoEndBlock("REAmo: Delete comp area");

    logging.debug("Deleted comp area", .{});
    response.success(null);
}
