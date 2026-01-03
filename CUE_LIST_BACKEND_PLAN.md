# Cue List — Backend Implementation Plan

**Status:** 🚧 READY FOR IMPLEMENTATION
**Last Updated:** 2026-01-03

This is a living document tracking the Cue List backend implementation. The backend provides playlist persistence, playback engine, and optional SWS import.

> **Research complete.** See [research/CUE_LIST_RESEARCH.md](research/CUE_LIST_RESEARCH.md) for SWS analysis.

---

## Quick Context for New Sessions

**Read these files first:**
- `DEVELOPMENT.md` — Architecture, conventions, FFI validation layer pattern
- `extension/API.md` — Protocol format, existing events (especially `regions` event)
- `features/CUE_LIST_FEATURE.md` — Full feature spec with protocol definitions
- `BACKEND_PLAN_TEMPLATE.md` — How to use this document

**Key architecture concepts:**
- `raw.zig` — Pure C bindings, returns what REAPER returns
- `RealBackend` / `MockBackend` — Abstraction for testing
- Timer callback runs at ~30Hz — playlist engine hooks into this
- EXTSTATE for persistence (`SetExtState`, `GetExtState`)
- Regions already polled — playlist references region IDs from existing `regions` event

**Frontend dependency:**
- Frontend already receives `regions` event with `{id, name, startTime, endTime, color}`
- Playlist entries reference `regionId` which maps to `id` in regions event
- Frontend handles time display formatting, region lookup by ID

---

## Testing with WebSocket

```bash
# Get credentials
TOKEN=$(curl -s "http://localhost:8099/_/GET/EXTSTATE/Reamo/SessionToken" | awk '{print $4}')
PORT=$(curl -s "http://localhost:8099/_/GET/EXTSTATE/Reamo/WebsocketPort" | awk '{print $4}')

# Create playlist
/bin/bash -c '{ echo '"'"'{"type":"hello","clientVersion":"1.0.0","protocolVersion":1,"token":"'$TOKEN'"}'"'"'; sleep 0.1; echo '"'"'{"type":"command","command":"playlist/create","name":"Test Set","id":"1"}'"'"'; sleep 0.3; } | /opt/homebrew/bin/websocat ws://localhost:'$PORT' 2>&1 | head -20'

# Add entry (after getting regionId from regions event)
# ... playlist/addEntry with regionId, loopCount
```

---

## Scope & Features

### Commands

| Command | Purpose | Parameters |
|---------|---------|------------|
| `playlist/create` | Create new playlist | `name` |
| `playlist/delete` | Delete playlist | `playlistIdx` |
| `playlist/rename` | Rename playlist | `playlistIdx`, `name` |
| `playlist/addEntry` | Add region to playlist | `playlistIdx`, `regionId`, `loopCount`, `atIdx?` |
| `playlist/removeEntry` | Remove entry | `playlistIdx`, `entryIdx` |
| `playlist/setLoopCount` | Change loop count | `playlistIdx`, `entryIdx`, `loopCount` |
| `playlist/reorderEntry` | Move entry | `playlistIdx`, `fromIdx`, `toIdx` |
| `playlist/play` | Start playlist (or resume if paused) | `playlistIdx` |
| `playlist/playFromEntry` | Start from specific entry | `playlistIdx`, `entryIdx` |
| `playlist/pause` | Pause playlist (remembers position) | (none) |
| `playlist/stop` | Exit playlist mode entirely | (none) |
| `playlist/next` | Advance to next entry | (none) |
| `playlist/prev` | Go to previous entry | (none) |
| `playlist/advanceAfterLoop` | Advance after current loop completes | (none) |
| `playlist/importSws` | Import SWS playlist | `swsPlaylistIdx` |

### Events

| Event | Purpose | Trigger |
|-------|---------|---------|
| `playlist` | Full playlist state | On change, on connect |
| `swsPlaylistDetected` | SWS playlists found in RPP | On project load |

### State Fields (in `playlist` event)

| Field | Type | Description |
|-------|------|-------------|
| `playlists` | `Playlist[]` | All playlists |
| `playlists[].name` | `string` | Playlist name |
| `playlists[].entries` | `Entry[]` | Ordered entries |
| `playlists[].entries[].regionId` | `number` | REAPER region ID |
| `playlists[].entries[].loopCount` | `number` | -1=infinite, 0=skip, N=times |
| `activePlaylistIndex` | `number?` | Currently playing playlist (null if none) |
| `currentEntryIndex` | `number?` | Currently playing entry (null if none) |
| `loopsRemaining` | `number?` | Loops left on current entry |
| `currentLoopIteration` | `number?` | Which loop we're on (1-indexed) |
| `isPlaylistActive` | `boolean` | Playlist engine active (playing or paused) |
| `isPaused` | `boolean` | Playlist paused (vs actively playing) |
| `advanceAfterLoop` | `boolean` | Flag: will advance after current loop |

---

## Design Decisions

### Playlist Storage: Project EXTSTATE

**Decision:** Store playlists using `SetProjExtState` / `GetProjExtState` (project-scoped).

**Research confirmed:**
- `SetProjExtState(proj, extname, key, value)` — saves with RPP file
- `GetProjExtState(proj, extname, key, buf, buf_sz)` — retrieves
- Pass `NULL` for `proj` to use active project
- Data persists in RPP file and restores on project load

**Critical limitation:** Values must be **single-line strings**. Newlines cause truncation.

**Schema:**
```
ExtName: "Reamo"
Key: "Playlist_0", "Playlist_1", etc.
Value: Pipe-delimited string (no JSON newlines)

Key: "PlaylistCount"
Value: Number as string
```

**Serialization format (pipe-delimited):**
```
PlaylistName|regionId,loopCount|regionId,loopCount|...
```

Example: `Friday Gig|1,4|2,2|3,1` = playlist "Friday Gig" with 3 entries

**Trade-offs:**
- ~16KB limit via web interface (practical testing shows larger works via API)
- Pipe parsing simpler than JSON, avoids newline issues
- wyhash for change detection (not JSON comparison)

### Playlist Engine: Timer Callback Integration

**Decision:** Add playlist monitoring to existing 30Hz timer callback.

**Rationale:**
- Already polling transport position
- 30Hz = 33ms resolution, acceptable for region boundary detection
- No additional threads/timers

**Implementation:**
```zig
// In processTimerCallback, after transport polling:
if (playlist_engine.active) {
    playlist_engine.tick(current_play_position);
}
```

### Boundary Detection: End Position with Tolerance

**Decision:** Detect region end at `region.endTime - epsilon` (50ms early).

**Rationale:**
- Accounts for polling jitter (could be up to 33ms late)
- Seek happens slightly before actual end, giving time to settle
- Prevents overshoot into next region

**SWS bug to avoid:** Regions ending at exactly the same time as the next region begins can be skipped. Our epsilon approach should handle this, but unit tests must verify.

**Alternative considered:** Check if position > endTime. Risk: miss the boundary if poll happens after end.

### Seeking: SetEditCurPos2 with seekplay=true

**Decision:** Use `SetEditCurPos2(NULL, pos, true, true)` for region transitions.

**Parameters:**
- `proj=NULL` — active project
- `time` — target position in seconds
- `moveview=true` — scroll arrange view (visual feedback that playlist mode is active)
- `seekplay=true` — jump playback to new position

**Research confirmed:** SWS uses `SetEditCurPos2` with `moveview=true`. No crossfade/smoothing.

**Known limitation:** Brief audio gap (~50-100ms) during seek. Acceptable for v1.

### Region ID Stability

**Decision:** Use display IDs (`markrgnindexnum` from `EnumProjectMarkers3`), NOT GUIDs.

**Research findings:**
- SWS uses display IDs (known limitation, documented as "kind of a hack")
- GUID approach initially seemed better, BUT:
  - Reamo's region editor "reset to default color" deletes/recreates region → new GUID
  - No API to preserve/set GUID on recreation
  - Display IDs are intuitive for users ("Region 1 is Region 1")

**Trade-offs accepted:**
- "Renumber all markers/regions" action will break playlist references
- This is rare edge case, unlikely during performance
- User can undo if needed
- SWS has same limitation, users cope

**Risk:** If user deletes a region, playlist entries become orphaned.

**Mitigation:**
- On playlist load AND every broadcast, validate regionIds exist
- Mark missing entries as `"valid": false` in event payload
- Frontend shows "Unknown region" warning (matches SWS behavior)
- Allow removal of invalid entries

### Loop Count Values

| Value | Meaning |
|-------|---------|
| `-1` | Infinite loop (never auto-advance) |
| `0` | Skip this entry |
| `1-N` | Play N times, then advance |

**Note:** Infinite loop requires manual `playlist/next` or `playlist/stop` to exit.

### SWS Import: Read-Only, On-Demand

**Decision:** Parse SWS playlists from RPP file, don't modify SWS data.

**Rationale:**
- SWS stores in `<EXTENSIONS>` block, not accessible via API
- Modifying RPP while project is open is risky
- Import creates Reamo copy, original untouched

**Implementation:**
- Read project path via `GetProjectPath()`
- Parse RPP file for `<S&M_RGN_PLAYLIST` blocks
- Send `swsPlaylistDetected` event
- User explicitly imports via `playlist/importSws`

---

## C API Functions

```c
// Already available (verify in raw.zig)
double GetPlayPosition();           // Current playback position
int GetPlayState();                 // 0=stopped, 1=playing, 2=paused, 4=recording
int EnumProjectMarkers3(ReaProject* proj, int idx, bool* isrgnOut, double* posOut,
                        double* rgnendOut, const char** nameOut, int* markrgnindexnumOut,
                        int* colorOut);  // Already used for regions event

// Seeking (research confirmed SWS uses this)
void SetEditCurPos2(ReaProject* proj, double time, bool moveview, bool seekplay);
// Use: SetEditCurPos2(NULL, targetTime, true, true)

// Project EXTSTATE (for playlist persistence)
int SetProjExtState(ReaProject* proj, const char* extname, const char* key, const char* value);
int GetProjExtState(ReaProject* proj, const char* extname, const char* key, char* buf, int buf_sz);
// Pass NULL for proj = active project. Values are single-line only!

// For SWS import (stretch goal)
void GetProjectPath(char* bufOut, int bufOut_sz);
// Then: std.fs.openFile for RPP parsing (not REAPER API)
```

---

## Implementation Phases

### Phase 0: Verify Existing Bindings
- [ ] Check raw.zig for `GetPlayPosition`, `GetPlayState` (likely exist)
- [ ] Check raw.zig for `EnumProjectMarkers3` (used by regions, should exist)
- [ ] Check raw.zig for `SetEditCurPos` or `SetEditCurPos2`
- [ ] Document what's missing before adding new bindings

**Files:** `extension/src/reaper/raw.zig`

### Phase 1: raw.zig — New Bindings
- [ ] Add `SetEditCurPos2` function pointer + wrapper (if not exists)
- [ ] Add `SetProjExtState` function pointer + wrapper
- [ ] Add `GetProjExtState` function pointer + wrapper
- [ ] Add `GetProjectPath` function pointer + wrapper (for SWS import, can defer)
- [ ] Load all in `Api.load()`
- [ ] **BUILD & TEST:** Verify ProjExtState read/write works

**Files:** `extension/src/reaper/raw.zig`

### Phase 2: Playlist Types
- [ ] Create `extension/src/playlist.zig`
- [ ] Define `PlaylistEntry` struct: `region_id: i32`, `loop_count: i32`
- [ ] Define `Playlist` struct: `name: [128]u8`, `entries: [64]PlaylistEntry`, `entry_count: u8`
- [ ] Define `PlaylistState` struct: `playlists: [16]Playlist`, `playlist_count: u8`, engine state fields
- [ ] Add `eql()` methods for change detection
- [ ] Add `toJson()` for serialization
- [ ] Add `fromJson()` for deserialization (EXTSTATE loading)

**Files:** `extension/src/playlist.zig`

**Limits (compile-time constants):**
| Resource | Limit | Rationale |
|----------|-------|-----------|
| Playlists | 16 | Reasonable for setlist management |
| Entries per playlist | 64 | Covers long sets |
| Playlist name | 128 chars | Matches track name |

### Phase 3: Playlist Persistence (ProjExtState)
- [ ] Implement `serializePlaylist(playlist) -> []u8` (pipe-delimited, no newlines)
- [ ] Implement `deserializePlaylist(buf) -> Playlist`
- [ ] Implement `savePlaylistToProjExtState(idx)`
- [ ] Implement `loadPlaylistFromProjExtState(idx)`
- [ ] Implement `loadAllPlaylists()` on extension init / project load
- [ ] Add to RealBackend: `projExtStateSet`, `projExtStateGet`
- [ ] Add to MockBackend with in-memory map
- [ ] **BUILD & TEST:** Create playlist, save project, reload, verify persisted

**Files:** `extension/src/playlist.zig`, `reaper/real.zig`, `reaper/mock/`

### Phase 4: Playlist CRUD Commands
- [ ] Create `commands/playlist.zig`
- [ ] Implement `playlist/create` — add to state, save to ProjExtState
- [ ] Implement `playlist/delete` — remove from state, clear ProjExtState key
- [ ] Implement `playlist/rename` — update state, save to ProjExtState
- [ ] Implement `playlist/addEntry` — validate regionId exists, add to entries
- [ ] Implement `playlist/removeEntry` — remove from entries
- [ ] Implement `playlist/setLoopCount` — update entry
- [ ] Implement `playlist/reorderEntry` — move entry in array
- [ ] Register all in `registry.zig`
- [ ] **BUILD & TEST:** Create, modify, delete playlists via WebSocket

**Files:** `extension/src/commands/playlist.zig`, `commands/registry.zig`

### Phase 5: Playlist Event Broadcasting
- [ ] Add playlist state to polling/event system
- [ ] Broadcast `playlist` event on connect (initial state)
- [ ] Broadcast `playlist` event on any playlist change
- [ ] Include all fields: playlists, activePlaylistIndex, currentEntryIndex, loopsRemaining, isPlaying
- [ ] **BUILD & TEST:** Verify frontend receives playlist state

**Files:** `extension/src/playlist.zig`, `extension/src/main.zig`

### Phase 6: Playback Engine — Core Logic
- [ ] Add `PlaylistEngine` struct with state: `active`, `playlist_idx`, `entry_idx`, `loops_remaining`
- [ ] Implement `start(playlistIdx, entryIdx)` — set state, seek to region start
- [ ] Implement `stop()` — clear active state
- [ ] Implement `tick(currentPosition)` — boundary detection + seeking
- [ ] Implement `advanceToNext()` — move to next entry or stop
- [ ] Implement `goToPrev()` — move to previous entry
- [ ] Hook into timer callback
- [ ] **BUILD & TEST:** Manual play, verify auto-advance at region end

**Files:** `extension/src/playlist.zig`

### Phase 7: Playback Commands
- [ ] Implement `playlist/play` — start engine from entry 0
- [ ] Implement `playlist/playFromEntry` — start engine from specific entry
- [ ] Implement `playlist/stop` — stop engine
- [ ] Implement `playlist/next` — advance entry (manual override)
- [ ] Implement `playlist/prev` — go back entry
- [ ] Register in `registry.zig`
- [ ] **BUILD & TEST:** Full playback flow via WebSocket

**Files:** `extension/src/commands/playlist.zig`, `commands/registry.zig`

### Phase 8: Edge Case Handling
- [ ] Handle deleted region (entry references non-existent region)
- [ ] Handle empty playlist (play command should no-op or error)
- [ ] Handle transport stop by user (pause playlist engine? continue on resume?)
- [ ] Handle transport started externally while playlist active (what to do?)
- [ ] Handle project switch (clear playlist engine state)
- [ ] **BUILD & TEST:** Each edge case manually

**Files:** `extension/src/playlist.zig`

### Phase 9: SWS Import (Optional/Stretch)
- [ ] Implement `getProjectPath()` wrapper
- [ ] Implement RPP file parser for `<S&M_RGN_PLAYLIST` blocks
- [ ] Decode SWS region IDs (strip `0x40000000` flag)
- [ ] Validate region IDs against current project regions
- [ ] Send `swsPlaylistDetected` event on project load
- [ ] Implement `playlist/importSws` command
- [ ] **BUILD & TEST:** Load project with SWS playlists, verify detection and import

**Files:** `extension/src/sws_import.zig`, `commands/playlist.zig`

### Phase 10: Documentation
- [ ] Update `API.md` — playlist event, all commands
- [ ] Update `PLANNED_FEATURES.md` — mark Cue List backend done
- [ ] Update this plan document
- [ ] Add playlist limits to API.md Limits table

**Files:** `extension/API.md`, `PLANNED_FEATURES.md`, `CUE_LIST_BACKEND_PLAN.md`

---

## JSON Output Format

### `playlist` Event

```json
{
  "type": "event",
  "event": "playlist",
  "payload": {
    "playlists": [
      {
        "name": "Friday Gig",
        "entries": [
          {"regionId": 1, "loopCount": 1, "valid": true},
          {"regionId": 2, "loopCount": 4, "valid": true},
          {"regionId": 99, "loopCount": 1, "valid": false}
        ]
      }
    ],
    "activePlaylistIndex": 0,
    "currentEntryIndex": 1,
    "loopsRemaining": 3,
    "isPlaying": true
  }
}
```

**Note:** `valid: false` indicates region no longer exists. Frontend should show warning.

### `swsPlaylistDetected` Event

```json
{
  "type": "event",
  "event": "swsPlaylistDetected",
  "payload": {
    "playlists": [
      {
        "name": "With infinite",
        "entries": [
          {"regionId": 1, "loopCount": -1},
          {"regionId": 4, "loopCount": 4}
        ]
      }
    ]
  }
}
```

---

## Commands Reference

| Command | Parameters | Response | Notes |
|---------|------------|----------|-------|
| `playlist/create` | `name: string` | `{success, playlistIdx}` | Returns new playlist index |
| `playlist/delete` | `playlistIdx: int` | `{success}` | Stops playback if active |
| `playlist/rename` | `playlistIdx, name` | `{success}` | |
| `playlist/addEntry` | `playlistIdx, regionId, loopCount, atIdx?` | `{success, entryIdx}` | `atIdx` optional, defaults to end |
| `playlist/removeEntry` | `playlistIdx, entryIdx` | `{success}` | |
| `playlist/setLoopCount` | `playlistIdx, entryIdx, loopCount` | `{success}` | |
| `playlist/reorderEntry` | `playlistIdx, fromIdx, toIdx` | `{success}` | |
| `playlist/play` | `playlistIdx` | `{success}` | Starts from entry 0, or resumes if paused |
| `playlist/playFromEntry` | `playlistIdx, entryIdx` | `{success}` | |
| `playlist/pause` | (none) | `{success}` | Remembers position |
| `playlist/stop` | (none) | `{success}` | Exits playlist mode |
| `playlist/next` | (none) | `{success}` | No-op if not active |
| `playlist/prev` | (none) | `{success}` | |
| `playlist/advanceAfterLoop` | (none) | `{success}` | Sets flag, clears after advance |
| `playlist/importSws` | `swsPlaylistIdx` | `{success, playlistIdx}` | Creates new Reamo playlist |

---

## Open Questions (For Research/Discussion)

### Q1: Transport Interaction

When user manually stops transport while playlist is active, should we:
- **A)** Pause playlist engine, resume on transport play
- **B)** Stop playlist engine entirely
- **C)** Keep playlist engine state, let user manually resume with `playlist/play`

**Leaning:** Option A — feels most natural. Pause = pause playlist. Play = continue where left off.

### Q2: External Transport Start

If user starts transport (not via playlist) while playlist is active, should we:
- **A)** Let playlist engine continue monitoring (may cause unexpected seeks)
- **B)** Stop playlist engine
- **C)** Ignore — playlist only seeks when it detects boundary

**Leaning:** Option C — playlist engine is passive. Only seeks at boundaries. If user manually navigates, playlist just waits at current entry until boundary detection kicks in.

### Q3: Playlist Persistence Scope

Should playlists persist:
- **A)** Per-project (in project EXTSTATE)
- **B)** Globally (in global EXTSTATE)
- **C)** Both (user choice)

**Leaning:** Option A — setlists are project-specific. Global playlists could reference regions that don't exist.

### Q4: Region Validation Timing

When should we validate that regionIds in playlist still exist:
- **A)** On playlist load from EXTSTATE
- **B)** On every `playlist` event broadcast
- **C)** On playback start
- **D)** All of the above

**Leaning:** Option B — always send current validity so frontend can show warnings. Lightweight check.

### Q5: Infinite Loop Exit

When entry has `loopCount: -1` (infinite), how does user exit:
- **A)** `playlist/next` advances to next entry
- **B)** `playlist/stop` stops entirely
- **C)** Both work

**Answer:** Option C — both should work. Next advances, stop exits.

---

## State Machine: Playlist Engine

```
                         ┌─────────────┐
                         │    IDLE     │
                         │active=false │
                         └──────┬──────┘
                                │ playlist/play
                                │ playlist/playFromEntry
                                ▼
                         ┌─────────────┐
         ┌──────────────►│  PLAYING    │◄──────────────┐
         │               │active=true  │               │
         │               │paused=false │               │
         │               └──────┬──────┘               │
         │                      │                      │
         │ playlist/play        │                      │ playlist/next
         │ (resume)             │                      │ playlist/prev
         │                      │                      │ (or boundary)
         │               ┌──────┴──────┐               │
         │               │             │               │
         │    playlist/  │   boundary  │  playlist/    │
         │    pause      │   detected  │  advanceAfterLoop
         │               │             │  (sets flag)  │
         │               ▼             ▼               │
         │        ┌──────────┐  ┌──────────┐          │
         │        │ PAUSED   │  │ SEEKING  │──────────┘
         │        │paused=   │  │(transient│
         └────────│true      │  │ state)   │
                  └────┬─────┘  └──────────┘
                       │
                       │ playlist/stop
                       ▼
                  ┌─────────────┐
                  │    IDLE     │
                  └─────────────┘

Notes:
- SEEKING is transient (seek happens, immediately back to PLAYING)
- advanceAfterLoop sets flag, advance happens at next boundary
- playlist/stop from any state → IDLE
- Last entry + boundary → auto IDLE (playlist complete)
```

---

## Progress Log

| Date | Phase | Notes |
|------|-------|-------|
| 2026-01-03 | Phase 0 | Planning document created from template |
| 2026-01-03 | Review | User feedback incorporated: dedicated playlist controls, pause/resume, advanceAfterLoop, wyhash, testable state machine, research query added |
| 2026-01-03 | Research | SWS analysis complete (see research/CUE_LIST_RESEARCH.md). Key decisions: use display IDs not GUIDs, SetProjExtState for persistence, pipe-delimited format, SetEditCurPos2 with moveview=true |

---

## Notes & Gotchas

- **Region IDs vs indices:** REAPER's `EnumProjectMarkers3` returns both `idx` (enumeration index) and `markrgnindexnumOut` (the actual ID shown in REAPER UI). We use the display ID, not the enumeration index.
- **SWS region ID encoding:** SWS adds `0x40000000` flag to region IDs. Strip with `& 0x3FFFFFFF`.
- **ProjExtState single-line only:** Values MUST NOT contain newlines — causes truncation. Use pipe-delimited format.
- **ProjExtState size:** ~16KB limit via web interface, larger works via direct API.
- **SetEditCurPos2 during playback:** Causes brief audio discontinuity (~50-100ms). Acceptable for v1.
- **Contiguous region bug:** SWS has issue where regions ending exactly at next region start can skip. Use epsilon (50ms) for boundary detection.
- **Infinite loop + empty playlist:** If only entry is infinite, `next` should stop (no next entry).
- **Zero entries:** `playlist/play` on empty playlist should return error, not crash.
- **Region color reset:** Reamo's region editor deletes/recreates region when resetting to default color. This changes the GUID (hence we use display IDs, not GUIDs).

---

## Research Query for External Claude

Copy the block below to a research Claude for investigation:

````markdown
# Cue List Backend Research Query

We're implementing a playlist/cue list feature for a REAPER extension. Before implementation, we need to understand how SWS (the gold-standard REAPER extension) handles several edge cases.

## Context

- Building a Zig-based REAPER extension with WebSocket API
- Playlist = ordered list of region references with loop counts
- Playback engine monitors position and seeks to next region at boundaries
- Need to match SWS behavior where sensible

## Research Questions

### 1. Region ID Stability

SWS playlists reference regions by ID. REAPER has commands to renumber/reorder markers and regions.

**Questions:**
- What happens to an SWS playlist when the user runs "Reorder all markers/regions" in REAPER?
- Does SWS use the region's `markrgnindexnum` (the ID shown in UI) or some other identifier?
- If a referenced region is deleted, what does SWS show in the playlist UI?
- Does SWS validate region existence on playlist load, or lazily when playing?

### 2. Transport Interaction

**Questions:**
- When SWS playlist is playing and user hits Stop on REAPER transport, what happens?
  - Does SWS pause its playlist state? Exit playlist mode entirely?
- When user hits Play on REAPER transport (not via SWS playlist UI), does SWS playlist engine activate?
- Does SWS have separate Play/Pause controls for playlist mode, or does it piggyback on transport?

### 3. Seeking Implementation

**Questions:**
- What REAPER API does SWS use to seek when advancing to next region?
  - `SetEditCurPos(time, moveview, seekplay)`?
  - `CSurf_OnPlayRateChange`?
  - Something else?
- What parameters does it use (e.g., `moveview=false`)?
- Is there any smoothing/crossfade, or is it a hard seek?

### 4. EXTSTATE API

We plan to persist playlists using REAPER's EXTSTATE.

**Questions:**
- Confirm function signatures: `SetExtState(section, key, value, persist)` and `GetExtState(section, key, buf, buf_sz)`?
- For project-scoped data, do we pass `persist=false` and it saves with project, or is there a separate project EXTSTATE API?
- Is there a size limit for EXTSTATE values?
- Does SWS use EXTSTATE for its playlists, or does it use the `<EXTENSIONS>` block in RPP directly?

### 5. Multi-Client Considerations (General)

If multiple WebSocket clients are connected and can edit the playlist:

**Questions:**
- What patterns exist for handling concurrent edits to shared state in control surface protocols?
- Is "last-write-wins" acceptable, or should we implement locking?
- Any prior art in OSC/MIDI control surface implementations?

## Desired Output

For each question:
1. Direct answer if known
2. Source (SWS source code location, REAPER forum thread, documentation)
3. If unknown, suggest how to test/verify empirically

Prioritize questions 1-4 (SWS-specific). Question 5 is more general architecture.
````

---

## Design Revisions (Post-Review)

Based on user feedback, the following changes to the original plan:

### Dedicated Playlist Controls (Not Transport Hijacking)

**Original:** Ambiguous whether playlist piggybacks on transport.

**Revised:** Playlist has its own play/pause/stop controls:
- `playlist/play` — Start playlist from entry 0 (or resume if paused)
- `playlist/pause` — Pause playlist (remembers position)
- `playlist/resume` — Resume from paused position
- `playlist/stop` — Exit playlist mode entirely

Regular transport play/stop does NOT automatically trigger playlist mode. User must explicitly start playlist.

**Rationale:** Intuitive UX. Being on the Cues page and hitting transport Play shouldn't assume playlist mode.

### Playlist Engine State Broadcasting

**Addition:** Backend broadcasts playlist engine state so late-joining clients can sync:

```json
{
  "isPlaylistActive": true,
  "isPaused": false,
  "activePlaylistIndex": 0,
  "currentEntryIndex": 2,
  "loopsRemaining": 3,
  "currentLoopIteration": 2
}
```

Frontend can auto-navigate to Cues view if `isPlaylistActive: true` on connect.

### "Advance After Current Loop" Feature

**Addition:** New command `playlist/advanceAfterLoop`:
- Sets flag to advance to next entry after current loop completes
- Useful for short-circuiting remaining loops mid-performance
- Broadcast flag state so all clients see pending advance

### Change Detection via wyhash

**Original:** Implied JSON comparison.

**Revised:** Use wyhash on serialized playlist state for efficient change detection (matches pattern used elsewhere in codebase).

### Polling Rate

**Revised:** Playlist state polled at 5Hz (MEDIUM tier), not 30Hz. Sufficient for UI updates.

### SWS Import Trigger

**Revised:** Only check for SWS playlists when user enters Cues view (on-demand), not on project load. Saves startup time.

### Unit Testable Playback Engine

**Requirement:** `PlaylistEngine` must be a pure state machine testable without REAPER API:

```zig
const PlaylistEngine = struct {
    // Pure state, no API dependency
    state: enum { idle, playing, paused },
    playlist_idx: usize,
    entry_idx: usize,
    loops_remaining: i32,
    advance_after_loop: bool,

    // Returns action to take, doesn't execute it
    pub fn tick(self: *@This(), current_pos: f64, region_end: f64) Action {
        // Pure logic, returns what to do
    }
};

const Action = union(enum) {
    none,
    seek_to: f64,
    stop,
    broadcast_state,
};
```

Actual seeking done by caller, engine just returns instructions. Fully testable with mock inputs.

### Verify Existing Bindings First

**Phase 0 Addition:** Before adding new bindings, audit what already exists:
- [ ] Check if `SetExtState`, `GetExtState` already in raw.zig
- [ ] Check if `GetProjectPath` already exists
- [ ] Document what's missing

---

## Open UX Questions (Frontend Team)

These don't block backend, but need decisions:

1. **Lock/View-Only Mode:** Should clients be able to enter "view only" mode to prevent accidental edits during performance? Leader/follower model?

2. **Progress Bar Design:** Show ticks for each loop iteration, or simple bar with counter overlay? Frontend decision.

3. **Infinity Symbol:** How to display infinite loop in progress UI?

4. **Multi-Client Edit Conflict:** Toast notification when another client edits? Or just silent last-write-wins?
