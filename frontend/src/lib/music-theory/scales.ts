/**
 * Scale Utilities
 * Bitmask-based scale representation and manipulation
 *
 * Scale bitmasks use 12 bits where bit N (0-11) indicates if semitone N is in the scale.
 * Bit 0 = root (C in C-rooted scale), Bit 1 = minor 2nd, etc.
 */

import { type NoteName, type ScaleType, type Scale, NOTE_NAMES } from './types';

/**
 * Scale bitmasks - bit N = semitone N is in scale
 * Values from research/CHORD_STRIP_TECH_REFERENCE.md
 */
export const SCALE_BITMASKS: Record<ScaleType, number> = {
  // Bitmask = sum of 2^N for each semitone N in the scale
  major: 0xab5, // intervals: 0,2,4,5,7,9,11
  natural_minor: 0x5ad, // intervals: 0,2,3,5,7,8,10
  harmonic_minor: 0x9ad, // intervals: 0,2,3,5,7,8,11
  melodic_minor: 0xaad, // intervals: 0,2,3,5,7,9,11
  dorian: 0x6ad, // intervals: 0,2,3,5,7,9,10
  phrygian: 0x5ab, // intervals: 0,1,3,5,7,8,10
  lydian: 0xad5, // intervals: 0,2,4,6,7,9,11
  mixolydian: 0x6b5, // intervals: 0,2,4,5,7,9,10
  locrian: 0x56b, // intervals: 0,1,3,5,6,8,10
  pentatonic_major: 0x295, // intervals: 0,2,4,7,9
  pentatonic_minor: 0x4a9, // intervals: 0,3,5,7,10
  blues: 0x4e9, // intervals: 0,3,5,6,7,10
};

/**
 * Convert a 12-bit scale bitmask to an array of semitone offsets (0-11)
 * @param bitmask - 12-bit scale bitmask
 * @returns Array of semitone offsets that are in the scale
 */
export function getScaleDegrees(bitmask: number): number[] {
  const degrees: number[] = [];
  for (let i = 0; i < 12; i++) {
    if ((bitmask & (1 << i)) !== 0) {
      degrees.push(i);
    }
  }
  return degrees;
}

/**
 * Transpose a scale bitmask by a number of semitones (rotate bits)
 * @param bitmask - 12-bit scale bitmask
 * @param semitones - Number of semitones to transpose (positive = up)
 * @returns Transposed bitmask
 */
export function transposeScale(bitmask: number, semitones: number): number {
  // Normalize semitones to 0-11 range
  const shift = ((semitones % 12) + 12) % 12;
  if (shift === 0) return bitmask;

  // Rotate bits left by shift amount, wrapping around 12 bits
  const rotated = ((bitmask << shift) | (bitmask >> (12 - shift))) & 0xfff;
  return rotated;
}

/**
 * Check if a semitone (0-11) is in the scale
 * @param bitmask - 12-bit scale bitmask
 * @param semitone - Semitone to check (0-11)
 * @returns true if the semitone is in the scale
 */
export function isInScale(bitmask: number, semitone: number): boolean {
  const normalizedSemitone = ((semitone % 12) + 12) % 12;
  return (bitmask & (1 << normalizedSemitone)) !== 0;
}

/**
 * Get semitone offset (0-11) from note name
 * @param name - Note name (C, C#, D, etc.)
 * @returns Semitone offset (0 = C, 1 = C#, etc.)
 */
export function semitoneFromNoteName(name: NoteName): number {
  return NOTE_NAMES.indexOf(name);
}

/**
 * Get note name from semitone offset (0-11)
 * @param semitone - Semitone offset (0-11)
 * @returns Note name
 */
export function noteNameFromSemitone(semitone: number): NoteName {
  const normalized = ((semitone % 12) + 12) % 12;
  return NOTE_NAMES[normalized];
}

/**
 * Create a Scale object from root note and scale type
 * @param root - Root note name
 * @param type - Scale type
 * @returns Scale object with bitmask transposed to the root
 */
export function createScale(root: NoteName, type: ScaleType): Scale {
  const baseBitmask = SCALE_BITMASKS[type];
  const rootSemitone = semitoneFromNoteName(root);
  const transposedBitmask = transposeScale(baseBitmask, rootSemitone);

  return {
    root,
    type,
    bitmask: transposedBitmask,
    degrees: getScaleDegrees(transposedBitmask),
  };
}

/**
 * Get the note names in a scale
 * @param scale - Scale object
 * @returns Array of note names in the scale
 */
export function getScaleNotes(scale: Scale): NoteName[] {
  return scale.degrees.map(noteNameFromSemitone);
}

/**
 * Get the Nth scale degree note (1-indexed)
 * @param scale - Scale object
 * @param degree - Scale degree (1 = root, 2 = second, etc.)
 * @returns Note name at that degree, or undefined if out of range
 */
export function getScaleDegreeNote(scale: Scale, degree: number): NoteName | undefined {
  // Get degrees relative to root (need to map back to C-based)
  const rootSemitone = semitoneFromNoteName(scale.root);
  const baseBitmask = SCALE_BITMASKS[scale.type];
  const baseDegrees = getScaleDegrees(baseBitmask);

  if (degree < 1 || degree > baseDegrees.length) {
    return undefined;
  }

  // Get the semitone offset for this degree (relative to C)
  const degreeSemitone = baseDegrees[degree - 1];
  // Add the root offset to get the actual note
  const actualSemitone = (rootSemitone + degreeSemitone) % 12;

  return noteNameFromSemitone(actualSemitone);
}

/**
 * Count the number of notes in a scale
 * @param bitmask - 12-bit scale bitmask
 * @returns Number of notes in the scale
 */
export function countScaleNotes(bitmask: number): number {
  let count = 0;
  let mask = bitmask;
  while (mask) {
    count += mask & 1;
    mask >>= 1;
  }
  return count;
}
