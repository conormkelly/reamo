# Planned Features

## Items Mode

### Rationale

The current app shows regions (song structure) but not what's actually recorded in them. Users must go to the computer to see/manage takes. This breaks the "stay at instrument" workflow.

### UI Concept

**Level of Detail (LOD) approach:**

**Zoomed Out (Navigate/Regions mode):**
Items shown as aggregate blobs — visual reference only, read-only.

```txt
┌─────────────────────────────────────────┐
│ Verse 1          │ Chorus               │
│ ▓▓░░▓▓▓░░▓▓     │ ▓▓▓▓░░░▓▓           │
└─────────────────────────────────────────┘
```

**Zoomed In (Items mode):**
Double-tap region or zoom to time selection. Single track view with detailed item management.

```txt
┌─────────────────────────────────────────────────────┐
│ Track: Guitar ▼              [Time Selection]       │
├─────────────────────────────────────────────────────┤
│                                                     │
│    ┌─────────────┐              ┌─────────────┐    │
│    │     1/3     │              │     2/3     │    │
│    │ ▓▓▓▓▓▓▓▓▓▓▓ │              │ ▓▓▓▓▓▓▓▓▓▓▓ │    │
│    └─────────────┘              └─────────────┘    │
│         ▲                                          │
│     (selected)                                     │
├─────────────────────────────────────────────────────┤
│ Take 1 of 3  [◀][▶]  [Crop] [🗑] [Notes] [Color]   │
└─────────────────────────────────────────────────────┘
```

**Key UI decisions:**

- Show ONE track at a time (not all tracks)
- Track dropdown shows tracks with items in the time selection
- Items shown as single bars (active take color) with take count badge ("1/3")
- No visual stacking of takes (unlike REAPER's arrange view)
- ItemInfoBar for selected item: take switching, actions

### Supported Item Actions

| Action | Purpose | REAPER API |
|--------|---------|------------|
| Switch take | Navigate takes | `SetMediaItemInfo_Value(item, "I_CURTAKE", index)` |
| Delete take | Remove bad take | `Main_OnCommand(40129, 0)` |
| Crop to active | "This is the keeper" | `Main_OnCommand(40131, 0)` |
| Move item | Nudge position | `SetMediaItemInfo_Value(item, "D_POSITION", pos)` |
| Trim item | Adjust boundaries | Modify `D_POSITION` + `D_LENGTH` + take offsets |
| Set color | Visual organization | `SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", color)` |
| Lock | Protect from accidents | `SetMediaItemInfo_Value(item, "C_LOCK", 1)` |
| Add notes | "Good energy", etc. | `GetSetMediaItemInfo_String(item, "P_NOTES", ...)` |
| Delete item | Remove entirely | `DeleteTrackMediaItem(track, item)` |

### What This Is NOT

- No comping lanes
- No crossfades
- No waveform editing
- No split/glue
- No detailed MIDI editing

Just: **"See what I recorded, tidy it up, make quick keep/trash decisions, move on."**

---

## Lua Script Deprecation

The original architecture used Lua scripts polling ExtState for operations that couldn't be done from the extension. Now that the Zig extension has matured, several scripts are redundant.

### Current Scripts

| Script | Purpose | Status |
|--------|---------|--------|
| `Reamo_MarkerEdit.lua` | Marker rename/recolor | **DELETED** - using native `marker/update` |
| `Reamo_RegionEdit.lua` | Region batch ops (resize, ripple, move) | **DELETED** - using native `region/batch` |
| `Reamo_TimeSig.lua` | Time signature changes | **DELETED** - using native `timesig/set` |

### Migration Plan

**Phase 1: TimeSig + Markers** ✅ COMPLETE
- ~~Delete `Reamo_TimeSig.lua`~~ - done
- ~~Update frontend to use native `marker/update` command~~ - done
- ~~Remove ExtState bridge calls from `MarkerEditModal.tsx` and `MarkerInfoBar.tsx`~~ - done
- ~~Delete `Reamo_MarkerEdit.lua`~~ - done
- ~~Remove `markerScriptInstalled` check from UI~~ - done

**Phase 2: Regions** ✅ COMPLETE

#### Extension: `region/batch` Command ✅

Add new command accepting JSON array of operations:

```json
{
  "command": "region/batch",
  "ops": [
    {"op": "update", "id": 5, "start": 10, "end": 20, "name": "Verse", "color": 16777472},
    {"op": "delete", "id": 3},
    {"op": "create", "start": 30, "end": 40, "name": "Bridge", "color": 0}
  ]
}
```

**Response format:**

```json
{"success": true, "applied": 9, "skipped": 1, "warnings": ["Region id=5 not found"]}
```

**Implementation requirements:**

| Requirement | Details |
|-------------|---------|
| Single undo block | Wrap entire batch in `undoBeginBlock`/`undoEndBlock` |
| color=0 reset | Delete and recreate region to reset to theme default (REAPER API quirk: `SetProjectMarker4` treats color=0 as "don't modify") |
| `addRegionWithId` | Need new helper to recreate region with preserved ID |
| Fresh enumeration lookup | For each op, look up current enumeration index by stable ID (indices shift during batch) |
| PreventUIRefresh | Wrap for performance |
| Error handling | Region not found → warn + skip, invalid params → skip with error, return response with success/warning counts |

**Design decisions:**

| Decision | Rationale |
|----------|-----------|
| Error handling: warn + continue | Skip failed ops, continue batch, return warnings. User sees partial success rather than total failure for one bad op. |
| Op order: process as-is | Frontend controls order. Each op does fresh ID lookup, so index shifts from prior ops don't corrupt subsequent ops. |
| Create ops: no ID return needed | Frontend uses negative temp IDs for preview only. WebSocket broadcasts new state within ~30ms, frontend syncs then. |
| Min region length: frontend only | REAPER is the final guard. Don't duplicate validation logic in extension. |
| Legacy `move`/`resize` ops: don't implement | Frontend calculates all final positions and emits only `update`/`create`/`delete`. These are dead code in the Lua script. |

**REAPER API gotchas (from Lua script analysis):**

1. `markrgnidx` (stable ID) vs enumeration index (shifts on add/delete/move)
2. `SetProjectMarkerByIndex2` color=0 means "don't modify", not "reset to default"
3. Color reset requires delete + recreate with preserved ID (tested and confirmed working)

#### Frontend Changes ✅

- ~~Update `RegionEditActionBar.tsx` to use `region/batch` command~~ - done
- ~~Build JSON ops array instead of pipe-delimited string~~ - done
- ~~Remove ExtState bridge calls~~ - done
- ~~Proper async handling (no 300ms polling hack)~~ - done
- ~~Remove `luaScriptInstalled`/`luaScriptChecked` state~~ - done

#### Cleanup: Files Modified ✅

| File | Action |
|------|--------|
| `scripts/Reamo_RegionEdit.lua` | **Deleted** |
| `installer/Install_Reamo.lua` | Removed regionEdit/markerEdit/timeSig copy logic |
| `installer/Uninstall_Reamo.lua` | Removed regionEdit/markerEdit deletion |
| `installer/Reamo_Startup.lua` | Simplified - no scripts to load |
| `.github/workflows/release.yml` | Removed Lua scripts from release artifacts |
| `scripts/create-release-zip.js` | Removed Lua scripts from zip |
| `README.md` | Simplified manual install instructions |
| `frontend/.../TimelineModeToggle.tsx` | Removed lua script check and warning |
| `frontend/.../regionEditSlice.ts` | Removed luaScriptInstalled/luaScriptChecked state |
| `frontend/.../store/index.ts` | Removed EXTSTATE handler for lua script check |

#### Manual QA Test Cases

**Basic Operations:**
1. Create single region → appears in REAPER
2. Update region name → name changes in REAPER
3. Update region color → color changes in REAPER
4. Update region position/length → boundaries change in REAPER
5. Delete region → removed from REAPER

**Batch Operations:**
6. Multiple creates in one save
7. Multiple updates in one save
8. Multiple deletes in one save
9. Mixed ops (create + update + delete) in one save

**Color Reset (the gotcha):**
10. Set region to custom color, save → color applied
11. Reset region to theme default (color=0), save → theme color restored

**Error Handling:**
12. Edit region on iPad, delete same region on computer, save from iPad → warning, other ops succeed

**Undo:**
13. Save batch of 5 ops → single Cmd+Z undoes all 5

**ID-Keyed State (architectural fix):**
14. Start editing region A, delete region B on computer (shifts indices), save → region A correctly updated (not corrupted)

---

## ID-Keyed Pending State (Architectural Fix)

### The Problem

Current `pendingChanges` is keyed by **array index**, but array indices shift when the server pushes region updates (add/delete/reorder). This causes:

1. User edits region at index 2 (id=5)
2. Server pushes update: region at index 0 deleted
3. Array re-indexes: index 2 now contains different region (id=7)
4. `pendingChanges[2]` visually overlays on wrong region
5. Save is correct (uses `originalIdx` = stable ID), but **display is wrong**

### The Solution

**Key pending changes by stable entity ID, not array index.** This is the established pattern used by Apollo Client (normalized cache), Replicache (key-based storage), and TanStack Query.

```typescript
// ❌ Current: index-based (breaks when indices shift)
pendingChanges: Record<number, PendingRegionChange>  // key = array index

// ✅ Fixed: ID-based (stable forever)
pendingChanges: Map<number, PendingRegionChange>     // key = region.id (markrgnidx)
```

For new regions (not yet in REAPER), continue using negative IDs as keys.

### Implementation Checklist

**Types (`regionEditSlice.types.ts`):**
- [ ] Change `PendingChangesRecord` from `Record<number, ...>` to `Map<number, ...>`
- [ ] Remove `_pendingKey` from `DisplayRegion` (no longer needed)
- [ ] Add `baseVersion?: number` to track server state when editing began

**Slice (`regionEditSlice.ts`):**
- [ ] Update `getDisplayRegions()` to look up by `region.id` instead of array index
- [ ] Update all ripple calculation functions to use IDs
- [ ] Update `selectedRegionIndices` to store IDs, not array indices

**Ripple operations (`regionEdit/rippleOperations.ts`):**
- [ ] All functions currently take `index` parameter → change to `id` parameter
- [ ] Update internal logic to work with ID-keyed maps

**Components:**
- [ ] `TimelineRegions.tsx`: Remove `_pendingKey` usage, look up by `region.id`
- [ ] `RegionInfoBar.tsx`: Same
- [ ] `Timeline.tsx`: Update `selectedPendingKeys` computation
- [ ] `useRegionDrag.ts`: Update to use IDs

**Tests:**
- [ ] Update all region edit tests to use ID-based assertions
- [ ] Add test: server update during pending changes doesn't corrupt display

### Conflict Detection (Future Enhancement)

For the multi-device scenario (edit on iPad, changes on computer, save from iPad):

**Option 1: Optimistic Locking (Recommended for MVP)**
- Track `baseVersion` when editing begins
- On save, include expected version
- Server rejects if version changed → prompt user to refresh

**Option 2: Field-level Last-Write-Wins**
- Each field carries timestamp
- Newest value wins per field
- Use Hybrid Logical Clocks to avoid clock skew

For single-user DAW where conflicts are rare, Option 1 is sufficient.

### Why Not OT/CRDTs?

Full Operational Transformation or CRDTs add 15-500KB of library code and complexity. The core insight from CRDT research applies without the overhead: **stable IDs eliminate index-shifting problems entirely**. Once every entity has an immutable ID and all operations reference that ID, no transformation is needed.

---

## Project Undo/Redo State

### The Problem

The current undo/redo buttons (under the time display) work but provide no feedback. Users don't know:
- Whether undo/redo is available before pressing
- What action was undone/redone after pressing

### Research: Full History Enumeration is Impossible

**Investigated approaches:**

| Approach | Finding |
|----------|---------|
| Native REAPER API | Only exposes next undo/redo description via `Undo_CanUndo2`/`Undo_CanRedo2`. No enumeration. |
| SWS Extension | Maintains **parallel** undo stacks (zoom history, cursor positions) - does NOT access REAPER's main undo stack. |
| RPP-UNDO files | Only written when project is saved. Not real-time, not programmatically accessible during session. |
| ReaScript enumeration | No `EnumUndoHistory()` or similar function exists. |
| Memory inspection | Undocumented, version-dependent, unsafe. |

**Conclusion:** REAPER's "Undo History" window (View → Undo History) uses internal data structures not exposed to extensions. A full history modal is not feasible without REAPER API changes.

### Available API

| Function | Returns |
|----------|---------|
| `Undo_CanUndo2(proj)` | Description of next undo action, or `NULL` if nothing to undo |
| `Undo_CanRedo2(proj)` | Description of next redo action, or `NULL` if nothing to redo |
| `Undo_DoUndo2(proj)` | Performs undo, returns nonzero on success |
| `Undo_DoRedo2(proj)` | Performs redo, returns nonzero on success |
| `GetProjectStateChangeCount(proj)` | Counter that increments on any project change (for detecting when to re-poll undo state) |

### Feasible UX Improvements

Given API limitations, we can still significantly improve the undo/redo experience:

**1. Button Enable/Disable State**
- Disable undo button when `Undo_CanUndo2` returns `NULL`
- Disable redo button when `Undo_CanRedo2` returns `NULL`
- Visual feedback that there's nothing to undo/redo

**2. Toast/Banner After Action**
When user presses undo/redo, show a brief toast displaying what happened:

```txt
┌───────────────────────────────┐
│  ↩ Add region at 30.0s       │
└───────────────────────────────┘
```

or

```txt
┌───────────────────────────────┐
│  ↪ Delete marker 'Bridge'    │
└───────────────────────────────┘
```

The icon indicates undo (↩) vs redo (↪) - no need for "Undid/Redid" text.

Toast auto-dismisses after 2-3 seconds.

**3. Tooltip on Hover (Desktop)**
Show next action description on button hover: "Undo: Add region at 30.0s"

### Why Not Track Our Own History?

Maintaining a parallel history stack was considered and rejected:

| Issue | Problem |
|-------|---------|
| Incomplete coverage | Only captures Reamo actions, misses direct REAPER edits |
| Sync complexity | Must detect external changes, handle undo count mismatches |
| "Jump to state" | Would require calling `Undo_DoUndo2` repeatedly, hoping counts align |
| State divergence | If user undoes in REAPER directly, our stack becomes stale |

The complexity isn't worth it for marginal benefit. Better to embrace the API limitation.

### Implementation

#### Extension: Project State Event

Add a **separate** `project` event (NOT in transport - undo state is project metadata, not playback state):

```json
{
  "type": "event",
  "event": "project",
  "payload": {
    "canUndo": "Add region at 30.0s",
    "canRedo": null,
    "stateChangeCount": 42
  }
}
```

**When to send:**
- On initial WebSocket connection
- When `GetProjectStateChangeCount()` changes (poll in run loop, ~30ms interval)
- After executing `undo/do` or `redo/do` commands

#### Extension: Zig API Bindings

Add to `extension/src/reaper.zig`:
```zig
undo_CanUndo2: ?*const fn (?*anyopaque) callconv(.c) ?[*:0]const u8 = null,
undo_CanRedo2: ?*const fn (?*anyopaque) callconv(.c) ?[*:0]const u8 = null,
undo_DoUndo2: ?*const fn (?*anyopaque) callconv(.c) c_int = null,
undo_DoRedo2: ?*const fn (?*anyopaque) callconv(.c) c_int = null,
getProjectStateChangeCount: ?*const fn (?*anyopaque) callconv(.c) c_int = null,
```

#### Extension: Commands

| Command | Action | Response |
|---------|--------|----------|
| `undo/do` | Calls `Undo_DoUndo2`, broadcasts new project state | `{ "success": true, "action": "Add region" }` |
| `redo/do` | Calls `Undo_DoRedo2`, broadcasts new project state | `{ "success": true, "action": "Delete marker" }` |

#### Frontend: Store

```typescript
// In store
canUndo: string | null;
canRedo: string | null;

// Handle project event
case 'project':
  set({
    canUndo: payload.canUndo ?? null,
    canRedo: payload.canRedo ?? null,
  });
```

#### Frontend: UI Components

**Undo/Redo buttons** (existing, in time display area):
- Add `disabled` state based on `canUndo`/`canRedo`
- On click: send command, show toast with result

**Toast component** (new):
- Positioned bottom-center or top-center
- Shows action description
- Auto-dismiss after 2.5s
- Queue multiple toasts if rapid undo/redo

---

## Tempo Marker Support

### The Problem

The current implementation uses `GetProjectTimeSignature2()` to fetch BPM and time signature, which **only returns project-level defaults**. This ignores tempo markers entirely.

```zig
// Current (BROKEN for tempo markers):
api.getProjectTimeSignature2(null, &bpm, &num, &denom);
// Returns: project default tempo (e.g., 120 BPM, 4/4)
// Ignores: any tempo markers in the project
```

### Correct API

`TimeMap_GetTimeSigAtTime()` returns **both** BPM and time signature at any position, fully respecting the tempo map including linear ramps:

```c
void TimeMap_GetTimeSigAtTime(
    ReaProject* proj,           // NULL for active project
    double time,                // position in seconds
    int* timesig_numOut,        // beats per measure (e.g., 4)
    int* timesig_denomOut,      // note value per beat (e.g., 4)
    double* tempoOut            // BPM at this position
);
```

**Key findings:**
- Single call returns both tempo AND time signature (no need for `TimeMap2_GetDividedBpmAtTime`)
- Handles tempo ramps (linear interpolation) automatically
- Works even with zero tempo markers (returns project defaults)
- At exact marker boundary, returns NEW values (post-marker)

### Gotchas

**Zero time sig values mean "inherit":** When a tempo marker only changes BPM (not time sig), the API returns 0 for timesig_num/denom. Always handle this:

```zig
if (timesig_num == 0) timesig_num = 4;  // Default to 4/4
if (timesig_denom == 0) timesig_denom = 4;
```

**`positionBeats` already works:** Our `TimeMap2_timeToBeats()` call already respects tempo markers - no changes needed there.

### Performance Optimization (Optional)

For projects with sparse tempo changes, cache the next change time to reduce API calls:

```c
static double s_nextChangeTime = -1;
// Only re-query if we've crossed a marker boundary
if (s_nextChangeTime < 0 || currentPos >= s_nextChangeTime) {
    TimeMap_GetTimeSigAtTime(NULL, currentPos, ...);
    s_nextChangeTime = TimeMap2_GetNextChangeTime(NULL, currentPos);
}
```

For tempo ramps, per-frame queries are still needed during interpolation.

### Implementation Checklist

**Extension (`transport.zig`):**
- [ ] Add REAPER API binding for `TimeMap_GetTimeSigAtTime`
- [ ] Replace `getProjectTimeSignature2()` with `TimeMap_GetTimeSigAtTime()`
- [ ] Pass current play position (or edit cursor when stopped)
- [ ] Handle zero timesig values (default to 4/4)

**Frontend:**
- [ ] No changes required - transport event structure unchanged

**Testing:**
- [ ] Create test project with multiple tempo markers
- [ ] Verify BPM updates when cursor crosses tempo marker during playback
- [ ] Verify time signature updates when crossing time sig marker
- [ ] Test tempo ramps (linear interpolation between markers)
- [ ] Test project with no tempo markers (should use defaults)

### Future: Tempo Map Visualization

For displaying the full tempo map in UI:

| Function | Purpose |
|----------|---------|
| `CountTempoTimeSigMarkers(proj)` | Count markers |
| `GetTempoTimeSigMarker(proj, idx, ...)` | Read marker details |
| `FindTempoTimeSigMarker(proj, time)` | Find marker at position |
| `TimeMap2_GetNextChangeTime(proj, time)` | Find next tempo change (-1 if none)

---

## Transport Event Refactoring ✅ COMPLETE

Moved project-level settings from `transport` event to `project` event for cleaner separation and reduced bandwidth.

### Changes Made

**Extension:**
- [x] Added `projectLength`, `repeat`, `metronome`, `barOffset` to `project.zig` State
- [x] Poll these values in project state (only broadcast on change)
- [x] Removed from `transport.zig`
- [x] Updated change detection to include new fields

**Frontend:**
- [x] Moved fields from `TransportEventPayload` to `ProjectEventPayload` in `WebSocketTypes.ts`
- [x] Updated `store/index.ts` to handle new project event fields
- [x] Components unchanged - state still lives in transportSlice

**Result:**
- `transport` event: High-frequency (~30ms) position-dependent data only
- `project` event: Low-frequency project settings + undo/redo state
