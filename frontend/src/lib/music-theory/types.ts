/**
 * Music Theory Types
 * Core type definitions for scales, chords, and MIDI note generation
 */

/** Note names without octave (sharps only, no enharmonic equivalents) */
export type NoteName = 'C' | 'C#' | 'D' | 'D#' | 'E' | 'F' | 'F#' | 'G' | 'G#' | 'A' | 'A#' | 'B';

/** All note names in chromatic order */
export const NOTE_NAMES: NoteName[] = [
  'C',
  'C#',
  'D',
  'D#',
  'E',
  'F',
  'F#',
  'G',
  'G#',
  'A',
  'A#',
  'B',
];

/** Scale types supported */
export type ScaleType =
  | 'major'
  | 'natural_minor'
  | 'harmonic_minor'
  | 'melodic_minor'
  | 'dorian'
  | 'phrygian'
  | 'lydian'
  | 'mixolydian'
  | 'locrian'
  | 'pentatonic_major'
  | 'pentatonic_minor'
  | 'blues';

/** Human-readable scale names for UI display */
export const SCALE_DISPLAY_NAMES: Record<ScaleType, string> = {
  major: 'Major',
  natural_minor: 'Minor',
  harmonic_minor: 'Harmonic Minor',
  melodic_minor: 'Melodic Minor',
  dorian: 'Dorian',
  phrygian: 'Phrygian',
  lydian: 'Lydian',
  mixolydian: 'Mixolydian',
  locrian: 'Locrian',
  pentatonic_major: 'Major Pentatonic',
  pentatonic_minor: 'Minor Pentatonic',
  blues: 'Blues',
};

/** Chord quality derived from intervals */
export type ChordQuality =
  | 'major'
  | 'minor'
  | 'diminished'
  | 'augmented'
  | 'major7'
  | 'minor7'
  | 'dominant7'
  | 'diminished7'
  | 'half_diminished7';

/** Suffix for chord display names by quality */
export const CHORD_QUALITY_SUFFIX: Record<ChordQuality, string> = {
  major: '',
  minor: 'm',
  diminished: 'dim',
  augmented: 'aug',
  major7: 'maj7',
  minor7: 'm7',
  dominant7: '7',
  diminished7: 'dim7',
  half_diminished7: 'm7b5',
};

/** A chord with all info needed for display and MIDI */
export interface Chord {
  /** Root note name */
  root: NoteName;
  /** Chord quality (major, minor, etc.) */
  quality: ChordQuality;
  /** Roman numeral notation (I, ii, iii, IV, V, vi, vii°) */
  romanNumeral: string;
  /** Display name (C, Dm, Em, F, G, Am, Bdim) */
  displayName: string;
  /** Intervals from root in semitones (e.g., [0, 4, 7] for major) */
  intervals: number[];
  /** MIDI note numbers at specified octave */
  midiNotes: number[];
  /** Scale degree (1-7) */
  degree: number;
}

/** Scale definition */
export interface Scale {
  /** Root note name */
  root: NoteName;
  /** Scale type */
  type: ScaleType;
  /** 12-bit bitmask where bit N = semitone N is in scale */
  bitmask: number;
  /** Semitone offsets from root (e.g., [0, 2, 4, 5, 7, 9, 11] for major) */
  degrees: number[];
}

/** Default octave for chord strips (C3-C4 range) */
export const DEFAULT_OCTAVE = 3;

/** Default velocity for chord triggers */
export const DEFAULT_VELOCITY = 100;
