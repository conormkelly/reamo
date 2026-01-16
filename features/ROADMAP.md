# Feature Priority List

Consolidated from PLANNED_FEATURES.md, PENDING_ITEMS.md, research docs, and ongoing development.

**Last updated:** 2026-01-16

---

## P0 — Quick Wins (Low Effort, High Value)

### Time Format Cycling

Tap time display to cycle: Bar.Beat → Seconds → SMPTE → Bar.Beat

**Status:** DEFERRED until requested. Research complete: [research/SMPTE.md](../research/SMPTE.md)

**Implementation:**

- Backend already sends `frameRate` and `dropFrame` in project event
- Add `timeDisplayMode` to UIPreferences (localStorage)
- Create `secondsToSMPTE()` helper — needs research for drop-frame edge cases (59.94fps, negative time)
- Use semicolon separator for drop-frame (29.97/59.94 fps)

**Effort:** TBD after research

---

## P2 — Feature Improvements (Larger Scope)

### Item Selection UX Refinement

Current item multi-select works but feels cluttered. Needs design rethink.

**Issues:**

- Info bar layouts clash (marker bar vs item bar - both can appear)
- "Item selection mode" concept is awkward - mode mainly just shows/hides info bar
- Batch operations UI needs polish

**Needs:** Design session to simplify the UX flow.

---

### Take Switcher Polish

Existing take switcher needs UX improvements:

- [ ] Larger touch targets for prev/next
- [ ] Show take name (if available) not just "Take 1/3"
- [ ] Visual preview of take waveforms (mini thumbnails?)
- [ ] Swipe gesture for take switching
- [x] "Delete take" confirmation flow
- [x] "Crop to active" quick action

**Effort:** ~1 day

---

## P3 — Future Features (Deferred)

### Folder Display

Show folder hierarchy in mixer/track views via flat navigation with breadcrumb "spill" pattern.

**Research:** [research/DAW_FOLDER_HIERARCHY_PATTERNS.md](../research/DAW_FOLDER_HIERARCHY_PATTERNS.md)

**Key Insight:** Most mobile DAW controllers ignore folders entirely. Avid Control's "spill" pattern (tap folder → see children only) is the gold standard. For mobile's limited screen space, externalize hierarchy to a flat bank-based navigation rather than visual nesting.

**Design Principles:**
- Folder tracks are normal tracks — no special tap behavior, just a folder icon badge
- Breadcrumb is the *only* folder navigation control (not on the tracks themselves)
- Folders bank + breadcrumb = fast folder discovery without scrolling through all tracks
- Filters stack on top of folder view (e.g., Armed tracks in Drums folder)

**Data Available:**
- Skeleton sends `fd` (folder_depth): `1` = folder parent, `0` = normal, `-N` = closes N folders
- Hierarchy computed client-side by walking track list with depth counter
- "Folders" built-in bank already exists (`fd === 1`)

**Phase 1 (MVP):**
- Folder icon badge on tracks where `fd === 1`
- Child count badge on folder tracks: `Drums (8)`
- "Folders" bank shows all folder tracks flat (already works)

**Phase 2 (Breadcrumb Navigation):**
- Compute folder hierarchy from skeleton (parent-child relationships)
- Breadcrumb UI: `All Folders > [Drums ▾] > [Toms ▾]`
- Each segment is a dropdown showing options at that level
- Final segment shows available subfolders to drill deeper
- Breadcrumb only visible when in folder navigation mode

**Phase 3 (Folder Banks):**
- New bank type: "folder" — saved shortcut to specific folder
- Auto-activates breadcrumb at that folder's level
- Enables quick access to frequently used folder views

**Banks vs Filters (Two Dropdowns):**

Banks and filters are orthogonal — banks define *which tracks*, filters define *what properties*. This requires restructuring the current "built-in banks" (Muted, Soloed, etc.) to be additive filters instead.

| Dropdown | Purpose | Options |
|----------|---------|---------|
| Bank | Which tracks to show | All Tracks, Smart banks, Custom banks, Folder banks |
| Filter | Property filter (additive) | None, Muted, Soloed, Armed, Selected, With Sends |

**Example Combinations:**
- "Drums" folder + "Armed" filter = armed tracks in Drums folder
- "All Tracks" + "Muted" = all muted tracks across project
- "Vox" smart bank + "Selected" = selected tracks matching "Vox"

**Bank Types:**
| Type | Purpose | Example |
|------|---------|---------|
| Smart | Pattern match track names | "Vox" matches Vox Lead, Vox Harm |
| Custom | Manual track selection | Hand-picked track GUIDs |
| Folder | Saved folder shortcut | "Drums" folder → shows children + breadcrumb |

**UX Flow:**
1. Select "Folders" bank → shows top-level folders, breadcrumb appears with `[Select folder ▾]`
2. Pick "Drums" from dropdown → view shows Drums' immediate children
3. Breadcrumb updates: `All Folders > Drums > [▾]`
4. If Toms is a subfolder, it appears in next dropdown to drill deeper
5. Tap any breadcrumb segment to navigate back or switch laterally

**Why Not Visual Nesting:**
- Only 3 tracks visible at a time on mobile — indentation wastes precious space
- Would need to conditionally show/hide nesting UI based on mode
- Users would have to scroll through all tracks to find folders
- Breadcrumb provides instant access to any folder level

---

### Touch Instruments

Chord strips and scale-locked keyboard for songwriting workflow.

**Status:** Drum Pads & Piano complete. Chord Strips next.

**Research:**
- [research/MIDI_TOUCH_INSTRUMENTS.md](../research/MIDI_TOUCH_INSTRUMENTS.md) - Latency analysis, StuffMIDIMessage API
- [research/LOGIC_CHORD_STRIPS.md](../research/LOGIC_CHORD_STRIPS.md) - Logic Remote layout & UX analysis
- [research/CHORD_STRIP_TECH_REFERENCE.md](../research/CHORD_STRIP_TECH_REFERENCE.md) - Scale bitmasks, chord generation algorithms
- [research/CHORD_STRIPS_PAIN_POINTS.md](../research/CHORD_STRIPS_PAIN_POINTS.md) - Logic Remote limitations & REAmo opportunities

**Key Finding:** WebSocket → StuffMIDIMessage achieves 5-15ms latency (matches Logic Remote). No WebMIDI complexity needed.

**Incremental Approach:**

1. ~~**Drum Pads (MVP)**~~ ✅ - 4x4 GM drum grid with multi-touch, Pointer Events API, 20ms debounce
2. ~~**Piano Keyboard**~~ ✅ - 2-octave keyboard with mod wheel, pitch bend, octave selector
3. **Chord Strips** - Diatonic chords with key/scale selector (see phases below)
4. ~~**Expression**~~ ✅ - Mod wheel (CC1), pitch bend (14-bit)

**Completed:**

- Backend: `midi/noteOn`, `midi/cc`, `midi/pitchBend` commands
- Frontend: InstrumentSelector, ChannelSelector (persisted per-instrument), DrumPadGrid, PianoKeyboard
- Orientation-locked UX: Drums=portrait only, Piano=landscape only (shows rotate warning otherwise)
- Flex-based piano layout with proper black key positioning
- Multi-touch support via Pointer Events API with pointer ID tracking
- Rate-limited continuous controllers: mod wheel 50Hz, pitch bend 120Hz with spring-back

**Chord Strips Implementation Phases:**

*Phase 1 (MVP):* ✅
- 7 vertical diatonic chord strips (triads only) arranged horizontally
- Key selector with enharmonic display (C# / Db) + Scale selector
- Proper enharmonic spelling (Eb not D#, Bb not A#)
- Automatic flat conversion for problem keys (D# → Eb spelling, etc.)
- Tap = note-on, release = note-off
- Landscape only, fixed velocity (100)

*Phase 1.5 (Polish) — NEEDS RESEARCH:*
- Which scales make sense for chord strips? (pentatonic has 5 notes, blues has 6)
- Double-sharp display symbol (𝄪 or x notation)
- Should key selector prefer flats for flat keys? (currently always shows C#, user picks)
- Consider restricting key selector to "practical" keys only

*Phase 2 (Enhanced):* ✅
- Vertical segments for inversions (Root, 1st, 2nd, Oct) - 4 segments matching Logic
- X-position velocity mapping (left=soft, right=loud)
- Octave up/down control in header
- Chord name integrated into top segment (maximizes touch target height)

*Phase 3 (Advanced):* ✅
- Bass notes (R, 5, 8) as vertical segments below inversions (7 equal-height segments total)
- Vertical swipe arpeggio between inversion segments
- Adaptive voicing "Voice Lead" toggle (minimizes voice movement)
- Strum mode with configurable delay (10-100ms)
- Next-chord color hints (green ring for suggested progressions)
- All controls moved to ViewHeader for cleaner layout

*Phase 4 (Customization) — Deferred:*
- 7ths toggle
- Hide/show specific chord strips (e.g., hide dim chord)
- Custom chord editing per strip (replace chord with variant like 7sus4)
- Configurable strip count (4-7 visible chords)
- Per-strip quality override (force minor instead of diminished)
- Adjustable inversion count (2-4 segments)

**Remaining for full instruments:**

- Velocity from pressure/position (touch pressure API)
- Aftertouch support

**Size:** ~~Backend S, Drum Pads MVP M~~, ~~Piano M~~, Chord Strips MVP S-M

---

### Automation Curve Editing

Touch-based drawing of automation lanes.

**From Logic Remote Analysis:**
> "Touch is actually superior for mouse for drawing curves"

**Effort:** Multi-week project

---

### MIDI Note Editing

Piano roll view with touch editing.

**Effort:** Multi-week project

---

### SWS Region Playlist Import

Parse existing SWS playlists from .RPP files for migration.

**Effort:** ~1 day (backend) + UI

---

### Toolbar Component Redesign

Current toolbar may need rework for better space utilization.

**Ideas:**

- Slot-based layout (buttons occupy 1-2 slots, auto-fit to width)
- Paging with indicator when buttons overflow (e.g., "1/2")
- Swipe navigation between pages on mobile
- Variable padding (compact/normal modes)

---

### Timeline Canvas Architecture

Single canvas for timeline content to fix browser compositing bugs.

**Status:** Research complete: [research/TIMELINE_CANVAS_ARCHITECTURE.md](../research/TIMELINE_CANVAS_ARCHITECTURE.md)

**Key Finding:** Layered Canvas2D (not WebGL) with DOM playhead. Playhead is already DOM - main work is replacing per-item canvases with batched draws + ImageBitmap caching.

**Current issues:**

- Waveform brightness changes at viewport edges (per-item canvas compositing)
- Waveform jitter during momentum scroll (cosmetic)

**Size:** L (significant refactor, but patterns well-defined)

---

### Add FX Browser

Frontend UI to browse and add available FX plugins to tracks.

**API Discovery:**

- `EnumInstalledFX(index, &nameOut, &identOut)` — iterates all installed plugins
- `TrackFX_AddByName(track, fxname, recFX, instantiate)` — adds FX by ident

**Implementation:**

1. Backend command `fx/enumInstalled` returns full plugin list (name + ident)
2. Frontend shows searchable list (grouped by type: VST3/VST2/AU/JS)
3. User taps plugin → sends `fx/add` with track index and ident
4. Backend calls `TrackFX_AddByName(track, ident, false, -1)`

**Notes:**

- `fxname` can have prefix: `VST3:`, `VST2:`, `AU:`, `JS:`, `DX:`
- `instantiate=-1` always creates new instance
- Could cache plugin list (rarely changes during session)

---

## Priority Rationale

**P0 items** are picked because:

- Backend support already exists
- Components can be reused (BottomSheet)
- High user value for minimal effort
- Complete existing UX patterns

**P1 items** improve existing features users already interact with daily.

**P2 items** require architectural changes but unlock new workflows.

**P3 items** are substantial new feature areas that need dedicated planning.

---

## Future Optimizations

Low-priority performance improvements to consider when scaling or if profiling indicates need.

### WebSocket Compression (gzip)

Per-message deflate for large payloads (action list ~985KB). Blocked on websocket.zig library update for Zig 0.15. Expected 10-15x compression for text payloads.

### Diff-Based Events

Only send changed fields instead of full state snapshots. Would reduce bandwidth for large track counts but adds complexity.

### FX Polling Optimization

Poll FX state on-demand or on track selection change, not every 30ms. Could integrate with CSurf hybrid architecture (see `docs/architecture/CSURF_HYBRID.md`) for push-based FX change notifications.

### Idle When No Clients

Skip all polling when `clientCount() == 0`. One-line change in timer callback. Trade-off: ~30ms delay to first update on connect.

### Per-Track Metering Subscriptions

Currently all visible tracks get metered. Could subscribe per-track for large projects where only a few tracks are visible.
