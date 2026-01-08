# Playlist Engine Design Document

This document describes the backend implementation of the Playlist (Cue List) feature in REAmo.

## Table of Contents

- [Purpose](#purpose)
- [Architecture Overview](#architecture-overview)
- [Key Components](#key-components)
- [Data Flow](#data-flow)
- [Playback Engine State Machine](#playback-engine-state-machine)
- [Native Looping Strategy](#native-looping-strategy)
- [Cross-Tier Region Access](#cross-tier-region-access)
- [Persistence](#persistence)
- [REAPER APIs Used](#reaper-apis-used)
- [Memory Management](#memory-management)
- [Gotchas & Edge Cases](#gotchas--edge-cases)
- [Command Handlers](#command-handlers)
- [JSON Events](#json-events)
- [Live Modification Behavior](#live-modification-behavior)
- [Testing](#testing)

---

## Purpose

The playlist engine provides a **cue list** feature for live performance:

- Create ordered lists of REAPER regions
- Each entry specifies loop count (-1=infinite, 0=skip, N=times)
- Seamless transitions between regions using REAPER's native looping
- Manual or automatic advancement through the playlist
- Persistent storage per-project via EXTSTATE

**Use case:** A musician defines song sections as REAPER regions (Intro, Verse, Chorus, etc.), then builds playlists for different performances (e.g., "Friday Gig", "Short Set") that specify which sections to play and how many times to loop each.

---

## Architecture Overview

```text
┌─────────────────────────────────────────────────────────────────────┐
│  Frontend (React)                                                   │
│  - PlaylistPanel: CRUD operations on playlists/entries              │
│  - Playback controls: Play, Pause, Stop, Next, Prev                │
│  - Visual feedback: current entry, loops remaining, progress        │
└───────────────────────────────┬─────────────────────────────────────┘
                                │ WebSocket (commands + events)
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Command Handlers (commands/playlist.zig)                           │
│  - 15 handlers for CRUD and playback                                │
│  - Validates input, updates State, persists to EXTSTATE             │
│  - Sets up REAPER looping via API calls                             │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Playlist State (playlist.zig)                                      │
│                                                                     │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐              │
│  │  Playlist[]  │  │   Engine     │  │ Persistence  │              │
│  │  - entries   │  │  - state     │  │  - serialize │              │
│  │  - name      │  │  - tick()    │  │  - loadAll() │              │
│  │  - settings  │  │  - actions   │  │  - saveAll() │              │
│  └──────────────┘  └──────────────┘  └──────────────┘              │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│  main.zig Timer Loop (30Hz)                                         │
│  - Calls engine.tick() every frame when playing                     │
│  - Processes Action returns (seek, setup_native_loop, stop)         │
│  - Syncs with external transport changes (user paused REAPER)       │
│  - Broadcasts state changes to clients                              │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Key Components

### 1. Entry (`playlist.Entry`)

Represents a single item in a playlist:

```zig
pub const Entry = struct {
    region_id: i32,    // REAPER region display ID (markrgnindexnum)
    loop_count: i32,   // -1=infinite, 0=skip, N=times
};
```

**Note:** `region_id` is the REAPER **display ID** (shown in the region manager), not the internal index. This is stable across project saves.

### 2. Playlist (`playlist.Playlist`)

An ordered collection of entries:

```zig
pub const Playlist = struct {
    name: [MAX_NAME_LEN]u8,
    name_len: usize,
    entries: [MAX_ENTRIES_PER_PLAYLIST]Entry,  // MAX = 64
    entry_count: usize,
    stop_after_last: bool,  // Stop transport when playlist ends
};
```

**Operations:** `addEntry`, `insertEntry`, `removeEntry`, `reorderEntry`

### 3. Engine (`playlist.Engine`)

Pure state machine for playback logic — **no REAPER API calls**:

```zig
pub const Engine = struct {
    state: EngineState,           // idle | playing | paused
    playlist_idx: usize,          // Which playlist is active
    entry_idx: usize,             // Current entry in playlist
    loops_remaining: i32,         // Loops left on current entry
    current_loop_iteration: i32,  // 1-indexed, which loop we're on
    advance_after_loop: bool,     // For infinite loops: advance on next wrap
    prev_pos: f64,                // Previous tick position (for wrap detection)
    next_loop_pending: bool,      // True when proactive setup done, awaiting transition
};
```

The engine is **deliberately pure** — it takes transport position as input and returns `Action` values that the caller (main.zig) executes. This makes it fully unit-testable without mocking REAPER.

### 4. Action (`playlist.Action`)

Return type from `engine.tick()`:

```zig
pub const Action = union(enum) {
    none,                          // No action needed
    seek_to: f64,                  // Seek to position (non-contiguous transition)
    setup_native_loop: NativeLoopInfo,  // Set loop points and enable repeat
    stop,                          // Playlist complete, stop transport
    broadcast_state,               // State changed, notify clients
};
```

### 5. State (`playlist.State`)

Container for all playlists + engine + persistence tracking:

```zig
pub const State = struct {
    playlists: [MAX_PLAYLISTS]Playlist,  // MAX = 16
    playlist_count: usize,
    engine: Engine,
    dirty: bool,         // Needs persistence
    dirty_since: f64,    // Timestamp for debounce
};
```

**Methods:** `addPlaylist`, `removePlaylist`, `getPlaylist`, `reset`, `markDirty`, `flushIfNeeded`, `saveAll`, `loadAll`

---

## Data Flow

### Playback Start

```text
1. Client sends: playlist/play {playlistIdx: 0}
2. handlePlay() validates playlist exists and has entries
3. Finds first valid entry (region exists)
4. Calls engine.playFromEntry() → sets engine state
5. Sets up REAPER:
   - setCursorPos(region_start)
   - setLoopPoints(region_start, region_end)
   - setRepeat(true)
   - runCommand(PLAY)
6. Returns success to client
```

### Tick Loop (main.zig)

Every 30Hz tick while `engine.isPlaying()`:

```text
1. Get current transport position
2. Look up current entry's region bounds in g_last_markers cache
3. Look up next entry's region bounds (if any)
4. Call engine.tick(current_pos, region_end, region_start, next_entry, ...)
5. Process returned Action:
   - setup_native_loop: Set REAPER loop points, seek if non-contiguous
   - broadcast_state: Send playlist JSON to all clients
   - stop: Disable repeat, clear loop points, stop transport
```

### Loop Transition (Proactive Setup)

```text
Position: 0────────────────────────9.85──9.9──10.0
                                    ↑     ↑     ↑
                          Proactive zone  │     │
                          (150ms before)  │     │
                                          │     └── Region end (REAPER wraps here)
                                          └──────── We set NEXT region's loop points

When position enters proactive zone (150ms before region end):
1. engine.tick() returns setup_native_loop with NEXT region's bounds
2. main.zig sets loop points to next region
3. engine.next_loop_pending = true
4. REAPER plays to end and seamlessly loops into next region
5. Next tick detects we're in new region → engine advances entry_idx
```

This **proactive setup** enables seamless transitions without audible gaps.

---

## Playback Engine State Machine

```text
                    ┌─────────────────────────────────────────┐
                    │                                         │
                    ▼                                         │
              ┌──────────┐                                    │
         ┌───▶│   IDLE   │◀───────────────────────┐          │
         │    └──────────┘                         │          │
         │         │                               │          │
         │         │ play() / playFromEntry()     │          │
         │         ▼                               │          │
         │    ┌──────────┐                         │          │
         │    │ PLAYING  │◀────────────┐          │          │
         │    └──────────┘             │          │          │
         │         │                    │          │          │
         │    pause()                   │ unpause()│          │
         │         │                    │          │          │
         │         ▼                    │          │          │
         │    ┌──────────┐             │          │          │
         │    │  PAUSED  │─────────────┘          │          │
         │    └──────────┘                         │          │
         │         │                               │          │
         │         │ stop()                        │ stop()   │
         │         │                               │          │
         │         ▼                               │          │
         └─────────┘                               │          │
                                                   │          │
                    tick() returns .stop ──────────┘          │
                    (last entry completes)                    │
                                                              │
                    External: user stops REAPER ──────────────┘
```

### Tick Logic Details

```text
tick(current_pos, region_end, region_start, next_entry, entry_count, bar_length)
│
├── If state != PLAYING → return .none
│
├── If next_loop_pending (proactive setup was done):
│   ├── Check if we've transitioned into next region
│   │   ├── Same region (duplicate entry): detect wrap-around
│   │   └── Different region: check if pos is in next region's bounds
│   └── If transitioned: advance entry_idx, clear pending, return .broadcast_state
│
├── Detect loop wrap-around (prev_pos near end, current_pos near start):
│   ├── If loops_remaining > 1: decrement, increment iteration, broadcast
│   └── If loops_remaining == -1 (infinite): increment iteration, broadcast
│
├── Check if should advance (advance_after_loop flag OR loops_remaining == 1):
│   ├── If last entry: return .stop when near end
│   └── If not last entry and approaching end:
│       ├── Contiguous regions: trigger at 150ms before end
│       └── Non-contiguous regions: trigger at final measure + 100ms buffer
│       └── Set next_loop_pending = true, return .setup_native_loop
│
└── return .none
```

---

## Native Looping Strategy

The engine uses **REAPER's native loop points** rather than manual seeking:

### Why Native Looping?

1. **Seamless audio** — No gaps at transitions
2. **Accurate timing** — REAPER handles sample-accurate wrapping
3. **Works with smooth seek** — Respects user's smooth seek settings
4. **Less CPU** — No need to poll position at audio-rate precision

### Approach

```zig
// When starting/transitioning to a region:
api.setLoopPoints(region_start, region_end);
api.setRepeat(true);

// When playlist ends:
api.setRepeat(false);
api.clearLoopPoints();
```

### Contiguous vs Non-Contiguous Transitions

**Contiguous regions** (R1 ends at 10.0, R2 starts at 10.0):
- Just change loop points proactively
- REAPER seamlessly continues into new region
- No seek needed

**Non-contiguous regions** (R1 ends at 10.0, R2 starts at 15.0):
- Use smooth seek timing (final measure + buffer)
- Set new loop points AND seek to new region
- REAPER's "play to end of N measures" setting handles the transition

---

## Cross-Tier Region Access

### The Problem

```text
Tier         Frequency    Contains
────────────────────────────────────
HIGH         30Hz         Transport, tracks, meters
MEDIUM       5Hz          Regions, markers, items, FX, sends
LOW          1Hz          Tempo map, track skeleton
```

The playlist engine runs at **30Hz** (HIGH tier) but regions are polled at **5Hz** (MEDIUM tier). How does the engine look up region bounds?

### The Solution: Cached Region State

```zig
// main.zig globals
var g_last_markers: markers.State = .{};
var g_last_markers_buf: [markers.MAX_MARKERS]markers.Marker = undefined;
var g_last_regions_buf: [markers.MAX_REGIONS]markers.Region = undefined;
```

At initialization and after each MEDIUM tier poll:

```zig
// Copy region state for playlist engine access
const cur_markers_len = medium_state.markers.len;
@memcpy(g_last_markers_buf[0..cur_markers_len], medium_state.markers[0..cur_markers_len]);
g_last_markers.markers = g_last_markers_buf[0..cur_markers_len];
// ... same for regions
```

The playlist engine then reads from `g_last_markers.regions` at 30Hz. This data may be up to 200ms stale (5Hz polling), but that's acceptable for region boundary lookups.

### Memory Layout

```text
┌──────────────────────────────────────────────────────────────────┐
│  MEDIUM Tier Arena (double-buffered, swaps at 5Hz)               │
│  ├── markers.State.markers → slice into arena                    │
│  └── markers.State.regions → slice into arena                    │
└────────────────────────┬─────────────────────────────────────────┘
                         │
                         │ Copy on MEDIUM tick
                         ▼
┌──────────────────────────────────────────────────────────────────┐
│  Static Buffers (g_last_markers_buf, g_last_regions_buf)         │
│  ├── Fixed-size arrays [MAX_MARKERS], [MAX_REGIONS]              │
│  └── Persist across arena swaps                                  │
└──────────────────────────────────────────────────────────────────┘
                         │
                         │ Referenced by
                         ▼
┌──────────────────────────────────────────────────────────────────┐
│  g_last_markers.regions → slice into static buffer               │
│  (Available to playlist engine at 30Hz)                          │
└──────────────────────────────────────────────────────────────────┘
```

---

## Persistence

Playlists are stored per-project using REAPER's **ProjExtState** API.

### Storage Format

```text
Key: "REAmo/PlaylistCount"
Value: "3"

Key: "REAmo/Playlist_0"
Value: "Friday Gig|S:1|1,4|2,2|3,1"
        ↑          ↑   ↑
        │          │   └── Entries: regionId,loopCount (pipe-separated)
        │          └────── Settings: S:1 = stopAfterLast true
        └───────────────── Name (escaped if contains |)

Key: "REAmo/Playlist_1"
Value: "Short Set|S:0|1,2|3,-1"
```

### Serialization (`Playlist.serialize`)

```zig
// Pipe-delimited format: Name|Settings|Entry1|Entry2|...
// Name has pipes escaped with backslash
// Settings: S:1 (stop after last) or S:0
// Entries: regionId,loopCount
pub fn serialize(self: *const Playlist, buf: []u8) ?[]const u8 {
    // Write name (escape pipes)
    for (self.name[0..self.name_len]) |c| {
        if (c == '|' or c == '\\') writer.writeByte('\\');
        writer.writeByte(c);
    }
    // Write settings
    writer.print("|S:{d}", .{@as(u8, if (self.stop_after_last) 1 else 0)});
    // Write entries
    for (0..self.entry_count) |i| {
        writer.print("|{d},{d}", .{ entry.region_id, entry.loop_count });
    }
}
```

### Load/Save Operations

```zig
// On project load / project change:
if (g_playlist_state.dirty) {
    g_playlist_state.saveAll(&backend);  // Flush pending changes first
}
g_playlist_state.reset();            // Clear stale data
g_playlist_state.loadAll(&backend);  // Load from new project's ProjExtState

// On playlist modification (via commands):
state.markDirty(api.timePrecise());  // Mark for deferred persistence

// In timer loop (5Hz MEDIUM tier):
_ = g_playlist_state.flushIfNeeded(&backend, backend.timePrecise());
// Flushes: immediately if not playing, after 1s debounce if playing
```

### Project Change Detection

When the project changes (detected via `projectStateChangeCount` resetting to 1):

```zig
// Stop playlist engine if playing
if (g_playlist_state.engine.isActive()) {
    _ = g_playlist_state.engine.stop();
    backend.clearLoopPoints();
}

// Flush any pending changes to old project before loading new
if (g_playlist_state.dirty) {
    g_playlist_state.saveAll(&backend);
    g_playlist_state.dirty = false;
}

// Reload playlists from new project
g_playlist_state.reset();
g_playlist_state.loadAll(&backend);
```

---

## REAPER APIs Used

| Function | Purpose |
|----------|---------|
| `GetSet_LoopTimeRange2(proj, isSet, isLoop, &start, &end, allowAuto)` | Get/set loop points |
| `GetSetRepeat(mode)` | Get/set repeat mode (-1=get, 0=off, 1=on) |
| `SetEditCurPos(time, moveview, seekplay)` | Seek to position |
| `Main_OnCommand(PLAY/PAUSE/STOP, 0)` | Transport control |
| `EnumProjectMarkers3(...)` | Enumerate regions by index |
| `GetProjExtState(proj, section, key, buf, buflen)` | Read per-project state |
| `SetProjExtState(proj, section, key, value)` | Write per-project state |
| `TimeMap_GetTimeSigAtTime(...)` | Get bar length for transition timing |

### Loop Points API Detail

```c
// REAPER API signature:
void GetSet_LoopTimeRange2(
    ReaProject* proj,   // NULL = current project
    bool isSet,         // true = set, false = get
    bool isLoop,        // true = loop points, false = time selection
    double* startOut,   // Start time (seconds)
    double* endOut,     // End time (seconds)
    bool allowAuto      // true = allow auto-seek
);

// Our wrapper (raw.zig):
pub fn setLoopPoints(self: *const Api, start: f64, end: f64) void {
    var s = start;
    var e = end;
    self.getSetLoopTimeRange2.?(null, true, true, &s, &e, false);
}

pub fn clearLoopPoints(self: *const Api) void {
    self.setLoopPoints(0, 0);  // Setting to 0,0 clears
}
```

---

## Memory Management

### Playlist State Location

```zig
// main.zig - Static storage (not arena-allocated)
var g_playlist_state: playlist.State = .{};
var g_last_playlist: playlist.State = .{};  // For change detection
```

**Why static?** Playlist state is:
1. Modified by commands (not polled from REAPER)
2. Needs to persist across arena swaps
3. Relatively small (~50KB for 16 playlists × 64 entries)

### JSON Serialization

```zig
// Uses scratch arena for JSON output
pub fn toJsonAlloc(self: *const State, allocator: std.mem.Allocator, regions: ?[]const markers.Region) ![]const u8 {
    var buf: [8192]u8 = undefined;  // Stack buffer for formatting
    const json = self.toJson(&buf, regions) orelse return error.JsonSerializationFailed;
    return allocator.dupe(u8, json);  // Copy to scratch arena
}

// In main.zig:
const scratch = tiered.scratchAllocator();
if (g_playlist_state.toJsonAlloc(scratch, g_last_markers.regions)) |json| {
    shared_state.broadcast(json);
}
```

The scratch arena is reset every frame, so the JSON string lives only for the broadcast duration.

### Region Cache Buffers

```zig
// Fixed-size static buffers for cross-tier region access
var g_last_markers_buf: [markers.MAX_MARKERS]markers.Marker = undefined;
var g_last_regions_buf: [markers.MAX_REGIONS]markers.Region = undefined;
```

These are copied from MEDIUM tier arenas at 5Hz. Size: ~256 × 170 bytes = ~43KB each.

---

## Gotchas & Edge Cases

### 1. Deleted Regions

A user might delete a region that's referenced in a playlist entry.

**Detection:** When serializing JSON, check each entry's `region_id` against current regions:

```zig
const is_deleted = if (regions) |regs| blk: {
    for (regs) |r| {
        if (r.id == e.region_id) break :blk false;
    }
    break :blk true;
} else false;

if (is_deleted) {
    // Include "deleted": true in JSON
}
```

**Playback:** `findFirstValidEntry()` skips entries with deleted regions.

### 2. Duplicate Region Entries

A playlist might contain the same region twice (e.g., Chorus → Verse → Chorus).

**Problem:** After proactive setup, how do we detect we've "entered" the next region when it has the same bounds?

**Solution:** Detect wrap-around instead of position check:

```zig
const is_same_region = @abs(next_e.region_start - region_start) < BOUNDARY_EPSILON and
    @abs(next_e.region_end - region_end) < BOUNDARY_EPSILON;

const transitioned = if (is_same_region) blk: {
    // Detect wrap: prev_pos near end, current_pos near start
    break :blk self.prev_pos > region_end - BOUNDARY_EPSILON and
        current_pos < region_start + BOUNDARY_EPSILON;
} else blk: {
    // Different region: check if we're inside its bounds
    break :blk current_pos >= next_e.region_start - BOUNDARY_EPSILON and
        current_pos < next_e.region_end + BOUNDARY_EPSILON;
};
```

### 3. External Transport Control

User might pause/stop REAPER directly (not through our commands).

**Detection:** Compare engine state with actual transport state:

```zig
if (g_playlist_state.engine.isPlaying() and !transport_playing) {
    if (transport_stopped) {
        _ = g_playlist_state.engine.stop();
        backend.setRepeat(false);
        backend.clearLoopPoints();
    } else {
        _ = g_playlist_state.engine.pause();
    }
    // Broadcast state change
}
```

### 4. Boundary Epsilon

REAPER's position reporting has jitter (~5-10ms). We use `BOUNDARY_EPSILON = 0.05` (50ms) for position comparisons:

```zig
// Don't use exact equality for position checks
if (current_pos > region_end - BOUNDARY_EPSILON)  // Approaching end
```

### 5. Non-Contiguous Transition Timing

For regions that don't share a boundary, we need to trigger early enough for smooth seek:

```zig
// Trigger when clearly inside the final measure (not right at boundary)
const MEASURE_ENTRY_BUFFER: f64 = 0.1;  // 100ms past measure start
const final_measure_start = region_end - bar_length;
const trigger_point = final_measure_start + MEASURE_ENTRY_BUFFER;
const was_before = self.prev_pos < trigger_point;
const now_past = current_pos >= trigger_point;
break :blk was_before and now_past;  // Edge detection
```

The 100ms buffer ensures we're clearly IN the final measure, so REAPER counts the current measure for "play to end of N measures" smooth seek.

### 6. Empty Playlists

Cannot play an empty playlist:

```zig
if (p.entry_count == 0) {
    response.err("EMPTY_PLAYLIST", "Cannot play empty playlist");
    return;
}
```

### 7. Region ID vs Index

REAPER's `EnumProjectMarkers3` returns markers/regions by **enumeration index** (0, 1, 2...), but the `markrgnindexnumber` (display ID) can be any number (1, 5, 42...).

**We store display IDs** because they're stable across project saves. The `findRegionBounds()` helper iterates all regions to find the one with matching display ID.

---

## Command Handlers

Located in `commands/playlist.zig`:

| Command | Handler | Description |
|---------|---------|-------------|
| `playlist/create` | `handleCreate` | Create new playlist with name |
| `playlist/delete` | `handleDelete` | Delete playlist by index |
| `playlist/rename` | `handleRename` | Rename playlist |
| `playlist/addEntry` | `handleAddEntry` | Add region to playlist (optional atIdx) |
| `playlist/removeEntry` | `handleRemoveEntry` | Remove entry from playlist |
| `playlist/setLoopCount` | `handleSetLoopCount` | Set entry's loop count |
| `playlist/setStopAfterLast` | `handleSetStopAfterLast` | Set playlist stop behavior |
| `playlist/reorderEntry` | `handleReorderEntry` | Move entry within playlist |
| `playlist/play` | `handlePlay` | Start playlist or resume if paused |
| `playlist/playFromEntry` | `handlePlayFromEntry` | Start from specific entry |
| `playlist/pause` | `handlePause` | Pause playback |
| `playlist/stop` | `handleStop` | Stop and reset |
| `playlist/next` | `handleNext` | Advance to next entry |
| `playlist/prev` | `handlePrev` | Go to previous entry |
| `playlist/advanceAfterLoop` | `handleAdvanceAfterLoop` | Set flag to advance after current loop |

---

## JSON Events

### Playlist State Event

Broadcast on state changes (entry add/remove, playback state change, etc.):

```json
{
  "type": "event",
  "event": "playlist",
  "payload": {
    "playlists": [
      {
        "name": "Friday Gig",
        "entries": [
          {"regionId": 1, "loopCount": 4},
          {"regionId": 2, "loopCount": 2},
          {"regionId": 99, "loopCount": 1, "deleted": true}
        ],
        "stopAfterLast": true
      }
    ],
    "activePlaylistIndex": 0,
    "currentEntryIndex": 1,
    "loopsRemaining": 2,
    "currentLoopIteration": 1,
    "isPlaylistActive": true,
    "isPaused": false,
    "advanceAfterLoop": false
  }
}
```

**Notes:**
- `deleted: true` appears when an entry's region no longer exists
- `loopsRemaining: null` for infinite loops
- `activePlaylistIndex: null` when no playlist is active

---

## Live Modification Behavior

### Persistence Strategy: Deferred with Debounce

Modifications are **buffered in-memory** and flushed to ProjExtState with smart debouncing:

```text
Command received → Update g_playlist_state (in-memory) → markDirty(timestamp)

Timer loop (5Hz):
  if dirty AND (not playing OR elapsed >= 1 second):
    saveAll() → ProjExtState
    dirty = false
```

**Benefits:**
- Immediate persistence when not playing (changes saved within 200ms)
- Debounced 1-second delay during playback (reduces disk I/O)
- Flush before project change (no data loss)

```zig
// State struct:
dirty: bool = false,
dirty_since: f64 = 0,

pub fn markDirty(self: *State, current_time: f64) void {
    if (!self.dirty) {
        self.dirty = true;
        self.dirty_since = current_time;
    }
}

pub fn flushIfNeeded(self: *State, api: anytype, current_time: f64) bool {
    if (!self.dirty) return false;
    const should_flush = if (!self.engine.isPlaying())
        true
    else
        (current_time - self.dirty_since) >= PERSIST_DEBOUNCE_SECS;
    // ...
}
```

### Entry Index Adjustment During Playback

The engine maintains `entry_idx` pointing to the current entry. When entries are modified during playback, the index is automatically adjusted:

**Removal (handleRemoveEntry):**
```zig
if (state.engine.isActive() and state.engine.playlist_idx == playlist_idx_usize) {
    if (entry_idx_usize < state.engine.entry_idx) {
        state.engine.entry_idx -= 1;  // Shift back
    } else if (entry_idx_usize == state.engine.entry_idx) {
        // Skip to next entry (which shifted into this index after removal)
        if (state.engine.entry_idx < p.entry_count) {
            const next_entry = &p.entries[state.engine.entry_idx];
            state.engine.loops_remaining = next_entry.loop_count;
            state.engine.current_loop_iteration = 1;
            // Set up native looping on next region...
        } else {
            _ = state.engine.stop();  // No more entries
        }
    }
}
```

**Insertion (handleAddEntry with atIdx):**
```zig
if (state.engine.isActive() and
    state.engine.playlist_idx == playlist_idx_usize and
    at_usize <= state.engine.entry_idx)
{
    state.engine.entry_idx += 1;  // Shift forward
}
```

**Reorder (handleReorderEntry):**
```zig
if (current_entry_idx == from_idx_usize) {
    state.engine.entry_idx = to_idx_usize;  // Follow the moved entry
} else if (from_idx_usize < to_idx_usize) {
    if (current_entry_idx > from_idx_usize and current_entry_idx <= to_idx_usize) {
        state.engine.entry_idx -= 1;  // Entry shifted back
    }
} else {
    if (current_entry_idx >= to_idx_usize and current_entry_idx < from_idx_usize) {
        state.engine.entry_idx += 1;  // Entry shifted forward
    }
}
```

### Current Entry Loop Count Sync

When modifying the loop count of the **currently playing entry**, `engine.loops_remaining` is synchronized:

```zig
// handleSetLoopCount:
if (state.engine.isPlaying() and
    state.engine.playlist_idx == playlist_idx_usize and
    state.engine.entry_idx == entry_idx_usize)
{
    if (loop_count == -1) {
        state.engine.loops_remaining = -1;  // Switch to infinite
    } else if (loop_count == 0) {
        state.engine.loops_remaining = 1;   // Finish current, then advance
    } else {
        // Preserve progress: new_count - completed_iterations
        const completed = state.engine.current_loop_iteration - 1;
        const remaining = loop_count - @as(i32, @intCast(completed));
        state.engine.loops_remaining = if (remaining > 0) remaining else 1;
    }
}
```

**Examples:**
- User on loop 3 of 4, changes to 6 → `loops_remaining` = 4 (6 - 2 completed)
- User on loop 2 of 2, changes to 1 → `loops_remaining` = 1 (graceful: finish current loop)
- User sets to 0 (skip) → `loops_remaining` = 1 (finish current, then advance; not 0 which would hang)

### Performance & Efficiency Analysis

#### Memory Allocation Pattern

**Playlist State:** Static storage (NOT arena-allocated)
```zig
// main.zig - lives for entire extension lifetime
var g_playlist_state: playlist.State = .{};  // ~10KB static
```

**Why not arena?** Playlists are modified by commands (not polled), must persist across arena swaps, and are small enough that static allocation is simpler.

**JSON Serialization:**
```zig
pub fn toJsonAlloc(self: *const State, allocator: std.mem.Allocator, regions: ?[]const markers.Region) ![]const u8 {
    // Allocate from arena based on actual content size
    const estimated_size = 512 + self.playlist_count * (256 + 64 * 60);
    const buf_size = @max(estimated_size, 4096);
    const buf = allocator.alloc(u8, buf_size) catch return error.OutOfMemory;
    const json = self.toJson(buf, regions) orelse return error.JsonSerializationFailed;
    return json;  // Already in arena, no copy needed
}
```

**Design:** Allocates directly from scratch arena with size proportional to content. No stack buffer intermediate, no extra copy.

#### Region Lookup Efficiency

**Current: O(n) linear scan at 30Hz**
```zig
// main.zig tick loop - runs twice per tick (current + next entry)
for (g_last_markers.regions) |*r| {
    if (r.id == entry.region_id) {
        region_start = r.start;
        region_end = r.end;
        break;
    }
}
```

**Cost analysis:**
- MAX_REGIONS = 256
- 2 scans per tick × 30Hz = 60 scans/second
- Each scan: up to 256 comparisons
- Total: up to 15,360 comparisons/second

**Is this a problem?** No. Integer comparisons are extremely fast (~1 CPU cycle each). Even at 256 regions, this is negligible compared to other work in the tick loop.

**If it became a problem:** Build a hashmap from region_id → region on MEDIUM tier poll:
```zig
var g_region_lookup: std.AutoHashMap(i32, *const markers.Region) = undefined;
// Rebuild at 5Hz when regions change
```

But this adds complexity for minimal gain. Linear scan is fine for <= 256 regions.

#### Deleted Region Detection in JSON

**Current: O(entries × regions) nested loop**
```zig
for (0..p.entry_count) |j| {
    const is_deleted = if (regions) |regs| blk: {
        for (regs) |r| {  // O(n) scan for each entry
            if (r.id == e.region_id) break :blk false;
        }
        break :blk true;
    } else false;
}
```

**Worst case:** 16 playlists × 64 entries × 256 regions = 262,144 comparisons per JSON serialization.

**Is this a problem?** Only if JSON is generated frequently. Currently:
- On command (occasional) ✓
- On state change via `eql()` check (occasional) ✓
- NOT at 30Hz ✓

**Optimization if needed:** Pre-build a region ID set:
```zig
var region_exists: std.AutoHashMap(i32, void) = undefined;
for (regions) |r| region_exists.put(r.id, {});
// Then O(1) lookup per entry
```

#### Summary Table

| Operation | Frequency | Complexity | Current Cost | Concern? |
|-----------|-----------|------------|--------------|----------|
| `engine.tick()` | 30Hz | O(1) | ~10 CPU cycles | No |
| Region lookup (current) | 30Hz | O(n) | ~256 comparisons | No |
| Region lookup (next) | 30Hz | O(n) | ~256 comparisons | No |
| `eql()` change detection | 30Hz | O(playlists × entries) | ~1024 comparisons | No |
| `toJson()` formatting | On change | O(playlists × entries) | ~1024 iterations | No |
| Deleted region check | On change | O(entries × regions) | ~16K comparisons | Marginal |
| `toJsonAlloc()` | On change | O(json_length) | Arena alloc | No |
| `savePlaylist()` | Debounced | O(entry_count) | ProjExtState write | No |

**No 30Hz persistence writes:** The tick loop only reads state and broadcasts JSON changes. ProjExtState writes are debounced (immediate when not playing, 1s delay during playback).

#### Large Region Count Handling

The design handles large region counts well:
- Region cache is fixed-size: `[MAX_REGIONS]Region` where MAX_REGIONS = 256
- Playlist entries reference regions by ID, not pointer (survives cache refresh)
- Linear scans are bounded by MAX_REGIONS, not unbounded

**Limitation:** Cannot have more than 256 regions in a project. This is a constants.zig limit, not a playlist engine limit. Increasing would affect memory footprint of `g_last_regions_buf`.

### What Works Correctly

All major live modification scenarios are now handled:

- **Current entry loop count changes:** Synced to `engine.loops_remaining` immediately
- **Next entry loop count changes:** Read fresh from playlist state each tick
- **Entry removal during playback:** Index adjusted; current entry removed skips to next (or stops if last)
- **Entry insertion during playback:** Index adjusted when inserting before current position
- **Entry reorder during playback:** Index follows the current entry to its new position
- **Adding entries at end:** Safe, doesn't affect current `entry_idx`
- **Playlist removal during playback:** Stops engine if removing active playlist
- **stopAfterLast changes:** Read from playlist state when last entry completes
- **Persistence:** Debounced writes reduce disk I/O during rapid edits

---

## Testing

The engine is fully unit-tested in `playlist.zig`:

```zig
// Core engine tests
test "Engine tick - proactive loop setup on final loop (contiguous)" { ... }
test "Engine tick - proactive loop setup on final loop (non-contiguous)" { ... }
test "Engine infinite loop with advance after" { ... }
test "Engine tick - duplicate region entries" { ... }
test "Playlist serialize/deserialize" { ... }
test "State toJson with deleted region detection" { ... }

// Gap fix tests - live modification behavior
test "Gap 1: loop count sync - modifying current entry updates loops_remaining" { ... }
test "Gap 1: loop count sync - changing to infinite" { ... }
test "Gap 1: loop count sync - reducing below current iteration lets loop finish" { ... }
test "Gap 1: loop count sync - setting to zero (skip) still finishes current" { ... }
test "Gap 2: remove entry before current - index shifts back" { ... }
test "Gap 2: remove entry after current - no index change" { ... }
test "Gap 2: remove current entry - skip to next" { ... }
test "Gap 3: insert entry before current - index shifts forward" { ... }
test "Gap 3: insert entry after current - no index change" { ... }
test "Gap 3: reorder - move current entry to new position" { ... }
test "Gap 3: reorder - entry moved forward past current" { ... }
test "Gap 3: reorder - entry moved backward past current" { ... }
```

Run tests: `make test-extension`

The engine's pure state machine design (no REAPER calls in Engine) makes it easy to test boundary conditions and state transitions.
