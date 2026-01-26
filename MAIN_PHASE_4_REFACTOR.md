# Phase 4: Extract Playlist Engine Tick

## Overview

This document provides surgical instructions for extracting the playlist engine tick logic from `doProcessing()` in `main.zig` into a new module `playlist_tick.zig`.

**Risk Level:** Low
**Estimated Lines Moved:** ~185
**Resulting main.zig:** ~1040 lines (down from ~1221)

---

## 1. Exact Line Ranges

### 1.1 Transport Sync with Playlist Engine (Lines 788-812)

```zig
// Sync playlist engine with external transport changes
// (user paused/stopped REAPER transport outside of our control)
if (g_playlist_state.engine.isActive()) {
    const transport_playing = transport.PlayState.isPlaying(current_transport.play_state);
    const transport_stopped = current_transport.play_state == transport.PlayState.STOPPED;

    if (g_playlist_state.engine.isPlaying() and !transport_playing) {
        // Engine thinks it's playing but transport isn't
        if (transport_stopped) {
            _ = g_playlist_state.engine.stop();
            backend.setRepeat(false);
            backend.clearLoopPoints();
            logging.debug("Stopped playlist engine - transport stopped externally", .{});
        } else {
            // Transport paused
            _ = g_playlist_state.engine.pause();
            logging.debug("Paused playlist engine - transport paused externally", .{});
        }
        // Broadcast state change
        const scratch = tiered.scratchAllocator();
        if (g_playlist_state.toJsonAlloc(scratch, g_last_markers.regions)) |json| {
            shared_state.broadcast(json);
        } else |_| {}
    }
}
```

**Line count:** 25 lines

### 1.2 Playlist Engine Tick (Lines 814-972)

```zig
// Playlist engine tick (when playing)
if (g_playlist_state.engine.isPlaying()) {
    const current_pos = current_transport.play_position;

    // Get current entry's region info
    if (g_playlist_state.getPlaylist(g_playlist_state.engine.playlist_idx)) |p| {
        if (g_playlist_state.engine.entry_idx < p.entry_count) {
            const entry = &p.entries[g_playlist_state.engine.entry_idx];

            // Find region by ID in cached markers state
            var region_start: f64 = 0;
            var region_end: f64 = 0;
            var region_found = false;
            for (g_last_markers.regions) |*r| {
                if (r.id == entry.region_id) {
                    region_start = r.start;
                    region_end = r.end;
                    region_found = true;
                    break;
                }
            }

            if (region_found) {
                // Get next entry info if available
                const next_entry: ?playlist.NextEntryInfo = blk: {
                    // ... next entry lookup ...
                };

                // Calculate bar length for non-contiguous transition timing
                const bpm = current_transport.bpm;
                const beats_per_bar = current_transport.time_sig_num;
                const bar_length = if (bpm > 0) beats_per_bar * (60.0 / bpm) else 2.0;

                const action = g_playlist_state.engine.tick(
                    current_pos,
                    region_end,
                    region_start,
                    next_entry,
                    p.entry_count,
                    bar_length,
                );

                // Handle action
                switch (action) {
                    .seek_to => |pos| { ... },
                    .setup_native_loop => |loop_info| { ... },
                    .stop => { ... },
                    .broadcast_state => { ... },
                    .none => {},
                }
            } else {
                // Current region was deleted - skip to next valid entry
                // ... deleted region handling ...
            }
        }
    }
}
```

**Line count:** 159 lines

### 1.3 Summary of Lines to Extract

| Block | Start Line | End Line | Line Count |
|-------|------------|----------|------------|
| Transport sync | 788 | 812 | 25 |
| Playlist tick | 814 | 972 | 159 |
| **Total** | - | - | **184** |

---

## 2. Dependency Analysis

### 2.1 Required Imports for playlist_tick.zig

```zig
const std = @import("std");
const reaper = @import("reaper.zig");
const logging = @import("logging.zig");
const transport = @import("transport.zig");
const playlist = @import("playlist.zig");
const markers = @import("markers.zig");
const ws_server = @import("ws_server.zig");
const tiered_state = @import("tiered_state.zig");
```

### 2.2 Parameters Required from Caller

The playlist tick functions need access to:

| Parameter | Type | Source in main.zig |
|-----------|------|-------------------|
| `playlist_state` | `*playlist.State` | `&g_playlist_state` |
| `transport_state` | `*const transport.State` | `high_result.transport_state` |
| `regions` | `[]const markers.Region` | `g_last_markers.regions` |
| `backend` | `*reaper.RealBackend` | `&backend` (local) |
| `tiered` | `*tiered_state.TieredArenas` | `tiered` |
| `shared_state` | `*ws_server.SharedState` | `shared_state` |

### 2.3 Globals Referenced

The code currently accesses these globals directly:

| Global | Usage | Strategy |
|--------|-------|----------|
| `g_playlist_state` | Playlist engine state (mutable) | Pass as parameter |
| `g_last_markers.regions` | Cached regions for lookups | Pass as parameter |
| `tiered` | Scratch allocator for JSON | Pass as parameter |
| `shared_state` | Broadcast state changes | Pass as parameter |
| `backend` | REAPER API calls (setCursorPos, setRepeat, etc.) | Pass as parameter |
| `current_transport` | Transport state from HIGH tier | Pass as parameter |

**Strategy:** All globals become explicit parameters. The function is designed to be generic over backend type to enable testing with mocks.

---

## 3. Interface Design

### 3.1 PlaylistTickContext Struct

```zig
/// Context for playlist engine tick operations.
/// Contains all state needed to sync and advance the playlist engine.
pub const PlaylistTickContext = struct {
    /// Playlist state (mutable - engine state is modified)
    playlist_state: *playlist.State,
    /// Current transport state from HIGH tier
    transport_state: *const transport.State,
    /// Cached regions for region lookups
    regions: []const markers.Region,
    /// Tiered arenas for scratch allocation
    tiered: *tiered_state.TieredArenas,
    /// WebSocket shared state for broadcasting
    shared_state: *ws_server.SharedState,

    /// Create a scratch allocator from the tiered arenas
    pub fn scratchAllocator(self: *const PlaylistTickContext) std.mem.Allocator {
        return self.tiered.scratchAllocator();
    }
};
```

### 3.2 Function Signatures

```zig
/// Sync playlist engine with external transport changes.
/// When the user pauses/stops REAPER transport outside our control,
/// we need to update the engine state to match.
///
/// Parameters:
/// - ctx: Playlist tick context with all required state
/// - backend: REAPER API backend for transport control
///
/// Returns: true if state changed (broadcast already sent)
pub fn syncWithTransport(
    ctx: *const PlaylistTickContext,
    backend: anytype,
) bool;

/// Advance playlist engine state based on transport position and regions.
/// Handles region transitions, looping, and playback control.
///
/// Parameters:
/// - ctx: Playlist tick context with all required state
/// - backend: REAPER API backend for transport control
///
/// This function only runs when the engine is playing.
/// Region lookups use the cached regions from MEDIUM tier.
pub fn tick(
    ctx: *const PlaylistTickContext,
    backend: anytype,
) void;
```

### 3.3 Usage from main.zig

After extraction, the playlist tick section in `doProcessing()` becomes:

```zig
const playlist_tick = @import("playlist_tick.zig");

// ... after subscription polling ...

// ========================================================================
// PLAYLIST ENGINE TICK - Extracted to playlist_tick.zig for testability
// ========================================================================

// Build playlist tick context
const playlist_ctx = playlist_tick.PlaylistTickContext{
    .playlist_state = &g_playlist_state,
    .transport_state = current_transport,
    .regions = g_last_markers.regions,
    .tiered = tiered,
    .shared_state = shared_state,
};

// Sync with external transport changes
_ = playlist_tick.syncWithTransport(&playlist_ctx, &backend);

// Advance playlist engine
playlist_tick.tick(&playlist_ctx, &backend);
```

---

## 4. The Extraction

### 4.1 Complete playlist_tick.zig

Create file at: `extension/src/playlist_tick.zig`

```zig
//! Playlist Engine Tick Module
//!
//! Extracted from main.zig doProcessing() to enable unit testing of
//! playlist engine behaviors in isolation.
//!
//! The playlist engine runs at 30Hz (HIGH tier) but relies on regions
//! from the MEDIUM tier (5Hz). This module uses cached regions passed
//! in via PlaylistTickContext to look up region bounds.
//!
//! Key behaviors:
//! - Transport sync: Detect when REAPER transport stops/pauses externally
//! - Region transitions: Advance to next entry when current region ends
//! - Loop management: Handle region looping and native REAPER loops
//! - Deleted regions: Skip to next valid entry when region is deleted

const std = @import("std");
const reaper = @import("reaper.zig");
const logging = @import("logging.zig");
const transport = @import("transport.zig");
const playlist = @import("playlist.zig");
const markers = @import("markers.zig");
const ws_server = @import("ws_server.zig");
const tiered_state = @import("tiered_state.zig");

/// Context for playlist engine tick operations.
/// Contains all state needed to sync and advance the playlist engine.
pub const PlaylistTickContext = struct {
    /// Playlist state (mutable - engine state is modified)
    playlist_state: *playlist.State,
    /// Current transport state from HIGH tier
    transport_state: *const transport.State,
    /// Cached regions for region lookups
    regions: []const markers.Region,
    /// Tiered arenas for scratch allocation
    tiered: *tiered_state.TieredArenas,
    /// WebSocket shared state for broadcasting
    shared_state: *ws_server.SharedState,

    /// Create a scratch allocator from the tiered arenas
    pub fn scratchAllocator(self: *const PlaylistTickContext) std.mem.Allocator {
        return self.tiered.scratchAllocator();
    }
};

/// Sync playlist engine with external transport changes.
/// When the user pauses/stops REAPER transport outside our control,
/// we need to update the engine state to match.
///
/// Returns: true if state changed and was broadcast
pub fn syncWithTransport(
    ctx: *const PlaylistTickContext,
    backend: anytype,
) bool {
    // Only sync if engine is active (playing or paused)
    if (!ctx.playlist_state.engine.isActive()) {
        return false;
    }

    const transport_playing = transport.PlayState.isPlaying(ctx.transport_state.play_state);
    const transport_stopped = ctx.transport_state.play_state == transport.PlayState.STOPPED;

    // Check if engine thinks it's playing but transport isn't
    if (ctx.playlist_state.engine.isPlaying() and !transport_playing) {
        if (transport_stopped) {
            // Transport stopped externally - stop engine
            _ = ctx.playlist_state.engine.stop();
            backend.setRepeat(false);
            backend.clearLoopPoints();
            logging.debug("Stopped playlist engine - transport stopped externally", .{});
        } else {
            // Transport paused - pause engine
            _ = ctx.playlist_state.engine.pause();
            logging.debug("Paused playlist engine - transport paused externally", .{});
        }

        // Broadcast state change
        const scratch = ctx.scratchAllocator();
        if (ctx.playlist_state.toJsonAlloc(scratch, ctx.regions)) |json| {
            ctx.shared_state.broadcast(json);
        } else |_| {}

        return true;
    }

    return false;
}

/// Find region bounds by region ID.
/// Returns null if region not found (deleted).
fn findRegionBounds(regions: []const markers.Region, region_id: i32) ?struct { start: f64, end: f64 } {
    for (regions) |*r| {
        if (r.id == region_id) {
            return .{ .start = r.start, .end = r.end };
        }
    }
    return null;
}

/// Get next entry info for the playlist engine tick.
fn getNextEntryInfo(
    playlist_entries: []const playlist.PlaylistEntry,
    current_idx: usize,
    entry_count: usize,
    regions: []const markers.Region,
) ?playlist.NextEntryInfo {
    if (current_idx + 1 >= entry_count) {
        return null;
    }

    const next = &playlist_entries[current_idx + 1];

    // Find next region's bounds
    for (regions) |*r| {
        if (r.id == next.region_id) {
            return playlist.NextEntryInfo{
                .loop_count = next.loop_count,
                .region_start = r.start,
                .region_end = r.end,
            };
        }
    }

    return null;
}

/// Advance playlist engine state based on transport position and regions.
/// Handles region transitions, looping, and playback control.
///
/// This function only runs when the engine is playing.
/// Region lookups use the cached regions from MEDIUM tier.
pub fn tick(
    ctx: *const PlaylistTickContext,
    backend: anytype,
) void {
    // Only tick when playing
    if (!ctx.playlist_state.engine.isPlaying()) {
        return;
    }

    const current_pos = ctx.transport_state.play_position;

    // Get current playlist
    const p = ctx.playlist_state.getPlaylist(ctx.playlist_state.engine.playlist_idx) orelse return;
    if (ctx.playlist_state.engine.entry_idx >= p.entry_count) return;

    const entry = &p.entries[ctx.playlist_state.engine.entry_idx];

    // Find current region bounds
    if (findRegionBounds(ctx.regions, entry.region_id)) |bounds| {
        // Region found - normal tick
        tickWithRegion(ctx, backend, p, entry, current_pos, bounds.start, bounds.end);
    } else {
        // Region was deleted - handle gracefully
        handleDeletedRegion(ctx, backend, p);
    }
}

/// Tick when current region is valid.
fn tickWithRegion(
    ctx: *const PlaylistTickContext,
    backend: anytype,
    p: *const playlist.Playlist,
    entry: *const playlist.PlaylistEntry,
    current_pos: f64,
    region_start: f64,
    region_end: f64,
) void {
    // Get next entry info if available
    const next_entry = getNextEntryInfo(
        p.entries[0..p.entry_count],
        ctx.playlist_state.engine.entry_idx,
        p.entry_count,
        ctx.regions,
    );

    // Calculate bar length for non-contiguous transition timing
    // bar_length = beats_per_bar * seconds_per_beat
    const bpm = ctx.transport_state.bpm;
    const beats_per_bar = ctx.transport_state.time_sig_num;
    const bar_length = if (bpm > 0) beats_per_bar * (60.0 / bpm) else 2.0;

    const action = ctx.playlist_state.engine.tick(
        current_pos,
        region_end,
        region_start,
        next_entry,
        p.entry_count,
        bar_length,
    );

    // Handle action
    switch (action) {
        .seek_to => |pos| {
            // Skip seek if already at target (contiguous regions)
            // This avoids audio hiccups when transitioning between
            // regions that share a boundary
            const distance = @abs(current_pos - pos);
            if (distance > 0.1) {
                backend.setCursorPos(pos);
            }
        },
        .setup_native_loop => |loop_info| {
            // Transition to new region with native looping
            // Check if this is a non-contiguous transition (needs seek)
            const approaching_contiguous = current_pos < loop_info.region_start and
                (loop_info.region_start - current_pos) < 0.2;
            const already_there = @abs(current_pos - loop_info.region_start) < 0.1;
            const needs_seek = !approaching_contiguous and !already_there;

            if (needs_seek) {
                // Non-contiguous transition - disable repeat first to prevent
                // REAPER from looping back to old region while we transition
                backend.setRepeat(false);
                backend.setCursorPos(loop_info.region_start);
            }
            // Set loop points to new region boundaries
            backend.setLoopPoints(loop_info.region_start, loop_info.region_end);
            // Enable repeat (re-enable after seek, or ensure it's on for contiguous)
            backend.setRepeat(true);
            // Note: Don't broadcast here - engine will broadcast when transition completes
        },
        .stop => {
            // Engine stopped - disable repeat and clear loop points
            backend.setRepeat(false);
            backend.clearLoopPoints();
            // Stop transport if playlist has stopAfterLast enabled
            if (p.stop_after_last) {
                backend.runCommand(reaper.Command.STOP);
            }
            // State will be broadcast via change detection
        },
        .broadcast_state => {
            // Immediate broadcast needed
            const scratch = ctx.scratchAllocator();
            if (ctx.playlist_state.toJsonAlloc(scratch, ctx.regions)) |json| {
                ctx.shared_state.broadcast(json);
            } else |_| {}
        },
        .none => {},
    }
}

/// Handle case where current region was deleted.
/// Skip to next valid entry or stop if none remain.
fn handleDeletedRegion(
    ctx: *const PlaylistTickContext,
    backend: anytype,
    p: *const playlist.Playlist,
) void {
    const entry = &p.entries[ctx.playlist_state.engine.entry_idx];
    logging.debug("Region {d} deleted, finding next valid entry", .{entry.region_id});

    // Find next entry with a valid region
    var next_valid_idx: ?usize = null;
    var next_bounds: ?struct { start: f64, end: f64 } = null;
    var search_idx = ctx.playlist_state.engine.entry_idx + 1;

    while (search_idx < p.entry_count) : (search_idx += 1) {
        const candidate = &p.entries[search_idx];
        if (findRegionBounds(ctx.regions, candidate.region_id)) |bounds| {
            next_valid_idx = search_idx;
            next_bounds = bounds;
            break;
        }
    }

    if (next_valid_idx) |valid_idx| {
        // Advance to valid entry
        const next_entry_data = &p.entries[valid_idx];
        ctx.playlist_state.engine.entry_idx = valid_idx;
        ctx.playlist_state.engine.loops_remaining = next_entry_data.loop_count;
        ctx.playlist_state.engine.current_loop_iteration = 1;
        ctx.playlist_state.engine.advance_after_loop = false;
        ctx.playlist_state.engine.next_loop_pending = false;

        // Set up loop for valid region
        if (next_bounds) |bounds| {
            backend.setCursorPos(bounds.start);
            backend.setLoopPoints(bounds.start, bounds.end);
        }

        logging.debug("Skipped to entry {d}", .{valid_idx});
    } else {
        // No valid entries remaining - stop
        _ = ctx.playlist_state.engine.stop();
        backend.setRepeat(false);
        backend.clearLoopPoints();
        logging.debug("No valid entries remaining, stopped playlist", .{});
    }

    // Broadcast state change
    const scratch = ctx.scratchAllocator();
    if (ctx.playlist_state.toJsonAlloc(scratch, ctx.regions)) |json| {
        ctx.shared_state.broadcast(json);
    } else |_| {}
}

// ============================================================================
// Tests
// ============================================================================

test "PlaylistTickContext.scratchAllocator returns valid allocator" {
    // Verify struct compiles correctly
    _ = PlaylistTickContext;
}

test "findRegionBounds returns null for missing region" {
    const regions = [_]markers.Region{
        .{ .id = 1, .start = 0.0, .end = 10.0, .name = .{} },
        .{ .id = 2, .start = 10.0, .end = 20.0, .name = .{} },
    };

    const result = findRegionBounds(&regions, 999);
    try std.testing.expect(result == null);
}

test "findRegionBounds returns bounds for existing region" {
    const regions = [_]markers.Region{
        .{ .id = 1, .start = 0.0, .end = 10.0, .name = .{} },
        .{ .id = 2, .start = 10.0, .end = 20.0, .name = .{} },
    };

    const result = findRegionBounds(&regions, 2);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(f64, 10.0), result.?.start);
    try std.testing.expectEqual(@as(f64, 20.0), result.?.end);
}
```

### 4.2 Edits to main.zig

#### 4.2.1 Add Import (after line 40)

Add this import after the `tier_polling` import:

```zig
const playlist_tick = @import("playlist_tick.zig");
```

**Edit location:** Line 41 (insert after `const tier_polling = @import("tier_polling.zig");`)

#### 4.2.2 Remove Transport Sync Block (Lines 788-812)

**Remove this block:**

```zig
    // Sync playlist engine with external transport changes
    // (user paused/stopped REAPER transport outside of our control)
    if (g_playlist_state.engine.isActive()) {
        const transport_playing = transport.PlayState.isPlaying(current_transport.play_state);
        const transport_stopped = current_transport.play_state == transport.PlayState.STOPPED;

        if (g_playlist_state.engine.isPlaying() and !transport_playing) {
            // Engine thinks it's playing but transport isn't
            if (transport_stopped) {
                _ = g_playlist_state.engine.stop();
                backend.setRepeat(false);
                backend.clearLoopPoints();
                logging.debug("Stopped playlist engine - transport stopped externally", .{});
            } else {
                // Transport paused
                _ = g_playlist_state.engine.pause();
                logging.debug("Paused playlist engine - transport paused externally", .{});
            }
            // Broadcast state change
            const scratch = tiered.scratchAllocator();
            if (g_playlist_state.toJsonAlloc(scratch, g_last_markers.regions)) |json| {
                shared_state.broadcast(json);
            } else |_| {}
        }
    }
```

#### 4.2.3 Remove Playlist Tick Block (Lines 814-972)

**Remove entire block starting with:**
```zig
    // Playlist engine tick (when playing)
    if (g_playlist_state.engine.isPlaying()) {
```

**Through the final closing brace** of the nested if statements (line 972).

#### 4.2.4 Insert New Playlist Tick Code

**Insert at line 788** (where transport sync was removed):

```zig
    // ========================================================================
    // PLAYLIST ENGINE TICK - Extracted to playlist_tick.zig for testability
    // ========================================================================

    // Build playlist tick context
    const playlist_ctx = playlist_tick.PlaylistTickContext{
        .playlist_state = &g_playlist_state,
        .transport_state = current_transport,
        .regions = g_last_markers.regions,
        .tiered = tiered,
        .shared_state = shared_state,
    };

    // Sync with external transport changes
    _ = playlist_tick.syncWithTransport(&playlist_ctx, &backend);

    // Advance playlist engine
    playlist_tick.tick(&playlist_ctx, &backend);
```

#### 4.2.5 Add Test Re-export

**Add to test block at end of main.zig:**

```zig
    _ = @import("playlist_tick.zig");
```

---

## 5. Verification Checklist

### 5.1 Build Commands

```bash
# Navigate to extension directory
cd "/Users/conor/Library/Application Support/REAPER/reaper_www_root/extension"

# Build the extension
zig build

# Run tests
zig build test

# Build with CSurf enabled (if applicable)
zig build -Dcsurf=true
```

### 5.2 Grep Checks for Dangling References

After extraction, verify no orphaned references exist:

```bash
# Ensure old playlist tick code is removed
grep -n "g_playlist_state.engine.isActive()" extension/src/main.zig
# Should return NO matches (logic now in playlist_tick.zig)

grep -n "transport_stopped = current_transport.play_state" extension/src/main.zig
# Should return NO matches

grep -n "Stopped playlist engine - transport stopped" extension/src/main.zig
# Should return NO matches (log message now in playlist_tick.zig)

grep -n "Region.*deleted, finding next valid entry" extension/src/main.zig
# Should return NO matches

# Verify new module is imported
grep -n "playlist_tick" extension/src/main.zig
# Should show import line and usage

# Verify PlaylistTickContext is used
grep -n "PlaylistTickContext" extension/src/main.zig
# Should show context creation
```

### 5.3 Functional Verification in REAPER

1. **Build and install extension**
   ```bash
   zig build && cp zig-out/lib/libreamo.dylib ~/.config/REAPER/UserPlugins/
   ```

2. **Launch REAPER with extension loaded**

3. **Test transport sync:**
   - Create a playlist with multiple entries
   - Start playlist playback
   - Press stop in REAPER (not via REAmo)
   - Verify playlist engine stops and state is broadcast
   - Restart playlist and press pause in REAPER
   - Verify playlist engine pauses and state is broadcast

4. **Test region transitions:**
   - Create a playlist with contiguous regions
   - Start playback and verify smooth transitions
   - Create a playlist with non-contiguous regions
   - Verify seeks happen between regions

5. **Test looping:**
   - Set loop_count > 1 on a playlist entry
   - Verify region loops the correct number of times
   - Verify transition to next entry after loops complete

6. **Test deleted region handling:**
   - Start playlist playback on a specific region
   - While playing, delete that region in REAPER
   - Verify engine skips to next valid entry
   - Delete all remaining regions
   - Verify engine stops gracefully

7. **Test stopAfterLast:**
   - Enable stopAfterLast on a playlist
   - Play to the end of the playlist
   - Verify REAPER transport stops after last entry

---

## 6. Testability Plan

### 6.1 Unit Test Strategy

The extracted module enables testing playlist engine behaviors without running the full `doProcessing()` loop.

#### Mock Types Needed

```zig
// test_mocks.zig (or inline in playlist_tick.zig tests)

pub const MockBackend = struct {
    cursor_pos: f64 = 0,
    loop_start: f64 = 0,
    loop_end: f64 = 0,
    repeat_enabled: bool = false,
    commands_run: std.ArrayList(i32),

    pub fn setCursorPos(self: *MockBackend, pos: f64) void {
        self.cursor_pos = pos;
    }

    pub fn setLoopPoints(self: *MockBackend, start: f64, end: f64) void {
        self.loop_start = start;
        self.loop_end = end;
    }

    pub fn clearLoopPoints(self: *MockBackend) void {
        self.loop_start = 0;
        self.loop_end = 0;
    }

    pub fn setRepeat(self: *MockBackend, enabled: bool) void {
        self.repeat_enabled = enabled;
    }

    pub fn runCommand(self: *MockBackend, cmd: i32) void {
        self.commands_run.append(cmd) catch {};
    }
};

pub const MockSharedState = struct {
    broadcasts: std.ArrayList([]const u8),

    pub fn broadcast(self: *MockSharedState, json: []const u8) void {
        self.broadcasts.append(json) catch {};
    }
};

pub const MockTieredArenas = struct {
    allocator: std.mem.Allocator,

    pub fn scratchAllocator(self: *MockTieredArenas) std.mem.Allocator {
        return self.allocator;
    }
};
```

#### Example Unit Tests

```zig
test "syncWithTransport stops engine when transport stopped externally" {
    // Setup playlist with engine playing
    var playlist_state = playlist.State{};
    playlist_state.engine.play_state = .playing;

    // Setup transport as stopped
    var transport_state = transport.State{};
    transport_state.play_state = transport.PlayState.STOPPED;

    var mock_tiered = MockTieredArenas{ .allocator = std.testing.allocator };
    var mock_shared = MockSharedState{ .broadcasts = std.ArrayList([]const u8).init(std.testing.allocator) };
    defer mock_shared.broadcasts.deinit();

    const ctx = PlaylistTickContext{
        .playlist_state = &playlist_state,
        .transport_state = &transport_state,
        .regions = &.{},
        .tiered = &mock_tiered,
        .shared_state = &mock_shared,
    };

    var mock_backend = MockBackend{};

    const changed = syncWithTransport(&ctx, &mock_backend);

    try std.testing.expect(changed);
    try std.testing.expect(!playlist_state.engine.isPlaying());
    try std.testing.expect(!mock_backend.repeat_enabled);
}

test "syncWithTransport pauses engine when transport paused externally" {
    // Setup playlist with engine playing
    var playlist_state = playlist.State{};
    playlist_state.engine.play_state = .playing;

    // Setup transport as paused
    var transport_state = transport.State{};
    transport_state.play_state = transport.PlayState.PAUSED;

    // ... similar setup ...

    const changed = syncWithTransport(&ctx, &mock_backend);

    try std.testing.expect(changed);
    try std.testing.expectEqual(playlist.EngineState.paused, playlist_state.engine.play_state);
}

test "tick skips to next entry when region deleted" {
    // Setup playlist with 3 entries, region for entry 0 deleted
    var playlist_state = playlist.State{};
    // ... populate playlist with entries ...
    playlist_state.engine.entry_idx = 0;
    playlist_state.engine.play_state = .playing;

    // Regions list WITHOUT region_id for entry 0
    const regions = [_]markers.Region{
        .{ .id = 2, .start = 10.0, .end = 20.0, .name = .{} }, // entry 1
        .{ .id = 3, .start = 20.0, .end = 30.0, .name = .{} }, // entry 2
    };

    // ... setup context ...

    tick(&ctx, &mock_backend);

    // Should have skipped to entry 1
    try std.testing.expectEqual(@as(usize, 1), playlist_state.engine.entry_idx);
}

test "tick stops when all regions deleted" {
    // Setup playlist with entries, but no regions exist
    var playlist_state = playlist.State{};
    // ... populate playlist ...
    playlist_state.engine.play_state = .playing;

    const regions: []const markers.Region = &.{}; // Empty

    // ... setup context ...

    tick(&ctx, &mock_backend);

    try std.testing.expect(!playlist_state.engine.isActive());
}
```

### 6.2 Integration Test Considerations

For full integration tests:

1. **Create test project** with known region configuration
2. **Create playlists** with various configurations (loops, contiguous/non-contiguous)
3. **Connect test WebSocket client** that receives playlist state broadcasts
4. **Manipulate REAPER transport** via API and verify engine syncs correctly
5. **Delete regions mid-playback** and verify graceful handling

---

## 7. Rollback Plan

### 7.1 Git Revert (Preferred)

If the extraction causes issues:

```bash
# Find the commit hash of the extraction
git log --oneline -5

# Revert the commit
git revert <commit-hash>

# Or soft reset to undo (keeps changes as uncommitted)
git reset --soft HEAD~1
```

### 7.2 Manual Restoration

If git history is unavailable:

1. **Delete** `extension/src/playlist_tick.zig`

2. **Edit main.zig:**
   - Remove `const playlist_tick = @import("playlist_tick.zig");`
   - Remove the new PlaylistTickContext construction code
   - Restore the original inline playlist tick code (see Section 1 for exact code)
   - Remove test re-export for playlist_tick

3. **Rebuild:**
   ```bash
   cd extension && zig build
   ```

### 7.3 Partial Rollback

If only one function has issues:

1. Keep `playlist_tick.zig` with working functions
2. Move the problematic function back inline in `main.zig`
3. Comment out the call to the problematic function

---

## 8. Implementation Sequence

Execute these steps in order:

### Step 1: Create playlist_tick.zig

```bash
# Create the new file
touch "/Users/conor/Library/Application Support/REAPER/reaper_www_root/extension/src/playlist_tick.zig"
```

Copy the complete content from Section 4.1 into this file.

### Step 2: Add Import to main.zig

Edit line 41 to add:
```zig
const playlist_tick = @import("playlist_tick.zig");
```

### Step 3: Build and Fix Any Import Errors

```bash
cd "/Users/conor/Library/Application Support/REAPER/reaper_www_root/extension"
zig build 2>&1 | head -50
```

Fix any missing imports or type mismatches in `playlist_tick.zig`.

### Step 4: Replace Inline Playlist Tick Code

1. Remove lines 788-972 (transport sync + playlist tick blocks)
2. Insert the new playlist tick code from Section 4.2.4 at line 788

### Step 5: Add Test Re-export

Add to test block at end of main.zig:
```zig
    _ = @import("playlist_tick.zig");
```

### Step 6: Build and Test

```bash
zig build test
zig build
```

### Step 7: Run Grep Verification

Execute all grep checks from Section 5.2.

### Step 8: Functional Test in REAPER

Follow the functional verification steps from Section 5.3.

### Step 9: Commit (User Action)

Suggested commit message:
```
refactor(main): extract playlist tick to playlist_tick.zig

Phase 4 of main.zig refactoring. Extracts playlist engine tick logic
from doProcessing() into a dedicated module:

- Transport sync: Detect external stop/pause and update engine state
- Region transitions: Advance to next entry when current region ends
- Loop management: Handle region looping and native REAPER loops
- Deleted regions: Skip to next valid entry when region is deleted

Introduces PlaylistTickContext struct to bundle dependencies and
enable future unit testing of playlist engine behaviors.

No functional changes - pure code movement.

Lines extracted: ~185
New module: playlist_tick.zig (~280 lines)
main.zig: ~1221 -> ~1040 lines
```

---

## 9. Summary Metrics

| Metric | Value |
|--------|-------|
| Lines extracted from main.zig | ~185 |
| New module size | ~280 lines (including docs/tests) |
| main.zig before | ~1221 lines |
| main.zig after | ~1040 lines |
| Risk level | Low |
| New public types | 1 (PlaylistTickContext) |
| New public functions | 2 (syncWithTransport, tick) |
| Helper functions | 3 (internal) |
| Behavior changes | None |
| New dependencies | None |

### Risk Factors

1. **Low complexity** - Self-contained logic with clear boundaries
2. **Transport interaction** - Must correctly detect play/pause/stop states
3. **Region lookups** - Uses cached regions, must handle deleted regions
4. **Backend calls** - Multiple REAPER API calls for transport control
5. **State mutation** - Engine state is modified directly

### Mitigation

1. Build after each edit to catch errors early
2. Run full test suite before REAPER testing
3. Verify with grep that all old code is removed
4. Test transport sync scenarios (external stop/pause)
5. Test deleted region handling extensively
6. Keep rollback plan ready for quick recovery

---

## Appendix A: Line-by-Line Mapping

| Original Lines | New Location | Notes |
|---------------|--------------|-------|
| 788-812 | `syncWithTransport()` | 25 lines - transport sync |
| 814-836 | `tick()` + `tickWithRegion()` | Entry setup, region lookup |
| 838-853 | `getNextEntryInfo()` | Helper function |
| 855-869 | `tickWithRegion()` | Engine tick call |
| 871-919 | `tickWithRegion()` | Action handling |
| 920-972 | `handleDeletedRegion()` | Deleted region handling |

## Appendix B: Type Dependencies

```
playlist_tick.zig
+-- std
+-- reaper.zig
|   +-- Command.STOP
+-- logging.zig
+-- transport.zig
|   +-- State
|   +-- PlayState
+-- playlist.zig
|   +-- State
|   +-- Playlist
|   +-- PlaylistEntry
|   +-- NextEntryInfo
+-- markers.zig
|   +-- Region
+-- ws_server.zig
|   +-- SharedState
+-- tiered_state.zig
    +-- TieredArenas
```

## Appendix C: Backend Method Requirements

The `backend` parameter must support these methods (already present on `reaper.RealBackend`):

| Method | Signature | Purpose |
|--------|-----------|---------|
| `setCursorPos` | `fn(self: *, pos: f64) void` | Seek to position |
| `setLoopPoints` | `fn(self: *, start: f64, end: f64) void` | Set loop region |
| `clearLoopPoints` | `fn(self: *) void` | Remove loop region |
| `setRepeat` | `fn(self: *, enabled: bool) void` | Enable/disable repeat |
| `runCommand` | `fn(self: *, cmd: i32) void` | Run REAPER action |

This makes the module testable with mock backends that implement these same methods.

## Appendix D: Key Differences from Phase 3

| Aspect | Phase 3 (tier_polling) | Phase 4 (playlist_tick) |
|--------|------------------------|-------------------------|
| Code blocks | 6+ scattered across tiers | 2 contiguous blocks |
| Mutable state | Extensive (hashes, buffers, caches) | Single (playlist_state.engine) |
| Return values | `HighTierResult` struct | `bool` (sync) + `void` (tick) |
| Timing logic | Conditional on frame counter | Always runs (30Hz) |
| Dependencies | 22 imports | 8 imports |
| Complexity | Medium-High | Low |
| Risk level | Medium-High | Low |
