# Feature Priority List

Consolidated from PLANNED_FEATURES.md, PENDING_ITEMS.md, research docs, and ongoing development.

**Last updated:** 2026-01-15

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

Show folder hierarchy in mixer/track views.

**Requirements:**

- Indentation or visual grouping for child tracks
- Collapse/expand folder tracks
- Backend already sends `isFolder` flag

---

### Touch Instruments

Chord strips and scale-locked keyboard for songwriting workflow.

**Status:** Research complete: [research/MIDI_TOUCH_INSTRUMENTS.md](../research/MIDI_TOUCH_INSTRUMENTS.md)

**Key Finding:** WebSocket → StuffMIDIMessage achieves 5-15ms latency (matches Logic Remote). No WebMIDI complexity needed.

**Incremental Approach:**

1. **Drum Pads (MVP)** - Grid of velocity-sensitive pads, multi-touch, configurable note mapping
2. **Piano Keyboard** - Note bars with octave selection, velocity from touch
3. **Chord Strips** - Diatonic chords locked to project key, inversions
4. **Expression** - Mod wheel, pitch bend strip, aftertouch

**Backend (trivial):** Add `midi/noteOn`, `midi/noteOff`, `midi/pitchBend`, `midi/aftertouch` commands

**Frontend (main effort):**

- Multi-touch tracking (touchId → noteId for proper note-off)
- Velocity from pressure/position
- Rate-limited continuous controllers (60-120Hz)
- Touch-optimized layouts

**Size:** Backend S, Drum Pads MVP M, Full instruments L-XL

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
