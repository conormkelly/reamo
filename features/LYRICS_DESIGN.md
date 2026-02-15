# Lyrics & Chord Teleprompter — System Design

**Status:** Design draft
**Target:** v2.0
**Last updated:** 2026-02-14

## Vision

A lyrics and chord display system for REAmo that turns a phone into a teleprompter synced to REAPER's timeline. The differentiator vs OnSong, ForScore, and other chord chart apps: native DAW integration. Chords sync to the playhead, sections map to regions, timing is beat-aware.

Two levels of value:

1. **30-second value** (no timing required) — Paste ChordPro text, get a readable chord chart on your phone immediately. Static scroll, same as any chord chart app but living inside your REAPER project.
2. **Full value** (with timing) — Tap through the song once during playback to create time-stamped lyric items. Phone becomes a synced teleprompter that follows the playhead.

---

## Data Model — Dual Representation

The system maintains two parallel representations of lyrics data:

### Untimed: ChordPro Source in ProjExtState

The canonical source text, stored in REAPER's project-level key-value store. Available the instant the user pastes it — no timing step required.

| ProjExtState Key | Value |
|---|---|
| `REAmo/lyrics_source` | Full ChordPro source text (may contain multiple songs separated by `{new_song}`) |
| `REAmo/lyrics_meta` | JSON: `{"songs": [{"title": "...", "key": "C", "capo": 0, "startPosition": 0.0}]}` |

The phone can read this via the existing ProjExtState subscription and render a formatted chord chart immediately. No items, no timing, no LYRICS track needed.

### Timed: Items on a LYRICS Track

After the timing step, each lyric line becomes a REAPER media item on a dedicated track:

| Item Property | Stores | Example |
|---|---|---|
| `D_POSITION` | When the line starts (seconds) | `12.345` |
| `D_LENGTH` | Duration until next line | `4.2` |
| `P_NOTES` | ChordPro-annotated line | `[Am]Amazing [G]grace, how [C]sweet the sound` |
| Take name | Plain text (visible in arrange view) | `Amazing grace, how sweet the sound` |
| `I_CUSTOMCOLOR` | Section type color | Blue=verse, green=chorus, orange=bridge |

The LYRICS track looks like a subtitle track in a video editor — small colored items with text labels, arranged against the timeline. Users can see and drag items in REAPER's arrange view on desktop.

**Color authority:** The extension is the single source of truth for item colors. The phone reads `I_CUSTOMCOLOR` from item data and displays it — it does not independently derive "Chorus = green." This means if a user manually recolors items in REAPER, the phone respects that.

### Phone Display Logic

The phone determines display mode based on what data exists:

| Timed items exist? | ChordPro source exists? | Display mode |
|---|---|---|
| Yes | Yes or No | **Synced teleprompter** — follows playhead, items drive scroll position |
| No | Yes | **Static chord chart** — manual scroll or auto-scroll by estimated duration |
| No | No | **Empty state** — "Import lyrics" prompt |

---

## Entry Flow — Paste & Parse

### Where Parsing Happens

**Phone-side only**, using [ChordSheetJS](https://github.com/martijnversluis/ChordSheetJS) in the browser. This means:

- One parser, one codebase, one place to fix bugs
- Live preview before committing
- No ChordPro parsing in Zig
- The extension receives pre-parsed structured data

### Supported Input Formats

ChordSheetJS handles format auto-detection:

| Format | Example | Detection |
|---|---|---|
| **ChordPro inline** | `[Am]Amazing [G]grace` | Brackets containing valid chord names adjacent to lyrics |
| **Chords-over-words** | Chord line above lyric line, whitespace-aligned | Line of only chords followed by line of only words |
| **Ultimate Guitar** | Same as chords-over-words + `[Verse]` headers | Section headers in brackets that aren't chords |
| **Plain lyrics** | No chords at all | Fallback — just text |

### Line Length Safety Valve

ChordPro source lines are author-controlled, but pasted text (especially from Ultimate Guitar) often has very long lines. A line that wraps to 3-4 visual lines on iPhone creates a bad teleprompter experience — one tap advances through too much text.

**Rule:** During the preview step, auto-split any line exceeding ~65 characters (roughly 2 visual lines at teleprompter font size) into sub-lines. Show split points with a visual indicator. Let the user adjust splits before entering the timing pass.

This follows subtitle editor convention — Aegisub and Subtitle Edit both enforce maximum line lengths because a subtitle that fills the screen is a bad subtitle.

### The Paste UI

```
┌──────────────────────────┐
│ Import Lyrics             │
│                           │
│ ┌───────────────────────┐ │
│ │ Paste ChordPro, UG,   │ │
│ │ or plain lyrics here   │ │
│ │                        │ │
│ └───────────────────────┘ │
│                           │
│ Detected: ChordPro ✓      │
│ 24 lines across 6 sections│
│                           │
│ ┌───────────────────────┐ │
│ │ Preview:               │ │
│ │                        │ │
│ │ Chorus                 │ │
│ │      D        G   D   │ │
│ │ 1. Swing low, sweet    │ │
│ │    chariot,             │ │
│ │                  A7    │ │
│ │ 2. Comin' for to carry │ │
│ │    me home.             │ │
│ │        ...              │ │
│ └───────────────────────┘ │
│                           │
│ [Save as Chart] [Time It] │
└──────────────────────────┘
```

**Two exit paths:**

- **"Save as Chart"** — Store ChordPro in ProjExtState only. Instant static chord chart on phone. No timing, no LYRICS track. Done in 5 seconds.
- **"Time It"** — Proceed to tap-to-advance flow. Creates timed items on LYRICS track.

---

## Timing Flow — Tap-to-Advance

### The Concept

Play the song in REAPER. Phone shows lyric lines one at a time. Tap when each line starts. One playthrough = fully timed lyrics.

A typical song has 20-30 lines. At ~2 seconds per line, the timing pass takes one playthrough of the song (~3-4 minutes). It's fast, musical (you're listening to the song), and produces accurate timing.

### Quantization

**Always quantize to the beat grid.** Every tap is snapped to the nearest beat (using REAPER's `TimeMap2_timeToBeats`, already bound).

Rationale:
- Items at beat 1.37 look sloppy in REAPER's arrange view
- Unquantized items fight REAPER's snap grid when dragged for adjustment
- Lyrics almost always start on or very near beats
- Sub-beat timing error is invisible to the performer (the teleprompter scrolls smoothly regardless)
- Quantization setting: **beat** (default), **half-beat**, **bar**, or **off** — exposed as a toggle before starting the timing pass

### Cursor Positioning (Multi-Song)

Before starting the timing pass, show the current cursor position and offer positioning options:

```
┌──────────────────────────┐
│ Start Timing              │
│                           │
│ Song: "Amazing Grace"     │
│ 24 lines, 6 sections     │
│                           │
│ Start from:               │
│ ● Current cursor (2:15 / │
│   Bar 33)                 │
│ ○ "Song 2" marker (4:32) │
│ ○ Project start (0:00)   │
│                           │
│ [Play from Here] [Begin] │
└──────────────────────────┘
```

- Shows time AND bar number for spatial orientation
- Lists any nearby markers/regions as starting point options
- "Play from here" button lets user audition the position before committing
- Prevents the "I tapped 30 lines over the wrong section" disaster

### The Timing UI

```
┌──────────────────────────┐
│ Timing — 0:42 ♪ Playing   │
│                           │
│  Comin' for to carry     │  ← just tapped (fading)
│  me home.                 │
│                           │
│ ┌───────────────────────┐ │
│ │                        │ │
│ │  I looked over Jordan, │ │  ← NEXT (large, highlighted)
│ │  and what did I see,   │ │
│ │                        │ │
│ └───────────────────────┘ │
│                           │
│  Comin' for to carry     │  ← on deck (dimmed)
│  me home.                 │
│                           │
│ ┌───────────────────────┐ │
│ │       TAP TO STAMP     │ │  ← full-width button
│ └───────────────────────┘ │
│                           │
│  [Undo] Lines: 5/24  [✓] │
└──────────────────────────┘
```

- Full-width tap target at bottom (or the entire lower half of screen)
- Shows previous line (fading), current line (large/highlighted), next line (dimmed)
- Progress counter: "Lines: 5/24"
- Undo button: removes last item, rewinds queue one position
- Finish button (✓): ends timing session early if remaining lines aren't needed
- Auto-finishes when all lines are tapped

### Post-Timing: Auto-Length Assignment

After the timing pass completes (all lines tapped or user taps finish):

1. Each item's length = next item's position minus this item's position
2. Last item in each section: extend to the section's end (derived from next section's first item, or a default 4 beats)
3. All wrapped in a single undo block: "REAmo: Time lyrics"

---

## Section ↔ Region Mapping

ChordPro sections (`{start_of_verse}`, `{start_of_chorus}`, etc.) carry structural meaning. REAPER regions carry timeline meaning. The mapping between them depends on project state.

### After Timing: Create Regions

If the project has no regions (or no matching regions), offer to create them from the timed section boundaries:

```
┌──────────────────────────┐
│ Create Regions?           │
│                           │
│ Your timed lyrics define  │
│ these sections:           │
│                           │
│ ■ Chorus    0:00 - 0:15  │
│ ■ Verse 1   0:15 - 0:42  │
│ ■ Chorus    0:42 - 0:57  │
│ ■ Verse 2   0:57 - 1:24  │
│ ■ Chorus    1:24 - 1:39  │
│                           │
│ [Create Regions] [Skip]  │
└──────────────────────────┘
```

Section start = position of first item with that section tag.
Section end = position + length of last item with that section tag.
Colors follow convention: blue=verse, green=chorus, orange=bridge, purple=pre-chorus.

### Before Timing: Match to Existing Regions

If the project already has regions, show a two-column mapping UI:

```
┌──────────────────────────┐
│ Match Sections to Regions │
│                           │
│ Lyrics        → Region   │
│ ─────────────────────────│
│ Chorus       → Chorus 1 ▾│
│ Verse 1      → V1       ▾│
│ Verse 2      → ⚠ None   ▾│
│                           │
│ Pre-populated obvious     │
│ matches. Uncertain ones   │
│ highlighted.              │
│                           │
│ [Confirm] [Skip Matching] │
└──────────────────────────┘
```

- Left column: ChordPro section names
- Right column: dropdown of REAPER regions (plus "None/skip")
- Pre-populate obvious matches by name
- Highlight uncertain matches in yellow
- User confirms in one screen (~10 seconds)
- When matched: auto-distribute lines within each region's time range (no tapping needed, or tap to refine)

---

## Multi-Song Projects

REAPER projects can contain multiple songs (worship setlists, live performance backing tracks, podcast episodes with music). The design handles this without a "setlist" abstraction — the timeline IS the structure.

### How It Works

Each song's lyrics occupy a time range on the LYRICS track. The teleprompter follows the playhead and shows whatever items are at the current position. No mode switching, no "select current song" UI.

**Import flow for multi-song projects:**

1. Position cursor at the start of Song 2 in the timeline
2. Open lyrics import, paste Song 2's ChordPro
3. The import UI shows starting position with time/bar readout
4. Tap through Song 2 (items land at the right positions)
5. Repeat for remaining songs

**Song boundaries** are natural:
- If songs already have markers or regions, the import UI offers them as starting points
- Gaps between songs (silence, transitions) have no items — the teleprompter shows nothing or "Up next: [Song Title]"
- The `{title}` directive from ChordPro can create a marker at each song's start

**ProjExtState metadata tracks multiple songs:**
```json
{
  "songs": [
    {"title": "Amazing Grace", "key": "C", "capo": 0, "startPosition": 0.0},
    {"title": "How Great Thou Art", "key": "Bb", "capo": 0, "startPosition": 245.0}
  ]
}
```

---

## Teleprompter Display

### Synced Mode (timed items exist)

- Current playhead line positioned at **35% from top** of viewport (maximizes read-ahead on iPhone's small screen)
- Smooth scrolling via `transform: translate3d()` (GPU-composited)
- `requestAnimationFrame` loop interpolates between transport tick updates
- Current section highlighted with subtle colored sidebar
- Chords rendered above lyrics in contrasting color (e.g., cyan on dark background)
- **Dark mode default** — white/light text on black, optimized for stage/studio lighting

**Transport state handling:**

| Playhead behavior | Teleprompter response |
|---|---|
| Normal playback | Smooth continuous scroll |
| Paused | Freeze in place, subtle pause indicator |
| Small scrub backward | Smooth reverse animation |
| Large jump (marker, seek) | Fast 200-300ms animated transition to new position |
| Song boundary crossed | Show song title briefly, then new song's lyrics |

### Static Mode (ChordPro source only, no timed items)

- Standard scrollable chord chart (manual touch scroll)
- Optional auto-scroll: estimate total duration from tempo + bar count, scroll at constant rate
- Tap song section headers to jump within the chart
- Transposition button (key change applied at display layer, doesn't modify source)

### Typography

- Sans-serif font, optimized for readability at arm's length
- Font size auto-fits to screen width with user-adjustable override
- Line spacing 1.3-1.5x for easy line tracking during scroll
- Chords in a distinct weight/color from lyrics
- Section headers as colored dividers

---

## Extension Command Protocol

All commands follow the existing handler pattern:
```zig
pub fn handle*(api: anytype, cmd: protocol.CommandMessage, response: *mod.ResponseWriter) void
```

### New REAPER API Binding

One function to add to `raw.zig`:

```zig
.addMediaItemToTrack = getFunc(info, "AddMediaItemToTrack",
    fn (?*anyopaque) callconv(.c) ?*anyopaque),
```

Returns a new empty item pointer. Position, length, notes, color set via existing `SetMediaItemInfo_Value` and `setItemNotes`.

### Commands

#### `lyrics/import`

Store ChordPro source in ProjExtState. No items created, no timing. This is the "Save as Chart" fast path.

```json
← {
    "command": "lyrics/import",
    "source": "{title: Amazing Grace}\n{key: C}\n\n{start_of_chorus}\nSwing [D]low...",
    "startPosition": 245.0
  }

→ {"success": true, "payload": {"songIndex": 0, "lineCount": 24, "sections": ["Chorus", "Verse 1", "Verse 2"]}}
```

Extension: parse minimally to extract title/key/metadata. Store full source in ProjExtState. Broadcast updated lyrics metadata event.

**Re-import handling:** If lyrics already exist for this song (matched by `startPosition` range), the phone should show a confirmation: "This song already has lyrics. Replace them?" On confirmation, the extension clears existing items in that time range and overwrites ProjExtState source. The replacement is wrapped in a single undo block ("REAmo: Replace lyrics") so the user can revert to the previous version.

#### `lyrics/prepare`

Set up a timing session. Extension creates LYRICS track if needed, stores the line queue in memory.

```json
← {
    "command": "lyrics/prepare",
    "lines": [
      {
        "text": "Swing low, sweet chariot,",
        "chordpro": "Swing [D]low, sweet [G]chari[D]ot,",
        "section": "Chorus"
      },
      ...
    ],
    "quantize": "beat",
    "startPosition": 0.0
  }

→ {"success": true, "payload": {"trackIdx": 5, "lineCount": 24}}
```

Extension:
- Find track named "LYRICS" or create one via `InsertTrackAtIndex`
- Allocate `LyricsTimingSession` struct holding the line queue
- Store start position for multi-song offset

#### `lyrics/tap`

Stamp the next line at the current playhead position. **Zero payload** — the extension reads the playhead from the C API and the next line from the queue.

```json
← {"command": "lyrics/tap", "clientTimestamp": 1707900000123}

→ {"success": true, "payload": {"index": 4, "position": 12.345, "beat": "4.1.00", "remaining": 20}}
```

The optional `clientTimestamp` is for development observability — the phone can compare its tap time against the snapped beat position to verify quantization is absorbing latency correctly. Not used in production logic.

Extension:
- Read playhead via `GetCursorPosition()`
- Quantize to nearest beat via `TimeMap2_timeToBeats` (if quantize != "off")
- Pop next line from queue
- `AddMediaItemToTrack` → set position, notes (ChordPro), take name (plain text), color (by section type from color convention)
- `UpdateTimeline()` so items appear in arrange view
- Respond with index, snapped position, remaining count

#### `lyrics/undo`

Remove the last stamped item, push its line back onto the queue.

```json
← {"command": "lyrics/undo"}

→ {"success": true, "payload": {"index": 3, "remaining": 21}}
```

Extension:
- Delete last created item via `DeleteTrackMediaItem`
- Push line back to front of queue
- `UpdateTimeline()`

#### `lyrics/finish`

End timing session, auto-assign item lengths.

```json
← {"command": "lyrics/finish"}

→ {"success": true, "payload": {"itemCount": 24}}
```

Extension:
- Record the playhead position at the moment `lyrics/finish` is received (natural song-end boundary)
- Auto-length: each item extends to next item's start position
- Last item in song: extend to the finish-tap playhead position (the user is presumably at the song's end when they tap finish). If no finish-tap position, extend to the end of the enclosing region. Fall back to 4 beats.
- Wrap in undo block: "REAmo: Time lyrics"
- Free the timing session
- Broadcast full lyrics event

#### `lyrics/get`

Request current lyrics state (items + metadata). Used for initial load and reconnection.

```json
← {"command": "lyrics/get"}

→ {
    "success": true,
    "payload": {
      "items": [
        {
          "guid": "{ABCD-1234}",
          "position": 12.345,
          "length": 4.2,
          "chordpro": "Swing [D]low, sweet [G]chari[D]ot,",
          "section": "Chorus"
        },
        ...
      ],
      "metadata": {
        "songs": [{"title": "Amazing Grace", "key": "C", "capo": 0}]
      },
      "source": "{title: Amazing Grace}\n..."
    }
  }
```

Note: extension sends raw ChordPro strings per item. The phone parses them for display using ChordSheetJS. One parser, one place.

#### `lyrics/update`

Edit an item's content by GUID (for phone-side quick edits).

```json
← {"command": "lyrics/update", "guid": "{ABCD-1234}", "chordpro": "[Am]Amazing [G]grace", "text": "Amazing grace"}
```

#### `lyrics/delete`

Remove a single item by GUID.

#### `lyrics/clear`

Remove all items from LYRICS track + clear ProjExtState lyrics data. Confirmation should happen phone-side before sending.

#### `lyrics/createRegions`

Create REAPER regions from section boundaries (post-timing).

```json
← {"command": "lyrics/createRegions"}

→ {"success": true, "payload": {"regionsCreated": 5}}
```

Extension:
- Group items by section tag
- For each section: create region from first item's position to last item's end
- Set region color by section type
- Undo block: "REAmo: Create lyric regions"

---

## Subscription / Event Push

### Lyrics Event

New event type on the **MEDIUM tier (5Hz)**, same tier as markers and regions.

**Cheap change detection:** During normal playback, lyrics items almost never change. Rather than hashing all item positions and notes content 5 times per second, first check REAPER's undo state count (`Undo_CanUndo2` returns a string that changes on any undo-point creation). If the undo state hasn't changed since the last poll, skip the expensive item enumeration entirely. This turns the 5Hz poll into "check one value, bail out 99% of the time." Only when the undo state changes (user dragged an item, edited notes, etc.) do we enumerate items and hash for real changes.

```json
{
  "type": "event",
  "event": "lyrics",
  "payload": {
    "items": [
      {
        "guid": "{ABCD-1234}",
        "position": 12.345,
        "length": 4.2,
        "chordpro": "Swing [D]low, sweet [G]chari[D]ot,",
        "section": "Chorus"
      }
    ],
    "metadata": {
      "songs": [{"title": "Amazing Grace", "key": "C", "capo": 0}]
    },
    "hasSource": true
  }
}
```

The `hasSource` flag tells the phone whether a ChordPro source is available in ProjExtState (avoids sending the full source text in every 5Hz update). The phone fetches source via `lyrics/get` on demand.

### Desktop Edit Detection

When the user drags items in REAPER's arrange view, the 5Hz poll detects position changes via hash comparison and pushes updated lyrics events. No special mechanism needed — the existing tier polling pattern handles this automatically.

---

## Frontend Architecture

### New Files

| File | Purpose |
|---|---|
| `store/slices/lyricsSlice.ts` | Lyrics state: items, metadata, source, timing session status |
| `core/WebSocketCommands.ts` | Add `lyrics.*` command builders (extend existing file) |
| `core/WebSocketTypes.ts` | Add lyrics event type definitions (extend existing file) |
| `views/Lyrics/LyricsView.tsx` | Top-level lyrics view (routes between modes) |
| `views/Lyrics/LyricsPaste.tsx` | Import/paste UI with ChordSheetJS parsing + preview |
| `views/Lyrics/TapToAdvance.tsx` | Timing session UI |
| `views/Lyrics/Teleprompter.tsx` | Synced performance display |
| `views/Lyrics/StaticChart.tsx` | Untimed chord chart display |
| `views/Lyrics/RegionMapping.tsx` | Two-column section ↔ region matching UI |
| `lib/chordpro.ts` | ChordSheetJS wrapper: parse, format, split long lines, extract metadata |

### Dependencies

- `chordsheetjs` — ChordPro/UG parsing, transposition, format conversion. ~380 GitHub stars, TypeScript, actively maintained.

### Slice Shape

```typescript
interface LyricsSlice {
  // Data
  items: LyricItem[];           // Timed items from LYRICS track
  metadata: LyricsMetadata;     // Song title, key, capo
  source: string | null;        // Raw ChordPro source from ProjExtState
  hasTimedItems: boolean;       // Determines display mode

  // Timing session
  timingActive: boolean;
  timingProgress: { current: number; total: number } | null;

  // Actions
  setLyricsEvent: (payload: LyricsEventPayload) => void;
  setTimingState: (active: boolean, progress?: TimingProgress) => void;
}
```

---

## Section Color Convention

Consistent across item colors, region colors, and UI section indicators:

| Section Type | Color | Hex |
|---|---|---|
| Verse | Blue | `#4A90D9` |
| Chorus | Green | `#5CB85C` |
| Bridge | Orange | `#F0AD4E` |
| Pre-Chorus | Purple | `#9B59B6` |
| Intro/Outro | Gray | `#888888` |
| Instrumental | Teal | `#5BC0DE` |
| Tag/Coda | Pink | `#E91E63` |

---

## Implementation Order

### Phase 1: Static Chart (fastest path to value)

1. `lyrics/import` command — store ChordPro in ProjExtState
2. `lyrics/get` command — read ChordPro back
3. Frontend: `LyricsPaste.tsx` with ChordSheetJS parsing + preview
4. Frontend: `StaticChart.tsx` — scrollable chord chart, no timing
5. Frontend: `lyricsSlice.ts` + event wiring
6. `{comment: Chorus}` expansion — detect repeat references in ChordSheetJS parsing and inline-expand them in the rendered static chart. Worship charts use this pattern heavily; without it the first worship team user sees "Chorus" as a text label instead of the actual chorus lyrics at the repeat point.

**Result:** User can paste ChordPro on phone, see formatted chord chart with repeated sections expanded. Value in 30 seconds.

### Phase 2: Timed Teleprompter

6. REAPER API: bind `AddMediaItemToTrack`
7. `lyrics/prepare` + `lyrics/tap` + `lyrics/undo` + `lyrics/finish` commands
8. `lyrics` subscription (5Hz poll of LYRICS track items)
9. Frontend: `TapToAdvance.tsx` — timing UI
10. Frontend: `Teleprompter.tsx` — synced display following playhead

**Result:** Full synced teleprompter. Items visible in REAPER arrange view.

### Phase 3: Polish

11. `lyrics/createRegions` command
12. Frontend: `RegionMapping.tsx` — section ↔ region matching
13. Auto-distribute lines within matched regions (skip timing for pre-structured projects)
14. Multi-song support (cursor positioning UI, song metadata)
15. Transposition UI (display-layer key change via ChordSheetJS)

---

## Known Rough Edges & Future Work

### Disconnect During Timing

The timing session state (line queue, progress) lives in the extension's memory. If the phone disconnects mid-timing (screen lock, WiFi blip, accidental navigation), the session is lost — but items created so far remain on the LYRICS track. On reconnect, the phone sees orphaned items via `lyrics/get` but cannot resume the session.

**Accepted for v2.0:** The timing pass is only 3-4 minutes. Recovery path is "undo all, start over." The `lyrics/clear` command (or REAPER's undo) cleans up partial items. Persisting session state to ProjExtState for `lyrics/resume` is a possible future improvement but not worth the complexity now.

### Desktop Editing UX

Double-clicking a LYRICS track item opens REAPER's standard item properties dialog — functional but not discoverable. The take name and P_NOTES fields are editable but it's not obvious that P_NOTES contains ChordPro. A custom action "Edit lyric item" could open a cleaner dialog or push item data to the phone for editing. Not a launch blocker.

### Chord-Only Mode

Session musicians often need just chords without lyrics ("Am for 4 bars, G for 2 bars"). The current design handles this (ChordPro can have chords without lyrics), but the teleprompter display should optimize for it: large chord name, bar count, no wasted space on empty lyric lines.

### Live Chord Tap

A separate flow for charting chord changes in real-time: play the song, tap chords from a diatonic palette as they change. Each tap records chord + playhead time. This is complementary to the lyric timing flow but a distinct feature. Deferred to a follow-on design.

### Phone-Side Chord Editing

Tap-to-place chords on lyrics (the "Chord Mode" concept from research). The phone becomes a visual chord editor: lyrics displayed read-only, tap a syllable to place a chord above it, chord picker replaces the keyboard. Deferred — v1 gets chords from the imported ChordPro source.

### File-Drop Import

Watch for `.chopro` / `.txt` files in the project folder, auto-import. Requires a minimal Zig-side parser (just line splitting + bracket extraction). Lower priority than phone-based import.

### `{comment: Chorus}` Expansion — Timed Mode

Phase 1 handles `{comment: Chorus}` for static charts by inline-expanding repeated sections during ChordSheetJS parsing. For Phase 2 (timed items), the question is: virtual expansion at display time, or duplicate items on the track?

**Recommendation: duplicate items on the track.** The whole point of items-on-track is that what you see in REAPER is what the phone displays. Virtual expansion breaks that mental model — the arrange view would show a gap where the phone shows chorus lyrics. Creating real items at real positions keeps the two views consistent. During the timing pass, the expanded lines are already in the queue (ChordSheetJS expands them before sending to `lyrics/prepare`), so duplicate items are created naturally.
