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

    const num_lanes = api.getNumFixedLanes(resolution.track);
    const free_mode = api.getTrackFreeMode(resolution.track);

    // Get comp target lane from LANEREC in track state chunk
    var comp_target_lane: i32 = 0;
    const chunk_buf = scratch.alloc(u8, 65536) catch {
        response.err("ALLOC_FAILED", "Failed to allocate chunk buffer");
        return;
    };
    const chunk = api.getTrackStateChunkStr(resolution.track, chunk_buf, false);
    if (chunk.len > 0) {
        if (std.mem.indexOf(u8, chunk, "LANEREC ")) |lanerec_start| {
            const after_lanerec = lanerec_start + 8;
            const line_end = std.mem.indexOfPos(u8, chunk, after_lanerec, "\n") orelse chunk.len;
            const lanerec_line = chunk[after_lanerec..line_end];

            // Parse LANEREC v1 v2 v3 v4 - v2 is the comp target lane
            var part_idx: usize = 0;
            var iter = std.mem.splitScalar(u8, lanerec_line, ' ');
            while (iter.next()) |part| {
                if (part_idx == 1) { // v2 = comp target lane
                    comp_target_lane = std.fmt.parseInt(i32, part, 10) catch |err| blk: {
                        logging.warn("Failed to parse LANEREC comp target: {}", .{err});
                        break :blk 0;
                    };
                    break;
                }
                part_idx += 1;
            }
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
        const plays = api.getTrackLanePlays(resolution.track, i);
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
        for (lane_name) |c| {
            if (offset >= buf.len - 10) break;
            switch (c) {
                '"' => {
                    buf[offset] = '\\';
                    offset += 1;
                    buf[offset] = '"';
                    offset += 1;
                },
                '\\' => {
                    buf[offset] = '\\';
                    offset += 1;
                    buf[offset] = '\\';
                    offset += 1;
                },
                '\n' => {
                    buf[offset] = '\\';
                    offset += 1;
                    buf[offset] = 'n';
                    offset += 1;
                },
                else => {
                    buf[offset] = c;
                    offset += 1;
                },
            }
        }

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

    const num_lanes = api.getNumFixedLanes(resolution.track);
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

    const lane_index = cmd.getInt("laneIndex") orelse {
        response.err("MISSING_LANE_INDEX", "laneIndex is required");
        return;
    };

    // Get current track state chunk
    const chunk_buf = scratch.alloc(u8, 65536) catch {
        response.err("ALLOC_FAILED", "Failed to allocate chunk buffer");
        return;
    };
    const chunk = api.getTrackStateChunkStr(resolution.track, chunk_buf, false);
    if (chunk.len == 0) {
        response.err("CHUNK_READ_FAILED", "Failed to read track state chunk");
        return;
    }

    // Find LANEREC in the chunk
    const lanerec_start = std.mem.indexOf(u8, chunk, "LANEREC ");
    if (lanerec_start == null) {
        response.err("NO_LANEREC", "Track has no LANEREC field (not in fixed lanes mode?)");
        return;
    }

    const after_lanerec = lanerec_start.? + 8; // "LANEREC " is 8 chars
    const line_end = std.mem.indexOfPos(u8, chunk, after_lanerec, "\n") orelse chunk.len;
    const lanerec_line = chunk[after_lanerec..line_end];

    // Parse LANEREC v1 v2 v3 v4
    var parts: [4]i32 = .{ -1, 0, 0, 0 };
    var part_idx: usize = 0;
    var iter = std.mem.splitScalar(u8, lanerec_line, ' ');
    while (iter.next()) |part| {
        if (part_idx >= 4) break;
        parts[part_idx] = std.fmt.parseInt(i32, part, 10) catch |err| blk: {
            logging.warn("Failed to parse LANEREC part {d}: {}", .{ part_idx, err });
            break :blk 0;
        };
        part_idx += 1;
    }

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

    // Replace old LANEREC line with new one
    // Allocate +1 for null terminator required by setTrackStateChunkStr
    const new_chunk_buf = scratch.alloc(u8, 65537) catch {
        response.err("ALLOC_FAILED", "Failed to allocate new chunk buffer");
        return;
    };
    const before = chunk[0..lanerec_start.?];
    const after = chunk[line_end..];

    var new_offset: usize = 0;

    // Validate total size before copying
    const total_size = before.len + new_lanerec.len + after.len;
    if (total_size >= new_chunk_buf.len) {
        response.err("CHUNK_TOO_LARGE", "Modified chunk exceeds buffer size");
        return;
    }

    @memcpy(new_chunk_buf[new_offset .. new_offset + before.len], before);
    new_offset += before.len;
    @memcpy(new_chunk_buf[new_offset .. new_offset + new_lanerec.len], new_lanerec);
    new_offset += new_lanerec.len;
    @memcpy(new_chunk_buf[new_offset .. new_offset + after.len], after);
    new_offset += after.len;

    // Null-terminate and create sentinel slice for FFI
    new_chunk_buf[new_offset] = 0;
    const chunk_z: [:0]const u8 = new_chunk_buf[0..new_offset :0];

    api.undoBeginBlock();

    if (!api.setTrackStateChunkStr(resolution.track, chunk_z, false)) {
        api.undoEndBlock("REAmo: Set comp target (failed)");
        response.err("CHUNK_SET_FAILED", "Failed to set track state chunk");
        return;
    }

    api.updateTimeline();
    api.undoEndBlock("REAmo: Set comp target lane");

    logging.debug("Set comp target lane to {d}", .{lane_index});
    response.success(null);
}

/// Set lane play state at track level.
/// Request: { "trackGuid": "{...}", "laneIndex": 0, "plays": 1 }
/// plays: 0=off, 1=exclusive, 2=layered
pub fn handleSetLanePlays(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
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
    const resolution = tracks.resolveTrack(api, cmd) orelse {
        response.err("NOT_FOUND", "trackIdx or trackGuid required, or track not found");
        return;
    };

    // Select the track first (action operates on selected track)
    _ = api.setTrackSelected(resolution.track, true);

    api.undoBeginBlock();
    api.runCommand(ACTION_CREATE_COMP_LANE);
    api.updateTimeline();
    api.undoEndBlock("REAmo: Create comp lane");

    logging.debug("Created new comp lane", .{});
    response.success(null);
}

/// Move selected comp area up (to previous source lane).
/// Request: { "trackGuid": "{...}" }
pub fn handleMoveCompUp(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
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

    // Unselect all items first, then select just this one
    api.runCommand(ACTION_UNSELECT_ALL_ITEMS);
    _ = api.setItemSelected(item, true);

    api.undoBeginBlock();
    api.runCommand(ACTION_DELETE_COMP_AREA);
    api.updateTimeline();
    api.undoEndBlock("REAmo: Delete comp area");

    logging.debug("Deleted comp area", .{});
    response.success(null);
}
