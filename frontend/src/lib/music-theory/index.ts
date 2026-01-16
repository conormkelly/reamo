/**
 * Music Theory Module
 * Pure TypeScript library for scales, chords, and voicings
 *
 * Usage:
 *   import { createScale, generateDiatonicChords } from '@/lib/music-theory';
 *   const scale = createScale('C', 'major');
 *   const chords = generateDiatonicChords(scale);
 */

// Types
export type { NoteName, NoteLetter, Accidental, SpelledNote, ScaleType, ChordQuality, Chord, Scale } from './types';
export {
  NOTE_NAMES,
  NOTE_LETTERS,
  LETTER_SEMITONES,
  ENHARMONIC_DISPLAY,
  SCALE_TYPES,
  SCALE_DISPLAY_NAMES,
  CHORD_QUALITY_SUFFIX,
  DEFAULT_OCTAVE,
  DEFAULT_VELOCITY,
} from './types';

// Scales
export {
  SCALE_BITMASKS,
  getScaleDegrees,
  transposeScale,
  isInScale,
  semitoneFromNoteName,
  noteNameFromSemitone,
  createScale,
  getScaleNotes,
  getScaleDegreeNote,
  countScaleNotes,
  spellNote,
  spellScale,
  getSpelledScaleDegree,
} from './scales';

// Chords
export {
  detectChordQuality,
  getRomanNumeral,
  intervalsToMidi,
  buildDiatonicChord,
  generateDiatonicChords,
  generateChordsForKey,
} from './chords';

// Voicings
export {
  generateInversions,
  getInversionNumber,
  spreadVoicing,
  calculateVoiceMovement,
  findClosestVoicing,
  transposeVoicing,
  isVoicingInRange,
  constrainToRange,
} from './voicings';
