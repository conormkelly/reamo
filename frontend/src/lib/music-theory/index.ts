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
export type { NoteName, ScaleType, ChordQuality, Chord, Scale } from './types';
export { NOTE_NAMES, SCALE_TYPES, CHORD_QUALITY_SUFFIX, DEFAULT_OCTAVE } from './types';

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
