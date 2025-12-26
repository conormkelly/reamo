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
