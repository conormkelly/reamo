# Track Management Feature Specification

## Why This Feature Matters

### The Problem

From user research, "track arming and creation — adding a new track for another layer" is listed as a top "walk to computer" trigger. Currently Reamo supports:

- Track selection
- Volume, pan, solo, mute, record arm
- Basic track info display

But musicians can't:
- Rename tracks (stuck with "Track 1" until they go to computer)
- Create new tracks for additional layers/instruments
- Duplicate a track to try a different take approach
- See folder structure (flat list loses organizational context)

### The Opportunity

These are relatively simple additions that significantly extend the "stay at instrument" workflow. A guitarist tracking multiple parts can create "Guitar Clean", "Guitar Dirty", "Guitar Solo" tracks without leaving their position.

---

## Feature Overview

| Capability | Use Case |
|------------|----------|
| **Rename track** | Give meaningful names during session |
| **Create track** | Add new track for another layer |
| **Duplicate track** | Copy track with all settings for alternate take |
| **Folder display** | See organizational hierarchy |
| **Delete track** | Remove unused tracks |

---

## Track Renaming

### REAPER API

```c
bool GetSetMediaTrackInfo_String(
    MediaTrack* track,
    const char* parmname,  // "P_NAME"
    char* stringNeedBig,   // buffer for get, or new name for set
    bool setNewValue       // false = get, true = set
);
```

**Behavior:**
- Empty string = track displays as "Track N" in REAPER
- No length limit documented, but practical limit ~256 chars
- Supports unicode

### Protocol

**Command:**
```json
{
  "type": "command",
  "command": "track/rename",
  "trackIdx": 1,
  "name": "Guitar Clean",
  "id": "1"
}
```

**Response:** Standard command acknowledgment. Track name change will appear in next `tracks` event broadcast.

### UI Concept

**Option A: Inline editing**
- Tap track name → text input appears inline
- Enter/blur → save
- Escape → cancel

**Option B: Long-press menu**
- Long-press track → context menu with "Rename..."
- Opens modal with text input

**Recommendation:** Option A for quick access, but requires careful touch target handling (tap vs long-press vs drag for fader).

---

## Track Creation

### REAPER API

```c
// Insert at specific index
int InsertTrackAtIndex(int idx, bool wantDefaults);
// Returns: index of new track

// Or via action
void Main_OnCommand(40001, 0);  // Track: Insert new track
```

**`wantDefaults` parameter:**
- `true` = apply default track settings (from Preferences)
- `false` = minimal/empty track

**Insertion behavior:**
- `InsertTrackAtIndex(n, ...)` inserts at position n, shifting others down
- To insert after selected track: get selected track index, insert at index+1
- To insert at end: use `CountTracks(NULL)` as index

### Folder-Aware Insertion

When inserting inside a folder:
- Need to set `I_FOLDERDEPTH` to match siblings
- If inserting after last track in folder, must handle folder closure

**Simpler approach:** Always insert at end, let user reorder in REAPER if needed. Or insert after currently selected track.

### Protocol

**Command:**
```json
{
  "type": "command",
  "command": "track/create",
  "name": "New Track",
  "afterTrackIdx": 3,
  "id": "1"
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | No | Initial track name (default: empty = "Track N") |
| `afterTrackIdx` | int | No | Insert after this track index. Omit = insert at end |

**Response:**
```json
{
  "type": "response",
  "id": "1",
  "success": true,
  "trackIdx": 4
}
```

Returns the index of the newly created track.

---

## Track Duplication

### REAPER API

No direct "duplicate track" function. Options:

**Option A: Action-based**
```c
// Select the track first
SetTrackSelected(track, true);
// Run duplicate action
Main_OnCommand(40062, 0);  // Track: Duplicate tracks
```

**Option B: State chunk copy**
```c
// Get source track state
char chunk[65536];
GetTrackStateChunk(srcTrack, chunk, sizeof(chunk), false);

// Insert new track
int newIdx = InsertTrackAtIndex(srcIdx + 1, false);
MediaTrack* newTrack = GetTrack(NULL, newIdx);

// Apply state (may need modification to avoid GUID conflicts)
SetTrackStateChunk(newTrack, chunk, false);
```

**Recommendation:** Option A is simpler and handles all edge cases (FX, items, envelopes, routing). The action creates the duplicate immediately after the source track.

### Protocol

**Command:**
```json
{
  "type": "command",
  "command": "track/duplicate",
  "trackIdx": 2,
  "id": "1"
}
```

**Response:**
```json
{
  "type": "response",
  "id": "1",
  "success": true,
  "trackIdx": 3
}
```

Returns the index of the duplicated track.

### Behavior Notes

- Duplicate includes: name (with " (copy)" suffix added by REAPER), volume, pan, FX chain, items, envelopes
- Does NOT include: record arm state (safety — don't want two tracks recording same input)
- Creates undo point: "Duplicate tracks"

---

## Track Deletion

### REAPER API

```c
bool DeleteTrack(MediaTrack* track);
```

**Behavior:**
- Deletes track and all its items
- Creates undo point
- Track indices shift down for all tracks after deleted one

### Protocol

**Command:**
```json
{
  "type": "command",
  "command": "track/delete",
  "trackIdx": 2,
  "id": "1"
}
```

### Safety Considerations

**Confirmation required?** Deleting a track with recorded items is destructive. Options:

1. **Always confirm:** Frontend shows "Delete 'Guitar' and its 3 items?" modal
2. **Confirm if items exist:** Only confirm if track has items, silent delete if empty
3. **Never confirm:** Trust the user, rely on undo

**Recommendation:** Option 2 — confirm only if track contains items. Frontend can check item count from track data before sending delete command.

**Alternative:** Add `force: true` parameter to skip confirmation handling on backend, let frontend decide policy.

---

## Folder-Aware Display

### REAPER API

```c
double GetMediaTrackInfo_Value(MediaTrack* track, const char* parmname);
// parmname = "I_FOLDERDEPTH"
```

**`I_FOLDERDEPTH` values:**
| Value | Meaning |
|-------|---------|
| 0 | Normal track |
| 1 | Folder parent (start of folder) |
| -1 | Last track in folder, close 1 level |
| -2 | Last track in folder, close 2 levels |
| ... | Negative = close N folder levels |

### Calculating Display Depth

To show proper indentation, track cumulative folder depth:

```typescript
function calculateTrackDepths(tracks: Track[]): Map<number, number> {
  const depths = new Map<number, number>();
  let currentDepth = 0;

  for (const track of tracks) {
    // Apply closing first (for last-in-folder tracks)
    if (track.folderDepth < 0) {
      // This track is still inside the folder(s) being closed
      depths.set(track.idx, currentDepth);
      currentDepth += track.folderDepth; // Negative, so reduces depth
    } else {
      depths.set(track.idx, currentDepth);
      if (track.folderDepth > 0) {
        currentDepth += 1; // Next tracks are inside this folder
      }
    }
  }

  return depths;
}
```

### State Changes

Add `folderDepth` to track data:

```json
{
  "type": "event",
  "event": "tracks",
  "payload": {
    "tracks": [{
      "idx": 0,
      "name": "Drums",
      "folderDepth": 1,
      ...
    }, {
      "idx": 1,
      "name": "Kick",
      "folderDepth": 0,
      ...
    }, {
      "idx": 2,
      "name": "Snare",
      "folderDepth": -1,
      ...
    }]
  }
}
```

### UI Display

```
Drums                    [▼] ──────── 0dB
  Kick                       ──────── -3dB
  Snare                      ──────── -2dB
Bass                         ──────── -1dB
Guitars                  [▼] ──────── 0dB
  Guitar Clean               ──────── -6dB
  Guitar Dirty               ──────── -4dB
```

**Visual elements:**
- Indentation (16-24px per level)
- Folder icon or disclosure triangle for folder parents
- Optional: collapse/expand folders (frontend-only, doesn't change REAPER state)

### Folder Collapse (Optional Enhancement)

Frontend-only feature — hide child tracks when folder is collapsed:

```typescript
const [collapsedFolders, setCollapsedFolders] = useState<Set<number>>(new Set());

function toggleFolder(trackIdx: number) {
  setCollapsedFolders(prev => {
    const next = new Set(prev);
    if (next.has(trackIdx)) {
      next.delete(trackIdx);
    } else {
      next.add(trackIdx);
    }
    return next;
  });
}
```

Filter visible tracks based on collapsed state. This is purely visual — no protocol changes needed.

---

## UI Integration

### Where to Access These Features

**Track context menu (long-press):**
```
┌─────────────────────────┐
│ Rename...               │
│ Duplicate               │
│ ─────────────────────── │
│ Delete                  │
└─────────────────────────┘
```

**Floating action button or toolbar:**
```
[+ New Track]
```

**Inline rename:**
Double-tap or long-press on track name → inline text edit

### Mobile Considerations

- Long-press for context menu is standard iOS/Android pattern
- Swipe-to-delete is familiar but risky for tracks with content
- "New Track" should be easily accessible, not buried in menus

---

## Implementation Checklist

### Extension

**API imports needed:**
- [ ] `GetSetMediaTrackInfo_String` (for rename)
- [ ] `InsertTrackAtIndex` (for create)
- [ ] `DeleteTrack` (for delete)
- [ ] `SetTrackSelected` (for duplicate setup)
- [ ] `Main_OnCommand` with action 40062 (for duplicate)
- [ ] `GetMediaTrackInfo_Value` with `I_FOLDERDEPTH` (for folder display)

**State polling:**
- [ ] Add `folderDepth` to track state struct
- [ ] Include in tracks event broadcast

**Command handlers:**
- [ ] `track/rename` — validate trackIdx, call GetSetMediaTrackInfo_String
- [ ] `track/create` — calculate insert index, call InsertTrackAtIndex, optionally set name
- [ ] `track/duplicate` — select track, run action 40062, return new track index
- [ ] `track/delete` — validate trackIdx, call DeleteTrack

### Frontend

**State:**
- [ ] Add `folderDepth` to Track type
- [ ] Calculate display depths from folder depth values
- [ ] Optional: track collapsed folder state (local only)

**Components:**
- [ ] Track context menu (long-press trigger)
- [ ] Rename modal or inline edit
- [ ] New track button/FAB
- [ ] Folder indentation in track list
- [ ] Optional: folder collapse/expand toggle

**Commands:**
- [ ] Wire up rename command with input validation
- [ ] Wire up create command with optional name
- [ ] Wire up duplicate command
- [ ] Wire up delete command with confirmation for non-empty tracks

---

## Edge Cases and Gotchas

### Track Index Stability

After create/delete/duplicate, track indices change. The next `tracks` event will have updated indices. Frontend should:
- Not cache track indices across operations
- Use track GUID for stable identity if needed (would require adding GUID to track data)

### Master Track

- Index -1 or special handling
- Cannot be deleted, duplicated, or renamed
- Should not appear in "create after" options

### Folder Track Operations

**Deleting a folder parent:**
- REAPER moves children out of folder (they become normal tracks)
- Or deletes children too? (need to verify behavior)

**Duplicating a folder:**
- Does action 40062 duplicate the folder and its contents?
- Need to test behavior

### Undo Integration

All operations create undo points:
- "Rename track"
- "Insert new track"
- "Duplicate tracks"
- "Remove tracks"

No special handling needed — REAPER manages undo state.

### Empty Track Names

Setting empty string `""` as track name → REAPER displays "Track N" where N is track number. This is valid and sometimes desired.

---

## Future Enhancements

- **Track color:** Set via `I_CUSTOMCOLOR` — could add color picker
- **Track icon:** REAPER supports track icons — niche but available
- **Track reordering:** Drag to reorder in list — complex, requires careful folder handling
- **Track templates:** Save/load track configurations — power user feature
- **Batch operations:** Select multiple tracks, delete/mute/solo all
