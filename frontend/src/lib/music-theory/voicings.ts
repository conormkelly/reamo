/**
 * Chord Voicings
 * Inversion generation and voice leading utilities
 *
 * MVP: Basic inversion generation
 * Phase 2: Adaptive voicing, voice leading
 */

/**
 * Generate inversions for a chord
 * An inversion moves the lowest note up an octave
 *
 * @param midiNotes - Array of MIDI note numbers in root position
 * @param numInversions - Number of inversions to generate (default: notes.length - 1)
 * @returns Array of inversions, where [0] is root position
 */
export function generateInversions(
  midiNotes: number[],
  numInversions?: number
): number[][] {
  if (midiNotes.length === 0) return [[]];

  const maxInversions = midiNotes.length - 1;
  const count = numInversions !== undefined ? Math.min(numInversions, maxInversions) : maxInversions;

  const inversions: number[][] = [];

  // Root position
  let current = [...midiNotes].sort((a, b) => a - b);
  inversions.push([...current]);

  // Generate inversions by moving lowest note up an octave
  for (let i = 0; i < count; i++) {
    const lowest = current[0];
    current = [...current.slice(1), lowest + 12].sort((a, b) => a - b);
    inversions.push([...current]);
  }

  return inversions;
}

/**
 * Get the inversion number for a set of MIDI notes
 * 0 = root position, 1 = first inversion, 2 = second inversion, etc.
 *
 * @param midiNotes - Array of MIDI note numbers
 * @param rootNote - MIDI note number of the chord root
 * @returns Inversion number (0-based)
 */
export function getInversionNumber(midiNotes: number[], rootNote: number): number {
  if (midiNotes.length === 0) return 0;

  const sorted = [...midiNotes].sort((a, b) => a - b);
  const bassNote = sorted[0] % 12;
  const root = rootNote % 12;

  if (bassNote === root) return 0; // Root position

  // Get unique pitch classes and sort by distance from root
  // This gives us the chord tones in order: root, 3rd, 5th, 7th...
  const pitchClasses = [...new Set(midiNotes.map((n) => n % 12))];
  pitchClasses.sort((a, b) => {
    const aRel = (a - root + 12) % 12;
    const bRel = (b - root + 12) % 12;
    return aRel - bRel;
  });

  // The inversion number is the position of the bass note in the chord order
  // First inversion = 3rd in bass (index 1), Second = 5th in bass (index 2)
  return pitchClasses.indexOf(bassNote);
}

/**
 * Spread a voicing across octaves (open voicing)
 * Moves alternating notes up an octave for a wider spread
 *
 * @param midiNotes - Array of MIDI note numbers
 * @param spreadInterval - How many octaves to spread (default: 1)
 * @returns Spread voicing
 */
export function spreadVoicing(midiNotes: number[], spreadInterval: number = 1): number[] {
  if (midiNotes.length <= 2) return [...midiNotes];

  const sorted = [...midiNotes].sort((a, b) => a - b);
  const spread = sorted.map((note, idx) => {
    // Keep bass and top, spread middle notes
    if (idx === 0 || idx === sorted.length - 1) return note;
    // Move every other middle note up
    if (idx % 2 === 1) return note + 12 * spreadInterval;
    return note;
  });

  return spread.sort((a, b) => a - b);
}

/**
 * Calculate the total voice movement between two voicings
 * Lower is smoother voice leading
 *
 * @param voicing1 - First voicing (MIDI notes)
 * @param voicing2 - Second voicing (MIDI notes)
 * @returns Total semitones of movement
 */
export function calculateVoiceMovement(voicing1: number[], voicing2: number[]): number {
  if (voicing1.length !== voicing2.length) {
    // Different sizes, calculate by closest notes
    return calculateMinimumMovement(voicing1, voicing2);
  }

  // Sort both and compare corresponding voices
  const sorted1 = [...voicing1].sort((a, b) => a - b);
  const sorted2 = [...voicing2].sort((a, b) => a - b);

  return sorted1.reduce((sum, note, idx) => sum + Math.abs(note - sorted2[idx]), 0);
}

/**
 * Calculate minimum movement between voicings of different sizes
 * Uses greedy matching
 */
function calculateMinimumMovement(voicing1: number[], voicing2: number[]): number {
  const [smaller, larger] = voicing1.length < voicing2.length ? [voicing1, voicing2] : [voicing2, voicing1];

  let totalMovement = 0;
  const usedIndices = new Set<number>();

  for (const note of smaller) {
    let minDist = Infinity;
    let bestIdx = -1;

    for (let i = 0; i < larger.length; i++) {
      if (usedIndices.has(i)) continue;
      const dist = Math.abs(note - larger[i]);
      if (dist < minDist) {
        minDist = dist;
        bestIdx = i;
      }
    }

    if (bestIdx !== -1) {
      totalMovement += minDist;
      usedIndices.add(bestIdx);
    }
  }

  return totalMovement;
}

/**
 * Find the inversion with smoothest voice leading from previous chord
 *
 * @param targetChord - MIDI notes for the target chord (root position)
 * @param previousVoicing - MIDI notes of the previous chord voicing
 * @param inversions - Pre-generated inversions (optional, will generate if not provided)
 * @returns The inversion with minimum voice movement
 */
export function findClosestVoicing(
  targetChord: number[],
  previousVoicing: number[],
  inversions?: number[][]
): number[] {
  if (previousVoicing.length === 0) return targetChord;

  const allInversions = inversions || generateInversions(targetChord);

  let bestInversion = allInversions[0];
  let minMovement = Infinity;

  for (const inversion of allInversions) {
    const movement = calculateVoiceMovement(previousVoicing, inversion);
    if (movement < minMovement) {
      minMovement = movement;
      bestInversion = inversion;
    }
  }

  return bestInversion;
}

/**
 * Transpose a voicing up or down by octaves
 *
 * @param midiNotes - Array of MIDI note numbers
 * @param octaves - Number of octaves to transpose (positive = up, negative = down)
 * @returns Transposed voicing
 */
export function transposeVoicing(midiNotes: number[], octaves: number): number[] {
  const semitones = octaves * 12;
  return midiNotes.map((note) => note + semitones);
}

/**
 * Check if a voicing is within MIDI range (0-127)
 *
 * @param midiNotes - Array of MIDI note numbers
 * @returns true if all notes are in valid MIDI range
 */
export function isVoicingInRange(midiNotes: number[]): boolean {
  return midiNotes.every((note) => note >= 0 && note <= 127);
}

/**
 * Constrain a voicing to be within a MIDI range, transposing by octaves if needed
 *
 * @param midiNotes - Array of MIDI note numbers
 * @param minNote - Minimum MIDI note (default: 36 = C2)
 * @param maxNote - Maximum MIDI note (default: 84 = C6)
 * @returns Transposed voicing within range
 */
export function constrainToRange(
  midiNotes: number[],
  minNote: number = 36,
  maxNote: number = 84
): number[] {
  if (midiNotes.length === 0) return [];

  const sorted = [...midiNotes].sort((a, b) => a - b);
  const lowest = sorted[0];
  const highest = sorted[sorted.length - 1];

  // Calculate how many octaves to shift
  let shift = 0;
  if (lowest < minNote) {
    shift = Math.ceil((minNote - lowest) / 12);
  } else if (highest > maxNote) {
    shift = -Math.ceil((highest - maxNote) / 12);
  }

  if (shift === 0) return midiNotes;

  return transposeVoicing(midiNotes, shift);
}
