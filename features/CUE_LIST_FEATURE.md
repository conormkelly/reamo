# Cue List Feature Specification

## Why This Feature Matters

### The Problem

From user research, two underserved segments emerged:

**Live performers and rehearsals:**
> "Absolutely critical that the songs/sessions load quickly and seamlessly between songs."

AbleSet's $49+ price tag for Ableton proves market demand for setlist management with song-section jumping. REAPER users have no equivalent without walking to the computer.

**Songwriters experimenting with arrangement:**
Record a verse and chorus once, then ask: "What would it sound like with 4 verses, then 2 choruses, then back to verse?" Currently requires manually duplicating regions. A playlist approach lets you experiment non-destructively.

### The Opportunity

REAmo already has regions and markers on a timeline. A Cue List is just a different *presentation* — a vertical tappable list instead of horizontal timeline, optimized for:

- Quick tap-to-jump navigation
- Playlist mode with loop counts
- Visibility from across the room

This is frontend-only for basic mode, with extension work for playlist playback.

---

## Feature Overview

### Two Modes

| Mode | Purpose | Implementation |
|------|---------|----------------|
| **Navigation Mode** | Tap region/marker to jump | Frontend-only, uses existing `region/goto` command |
| **Playlist Mode** | Define sequence with loop counts, auto-advance | Extension work for playback monitoring |

### Views

```
┌─────────────────────────────────────────────────────────┐
│ Cue List                          [Edit] [▶ Play All]  │
├─────────────────────────────────────────────────────────┤
│ ▶ Intro                     x1              0:00       │  ← playing
├─────────────────────────────────────────────────────────┤
│   Verse 1                   x4              0:32       │
│   Chorus                    x2              1:04       │
│   Verse 2                   x4              1:36       │
│   Chorus                    x2              2:08       │
│   Bridge                    x1              2:40       │
│   Outro                     x1              3:12       │
└─────────────────────────────────────────────────────────┘
```

**Navigation Mode:** Tap any row → jump to that region's start
**Playlist Mode:** Hit "Play All" → auto-advance through sequence with loop counts

---

## Data Model

### REAmo Playlist Entry

```typescript
interface PlaylistEntry {
  regionId: number;      // REAPER region ID (from EnumProjectMarkers2)
  loopCount: number;     // -1 = infinite, 0 = skip, N = play N times
}

interface Playlist {
  name: string;
  entries: PlaylistEntry[];
}

interface PlaylistState {
  playlists: Playlist[];
  activePlaylistIndex: number | null;
  currentEntryIndex: number | null;
  loopsRemaining: number | null;
  isPlaying: boolean;
}
```

### Storage

REAmo stores playlists in REAPER's EXTSTATE for persistence and API accessibility:

```
Key: "REAMO" / "PLAYLIST_0"
Value: JSON string of Playlist object
```

This differs from SWS which uses project extension config (not accessible via API).

---

## SWS Import (Read-Only)

### Why Import Matters

Users with existing SWS Region Playlists shouldn't have to rebuild them. REAmo can detect and import SWS playlists on project load.

### Confirmed SWS RPP Format

From empirical testing on real .RPP files:

```
<EXTENSIONS
  <S&M_RGN_PLAYLIST Untitled 1
    1073741828 1
    1073741825 1
    1073741827 1
  >
  <S&M_RGN_PLAYLIST "With infinite"
    1073741825 -1
    1073741828 4
  >
>
```

**Format breakdown:**

| Element | Format | Example |
|---------|--------|---------|
| Header | `<S&M_RGN_PLAYLIST <name>` | `<S&M_RGN_PLAYLIST "My Set"` |
| Name | Unquoted or `"quoted with spaces"` | `Untitled 1` or `"With infinite"` |
| Entry | `<region_id> <loop_count>` | `1073741828 4` |
| Infinite loop | `loop_count = -1` | `1073741825 -1` |
| Block close | `>` | |

**Region ID encoding:**

SWS uses REAPER's internal region IDs with a flag bit:

| Decimal | Hex | Actual Region |
|---------|-----|---------------|
| 1073741825 | `0x40000001` | Region 1 |
| 1073741826 | `0x40000002` | Region 2 |

To extract: `region_index = region_id & 0x3FFFFFFF`

### Import Flow

```
┌─────────────────────────────────────────────────────────┐
│ SWS Playlist Detected                    [Import →]     │
├─────────────────────────────────────────────────────────┤
│ "With infinite" (5 entries)                             │
│ "Untitled 1" (4 entries)                                │
├─────────────────────────────────────────────────────────┤
│ Import creates a copy in REAmo. Original unchanged.     │
└─────────────────────────────────────────────────────────┘
```

1. On project load, extension reads .RPP file path via `GetProjectPath()`
2. Parse file for `<S&M_RGN_PLAYLIST` blocks
3. Decode region IDs, cross-reference with current regions
4. Send `swsPlaylistDetected` event to frontend
5. User clicks "Import" → copy to REAmo's EXTSTATE format

**Why read-only:**

- No risk of corrupting SWS data
- No conflicts with SWS undo integration
- No memory vs disk sync issues
- Clear separation of concerns

---

## Playlist Playback Engine

### Architecture

REAmo already polls at ~30ms. Add playlist monitoring to existing timer callback:

```zig
const PlaylistEngine = struct {
    active: bool = false,
    playlist_idx: usize = 0,
    entry_idx: usize = 0,
    loops_remaining: i32 = 0,

    fn tick(self: *@This(), play_position: f64) void {
        if (!self.active) return;

        const entry = current_playlist.entries[self.entry_idx];
        const region = getRegionById(entry.region_id);

        // Check if we've passed region end
        if (play_position >= region.end_pos - 0.05) { // 50ms tolerance
            self.loops_remaining -= 1;

            if (self.loops_remaining <= 0 and entry.loop_count != -1) {
                // Advance to next entry
                self.entry_idx += 1;
                if (self.entry_idx >= current_playlist.entries.len) {
                    self.active = false;
                    return;
                }
                self.loops_remaining = current_playlist.entries[self.entry_idx].loop_count;
            }

            // Seek to (current or next) region start
            const next_region = getRegionById(current_playlist.entries[self.entry_idx].region_id);
            api.SetEditCurPos(next_region.start_pos, false, true);
        }
    }
};
```

### Seeking Behavior

| Scenario | Result |
|----------|--------|
| Regions contiguous (end = next start) | Seamless playback |
| Gap between regions | Brief silence during seek |
| Same region looping | Seeks back to start, tiny gap |
| Infinite loop (`-1`) | Never advances, loops forever |

REAPER's `SetEditCurPos(..., true)` with `seekplay=true` provides near-gapless seeking, acceptable for most use cases.

---

## Protocol

### Events (Server → Client)

**Playlist state broadcast:**

```json
{
  "type": "event",
  "event": "playlist",
  "payload": {
    "playlists": [{
      "name": "My Setlist",
      "entries": [
        {"regionId": 1, "loopCount": 4},
        {"regionId": 2, "loopCount": 2}
      ]
    }],
    "activePlaylistIndex": 0,
    "currentEntryIndex": 1,
    "loopsRemaining": 3,
    "isPlaying": true
  }
}
```

**SWS playlist detection:**

```json
{
  "type": "event",
  "event": "swsPlaylistDetected",
  "payload": {
    "playlists": [{
      "name": "With infinite",
      "entries": [
        {"regionId": 1, "loopCount": -1},
        {"regionId": 4, "loopCount": 4}
      ]
    }]
  }
}
```

### Commands (Client → Server)

**Playlist management:**

```json
{"type": "command", "command": "playlist/create", "name": "New Setlist", "id": "1"}
{"type": "command", "command": "playlist/delete", "playlistIdx": 0, "id": "2"}
{"type": "command", "command": "playlist/rename", "playlistIdx": 0, "name": "Gig Set", "id": "3"}
```

**Entry management:**

```json
{"type": "command", "command": "playlist/addEntry", "playlistIdx": 0, "regionId": 3, "loopCount": 2, "id": "4"}
{"type": "command", "command": "playlist/removeEntry", "playlistIdx": 0, "entryIdx": 1, "id": "5"}
{"type": "command", "command": "playlist/setLoopCount", "playlistIdx": 0, "entryIdx": 0, "loopCount": 4, "id": "6"}
{"type": "command", "command": "playlist/reorderEntry", "playlistIdx": 0, "fromIdx": 2, "toIdx": 0, "id": "7"}
```

**Playback control:**

```json
{"type": "command", "command": "playlist/play", "playlistIdx": 0, "id": "8"}
{"type": "command", "command": "playlist/playFromEntry", "playlistIdx": 0, "entryIdx": 2, "id": "9"}
{"type": "command", "command": "playlist/stop", "id": "10"}
{"type": "command", "command": "playlist/next", "id": "11"}
{"type": "command", "command": "playlist/prev", "id": "12"}
```

**SWS import:**

```json
{"type": "command", "command": "playlist/importSws", "swsPlaylistIdx": 0, "id": "13"}
```

---

## UI Components

### CueListView

Main container component:

```typescript
function CueListView() {
  const { playlists, activePlaylistIndex, currentEntryIndex, isPlaying } = usePlaylistState();
  const regions = useRegions();

  return (
    <div className="cue-list-view">
      <CueListHeader
        playlists={playlists}
        activeIndex={activePlaylistIndex}
        onPlayAll={() => sendCommand('playlist/play', { playlistIdx: activePlaylistIndex })}
      />
      <CueListEntries
        entries={playlists[activePlaylistIndex]?.entries ?? []}
        regions={regions}
        currentEntryIndex={currentEntryIndex}
        isPlaying={isPlaying}
        onEntryTap={(idx) => sendCommand('playlist/playFromEntry', { entryIdx: idx })}
        onLoopCountChange={(idx, count) => sendCommand('playlist/setLoopCount', { entryIdx: idx, loopCount: count })}
      />
    </div>
  );
}
```

### Entry Row

```
┌─────────────────────────────────────────────────────────┐
│ ▶│ Chorus                    [x2 ▼]           1:04     │
│  │ ████████████░░░░░░░░░░░░  (progress bar)            │
└─────────────────────────────────────────────────────────┘
```

| Element | Behavior |
|---------|----------|
| Play indicator | Shows when this entry is active |
| Region name | Tap to jump (navigation mode) |
| Loop count dropdown | `x1`, `x2`, `x3`, `x4`, `∞` |
| Time | Region start position |
| Progress bar | Shows playback position within region (optional) |

### Edit Mode

Toggle between:

- **View mode:** Tap to jump, read-only display
- **Edit mode:** Drag to reorder, tap loop count to change, swipe to delete

---

## Implementation Checklist

### Phase 1: Navigation Mode (Frontend-only)

- [ ] Create `CueListView` component
- [ ] Display regions as vertical list
- [ ] Tap row → send existing `region/goto` command
- [ ] Highlight region containing current play position
- [ ] Add "Cues" tab to view switcher

### Phase 2: Playlist Data Model (Extension)

- [ ] Define playlist EXTSTATE schema
- [ ] Add `playlist/create`, `playlist/delete` commands
- [ ] Add `playlist/addEntry`, `playlist/removeEntry` commands
- [ ] Add `playlist/setLoopCount`, `playlist/reorderEntry` commands
- [ ] Broadcast playlist state on change

### Phase 3: Playlist Playback (Extension)

- [ ] Add `PlaylistEngine` struct to timer callback
- [ ] Monitor play position vs region boundaries
- [ ] Implement `SetEditCurPos` seeking on region end
- [ ] Track loop counts, advance entries
- [ ] Add `playlist/play`, `playlist/stop`, `playlist/next`, `playlist/prev` commands
- [ ] Broadcast current entry index and loops remaining

### Phase 4: SWS Import (Extension)

- [ ] Read .RPP file path via `GetProjectPath()`
- [ ] Parse `<S&M_RGN_PLAYLIST` blocks
- [ ] Decode region IDs (strip `0x40000000` flag)
- [ ] Cross-reference with current project regions
- [ ] Send `swsPlaylistDetected` event
- [ ] Add `playlist/importSws` command

### Phase 5: UI Polish (Frontend)

- [ ] Edit mode with drag-to-reorder
- [ ] Loop count dropdown/stepper
- [ ] Swipe-to-delete entries
- [ ] Progress bar within entry
- [ ] Playlist selector (multiple playlists)
- [ ] SWS import modal

---

## SWS Action Bridge (Optional)

For users who want to trigger SWS Region Playlist directly:

| REAmo Command | SWS Action |
|---------------|------------|
| `sws/playPlaylist` | `_S&M_PLAY_RGN_PLAYLIST` |
| `sws/nextRegion` | `_S&M_PLAY_NEXT_RGN_PLAYLIST` |
| `sws/prevRegion` | `_S&M_PLAY_PREV_RGN_PLAYLIST` |

These trigger via `NamedCommandLookup()` + `Main_OnCommand()`. Note: SWS has no "stop playlist" action — use standard transport stop.

---

## Use Cases

### Live Performance Setlist

1. Create playlist: "Friday Gig"
2. Add regions: Intro, Song 1, Song 2, Song 3, Encore
3. Set loop counts: all x1
4. Hit "Play All" at show start
5. Each song auto-advances when region ends

### Songwriting Arrangement Sketch

1. Record verse region, chorus region
2. Create playlist: "Structure Test"
3. Add: Verse x4, Chorus x2, Verse x2, Chorus x4, Outro x1
4. Play → hear full arrangement without duplicating regions
5. Don't like it? Change to Verse x2, Chorus x1 — instant feedback

### Rehearsal Loop

1. Working on a tricky chorus
2. Add Chorus with loop count `-1` (infinite)
3. Hit play → loops forever until manual stop
4. Nail it? Tap "Next" to advance to bridge

---

## Future Enhancements

- **Lyrics sync:** Display lyrics for current region (pull from region notes or separate field)
- **Stop markers:** Pause at specific points, wait for manual continue
- **Tempo changes:** Set tempo per entry for medley/mashup sets
- **Cross-fade:** Smooth audio transition between regions (requires audio processing)
- **Export to SWS:** Write back to SWS format for users who switch between tools
