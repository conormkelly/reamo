# REAmo Roadmap

**Last updated:** 2026-02-04

---

## v1.0 — Release Blockers

Two items remaining before public release.

### Responsive Layout Refinement

App works well on iOS phone PWA but needs polish across form factors. First impressions matter.

**Test matrix:**

| Device | Mode | Status |
|--------|------|--------|
| iPhone (PWA) | Portrait | ✅ Primary dev target |
| iPhone (PWA) | Landscape | ⚠️ Needs testing |
| iPhone (Safari) | Both | ⚠️ Needs testing |
| iPad | Portrait | ⚠️ Needs testing |
| iPad | Landscape | ⚠️ Needs testing |
| Android phone | Chrome | ⚠️ Needs testing |
| Android tablet | Chrome | ⚠️ Needs testing |
| Desktop browser | - | ⚠️ Needs testing |

**Known issues to check:**

- Safe area insets (notch, home indicator) on different devices
- Mixer fader count at different widths
- Timeline track height at different heights
- Touch target sizes on tablets (may want larger)
- Orientation transitions (no layout jump)

**Effort:** M (mostly testing + CSS tweaks)

---

## Deferred — WIP Branch

### Swipe Comping

**Branch:** `feature/swipe-comping`

Touch-based take comping for fixed lane mode. Swipe across waveform to select which take plays for each time region — the mobile equivalent of REAPER's mouse-based swipe comping.

**Why deferred:** Frontend complexity was growing; returning to stabilize v1.0 features first.

**Backend (working):**

- `lanes/swipeComp` creates razor edits and promotes selection to comp lane
- `lanes/getState` returns lane metadata (numLanes, freeMode, compTargetLane)
- `lanes/setLanePlays`, `lanes/setCompTarget`, `lanes/moveCompUp/Down` commands
- `broadcastLanesEvent` sends real-time updates after lane operations
- Track skeleton includes `I_FREEMODE` for detecting fixed lanes mode

**Frontend (partial, needs iteration):**

- `compSlice` manages comp mode state, lane data, segments
- Comp mode renders lanes as virtual tracks in Timeline
- `WaveformLayer` filters items by fixedLane for per-lane rendering
- `CompControlsBar` with play matrix (in BottomSheet)
- `SwipeCompOverlay` handles swipe gestures and segment visualization
- `TimelineFooter` shows in comp mode with swipe/scroll toggle
- WebSocket protocol extended with `lanes` event type

**Known issues to address:**

- Segment visualization and tap-to-switch needs refinement
- Frontend state sync between segments and actual REAPER items
- UI polish for comp controls layout

**Requires:** REAPER 7.0+ (fixed track lanes API)

---

### Accessibility Pass

Review and improve accessibility before public release. REAPER + OSARA users represent an underserved audience.

**Checklist:**

- [ ] VoiceOver testing on iOS (navigate all views, verify announcements)
- [ ] Audit aria-labels on interactive elements (buttons, sliders, modals)
- [ ] Focus management in modals and sheets (trap focus, return on close)
- [ ] Keyboard navigation for desktop browser users
- [ ] Color contrast verification (WCAG AA minimum)
- [ ] Reduced motion support (`prefers-reduced-motion` media query)
- [ ] Screen reader announcements for state changes (play/stop, record, mute/solo)

**Effort:** S-M (audit + targeted fixes)

---

## v2.0 — Future Development

Features planned for post-release development.

### Move Items

Enable drag-to-move for selected items on timeline. First step towards full arrangement editing.

**Why this matters:** Research identified "touch-enabled arrangement view with direct region manipulation" as the killer differentiator vs Logic Remote. Waveform display is complete — now items need to be movable.

**Implementation approach:**

1. **Horizontal move (time)** — Drag item left/right to change position
2. **Vertical move (track)** — Drag item up/down to move to different track
3. **Multi-item move** — Selected items move together
4. **Snap behavior** — Respect REAPER's snap settings (grid, other items)

**Backend:**

- `item/setPosition` command with `itemGuid`, `position` (time), `trackGuid` (optional, for cross-track moves)
- Gesture-based undo coalescing (same pattern as faders)

**Frontend:**

- Drag gesture on item (distinguish from pan gesture on empty space)
- Ghost preview during drag showing destination
- Visual feedback for snap points

---

### Add Send to Track

Currently can view and adjust existing sends but not create new ones.

**Implementation:**

- `send/add` command with `sourceTrackGuid`, `destTrackGuid`
- UI in track detail modal or dedicated sends view
- Show available destination tracks (exclude self, existing destinations)

---

### Automation Curve Editing

Touch-based drawing of automation lanes.

**From Logic Remote Analysis:**
> "Touch is actually superior to mouse for drawing curves"

---

### MIDI Note Editing

Piano roll view with touch editing.

---

### Time Format Cycling (SMPTE)

Tap time display to cycle: Bar.Beat → Seconds → SMPTE → Bar.Beat

**Research complete:** [research/archived/general/SMPTE.md](../research/archived/general/SMPTE.md)

- Backend already sends `frameRate` and `dropFrame` in project event
- Add `timeDisplayMode` to UIPreferences (localStorage)
- Create `secondsToSMPTE()` helper

---

### Ruler Drag-to-Select

Drag on timeline ruler to create time selection. Currently have long-press-to-seek on ruler ticks; this would add drag gesture for selection creation.

**Deferred because:**
- Snap points need to be zoom-level specific (different density at different zooms)
- Edge cases: selecting beyond visible viewport, auto-scroll while dragging
- Long-press-to-seek + MakeSelectionModal covers the use case adequately for v1

**Implementation notes (when needed):**
- Create `useRulerDragSelect` hook following `usePlayheadDrag` pattern
- Pointer capture + vertical-cancel (50px threshold)
- On commit: set time selection AND seek playhead to selection start
- Snap to beats via `snapToGrid(time, bpm, 1)`

**Status:** Implement if requested

---

### Item Selection UX Polish

Current item multi-select works but feels cluttered. Needs design rethink.

- Info bar layouts clash (marker bar vs item bar)
- "Item selection mode" concept is awkward
- Batch operations UI needs polish

---

### Take Waveform Previews

Visual preview of take waveforms (mini thumbnails) in take switcher.
Deferred — requires fetching all takes' peaks.

---

### Context-Aware Take/Item Coloring ✅

**Status:** Complete (merged to main 2026-02-05)

Quick take rating during recording sessions. Tap to mark a take as keeper (green), maybe (yellow), or discard (red) without leaving the instrument. Colors visible in REAPER's take lanes for later comping.

**Behavior (two separate controls):**

- **Info bar swatch:** Always colors the active take. Displays take color with item color fallback (matches REAPER's render priority)
- **Bottom sheet "Item Color":** Always colors the item container
- **Batch mode:** Colors items (not takes)

**REAPER color priority chain (confirmed via Lua testing):**

1. Take custom color (`I_CUSTOMCOLOR` on `MediaItem_Take`) — wins if set
2. Item color (`I_CUSTOMCOLOR` on `MediaItem`) — fallback for uncolored takes
3. Theme default — if neither has custom color

**Platform note:** macOS REAPER stores colors as `0x01RRGGBB` (RGB). Windows uses `0x01BBGGRR` (COLORREF/BGR). Frontend `color.ts` treats values as RGB — correct for macOS. Cross-platform will need a conversion layer in the Zig backend if Windows support is added.

**Also shipped:** Removed position label from info bar (declutter), take nav round-robin wrap-around, fixed bare colon in ColorPickerInput when label is empty

---

### REAPER Version Feature Flags

Include REAPER version in connect/hello event for graceful feature degradation.

**Why this matters:** Some features are version-specific (e.g., swipe comping, fixed track lanes are REAPER 7+ features). Rather than breaking on older versions, the frontend can disable unavailable features.

**Implementation:**

- Backend: Add `reaperVersion: "7.24"` to hello/project event payload
- Frontend: Feature matrix mapping version → enabled features
- UI: Hide or grey out unavailable features with "Requires REAPER 7+" tooltip

**Example features needing version gates:**

| Feature | Minimum Version | Status |
|---------|-----------------|--------|
| Swipe comping | REAPER 7.0+ | Backend ready, frontend WIP (`feature/swipe-comping`) |
| Fixed track lanes | REAPER 7.0+ | Backend ready (part of swipe comping) |

**Effort:** S (backend trivial, frontend feature matrix)

---

### Subtle Recording Indicator Option

Settings toggle to reduce visual prominence of recording state for musicians with "red light fever."

**Why this matters:** Research shows recording anxiety is a real barrier—the prominent red recording indicator triggers performance anxiety in many musicians. A subtle mode helps them stay in performer mindset.

**Implementation:**

- Settings toggle: "Subtle recording indicator"
- When enabled: dim red to muted color, smaller indicator, no pulsing animation
- Transport still shows recording state, just less aggressively

**Effort:** XS (CSS toggle)

---

### Pre-roll Settings in Quick Actions

Surface metronome pre-roll (count-in bars) more prominently for self-recording musicians.

**Why this matters:** Pre-roll is essential for self-recording but currently buried in metronome settings. Musicians need quick access to "give me 2 bars before recording starts."

**Implementation:**

- Add pre-roll bar count to QuickActionsPanel (near metronome/click controls)
- Simple stepper: 0, 1, 2, 4 bars
- Visual indicator when pre-roll is active

**Effort:** XS (frontend only, settings already exist)

---

### Haptic Click

Haptic feedback as metronome. Phone vibrates on beat for silent click track.

**Why this matters:** Musicians practicing with headphones can feel the beat without audio bleed. Useful for quiet practice, recording in shared spaces, or when audio click interferes with performance.

**Implementation:**

- Use Vibration API (`navigator.vibrate()`) synced to beat
- Pattern options: downbeat only, all beats, subdivisions
- Intensity control (where hardware supports)
- Settings toggle: "Haptic metronome" (off by default)

**Challenges:**

- Latency compensation — vibration must anticipate beat
- iOS limitations (Vibration API not supported, may need Web Audio workaround)
- Battery impact at high BPM

**Effort:** S-M (sync timing is the tricky part)

---

### Mix Monitoring (Sonobus-style)

Monitor mix audio on phone while playing. Hear the DAW output through phone speakers/headphones.

**Why this matters:** Self-recording musicians can hear their mix without being tethered to studio monitors. Walk around the room while monitoring, or use phone as a "how does it sound on small speakers" check.

**Implementation approaches:**

1. **WebRTC stream** — REAPER sends audio via WebRTC peer connection
2. **Network audio** — Stream compressed audio over WebSocket (high latency)
3. **ReaStream plugin** — Leverage existing REAPER network audio plugin

**Challenges:**

- Latency must be low enough for monitoring (sub-100ms ideal)
- Audio routing complexity in REAPER (master output to network)
- Codec selection (Opus for quality/latency balance)
- Sync with video/waveform display

**Reference:** Sonobus uses Opus codec over custom UDP protocol for ~20ms latency.

**Effort:** L (significant audio streaming infrastructure)

---

### Practice Tools

Metronome modes that build internal timing and speed, not just keep time.

**Gap-Click Metronome:**

Click plays for N bars, then goes silent for N bars. Forces musicians to maintain internal time without dependency on the click. Based on Benny Greb's practice method (Time Guru app).

- Configurable gap length: 1, 2, 4, 8 bars
- Visual beat indicator continues during silence (shows if you drifted)
- Progressive mode: gaps get longer as you succeed
- Randomized gap option for advanced training

**Accelerating Metronome:**

Tempo increases gradually over time for speed-building practice.

- Start tempo → target tempo over N minutes
- Small increments (1-2 BPM) to avoid conscious awareness of change
- Optional "plateau" periods (stay at tempo for 30s before next bump)
- Visual progress indicator

**Why this matters:** Positions REAmo as a practice tool, not just a recording remote. Musicians would open it even when not recording.

**Implementation:** Leverages beat-accurate time sync; can control REAPER's metronome and tempo via actions.

**Effort:** M (requires beat-sync logic and UI)

---

### Sandbox Tools

Creative playgrounds that give permission to just play. Low-pressure modes for experimentation and jamming.

**Cues/Playlist** — Already implemented. Arrange regions into setlists, test song structures without duplicating audio.

**Looper Mode:**

Live looping surface for jamming. Record a phrase, it loops, layer on top, play along.

- Record loop of N bars (synced to tempo)
- Overdub layers
- Undo last layer
- Clear and restart
- Classic guitarist workflow — iPad as a loop pedal

**Design consideration:** How this maps to REAPER's actual looping/overdub modes needs exploration. Could use dedicated looper track with pre-configured FX, or leverage REAPER's native loop recording.

**Timebox Challenge:**

Constraint-based creation mode — random musical constraints, time limit, automatic closure. Research-validated approach to breaking perfectionism paralysis.

**Research validation:**

- Constrained creative work scores **23% higher on originality** than unconstrained work (Haught-Tromp, large effect size η²p = .53)
- Moderate time pressure preserves creativity; high pressure kills it — 45% less creative thinking on high-pressure days (Amabile, 12,000 diary entries)
- Constraints work by forcing exploration of unexpected territory, overriding default patterns
- The "carryover effect": constraint-based practice builds lasting creative capacity
- ~10% of output will be genuinely great — but only if you make enough (Jonathan Mann, 5,000+ consecutive songs)

**Core experience flow:**

1. **Challenge reveal** — Full-screen display of three constraints with reroll options
2. **Project auto-creation** — REAPER project with tempo set, regions marking song structure
3. **Recording phase** — Hidden timer with audio-only notifications
4. **Playback reveal** — 5-second countdown, then automatic playback from start
5. **Closure prompt** — Three equal options: Save / Mark for Later / Let It Go

**Three focusing constraints (v1):**

Research shows focusing constraints ("include this") outperform exclusionary ("avoid this"). Three constraints fit working memory — users can recall all without checking a reference.

| Constraint | Implementation |
|------------|----------------|
| **Key** | All 12 major/minor, weighted toward common keys with occasional wild cards |
| **Tempo** | Named ranges: Chill (60-80), Moderate (80-110), Energetic (110-140), Intense (140-180) |
| **Title** | Evocative phrases suggesting mood/imagery without dictating genre: "The Space Between Wanting", "Copper and Glass", "2AM Parking Lot" |

**Reroll essential:** Allow individual constraint rerolls (tap key to regenerate just key) and full regeneration. Random works, but needs escape valves.

**Time parameters:**

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Default duration | **20 minutes** | Amabile's "low-to-moderate" pressure zone |
| Selectable presets | 10 / 15 / 20 / 30 / 45 min | 10 = Kenny Beats extreme; 45 = deep focus (~23 min to reach flow) |
| Timer visibility | **Hidden by default** | Research: visible countdown creates anxiety; audio cues preserve urgency |
| 2-minute warning | Gentle chime | Mental preparation for closure |
| Completion | Distinct sound | Clear "done" signal |
| Stop type | **Soft stop** | "I'm in flow, give me 5 more minutes" extend option respects flow states |

**Song structure auto-generation:**

Removes blank canvas anxiety. Regions created in REAPER project:

```
Intro:    4 bars
Verse:    8 bars
Chorus:   8 bars
Verse 2:  8 bars
Chorus 2: 8 bars
Bridge:   8 bars
```

User can modify structure before starting (preserves autonomy). Tempo-adaptive: faster tempos get shorter bar counts.

**Closure options (equal prominence):**

- **Save to Library** — Archives with metadata (key, tempo, title, date)
- **Mark for Later** — Flag for revisiting/developing
- **Let It Go** — Explicit permission to not care; moves to "completed" without saving

Avoid elaborate reflection prompts ("What did you learn?") — the goal is permission to move on, not homework.

**The solo musician problem:**

Every successful constraint challenge (FAWM, NaNoWriMo, game jams) has community accountability. Solo home recording musicians don't. Mitigations:

- **"On This Day"** — Surface completed timeboxes from 30/90/365 days ago. Creates temporal community with past self.
- **Session stats** — Volume celebration: "This month you created 12 pieces totaling 47 minutes of original music"
- **Streak forgiveness** — Missing one day doesn't break streak if you complete one the next day
- **First sessions critical** — NaNoWriMo dropouts happen in week 1. First 3-5 timeboxes must feel achievable.

**V1 scope (ship the core loop fast):**

- Three-constraint generation (key, tempo, title)
- Duration presets (10/15/20/30/45)
- Individual + full reroll
- REAPER project auto-creation with tempo and regions
- Hidden timer with audio cues
- Automatic playback on completion
- Save / Mark / Let It Go options
- Basic library of completed timeboxes

**V2+ additions:**

- Difficulty levels (Beginner: 2 constraints, 30 min; Challenge: 4 constraints, 15 min)
- Light achievement system (volume milestones, not competition)
- "On This Day" feature
- Session statistics and monthly summaries
- Mood/genre as optional fourth constraint
- Time signature constraints (3/4, 6/8, 5/4)
- Musician-type templates (drummer, vocalist, producer)

**Effort:** M (v1 is project creation + timer + UI; v2 adds persistence and stats)

---

### Lyric/Chord Teleprompter

ChordPro import with timeline-synced display for performers.

**Core features:**

- Import lyrics + chords from ChordPro format, Ultimate Guitar, or plain text
- Display scrolls with REAPER playhead position
- Section markers from REAPER regions highlight current section
- Large, readable text designed for viewing from instrument position
- Transposition control

**Advanced features:**

- Annotation layer that saves with project
- Practice mode: loop current section with tempo reduction
- Performer view: full-screen teleprompter, minimal controls

**Use cases:**

- Singer-songwriters tracking vocals with lyrics visible
- Cover bands / worship bands with setlists
- Session musicians sight-reading charts

**Why this matters:** OnSong and ForScore are beloved because they combine lyrics, chords, and playback. REAmo can do this with native REAPER integration — charts live with the project, sync is automatic.

**Implementation:** Text rendering + ChordPro parsing + region sync. Substantial but well-defined.

**Effort:** M-L (parsing, rendering, sync logic)

---

### Session Stats

Recording activity visualization — tucked-away info screen for motivation and self-awareness.

**Metrics:**

- Recording streak: consecutive days with any recording activity
- Monthly summary: takes recorded, time spent, sessions count
- Personal records: longest session, most productive day
- Trend graphs: consistency over time

**Implementation:** Query REAPER project history and modification dates; persistent storage tracks session metadata.

**Effort:** S (mostly UI, minimal REAPER integration)

---

### Project Notes Reminder

Gentle nudge to document what you're doing.

**Behavior:**

- Toggleable setting: remind to add project notes every N minutes when not recording
- Non-intrusive notification (not a modal — subtle indicator)
- Leverage phone's native speech-to-text for quick voice notes
- Markers already easy to add/edit; this just prompts the habit

**Why this matters:** Musicians forget setup details, performance notes, and what worked. A gentle reminder builds the documentation habit without friction.

**Effort:** XS (timer + notification, settings toggle)

---

## v3.0+ — Long-term Ideas

### Folder Display

Show folder hierarchy in mixer/track views via flat navigation with breadcrumb "spill" pattern.

**Research:** [research/archived/competitive-analysis/DAW_FOLDER_HIERARCHY_PATTERNS.md](../research/archived/competitive-analysis/DAW_FOLDER_HIERARCHY_PATTERNS.md)

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

**Phase 1 (MVP):** ✅

- Folder icon badge on tracks where `fd === 1` (TrackInfoBar)
- Child count badge on folder tracks: `Drums (8)`
- "Folders" bank shows all folder tracks flat

**Phase 2 (Folder Navigation):** ✅

Implemented via bottom sheet instead of inline breadcrumb (saves vertical space on mobile).

- `FolderNavSheet` bottom sheet with breadcrumb navigation and track list
- Folder badge in TrackInfoBar is clickable → opens folder sheet and navigates to that folder
- FolderOpen button appears in ViewHeader when Folders bank is selected
- Breadcrumb in sheet: `All > Drums > Toms` with tap-to-navigate
- Toggle between "Subfolders" and "All tracks" view modes
- Path validation when skeleton changes (handles folder deletion)

**Banks vs Filters (Two Dropdowns):** ✅

Separated banks and filters into orthogonal controls:

| Control | Purpose | Options |
|---------|---------|---------|
| Bank dropdown | Which tracks to show | All Tracks, Folders, Custom banks |
| Filter button | Property filter | Muted, Soloed, Armed, Selected, With Sends |

- QuickFilterDropdown: compact filter icon + X button when active
- Bank selector simplified: All Tracks and Folders as first-class options
- Filters moved from "built-in banks" to dedicated dropdown with counts

**Example Combinations:**

- "Drums" folder + "Armed" filter = armed tracks in Drums folder
- "All Tracks" + "Muted" = all muted tracks across project

**Phase 3 (Folder Banks) — Deferred:**

- New bank type: "folder" — saved shortcut to specific folder
- Auto-opens folder sheet at that folder's level
- Enables quick access to frequently used folder views

---

### Touch Instruments

Chord pads and scale-locked keyboard for songwriting workflow.

**Status:** Drum Pads & Piano complete. Chord Pads next.

**Research:**

- [research/archived/competitive-analysis/MIDI_TOUCH_INSTRUMENTS.md](../research/archived/competitive-analysis/MIDI_TOUCH_INSTRUMENTS.md) - Latency analysis, StuffMIDIMessage API
- [research/archived/competitive-analysis/LOGIC_CHORD_STRIPS.md](../research/archived/competitive-analysis/LOGIC_CHORD_STRIPS.md) - Logic Remote layout & UX analysis
- [research/archived/competitive-analysis/CHORD_STRIP_TECH_REFERENCE.md](../research/archived/competitive-analysis/CHORD_STRIP_TECH_REFERENCE.md) - Scale bitmasks, chord generation algorithms
- [research/archived/competitive-analysis/CHORD_STRIPS_PAIN_POINTS.md](../research/archived/competitive-analysis/CHORD_STRIPS_PAIN_POINTS.md) - Logic Remote limitations & REAmo opportunities

**Key Finding:** WebSocket → StuffMIDIMessage achieves 5-15ms latency (matches Logic Remote). No WebMIDI complexity needed.

**Incremental Approach:**

1. ~~**Drum Pads (MVP)**~~ ✅ - 4x4 GM drum grid with multi-touch, Pointer Events API, 20ms debounce
2. ~~**Piano Keyboard**~~ ✅ - 2-octave keyboard with mod wheel, pitch bend, octave selector
3. **Chord Pads** - Diatonic chords with key/scale selector (see phases below)
4. ~~**Expression**~~ ✅ - Mod wheel (CC1), pitch bend (14-bit)

**Completed:**

- Backend: `midi/noteOn`, `midi/cc`, `midi/pitchBend` commands
- Frontend: InstrumentSelector, ChannelSelector (persisted per-instrument), DrumPadGrid, PianoKeyboard
- Orientation-locked UX: Drums=portrait only, Piano=landscape only (shows rotate warning otherwise)
- Flex-based piano layout with proper black key positioning
- Multi-touch support via Pointer Events API with pointer ID tracking
- Rate-limited continuous controllers: mod wheel 50Hz, pitch bend 120Hz with spring-back

**Chord Pads Implementation Phases:**

*Phase 1 (MVP):* ✅

- 7 vertical diatonic chord pads (triads only) arranged horizontally
- Key selector with enharmonic display (C# / Db) + Scale selector
- Proper enharmonic spelling (Eb not D#, Bb not A#)
- Automatic flat conversion for problem keys (D# → Eb spelling, etc.)
- Tap = note-on, release = note-off
- Landscape only, fixed velocity (100)

*Phase 1.5 (Polish) — NEEDS RESEARCH:*

- Which scales make sense for chord pads? (pentatonic has 5 notes, blues has 6)
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
- Hide/show specific chord pads (e.g., hide dim chord)
- Custom chord editing per strip (replace chord with variant like 7sus4)
- Configurable strip count (4-7 visible chords)
- Per-strip quality override (force minor instead of diminished)
- Adjustable inversion count (2-4 segments)

**Remaining for full instruments:**

- Velocity from pressure/position (touch pressure API)
- Aftertouch support

**Size:** ~~Backend S, Drum Pads MVP M~~, ~~Piano M~~, Chord Pads MVP S-M

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

### Toolbar Component Redesign ✅

Slot-based paged grid with uniform touch targets and swipe paging.

**Status:** ✅ Complete (2026-01-29)

**Implemented:**

- Slot-based grid layout with uniform 4 buttons per row
- Horizontal swipe paging with page indicator
- 48-54pt touch targets
- Pre-built defaults (Split, Glue, Delete, Marker, Ripple, Snap, Duplicate)
- In-app edit mode for customization
- Toggle state sync with REAPER

**Research:** [research/archived/ui-ux/MOBILE_TOOLBAR_UX.md](../research/archived/ui-ux/MOBILE_TOOLBAR_UX.md)

---

### Timeline Canvas Architecture ✅

Single canvas for timeline content to fix browser compositing bugs.

**Status:** ✅ Complete

**Research:** [research/archived/timeline-canvas/TIMELINE_CANVAS_ARCHITECTURE.md](../research/archived/timeline-canvas/TIMELINE_CANVAS_ARCHITECTURE.md)

**Implemented:**

- **TileBitmapCache:** Pre-renders waveform tiles to ImageBitmap via OffscreenCanvas, LRU eviction at 200 bitmaps (~50MB), calls `bitmap.close()` on evict
- **Per-track canvases:** Replaced per-item canvases with single canvas per track lane — eliminates DOM overhead for projects with many items
- **Never-clear rendering:** Track drawn regions, clear only item rects before redraw — fixes flash-to-black between render cycles
- **Synchronous fallback:** Draw peaks directly when ImageBitmap not cached, with adjacent LOD scaling
- **GPU-accelerated blitting:** `ctx.drawImage()` for hardware-accelerated tile compositing
- **1x DPR rendering:** 4x memory savings vs retina resolution (waveforms don't need subpixel precision)

**Fixed issues:**

- ~~Waveform brightness changes at viewport edges~~ — per-item canvas compositing eliminated
- ~~Waveform jitter during momentum scroll~~ — never-clear + sync fallback prevents blank frames

---

### Tile-Based Waveform System ✅

Complete rewrite of waveform rendering with multi-level LOD tile caching.

**Status:** ✅ Complete (Backend + Frontend)

**Backend (Zig + Lua bridge):**

- 8-level LOD system with 4x ratio between levels (was 3 levels with 10x/40x jumps)
- LOD 7 (finest): 1024 peaks/sec, 0.5s tiles — LOD 0 (coarsest): 0.0625 peaks/sec, 4096s tiles
- All peak fetching via Lua bridge (`reamo_internal_fetch_peaks.lua`) using `GetMediaItemTake_Peaks`
- Root source traversal via `GetMediaSourceParent` loop — fixes wrapper sources returning 0 peaks for items with take offsets
- Retry logic with `PCM_Source_BuildPeaks` fallback when initial fetch returns 0
- Per-subscription viewport tracking with debounced broadcasts

**Frontend (React + Canvas):**

- Tile cache with 500-tile LRU eviction and `makeTileCacheKeyString()` keying
- `assemblePeaksForViewport()` selector concatenates tiles for render
- LOD selection based on viewport duration thresholds
- 200ms debounce on viewport updates (prevents thrashing during pan/zoom)

**Stereo rendering:**

- Split lanes: L channel in top half, R channel in bottom half
- Mono files continue as single centered waveform

**Reference:** [docs/architecture/timeline/ADAPTIVE_WAVEFORM_ZOOM.md](../docs/architecture/timeline/ADAPTIVE_WAVEFORM_ZOOM.md)

---

### Viewport-Relative Pan & Zoom ✅

Momentum scrolling and zoom behavior improvements.

**Status:** ✅ Complete

**Pan momentum:**

- Velocity now viewport-relative (% of viewport/frame) not time-absolute (sec/frame)
- Same physical gesture = same screen-percentage movement at any zoom level
- Configurable friction (0.95) for faster decay, less settling time

**Follow playhead zoom:**

- With follow playhead enabled, zoom centers on playhead position (was: playhead drifted out of view)
- Both button zoom and pinch-to-zoom respect follow playhead as zoom anchor
- Makes toggle a "swiss army knife": find playhead, follow during playback, AND control zoom center

---

### Per-Device Layout Memory ✅

Remember last-used view and settings per device.

**Status:** ✅ Complete (localStorage)

**Implemented:**

- Last active view persisted and restored on load
- UI preferences (banks, filters, viewport position) stored per-device
- Instrument channel selection persisted per-instrument type

---

### Marker Navigation via Long-Press ✅

Touch-hold on position display reveals marker jumplist.

**Status:** ✅ Complete

**Implementation:** Long-press (500ms) on transport time display opens marker sheet with tap-to-jump. Matches Logic Remote's LCD touch-hold pattern identified in competitive analysis.

---

### PWA Version Detection ✅

Detect stale cache and prompt for update on iOS Safari.

**Status:** ✅ Complete

**Problem:** iOS Safari's aggressive dual-layer caching serves stale HTML/JS even after extension updates.

**Solution:**

- Compare stored `extensionVersion` + `htmlMtime` against server values on WebSocket connect
- If mismatch + `autoUpdateEnabled` (default): silent hard refresh with cache bust
- If mismatch + auto-update disabled: show "New version available" banner

**Hard refresh:**

- Clears Cache Storage and unregisters ServiceWorkers before navigate
- Cache-busting query param ensures fresh fetch
- Awaits cleanup to complete before page unload

---

### Add FX Browser ✅

Frontend UI to browse and add available FX plugins to tracks.

**Status:** ✅ Complete (Backend + Frontend)

**API:**

- `EnumInstalledFX(index, &nameOut, &identOut)` — iterates all installed plugins
- `TrackFX_AddByName(track, fxname, recFX, instantiate)` — adds FX by ident

**Implementation:**

1. ~~Backend command `fxPlugin/getList` returns full plugin list (name + ident)~~ ✅
2. ~~Frontend shows searchable list (grouped by type: VST3/VST2/AU/JS)~~ ✅
3. ~~User taps plugin → sends `trackFx/add` with track GUID and ident~~ ✅
4. ~~Backend calls `TrackFX_AddByName(track, ident, false, -1)`~~ ✅

**Notes:**

- Plugin list format: `[displayName, ident]` tuples
- Type prefix is in displayName (AU:, AUi:, VST3:, VST3i:, VST:, VSTi:, JS:)
- Frontend caches plugin list (fetched once per session)

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

### Dirty Flag Poll Deferral

When CSurf dirty flags trigger an immediate poll, defer the next tier poll to avoid redundant API calls.

**Current behavior:**

- Frame N: Dirty flag fires → immediate poll (not on tier tick)
- Frame N+3: Tier tick → polls AGAIN (redundant, hash prevents broadcast but API calls still made)

**Proposed:** Track `last_poll_frame` per resource, skip tier poll if recently polled via dirty flag.

**Applicable resources:**

| Resource | Tier | Dirty Flag | Savings |
|----------|------|------------|---------|
| Markers/regions | MEDIUM (5Hz) | `markers_dirty` | Skip redundant 5Hz poll |
| Tempo map | LOW (1Hz) | `tempo_dirty` | Skip redundant 1Hz poll |
| FX details | MEDIUM (5Hz) | `fx_dirty` | Future (when subscription-based) |
| Sends | MEDIUM (5Hz) | `sends_dirty` | Future (if subscription-based) |

**Not applicable:** Transport/tracks (already 30Hz, no tier to defer), items/project notes (no CSurf callback).

**Implementation:** ~20 lines per resource — track frame number, compare in tier poll.

### Diff-Based Events

Only send changed fields instead of full state snapshots. Would reduce bandwidth for large track counts but adds complexity.

### FX Chain Subscription ✅

**Status:** Backend complete. Frontend integration pending.

FX chain subscription via `trackFx/subscribe` and `trackFx/unsubscribe` commands.
Follows routing subscription pattern — single track per client, GUID-based addressing.

**Implemented:**

- `trackFx/subscribe` with `trackGuid` — subscribe to single track's FX chain
- `trackFx/unsubscribe` — clear subscription
- `trackFxChain` events: fxGuid, name, presetName, presetIndex, presetCount, modified, enabled
- Management: `trackFx/add`, `trackFx/delete`, `trackFx/move` with undo blocks
- FX GUIDs exposed for stable addressing across reorders

**Remaining:**

- [x] Frontend: FX modal to use subscription instead of on-demand fetch

**Reference:** [trackfx_subscriptions.zig](../extension/src/subscriptions/trackfx_subscriptions.zig)

### CSurf FX/Sends Dirty Flag Consumption ✅

**Status:** Complete.

The main loop now consumes `fx_dirty` and `sends_dirty` bitsets from CSurf callbacks to force immediate broadcast when FX params or send levels change. This provides instant latency response in addition to hash-based change detection.

**Implementation:** Dirty flags are per-track. When a subscription's track has its dirty bit set, the broadcast is forced even if hash comparison would skip it.

**Reference:** [CSURF_MIGRATION.md](../docs/architecture/backend/csurf/CSURF_MIGRATION.md)

### FX Parameter Subscription ✅

**Status:** Backend complete. Frontend integration pending.

Per-parameter subscriptions for FX detail modal with virtual scrolling support.

**Implemented:**

- `trackFx/getParams` — skeleton fetch (param names), frontend caches in LRU
- `trackFxParams/subscribe` — subscribe to param range or specific indices
- `trackFxParams/unsubscribe` — clear subscription
- `trackFxParams/set` — set param value with gesture-based undo coalescing
- `trackFxParams` events push values at 30Hz for subscribed range/indices
- `trackFxParamsError` event on FX deletion (auto-unsubscribes client)
- Skeleton invalidation via `paramCount` + `nameHash` in events

**Gesture support:** `fxParam` control type added. Uses unified `ManualUndoState` with bitfield tracking for proper undo messages across HW outputs and FX params.

**Reference:** [API.md - Track FX Parameter Commands](../extension/API.md#track-fx-parameter-commands)

**Remaining:**

- [x] Frontend: FX param modal to use subscription
- [x] Frontend: Sparse index subscription for filtered param lists (replaces virtual scrolling)

**REAPER API — Stable FX Addressing:**

| Level | Stable Identifier | API |
|-------|-------------------|-----|
| Track | Track GUID | `GetTrackGUID()` |
| FX | FX GUID | `TrackFX_GetFXGUID(track, fx_idx)` |
| Parameter | Param Ident (string) | `TrackFX_GetParamIdent()` / `TrackFX_GetParamFromIdent()` |

**Future: Pinned FX Controls**

For a "pin FX parameter to toolbar" feature, store:

```json
{
  "trackGuid": "{AAA-BBB-CCC}",
  "fxGuid": "{DDD-EEE-FFF}",
  "paramIdent": "wet_dry_mix"
}
```

Runtime lookup: Track GUID → Track pointer → enumerate FX by GUID → `TrackFX_GetParamFromIdent`

### Idle When No Clients

Skip all polling when `clientCount() == 0`. One-line change in timer callback. Trade-off: ~30ms delay to first update on connect.

### Per-Track Metering Subscriptions

Currently all visible tracks get metered. Could subscribe per-track for large projects where only a few tracks are visible.

---

## Technical Debt

### Frontend Cleanup Deferred Items

Items identified during Jan 2025 frontend cleanup (Phases 1-6) but intentionally deferred.

**Toast Re-integration** ✅

The Toast system (undo/redo feedback) was re-integrated after being disconnected when legacy StudioView was removed.

- [x] Created `toastSlice.ts` for centralized toast state management
- [x] Created `ToastRoot.tsx` with portal rendering (matches `ModalRoot` pattern)
- [x] Added `ToastRoot` to App.tsx alongside `ModalRoot`
- [x] Updated `QuickActionsPanel` to use `sendCommandAsync` for undo/redo and show toast with action description

**TimeSignatureButton Integration** ✅

Time signature editing integrated into QuickActionsPanel (2026-01-27). The standalone component was removed.

- [x] Add time signature editing to QuickActionsPanel
- [x] Remove standalone TimeSignatureButton after integration

**Density Modes**

Control height tokens (`--size-control-sm/md/lg/xl`) are now in place. This enables future density mode implementation where users can select Compact/Normal/Accessible button sizes.

- [ ] Add density mode selector to settings
- [ ] Apply control height tokens based on selected mode

**Non-Color Indicators for Track Buttons**

Track buttons (Mute, Solo, RecordArm) rely on domain-standard colors for state indication. Current mitigations: text labels, position-based meaning, brightness differences.

- [ ] Accessibility audit to determine if icons/shapes needed alongside color
- [ ] Consider colorblind simulation testing

**Visual Polish (Phase 7)**

Deferred until side rail responsive design is finalized.

- Touch target verification on actual devices
- Text hierarchy audit
- Loading/empty state consistency
- Transition/animation polish

---

### Frontend Toggle Subscription Not Updating UI ✅

**Status:** Fixed (2026-01-26)

**Symptom:** Toolbar toggle buttons (and ActionsView toggles) didn't update when toggled from REAPER directly. User had to refresh to see current state.

**Root cause:** Backend event format mismatch. The backend was sending `changes` at the top level:

```json
{"type":"event","event":"actionToggleState","changes":[{"s":0,"c":40364,"v":1}]}
```

But the frontend expected `changes` inside a `payload` wrapper (matching the documented API):

```json
{"type":"event","event":"actionToggleState","payload":{"changes":[{"s":0,"c":40364,"v":1}]}}
```

**Fix:** Updated `changesToJson()` in `extension/src/subscriptions/toggle_subscriptions.zig` to wrap `changes` in a `payload` object, matching the documented API format and the frontend's expectation.
