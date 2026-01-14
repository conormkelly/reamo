# Feature Priority List

Consolidated from PLANNED_FEATURES.md, PENDING_ITEMS.md, research docs, and ongoing development.

**Last updated:** 2026-01-12

---

## P0 — Quick Wins (Low Effort, High Value)

### ~~Marker Navigation Modal~~ ✅
Long-press (500ms) on time display in PersistentTransport shows marker/region list for quick navigation.

**Implemented:** 2026-01-12
- MarkerNavigationPanel component using BottomSheet
- Shows markers and region start points sorted by position
- Tap to seek and close panel
- Coexists with double-tap Quick Actions Panel

---

### Time Format Cycling
Tap time display to cycle: Bar.Beat → Seconds → SMPTE → Bar.Beat

**Implementation:**
- Backend already sends `frameRate` and `dropFrame` in project event
- Add `timeDisplayMode` to UIPreferences (localStorage)
- Create `secondsToSMPTE()` helper (see API.md for formula)
- Use semicolon separator for drop-frame (29.97/59.94 fps)

**Effort:** ~2-3 hours

---

### Track Create Button
Add "New Track" button to TrackInfoBar or as FAB in mixer.

**Implementation:**
- Backend `track/create` command already exists
- Wire up UI button
- Optional: prompt for track name

**Effort:** ~1 hour

---

## P1 — UX Polish (Medium Effort)

### ~~Fine-Grained Fader Control~~ ✅
Horizontal distance from fader reduces sensitivity for precision adjustments.

**Implemented:** 2026-01-12
- Delta-based movement (captures initial position on drag start)
- Sensitivity scales by `1 / (1 + horizontalOffset / 50)`
- "FINE" indicator appears when finger is >30px away horizontally
- Works with both mouse and touch

---

### ~~Exclusive Solo Mode~~ ✅
Option for solo buttons to work exclusively (soloing one track un-solos others).

**Implemented:** 2026-01-12
- Long-press (400ms) on solo button triggers exclusive solo
- New `track/setSoloExclusive` command handles atomically on backend
- Uses action 40340 (unsolo all) + setSolo, wrapped in undo block
- Undo label: "REAmo: Solo track exclusively"
- Normal tap still toggles solo additively

---

### ~~Migrate FX Modal to BottomSheet~~ ✅
Current FX modal uses custom modal. Migrate to BottomSheet for consistency.

**Implemented:** 2026-01-12
- Replaced Modal with BottomSheet slide-up panel
- Added header with track name
- Scrollable content area with max-height
- Footer summary showing FX count

---

### ~~Migrate Routing Modal to BottomSheet~~ ✅
Same as above — consistent slide-up panel UX.

**Implemented:** 2026-01-12
- Replaced Modal with BottomSheet slide-up panel
- Added header with track name
- Scrollable content area with tabs for Sends/Receives
- Footer summary showing send and receive counts

---

## P2 — Feature Improvements (Larger Scope)

### Viewport-Aware Take Management
Current ItemsTimeline loads all items. Rework to be viewport-aware like tracks.

**Requirements:**
- Time-range subscription model (not index-based like tracks)
- Only load items within visible time range + buffer
- Efficient for large projects with 1000+ items

**Architecture (from PENDING_ITEMS.md):**
```typescript
{ "type": "item/subscribe", "timeRange": { "start": 0.0, "end": 120.0 } }
```

**Effort:** ~1-2 days

---

### Built-in Bank Groups
Pre-defined smart banks for common workflows:

| Bank | Filter Logic |
|------|--------------|
| Clipped | Tracks with peak > 0dB in current session |
| Selected | REAPER-selected tracks only |
| Armed | Record-armed tracks |
| Soloed | Currently soloed tracks |
| With Sends | Tracks that have sends configured |
| Folders Only | Parent folder tracks |

**Implementation:**
- Extend BankEditorModal with "System Banks" section
- System banks are read-only, always available
- Filter logic runs client-side on track data

**Effort:** ~4-6 hours

---

### Take Switcher Polish
Existing take switcher needs UX improvements:

- [ ] Larger touch targets for prev/next
- [ ] Show take name (if available) not just "Take 1/3"
- [ ] Visual preview of take waveforms (mini thumbnails?)
- [ ] Swipe gesture for take switching
- [ ] "Delete take" confirmation flow
- [ ] "Crop to active" quick action

**Effort:** ~1 day

---

## P3 — Future Features (Deferred)

### Touch Instruments
Chord strips and scale-locked keyboard for songwriting workflow.

**From Research:**
> "Chord strips with customizable chords per project—major differentiator for songwriting"

**Requirements:**
- MIDI output from web → REAPER
- Scale/key detection or manual setting
- Diatonic chord filtering
- Strumming gestures for guitar strips

**Effort:** Multi-week project

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

**Effort:** ~4-6 hours

---

## Completed Recently ✅

For reference — features completed in recent commits:

- [x] Quick Actions Panel (double-tap time display)
- [x] Track color picker with reset
- [x] Per-FX bypass controls
- [x] FX Modal with preset navigation
- [x] Routing Modal with send faders
- [x] Custom track banks (smart + manual)
- [x] Pinch-to-zoom timeline
- [x] Momentum scrolling
- [x] Region editing / arranger mode
- [x] Recording quick actions (Scrap/Retake/Keep)
- [x] Global select-none for touch UX

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
