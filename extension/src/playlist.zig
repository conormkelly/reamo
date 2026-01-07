const std = @import("std");
const protocol = @import("protocol.zig");
const markers = @import("markers.zig");
const constants = @import("constants.zig");
const logging = @import("logging.zig");

// Maximum playlists per project
pub const MAX_PLAYLISTS: usize = 16;

// Maximum entries per playlist
pub const MAX_ENTRIES_PER_PLAYLIST: usize = 64;

// Re-export shared constant for backward compatibility
pub const MAX_NAME_LEN = constants.MAX_NAME_LEN;

// Boundary detection epsilon (50ms early to account for polling jitter)
pub const BOUNDARY_EPSILON: f64 = 0.05;

/// Single playlist entry (region reference with loop count)
pub const Entry = struct {
    region_id: i32 = 0, // REAPER region display ID (markrgnindexnum)
    loop_count: i32 = 1, // -1=infinite, 0=skip, N=times

    pub fn eql(self: Entry, other: Entry) bool {
        return self.region_id == other.region_id and self.loop_count == other.loop_count;
    }
};

/// A playlist is an ordered list of region entries
pub const Playlist = struct {
    name: [MAX_NAME_LEN]u8 = undefined,
    name_len: usize = 0,
    entries: [MAX_ENTRIES_PER_PLAYLIST]Entry = undefined,
    entry_count: usize = 0,
    stop_after_last: bool = true, // Stop transport after final region's last loop

    pub fn getName(self: *const Playlist) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn setName(self: *Playlist, new_name: []const u8) void {
        const copy_len = @min(new_name.len, MAX_NAME_LEN);
        @memcpy(self.name[0..copy_len], new_name[0..copy_len]);
        self.name_len = copy_len;
    }

    pub fn addEntry(self: *Playlist, region_id: i32, loop_count: i32) bool {
        if (self.entry_count >= MAX_ENTRIES_PER_PLAYLIST) return false;
        self.entries[self.entry_count] = .{
            .region_id = region_id,
            .loop_count = loop_count,
        };
        self.entry_count += 1;
        return true;
    }

    pub fn insertEntry(self: *Playlist, at_idx: usize, region_id: i32, loop_count: i32) bool {
        if (self.entry_count >= MAX_ENTRIES_PER_PLAYLIST) return false;
        if (at_idx > self.entry_count) return false;

        // Shift entries down
        var i = self.entry_count;
        while (i > at_idx) : (i -= 1) {
            self.entries[i] = self.entries[i - 1];
        }
        self.entries[at_idx] = .{
            .region_id = region_id,
            .loop_count = loop_count,
        };
        self.entry_count += 1;
        return true;
    }

    pub fn removeEntry(self: *Playlist, idx: usize) bool {
        if (idx >= self.entry_count) return false;

        // Shift entries up
        for (idx..self.entry_count - 1) |i| {
            self.entries[i] = self.entries[i + 1];
        }
        self.entry_count -= 1;
        return true;
    }

    pub fn reorderEntry(self: *Playlist, from_idx: usize, to_idx: usize) bool {
        if (from_idx >= self.entry_count or to_idx >= self.entry_count) return false;
        if (from_idx == to_idx) return true;

        const entry = self.entries[from_idx];

        if (from_idx < to_idx) {
            // Shift entries up
            for (from_idx..to_idx) |i| {
                self.entries[i] = self.entries[i + 1];
            }
        } else {
            // Shift entries down
            var i = from_idx;
            while (i > to_idx) : (i -= 1) {
                self.entries[i] = self.entries[i - 1];
            }
        }
        self.entries[to_idx] = entry;
        return true;
    }

    pub fn eql(self: Playlist, other: Playlist) bool {
        if (self.name_len != other.name_len) return false;
        if (!std.mem.eql(u8, self.name[0..self.name_len], other.name[0..other.name_len])) return false;
        if (self.entry_count != other.entry_count) return false;
        for (0..self.entry_count) |i| {
            if (!self.entries[i].eql(other.entries[i])) return false;
        }
        return true;
    }

    /// Serialize to pipe-delimited format for EXTSTATE storage
    /// Format: PlaylistName|S:1|regionId,loopCount|regionId,loopCount|...
    /// S:1 = stop_after_last true, S:0 = false
    pub fn serialize(self: *const Playlist, buf: []u8) ?[]const u8 {
        var stream = std.io.fixedBufferStream(buf);
        const writer = stream.writer();

        // Write name (escape pipes)
        for (self.name[0..self.name_len]) |c| {
            if (c == '|' or c == '\\') {
                writer.writeByte('\\') catch return null;
            }
            writer.writeByte(c) catch return null;
        }

        // Write settings: S:1 or S:0
        writer.print("|S:{d}", .{@as(u8, if (self.stop_after_last) 1 else 0)}) catch return null;

        // Write entries
        for (0..self.entry_count) |i| {
            const entry = &self.entries[i];
            writer.print("|{d},{d}", .{ entry.region_id, entry.loop_count }) catch return null;
        }

        return stream.getWritten();
    }

    /// Deserialize from pipe-delimited format
    pub fn deserialize(buf: []const u8) ?Playlist {
        var playlist = Playlist{};
        const allocator = std.heap.page_allocator;

        // Split on unescaped pipes
        var segments: std.ArrayList([]const u8) = .empty;
        defer segments.deinit(allocator);

        var start: usize = 0;
        var i: usize = 0;
        while (i < buf.len) : (i += 1) {
            if (buf[i] == '\\' and i + 1 < buf.len) {
                i += 1; // Skip escaped char
            } else if (buf[i] == '|') {
                segments.append(allocator, buf[start..i]) catch return null;
                start = i + 1;
            }
        }
        segments.append(allocator, buf[start..]) catch return null;

        if (segments.items.len == 0) return null;

        // First segment is name (unescape)
        const name_escaped = segments.items[0];
        var name_idx: usize = 0;
        i = 0;
        while (i < name_escaped.len and name_idx < MAX_NAME_LEN) : (i += 1) {
            if (name_escaped[i] == '\\' and i + 1 < name_escaped.len) {
                i += 1;
            }
            playlist.name[name_idx] = name_escaped[i];
            name_idx += 1;
        }
        playlist.name_len = name_idx;

        // Remaining segments are settings (S:) or entries (regionId,loopCount)
        for (segments.items[1..]) |segment| {
            if (segment.len == 0) continue;

            // Check for settings prefix
            if (std.mem.startsWith(u8, segment, "S:")) {
                // Parse stop_after_last: S:1 or S:0
                if (segment.len >= 3) {
                    playlist.stop_after_last = segment[2] == '1';
                }
                continue;
            }

            // Parse entry "regionId,loopCount"
            if (playlist.entry_count >= MAX_ENTRIES_PER_PLAYLIST) break;
            if (std.mem.indexOf(u8, segment, ",")) |comma| {
                const region_id = std.fmt.parseInt(i32, segment[0..comma], 10) catch continue;
                const loop_count = std.fmt.parseInt(i32, segment[comma + 1 ..], 10) catch continue;
                playlist.entries[playlist.entry_count] = .{
                    .region_id = region_id,
                    .loop_count = loop_count,
                };
                playlist.entry_count += 1;
            }
        }

        return playlist;
    }
};

/// Playlist engine state (for playback)
pub const EngineState = enum {
    idle,
    playing,
    paused,
};

/// Action returned by engine tick (caller executes, keeps engine testable)
pub const Action = union(enum) {
    none,
    seek_to: f64, // Seek to this position (only for transitions, not loops)
    setup_native_loop: NativeLoopInfo, // Set loop points and enable repeat
    stop, // Playlist complete
    broadcast_state, // State changed, broadcast to clients
};

/// Info for setting up native looping on a region
pub const NativeLoopInfo = struct {
    region_start: f64,
    region_end: f64,
};

/// Info about the next entry (for tick function)
pub const NextEntryInfo = struct {
    loop_count: i32,
    region_start: f64,
    region_end: f64,
};

/// Playlist playback engine - pure state machine, no REAPER API calls
pub const Engine = struct {
    state: EngineState = .idle,
    playlist_idx: usize = 0,
    entry_idx: usize = 0,
    loops_remaining: i32 = 0,
    current_loop_iteration: i32 = 0, // 1-indexed, which loop we're on
    advance_after_loop: bool = false,
    prev_pos: f64 = 0, // Previous tick position for loop wrap-around detection
    next_loop_pending: bool = false, // True when we've set up next region's loop points proactively

    /// Start playing a playlist from entry 0
    pub fn play(self: *Engine, playlist_idx: usize, first_entry_loop_count: i32) Action {
        self.state = .playing;
        self.playlist_idx = playlist_idx;
        self.entry_idx = 0;
        self.loops_remaining = first_entry_loop_count;
        self.current_loop_iteration = 1;
        self.advance_after_loop = false;
        self.prev_pos = 0;
        self.next_loop_pending = false;
        return .broadcast_state;
    }

    /// Start playing from a specific entry
    pub fn playFromEntry(self: *Engine, playlist_idx: usize, entry_idx: usize, loop_count: i32) Action {
        self.state = .playing;
        self.playlist_idx = playlist_idx;
        self.entry_idx = entry_idx;
        self.loops_remaining = loop_count;
        self.current_loop_iteration = 1;
        self.advance_after_loop = false;
        self.prev_pos = 0;
        self.next_loop_pending = false;
        return .broadcast_state;
    }

    /// Pause playback (remembers position)
    pub fn pause(self: *Engine) Action {
        if (self.state == .playing) {
            self.state = .paused;
            return .broadcast_state;
        }
        return .none;
    }

    /// Resume from pause
    pub fn unpause(self: *Engine) Action {
        if (self.state == .paused) {
            self.state = .playing;
            return .broadcast_state;
        }
        return .none;
    }

    /// Stop playback entirely
    pub fn stop(self: *Engine) Action {
        if (self.state != .idle) {
            self.state = .idle;
            self.advance_after_loop = false;
            return .broadcast_state;
        }
        return .none;
    }

    /// Set flag to advance after current loop completes
    pub fn setAdvanceAfterLoop(self: *Engine) Action {
        if (self.state == .playing and self.loops_remaining == -1) {
            self.advance_after_loop = true;
            return .broadcast_state;
        }
        return .none;
    }

    /// Check if engine is active (playing or paused)
    pub fn isActive(self: *const Engine) bool {
        return self.state != .idle;
    }

    /// Check if currently playing (not paused)
    pub fn isPlaying(self: *const Engine) bool {
        return self.state == .playing;
    }

    /// Check if paused
    pub fn isPaused(self: *const Engine) bool {
        return self.state == .paused;
    }

    // How early to set up next loop points (in seconds) - gives REAPER time to prepare
    // For contiguous regions, a small margin is fine (just setting loop points)
    const PROACTIVE_MARGIN: f64 = 0.15;

    /// Called every tick to check for loop transitions.
    /// Uses proactive loop setup: sets up next region's loop points BEFORE reaching the end,
    /// so REAPER can seamlessly transition without any seek.
    ///
    /// bar_length: Duration of one bar in seconds (used for non-contiguous transition timing).
    ///             For non-contiguous regions, we trigger the seek early (in the last bar)
    ///             to give REAPER's smooth seek time to prepare.
    pub fn tick(
        self: *Engine,
        current_pos: f64,
        region_end: f64,
        region_start: f64,
        next_entry: ?NextEntryInfo,
        entry_count: usize,
        bar_length: f64,
    ) Action {
        if (self.state != .playing) return .none;

        // Store result and update prev_pos at the end
        defer self.prev_pos = current_pos;

        // Check if we've transitioned into the next region (after proactive setup)
        if (self.next_loop_pending) {
            if (next_entry) |next_e| {
                // Check if next region is the same as current (duplicate entry in playlist)
                const is_same_region = @abs(next_e.region_start - region_start) < BOUNDARY_EPSILON and
                    @abs(next_e.region_end - region_end) < BOUNDARY_EPSILON;

                const transitioned = if (is_same_region) blk: {
                    // For same region: detect wrap-around (position went from near-end to near-start)
                    // This happens when REAPER's native loop wraps back
                    break :blk self.prev_pos > region_end - BOUNDARY_EPSILON and
                        current_pos < region_start + BOUNDARY_EPSILON;
                } else blk: {
                    // For different region: check if we're now IN the next region
                    // For contiguous R1→R2: position 12.0 is in [12, 16)
                    // For non-contiguous R3→R1: position 8.0 is in [8, 12) after seek
                    break :blk current_pos >= next_e.region_start - BOUNDARY_EPSILON and
                        current_pos < next_e.region_end + BOUNDARY_EPSILON;
                };

                if (transitioned) {
                    // Complete the transition
                    self.next_loop_pending = false;
                    self.advance_after_loop = false;
                    self.entry_idx += 1;
                    self.loops_remaining = next_e.loop_count;
                    self.current_loop_iteration = 1;
                    return .broadcast_state;
                }
            }
            // Still waiting for transition
            return .none;
        }

        // Detect loop wrap-around: prev_pos was near region_end, current_pos is near region_start
        // This happens when REAPER's native loop points cause position to wrap back
        const wrapped = self.prev_pos > region_end - BOUNDARY_EPSILON and
            current_pos < region_start + BOUNDARY_EPSILON;

        if (wrapped) {
            // A loop iteration completed - decrement counter
            if (self.loops_remaining > 1) {
                self.loops_remaining -= 1;
                self.current_loop_iteration += 1;
                return .broadcast_state;
            } else if (self.loops_remaining == -1) {
                // Infinite loop - just count iterations
                self.current_loop_iteration += 1;
                return .broadcast_state;
            }
            // loops_remaining == 1 case is handled by proactive setup below
        }

        // Proactive setup: when approaching end on final loop, set up next region's loop points
        // This must happen BEFORE REAPER reaches the loop boundary
        const should_advance = self.advance_after_loop or self.loops_remaining == 1;

        if (should_advance and !self.next_loop_pending) {
            // Check if this is the last entry
            if (self.entry_idx + 1 >= entry_count) {
                // Last entry - stop when we reach the end (use small margin)
                if (current_pos > region_end - PROACTIVE_MARGIN) {
                    self.state = .idle;
                    return .stop;
                }
                return .none;
            }

            // Set up next region's loop points proactively
            if (next_entry) |next_e| {
                // Check if next region is contiguous (starts where current ends)
                const is_contiguous = @abs(next_e.region_start - region_end) < BOUNDARY_EPSILON;

                // For contiguous: use small margin (just setting loop points)
                // For non-contiguous: trigger when we're INTO the final measure
                //   We add a small buffer (0.1s) past the measure boundary so REAPER's
                //   "play to end of N measures" smooth seek counts the CURRENT measure,
                //   not immediately seeking because we're right at the boundary.
                const approaching_end = if (is_contiguous)
                    current_pos > region_end - PROACTIVE_MARGIN
                else blk: {
                    // Trigger when clearly inside the final measure (not right at boundary)
                    const MEASURE_ENTRY_BUFFER: f64 = 0.1; // 100ms past measure start
                    const final_measure_start = region_end - bar_length;
                    const trigger_point = final_measure_start + MEASURE_ENTRY_BUFFER;
                    const was_before = self.prev_pos < trigger_point;
                    const now_past = current_pos >= trigger_point;
                    break :blk was_before and now_past;
                };

                if (approaching_end) {
                    self.next_loop_pending = true;
                    // Return setup_native_loop - caller will set loop points and seek if needed
                    return .{ .setup_native_loop = .{
                        .region_start = next_e.region_start,
                        .region_end = next_e.region_end,
                    } };
                }
            }
        }

        return .none;
    }

    /// Manually advance to next entry
    pub fn next(self: *Engine, entry_count: usize, next_loop_count: i32) Action {
        if (self.state == .idle) return .none;

        self.entry_idx += 1;
        if (self.entry_idx >= entry_count) {
            self.state = .idle;
            self.advance_after_loop = false;
            return .stop;
        }

        self.loops_remaining = next_loop_count;
        self.current_loop_iteration = 1;
        self.advance_after_loop = false;
        return .broadcast_state;
    }

    /// Manually go to previous entry
    pub fn prev(self: *Engine, prev_loop_count: i32) Action {
        if (self.state == .idle) return .none;
        if (self.entry_idx == 0) return .none;

        self.entry_idx -= 1;
        self.loops_remaining = prev_loop_count;
        self.current_loop_iteration = 1;
        self.advance_after_loop = false;
        return .broadcast_state;
    }
};

/// Full playlist state (all playlists + engine state)
pub const State = struct {
    playlists: [MAX_PLAYLISTS]Playlist = undefined,
    playlist_count: usize = 0,
    engine: Engine = .{},

    pub fn addPlaylist(self: *State, name: []const u8) ?usize {
        if (self.playlist_count >= MAX_PLAYLISTS) return null;
        const idx = self.playlist_count;
        self.playlists[idx] = .{};
        self.playlists[idx].setName(name);
        self.playlist_count += 1;
        return idx;
    }

    pub fn removePlaylist(self: *State, idx: usize) bool {
        if (idx >= self.playlist_count) return false;

        // Stop engine if this playlist is active
        if (self.engine.isActive() and self.engine.playlist_idx == idx) {
            _ = self.engine.stop();
        }

        // Shift playlists up
        for (idx..self.playlist_count - 1) |i| {
            self.playlists[i] = self.playlists[i + 1];
        }
        self.playlist_count -= 1;

        // Adjust engine playlist index if needed
        if (self.engine.playlist_idx > idx and self.engine.playlist_idx > 0) {
            self.engine.playlist_idx -= 1;
        }

        return true;
    }

    pub fn getPlaylist(self: *State, idx: usize) ?*Playlist {
        if (idx >= self.playlist_count) return null;
        return &self.playlists[idx];
    }

    /// Reset all state (clear playlists and stop engine).
    /// Used when project changes to clear stale data before loading new project's playlists.
    pub fn reset(self: *State) void {
        self.playlist_count = 0;
        self.engine = .{};
    }

    /// Compare for change detection (using wyhash on serialized form would be more efficient,
    /// but field-by-field comparison is simpler for now)
    pub fn eql(self: *const State, other: *const State) bool {
        if (self.playlist_count != other.playlist_count) return false;
        for (0..self.playlist_count) |i| {
            if (!self.playlists[i].eql(other.playlists[i])) return false;
        }
        // Compare engine state
        if (self.engine.state != other.engine.state) return false;
        if (self.engine.playlist_idx != other.engine.playlist_idx) return false;
        if (self.engine.entry_idx != other.engine.entry_idx) return false;
        if (self.engine.loops_remaining != other.engine.loops_remaining) return false;
        if (self.engine.current_loop_iteration != other.engine.current_loop_iteration) return false;
        if (self.engine.advance_after_loop != other.engine.advance_after_loop) return false;
        return true;
    }

    /// Build JSON event for playlist state.
    /// If regions is provided, checks each entry's region existence and includes "deleted":true for missing regions.
    pub fn toJson(self: *const State, buf: []u8, regions: ?[]const markers.Region) ?[]const u8 {
        var stream = std.io.fixedBufferStream(buf);
        const writer = stream.writer();

        writer.writeAll("{\"type\":\"event\",\"event\":\"playlist\",\"payload\":{\"playlists\":[") catch return null;

        for (0..self.playlist_count) |i| {
            if (i > 0) writer.writeByte(',') catch return null;
            const p = &self.playlists[i];
            writer.writeAll("{\"name\":\"") catch return null;
            protocol.writeJsonString(writer, p.getName()) catch return null;
            writer.writeAll("\",\"entries\":[") catch return null;

            for (0..p.entry_count) |j| {
                if (j > 0) writer.writeByte(',') catch return null;
                const e = &p.entries[j];

                // Check if region exists (if regions provided)
                const is_deleted = if (regions) |regs| blk: {
                    for (regs) |r| {
                        if (r.id == e.region_id) break :blk false;
                    }
                    break :blk true;
                } else false;

                if (is_deleted) {
                    writer.print("{{\"regionId\":{d},\"loopCount\":{d},\"deleted\":true}}", .{
                        e.region_id,
                        e.loop_count,
                    }) catch return null;
                } else {
                    writer.print("{{\"regionId\":{d},\"loopCount\":{d}}}", .{
                        e.region_id,
                        e.loop_count,
                    }) catch return null;
                }
            }
            writer.print("],\"stopAfterLast\":{}}}", .{p.stop_after_last}) catch return null;
        }

        writer.writeAll("]") catch return null;

        // Engine state
        const e = &self.engine;
        if (e.isActive()) {
            writer.print(",\"activePlaylistIndex\":{d},\"currentEntryIndex\":{d}", .{
                e.playlist_idx,
                e.entry_idx,
            }) catch return null;

            if (e.loops_remaining >= 0) {
                writer.print(",\"loopsRemaining\":{d}", .{e.loops_remaining}) catch return null;
            } else {
                writer.writeAll(",\"loopsRemaining\":null") catch return null;
            }

            writer.print(",\"currentLoopIteration\":{d}", .{e.current_loop_iteration}) catch return null;
        } else {
            writer.writeAll(",\"activePlaylistIndex\":null,\"currentEntryIndex\":null,\"loopsRemaining\":null,\"currentLoopIteration\":null") catch return null;
        }

        writer.print(",\"isPlaylistActive\":{s},\"isPaused\":{s},\"advanceAfterLoop\":{s}", .{
            if (e.isActive()) "true" else "false",
            if (e.isPaused()) "true" else "false",
            if (e.advance_after_loop) "true" else "false",
        }) catch return null;

        writer.writeAll("}}") catch return null;

        return stream.getWritten();
    }

    // Allocator-based version - returns owned slice from allocator
    pub fn toJsonAlloc(self: *const State, allocator: std.mem.Allocator, regions: ?[]const markers.Region) ![]const u8 {
        var buf: [8192]u8 = undefined;
        const json = self.toJson(&buf, regions) orelse return error.JsonSerializationFailed;
        return allocator.dupe(u8, json);
    }

    // =========================================================================
    // Persistence (ProjExtState)
    // =========================================================================

    /// Save a single playlist to ProjExtState
    pub fn savePlaylist(self: *const State, api: anytype, idx: usize) void {
        if (idx >= self.playlist_count) return;

        // Build key: "Playlist_0", "Playlist_1", etc.
        var key_buf: [32]u8 = undefined;
        const key = std.fmt.bufPrintZ(&key_buf, "Playlist_{d}", .{idx}) catch {
            logging.warn("playlist: savePlaylist key format failed for idx={d}", .{idx});
            return;
        };

        // Serialize playlist to pipe-delimited format
        var value_buf: [4096]u8 = undefined;
        const value = self.playlists[idx].serialize(&value_buf) orelse return;

        // Need null-terminated value for API
        var value_z_buf: [4097]u8 = undefined;
        if (value.len >= value_z_buf.len) return;
        @memcpy(value_z_buf[0..value.len], value);
        value_z_buf[value.len] = 0;

        api.setProjExtStateValue("Reamo", key, value_z_buf[0..value.len :0]);
    }

    /// Clear a playlist from ProjExtState (for deletion)
    pub fn clearPlaylist(api: anytype, idx: usize) void {
        var key_buf: [32]u8 = undefined;
        const key = std.fmt.bufPrintZ(&key_buf, "Playlist_{d}", .{idx}) catch {
            logging.warn("playlist: clearPlaylist key format failed for idx={d}", .{idx});
            return;
        };
        // Setting empty string clears the key
        api.setProjExtStateValue("Reamo", key, "");
    }

    /// Save playlist count to ProjExtState
    pub fn savePlaylistCount(self: *const State, api: anytype) void {
        var count_buf: [16]u8 = undefined;
        const count_str = std.fmt.bufPrintZ(&count_buf, "{d}", .{self.playlist_count}) catch {
            logging.warn("playlist: savePlaylistCount format failed for count={d}", .{self.playlist_count});
            return;
        };
        api.setProjExtStateValue("Reamo", "PlaylistCount", count_str);
    }

    /// Save all playlists to ProjExtState
    pub fn saveAll(self: *const State, api: anytype) void {
        self.savePlaylistCount(api);
        for (0..self.playlist_count) |i| {
            self.savePlaylist(api, i);
        }
        // Clear any stale playlists beyond current count
        for (self.playlist_count..MAX_PLAYLISTS) |i| {
            clearPlaylist(api, i);
        }
    }

    /// Load a single playlist from ProjExtState
    fn loadPlaylist(self: *State, api: anytype, idx: usize) bool {
        if (idx >= MAX_PLAYLISTS) return false;

        var key_buf: [32]u8 = undefined;
        const key = std.fmt.bufPrintZ(&key_buf, "Playlist_{d}", .{idx}) catch return false;

        var value_buf: [4096]u8 = undefined;
        const value = api.getProjExtStateValue("Reamo", key, &value_buf) orelse return false;
        if (value.len == 0) return false;

        const playlist = Playlist.deserialize(value) orelse return false;
        self.playlists[idx] = playlist;
        return true;
    }

    /// Load all playlists from ProjExtState
    pub fn loadAll(self: *State, api: anytype) void {
        // Read playlist count
        var count_buf: [16]u8 = undefined;
        const count_str = api.getProjExtStateValue("Reamo", "PlaylistCount", &count_buf) orelse {
            self.playlist_count = 0;
            return;
        };

        const count = std.fmt.parseInt(usize, count_str, 10) catch {
            self.playlist_count = 0;
            return;
        };

        self.playlist_count = 0;
        for (0..@min(count, MAX_PLAYLISTS)) |i| {
            if (self.loadPlaylist(api, i)) {
                self.playlist_count = i + 1;
            }
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Entry equality" {
    const a = Entry{ .region_id = 1, .loop_count = 4 };
    const b = Entry{ .region_id = 1, .loop_count = 4 };
    const c = Entry{ .region_id = 2, .loop_count = 4 };
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "Playlist add/remove entries" {
    var p = Playlist{};
    p.setName("Test");

    try std.testing.expect(p.addEntry(1, 4));
    try std.testing.expect(p.addEntry(2, 2));
    try std.testing.expectEqual(@as(usize, 2), p.entry_count);

    try std.testing.expect(p.removeEntry(0));
    try std.testing.expectEqual(@as(usize, 1), p.entry_count);
    try std.testing.expectEqual(@as(i32, 2), p.entries[0].region_id);
}

test "Playlist reorder" {
    var p = Playlist{};
    _ = p.addEntry(1, 1);
    _ = p.addEntry(2, 1);
    _ = p.addEntry(3, 1);

    try std.testing.expect(p.reorderEntry(0, 2)); // Move 1 to end
    try std.testing.expectEqual(@as(i32, 2), p.entries[0].region_id);
    try std.testing.expectEqual(@as(i32, 3), p.entries[1].region_id);
    try std.testing.expectEqual(@as(i32, 1), p.entries[2].region_id);
}

test "Playlist serialize/deserialize" {
    var p = Playlist{};
    p.setName("Friday Gig");
    _ = p.addEntry(1, 4);
    _ = p.addEntry(2, 2);
    _ = p.addEntry(3, 1);

    var buf: [1024]u8 = undefined;
    const serialized = p.serialize(&buf) orelse unreachable;
    try std.testing.expectEqualStrings("Friday Gig|1,4|2,2|3,1", serialized);

    const p2 = Playlist.deserialize(serialized) orelse unreachable;
    try std.testing.expectEqualStrings("Friday Gig", p2.getName());
    try std.testing.expectEqual(@as(usize, 3), p2.entry_count);
    try std.testing.expectEqual(@as(i32, 1), p2.entries[0].region_id);
    try std.testing.expectEqual(@as(i32, 4), p2.entries[0].loop_count);
}

test "Playlist name with pipe escaping" {
    var p = Playlist{};
    p.setName("Test|Name");
    _ = p.addEntry(1, 1);

    var buf: [1024]u8 = undefined;
    const serialized = p.serialize(&buf) orelse unreachable;
    try std.testing.expectEqualStrings("Test\\|Name|1,1", serialized);

    const p2 = Playlist.deserialize(serialized) orelse unreachable;
    try std.testing.expectEqualStrings("Test|Name", p2.getName());
}

test "Engine play/pause/stop" {
    var engine = Engine{};

    // Start playing
    const action1 = engine.play(0, 4);
    try std.testing.expectEqual(Action.broadcast_state, action1);
    try std.testing.expect(engine.isActive());
    try std.testing.expect(engine.isPlaying());
    try std.testing.expect(!engine.isPaused());

    // Pause
    const action2 = engine.pause();
    try std.testing.expectEqual(Action.broadcast_state, action2);
    try std.testing.expect(engine.isActive());
    try std.testing.expect(!engine.isPlaying());
    try std.testing.expect(engine.isPaused());

    // Resume
    const action3 = engine.unpause();
    try std.testing.expectEqual(Action.broadcast_state, action3);
    try std.testing.expect(engine.isPlaying());

    // Stop
    const action4 = engine.stop();
    try std.testing.expectEqual(Action.broadcast_state, action4);
    try std.testing.expect(!engine.isActive());
}

test "Engine tick - proactive loop setup on final loop (contiguous)" {
    var engine = Engine{};
    _ = engine.play(0, 1); // 1 loop (final loop)

    const bar_length = 2.0; // 4/4 at 120 BPM

    // Next region starts where current ends (contiguous) - margin is 0.15s
    // Position 9.9 is within 0.15s of region_end (10.0), should trigger setup
    const action1 = engine.tick(9.9, 10.0, 0.0, .{ .loop_count = 1, .region_start = 10.0, .region_end = 20.0 }, 2, bar_length);
    try std.testing.expectEqual(Action{ .setup_native_loop = .{ .region_start = 10.0, .region_end = 20.0 } }, action1);
    try std.testing.expect(engine.next_loop_pending);
}

test "Engine tick - proactive loop setup on final loop (non-contiguous)" {
    var engine = Engine{};
    _ = engine.play(0, 1); // 1 loop (final loop)

    const bar_length = 2.0; // 4/4 at 120 BPM

    // Next region starts at 15.0, not contiguous with current end (10.0)
    // Should trigger setup when within bar_length (2.0s) of end
    // Position 8.5 is within 2.0s of region_end (10.0), should trigger setup
    const action1 = engine.tick(8.5, 10.0, 0.0, .{ .loop_count = 1, .region_start = 15.0, .region_end = 20.0 }, 2, bar_length);
    try std.testing.expectEqual(Action{ .setup_native_loop = .{ .region_start = 15.0, .region_end = 20.0 } }, action1);
    try std.testing.expect(engine.next_loop_pending);
}

test "Engine infinite loop with advance after" {
    var engine = Engine{};
    _ = engine.play(0, -1); // Infinite

    const bar_length = 2.0;

    // Should not advance yet (infinite loop, no advance flag)
    const action1 = engine.tick(9.9, 10.0, 0.0, .{ .loop_count = 1, .region_start = 10.0, .region_end = 20.0 }, 2, bar_length);
    try std.testing.expectEqual(Action.none, action1);

    // Set advance flag
    _ = engine.setAdvanceAfterLoop();
    try std.testing.expect(engine.advance_after_loop);

    // Should now trigger setup_native_loop
    const action2 = engine.tick(9.9, 10.0, 0.0, .{ .loop_count = 1, .region_start = 10.0, .region_end = 20.0 }, 2, bar_length);
    try std.testing.expectEqual(Action{ .setup_native_loop = .{ .region_start = 10.0, .region_end = 20.0 } }, action2);
}

test "Engine tick - duplicate region entries (same region twice in playlist)" {
    var engine = Engine{};
    _ = engine.play(0, 1); // Entry 0: 1 loop

    const bar_length = 2.0;
    // Both entries use the SAME region (0-10)
    const same_region_next = NextEntryInfo{ .loop_count = 1, .region_start = 0.0, .region_end = 10.0 };

    // Position 5: mid-playback of entry 0, approaching end triggers proactive setup
    var action = engine.tick(5.0, 10.0, 0.0, same_region_next, 2, bar_length);
    try std.testing.expectEqual(Action.none, action);
    try std.testing.expectEqual(@as(usize, 0), engine.entry_idx);

    // Position 9.9: near end, should trigger setup_native_loop
    action = engine.tick(9.9, 10.0, 0.0, same_region_next, 2, bar_length);
    try std.testing.expectEqual(Action{ .setup_native_loop = .{ .region_start = 0.0, .region_end = 10.0 } }, action);
    try std.testing.expect(engine.next_loop_pending);
    try std.testing.expectEqual(@as(usize, 0), engine.entry_idx); // Still on entry 0!

    // Position 9.95: still near end, waiting for wrap-around - should NOT advance yet
    action = engine.tick(9.95, 10.0, 0.0, same_region_next, 2, bar_length);
    try std.testing.expectEqual(Action.none, action);
    try std.testing.expectEqual(@as(usize, 0), engine.entry_idx); // Still on entry 0!

    // Position 0.1: wrapped around to start, NOW we should advance to entry 1
    action = engine.tick(0.1, 10.0, 0.0, same_region_next, 2, bar_length);
    try std.testing.expectEqual(Action.broadcast_state, action);
    try std.testing.expectEqual(@as(usize, 1), engine.entry_idx); // Now on entry 1!
    try std.testing.expect(!engine.next_loop_pending);
}

test "State toJson" {
    var state = State{};
    _ = state.addPlaylist("Test Set");
    if (state.getPlaylist(0)) |p| {
        _ = p.addEntry(1, 4);
        _ = p.addEntry(2, 2);
    }

    var buf: [4096]u8 = undefined;
    const json = state.toJson(&buf, null) orelse unreachable;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"event\":\"playlist\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Test Set\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"isPlaylistActive\":false") != null);
}

test "State toJson with deleted region detection" {
    var state = State{};
    _ = state.addPlaylist("Test");
    if (state.getPlaylist(0)) |p| {
        _ = p.addEntry(1, 4); // Region 1 exists
        _ = p.addEntry(99, 2); // Region 99 doesn't exist
    }

    // Create mock regions - only region 1 exists
    var regions: [1]markers.Region = undefined;
    regions[0] = .{ .id = 1, .start = 0, .end = 10 };

    var buf: [4096]u8 = undefined;
    const json = state.toJson(&buf, &regions) orelse unreachable;

    // Region 1 should not have deleted field
    try std.testing.expect(std.mem.indexOf(u8, json, "\"regionId\":1,\"loopCount\":4}") != null);
    // Region 99 should have deleted:true
    try std.testing.expect(std.mem.indexOf(u8, json, "\"regionId\":99,\"loopCount\":2,\"deleted\":true}") != null);
}
