# REAmo Roadmap

**Last updated:** 2026-02-05

Prioritized by market impact. Each version has a thesis: v1.0 = first impressions, v1.1 = retention, v2.0 = growth.

---

## v1.0 — Launch (First Impressions)

What must be flawless. First-time users form opinions in 60 seconds — broken layouts, confusing setup, or laggy transport generate "not ready yet" verdicts that are extremely hard to recover from.

### Responsive Layout Refinement

App works well on iOS phone PWA but needs polish across form factors.

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
- `MixerStripCompact` (landscape phone mixer) — WIP, needs design/polish pass. Missing selected-track name styling parity with `MixerStrip`, no `data-selected`/`data-master` attributes for testing

**Effort:** M (mostly testing + CSS tweaks)

### First-Run Experience

Time from "I heard about this" to "I'm controlling REAPER" must be under 2 minutes. The proof-of-life moment: open browser → connect → tap Play → REAPER plays.

**Checklist:**

- [ ] Installation: Lua installer script works reliably on macOS + Windows
- [ ] Discovery: PWA finds WebSocket port automatically via EXTSTATE
- [ ] First connect: Hello handshake completes without user intervention
- [ ] Error states: Actionable messages, not cryptic codes ("REAPER not found — is the extension installed?")
- [ ] QR code in REAPER CSurf settings that opens REAmo on phone (stretch goal)
- [ ] Default view on first load is sensible (Studio or Clock, not a complex view)
- [ ] USB tethering works out of the box on iOS + macOS (link-local)

**Effort:** S-M (mostly testing + error message polish)

### Scrap/Retake/Keep Polish

This is REAmo's headline feature — the single most differentiating workflow. It must feel bulletproof.

**Checklist:**

- [ ] Scrap during recording: deletes take, continues without gap — verify no audio glitches
- [ ] Retake: deletes take, restarts from same position — verify position accuracy
- [ ] Keep: stops cleanly, take preserved — verify undo state is correct
- [ ] Visual feedback: clear distinction between recording, stopped, and transitioning states
- [ ] Edge cases: scrap when only one take exists, retake at project start, keep with auto-punch active
- [ ] Latency: action completes within one frame (33ms) of button tap

**Effort:** S (testing + edge case fixes)

### Cross-Platform Extension Validation (Windows)

Extension builds and runs on macOS. Windows support compiles (Zig cross-compilation) but has not been validated on a real Windows REAPER instance.

**Blocked features on Windows:**

- [ ] Extensions menu (SWELL wrappers currently no-op on Windows — need Win32 `extern "user32"` implementations for ~8 menu functions)
- [ ] QR code window (SWELL window/GDI calls — same pattern, need Win32 equivalents)
- [ ] Network detection (platform-specific socket calls — needs Windows `GetAdaptersAddresses` path)

**Not blocked (platform-agnostic):**

- WebSocket server, state polling, command dispatch, all subscription systems
- These use REAPER C API which is identical across platforms

**Effort:** S-M (menu wrappers are small; QR window and network detection need more work)

### Connection Reliability Testing

WiFi unreliability is the #1 complaint about every DAW remote app. REAmo's USB tethering is a killer advantage — but it must work.

**Test matrix:**

- [ ] WiFi connection on 5GHz network (primary use case)
- [ ] WiFi on 2.4GHz (degraded but functional)
- [ ] USB tethering: iPhone → Mac (link-local)
- [ ] USB tethering: iPhone → Windows (if supported)
- [ ] PWA backgrounding: iOS suspend >10s → reconnect <2s
- [ ] PWA backgrounding: Android suspend → reconnect
- [ ] Cold start: iOS PWA from home screen (Safari WebSocket bug workaround)
- [ ] Network switch: WiFi → USB mid-session (graceful reconnect)

**Effort:** S (testing, not implementation — infrastructure already built)

---

## v1.1 — Post-Launch Polish (Retention)

Quick wins based on early feedback. Ship within 2-4 weeks of launch.

### Accessibility Pass

Review and improve accessibility. REAPER + OSARA users represent an underserved audience.

**Checklist:**

- [ ] VoiceOver testing on iOS (navigate all views, verify announcements)
- [ ] Audit aria-labels on interactive elements (buttons, sliders, modals)
- [ ] Focus management in modals and sheets (trap focus, return on close)
- [ ] Keyboard navigation for desktop browser users
- [ ] Color contrast verification (WCAG AA minimum)
- [ ] Reduced motion support (`prefers-reduced-motion` media query)
- [ ] Screen reader announcements for state changes (play/stop, record, mute/solo)
- [ ] Non-color indicators for track buttons (icons/shapes alongside M/S/R colors)
- [ ] Density mode selector in settings (Compact/Normal/Accessible)

**Effort:** S-M (audit + targeted fixes)

### View Customization — Presets & Onboarding

Core toggle + reorder shipped (see Shipped table). Remaining work:

**Named presets:**

| Preset | Visible Views |
|--------|---------------|
| Full | All 8 views |
| Voiceover | Timeline, Mixer, Actions, Clock |
| Self-Recording | Timeline, Mixer, Instruments, Actions, Clock |
| Worship / Band | Cues, Mixer, Clock, Notes |

- First-run onboarding: "How will you use REAmo?" → sets preset
- Users can customize after preset selection
- Preset choice doubles as analytics signal for which segments are adopting

**Marketing angle:** Landing page can show "REAmo for Voiceover" / "REAmo for Musicians" / "REAmo for Worship" — same app, different screenshots, each showing only the relevant tabs.

**Effort:** S

### Pre-roll & Count-In Settings — Measure Counts

Toggle controls shipped (see Shipped table). Remaining work:

- Measure count steppers for count-in bars and pre-roll bars
- Requires discovering REAPER config var names for count-in measure count and pre-roll measure count (not exposed via SWS or known API docs)

**Effort:** XS (once config var names known)

### REAPER Version Feature Flags

Include REAPER version in connect/hello event for graceful feature degradation.

- Backend: Add `reaperVersion: "7.24"` to hello/project event payload
- Frontend: Feature matrix mapping version → enabled features
- UI: Hide or grey out unavailable features with "Requires REAPER 7+" tooltip

| Feature | Minimum Version |
|---------|-----------------|
| Swipe comping | REAPER 7.0+ |
| Fixed track lanes | REAPER 7.0+ |

**Effort:** S (backend trivial, frontend feature matrix)

### Visual Polish

- Touch target verification on actual devices
- Text hierarchy audit
- Loading/empty state consistency
- Transition/animation polish

**Effort:** S-M

---

## v2.0 — Growth Features

Expand the user base into new segments: worship teams, bands, podcasters, songwriting challenge communities.

### Lyric/Chord Teleprompter

**Design doc:** [LYRICS_DESIGN.md](LYRICS_DESIGN.md) (WIP)

ChordPro import with timeline-synced display for performers. Unlocks the worship/band market.

**Why this matters:** OnSong and ForScore are beloved because they combine lyrics, chords, and playback. REAmo can do this with native REAPER integration — charts live with the project, sync is automatic. Worship teams spend $30-300/month on tools like Planning Center. Bands and session musicians sight-read charts constantly.

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

**Effort:** M-L (parsing, rendering, sync logic)

### Swipe Comping

**Branch:** `feature/swipe-comping`

Touch-based take comping for fixed lane mode. Swipe across waveform to select which take plays for each time region — the mobile equivalent of REAPER's mouse-based swipe comping.

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

### Timebox Challenge

Constraint-based creation mode — random musical constraints, time limit, automatic closure. Research-validated approach to breaking perfectionism paralysis. Ship as a "surprise and delight" secondary feature, not a headline. Time marketing to FAWM 2027 (February) or 50/90 2026 (July 4).

**Research validation:**

- Constrained creative work scores **23% higher on originality** (Haught-Tromp, η²p = .53)
- Moderate time pressure preserves creativity; high pressure kills it (Amabile, 12,000 diary entries)
- FAWM has generated **250,000+ songs** since 2004; the format is proven

**Core experience flow:**

1. **Challenge reveal** — Full-screen display of three constraints with reroll options
2. **Project auto-creation** — REAPER project with tempo set, regions marking song structure
3. **Recording phase** — Hidden timer with audio-only notifications
4. **Playback reveal** — 5-second countdown, then automatic playback from start
5. **Closure prompt** — Three equal options: Save / Mark for Later / Let It Go

**Three focusing constraints (v1):**

| Constraint | Implementation |
|------------|----------------|
| **Key** | All 12 major/minor, weighted toward common keys with occasional wild cards |
| **Tempo** | Named ranges: Chill (60-80), Moderate (80-110), Energetic (110-140), Intense (140-180) |
| **Title** | Evocative phrases suggesting mood/imagery: "The Space Between Wanting", "Copper and Glass", "2AM Parking Lot" |

**Time parameters:**

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Default duration | **20 minutes** | Amabile's "low-to-moderate" pressure zone |
| Selectable presets | 10 / 15 / 20 / 30 / 45 min | 10 = Kenny Beats extreme; 45 = deep focus |
| Timer visibility | **Hidden by default** | Visible countdown creates anxiety; audio cues preserve urgency |
| 2-minute warning | Gentle chime | Mental preparation for closure |
| Stop type | **Soft stop** | "Give me 5 more minutes" extend option respects flow states |

**Song structure auto-generation (REAPER regions):**

```
Intro:    4 bars
Verse:    8 bars
Chorus:   8 bars
Verse 2:  8 bars
Chorus 2: 8 bars
Bridge:   8 bars
```

User can modify before starting. Tempo-adaptive bar counts.

**Closure options (equal prominence):** Save to Library / Mark for Later / Let It Go. No reflection prompts — the goal is permission to move on.

**V1 scope:** Three-constraint generation, duration presets, individual + full reroll, REAPER project auto-creation, hidden timer with audio cues, automatic playback on completion, save/mark/let-it-go, basic library of completed timeboxes.

**V2+ additions:** Difficulty levels, "On This Day" (surface old timeboxes), session stats, mood/genre fourth constraint, time signature constraints.

**Effort:** M (project creation + timer + UI)

### Move Items

Enable drag-to-move for selected items on timeline.

**Why this matters:** "Touch-enabled arrangement view with direct region manipulation" was identified as the killer differentiator vs Logic Remote. Waveform display is complete — now items need to be movable.

**Implementation:**

1. Horizontal move (time) — Drag item left/right to change position
2. Vertical move (track) — Drag item up/down to move to different track
3. Multi-item move — Selected items move together
4. Snap behavior — Respect REAPER's snap settings

**Backend:** `item/setPosition` with `itemGuid`, `position`, `trackGuid`. Gesture-based undo coalescing.

**Frontend:** Drag gesture on item (distinguish from pan on empty space), ghost preview, snap feedback.

### Time Format Cycling (SMPTE)

Tap time display to cycle: Bar.Beat → Seconds → SMPTE → Bar.Beat

**Research complete:** [research/archived/general/SMPTE.md](../research/archived/general/SMPTE.md)

- Backend already sends `frameRate` and `dropFrame` in project event
- Add `timeDisplayMode` to UIPreferences (localStorage)
- Create `secondsToSMPTE()` helper

### SWS Region Playlist Import

Parse existing SWS playlists from .RPP files for migration into REAmo cue lists.

**Effort:** ~1 day (backend) + UI

---

## v3.0+ — Long-term

Substantial new capabilities that require dedicated planning phases.

### Automation Curve Editing

Touch-based drawing of automation lanes. "Touch is actually superior to mouse for drawing curves" — Logic Remote analysis.

**Effort:** Multi-week project

### MIDI Note Editing

Piano roll view with touch editing.

**Effort:** Multi-week project

### Practice Tools

Metronome modes that build internal timing and speed, not just keep time.

**Gap-Click Metronome:** Click plays for N bars, then silent for N bars. Forces internal time. Based on Benny Greb's method (Time Guru app). Configurable gap length, visual beat indicator during silence, progressive mode, randomized gaps.

**Accelerating Metronome:** Tempo increases gradually over time for speed-building. Start → target tempo over N minutes. Small increments (1-2 BPM). Optional plateau periods.

**Effort:** M (requires beat-sync logic and UI)

### Looper Mode

Live looping surface for jamming. Record a phrase, it loops, layer on top, play along.

- Record loop of N bars (synced to tempo)
- Overdub layers, undo last layer, clear and restart
- Classic guitarist workflow — iPad as a loop pedal

**Design consideration:** How this maps to REAPER's actual looping/overdub modes needs exploration.

### Haptic Click

Haptic feedback as metronome. Phone vibrates on beat for silent click track.

**Challenges:** Latency compensation, iOS Vibration API not supported, battery impact.

**Effort:** S-M

### Session Stats

Recording activity visualization — tucked-away info screen for motivation.

- Recording streak, monthly summary, personal records, trend graphs
- Light gamification: volume milestones, not competition

**Effort:** S (mostly UI)

### Project Notes Reminder

Gentle nudge to document sessions. Toggleable setting, non-intrusive notification, leverages phone's speech-to-text.

**Effort:** XS

### Ruler Drag-to-Select

Drag on timeline ruler to create time selection. Currently covered by long-press-to-seek + MakeSelectionModal.

**Status:** Implement if requested

### Item Selection UX Polish

Current multi-select works but feels cluttered. Info bar layouts clash, "item selection mode" concept is awkward, batch operations UI needs polish.

### Take Waveform Previews

Visual preview of take waveforms (mini thumbnails) in take switcher. Requires fetching all takes' peaks.

### Touch Instruments — Remaining

**Chord Pads Phase 1.5 (Polish):**

- Which scales make sense for chord pads? (pentatonic has 5 notes, blues has 6)
- Double-sharp display symbol
- Key selector flat preference for flat keys
- Consider restricting to "practical" keys only

**Chord Pads Phase 4 (Customization):**

- 7ths toggle, hide/show specific pads, custom chord editing per strip
- Configurable strip count (4-7), per-strip quality override, adjustable inversion count

**Expression:** Velocity from touch pressure API, aftertouch support

### Folder Banks (Phase 3)

- New bank type: "folder" — saved shortcut to specific folder
- Auto-opens folder sheet at that folder's level
- Enables quick access to frequently used folder views

---

## Future Optimizations

Low-priority performance improvements to consider when scaling or if profiling indicates need.

### WebSocket Compression (gzip)

Per-message deflate for large payloads (action list ~985KB). Blocked on websocket.zig library update for Zig 0.15. Expected 10-15x compression for text payloads.

### Dirty Flag Poll Deferral

When CSurf dirty flags trigger an immediate poll, defer the next tier poll to avoid redundant API calls.

**Applicable resources:**

| Resource | Tier | Dirty Flag | Savings |
|----------|------|------------|---------|
| Markers/regions | MEDIUM (5Hz) | `markers_dirty` | Skip redundant 5Hz poll |
| Tempo map | LOW (1Hz) | `tempo_dirty` | Skip redundant 1Hz poll |

**Implementation:** ~20 lines per resource — track frame number, compare in tier poll.

### Diff-Based Events

Only send changed fields instead of full state snapshots. Would reduce bandwidth for large track counts but adds complexity.

### Idle When No Clients

Skip all polling when `clientCount() == 0`. One-line change in timer callback. Trade-off: ~30ms delay to first update on connect.

### Per-Track Metering Subscriptions

Currently all visible tracks get metered. Could subscribe per-track for large projects where only a few tracks are visible.

### Pinned FX Controls

"Pin FX parameter to toolbar" feature. Store `{trackGuid, fxGuid, paramIdent}`. Runtime lookup: Track GUID → Track pointer → enumerate FX by GUID → `TrackFX_GetParamFromIdent`.

---

## Technical Debt

### Density Modes

Control height tokens (`--size-control-sm/md/lg/xl`) are in place. Needs density mode selector in settings to apply them.

### Theme Customization

User-selectable color themes. All UI colors are already CSS custom properties — swapping themes is a `[data-theme]` attribute on the root + a block of variable overrides. Subsumes the shelved "Subtle Recording Indicator" idea (a calmer theme naturally uses muted reds). Could ship with 2-3 presets (Default, Low-Key, High Contrast) before opening up full customization.

**Effort:** S-M (CSS variable overrides + settings UI + localStorage)

### Non-Color Indicators for Track Buttons

Track buttons (Mute, Solo, RecordArm) rely on domain-standard colors. Current mitigations: text labels, position-based meaning, brightness differences. Needs accessibility audit + colorblind simulation testing.

---

## Shipped

Completed features, kept for historical reference.

| Feature | Completed | Notes |
|---------|-----------|-------|
| Mix Monitoring (Audio Streaming) | 2026-02-15 | Stream REAPER master output as raw 16-bit PCM over binary WebSocket to phone. AudioWorklet (secure contexts) + AudioBufferSourceNode scheduling (insecure HTTP over LAN). 80ms jitter buffer, iOS gesture unlock, foreground-only. ~80-150ms latency on WiFi. [Architecture doc](../docs/architecture/AUDIO_MONITORING.md) |
| Routing Create/Delete (Sends, Receives, HW Outputs) | 2026-02-15 | Add/remove sends, receives, and hardware outputs from routing bottom sheet. Track picker for send/receive destinations. HW output channel picker with stereo pairs + mono. Two-tap delete confirmation. `CreateTrackSend`/`RemoveTrackSend` bindings, `hw/listOutputs` for channel enumeration. |
| Count-In & Pre-Roll Toggles | 2026-02-14 | 4 toggles in QuickActionsPanel: count-in play/rec + pre-roll play/rec. Count-in uses native `projmetroen` config var (no SWS dep). Pre-roll uses REAPER actions 41818/41819. State via project event polling. |
| View Customization (Hide/Show/Reorder) | 2026-02-14 | Per-view show/hide toggles + drag-to-reorder in bottom sheet. Tab bar and side rail filter by visibility/order. Persisted to localStorage. Presets/onboarding deferred to v1.1. |
| Extensions Menu System | 2026-02-07 | Declarative menu under Extensions > REAmo. SWELL bridge for macOS/Linux. **Windows: needs validation** — Win32 branches stub out, need `extern "user32"` calls. |
| Context-Aware Take/Item Coloring | 2026-02-05 | Take rating via color (green/orange/red). REAPER color priority chain: take > item > theme. |
| Toolbar Component Redesign | 2026-01-29 | Slot-based paged grid, swipe paging, 48-54pt targets, in-app edit mode. |
| Timeline Canvas Architecture | 2026-01 | Per-track canvases, never-clear rendering, TileBitmapCache with LRU eviction. |
| Tile-Based Waveform System | 2026-01 | 8-level LOD, Lua bridge for peak fetching, stereo split rendering. |
| Viewport-Relative Pan & Zoom | 2026-01 | Viewport-relative momentum, follow-playhead zoom anchor. |
| Per-Device Layout Memory | 2026-01 | Last view, banks, filters, viewport, instrument channels in localStorage. |
| Marker Navigation via Long-Press | 2025 | 500ms on time display → marker sheet with tap-to-jump. |
| PWA Version Detection | 2025 | EXTSTATE version compare, silent hard refresh, Cache Storage cleanup. |
| Add FX Browser | 2025 | Searchable plugin list (VST3/VST2/AU/JS), `TrackFX_AddByName`. |
| Folder Display (Phase 1-2) | 2025 | Folder badges, child counts, FolderNavSheet, breadcrumbs, banks vs filters. |
| Touch Instruments (Drums, Piano, Chords Phase 1-3) | 2025-2026 | 4x4 GM drums, 2-oct piano + mod wheel + pitch bend, 7 diatonic chords + inversions + bass + strum + voice leading. |
| Banks vs Filters | 2025 | Orthogonal bank selector + property filter dropdown. |
| Toast Re-integration | 2025 | toastSlice, ToastRoot portal, undo/redo feedback. |
| TimeSignatureButton Integration | 2026-01-27 | Integrated into QuickActionsPanel, standalone removed. |
| Frontend Toggle Subscription Fix | 2026-01-26 | Backend event format mismatch (`changes` wrapper in `payload`). |
| FX Chain Subscription | 2025 | Backend + frontend complete. GUID-based, 5Hz push. |
| FX Parameter Subscription | 2025 | Backend + frontend complete. Sparse index subscription, 30Hz push. |
| Cues/Playlist | 2025 | Arrange regions into setlists, test song structures without duplicating audio. |
| CSurf FX/Sends Dirty Flags | 2025 | Per-track bitset consumption for instant broadcast. |
