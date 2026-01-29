# Scale Lock for REAmo

## Overview

Scale lock transforms the piano keyboard to show only in-scale notes (GarageBand's "replacement" approach). Wrong notes become impossible — the keyboard displays uniform bars for each scale degree.

**Design goal**: More comprehensive than GarageBand (which offers only 6 scales) while maintaining usability through logical grouping.

---

## Menu Structure

```
┌─────────────────────────────────┐
│  ● Major                        │  ← top-level, one tap
├─────────────────────────────────┤
│    Minor                      ▶ │
│      ├─ ● Natural               │  ← default, emphasized
│      ├─ Harmonic                │
│      └─ Melodic (Jazz)          │
├─────────────────────────────────┤
│    Pentatonic                 ▶ │
│      ├─ Major                   │
│      └─ Minor                   │
├─────────────────────────────────┤
│  ● Blues                        │  ← top-level, one tap
├─────────────────────────────────┤
│    Modes                      ▶ │
│      ├─ Dorian                  │
│      ├─ Phrygian                │
│      ├─ Lydian                  │
│      ├─ Mixolydian              │
│      └─ Locrian                 │
├─────────────────────────────────┤
│    World                      ▶ │
│      ├─ Japanese (Hirajōshi)    │
│      ├─ Arabic (Phrygian Dom.)  │
│      ├─ Hungarian Minor         │
│      └─ Whole Tone              │
└─────────────────────────────────┘
```

### Design Decisions

| Decision | Rationale |
|----------|-----------|
| Major & Blues at top level | Most common, deserve one-tap access |
| Minor as submenu | Groups variants logically; Natural is default |
| Modes exclude Ionian/Aeolian | Ionian = Major, Aeolian = Natural Minor (redundant) |
| World starts with 4 scales | Covers most requests; expandable later |
| Melodic = Jazz Melodic | Same notes ascending/descending; what producers expect |

---

## Scale Definitions

### Top Level

| Scale | Intervals | Semitones | Notes (C) |
|-------|-----------|-----------|-----------|
| **Major** | 1 2 3 4 5 6 7 | 0 2 4 5 7 9 11 | C D E F G A B |
| **Blues** | 1 ♭3 4 ♭5 5 ♭7 | 0 3 5 6 7 10 | C E♭ F G♭ G B♭ |

### Minor Variants

| Scale | Intervals | Semitones | Notes (C) | Character |
|-------|-----------|-----------|-----------|-----------|
| **Natural Minor** | 1 2 ♭3 4 5 ♭6 ♭7 | 0 2 3 5 7 8 10 | C D E♭ F G A♭ B♭ | Default "minor" sound |
| **Harmonic Minor** | 1 2 ♭3 4 5 ♭6 7 | 0 2 3 5 7 8 11 | C D E♭ F G A♭ B | Exotic/tense; raised 7th |
| **Melodic Minor** | 1 2 ♭3 4 5 6 7 | 0 2 3 5 7 9 11 | C D E♭ F G A B | Jazz minor; raised 6th & 7th |

### Pentatonic

| Scale | Intervals | Semitones | Notes (C) | Character |
|-------|-----------|-----------|-----------|-----------|
| **Pentatonic Major** | 1 2 3 5 6 | 0 2 4 7 9 | C D E G A | Happy, folk, country |
| **Pentatonic Minor** | 1 ♭3 4 5 ♭7 | 0 3 5 7 10 | C E♭ F G B♭ | Rock, blues, universal |

### Modes

| Scale | Intervals | Semitones | Notes (C) | Character |
|-------|-----------|-----------|-----------|-----------|
| **Dorian** | 1 2 ♭3 4 5 6 ♭7 | 0 2 3 5 7 9 10 | C D E♭ F G A B♭ | Minor with bright 6th; funk, jazz |
| **Phrygian** | 1 ♭2 ♭3 4 5 ♭6 ♭7 | 0 1 3 5 7 8 10 | C D♭ E♭ F G A♭ B♭ | Spanish, dark, metal |
| **Lydian** | 1 2 3 ♯4 5 6 7 | 0 2 4 6 7 9 11 | C D E F♯ G A B | Dreamy, floaty, film scores |
| **Mixolydian** | 1 2 3 4 5 6 ♭7 | 0 2 4 5 7 9 10 | C D E F G A B♭ | Bluesy major; rock, folk |
| **Locrian** | 1 ♭2 ♭3 4 ♭5 ♭6 ♭7 | 0 1 3 5 6 8 10 | C D♭ E♭ F G♭ A♭ B♭ | Unstable, diminished; rarely used |

### World

| Scale | Intervals | Semitones | Notes (C) | Character |
|-------|-----------|-----------|-----------|-----------|
| **Hirajōshi** | 1 2 ♭3 5 ♭6 | 0 2 3 7 8 | C D E♭ G A♭ | Japanese; melancholic, Eastern |
| **Phrygian Dominant** | 1 ♭2 3 4 5 ♭6 ♭7 | 0 1 4 5 7 8 10 | C D♭ E F G A♭ B♭ | Arabic, Flamenco, metal |
| **Hungarian Minor** | 1 2 ♭3 ♯4 5 ♭6 7 | 0 2 3 6 7 8 11 | C D E♭ F♯ G A♭ B | Dark, dramatic, classical |
| **Whole Tone** | 1 2 3 ♯4 ♯5 ♯6 | 0 2 4 6 8 10 | C D E F♯ G♯ A♯ | Dreamy, ambiguous, Debussy |

---

## Implementation

### Scale Data Structure

```typescript
type ScaleId = 
  // Top level
  | 'major'
  | 'blues'
  // Minor
  | 'natural_minor'
  | 'harmonic_minor'
  | 'melodic_minor'
  // Pentatonic
  | 'pentatonic_major'
  | 'pentatonic_minor'
  // Modes
  | 'dorian'
  | 'phrygian'
  | 'lydian'
  | 'mixolydian'
  | 'locrian'
  // World
  | 'hirajoshi'
  | 'phrygian_dominant'
  | 'hungarian_minor'
  | 'whole_tone';

interface ScaleDefinition {
  id: ScaleId;
  name: string;
  semitones: number[];  // intervals from root (0-11)
  noteCount: number;    // convenience: semitones.length
}

const SCALES: Record<ScaleId, ScaleDefinition> = {
  // Top level
  major: {
    id: 'major',
    name: 'Major',
    semitones: [0, 2, 4, 5, 7, 9, 11],
    noteCount: 7,
  },
  blues: {
    id: 'blues',
    name: 'Blues',
    semitones: [0, 3, 5, 6, 7, 10],
    noteCount: 6,
  },

  // Minor variants
  natural_minor: {
    id: 'natural_minor',
    name: 'Natural Minor',
    semitones: [0, 2, 3, 5, 7, 8, 10],
    noteCount: 7,
  },
  harmonic_minor: {
    id: 'harmonic_minor',
    name: 'Harmonic Minor',
    semitones: [0, 2, 3, 5, 7, 8, 11],
    noteCount: 7,
  },
  melodic_minor: {
    id: 'melodic_minor',
    name: 'Melodic Minor',
    semitones: [0, 2, 3, 5, 7, 9, 11],
    noteCount: 7,
  },

  // Pentatonic
  pentatonic_major: {
    id: 'pentatonic_major',
    name: 'Pentatonic Major',
    semitones: [0, 2, 4, 7, 9],
    noteCount: 5,
  },
  pentatonic_minor: {
    id: 'pentatonic_minor',
    name: 'Pentatonic Minor',
    semitones: [0, 3, 5, 7, 10],
    noteCount: 5,
  },

  // Modes
  dorian: {
    id: 'dorian',
    name: 'Dorian',
    semitones: [0, 2, 3, 5, 7, 9, 10],
    noteCount: 7,
  },
  phrygian: {
    id: 'phrygian',
    name: 'Phrygian',
    semitones: [0, 1, 3, 5, 7, 8, 10],
    noteCount: 7,
  },
  lydian: {
    id: 'lydian',
    name: 'Lydian',
    semitones: [0, 2, 4, 6, 7, 9, 11],
    noteCount: 7,
  },
  mixolydian: {
    id: 'mixolydian',
    name: 'Mixolydian',
    semitones: [0, 2, 4, 5, 7, 9, 10],
    noteCount: 7,
  },
  locrian: {
    id: 'locrian',
    name: 'Locrian',
    semitones: [0, 1, 3, 5, 6, 8, 10],
    noteCount: 7,
  },

  // World
  hirajoshi: {
    id: 'hirajoshi',
    name: 'Japanese (Hirajōshi)',
    semitones: [0, 2, 3, 7, 8],
    noteCount: 5,
  },
  phrygian_dominant: {
    id: 'phrygian_dominant',
    name: 'Arabic (Phrygian Dom.)',
    semitones: [0, 1, 4, 5, 7, 8, 10],
    noteCount: 7,
  },
  hungarian_minor: {
    id: 'hungarian_minor',
    name: 'Hungarian Minor',
    semitones: [0, 2, 3, 6, 7, 8, 11],
    noteCount: 7,
  },
  whole_tone: {
    id: 'whole_tone',
    name: 'Whole Tone',
    semitones: [0, 2, 4, 6, 8, 10],
    noteCount: 6,
  },
};
```

### Menu Structure Data

```typescript
type MenuItemType = 'scale' | 'submenu';

interface ScaleMenuItem {
  type: 'scale';
  scaleId: ScaleId;
  label: string;
}

interface SubmenuItem {
  type: 'submenu';
  label: string;
  children: ScaleMenuItem[];
  defaultScaleId?: ScaleId;  // pre-selected when opening submenu
}

type MenuItem = ScaleMenuItem | SubmenuItem;

const SCALE_MENU: MenuItem[] = [
  { type: 'scale', scaleId: 'major', label: 'Major' },
  {
    type: 'submenu',
    label: 'Minor',
    defaultScaleId: 'natural_minor',
    children: [
      { type: 'scale', scaleId: 'natural_minor', label: 'Natural' },
      { type: 'scale', scaleId: 'harmonic_minor', label: 'Harmonic' },
      { type: 'scale', scaleId: 'melodic_minor', label: 'Melodic (Jazz)' },
    ],
  },
  {
    type: 'submenu',
    label: 'Pentatonic',
    children: [
      { type: 'scale', scaleId: 'pentatonic_major', label: 'Major' },
      { type: 'scale', scaleId: 'pentatonic_minor', label: 'Minor' },
    ],
  },
  { type: 'scale', scaleId: 'blues', label: 'Blues' },
  {
    type: 'submenu',
    label: 'Modes',
    children: [
      { type: 'scale', scaleId: 'dorian', label: 'Dorian' },
      { type: 'scale', scaleId: 'phrygian', label: 'Phrygian' },
      { type: 'scale', scaleId: 'lydian', label: 'Lydian' },
      { type: 'scale', scaleId: 'mixolydian', label: 'Mixolydian' },
      { type: 'scale', scaleId: 'locrian', label: 'Locrian' },
    ],
  },
  {
    type: 'submenu',
    label: 'World',
    children: [
      { type: 'scale', scaleId: 'hirajoshi', label: 'Japanese (Hirajōshi)' },
      { type: 'scale', scaleId: 'phrygian_dominant', label: 'Arabic (Phrygian Dom.)' },
      { type: 'scale', scaleId: 'hungarian_minor', label: 'Hungarian Minor' },
      { type: 'scale', scaleId: 'whole_tone', label: 'Whole Tone' },
    ],
  },
];
```

### Scale Lock State

```typescript
interface ScaleLockState {
  enabled: boolean;
  rootNote: number;      // 0-11 (C=0, C#=1, ... B=11)
  scaleId: ScaleId;
}

const DEFAULT_SCALE_LOCK: ScaleLockState = {
  enabled: false,
  rootNote: 0,           // C
  scaleId: 'major',
};
```

### Core Functions

```typescript
/**
 * Get all MIDI notes in a scale across the full MIDI range
 */
function getScaleNotes(rootNote: number, scaleId: ScaleId): number[] {
  const scale = SCALES[scaleId];
  const notes: number[] = [];

  // For each octave in MIDI range (0-127)
  for (let octave = 0; octave <= 10; octave++) {
    for (const semitone of scale.semitones) {
      const note = rootNote + (octave * 12) + semitone;
      if (note >= 0 && note <= 127) {
        notes.push(note);
      }
    }
  }

  return notes;
}

/**
 * Check if a MIDI note is in the current scale
 */
function isNoteInScale(
  midiNote: number,
  rootNote: number,
  scaleId: ScaleId
): boolean {
  const scale = SCALES[scaleId];
  const noteInOctave = ((midiNote - rootNote) % 12 + 12) % 12;
  return scale.semitones.includes(noteInOctave);
}

/**
 * Get scale degree (1-indexed) for a MIDI note, or null if not in scale
 */
function getScaleDegree(
  midiNote: number,
  rootNote: number,
  scaleId: ScaleId
): number | null {
  const scale = SCALES[scaleId];
  const noteInOctave = ((midiNote - rootNote) % 12 + 12) % 12;
  const index = scale.semitones.indexOf(noteInOctave);
  return index === -1 ? null : index + 1;
}

/**
 * Map a "scale-locked" key index to actual MIDI note
 * Used when keyboard shows only in-scale notes
 */
function scaleIndexToMidiNote(
  scaleIndex: number,  // 0-indexed position on locked keyboard
  rootNote: number,
  scaleId: ScaleId,
  startOctave: number = 4  // middle C octave
): number {
  const scale = SCALES[scaleId];
  const octaveOffset = Math.floor(scaleIndex / scale.noteCount);
  const degreeIndex = scaleIndex % scale.noteCount;
  
  return rootNote + (startOctave * 12) + (octaveOffset * 12) + scale.semitones[degreeIndex];
}
```

---

## UI/UX

### Scale Selector Component

**Inline expand approach** (recommended for mobile):

```
┌─────────────────────────────────┐
│ Scale Lock                [ON]  │
├─────────────────────────────────┤
│ Root: [C] [C#] [D] ... [B]      │  ← horizontal scroll or 2 rows
├─────────────────────────────────┤
│  ● Major                        │
│  ▼ Minor                        │  ← tapped, expanded
│      ● Natural            ✓     │  ← selected
│        Harmonic                 │
│        Melodic (Jazz)           │
│  ▶ Pentatonic                   │  ← collapsed
│    Blues                        │
│  ▶ Modes                        │
│  ▶ World                        │
└─────────────────────────────────┘
```

### Keyboard Transformation

When scale lock is **off**:
```
┌─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┐
│ │█│ │█│ │ │█│ │█│ │█│ │   ← standard piano layout
│ │█│ │█│ │ │█│ │█│ │█│ │      (12 keys per octave)
│ └┬┘ └┬┘ │ └┬┘ └┬┘ └┬┘ │
│  │   │  │  │   │   │  │
└──┴───┴──┴──┴───┴───┴──┘
 C  D  E  F  G  A  B  C
```

When scale lock is **on** (e.g., C Major):
```
┌───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┐
│   │   │   │   │   │   │   │   │   │   │   │   │   │   │
│ C │ D │ E │ F │ G │ A │ B │ C │ D │ E │ F │ G │ A │ B │
│   │   │   │   │   │   │   │   │   │   │   │   │   │   │
└───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┘
  1   2   3   4   5   6   7   1   2   3   4   5   6   7
```

- All keys become equal width
- Only in-scale notes shown
- Root notes (1) could be visually highlighted

### Pentatonic Example (5 notes = wider keys)

C Pentatonic Minor locked:
```
┌─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┐
│     │     │     │     │     │     │     │     │     │     │
│  C  │ E♭  │  F  │  G  │ B♭  │  C  │ E♭  │  F  │  G  │ B♭  │
│     │     │     │     │     │     │     │     │     │     │
└─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┘
   1     2     3     4     5     1     2     3     4     5
```

Fewer notes = bigger touch targets = easier to play.

---

## Display Labels

### Root Note Selector

Use flats for display consistency (or user preference):

```typescript
const NOTE_NAMES = ['C', 'C♯', 'D', 'E♭', 'E', 'F', 'F♯', 'G', 'A♭', 'A', 'B♭', 'B'];

// Or with preference:
const NOTE_NAMES_SHARP = ['C', 'C♯', 'D', 'D♯', 'E', 'F', 'F♯', 'G', 'G♯', 'A', 'A♯', 'B'];
const NOTE_NAMES_FLAT  = ['C', 'D♭', 'D', 'E♭', 'E', 'F', 'G♭', 'G', 'A♭', 'A', 'B♭', 'B'];
```

### Current Scale Display (Header)

When scale lock is active, show in piano header:

```
┌──────────────────────────────────────┐
│  🔒 C Major                    [×]   │  ← tap × or 🔒 to disable
├──────────────────────────────────────┤
│  [piano keys...]                     │
```

Or more compact:
```
┌──────────────────────────────────────┐
│  C Maj 🔒                  ⚙️  Oct 4  │
```

---

## Edge Cases

### Whole Tone Scale

Only 2 unique whole tone scales exist (C and C♯ cover all 12 roots). Display all 12 roots anyway — users expect to pick their root, and it's less confusing than explaining the theory.

### Scale Changes Mid-Performance

If user changes scale while notes are held:
1. **Option A**: Let held notes continue, new presses use new scale
2. **Option B**: Force note-off on all held notes, then apply new scale

Recommend **Option A** — less disruptive during performance.

### Octave Range

When locked, how many octaves to show? Options:
- Fixed 2-3 octaves (simpler)
- User-adjustable (current behavior, keep it)
- Auto-fit based on note count (pentatonic = more octaves since keys are wider)

Recommend keeping user-adjustable octave range. The wider keys in pentatonic naturally give more octaves for the same screen width.

---

## Future Considerations (V2+)

| Feature | Notes |
|---------|-------|
| **Custom scales** | 12-bit bitmask UI; tap notes to include/exclude |
| **More world scales** | In Sen, Double Harmonic, Bebop, etc. |
| **Scale detection** | Analyze incoming MIDI and suggest scale |
| **Chord-scale linking** | Auto-set scale based on chord pad selection |
| **Favorites** | Star frequently used scales for quick access |

---

## Migration from Current Library

Your existing 12 scales map directly:

| Current | New Location |
|---------|--------------|
| `major` | Top level |
| `natural_minor` | Minor → Natural |
| `harmonic_minor` | Minor → Harmonic |
| `melodic_minor` | Minor → Melodic |
| `pentatonic_major` | Pentatonic → Major |
| `pentatonic_minor` | Pentatonic → Minor |
| `blues` | Top level |
| `dorian` | Modes → Dorian |
| `phrygian` | Modes → Phrygian |
| `lydian` | Modes → Lydian |
| `mixolydian` | Modes → Mixolydian |
| `locrian` | Modes → Locrian |

**New scales to add (4):**
- `hirajoshi`
- `phrygian_dominant`
- `hungarian_minor`
- `whole_tone`

---

## Summary

- **16 total scales** organized into logical groups
- **Top-level access** for Major and Blues (most common)
- **Submenus** for variants (Minor, Pentatonic, Modes, World)
- **Natural Minor as default** when selecting "Minor"
- **Jazz Melodic Minor** (ascending form only, consistent)
- **4 World scales** covering Japanese, Arabic, Hungarian, and Whole Tone
- **Inline expand UI** for submenus on mobile
- **Uniform key widths** when locked — fewer notes = wider keys = easier playing
