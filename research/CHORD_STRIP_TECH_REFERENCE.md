# Chord Strips Technical Reference

Complete research findings on Logic Remote chord strips implementation, music theory reference data, and chord generation code for REAmo.

---

## 1. Logic Remote Chord Strips Layout

### Strip Count & Arrangement

- **8 chord strips** on standard iPads
- **12 chord strips** on iPad Pro (increased from 8 in version 1.3)
- **Layout**: Horizontal row of vertical strips across the screen

### Visual Design

- Each strip displays the chord name prominently (e.g., "Am", "F", "G7")
- Strips show only **diatonic chords** based on the project's key signature

### Segment Structure (8 segments per strip)

| Segment | Position | Function |
|---------|----------|----------|
| 1-5 | Upper | Chord inversions (highest voicing at top, lowest at bottom) |
| 6-8 | Lower | Bass notes: Root (top), Fifth (middle), Octave (bottom) |

### Chord Types

- **Default**: Diatonic triads only
- **Extensions**: 7ths/9ths require manual editing via chord editor
- **No multiple rows** for different chord types

### Inversions

- **Position-based**: Tap higher on strip = higher voicing, lower = lower voicing
- **No swipe gestures** or menus for inversion selection
- Smart Strings: "Wherever in the chord strip you start the glide, that's the inversion or voicing"

### Bass Notes / Slash Chords

- Lower 3 segments: Root, Fifth, Octave by default
- Custom bass notes set via Edit Chords → Bass wheel
- Play chord + bass together by tapping both simultaneously

### Touch Behavior

- **Touch-down**: Note-on (chord sounds immediately)
- **Touch-up**: Note-off (chord releases)
- **Exception**: Smart Strings pizzicato plays on finger lift
- **Multi-touch**: Fully supported for chord + bass, multiple strips

---

## 2. Scale/Key Selection UX

### Key Synchronization

- Chord strips **automatically sync** with Logic's Signature Track
- No independent key selector in chord strips view
- Changing project key in Logic updates strips immediately

### Scale Mode (Keyboard View)

- Scale button locks notes to chosen scale
- Available scales: Major, Minor, modes, pentatonics (not exhaustively documented)
- Version 1.1 "adds more scale choices for Touch Instruments"

### Custom Scales

- **Not supported** — users limited to Apple's presets

### Custom Chords

- Access: Settings → Edit Chords
- Wheels for: Root note, Chord type, Extensions, Bass note
- Custom chords available across all Touch Instruments in project

---

## 3. Scale Bitmasks

12-bit bitmasks where bit 0 = root, bit 1 = minor 2nd, etc.

### Heptatonic Scales (7 notes)

| Scale | Intervals | Binary | Hex |
|-------|-----------|--------|-----|
| Major (Ionian) | 0,2,4,5,7,9,11 | `101010110101` | `0xAB5` |
| Natural Minor (Aeolian) | 0,2,3,5,7,8,10 | `101101011010` | `0xB5A` |
| Harmonic Minor | 0,2,3,5,7,8,11 | `101100011010` | `0xB1A` |
| Melodic Minor (asc) | 0,2,3,5,7,9,11 | `101010011010` | `0xA9A` |
| Dorian | 0,2,3,5,7,9,10 | `101011011010` | `0xADA` |
| Phrygian | 0,1,3,5,7,8,10 | `101101010110` | `0xB56` |
| Lydian | 0,2,4,6,7,9,11 | `101010101101` | `0xAAD` |
| Mixolydian | 0,2,4,5,7,9,10 | `101011010101` | `0xAD5` |
| Locrian | 0,1,3,5,6,8,10 | `101101101010` | `0xB6A` |

### Pentatonic & Blues Scales

| Scale | Intervals | Binary | Hex |
|-------|-----------|--------|-----|
| Major Pentatonic | 0,2,4,7,9 | `001010010101` | `0x295` |
| Minor Pentatonic | 0,3,5,7,10 | `010100101001` | `0x529` |
| Blues | 0,3,5,6,7,10 | `010110101001` | `0x5A9` |

### Usage Example

```javascript
const SCALES = {
  major:           0xAB5,
  naturalMinor:    0xB5A,
  harmonicMinor:   0xB1A,
  melodicMinor:    0xA9A,
  dorian:          0xADA,
  phrygian:        0xB56,
  lydian:          0xAAD,
  mixolydian:      0xAD5,
  locrian:         0xB6A,
  majorPentatonic: 0x295,
  minorPentatonic: 0x529,
  blues:           0x5A9
};

// Check if a note is in the scale
function isInScale(scaleBitmask, semitone) {
  return (scaleBitmask & (1 << (semitone % 12))) !== 0;
}
```

---

## 4. Chord Construction from Scale

### Diatonic Triads

For any 7-note scale, build triads by stacking scale degrees:

- **Root**: Scale degree N
- **Third**: Scale degree N+2 (skip one)
- **Fifth**: Scale degree N+4 (skip two more)

### Major Scale Diatonic Triads

| Degree | Roman | Chord | Intervals | Quality |
|--------|-------|-------|-----------|---------|
| 1 | I | C | 0-4-7 | Major |
| 2 | ii | Dm | 0-3-7 | Minor |
| 3 | iii | Em | 0-3-7 | Minor |
| 4 | IV | F | 0-4-7 | Major |
| 5 | V | G | 0-4-7 | Major |
| 6 | vi | Am | 0-3-7 | Minor |
| 7 | vii° | Bdim | 0-3-6 | Diminished |

### Diatonic 7th Chords

Add scale degree N+6 (the 7th):

| Degree | Roman | Chord | Intervals | Quality |
|--------|-------|-------|-----------|---------|
| 1 | Imaj7 | Cmaj7 | 0-4-7-11 | Major 7th |
| 2 | ii7 | Dm7 | 0-3-7-10 | Minor 7th |
| 3 | iii7 | Em7 | 0-3-7-10 | Minor 7th |
| 4 | IVmaj7 | Fmaj7 | 0-4-7-11 | Major 7th |
| 5 | V7 | G7 | 0-4-7-10 | Dominant 7th |
| 6 | vi7 | Am7 | 0-3-7-10 | Minor 7th |
| 7 | viiø7 | Bø7 | 0-3-6-10 | Half-diminished |

### Chord Quality Detection

| 3rd Interval | 5th Interval | 7th Interval | Quality |
|--------------|--------------|--------------|---------|
| 4 (major 3rd) | 7 (perfect 5th) | — | Major |
| 3 (minor 3rd) | 7 (perfect 5th) | — | Minor |
| 3 (minor 3rd) | 6 (diminished 5th) | — | Diminished |
| 4 (major 3rd) | 8 (augmented 5th) | — | Augmented |
| 4 | 7 | 11 | Major 7th |
| 3 | 7 | 10 | Minor 7th |
| 4 | 7 | 10 | Dominant 7th |
| 3 | 6 | 10 | Half-diminished |
| 3 | 6 | 9 | Diminished 7th |

### Suspended Chords

Suspended chords replace the 3rd—they are **chromatic additions**, not strictly diatonic:

| Type | Intervals | Notes (from C) |
|------|-----------|----------------|
| sus2 | 0-2-7 | C-D-G |
| sus4 | 0-5-7 | C-F-G |

---

## 5. Voicing and Octave

### Default Octave Range

- **Recommended**: C3-C4 (MIDI 48-60) for chord strips
- Sits well in mix without conflicting with bass or leads
- Logic Remote uses approximately this range

### Root Position vs Inversions

- **Default**: Root position (root as lowest note)
- **Inversions**: Secondary, accessed via strip segments
  - 1st inversion: 3rd in bass
  - 2nd inversion: 5th in bass

### Typical Velocity

- **Standard pads**: 80-100 velocity
- **Logic Remote issue**: Compressed to 95-110 (problematic)
- **REAmo target**: Full 1-127 range via Y-position mapping

---

## 6. Design Recommendations for REAmo

### Orientation

**Landscape** — more strips visible, matches piano/keyboard mental model

### Multi-touch

**Essential** — users must be able to hold one chord while tapping another for smooth voice leading and transitions

### Strum/Arpeggiate Support

**Yes** — configurable note-on delay:

- 0ms = block chord (simultaneous)
- 10-50ms per note = strum effect
- Direction: up (low to high) or down (high to low)

### Bass Strip

**Separate bottom row** — enables independent bass note selection for slash chords (C/G, Am/E, etc.)

---

## 7. Chord Generation Implementation

```javascript
/**
 * REAmo Chord Strips - Chord Generation Module
 * 
 * Generates diatonic chords from any scale bitmask and root note.
 */

// ============================================
// CONSTANTS
// ============================================

const NOTE_NAMES = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];

const SCALES = {
  major:           0xAB5,  // 101010110101
  naturalMinor:    0xB5A,  // 101101011010
  harmonicMinor:   0xB1A,  // 101100011010
  melodicMinor:    0xA9A,  // 101010011010
  dorian:          0xADA,  // 101011011010
  phrygian:        0xB56,  // 101101010110
  lydian:          0xAAD,  // 101010101101
  mixolydian:      0xAD5,  // 101011010101
  locrian:         0xB6A,  // 101101101010
  majorPentatonic: 0x295,  // 001010010101
  minorPentatonic: 0x529,  // 010100101001
  blues:           0x5A9   // 010110101001
};

const CHORD_QUALITIES = {
  major:          { symbol: '',    intervals: [0, 4, 7] },
  minor:          { symbol: 'm',   intervals: [0, 3, 7] },
  diminished:     { symbol: '°',   intervals: [0, 3, 6] },
  augmented:      { symbol: '+',   intervals: [0, 4, 8] },
  major7:         { symbol: 'maj7', intervals: [0, 4, 7, 11] },
  minor7:         { symbol: 'm7',   intervals: [0, 3, 7, 10] },
  dominant7:      { symbol: '7',    intervals: [0, 4, 7, 10] },
  halfDiminished: { symbol: 'ø7',   intervals: [0, 3, 6, 10] },
  diminished7:    { symbol: '°7',   intervals: [0, 3, 6, 9] },
  sus2:           { symbol: 'sus2', intervals: [0, 2, 7] },
  sus4:           { symbol: 'sus4', intervals: [0, 5, 7] }
};

const ROMAN_NUMERALS = ['I', 'II', 'III', 'IV', 'V', 'VI', 'VII'];

// ============================================
// SCALE UTILITIES
// ============================================

/**
 * Extract scale degrees (semitones from root) from a bitmask
 * @param {number} bitmask - 12-bit scale bitmask
 * @returns {number[]} Array of semitones in the scale
 */
function getScaleDegrees(bitmask) {
  const degrees = [];
  for (let i = 0; i < 12; i++) {
    if (bitmask & (1 << i)) {
      degrees.push(i);
    }
  }
  return degrees;
}

/**
 * Transpose a scale bitmask to a new root
 * @param {number} bitmask - Original scale bitmask (assumes root = 0)
 * @param {number} newRoot - New root note (0-11, where 0=C)
 * @returns {number} Transposed bitmask
 */
function transposeScale(bitmask, newRoot) {
  // Rotate the bitmask left by newRoot positions (with wrap)
  const rotated = ((bitmask << newRoot) | (bitmask >> (12 - newRoot))) & 0xFFF;
  return rotated;
}

/**
 * Check if a semitone is in the scale
 * @param {number} bitmask - Scale bitmask
 * @param {number} semitone - Semitone to check (0-11)
 * @returns {boolean}
 */
function isInScale(bitmask, semitone) {
  return (bitmask & (1 << (semitone % 12))) !== 0;
}

// ============================================
// CHORD CONSTRUCTION
// ============================================

/**
 * Determine chord quality from intervals
 * @param {number} thirdInterval - Semitones from root to third
 * @param {number} fifthInterval - Semitones from root to fifth
 * @param {number} [seventhInterval] - Semitones from root to seventh (optional)
 * @returns {string} Chord quality key
 */
function detectChordQuality(thirdInterval, fifthInterval, seventhInterval = null) {
  // Triads
  if (seventhInterval === null) {
    if (thirdInterval === 4 && fifthInterval === 7) return 'major';
    if (thirdInterval === 3 && fifthInterval === 7) return 'minor';
    if (thirdInterval === 3 && fifthInterval === 6) return 'diminished';
    if (thirdInterval === 4 && fifthInterval === 8) return 'augmented';
    return 'major'; // fallback
  }
  
  // 7th chords
  if (thirdInterval === 4 && fifthInterval === 7 && seventhInterval === 11) return 'major7';
  if (thirdInterval === 3 && fifthInterval === 7 && seventhInterval === 10) return 'minor7';
  if (thirdInterval === 4 && fifthInterval === 7 && seventhInterval === 10) return 'dominant7';
  if (thirdInterval === 3 && fifthInterval === 6 && seventhInterval === 10) return 'halfDiminished';
  if (thirdInterval === 3 && fifthInterval === 6 && seventhInterval === 9) return 'diminished7';
  
  return 'major7'; // fallback
}

/**
 * Build a single diatonic chord from a scale
 * @param {number[]} scaleDegrees - Array of semitones in the scale
 * @param {number} degreeIndex - Which scale degree to build chord on (0-6)
 * @param {number} rootNote - MIDI note number of the scale root
 * @param {boolean} includeSeventh - Whether to include the 7th
 * @returns {Object} Chord object with notes, quality, name, etc.
 */
function buildDiatonicChord(scaleDegrees, degreeIndex, rootNote, includeSeventh = false) {
  const numDegrees = scaleDegrees.length;
  
  // Get scale degrees for chord tones (stacking 3rds within the scale)
  const chordRoot = scaleDegrees[degreeIndex];
  const chordThird = scaleDegrees[(degreeIndex + 2) % numDegrees];
  const chordFifth = scaleDegrees[(degreeIndex + 4) % numDegrees];
  const chordSeventh = scaleDegrees[(degreeIndex + 6) % numDegrees];
  
  // Calculate intervals from chord root
  const thirdInterval = (chordThird - chordRoot + 12) % 12;
  const fifthInterval = (chordFifth - chordRoot + 12) % 12;
  const seventhInterval = (chordSeventh - chordRoot + 12) % 12;
  
  // Determine quality
  const quality = detectChordQuality(
    thirdInterval, 
    fifthInterval, 
    includeSeventh ? seventhInterval : null
  );
  
  // Build MIDI note array
  const chordRootMidi = rootNote + chordRoot;
  const notes = [
    chordRootMidi,
    chordRootMidi + thirdInterval,
    chordRootMidi + fifthInterval
  ];
  
  if (includeSeventh) {
    notes.push(chordRootMidi + seventhInterval);
  }
  
  // Generate chord name
  const rootName = NOTE_NAMES[chordRoot];
  const qualityInfo = CHORD_QUALITIES[quality];
  const chordName = rootName + qualityInfo.symbol;
  
  // Roman numeral (lowercase for minor/diminished)
  let roman = ROMAN_NUMERALS[degreeIndex];
  if (quality === 'minor' || quality === 'diminished' || 
      quality === 'minor7' || quality === 'halfDiminished') {
    roman = roman.toLowerCase();
  }
  if (quality === 'diminished' || quality === 'halfDiminished') {
    roman += '°';
  }
  if (includeSeventh) {
    roman += '7';
  }
  
  return {
    degreeIndex,
    roman,
    name: chordName,
    quality,
    root: chordRootMidi,
    notes,
    intervals: includeSeventh 
      ? [0, thirdInterval, fifthInterval, seventhInterval]
      : [0, thirdInterval, fifthInterval]
  };
}

/**
 * Generate all diatonic chords for a scale
 * @param {string} scaleName - Key in SCALES object
 * @param {number} rootNote - MIDI note number of scale root (e.g., 60 for C4)
 * @param {boolean} includeSeventh - Whether to generate 7th chords
 * @returns {Object[]} Array of chord objects
 */
function generateDiatonicChords(scaleName, rootNote, includeSeventh = false) {
  const bitmask = SCALES[scaleName];
  if (!bitmask) {
    throw new Error(`Unknown scale: ${scaleName}`);
  }
  
  const scaleDegrees = getScaleDegrees(bitmask);
  
  // Only generate 7 chords for heptatonic scales
  const numChords = Math.min(scaleDegrees.length, 7);
  
  const chords = [];
  for (let i = 0; i < numChords; i++) {
    chords.push(buildDiatonicChord(scaleDegrees, i, rootNote, includeSeventh));
  }
  
  return chords;
}

// ============================================
// INVERSIONS
// ============================================

/**
 * Generate all inversions of a chord
 * @param {number[]} notes - Array of MIDI note numbers (root position)
 * @returns {number[][]} Array of note arrays, one per inversion
 */
function generateInversions(notes) {
  const inversions = [notes.slice()]; // Root position
  
  for (let i = 1; i < notes.length; i++) {
    const prev = inversions[i - 1];
    const inversion = prev.slice(1); // Remove lowest note
    inversion.push(prev[0] + 12);     // Add it an octave higher
    inversions.push(inversion);
  }
  
  return inversions;
}

/**
 * Generate chord voicings at different octave positions
 * @param {number[]} notes - Chord notes (root position)
 * @param {number} baseOctave - Base octave (e.g., 3 for C3)
 * @param {number} numVoicings - Number of voicing positions (e.g., 5)
 * @returns {number[][]} Array of voiced note arrays
 */
function generateVoicings(notes, baseOctave = 3, numVoicings = 5) {
  const inversions = generateInversions(notes);
  const voicings = [];
  
  // Spread voicings across the specified positions
  // Lower index = lower voicing, higher index = higher voicing
  for (let i = 0; i < numVoicings; i++) {
    const inversionIndex = Math.floor(i * inversions.length / numVoicings);
    const octaveOffset = Math.floor(i / inversions.length) * 12;
    
    const voicing = inversions[inversionIndex % inversions.length].map(
      note => note + octaveOffset
    );
    
    // Normalize to base octave
    const lowestNote = Math.min(...voicing);
    const targetLowest = (baseOctave + 1) * 12 + Math.floor(i * 12 / numVoicings);
    const adjustment = targetLowest - lowestNote;
    
    voicings.push(voicing.map(n => n + adjustment));
  }
  
  return voicings;
}

// ============================================
// BASS NOTES
// ============================================

/**
 * Generate bass notes for a chord
 * @param {number} chordRoot - MIDI note of chord root
 * @param {number} bassOctave - Octave for bass notes (e.g., 2 for C2)
 * @returns {Object} Bass note options
 */
function generateBassNotes(chordRoot, bassOctave = 2) {
  const rootInBassOctave = (bassOctave + 1) * 12 + (chordRoot % 12);
  
  return {
    root: rootInBassOctave,
    fifth: rootInBassOctave + 7,
    octave: rootInBassOctave + 12
  };
}

// ============================================
// MAIN CHORD STRIP GENERATOR
// ============================================

/**
 * Generate complete chord strip data for UI
 * @param {Object} config - Configuration object
 * @param {string} config.scale - Scale name (key in SCALES)
 * @param {string} config.key - Root note name (e.g., 'C', 'F#')
 * @param {number} config.octave - Base octave for chords (default 3)
 * @param {boolean} config.sevenths - Include 7th chords (default false)
 * @param {number} config.voicings - Number of voicing rows (default 5)
 * @returns {Object[]} Array of chord strip data
 */
function generateChordStrips(config) {
  const {
    scale = 'major',
    key = 'C',
    octave = 3,
    sevenths = false,
    voicings = 5
  } = config;
  
  // Convert key name to MIDI root
  const keyIndex = NOTE_NAMES.indexOf(key.toUpperCase());
  if (keyIndex === -1) {
    throw new Error(`Unknown key: ${key}`);
  }
  const rootNote = (octave + 1) * 12 + keyIndex; // e.g., C3 = 48
  
  // Generate diatonic chords
  const chords = generateDiatonicChords(scale, rootNote, sevenths);
  
  // Build strip data for each chord
  return chords.map(chord => {
    const chordVoicings = generateVoicings(chord.notes, octave, voicings);
    const bassNotes = generateBassNotes(chord.root, octave - 1);
    
    return {
      // Identity
      name: chord.name,
      roman: chord.roman,
      quality: chord.quality,
      degreeIndex: chord.degreeIndex,
      
      // Note data
      rootNote: chord.root,
      intervals: chord.intervals,
      
      // Voicings (index 0 = lowest, index N = highest)
      voicings: chordVoicings,
      
      // Bass notes
      bass: {
        root: bassNotes.root,
        fifth: bassNotes.fifth,
        octave: bassNotes.octave
      }
    };
  });
}

// ============================================
// ADAPTIVE VOICING (BONUS)
// ============================================

/**
 * Calculate total voice movement between two chords
 * @param {number[]} chord1 - First chord notes
 * @param {number[]} chord2 - Second chord notes
 * @returns {number} Total semitones of movement
 */
function voiceMovement(chord1, chord2) {
  // Simple: sum of absolute differences for matching voices
  let total = 0;
  const len = Math.min(chord1.length, chord2.length);
  for (let i = 0; i < len; i++) {
    total += Math.abs(chord1[i] - chord2[i]);
  }
  return total;
}

/**
 * Find the voicing of chord2 that minimizes movement from chord1
 * @param {number[]} prevChord - Previous chord notes
 * @param {number[][]} nextVoicings - Available voicings for next chord
 * @returns {number} Index of best voicing
 */
function findAdaptiveVoicing(prevChord, nextVoicings) {
  let bestIndex = 0;
  let bestMovement = Infinity;
  
  nextVoicings.forEach((voicing, index) => {
    const movement = voiceMovement(prevChord, voicing);
    if (movement < bestMovement) {
      bestMovement = movement;
      bestIndex = index;
    }
  });
  
  return bestIndex;
}

// ============================================
// EXPORTS
// ============================================

export {
  // Constants
  NOTE_NAMES,
  SCALES,
  CHORD_QUALITIES,
  ROMAN_NUMERALS,
  
  // Scale utilities
  getScaleDegrees,
  transposeScale,
  isInScale,
  
  // Chord construction
  detectChordQuality,
  buildDiatonicChord,
  generateDiatonicChords,
  
  // Voicings
  generateInversions,
  generateVoicings,
  
  // Bass
  generateBassNotes,
  
  // Main generator
  generateChordStrips,
  
  // Adaptive voicing
  voiceMovement,
  findAdaptiveVoicing
};
```

---

## 8. Usage Example

```javascript
import { generateChordStrips, SCALES } from './chordGenerator.js';

// Generate C Major chord strips with triads
const strips = generateChordStrips({
  scale: 'major',
  key: 'C',
  octave: 3,
  sevenths: false,
  voicings: 5
});

console.log(strips);
// [
//   {
//     name: 'C',
//     roman: 'I',
//     quality: 'major',
//     degreeIndex: 0,
//     rootNote: 48,
//     intervals: [0, 4, 7],
//     voicings: [[48, 52, 55], [52, 55, 60], ...],
//     bass: { root: 36, fifth: 43, octave: 48 }
//   },
//   {
//     name: 'Dm',
//     roman: 'ii',
//     quality: 'minor',
//     ...
//   },
//   // ... 5 more chords
// ]

// Generate F minor 7th chords
const minorStrips = generateChordStrips({
  scale: 'naturalMinor',
  key: 'F',
  octave: 3,
  sevenths: true,
  voicings: 5
});
```

---

## 9. Integration with WebSocket MIDI

```javascript
/**
 * Send chord notes via WebSocket to REAPER
 * @param {WebSocket} ws - Active WebSocket connection
 * @param {number[]} notes - MIDI note numbers to play
 * @param {number} velocity - Note velocity (1-127)
 * @param {number} channel - MIDI channel (0-15)
 * @param {boolean} noteOn - true for note-on, false for note-off
 */
function sendChordMidi(ws, notes, velocity, channel = 0, noteOn = true) {
  const statusByte = noteOn ? (0x90 | channel) : (0x80 | channel);
  
  notes.forEach(note => {
    // Format: midi/noteOn or midi/noteOff with velocity 0
    const message = {
      command: 'midi/noteOn',
      note: note,
      velocity: noteOn ? velocity : 0,
      channel: channel
    };
    
    ws.send(JSON.stringify(message));
  });
}

/**
 * Handle chord strip touch
 * @param {Object} strip - Chord strip data from generateChordStrips()
 * @param {number} voicingIndex - Which voicing segment was touched (0-4)
 * @param {number} yPosition - Y position within segment (0-1, for velocity)
 * @param {WebSocket} ws - WebSocket connection
 * @param {number} channel - MIDI channel
 */
function onChordStripTouch(strip, voicingIndex, yPosition, ws, channel) {
  // Map Y position to velocity (top = 127, bottom = 40)
  const velocity = Math.round(40 + (1 - yPosition) * 87);
  
  // Get the voicing notes
  const notes = strip.voicings[voicingIndex];
  
  // Send note-on messages
  sendChordMidi(ws, notes, velocity, channel, true);
  
  // Return release function for touch-up
  return () => {
    sendChordMidi(ws, notes, 0, channel, false);
  };
}
```
