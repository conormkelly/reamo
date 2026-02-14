# REAmo Item Movement: Implementation Reference

> Reference document for implementing item movement in REAmo mobile DAW controller.
> Updated January 2026 after design review.

---

## Executive Summary

**Current state**: REAmo's `item/move` command naively sets `D_POSITION` without respecting REAPER's ripple editing, snap-to-grid, or item grouping settings.

**Chosen approach**: Modal/bottomsheet UI for atomic move operations. User selects item(s), opens move controls, enters offset or position, commits. One command, one undo point.

**Why not drag?** REAmo's purpose is "idea capture, not production" (see README). A modal with quick-nudge buttons (+1 bar, -1 beat) is faster from an iPad on a music stand than precise finger-dragging on a small timeline. Users who need surgical editing are at the computer anyway.

---

## Part 1: Technical API Reference

### 1.1 Core APIs for Item Movement

| Function | Purpose | Respects Ripple? | Respects Snap? | Respects Groups? |
|----------|---------|------------------|----------------|------------------|
| `SetMediaItemInfo_Value(item, "D_POSITION", pos)` | Direct position set | No | No | No |
| `ApplyNudge(proj, flag, what, units, val, rev, copies)` | Move selected items | Yes | Yes | Yes |

**ApplyNudge parameters for position moves:**

```c
// Move selected items by `delta` seconds:
ApplyNudge(nullptr, 0, 0, 1, delta, false, 0);
//              |    |  |  |   |      |      +-- copies (0 = move, not copy)
//              |    |  |  |   |      +-- reverse direction
//              |    |  |  |   +-- amount in specified units
//              |    |  |  +-- nudgeunits: 1 = seconds
//              |    |  +-- nudgewhat: 0 = position (left edge)
//              |    +-- nudgeflag: 0 = selected items
//              +-- project (nullptr = current)
```

**Why ApplyNudge over direct manipulation?**
It handles ripple, snap, and groups automatically. Since REAmo already selects items when tapped (via `item/toggleSelect`), the selection is already correct for ApplyNudge.

### 1.2 Reading User Settings

**Ripple mode** (`projripedit` ConfigVar):

- `0` = Off
- `1` = Per-track (items on same track shift)
- `2` = All tracks (items on all tracks shift)

```c
int size;
int* val = (int*)get_config_var("projripedit", &size);
```

**Snap enabled** (action 1157):

```c
bool snapEnabled = GetToggleCommandState(1157) == 1;
```

REAmo already has toolbar buttons for ripple (action 1162) and snap (action 1157) that toggle these settings.

### 1.3 Take Properties (Clarification)

Moving an item (`D_POSITION`) does **not** affect:

- `D_STARTOFFS` (take source offset)
- `D_LENGTH` (item length)
- `D_PLAYRATE` (playback rate)
- Stretch markers (positions are item-relative)

No take-level updates needed for simple moves.

---

## Part 2: Implementation Design

### 2.1 Chosen Approach: Atomic Move Commands

Instead of real-time drag gestures, implement discrete move operations with full time/beats support (similar to MarkerEditModal):

**Relative move (nudge):**

```json
{"type": "command", "command": "item/nudge", "delta": 2.0, "unit": "beats"}
{"type": "command", "command": "item/nudge", "delta": -1.0, "unit": "bars"}
{"type": "command", "command": "item/nudge", "delta": 0.5, "unit": "seconds"}
```

**Absolute move (time-based):**

```json
{"type": "command", "command": "item/moveTo", "position": 16.5}
```

**Absolute move (bar.beat-based):**

```json
{"type": "command", "command": "item/moveTo", "bar": 5, "beat": 1}
{"type": "command", "command": "item/moveTo", "bar": 5, "beat": 2.5}
```

Both commands operate on REAPER's current item selection (already set via tap).

### 2.2 Backend Implementation

**New command: `item/nudge`**

Parameters:

- `delta` (float, required): Amount to move (positive = forward, negative = backward)
- `unit` (string, optional): `"seconds"` (default), `"beats"`, or `"bars"`

```zig
pub fn handleItemNudge(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    const delta = cmd.getFloat("delta") orelse {
        response.err("MISSING_DELTA", "Delta is required");
        return;
    };

    const unit = cmd.getString("unit") orelse "seconds";

    // Convert delta to seconds based on unit
    // For beats/bars, use REAPER's tempo map at cursor position
    var delta_seconds: f64 = delta;
    if (std.mem.eql(u8, unit, "beats")) {
        // Convert quarter-note beats to seconds at current tempo
        delta_seconds = api.beatsToTime(delta);
    } else if (std.mem.eql(u8, unit, "bars")) {
        // Convert bars to seconds (1 bar = beatsPerBar beats)
        delta_seconds = api.barsToTime(delta);
    }

    api.undoBeginBlock();

    // ApplyNudge: nudgeflag=0 (selected items), nudgewhat=0 (position), nudgeunits=1 (seconds)
    const reverse = delta_seconds < 0;
    api.applyNudge(0, 0, 1, @abs(delta_seconds), reverse, 0);

    api.undoEndBlock("REAmo: Nudge items");
    api.updateTimeline();
}
```

**New command: `item/moveTo`**

Parameters:

- `position` (float, optional): Target position in seconds
- `bar` (int, optional): Target bar number (1-based)
- `beat` (float, optional): Target beat within bar (1-based, can be fractional)

Must provide either `position` OR `bar` (beat defaults to 1 if omitted).

```zig
pub fn handleItemMoveTo(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void {
    // Determine target position
    var target_seconds: f64 = undefined;

    if (cmd.getFloat("position")) |pos| {
        // Direct time-based positioning
        target_seconds = pos;
    } else if (cmd.getInt("bar")) |bar| {
        // Bar.beat positioning - convert using tempo map
        const beat = cmd.getFloat("beat") orelse 1.0;
        target_seconds = api.barBeatToTime(bar, beat);
    } else {
        response.err("MISSING_POSITION", "Either position or bar is required");
        return;
    }

    if (target_seconds < 0) {
        target_seconds = 0;
    }

    // Get first selected item's current position to calculate delta
    const first_item = api.getFirstSelectedItem() orelse {
        response.err("NO_SELECTION", "No items selected");
        return;
    };
    const current_pos = api.getItemPosition(first_item);
    const delta = target_seconds - current_pos;

    if (@abs(delta) < 0.001) {
        // Already at target, no-op
        response.success(null);
        return;
    }

    api.undoBeginBlock();

    const reverse = delta < 0;
    api.applyNudge(0, 0, 1, @abs(delta), reverse, 0);

    api.undoEndBlock("REAmo: Move items");
    api.updateTimeline();
}
```

**Required backend additions:**

1. Wrap REAPER's `ApplyNudge` function in the API abstraction
2. Add `beatsToTime(beats)` - convert quarter-note beats to seconds at current tempo
3. Add `barsToTime(bars)` - convert bar count to seconds
4. Add `barBeatToTime(bar, beat)` - convert absolute bar.beat to seconds
5. Add `getFirstSelectedItem()` - for calculating delta in moveTo

### 2.3 Frontend UI Design

**Location:** NavigateItemInfoBar's existing "More" BottomSheet, plus quick-nudge buttons in the info bar itself.

**Pattern to follow:** MarkerEditModal (`frontend/src/components/Timeline/MarkerEditModal.tsx`)

- Mode toggle: `'time' | 'beats'`
- Existing utilities: `formatTime`, `secondsToBeats`, `beatsToSeconds`, `formatBeatsToBarBeatTicks`, `parseBarBeatTicksToBeats`
- Time signature awareness: `beatsPerBar`, `denominator`, `barOffset`

**Quick nudge buttons (in info bar, always visible):**

```
[Selected: "Vocals 01"]  [◀ beat] [beat ▶]  [◀ bar] [bar ▶]  [Move...]
```

These send `item/nudge` with delta ±1 beat or ±1 bar. Tap-tap-tap workflow without opening anything.

**Move modal (opened via "Move..." button):**

```
┌─────────────────────────────────────────────────┐
│  Move Item                                 [x]  │
├─────────────────────────────────────────────────┤
│  Current: 00:15.250 (Bar 5, Beat 1)            │
├─────────────────────────────────────────────────┤
│  Mode:  [Time]  [Bar.Beat]                      │
│                                                 │
│  ┌─ Time mode ─────────────────────────────┐   │
│  │  Position: [00:15.250    ]              │   │
│  └─────────────────────────────────────────┘   │
│                                                 │
│  ┌─ Bar.Beat mode ─────────────────────────┐   │
│  │  Bar: [5    ]  Beat: [1.00  ]           │   │
│  └─────────────────────────────────────────┘   │
│                                                 │
│  Nudge: [-1 bar] [-1 beat] [+1 beat] [+1 bar]  │
│                                                 │
│              [Cancel]        [Move]             │
└─────────────────────────────────────────────────┘
```

**UI State:**

- `editMode: 'time' | 'beats'` - toggle between input modes
- `timeValue: string` - editable time string (MM:SS.ms)
- `beatsValue: string` - editable bar.beat string (e.g., "5.1.00")
- Sync both values when modal opens (from selected item position)
- Parse and validate on Move button click

**Conversion notes:**

- For absolute moves, frontend converts input to the appropriate command params
- Time mode: `item/moveTo` with `position` in seconds
- Bar.Beat mode: `item/moveTo` with `bar` and `beat` params
- Backend handles tempo map conversion to actual seconds

### 2.4 WebSocket Commands

```typescript
export const item = {
  // ...existing commands...

  /** Nudge selected items by relative amount */
  nudge: (delta: number, unit: 'seconds' | 'beats' | 'bars' = 'seconds'): WSCommand => ({
    command: 'item/nudge',
    params: { delta, unit },
  }),

  /** Move selected items to absolute time position */
  moveTo: (position: number): WSCommand => ({
    command: 'item/moveTo',
    params: { position },
  }),

  /** Move selected items to absolute bar.beat position */
  moveToBarBeat: (bar: number, beat: number = 1): WSCommand => ({
    command: 'item/moveTo',
    params: { bar, beat },
  }),
};
```

---

## Part 3: Existing Codebase Patterns to Follow

### 3.1 MarkerEditModal (PRIMARY REFERENCE)

**File:** `frontend/src/components/Timeline/MarkerEditModal.tsx`

This is the template for ItemMoveModal. Key patterns:

```typescript
// Mode toggle state
const [editMode, setEditMode] = useState<'time' | 'beats'>('time');
const [timeValue, setTimeValue] = useState('');
const [beatsValue, setBeatsValue] = useState('');

// Initialize from current position
useEffect(() => {
  setTimeValue(formatTime(marker.position, { precision: 3 }));
  const quarterNoteBeats = secondsToBeats(marker.position, bpm);
  const denominatorBeats = quarterNoteBeats * (denominator / 4);
  setBeatsValue(formatBeatsToBarBeatTicks(denominatorBeats, beatsPerBar, true, barOffset));
}, [marker, bpm, barOffset, beatsPerBar, denominator]);

// Parse input and execute move
const handleMove = useCallback(() => {
  let newPositionSeconds: number | null = null;

  if (editMode === 'time') {
    newPositionSeconds = parseTime(timeValue);
  } else {
    const denominatorBeats = parseBarBeatTicksToBeats(beatsValue, beatsPerBar, barOffset);
    if (denominatorBeats !== null) {
      const quarterNoteBeats = denominatorBeats * (4 / denominator);
      newPositionSeconds = beatsToSeconds(quarterNoteBeats, bpm);
    }
  }

  if (newPositionSeconds === null || newPositionSeconds < 0) {
    setError('Invalid position');
    return;
  }

  onMove(marker.id, newPositionSeconds);
  onClose();
}, [editMode, timeValue, beatsValue, ...]);
```

**Utilities to reuse** (from `frontend/src/utils/`):

- `formatTime(seconds, options)` - format for display
- `secondsToBeats(seconds, bpm)` - convert to quarter-note beats
- `beatsToSeconds(beats, bpm)` - convert back
- `formatBeatsToBarBeatTicks(beats, beatsPerBar, showTicks, barOffset)` - format bar.beat string
- `parseBarBeatTicksToBeats(str, beatsPerBar, barOffset)` - parse bar.beat input

### 3.2 Item Selection (already works)

**File:** `frontend/src/components/Timeline/Timeline.tsx` (lines 740-810)

Tapping an item calls:

```typescript
sendCommand(itemCmd.toggleSelect(firstItem.guid));
```

This selects/deselects items in REAPER. The selection state is polled back via items events at ~5Hz.

### 3.3 NavigateItemInfoBar (where move controls will live)

**File:** `frontend/src/components/Timeline/NavigateItemInfoBar.tsx`

Current structure:

- Shows selected item info (name, position, length)
- Take navigation buttons
- Color picker
- "More" button opens BottomSheet with detailed controls

Add quick nudge buttons inline, and "Move..." button that opens ItemMoveModal.

### 3.4 Tempo Commands (backend reference)

**File:** `extension/src/commands/tempo.zig`

Existing commands for tempo-aware operations:

- `tempo/snap` - snap time to grid
- `tempo/barsToTime` - convert bar.beat to seconds
- `tempo/timeToBeats` - convert seconds to beats with bar string

These can inform the new helper functions needed for item/nudge and item/moveTo.

---

## Part 4: UX Decisions (Resolved)

### Q1: Should moves respect REAPER's ripple/snap settings?

**Answer:** Yes, always. Users control these via existing toolbar buttons. ApplyNudge respects them automatically.

### Q2: Selection semantics?

**Answer:** Operate on REAPER's current selection. When user taps item in REAmo, it gets selected in REAPER. Move commands affect that selection. This is already how it works.

### Q3: Multi-item moves?

**Answer:** ApplyNudge moves all selected items together by the same delta. If user taps multiple items (multi-select), nudge moves them all.

**Edge case to document:** For `item/moveTo`, the delta is calculated from the **first selected item's position**. If items are at bar 1 and bar 5, and user says "move to bar 3":

- Delta = bar 3 - bar 1 = +2 bars
- Item at bar 1 → bar 3
- Item at bar 5 → bar 7

This is standard DAW behavior (relative group move). The alternative (rightmost item lands at target) would require different semantics. Current behavior is intentional.

### Q4: What about grouped items?

**Answer:** ApplyNudge automatically handles groups. If item A is grouped with B, nudging A moves B too.

---

## Part 5: Implementation Checklist

### Backend (Zig extension)

- [ ] Add `ApplyNudge` to REAPER API wrapper (`extension/src/reaper/raw.zig`)
- [ ] Add `beatsToTime(beats)` helper using REAPER's tempo map
- [ ] Add `barsToTime(bars)` helper
- [ ] Add `barBeatToTime(bar, beat)` helper
- [ ] Add `getFirstSelectedItem()` helper
- [ ] Implement `item/nudge` command handler (`extension/src/commands/items.zig`)
- [ ] Implement `item/moveTo` command handler
- [ ] Register commands in `extension/src/commands/registry.zig`
- [ ] Add unit tests for nudge/moveTo handlers

### Frontend (React)

- [ ] Add `item.nudge()`, `item.moveTo()`, `item.moveToBarBeat()` to WebSocketCommands.ts
- [ ] Add quick nudge buttons to NavigateItemInfoBar: `[◀ beat] [beat ▶] [◀ bar] [bar ▶]`
- [ ] Create ItemMoveModal component (follow MarkerEditModal pattern)
  - [ ] Mode toggle: time vs bar.beat
  - [ ] Time input with validation (MM:SS.ms format)
  - [ ] Bar.beat input with validation
  - [ ] Nudge buttons within modal
  - [ ] Move and Cancel buttons
- [ ] Add "Move..." button to NavigateItemInfoBar that opens ItemMoveModal
- [ ] Show current ripple/snap state indicator (reads from toolbar toggle states)

### Documentation

- [ ] Update extension/API.md with `item/nudge` and `item/moveTo` commands
- [ ] Add item movement to README features list

---

## Part 6: Why Not Real-Time Drag?

The original research document explored hold-to-drag with 100Hz updates. This was rejected for REAmo because:

1. **Doesn't fit the use case.** REAmo is for "staying at the instrument" - quick adjustments from an iPad on a stand. Precise finger-dragging on a small timeline while squinting is worse UX than tapping "+1 bar".

2. **Over-engineered.** Gesture wrapping, selection save/restore, 100Hz updates, drag cancellation - all for something users do occasionally when they notice an item is slightly off.

3. **Network latency.** WiFi adds 20-50ms latency. Real-time drag would feel sluggish. Atomic commands feel instant.

4. **Logic Remote doesn't do it.** Apple's own DAW remote doesn't let you drag regions. Users don't complain because that's not what you reach for the iPad to do.

If drag is ever needed, the research is preserved below, but it's not recommended.

<details>
<summary>Archived: Real-Time Drag Implementation (Not Recommended)</summary>

### Gesture-Wrapped ApplyNudge Pattern

```c
// === DRAG START ===
void OnDragStart(MediaItem* item) {
    Undo_BeginBlock2(nullptr);
    m_dragItem = item;
    m_startPos = GetMediaItemInfo_Value(item, "D_POSITION");

    // Cache original selection
    m_savedSelection.clear();
    int selCount = CountSelectedMediaItems(nullptr);
    for (int i = 0; i < selCount; i++) {
        m_savedSelection.push_back(GetSelectedMediaItem(nullptr, i));
    }
}

// === EACH TICK ===
void OnDragUpdate(double targetPos) {
    PreventUIRefresh(1);

    Main_OnCommand(40289, 0);  // Deselect all
    SetMediaItemSelected(m_dragItem, true);

    double currentPos = GetMediaItemInfo_Value(m_dragItem, "D_POSITION");
    double delta = targetPos - currentPos;

    if (delta != 0.0) {
        ApplyNudge(nullptr, 0, 0, 1, delta, false, 0);
    }

    PreventUIRefresh(-1);
    UpdateArrange();
}

// === DRAG END ===
void OnDragEnd() {
    Main_OnCommand(40289, 0);
    for (MediaItem* item : m_savedSelection) {
        SetMediaItemSelected(item, true);
    }

    Undo_EndBlock2(nullptr, "REAmo: Move item", 4);
    UpdateArrange();
}
```

WebSocket protocol for drag:

```json
{"type": "command", "command": "item/drag_start", "trackIdx": 0, "itemIdx": 0}
{"type": "command", "command": "item/drag_update", "position": 15.0}
{"type": "command", "command": "item/drag_end"}
```

</details>

---

## References

- REAPER API: <https://www.reaper.fm/sdk/reascript/reascripthelp.html>
- REAPER Config Variables: <https://mespotin.uber.space/Ultraschall/Reaper_Config_Variables.html>
- Existing item commands: `extension/src/commands/items.zig`
- NavigateItemInfoBar: `frontend/src/components/Timeline/NavigateItemInfoBar.tsx`
- BottomSheet component: `frontend/src/components/Modal/BottomSheet.tsx`
