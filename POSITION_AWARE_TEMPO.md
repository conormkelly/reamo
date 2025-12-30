# Position-Aware Tempo Implementation Plan

## Overview

Add tempo marker support so that BPM/time signature display, bar.beat formatting, and snapping all respect tempo changes throughout the project.

**Design Principles:**
- Server handles all tempo math using REAPER's TimeMap2 APIs
- Client receives pre-calculated beat values and formatted bar strings
- Position-aware display matches REAPER's toolbar behavior

---

## What Changes

### Current Behavior
- BPM/time signature from project settings (static)
- `formatBeats(seconds, bpm)` uses single BPM for bar.beat display
- `snapToGrid(seconds, bpm)` snaps using single BPM
- Breaks when project has tempo markers

### New Behavior
- BPM/time signature reflects tempo **at current position** (playhead or cursor)
- Regions/markers include pre-formatted bar strings from server
- Snapping via server round-trip (tempo-aware)
- Works correctly with tempo markers, ramps, time sig changes

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                           REAPER                                 │
│  Tempo Map: tempo markers, ramps, time sig changes              │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                        Zig Extension                             │
│                                                                  │
│  Uses REAPER's native APIs for all tempo math:                  │
│  ├── TimeMap_GetTimeSigAtTime() → tempo/timesig at position     │
│  ├── TimeMap2_timeToBeats() → seconds to beats                  │
│  └── TimeMap2_beatsToTime() → beats to seconds                  │
│                                                                  │
│  Sends to client:                                                │
│  ├── Position-aware BPM and time signature                      │
│  ├── Pre-formatted bar strings for regions and markers          │
│  └── Snap results (snapped time + beats)                        │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼ WebSocket
┌─────────────────────────────────────────────────────────────────┐
│                       React Frontend                             │
│                                                                  │
│  ├── Display BPM/time sig from transport (already position-aware)│
│  ├── Display bar.beat using server-provided strings             │
│  └── Snap via server round-trip during drag                     │
└─────────────────────────────────────────────────────────────────┘
```

---

## Server Changes

### Transport Event (Enhanced)

```json
{
  "type": "event",
  "event": "transport",
  "payload": {
    "playState": 1,
    "position": 10.5,
    "cursorPosition": 10.5,
    "bpm": 95.0,
    "timeSignature": { "numerator": 4, "denominator": 4 },
    "positionBeats": 21.0,
    "cursorPositionBeats": 21.0,
    "positionBars": "6.1.00",
    "tempoMarkerCount": 3
  }
}
```

**Key change:** `bpm` and `timeSignature` now reflect tempo **at current position**:
- When playing: tempo at playhead position
- When stopped: tempo at edit cursor position

This matches REAPER's toolbar behavior.

**New fields:**
- `positionBeats` — Playhead position in beats
- `cursorPositionBeats` — Edit cursor in beats
- `positionBars` — Formatted "bar.beat.ticks" string
- `tempoMarkerCount` — Number of tempo markers (0 = fixed tempo project)

### Regions Event (Enhanced)

```json
{
  "type": "event",
  "event": "regions",
  "payload": [
    {
      "id": 1,
      "name": "Verse 1",
      "start": 0.0,
      "end": 16.0,
      "startBeats": 0.0,
      "endBeats": 32.0,
      "startBars": "1.1.00",
      "endBars": "9.1.00",
      "color": 16777215
    }
  ]
}
```

**New fields:**
- `startBeats` — Start position in beats
- `endBeats` — End position in beats
- `startBars` — Pre-formatted "bar.beat.ticks" (uses time sig at that position)
- `endBars` — Pre-formatted "bar.beat.ticks"

### Markers Event (Enhanced)

```json
{
  "type": "event",
  "event": "markers",
  "payload": [
    {
      "id": 1,
      "name": "Chorus",
      "position": 32.0,
      "positionBeats": 64.0,
      "positionBars": "17.1.00",
      "color": 16777215
    }
  ]
}
```

**New fields:**
- `positionBeats` — Position in beats
- `positionBars` — Pre-formatted "bar.beat.ticks"

### New Commands

#### `tempo/snap`

Snap a time position to the beat grid.

**Request:**
```json
{
  "command": "tempo/snap",
  "time": 15.7,
  "subdivision": 1
}
```

- `time` — Position in seconds
- `subdivision` — 1 = beat, 2 = 8th note, 4 = 16th note

**Response:**
```json
{
  "snappedTime": 16.0,
  "snappedBeats": 32.0
}
```

#### `tempo/getBarDuration`

Get the duration of one bar at a specific position (for minimum region length).

**Request:**
```json
{
  "command": "tempo/getBarDuration",
  "time": 10.5
}
```

**Response:**
```json
{
  "duration": 2.0,
  "durationBeats": 4.0,
  "bpm": 120.0,
  "timesigNum": 4,
  "timesigDenom": 4
}
```

#### `tempo/timeToBeats`

Convert seconds to beats (for edge cases).

**Request:**
```json
{
  "command": "tempo/timeToBeats",
  "time": 16.0
}
```

**Response:**
```json
{
  "beats": 32.0,
  "bars": "9.1.00"
}
```

---

## Implementation Phases

### Phase 1: Position-Aware Transport (0.5 days)

Make BPM and time signature display reflect current position.

**Extension Changes:**

`extension/src/reaper.zig` — Add API binding:
```zig
// Position-aware tempo lookup (returns tempo AND time sig at position)
TimeMap_GetTimeSigAtTime: ?*const fn (
    ?*anyopaque, f64, *c_int, *c_int, *f64
) callconv(.c) void = null,

pub fn getTempoAtPosition(self: *const Api, time: f64) TempoAtPosition {
    var num: c_int = 4;
    var denom: c_int = 4;
    var bpm: f64 = 120;
    if (self.TimeMap_GetTimeSigAtTime) |f| {
        f(null, time, &num, &denom, &bpm);
    }
    return .{ .bpm = bpm, .timesig_num = num, .timesig_denom = denom };
}
```

`extension/src/transport.zig`:
```zig
pub fn poll(api: *const reaper.Api) State {
    // ... existing code to get play_state, play_pos, cursor_pos ...

    // Use position-aware tempo
    const current_pos = if (play_state & 1 != 0) play_pos else cursor_pos;
    const tempo = api.getTempoAtPosition(current_pos);

    return .{
        .bpm = tempo.bpm,
        .time_sig_num = tempo.timesig_num,
        .time_sig_denom = tempo.timesig_denom,
        // ... other fields ...
    };
}
```

**Frontend Changes:** None - existing display automatically shows position-aware values.

**Deliverable:** Toolbar BPM/time sig updates as playhead moves through tempo changes.

---

### Phase 2: Region/Marker Beat Positions (0.5 days)

Add beat positions and bar strings to regions and markers.

**Extension Changes:**

`extension/src/regions.zig`:
```zig
fn formatRegion(api: *const Api, region: MarkerInfo, buf: []u8) []const u8 {
    const start_beats = api.timeToBeats(region.pos);
    const end_beats = api.timeToBeats(region.end);
    const start_bars = api.formatBars(region.pos);
    const end_bars = api.formatBars(region.end);

    // Add to JSON output
}
```

`extension/src/markers.zig`:
```zig
fn formatMarker(api: *const Api, marker: MarkerInfo, buf: []u8) []const u8 {
    const position_beats = api.timeToBeats(marker.pos);
    const position_bars = api.formatBars(marker.pos);

    // Add to JSON output
}
```

**Frontend Changes:**

`frontend/src/core/types.ts`:
```typescript
export interface Region {
  id: number;
  name: string;
  start: number;
  end: number;
  startBeats: number;
  endBeats: number;
  startBars: string;
  endBars: string;
  color?: number;
}

export interface Marker {
  id: number;
  name: string;
  position: number;
  positionBeats: number;
  positionBars: string;
  color?: number;
}
```

**Deliverable:** Regions and markers include beat positions and pre-formatted bar strings.

---

### Phase 3: Server-Side Snapping (1 day)

Add tempo/snap command and update drag hooks to use it.

**Extension Changes:**

`extension/src/commands/tempo.zig` (NEW):
```zig
pub fn register(registry: *CommandRegistry) void {
    registry.register("tempo/snap", handleSnap);
    registry.register("tempo/getBarDuration", handleGetBarDuration);
    registry.register("tempo/timeToBeats", handleTimeToBeats);
}

fn handleSnap(api: *const reaper.Api, cmd: CommandMessage, response: *ResponseWriter) void {
    const time = cmd.getFloat("time") orelse {
        response.err("time required");
        return;
    };
    const subdivision = cmd.getInt("subdivision") orelse 1;

    // Convert to beats, snap, convert back
    const beats = api.timeToBeats(time);
    const subdiv_f: f64 = @floatFromInt(subdivision);
    const snapped_beats = @round(beats * subdiv_f) / subdiv_f;
    const snapped_time = api.beatsToTime(snapped_beats);

    response.beginObject();
    response.field("snappedTime", snapped_time);
    response.field("snappedBeats", snapped_beats);
    response.endObject();
}
```

**Frontend Changes:**

`frontend/src/core/WebSocketCommands.ts`:
```typescript
export const tempo = {
  snap: (time: number, subdivision: number = 1): WSCommand => ({
    command: 'tempo/snap',
    params: { time, subdivision },
  }),
  getBarDuration: (time: number): WSCommand => ({
    command: 'tempo/getBarDuration',
    params: { time },
  }),
};
```

`frontend/src/components/Timeline/hooks/useRegionDrag.ts`:
```typescript
// Replace local snapToGrid with server call
const handlePointerMove = useCallback(async (e: React.PointerEvent) => {
  const time = positionToTime(e.clientX);

  // For resize: snap to bar boundaries via server
  if (regionDragType === 'resize-start' || regionDragType === 'resize-end') {
    const { snappedTime } = await sendCommand(tempo.snap(time, 1));
    updateDrag(e.clientX, snappedTime);
  }
  // Move logic unchanged (snaps to region boundaries)
}, [/* ... */]);
```

**Deliverable:** Snapping is tempo-aware across tempo changes.

---

### Phase 4: Use Server Bar Strings for Display (0.5 days)

Update components to display server-provided bar strings.

**Frontend Changes:**

Replace `formatBeats(region.end, bpm, ...)` with server-provided string:

```typescript
// Before
const endDisplay = formatBeats(region.end, bpm, barOffset, beatsPerBar, denominator);

// After
const endDisplay = region.endBars;
```

Server provides ready-to-display strings - no client formatting needed.

**Why server strings?** A region in a 6/8 section needs different bar formatting than one in 4/4. The server knows the time signature at each position.

**Files to update:**
- `RegionInfoBar.tsx` — Region end display
- `TimelineRegions.tsx` — Region labels
- `MarkerEditModal.tsx` — Marker position display

**Deliverable:** Bar.beat displays are accurate across tempo and time sig changes.

---

## File Summary

### Extension Files

| File | Action | Purpose |
|------|--------|---------|
| `src/reaper.zig` | MODIFY | Add `TimeMap_GetTimeSigAtTime`, `TimeMap2_timeToBeats` bindings |
| `src/transport.zig` | MODIFY | Use position-aware tempo lookup |
| `src/regions.zig` | MODIFY | Add beat/bar fields to output |
| `src/markers.zig` | MODIFY | Add beat/bar fields to output |
| `src/commands/tempo.zig` | CREATE | `tempo/snap`, `tempo/getBarDuration`, `tempo/timeToBeats` |
| `src/commands.zig` | MODIFY | Register tempo command handlers |

### Frontend Files

| File | Action | Purpose |
|------|--------|---------|
| `src/core/types.ts` | MODIFY | Add beat/bar fields to Region, Marker types |
| `src/core/WebSocketCommands.ts` | MODIFY | Add tempo commands |
| `src/components/Timeline/hooks/useRegionDrag.ts` | MODIFY | Server-side snapping |
| `src/components/Timeline/hooks/useMarkerDrag.ts` | MODIFY | Server-side snapping |
| `src/components/Timeline/RegionInfoBar.tsx` | MODIFY | Use server bar strings |

---

## Testing Strategy

### Manual Testing

1. **Fixed tempo project** — Baseline, should work exactly as before
2. **Single tempo change** — Verify:
   - BPM display updates when playhead crosses tempo marker
   - Time sig display updates for time sig markers
   - Region bar.beat displays correct at their positions
3. **Tempo ramp** — Verify snap works correctly in ramped section
4. **Time signature change** — Verify bar numbering adjusts

### Integration Tests

```typescript
describe('tempo/snap command', () => {
  test('snaps to beat boundary at 120 BPM', async () => {
    const result = await sendCommand({ command: 'tempo/snap', time: 0.45, subdivision: 1 });
    expect(result.snappedTime).toBeCloseTo(0.5);  // 1 beat at 120 BPM
    expect(result.snappedBeats).toBe(1.0);
  });

  test('snaps correctly after tempo change', async () => {
    // With tempo marker at bar 5 changing from 120 to 60 BPM
    // Position after tempo change should snap using 60 BPM
  });
});
```

---

## Estimated Effort

| Phase | Description | Days |
|-------|-------------|------|
| 1 | Position-aware transport | 0.5 |
| 2 | Region/marker beat positions | 0.5 |
| 3 | Server-side snapping | 1 |
| 4 | Use server bar strings for display | 0.5 |
| - | Testing & polish | 0.5-1 |
| **Total** | | **3-3.5 days** |

---

## Migration Notes

- No breaking changes to WebSocket protocol (all new fields are additive)
- Frontend can gradually adopt server bar strings
- Snapping can be migrated one hook at a time
- Existing `formatBeats()` still works for transport position display

---

## Known Limitations

- **Snap grid**: Snaps to beat/bar boundaries only. Does not respect REAPER's user-defined grid settings (triplets, dotted notes, etc.)
- **Snap latency**: ~30ms round-trip for snap requests. If noticeable, can implement snap grid caching as a future enhancement.
