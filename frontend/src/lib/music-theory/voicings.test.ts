/**
 * Chord Voicings Tests
 */

import { describe, it, expect } from 'vitest';
import {
  generateInversions,
  getInversionNumber,
  spreadVoicing,
  calculateVoiceMovement,
  findClosestVoicing,
  transposeVoicing,
  isVoicingInRange,
  constrainToRange,
} from './voicings';

describe('voicings', () => {
  describe('generateInversions', () => {
    it('generates root position as first inversion', () => {
      // C major triad: C3, E3, G3 (48, 52, 55)
      const inversions = generateInversions([48, 52, 55]);
      expect(inversions[0]).toEqual([48, 52, 55]);
    });

    it('generates first inversion correctly', () => {
      // C major: root = [48, 52, 55], first inversion = [52, 55, 60]
      const inversions = generateInversions([48, 52, 55]);
      expect(inversions[1]).toEqual([52, 55, 60]);
    });

    it('generates second inversion correctly', () => {
      // C major: second inversion = [55, 60, 64]
      const inversions = generateInversions([48, 52, 55]);
      expect(inversions[2]).toEqual([55, 60, 64]);
    });

    it('generates correct number of inversions for triad', () => {
      const inversions = generateInversions([48, 52, 55]);
      expect(inversions).toHaveLength(3); // Root + 2 inversions
    });

    it('generates correct number of inversions for 7th chord', () => {
      // C major 7: C, E, G, B
      const inversions = generateInversions([48, 52, 55, 59]);
      expect(inversions).toHaveLength(4); // Root + 3 inversions
    });

    it('respects numInversions parameter', () => {
      const inversions = generateInversions([48, 52, 55], 1);
      expect(inversions).toHaveLength(2); // Root + 1 inversion
    });

    it('handles empty array', () => {
      const inversions = generateInversions([]);
      expect(inversions).toEqual([[]]);
    });

    it('handles single note', () => {
      const inversions = generateInversions([60]);
      expect(inversions).toEqual([[60]]);
    });

    it('sorts unsorted input', () => {
      // Input in wrong order
      const inversions = generateInversions([55, 48, 52]);
      expect(inversions[0]).toEqual([48, 52, 55]); // Should be sorted
    });
  });

  describe('getInversionNumber', () => {
    it('returns 0 for root position', () => {
      // C in bass of C major triad
      expect(getInversionNumber([48, 52, 55], 48)).toBe(0);
      expect(getInversionNumber([60, 64, 67], 60)).toBe(0);
    });

    it('returns 1 for first inversion', () => {
      // E in bass of C major triad (C root)
      expect(getInversionNumber([52, 55, 60], 48)).toBe(1);
    });

    it('returns 2 for second inversion', () => {
      // G in bass of C major triad (C root)
      expect(getInversionNumber([55, 60, 64], 48)).toBe(2);
    });

    it('handles different octaves for root', () => {
      // Root can be any octave
      expect(getInversionNumber([48, 52, 55], 60)).toBe(0); // C4 is also C
    });

    it('returns 0 for empty array', () => {
      expect(getInversionNumber([], 48)).toBe(0);
    });
  });

  describe('spreadVoicing', () => {
    it('returns same notes for 2 or fewer notes', () => {
      expect(spreadVoicing([48, 55])).toEqual([48, 55]);
      expect(spreadVoicing([48])).toEqual([48]);
    });

    it('spreads middle notes of triad', () => {
      // C major: 48, 52, 55 -> keep bass and top, spread middle
      const spread = spreadVoicing([48, 52, 55]);
      // Bass stays at 48, top stays at 55, middle E goes up an octave to 64
      expect(spread).toEqual([48, 55, 64]);
    });

    it('keeps bass and top notes in place', () => {
      const spread = spreadVoicing([48, 52, 55, 59]);
      expect(spread[0]).toBe(48); // Bass unchanged
      expect(spread).toContain(59); // Top unchanged (but position may change due to sorting)
    });

    it('respects spreadInterval parameter', () => {
      const spread = spreadVoicing([48, 52, 55], 2);
      // Middle note should go up 2 octaves (24 semitones)
      expect(spread).toContain(52 + 24);
    });
  });

  describe('calculateVoiceMovement', () => {
    it('returns 0 for identical voicings', () => {
      expect(calculateVoiceMovement([48, 52, 55], [48, 52, 55])).toBe(0);
    });

    it('calculates movement for simple case', () => {
      // Each voice moves 1 semitone
      expect(calculateVoiceMovement([48, 52, 55], [49, 53, 56])).toBe(3);
    });

    it('calculates movement correctly for chord changes', () => {
      // C major to G major in close position
      const cMajor = [48, 52, 55]; // C, E, G
      const gMajor = [47, 50, 55]; // B, D, G
      // Movement: C->B (1), E->D (2), G->G (0) = 3
      expect(calculateVoiceMovement(cMajor, gMajor)).toBe(3);
    });

    it('handles different sized voicings', () => {
      // Uses greedy matching for different sizes
      const triad = [48, 52, 55];
      const seventh = [48, 52, 55, 59];
      const movement = calculateVoiceMovement(triad, seventh);
      // Should match 3 closest notes
      expect(movement).toBe(0); // All triad notes are in the 7th chord
    });
  });

  describe('findClosestVoicing', () => {
    it('returns target chord when no previous voicing', () => {
      const target = [48, 52, 55];
      expect(findClosestVoicing(target, [])).toEqual(target);
    });

    it('finds closest inversion to previous chord', () => {
      // Previous: G major (55, 59, 62) - G, B, D high
      // Target: C major - should prefer inversion closest to this
      const previous = [55, 59, 62];
      const target = [48, 52, 55]; // C major root position

      const closest = findClosestVoicing(target, previous);
      // Second inversion [55, 60, 64] is closest to [55, 59, 62]
      expect(closest[0]).toBe(55); // G in bass (second inversion)
    });

    it('uses provided inversions when given', () => {
      const target = [48, 52, 55];
      const previous = [60, 64, 67];
      const inversions = [[48, 52, 55], [52, 55, 60]];

      const closest = findClosestVoicing(target, previous, inversions);
      // Should pick from provided inversions only
      expect(inversions).toContainEqual(closest);
    });
  });

  describe('transposeVoicing', () => {
    it('transposes up by octaves', () => {
      expect(transposeVoicing([48, 52, 55], 1)).toEqual([60, 64, 67]);
    });

    it('transposes down by octaves', () => {
      expect(transposeVoicing([60, 64, 67], -1)).toEqual([48, 52, 55]);
    });

    it('handles multiple octaves', () => {
      expect(transposeVoicing([48, 52, 55], 2)).toEqual([72, 76, 79]);
    });

    it('returns same notes for 0 octaves', () => {
      expect(transposeVoicing([48, 52, 55], 0)).toEqual([48, 52, 55]);
    });
  });

  describe('isVoicingInRange', () => {
    it('returns true for valid MIDI range', () => {
      expect(isVoicingInRange([48, 52, 55])).toBe(true);
      expect(isVoicingInRange([0, 64, 127])).toBe(true);
    });

    it('returns false for notes below 0', () => {
      expect(isVoicingInRange([-1, 52, 55])).toBe(false);
    });

    it('returns false for notes above 127', () => {
      expect(isVoicingInRange([48, 52, 128])).toBe(false);
    });

    it('returns true for empty array', () => {
      expect(isVoicingInRange([])).toBe(true);
    });
  });

  describe('constrainToRange', () => {
    it('returns same voicing if already in range', () => {
      expect(constrainToRange([48, 52, 55])).toEqual([48, 52, 55]);
    });

    it('transposes up if below minimum', () => {
      // Default min is 36 (C2)
      const result = constrainToRange([24, 28, 31]); // C1 chord
      expect(result[0]).toBeGreaterThanOrEqual(36);
    });

    it('transposes down if above maximum', () => {
      // Default max is 84 (C6)
      const result = constrainToRange([96, 100, 103]); // C7 chord
      expect(result[result.length - 1]).toBeLessThanOrEqual(84);
    });

    it('respects custom range', () => {
      const result = constrainToRange([48, 52, 55], 60, 72);
      expect(result[0]).toBeGreaterThanOrEqual(60);
    });

    it('returns empty array for empty input', () => {
      expect(constrainToRange([])).toEqual([]);
    });
  });
});
