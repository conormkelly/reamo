const std = @import("std");
const protocol = @import("../core/protocol.zig");
const mod = @import("mod.zig");
const reaper = @import("../reaper.zig");
const playlist_mod = @import("../state/playlist.zig");
const logging = @import("../core/logging.zig");

/// Create a new playlist
/// Params: name (string)
/// Returns: {"playlistIdx": N}
pub fn handleCreate(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const state = response.playlist orelse {
        response.err("INTERNAL", "Playlist state not initialized");
        return;
    };

    var name_buf: [playlist_mod.MAX_NAME_LEN]u8 = undefined;
    const name = cmd.getStringUnescaped("name", &name_buf) orelse {
        response.err("MISSING_NAME", "name is required");
        return;
    };

    const idx = state.addPlaylist(name) orelse {
        response.err("LIMIT_REACHED", "Maximum playlists reached");
        return;
    };

    // Mark dirty for deferred persistence
    state.markDirty(api.timePrecise());

    // Return the new playlist index
    var resp_buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&resp_buf, "{{\"playlistIdx\":{d}}}", .{idx}) catch {
        response.err("INTERNAL", "Buffer overflow");
        return;
    };
    response.success(json);
    logging.debug("Created playlist '{s}' at index {d}", .{ name, idx });
}

/// Delete a playlist
/// Params: playlistIdx (int)
pub fn handleDelete(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const state = response.playlist orelse {
        response.err("INTERNAL", "Playlist state not initialized");
        return;
    };

    const idx = cmd.getInt("playlistIdx") orelse {
        response.err("MISSING_IDX", "playlistIdx is required");
        return;
    };
    const idx_usize: usize = if (idx >= 0) @intCast(idx) else {
        response.err("INVALID_IDX", "playlistIdx must be non-negative");
        return;
    };

    if (!state.removePlaylist(idx_usize)) {
        response.err("NOT_FOUND", "Playlist not found");
        return;
    }

    // Mark dirty for deferred persistence
    state.markDirty(api.timePrecise());

    response.success(null);
    logging.debug("Deleted playlist at index {d}", .{idx_usize});
}

/// Rename a playlist
/// Params: playlistIdx (int), name (string)
pub fn handleRename(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const state = response.playlist orelse {
        response.err("INTERNAL", "Playlist state not initialized");
        return;
    };

    const idx = cmd.getInt("playlistIdx") orelse {
        response.err("MISSING_IDX", "playlistIdx is required");
        return;
    };
    const idx_usize: usize = if (idx >= 0) @intCast(idx) else {
        response.err("INVALID_IDX", "playlistIdx must be non-negative");
        return;
    };

    var name_buf: [playlist_mod.MAX_NAME_LEN]u8 = undefined;
    const name = cmd.getStringUnescaped("name", &name_buf) orelse {
        response.err("MISSING_NAME", "name is required");
        return;
    };

    const p = state.getPlaylist(idx_usize) orelse {
        response.err("NOT_FOUND", "Playlist not found");
        return;
    };

    p.setName(name);
    state.markDirty(api.timePrecise());

    response.success(null);
    logging.debug("Renamed playlist {d} to '{s}'", .{ idx_usize, name });
}

/// Add an entry to a playlist
/// Params: playlistIdx (int), regionId (int), loopCount (int), atIdx (optional int)
/// Returns: {"entryIdx": N}
pub fn handleAddEntry(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const state = response.playlist orelse {
        response.err("INTERNAL", "Playlist state not initialized");
        return;
    };

    const playlist_idx = cmd.getInt("playlistIdx") orelse {
        response.err("MISSING_IDX", "playlistIdx is required");
        return;
    };
    const playlist_idx_usize: usize = if (playlist_idx >= 0) @intCast(playlist_idx) else {
        response.err("INVALID_IDX", "playlistIdx must be non-negative");
        return;
    };

    const region_id = cmd.getInt("regionId") orelse {
        response.err("MISSING_REGION_ID", "regionId is required");
        return;
    };

    const loop_count = cmd.getInt("loopCount") orelse 1;

    const p = state.getPlaylist(playlist_idx_usize) orelse {
        response.err("NOT_FOUND", "Playlist not found");
        return;
    };

    // Optional atIdx for insert position
    const entry_idx: usize = if (cmd.getInt("atIdx")) |at_idx| blk: {
        if (at_idx < 0) {
            response.err("INVALID_IDX", "atIdx must be non-negative");
            return;
        }
        const at_usize: usize = @intCast(at_idx);
        if (!p.insertEntry(at_usize, region_id, loop_count)) {
            response.err("INSERT_FAILED", "Failed to insert entry");
            return;
        }

        // Gap 3 fix: Adjust engine.entry_idx when inserting before current position
        if (state.engine.isActive() and
            state.engine.playlist_idx == playlist_idx_usize and
            at_usize <= state.engine.entry_idx)
        {
            state.engine.entry_idx += 1;
        }

        break :blk at_usize;
    } else blk: {
        const new_idx = p.entry_count;
        if (!p.addEntry(region_id, loop_count)) {
            response.err("LIMIT_REACHED", "Maximum entries reached");
            return;
        }
        // Appending at end - no index adjustment needed
        break :blk new_idx;
    };

    state.markDirty(api.timePrecise());

    var resp_buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&resp_buf, "{{\"entryIdx\":{d}}}", .{entry_idx}) catch {
        response.err("INTERNAL", "Buffer overflow");
        return;
    };
    response.success(json);
    logging.debug("Added entry to playlist {d}: region {d} x{d}", .{ playlist_idx_usize, region_id, loop_count });
}

/// Remove an entry from a playlist
/// Params: playlistIdx (int), entryIdx (int)
pub fn handleRemoveEntry(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const state = response.playlist orelse {
        response.err("INTERNAL", "Playlist state not initialized");
        return;
    };

    const playlist_idx = cmd.getInt("playlistIdx") orelse {
        response.err("MISSING_IDX", "playlistIdx is required");
        return;
    };
    const playlist_idx_usize: usize = if (playlist_idx >= 0) @intCast(playlist_idx) else {
        response.err("INVALID_IDX", "playlistIdx must be non-negative");
        return;
    };

    const entry_idx = cmd.getInt("entryIdx") orelse {
        response.err("MISSING_ENTRY_IDX", "entryIdx is required");
        return;
    };
    const entry_idx_usize: usize = if (entry_idx >= 0) @intCast(entry_idx) else {
        response.err("INVALID_IDX", "entryIdx must be non-negative");
        return;
    };

    const p = state.getPlaylist(playlist_idx_usize) orelse {
        response.err("NOT_FOUND", "Playlist not found");
        return;
    };

    if (!p.removeEntry(entry_idx_usize)) {
        response.err("NOT_FOUND", "Entry not found");
        return;
    }

    // Gap 2 fix: Adjust engine.entry_idx when removing entries from active playlist
    if (state.engine.isActive() and state.engine.playlist_idx == playlist_idx_usize) {
        if (entry_idx_usize < state.engine.entry_idx) {
            // Removed before current position - shift index back
            state.engine.entry_idx -= 1;
        } else if (entry_idx_usize == state.engine.entry_idx) {
            // Removed current entry - skip to next entry (which shifted into this index)
            // Note: p.removeEntry already shifted entries, so entry_idx now points to "next"
            if (state.engine.entry_idx < p.entry_count) {
                // There's a next entry - immediately set up its region
                const next_entry = &p.entries[state.engine.entry_idx];
                state.engine.loops_remaining = next_entry.loop_count;
                state.engine.current_loop_iteration = 1;
                state.engine.next_loop_pending = false;
                state.engine.advance_after_loop = false;
                // Set up native looping on next region
                if (findRegionBounds(api, next_entry.region_id)) |bounds| {
                    api.setCursorPos(bounds.start);
                    api.setLoopPoints(bounds.start, bounds.end);
                }
                logging.debug("Deleted current entry, skipped to next (now at idx {d})", .{state.engine.entry_idx});
            } else {
                // No more entries - stop playback
                _ = state.engine.stop();
                api.setRepeat(false);
                api.clearLoopPoints();
                logging.debug("Deleted current entry (last), stopped playlist", .{});
            }
        }
        // If removed after current position, no adjustment needed (will be skipped naturally)
    }

    state.markDirty(api.timePrecise());
    response.success(null);
    logging.debug("Removed entry {d} from playlist {d}", .{ entry_idx_usize, playlist_idx_usize });
}

/// Set loop count for an entry
/// Params: playlistIdx (int), entryIdx (int), loopCount (int)
pub fn handleSetLoopCount(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const state = response.playlist orelse {
        response.err("INTERNAL", "Playlist state not initialized");
        return;
    };

    const playlist_idx = cmd.getInt("playlistIdx") orelse {
        response.err("MISSING_IDX", "playlistIdx is required");
        return;
    };
    const playlist_idx_usize: usize = if (playlist_idx >= 0) @intCast(playlist_idx) else {
        response.err("INVALID_IDX", "playlistIdx must be non-negative");
        return;
    };

    const entry_idx = cmd.getInt("entryIdx") orelse {
        response.err("MISSING_ENTRY_IDX", "entryIdx is required");
        return;
    };
    const entry_idx_usize: usize = if (entry_idx >= 0) @intCast(entry_idx) else {
        response.err("INVALID_IDX", "entryIdx must be non-negative");
        return;
    };

    const loop_count = cmd.getInt("loopCount") orelse {
        response.err("MISSING_LOOP_COUNT", "loopCount is required");
        return;
    };

    const p = state.getPlaylist(playlist_idx_usize) orelse {
        response.err("NOT_FOUND", "Playlist not found");
        return;
    };

    if (entry_idx_usize >= p.entry_count) {
        response.err("NOT_FOUND", "Entry not found");
        return;
    }

    p.entries[entry_idx_usize].loop_count = loop_count;

    // Gap 1 fix: If we're modifying the currently playing entry, sync loops_remaining
    // This ensures live loop count changes take effect immediately
    if (state.engine.isPlaying() and
        state.engine.playlist_idx == playlist_idx_usize and
        state.engine.entry_idx == entry_idx_usize)
    {
        if (loop_count == -1) {
            // Switch to infinite looping
            state.engine.loops_remaining = -1;
        } else if (loop_count == 0) {
            // Skip: finish current iteration then advance (set to 1, not 0)
            // Setting to 0 would cause infinite loop since tick only advances on ==1
            state.engine.loops_remaining = 1;
        } else {
            // Calculate remaining: new_count - completed_iterations
            // current_loop_iteration is 1-indexed (which loop we're ON)
            // completed = current_loop_iteration - 1
            const completed = state.engine.current_loop_iteration - 1;
            const remaining = loop_count - @as(i32, @intCast(completed));
            // Always ensure at least 1 remaining so current iteration finishes
            // This handles edge case: on loop 2 of 2, user changes to 1 loop
            // We let current loop play out, then advance (graceful degradation)
            state.engine.loops_remaining = if (remaining > 0) remaining else 1;
        }
    }

    state.markDirty(api.timePrecise());

    response.success(null);
    logging.debug("Set loop count for playlist {d} entry {d} to {d}", .{ playlist_idx_usize, entry_idx_usize, loop_count });
}

/// Set stopAfterLast for a playlist
/// Params: playlistIdx (int), stopAfterLast (int: 0=false, 1=true)
pub fn handleSetStopAfterLast(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const state = response.playlist orelse {
        response.err("INTERNAL", "Playlist state not initialized");
        return;
    };

    const playlist_idx = cmd.getInt("playlistIdx") orelse {
        response.err("MISSING_IDX", "playlistIdx is required");
        return;
    };
    const playlist_idx_usize: usize = if (playlist_idx >= 0) @intCast(playlist_idx) else {
        response.err("INVALID_IDX", "playlistIdx must be non-negative");
        return;
    };

    const stop_after_last = cmd.getInt("stopAfterLast") orelse {
        response.err("MISSING_VALUE", "stopAfterLast is required (0 or 1)");
        return;
    };

    const p = state.getPlaylist(playlist_idx_usize) orelse {
        response.err("NOT_FOUND", "Playlist not found");
        return;
    };

    p.stop_after_last = stop_after_last != 0;
    state.markDirty(api.timePrecise());

    response.success(null);
    logging.debug("Set stopAfterLast for playlist {d} to {}", .{ playlist_idx_usize, p.stop_after_last });
}

/// Reorder an entry within a playlist
/// Params: playlistIdx (int), fromIdx (int), toIdx (int)
pub fn handleReorderEntry(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const state = response.playlist orelse {
        response.err("INTERNAL", "Playlist state not initialized");
        return;
    };

    const playlist_idx = cmd.getInt("playlistIdx") orelse {
        response.err("MISSING_IDX", "playlistIdx is required");
        return;
    };
    const playlist_idx_usize: usize = if (playlist_idx >= 0) @intCast(playlist_idx) else {
        response.err("INVALID_IDX", "playlistIdx must be non-negative");
        return;
    };

    const from_idx = cmd.getInt("fromIdx") orelse {
        response.err("MISSING_FROM_IDX", "fromIdx is required");
        return;
    };
    const from_idx_usize: usize = if (from_idx >= 0) @intCast(from_idx) else {
        response.err("INVALID_IDX", "fromIdx must be non-negative");
        return;
    };

    const to_idx = cmd.getInt("toIdx") orelse {
        response.err("MISSING_TO_IDX", "toIdx is required");
        return;
    };
    const to_idx_usize: usize = if (to_idx >= 0) @intCast(to_idx) else {
        response.err("INVALID_IDX", "toIdx must be non-negative");
        return;
    };

    const p = state.getPlaylist(playlist_idx_usize) orelse {
        response.err("NOT_FOUND", "Playlist not found");
        return;
    };

    // Gap 3 fix: Track current entry position before reorder
    const current_entry_idx = state.engine.entry_idx;
    const is_active_playlist = state.engine.isActive() and state.engine.playlist_idx == playlist_idx_usize;

    if (!p.reorderEntry(from_idx_usize, to_idx_usize)) {
        response.err("REORDER_FAILED", "Failed to reorder entry");
        return;
    }

    // Gap 3 fix: Adjust engine.entry_idx based on how reorder affected current position
    if (is_active_playlist) {
        if (current_entry_idx == from_idx_usize) {
            // We moved the current entry - follow it to its new position
            state.engine.entry_idx = to_idx_usize;
        } else if (from_idx_usize < to_idx_usize) {
            // Moving entry forward: entries in (from, to] shift back by 1
            if (current_entry_idx > from_idx_usize and current_entry_idx <= to_idx_usize) {
                state.engine.entry_idx -= 1;
            }
        } else {
            // Moving entry backward: entries in [to, from) shift forward by 1
            if (current_entry_idx >= to_idx_usize and current_entry_idx < from_idx_usize) {
                state.engine.entry_idx += 1;
            }
        }
    }

    state.markDirty(api.timePrecise());
    response.success(null);
    logging.debug("Reordered playlist {d} entry from {d} to {d}", .{ playlist_idx_usize, from_idx_usize, to_idx_usize });
}

// ============================================================================
// Playback Commands
// ============================================================================

/// Start playing a playlist from entry 0, or resume if paused
/// Params: playlistIdx (int)
pub fn handlePlay(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const state = response.playlist orelse {
        response.err("INTERNAL", "Playlist state not initialized");
        return;
    };

    const playlist_idx = cmd.getInt("playlistIdx") orelse {
        response.err("MISSING_IDX", "playlistIdx is required");
        return;
    };
    const playlist_idx_usize: usize = if (playlist_idx >= 0) @intCast(playlist_idx) else {
        response.err("INVALID_IDX", "playlistIdx must be non-negative");
        return;
    };

    const p = state.getPlaylist(playlist_idx_usize) orelse {
        response.err("NOT_FOUND", "Playlist not found");
        return;
    };

    if (p.entry_count == 0) {
        response.err("EMPTY_PLAYLIST", "Cannot play empty playlist");
        return;
    }

    // If paused on same playlist, resume
    if (state.engine.isPaused() and state.engine.playlist_idx == playlist_idx_usize) {
        _ = state.engine.unpause();
        // Start REAPER transport
        api.runCommand(reaper.Command.PLAY);
    } else {
        // Find first valid entry (skip deleted regions)
        const valid = findFirstValidEntry(api, p, 0) orelse {
            response.err("NO_VALID_ENTRIES", "No entries have valid regions");
            return;
        };

        // Start from first valid entry
        const loop_count = p.entries[valid.entry_idx].loop_count;
        _ = state.engine.playFromEntry(playlist_idx_usize, valid.entry_idx, loop_count);

        // Set up native looping
        api.setCursorPos(valid.bounds.start);
        api.setLoopPoints(valid.bounds.start, valid.bounds.end);
        api.setRepeat(true);
        api.runCommand(reaper.Command.PLAY);
    }

    response.success(null);
    logging.debug("Started playlist {d}", .{playlist_idx_usize});
}

/// Start playing from a specific entry
/// Params: playlistIdx (int), entryIdx (int)
pub fn handlePlayFromEntry(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const state = response.playlist orelse {
        response.err("INTERNAL", "Playlist state not initialized");
        return;
    };

    const playlist_idx = cmd.getInt("playlistIdx") orelse {
        response.err("MISSING_IDX", "playlistIdx is required");
        return;
    };
    const playlist_idx_usize: usize = if (playlist_idx >= 0) @intCast(playlist_idx) else {
        response.err("INVALID_IDX", "playlistIdx must be non-negative");
        return;
    };

    const entry_idx = cmd.getInt("entryIdx") orelse {
        response.err("MISSING_ENTRY_IDX", "entryIdx is required");
        return;
    };
    const entry_idx_usize: usize = if (entry_idx >= 0) @intCast(entry_idx) else {
        response.err("INVALID_IDX", "entryIdx must be non-negative");
        return;
    };

    const p = state.getPlaylist(playlist_idx_usize) orelse {
        response.err("NOT_FOUND", "Playlist not found");
        return;
    };

    if (entry_idx_usize >= p.entry_count) {
        response.err("NOT_FOUND", "Entry not found");
        return;
    }

    // Find first valid entry starting from requested index (skip deleted regions)
    const valid = findFirstValidEntry(api, p, entry_idx_usize) orelse {
        response.err("NO_VALID_ENTRIES", "No valid entries from this position");
        return;
    };

    const loop_count = p.entries[valid.entry_idx].loop_count;
    _ = state.engine.playFromEntry(playlist_idx_usize, valid.entry_idx, loop_count);

    // Set up native looping
    api.setCursorPos(valid.bounds.start);
    api.setLoopPoints(valid.bounds.start, valid.bounds.end);
    api.setRepeat(true);
    api.runCommand(reaper.Command.PLAY);

    response.success(null);
    logging.debug("Started playlist {d} from entry {d}", .{ playlist_idx_usize, valid.entry_idx });
}

/// Pause playlist playback (remembers position)
pub fn handlePause(api: anytype, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const state = response.playlist orelse {
        response.err("INTERNAL", "Playlist state not initialized");
        return;
    };

    _ = state.engine.pause();
    // Also pause the REAPER transport
    api.runCommand(reaper.Command.PAUSE);

    response.success(null);
    logging.debug("Paused playlist", .{});
}

/// Stop playlist playback entirely
pub fn handleStop(api: anytype, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const state = response.playlist orelse {
        response.err("INTERNAL", "Playlist state not initialized");
        return;
    };

    _ = state.engine.stop();
    // Clean up native looping state
    api.setRepeat(false);
    api.clearLoopPoints();
    // Also stop the REAPER transport
    api.runCommand(reaper.Command.STOP);

    response.success(null);
    logging.debug("Stopped playlist", .{});
}

/// Advance to next entry
pub fn handleNext(api: anytype, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const state = response.playlist orelse {
        response.err("INTERNAL", "Playlist state not initialized");
        return;
    };

    if (!state.engine.isActive()) {
        response.err("NOT_PLAYING", "No playlist is active");
        return;
    }

    const p = state.getPlaylist(state.engine.playlist_idx) orelse {
        response.err("INTERNAL", "Active playlist not found");
        return;
    };

    // Get next entry's loop count
    const next_idx = state.engine.entry_idx + 1;
    if (next_idx >= p.entry_count) {
        // At last entry - stop and clean up native looping
        _ = state.engine.stop();
        api.setRepeat(false);
        api.clearLoopPoints();
        response.success(null);
        return;
    }

    const next_loop_count = p.entries[next_idx].loop_count;
    _ = state.engine.next(p.entry_count, next_loop_count);

    // Set up native looping on next region
    const region_id = p.entries[next_idx].region_id;
    if (findRegionBounds(api, region_id)) |bounds| {
        api.setCursorPos(bounds.start);
        api.setLoopPoints(bounds.start, bounds.end);
    }

    response.success(null);
    logging.debug("Advanced to next entry", .{});
}

/// Go to previous entry
pub fn handlePrev(api: anytype, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const state = response.playlist orelse {
        response.err("INTERNAL", "Playlist state not initialized");
        return;
    };

    if (!state.engine.isActive()) {
        response.err("NOT_PLAYING", "No playlist is active");
        return;
    }

    if (state.engine.entry_idx == 0) {
        response.err("AT_START", "Already at first entry");
        return;
    }

    const p = state.getPlaylist(state.engine.playlist_idx) orelse {
        response.err("INTERNAL", "Active playlist not found");
        return;
    };

    const prev_idx = state.engine.entry_idx - 1;
    const prev_loop_count = p.entries[prev_idx].loop_count;
    _ = state.engine.prev(prev_loop_count);

    // Set up native looping on previous region
    const region_id = p.entries[prev_idx].region_id;
    if (findRegionBounds(api, region_id)) |bounds| {
        api.setCursorPos(bounds.start);
        api.setLoopPoints(bounds.start, bounds.end);
    }

    response.success(null);
    logging.debug("Went to previous entry", .{});
}

/// Set flag to advance after current loop completes
pub fn handleAdvanceAfterLoop(_: anytype, _: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const state = response.playlist orelse {
        response.err("INTERNAL", "Playlist state not initialized");
        return;
    };

    if (!state.engine.isPlaying()) {
        response.err("NOT_PLAYING", "Playlist is not playing");
        return;
    }

    _ = state.engine.setAdvanceAfterLoop();

    response.success(null);
    logging.debug("Set advance after loop flag", .{});
}

/// Region boundaries for native looping
const RegionBounds = struct {
    start: f64,
    end: f64,
};

/// Result of finding a valid entry
const ValidEntryResult = struct {
    entry_idx: usize,
    bounds: RegionBounds,
};

// Helper to find the first valid entry (whose region exists) starting from a given index
fn findFirstValidEntry(api: anytype, p: *const playlist_mod.Playlist, start_idx: usize) ?ValidEntryResult {
    var idx = start_idx;
    while (idx < p.entry_count) : (idx += 1) {
        const region_id = p.entries[idx].region_id;
        if (findRegionBounds(api, region_id)) |bounds| {
            return .{ .entry_idx = idx, .bounds = bounds };
        }
    }
    return null;
}

// Helper to find a region's start position by ID
fn findRegionStart(api: anytype, region_id: i32) ?f64 {
    if (findRegionBounds(api, region_id)) |bounds| {
        return bounds.start;
    }
    return null;
}

// Helper to find a region's start and end positions by ID
fn findRegionBounds(api: anytype, region_id: i32) ?RegionBounds {
    // Poll regions to get current state
    // Note: This is a bit inefficient but ensures we have fresh data
    var idx: c_int = 0;
    while (true) : (idx += 1) {
        const marker = api.enumMarker(idx) orelse break;

        if (marker.is_region and marker.id == region_id) {
            return .{ .start = marker.pos, .end = marker.end };
        }
    }
    return null;
}
