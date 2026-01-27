# REAmo Roadmap

**Last updated:** 2026-01-26

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

### Toolbar Component Redesign

Current toolbar is functional but needs polish for v1.

**Current Issues:**

- No slot concept — buttons sized by text content, inconsistent widths
- No overflow handling — buttons just squeeze together or clip
- Padding not well thought out — items too close together

**Design Direction:**

- Uniform 48-54pt touch targets
- 4 buttons per row
- Horizontal swipe paging (existing "1-4 / 11" pattern is good)

**Effort:** S (half day)

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

### Toolbar Component Redesign

Current toolbar is a simple button bar with text-sized buttons. Needs rework for better space utilization and user configurability.

**Status:** Research complete. See [research/archived/ui-ux/MOBILE_TOOLBAR_UX.md](../research/archived/ui-ux/MOBILE_TOOLBAR_UX.md)

**Research:** [research/archived/ui-ux/MOBILE_TOOLBAR_UX.md](../research/archived/ui-ux/MOBILE_TOOLBAR_UX.md)

**Prerequisites:**

- [ ] **Track selection from timeline** — Tap empty area of track lane to select that track (clears other track selections). Matches REAPER behavior where clicking anywhere on a track's lane selects it. Item tap should also select the item's track. Multi-select items should update selected track to last touched, keeping all items selected. This consistency with REAPER behavior makes toolbar actions (which operate on selected tracks/items) more predictable.

**Current Issues:**

- No slot concept — buttons sized by text content, inconsistent widths
- No overflow handling — buttons just squeeze together or clip
- Padding not well thought out — items too close together
- No way for user to resize buttons or organize layout

**Design Direction (from research):**

- **Uniform button sizes** — Variable widths prevent muscle memory; users remember position, not labels
- **48-54pt touch targets** — Edge locations need larger targets than Apple's 44pt minimum
- **4 buttons per row** — Fits small toolbar area with adequate touch targets
- **Horizontal swipe paging** with numeric indicator (existing "1-4 / 11" pattern is good)
- **Text + icon** as default — REAPER's thousands of actions can't be icon-only
- **In-app editing only** — Users hate needing desktop software for configuration
- **Pre-built defaults** with full customization — Users spend 5-15 min on setup if starting point is good

**Default Actions:**

Focus on **item editing operations** — transport, markers, and track operations are already covered by dedicated UI (transport bar, mixer view).

| Page | Slot 1 | Slot 2 | Slot 3 | Slot 4 |
|------|--------|--------|--------|--------|
| 1 | Split | Glue | Delete | Add Marker |
| 2 | Ripple ⟳ | Snap ⟳ | Duplicate | — |

**Why these actions:**

- **Split at cursor** — #1 most-used editing action across all REAPER workflows (forum consensus)
- **Glue items** — Natural pair with split; consolidates edits into single item
- **Delete items** — Completes the edit trio; backend `item/delete` exists but no dedicated button
- **Add marker** — Quick annotation during playback/editing; transport has prev/next but not add
- **Toggle ripple editing** — Critical for podcast/dialogue editing; users toggle constantly
- **Toggle snap** — Constantly toggled during precision editing
- **Duplicate items** — Common arrangement workflow (track duplicate already in mixer)

**Not included (already covered):**

- Undo/Redo, Metronome, Markers — Transport bar
- Solo/Mute/Arm — Mixer view
- Track create/duplicate — Mixer view
- FX chain — Track detail modal

**Configuration UX:**

- Reset current page / all pages to defaults
- Import/export toolbar configuration (JSON)
- Long-press + explicit Edit button for customization

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

**TimeSignatureButton Integration**

`Actions/TimeSignatureButton.tsx` (203 LOC) has unique time signature editing functionality not available elsewhere. Keep for integration into QuickActionsPanel.

- [ ] Add time signature editing to QuickActionsPanel
- [ ] Remove standalone TimeSignatureButton after integration

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
