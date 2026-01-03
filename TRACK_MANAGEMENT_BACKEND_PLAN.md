# Track Management — Backend Implementation Plan

**Status:** ✅ COMPLETE
**Last Updated:** 2026-01-02

This is a living document tracking the Track Management backend implementation. Update after completing each phase.

---

## Quick Context for New Sessions

**Read these files first:**
- `DEVELOPMENT.md` — Architecture, conventions, FFI validation layer pattern
- `extension/API.md` — Protocol format, existing events
- `features/TRACK_MANAGEMENT_FEATURE.md` — Full feature spec with UI concepts
- `SEND_BACKEND_PLAN.md` — Similar implementation pattern

**Key architecture concepts:**
- `raw.zig` — Pure C bindings, returns what REAPER returns
- `RealBackend` — Adds validation via `ffi.safeFloatToInt()`
- `MockBackend` — Injectable state for testing
- `backend.zig` — `validateBackend(T)` ensures both backends have all methods
- Unified track indexing: 0=master, 1+=user tracks

---

## Testing with WebSocket

Get token and port, then connect:

```bash
# Get credentials
TOKEN=$(curl -s "http://localhost:8099/_/GET/EXTSTATE/Reamo/SessionToken" | awk '{print $4}')
PORT=$(curl -s "http://localhost:8099/_/GET/EXTSTATE/Reamo/WebsocketPort" | awk '{print $4}')
echo "Token: $TOKEN, Port: $PORT"

# Connect and send commands
/bin/bash -c '{ echo '"'"'{"type":"hello","clientVersion":"1.0.0","protocolVersion":1,"token":"'$TOKEN'"}'"'"'; sleep 0.1; echo '"'"'{"type":"command","command":"track/rename","trackIdx":1,"name":"Test Track","id":"1"}'"'"'; sleep 0.3; } | /opt/homebrew/bin/websocat ws://localhost:'$PORT' 2>&1 | head -20'
```

---

## Scope & Features

| Command | Purpose | REAPER API |
|---------|---------|------------|
| `track/rename` | Set track name | `GetSetMediaTrackInfo_String` with P_NAME |
| `track/create` | Insert new track | `InsertTrackAtIndex` + optional name set |
| `track/duplicate` | Copy track with FX/items | `SetTrackSelected` + action 40062 |
| `track/duplicateSelected` | Duplicate all selected | action 40062 (native) |
| `track/delete` | Remove track | `DeleteTrack` |
| `track/deleteSelected` | Delete all selected | action 40005 (native) |

| State Field | Purpose | REAPER API |
|-------------|---------|------------|
| `folderDepth` | Folder hierarchy display | `GetMediaTrackInfo_Value` with I_FOLDERDEPTH |

---

## Design Decisions

### Folder Depth in Tracks Event

Add `folderDepth` to track state for UI hierarchy display:
- `1` = folder parent (start of folder)
- `0` = normal track
- `-1` = last track in folder, closes 1 level
- `-N` = closes N folder levels

Frontend calculates cumulative depth for indentation. No folder collapse state in backend (frontend-only).

### Track Duplicate via Action

Use action-based duplicate (40062) wrapped in undo block:
1. `Undo_BeginBlock2(0)`
2. Unselect all tracks (action 40297)
3. `SetTrackSelected(targetTrack, true)`
4. `Main_OnCommand(40062, 0)` — duplicate
5. `GetSelectedTrack(0, 0)` — get new track
6. `Undo_EndBlock2(0, "Duplicate track N", -1)`

**Benefits:**
- Single undo point: "Duplicate track N"
- Undo restores previous selection state
- Handles all edge cases (FX, items, envelopes, routing)

### Master Track Protection

Master track (idx 0) cannot be renamed, created, duplicated, or deleted. Commands validate and reject.

### Track Create Return Value

Return the new track index in the response so frontend knows which track was created.

### Track Create Insert Position

Support optional `afterTrackIdx` parameter:
- **If omitted:** Append at end using `InsertTrackAtIndex(CountTracks(0), true)`
- **If provided:** Insert after that track using `InsertTrackAtIndex(afterTrackIdx + 1, true)`
- **Validation:** Reject if `afterTrackIdx` > track count or < 0

---

## C API Functions

From `reaper_plugin_functions.h`:

```c
// Rename track
bool GetSetMediaTrackInfo_String(MediaTrack* tr, const char* parmname, char* stringNeedBig, bool setNewValue);
// parmname = "P_NAME", setNewValue = true

// Insert new track at index
void InsertTrackAtIndex(int idx, bool wantDefaults);

// Delete track
void DeleteTrack(MediaTrack* tr);

// Select track (needed for duplicate action)
void SetTrackSelected(MediaTrack* track, bool selected);

// Run action (already exists)
void Main_OnCommand(int command, int flag);
// command 40062 = "Track: Duplicate tracks"

// Get folder depth (already exists)
double GetMediaTrackInfo_Value(MediaTrack* track, const char* parmname);
// parmname = "I_FOLDERDEPTH"

// Get track count (likely already exists)
int CountTracks(ReaProject* proj);
// Pass 0 for active project

// Get selected track (for duplicate response)
MediaTrack* GetSelectedTrack(ReaProject* proj, int selIndex);
// After action 40062, duplicated track becomes selected - use GetSelectedTrack(0, 0)
```

---

## Implementation Phases

### Phase 1: raw.zig — C Function Pointers ✅
- [x] Add `GetSetMediaTrackInfo_String` function pointer + wrapper
- [x] Add `InsertTrackAtIndex` function pointer + wrapper
- [x] Add `DeleteTrack` function pointer + wrapper
- [x] Add `SetTrackSelected` function pointer + wrapper
- [x] Add `GetSelectedTrack` function pointer + wrapper (for duplicate response)
- [x] Load all in `Api.load()`

**Already exists:** `Main_OnCommand`, `GetMediaTrackInfo_Value`, `CountTracks` (verify)

**Files:** `extension/src/reaper/raw.zig`

### Phase 2: real.zig — RealBackend Methods ✅
- [x] Add `setTrackName(track, name)` delegation
- [x] Add `insertTrack(idx, wantDefaults)` delegation
- [x] Add `deleteTrackPtr(track)` delegation
- [x] Add `getSelectedTrackByIdx(selIdx)` delegation
- [x] Add `getTrackFolderDepth(track)` using existing GetMediaTrackInfo_Value

**Files:** `extension/src/reaper/real.zig`

### Phase 3: mock/ — MockBackend Support ✅
- [x] Add mock methods for all 5 operations
- [x] Add to `state.zig` Method enum
- [x] Add `folder_depth` field to MockTrack
- [x] Re-export in `mod.zig`

**Files:** `extension/src/reaper/mock/mod.zig`, `mock/state.zig`, `mock/tracks.zig`

### Phase 4: backend.zig — Update Validator ✅
- [x] Add 5 new methods to `required_methods`

**Files:** `extension/src/reaper/backend.zig`

### Phase 5: tracks.zig — Add Folder Depth ✅
- [x] Add `folder_depth: c_int` field to `Track` struct
- [x] Update `Track.eql()` to compare folder_depth
- [x] Poll folder depth in track state gathering
- [x] Update `toJson()` to include `"folderDepth"` field

**Files:** `extension/src/tracks.zig`

### Phase 6: Commands — Add Handlers ✅
- [x] Add handlers to existing `commands/tracks.zig`
- [x] Implement `track/rename` handler
- [x] Implement `track/create` handler (return new idx)
- [x] Implement `track/duplicate` handler (undo block + action + return new idx)
- [x] Implement `track/delete` handler
- [x] Add to `registry.zig`

**Files:** `extension/src/commands/tracks.zig`, `commands/registry.zig`

### Phase 7: Documentation ✅
- [x] Update `API.md` — tracks event folderDepth, track commands
- [x] Update `PLANNED_FEATURES.md` — mark backend done
- [x] Update this plan document

**Files:** `extension/API.md`, `PLANNED_FEATURES.md`, `TRACK_MANAGEMENT_BACKEND_PLAN.md`

---

## JSON Output Format

Tracks event includes folder depth:

```json
{
  "type": "event",
  "event": "tracks",
  "payload": {
    "tracks": [
      {"idx": 0, "name": "MASTER", "folderDepth": 0, ...},
      {"idx": 1, "name": "Drums", "folderDepth": 1, ...},
      {"idx": 2, "name": "Kick", "folderDepth": 0, ...},
      {"idx": 3, "name": "Snare", "folderDepth": -1, ...},
      {"idx": 4, "name": "Bass", "folderDepth": 0, ...}
    ]
  }
}
```

---

## Commands

| Command | Parameters | Response |
|---------|------------|----------|
| `track/rename` | `trackIdx`, `name` | `{success: true}` |
| `track/create` | `name?`, `afterTrackIdx?` | `{success: true, trackIdx: N}` |
| `track/duplicate` | `trackIdx` | `{success: true, trackIdx: N}` |
| `track/duplicateSelected` | (none) | `{success: true}` |
| `track/delete` | `trackIdx` | `{success: true}` |
| `track/deleteSelected` | (none) | `{success: true}` |

---

## Design Decisions (Confirmed)

### Master Track Protection
Master track (idx 0) **cannot be renamed, duplicated, or deleted**. Commands validate and return error.

### Duplicate Response
After running action 40062, the duplicated track becomes selected. Use `GetSelectedTrack(0, 0)` to retrieve it and get its index. This is more robust than assuming `sourceTrackIdx + 1` (though in practice they should match).

### Delete Confirmation
Backend does not provide item count — frontend can use existing item data from items event to show confirmation.

### Selection Behavior
Single-track commands (`track/delete`, `track/duplicate`) operate on the specified `trackIdx` and ignore current selection state. Frontend is responsible for UX around multi-selection scenarios (e.g., showing a modal to confirm "delete all selected" vs "delete just this one").

### Selection-Based Commands ✅
Implemented:
- `track/duplicateSelected` — duplicates all selected tracks (native action 40062)
- `track/deleteSelected` — deletes all selected tracks (action 40005)

These give power users native REAPER gang behavior from the tablet.

## Progress Log

| Date | Phase | Notes |
|------|-------|-------|
| 2026-01-02 | Phase 0 | Planning complete, document created |
| 2026-01-02 | Phase 0 | Refined with FOLDER_INFO_REAPER.md research: resolved insert position, added GetSelectedTrack |
| 2026-01-02 | Phase 0 | Confirmed undo block approach for duplicate (Lua test passed), documented selection behavior |
| 2026-01-02 | Phase 1-7 | Implementation complete: raw.zig, real.zig, mock/, backend.zig, tracks.zig, commands/tracks.zig, API.md |
| 2026-01-03 | Bonus | Added `track/duplicateSelected` and `track/deleteSelected` commands (actions 40062, 40005) |

---

## Notes & Gotchas

- **Master track protection:** idx 0 cannot be modified/deleted
- **Track indices shift:** After create/delete, indices change. Next tracks event has updated data.
- **Empty track name:** Setting `""` makes REAPER display "Track N" — this is valid
- **Folder deletion:** Deleting folder parent does NOT delete children — they become orphaned/promoted to parent level
- **Undo points:** All operations create undo points automatically
- **GetTrack(0, 0):** Returns first regular track, NOT master. Use `GetMasterTrack(proj)` for master.
- **DeleteTrack:** Invalidates the MediaTrack* pointer immediately — don't use after calling
- **Multiple deletions:** Must iterate in reverse order (highest index first) to avoid index shifting issues
- **GetParentTrack(track):** API exists for getting parent folder — useful for future hierarchy features
