/**
 * Chord Generation
 * Build diatonic chords from scales using scale degree stacking
 */

import {
  type NoteName,
  type ScaleType,
  type Scale,
  type Chord,
  type ChordQuality,
  CHORD_QUALITY_SUFFIX,
  DEFAULT_OCTAVE,
} from './types';
import {
  SCALE_BITMASKS,
  getScaleDegrees,
  semitoneFromNoteName,
  noteNameFromSemitone,
  createScale,
} from './scales';

/**
 * Detect chord quality from intervals (semitones from root)
 * @param intervals - Array of semitone intervals from root (e.g., [0, 4, 7])
 * @returns Detected chord quality
 */
export function detectChordQuality(intervals: number[]): ChordQuality {
  // Normalize intervals to start from 0
  const sorted = [...intervals].sort((a, b) => a - b);
  const normalized = sorted.map((i) => i - sorted[0]);

  // Check for triads (3 notes)
  if (normalized.length === 3) {
    const third = normalized[1];
    const fifth = normalized[2];

    // Major: 0-4-7
    if (third === 4 && fifth === 7) return 'major';
    // Minor: 0-3-7
    if (third === 3 && fifth === 7) return 'minor';
    // Diminished: 0-3-6
    if (third === 3 && fifth === 6) return 'diminished';
    // Augmented: 0-4-8
    if (third === 4 && fifth === 8) return 'augmented';
  }

  // Check for 7th chords (4 notes)
  if (normalized.length === 4) {
    const third = normalized[1];
    const fifth = normalized[2];
    const seventh = normalized[3];

    // Major 7th: 0-4-7-11
    if (third === 4 && fifth === 7 && seventh === 11) return 'major7';
    // Minor 7th: 0-3-7-10
    if (third === 3 && fifth === 7 && seventh === 10) return 'minor7';
    // Dominant 7th: 0-4-7-10
    if (third === 4 && fifth === 7 && seventh === 10) return 'dominant7';
    // Diminished 7th: 0-3-6-9
    if (third === 3 && fifth === 6 && seventh === 9) return 'diminished7';
    // Half-diminished 7th: 0-3-6-10
    if (third === 3 && fifth === 6 && seventh === 10) return 'half_diminished7';
  }

  // Default to major if unrecognized
  return 'major';
}

/**
 * Get roman numeral for a chord degree and quality
 * @param degree - Scale degree (1-7)
 * @param quality - Chord quality
 * @returns Roman numeral string (e.g., "I", "ii", "iii", "IV", "V", "vi", "vii°")
 */
export function getRomanNumeral(degree: number, quality: ChordQuality): string {
  const numerals = ['I', 'II', 'III', 'IV', 'V', 'VI', 'VII'];
  const base = numerals[degree - 1] || 'I';

  // Major and dominant chords use uppercase
  // Minor, diminished, half-diminished use lowercase
  const isUppercase = quality === 'major' || quality === 'augmented' || quality === 'major7' || quality === 'dominant7';

  const numeral = isUppercase ? base : base.toLowerCase();

  // Add quality suffixes
  switch (quality) {
    case 'diminished':
      return numeral + '°';
    case 'augmented':
      return numeral + '+';
    case 'diminished7':
      return numeral + '°7';
    case 'half_diminished7':
      return numeral + 'ø7';
    case 'major7':
      return numeral + 'M7';
    case 'minor7':
      return numeral + '7';
    case 'dominant7':
      return numeral + '7';
    default:
      return numeral;
  }
}

/**
 * Convert intervals to MIDI note numbers at a given octave
 * @param rootNote - Root note name
 * @param intervals - Semitone intervals from root
 * @param octave - MIDI octave (0-9, where 4 = middle C at MIDI 60)
 * @returns Array of MIDI note numbers
 */
export function intervalsToMidi(rootNote: NoteName, intervals: number[], octave: number): number[] {
  const rootSemitone = semitoneFromNoteName(rootNote);
  // MIDI note = (octave + 1) * 12 + semitone
  // C4 (middle C) = 60 = (4 + 1) * 12 + 0
  const rootMidi = (octave + 1) * 12 + rootSemitone;

  return intervals.map((interval) => rootMidi + interval);
}

/**
 * Build a diatonic chord by stacking scale degrees
 * @param scale - Scale to build chord from
 * @param degree - Scale degree (1-7, where 1 = root chord)
 * @param include7th - Whether to include the 7th degree
 * @param octave - MIDI octave for the chord
 * @returns Chord object
 */
export function buildDiatonicChord(
  scale: Scale,
  degree: number,
  include7th: boolean = false,
  octave: number = DEFAULT_OCTAVE
): Chord {
  // Get the base scale degrees (relative to C)
  const baseBitmask = SCALE_BITMASKS[scale.type];
  const baseDegrees = getScaleDegrees(baseBitmask);

  if (degree < 1 || degree > baseDegrees.length) {
    throw new Error(`Invalid degree ${degree} for scale with ${baseDegrees.length} notes`);
  }

  // Stack thirds to build the chord
  // Root = degree, 3rd = degree+2, 5th = degree+4, 7th = degree+6
  const chordDegreeIndices = [
    degree - 1, // Root (0-indexed)
    (degree - 1 + 2) % baseDegrees.length, // 3rd
    (degree - 1 + 4) % baseDegrees.length, // 5th
  ];

  if (include7th) {
    chordDegreeIndices.push((degree - 1 + 6) % baseDegrees.length);
  }

  // Convert degree indices to semitone intervals
  const rootSemitone = baseDegrees[degree - 1];
  const intervals = chordDegreeIndices.map((idx) => {
    let semitone = baseDegrees[idx] - rootSemitone;
    // Handle wrapping for notes that go past the root
    if (semitone < 0) semitone += 12;
    return semitone;
  });

  // Sort intervals to ensure correct order
  intervals.sort((a, b) => a - b);

  // Get the root note name (transposed from C)
  const rootOffset = semitoneFromNoteName(scale.root);
  const chordRootSemitone = (rootSemitone + rootOffset) % 12;
  const chordRootNote = noteNameFromSemitone(chordRootSemitone);

  // Detect quality and generate display name
  const quality = detectChordQuality(intervals);
  const displayName = chordRootNote + CHORD_QUALITY_SUFFIX[quality];
  const romanNumeral = getRomanNumeral(degree, quality);

  // Convert to MIDI notes
  const midiNotes = intervalsToMidi(chordRootNote, intervals, octave);

  return {
    root: chordRootNote,
    quality,
    romanNumeral,
    displayName,
    intervals,
    midiNotes,
    degree,
  };
}

/**
 * Generate all diatonic chords for a scale
 * @param scale - Scale to generate chords from
 * @param include7th - Whether to include 7th chords
 * @param octave - MIDI octave for the chords
 * @returns Array of 7 Chord objects (one for each scale degree)
 */
export function generateDiatonicChords(
  scale: Scale,
  include7th: boolean = false,
  octave: number = DEFAULT_OCTAVE
): Chord[] {
  const baseBitmask = SCALE_BITMASKS[scale.type];
  const baseDegrees = getScaleDegrees(baseBitmask);

  // Only generate chords for heptatonic scales (7 notes)
  const numChords = Math.min(baseDegrees.length, 7);

  const chords: Chord[] = [];
  for (let degree = 1; degree <= numChords; degree++) {
    chords.push(buildDiatonicChord(scale, degree, include7th, octave));
  }

  return chords;
}

/**
 * Generate diatonic chords for a key and scale type
 * Convenience function that creates the scale and generates chords in one call
 * @param root - Root note name
 * @param scaleType - Scale type
 * @param include7th - Whether to include 7th chords
 * @param octave - MIDI octave for the chords
 * @returns Array of Chord objects
 */
export function generateChordsForKey(
  root: NoteName,
  scaleType: ScaleType,
  include7th: boolean = false,
  octave: number = DEFAULT_OCTAVE
): Chord[] {
  const scale = createScale(root, scaleType);
  return generateDiatonicChords(scale, include7th, octave);
}
