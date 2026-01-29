# Instrument Enhancements Research Brief

This document describes REAmo's current touch instrument implementations and proposed enhancements. It serves as a self-contained context for competitive research, user needs analysis, and implementation planning.

---

## Executive Summary

REAmo is a web-based remote control for REAPER (Digital Audio Workstation) that runs as a Progressive Web App on tablets and phones. The Instruments view provides touch-based MIDI input for drums, piano, and chord pads—enabling musicians to play virtual instruments directly from their mobile device with sub-15ms latency over local network.

We're planning significant enhancements to make these instruments more customizable, expressive, and useful for real-world music production workflows.

---

## Architecture Overview

### Communication Stack

```
Touch Event → React Pointer Handler → WebSocket Command → REAPER Extension → MIDI Output
     |                  |                    |                    |
  <1ms            Immediate            ~0.5ms RTT            <0.1ms
```

**Total latency**: 5-15ms (professional-grade; below 10ms perceptible threshold)

### MIDI Commands Available

```typescript
midi.noteOn(note: number, velocity: number, channel: number)
  // velocity=0 acts as note-off

midi.cc(cc: number, value: number, channel: number)
  // Continuous controller (0-127)

midi.pitchBend(value: number, channel: number)
  // 14-bit value: 0-16383, center=8192
```

### State Persistence

All instrument settings are persisted to `localStorage`:

| Key | Description | Default |
|-----|-------------|---------|
| `reamo_instruments_selected` | Active instrument | `drums` |
| `reamo_instruments_drums_channel` | Drum MIDI channel | `9` (GM drums = ch 10) |
| `reamo_instruments_piano_channel` | Piano MIDI channel | `0` (ch 1) |
| `reamo_instruments_piano_octave` | Starting octave | `4` (middle C) |
| `reamo_instruments_chords_channel` | Chords MIDI channel | `0` |
| `reamo_instruments_chords_key` | Root key | `C` |
| `reamo_instruments_chords_scale` | Scale type | `major` |
| `reamo_instruments_chords_octave` | Chord octave | `3` |
| `reamo_instruments_chords_hints` | Show progressions | `true` |
| `reamo_instruments_chords_voicelead` | Adaptive voicing | `false` |
| `reamo_instruments_chords_strum` | Strum mode | `false` |
| `reamo_instruments_chords_strum_delay` | Strum delay (ms) | `30` |

---

## Current Implementations

### 1. Drum Pads

**Location**: `frontend/src/components/Instruments/DrumPad.tsx`, `DrumPadGrid.tsx`

#### Current Layout

4×4 grid with hardcoded General MIDI drum mapping:

```
Row 1 (Cymbals):  Crash (49) | Ride (51)  | HH Open (46) | HH Close (42)
Row 2 (Toms):     Tom 1 (48) | Tom 2 (47) | Tom 3 (45)   | Tom 4 (43)
Row 3 (Snares):   Snare (38) | Snare2(40) | Side (37)    | Clap (39)
Row 4 (Kicks):    Kick (36)  | Kick2 (35) | Pedal (44)   | Floor (41)
```

#### Current Behavior

- **Note On**: Triggered by `pointerdown` with fixed velocity (100)
- **Note Off**: **NOT SENT** - drums treated as one-shots
- **Touch**: Multi-touch capable, 20ms debounce per pad
- **Visuals**: Color-coded by category (gray=cymbals, purple=toms, red=snares, blue=kicks), scale-95 + brightness-125 on press

#### Responsive Design

- **Portrait**: Width-constrained with derived height (aspect-square)
- **Landscape**: Height-constrained with derived width (aspect-square)
- Always maintains square aspect ratio, centered on viewport

---

### 2. Piano Keyboard

**Location**: `frontend/src/components/Instruments/PianoKeyboard.tsx`, `PianoKey.tsx`

#### Current Layout

- 2-octave display (configurable)
- Octave range: 0-8 (navigation limited to 1-7 in UI)
- White/black key positioning following standard piano layout
- Black keys at 60% width, 60% height, positioned -30% from right of white key

#### Current Behavior

- **Note On**: Triggered by `pointerdown` with pointer capture, fixed velocity (100)
- **Note Off**: Properly sent on `pointerup`, `pointercancel`, or pointer leaving key
- **Multi-touch**: Smart pointer-to-note tracking prevents hanging notes
- **Sliding**: Does nothing — pressing a key holds it, dragging elsewhere keeps the original note held until release
- **No glissando**: Moving across keys doesn't trigger intermediate notes or change the held note

#### Expressive Controllers

**Mod Wheel (CC1)**:
- Vertical strip, Y-position → 0-127
- Rate-limited to 50Hz (20ms)
- Spring-back not implemented (stays where released)

**Pitch Bend Wheel**:
- Vertical strip, Y-position → 0-16383 (center=8192)
- Rate-limited to 60Hz (16ms)
- Spring-back to center on release (150ms ease-out cubic)

#### Responsive Design

- **Portrait**: Keyboard scrollable horizontally with wheels on sides, min-width 500px
- **Landscape**: Full 2 octaves visible, wheels on sides

**Known Issue**: Portrait view has very narrow keys (looks like a "barcode"), not optimized for actual playability.

---

### 3. Chord Pads/Strips

**Location**: `frontend/src/components/Instruments/Chords.tsx`, `ChordColumn.tsx`

#### Current Layout

- 7 diatonic chords per scale (one per scale degree)
- Each chord column contains:
  - 4 inversion segments (Root, 1st, 2nd, Octave - displayed top-to-bottom)
  - 3 bass note buttons (Root, 5th, Octave below)

#### Music Theory Engine

**Scales Supported** (12 types):
- Diatonic: major, natural_minor, harmonic_minor, melodic_minor
- Modes: dorian, phrygian, lydian, mixolydian, locrian
- Pentatonic: pentatonic_major, pentatonic_minor, blues

**Chord Detection**: Automatically identifies quality (major, minor, diminished, augmented, 7ths)

**Roman Numeral Display**: I, ii, iii, IV, V, vi, vii° (respects chord quality)

#### Current Behavior

- **Note On**: Triggered by `pointerdown`, all chord notes sent simultaneously (or strummed)
- **Note Off**: Properly sent on release
- **Velocity**: X-position maps to 30-127 range (left=soft, right=loud)
- **Vertical swipe**: Moving finger up/down changes inversion (arpeggio effect)

#### Advanced Features

1. **Adaptive Voice Leading**: Minimizes total voice movement between chords
2. **Progression Hints**: Shows common next chords (I→IV,V,vi etc.)
3. **Strum Mode**: Notes played sequentially with configurable delay (10-100ms)

#### Responsive Design

- **Portrait**: Horizontal snap-scroll (7 columns need ~700px), settings in overflow menu
- **Landscape**: All 7 columns visible, full control set in header

**Known Issues (Portrait)**:
- Thin scrollbar visible between tab nav bar and chord pads
- ViewHeader overflowing and clipped off
- Needs responsive redesign similar to mixer view approach

---

## Proposed Enhancements

### 1. Drum Pads Enhancements

#### 1.1 Editable Pad Configuration

**Problem**: Current GM mapping is hardcoded and may not match user's drum kit or workflow.

**Proposed Features**:
- Edit individual pad color
- Edit pad label text
- Change MIDI note number per pad
- Velocity curve/fixed velocity per pad
- Save/load named layouts to localStorage

**UI Concept**:
- Gear icon in header enters dedicated editor view (similar to Actions or Clock view)
- NOT long-press (conflicts with hold-to-sustain trigger mode)
- Tap pad in edit mode to open configuration popover
- "Save as preset" / "Load preset" buttons
- Named banks (user-defined names, not generic A/B/C/D)

#### 1.2 MIDI Note Length / Note Off

**Problem**: Currently no note-off is sent. This causes issues when:
- Recording MIDI loops (double-trigger when loop wraps around)
- Triggering samples with release behavior
- Working with sustaining drum sounds

**Proposed Solution**:
- Configurable note length per pad or global
- Options: "One-shot" (no note-off), or tempo-synced lengths (1/4, 1/8, 1/16, 1/32)
- Tempo-synced requires reading current BPM from REAPER
- Note-off sent after calculated duration from note-on

**Technical Consideration**: Need to track active notes with setTimeout/setInterval for delayed note-off, being careful about race conditions with rapid re-triggers.

**Research Needed**: Debouncing and retriggering behavior — what happens when a pad is hit again before the previous note-off fires? Cancel previous timer? Stack? Need to investigate best practices. Particularly important for snare rolls and rapid retriggering scenarios.

**Research Needed**: Touch pressure/Force Touch detection — can we detect pressure on supported devices? If so:
- How to detect availability (not all devices support it)
- Should it auto-enable when available, or be a setting?
- Do we need velocity curves for pressure-to-velocity mapping?
- What's the UX for devices without pressure support?

**Visual Feedback**: Note repeat mode should show pulsing/flashing indicator synced to repeat rate.

#### 1.3 Configurable Layouts / Banks

**Problem**: 4×4 GM layout doesn't suit all workflows (e.g., finger drumming, sample launching, custom kits).

**Proposed Features**:
- Multiple saved layouts (banks) - switchable via bank selector
- Layout editor: drag to rearrange pads, resize grid (4×4, 4×2, 8×2, etc.)
- Import/export layouts (JSON file or shareable URL)
- Per-bank channel assignment

**Persistence**: Bank configurations stored in localStorage with unique IDs.

---

### 2. Piano Keyboard Enhancements

#### 2.1 Lock to Scale Mode

**Problem**: Playing wrong notes is easy; users want to stay in key.

**Proposed Features**:
- Toggle "lock to scale" mode
- Only in-scale notes are playable (GarageBand "replacement" approach — keys transform to uniform note bars)
- Reuse existing scale infrastructure from chord pads
- Scale selector in piano settings popover
- Curated scale list (research needed on most useful scales)
- "Custom scale" option: user can select/deselect specific notes to create any scale

**Technical**: Use the existing music-theory library's scale bitmask to determine which notes are enabled. Custom scale stores as a 12-bit bitmask.

#### 2.2 Glissando Support

**Problem**: Sliding finger across keys doesn't trigger intermediate notes—only the start and end notes play.

**Proposed Behavior**:
- When pointer moves across keys, trigger note-on for each new key entered
- Previous note gets note-off when leaving that key
- Creates smooth glissando effect
- Rate-limit to prevent MIDI flooding (max ~20 notes/sec)

**Technical**: Track pointer position in `onPointerMove`, detect key boundary crossings, trigger appropriate notes.

**Toggle Location**: Settings popover (not header — keep header uncluttered).

#### 2.3 Responsive Portrait Layout

**Problem**: Portrait piano looks like a "barcode"—keys too narrow to play.

**Proposed Solution** (following UX_GUIDELINES.md patterns):
- Show fewer octaves in portrait (1 octave default)
- Larger, playable key width (minimum 44px for touch targets)
- Horizontal scroll with momentum scrolling
- Scroll position indicator at top
- Octave quick-jump buttons
- No orientation prompts — trust users to rotate if they want landscape

**Implementation**: Container query to detect available width, dynamically adjust number of visible octaves and key sizing.

#### 2.4 Scroll Bar / Navigation

**Problem**: No visual indication of position within full keyboard range.

**Proposed Features**:
- Mini scroll indicator at top showing viewport position within full range
- Tap-to-jump: tap on scroll bar to jump to that octave
- Octave labels on each C key (C1, C2, C3, etc.)

#### 2.5 Octave Labels

**Problem**: Hard to know which octave you're in without looking at settings.

**Proposed Solution**:
- Label "C" keys with octave number (C3, C4, C5)
- Subtle, doesn't interfere with playing
- Highlight middle C (C4) specially

---

### 3. Chord Pads Enhancements

#### 3.1 Custom Chord Banks

**Problem**: Users want their own chord progressions, not just diatonic chords in one key.

**Proposed Features**:
- Create custom banks with any chords (not limited to diatonic)
- Name banks ("Verse", "Chorus", "Jazz Voicings", etc.)
- Arbitrary number of chords per bank (not fixed 7)
- Mix different chord types (maj7, min7, sus2, sus4, add9, etc.)
- Chord picker UI: select root + quality + extensions

#### 3.2 Transposition & Enharmonic Awareness

**Problem**: Users want to transpose their custom banks to different keys.

**Proposed Features**:
- Global transpose slider/selector (+/- semitones or select key)
- Per-chord "absolute" flag: chord stays fixed during transpose (e.g., a signature chord)
- Enharmonic-aware display: show F# vs Gb correctly based on key context
- "Transpose bank" button to permanently shift all chords

**Technical Consideration**: Need to decide if transposition is relative (intervals preserved) or absolute (re-calculate diatonic chords in new key).

#### 3.3 Customizable Labels & Colors

**Problem**: Roman numerals may not be meaningful; users want custom labels.

**Proposed Features**:
- Edit chord display name (e.g., "Cmaj7" → "Home", "Verse Start")
- Custom color per chord column
- Bass note button labels customizable
- Visual groupings (separate verse chords from chorus chords)

#### 3.4 Configurable Bass Notes

**Problem**: Fixed 3 bass notes (Root, 5th, Octave) doesn't suit all workflows; users may want fewer buttons or different notes for slash chords.

**Proposed Features**:
- Choose number of bass notes per chord column: 1, 2, or 3
- Pad sizes adjust automatically based on count
- Custom label for each bass note (not just R/5/8)
- Custom color per bass note
- Configurable interval from root (not limited to 5th/octave)
- Enables flexible slash chord setups (e.g., C/E, Am/G)

#### 3.6 Chord Flavors / Variations

**Problem**: Instead of inversions in different octaves, users might want chord variations.

**Proposed Alternative Layout Option**:
- Instead of Root/1st/2nd/Oct inversions, allow:
  - Chord variations: maj → maj7 → add9 → sus4
  - Or user-defined variations per chord column
- Keep original inversion mode as an option

**Example**:
```
Default mode (inversions):     Variation mode:
  Oct                           sus4
  2nd                           add9
  1st                           maj7
  Root                          maj
```

#### 3.7 Research Questions

These need user/competitor research before implementation:

1. **What do users actually want from chord strips?**
   - Quick songwriting tool?
   - Live performance instrument?
   - Learning aid?

2. **How do competitors handle custom chords?**
   - Apps to research: Suggester, ChordPad, ChordPolyPad, Navichord, Scaler 2

3. **Transposition UX patterns**
   - How do other apps handle "some chords transpose, some don't"?
   - Is this even a real use case?

---

## Competitive Research Findings

Research conducted across 15+ apps (iOS, Android, desktop) plus user feedback from Reddit r/ipadmusic, Audiobus forums, and app reviews.

### Drum Pads: Industry Patterns

**Trigger Modes** (BeatMaker 3 gold standard):
- **One-Shot**: Plays full sample regardless of finger lift
- **Hold**: Plays only while pressed (note-off on release)
- **On-Release**: Triggers on finger lift
- **Note Repeat**: Retrigger at tempo-synced intervals (1/4, 1/8, 1/16, 1/16T, 1/32)

**Edit Mode UX**: No mainstream app uses long-press to edit during play (conflicts with hold-to-sustain). Instead: global Edit/Play mode toggle with **double-tap protection** to exit Play mode (TouchOSC pattern for live performance).

**Grid Sizes**: 4×4 is standard (MPC legacy), but power users request 8×2 ("matches natural finger layout") and 8×8 (fewer bank switches). Koala Sampler uses 4 banks × 16 pads (A/B/C/D).

### Piano: Industry Patterns

**Glissando Modes** (GarageBand):
1. **Glissando**: Sliding triggers each key passed
2. **Scroll**: Sliding moves keyboard position without triggering
3. **Pitch/Portamento**: Smooth pitch bend between notes (synths only)

No rate-limiting observed in apps during glissando—they trigger at touch sample rate.

**Scale Lock** (two approaches):
- **Replacement** (GarageBand): Keyboard transforms to uniform note bars, out-of-scale keys removed entirely. Wrong notes impossible.
- **Highlighting** (Yousician, Simply Piano): All keys visible, target notes color-coded. Feedback on incorrect notes rather than prevention.

Recommendation: Replacement approach is better for performance-focused remote control.

**Portrait Piano**:
- Reduced key count (1-2 octaves)
- Octave navigation buttons (Up/Down/Reset)
- Key width presets (Small/Medium/Large)
- WCAG 1.3.4 notes piano apps are legitimate exception to orientation flexibility

**Touch Targets**: 44-48px minimum (Apple HIG/Material Design). Piano keys typically 8-15mm width.

### Chord Pads: Industry Patterns

**Custom Banks**:
| App | Chords per Bank | Arbitrary Chords | Custom Names | Custom Colors |
|-----|-----------------|------------------|--------------|---------------|
| ChordPolyPad | 128 (8×16) | Yes | Yes | No |
| Navichord | 256 (16×16) | Yes (Tonnetz) | Auto | Theme-based |
| Scaler 2 | Multiple patterns | Yes (note editor) | Yes | Harmonic distance |

**Transposition**: All major apps support global transpose with automatic chord name recalculation. Scaler 2 uses semitone +/- with optional "padlock" to force notes into new scale.

**Notably Absent**: Ability to "pin" specific chords while transposing others. This is a potential differentiator for REAmo.

**Variations vs Inversions**:
- Inversions: Dropdown or +/- control per chord
- Variations (maj7, sus4, add9): Scaler 2 shows in "Colors Page" by harmonic distance. Chord Prism uses black keys as real-time modifiers.

### User Pain Points (Forums/Reviews)

**Critical issues**:
1. **Latency** is #1 complaint across all platforms
2. **MIDI mapping persistence failures** generate significant frustration
3. **System gesture conflicts** (iOS 3-finger gestures) interrupt creative flow

**Common requests**:
- Pressure sensitivity on iPad (never got 3D Touch)
- Larger controls ("fiddly" small touch targets)
- Better discoverability (Koala praised for immediate usability)

---

## Infrastructure Analysis

Codebase exploration to determine implementation feasibility.

### Tempo/BPM Access: Fully Available

BPM is in the Redux transport slice, accessible via:
```typescript
const bpm = useReaperStore((state) => state.bpm);
```

**Source files**:
- `frontend/src/store/slices/transportSlice.ts` (lines 29, 48, 65, 116)
- `frontend/src/core/WebSocketTypes.ts` (lines 94-101)

**Available commands**: `tempo.set()`, `tempo.tap()`, `tempo.getBarDuration()`, `tempo.timeToBeats()`

**Implication**: Tempo-synced note repeat and note lengths are straightforward:
```typescript
const noteLengthMs = (60 / bpm) * (4 / subdivision) * 1000;
// At 120 BPM: 1/16 = 125ms, 1/32 = 62.5ms
```

### Grid Layout Flexibility: Trivial to Parameterize

**Current state** (`DrumPadGrid.tsx`):
- Grid is `grid-cols-4` (hardcoded)
- 16 pads defined in `DEFAULT_PADS` constant (flat array)

**To support 4×2, 8×2, etc.**:
1. Add `columns` prop
2. Accept custom `pads` array
3. Adjust container aspect ratio

No structural refactoring needed—just prop parameterization.

### Chord System: Needs Extension for Variations

**Current capabilities** (`lib/music-theory/`):
- `ChordQuality` type includes: major, minor, diminished, augmented, major7, minor7, dominant7, diminished7, half_diminished7
- `buildDiatonicChord()` generates chords by stacking scale degrees (3rds only)
- `detectChordQuality()` identifies chord type from interval patterns

**Missing for chord variations**:
- No `ChordQuality` entries for: sus2, sus4, add9, add11, 6, 9, 11, 13
- No interval-based chord builder (current system only builds diatonic from scales)
- No function like `buildChordFromIntervals(root, intervals)`

**To add variations**:
1. Extend `ChordQuality` type
2. Add suffix mappings to `CHORD_QUALITY_SUFFIX`
3. Create `buildChordFromIntervals()` function
4. Extend `detectChordQuality()` for new patterns

**Effort**: Medium—infrastructure is solid but needs extension.

### Portrait Piano: Hook Exists, Not Used

**Current state** (`PianoKeyboard.tsx`, `InstrumentsView.tsx:509-518`):
- Hardcoded `min-w-[500px]` with horizontal scroll
- No container queries on piano itself
- `useIsLandscape()` hook controls layout branch

**Available infrastructure**:
- `useContainerQuery` hook exists at `frontend/src/hooks/useContainerQuery.ts`
- CSS `@container` queries supported

**To fix portrait**:
1. Use `useContainerQuery` to detect narrow containers
2. Reduce `numOctaves` or scale keys based on width
3. Add octave navigation buttons

**Effort**: Medium—layout work with existing infrastructure.

### Persistence: Pattern Established

**Two patterns exist**:

1. **Individual keys** (InstrumentsView.tsx):
   ```typescript
   const STORAGE_KEY_DRUMS_CHANNEL = 'reamo_instruments_drums_channel';
   localStorage.setItem(key, String(value));
   ```

2. **JSON object** (uiPreferencesSlice.ts):
   ```typescript
   const UI_PREFS_KEY = 'reamo_ui_preferences';
   localStorage.setItem(key, JSON.stringify(prefs));
   ```

**For custom banks**: JSON object pattern is better for structured data like drum layouts or chord banks.

**Effort**: Low—extend existing pattern.

### Infrastructure Summary

| Feature | Blocked by? | Actual Effort |
|---------|-------------|---------------|
| Trigger modes + note repeat | Nothing | Low |
| Edit mode protection | Nothing | Low |
| Scale lock for piano | Nothing | Low |
| Grid size options | Nothing | Low |
| Custom pad colors/labels | Nothing | Low-Medium |
| Portrait piano fix | Nothing | Medium |
| Custom chord banks | Chord builder | Medium-High |
| Chord variations | Type system extension | Medium-High |
| Pinned chord transpose | Custom chord system | Depends on above |

---

## Implementation Priority (Revised)

Based on competitive research and infrastructure analysis.

### Phase 1: Quick Wins (Low Effort, High Impact)

These have no blockers and address the most common user complaints:

1. **Drums: Trigger mode selector** — One-shot (fixed 200ms), Hold (note-off on release), Note Repeat (tempo-synced 1/8, 1/16, 1/32). BPM already available in store.

2. **Drums: Edit mode with double-tap protection** — Toggle between Edit/Play modes. "Require double-tap to exit Play" setting for live performance confidence.

3. **Piano: Scale lock** — Transform keyboard to show only in-scale notes (GarageBand "replacement" pattern). Reuse existing scale infrastructure from chords.

4. **Piano: Octave labels on C keys** — Label C keys with octave number (C3, C4, C5). Highlight middle C.

5. **Piano: Glissando support** — Trigger note-on for each key crossed during pointer move. Builds on existing pointer handling.

### Phase 2: Layout & Customization (Medium Effort)

6. **Drums: Grid size options** — Support 4×4, 4×2, 8×2. Just prop parameterization of existing component.

7. **Drums: Custom pad colors/labels/notes** — Edit mode UI to configure individual pads. Save to localStorage as JSON.

8. **Drums: Bank switching** — 4 banks (A/B/C/D) following Koala Sampler pattern.

9. **Piano: Responsive portrait layout** — Use existing `useContainerQuery` hook. Reduce octaves, increase key width, add octave nav buttons.

10. **Chords: Global transpose** — Semitone +/- control. Table-stakes feature for chord tools.

11. **Chords: Custom labels & colors** — Edit chord display names and colors.

### Phase 3: Advanced Chord Features (Higher Effort)

Requires extending the music-theory type system:

12. **Chords: Custom chord banks** — Arbitrary chords (not just diatonic). Requires new `buildChordFromIntervals()` function.

13. **Chords: Extended chord qualities** — Add sus2, sus4, add9, 6, 9, 11, 13 to `ChordQuality` type.

14. **Chords: Chord variations mode** — Alternative to inversions (maj → maj7 → add9 → sus4).

15. **Chords: Pinned chord transposition** — Mark specific chords as "absolute" during transpose. Unique differentiator not found in competitors.

### Deferred / Needs Validation

- **Chords: Enharmonic-aware display** — Complexity vs value unclear
- **Layout sharing/export** — Community repository vs local-only
- **Piano: Pitch/portamento mode** — Synth-specific, lower priority

---

## Open Questions

1. **Piano scale lock — scale list**: Which scales to include? GarageBand only offers 6. Curate a "greatest hits" list at implementation time. Also consider "custom scale" option where user can select/deselect specific notes.

**Resolved:**
- **Progressive disclosure**: Moderate — settings in popovers, edit mode separate from play mode

**Resolved:**
- **Shared scale state**: Independent — piano and chords each have their own scale selection, but from the same curated list of available scales
- **MIDI channel routing**: Single channel per instrument for now. MPE exploration deferred.
- **Layout sharing**: Import/export via file picker (JSON files). No server needed. Pattern should extend to Actions and other user-configurable features.
- **Mobile-first**: Always design for mobile first; iPad gets the benefit automatically.
- **Custom bank storage**: User choice — "Global" saves to localStorage (available across projects), "Project" saves to REAPER extstate (travels with project file)
- **Drum trigger mode default**: One-shot (need to be careful about note-off timing and repeat logic for things like snare rolls)
- **Edit mode startup**: Always start in play mode
- **Glissando toggle location**: Settings popover

---

## Appendix: Current File Structure

```
frontend/src/
├── components/Instruments/
│   ├── DrumPad.tsx           # Individual drum pad
│   ├── DrumPadGrid.tsx       # 4×4 grid container
│   ├── PianoKeyboard.tsx     # Multi-octave keyboard
│   ├── PianoKey.tsx          # Individual key
│   ├── OctaveSelector.tsx    # Octave navigation
│   ├── ModWheel.tsx          # CC1 controller
│   ├── PitchBendWheel.tsx    # Pitch bend
│   ├── Chords.tsx            # Chord container
│   ├── ChordColumn.tsx       # Single chord with inversions
│   ├── BassStrip.tsx         # Bass note buttons
│   ├── KeySelector.tsx       # Root note selector
│   └── ScaleSelector.tsx     # Scale type selector
├── views/instruments/
│   └── InstrumentsView.tsx   # Main view orchestrator
├── lib/music-theory/
│   ├── scales.ts             # Scale generation & utilities
│   ├── chords.ts             # Chord building & detection
│   └── voicings.ts           # Inversions & voice leading
└── core/
    └── WebSocketCommands.ts  # MIDI command layer
```
