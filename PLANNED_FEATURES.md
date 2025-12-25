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
| `Reamo_RegionEdit.lua` | Region batch ops (resize, ripple, move) | In use - need `region/batch` command |
| `Reamo_TimeSig.lua` | Time signature changes | **DELETED** - using native `timesig/set` |

### Migration Plan

**Phase 1: TimeSig + Markers** ✅ COMPLETE
- ~~Delete `Reamo_TimeSig.lua`~~ - done
- ~~Update frontend to use native `marker/update` command~~ - done
- ~~Remove ExtState bridge calls from `MarkerEditModal.tsx` and `MarkerInfoBar.tsx`~~ - done
- ~~Delete `Reamo_MarkerEdit.lua`~~ - done
- ~~Remove `markerScriptInstalled` check from UI~~ - done

**Phase 2: Regions (Medium)**
- Add `region/batch` command to extension accepting JSON array of operations
- Each op: `{op: "update"|"create"|"delete", id?, start?, end?, name?, color?}`
- Handle color=0 reset case (delete/recreate)
- Wrap entire batch in undo block
- Update frontend `RegionEditActionBar.tsx` to use native command
- Delete `Reamo_RegionEdit.lua`
