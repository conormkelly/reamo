/**
 * Tests for ripple edit operations
 */

import { describe, it, expect } from 'vitest';
import { getMinRegionLength } from './rippleOperations';

describe('getMinRegionLength', () => {
  describe('returns default when no BPM', () => {
    it('returns 2 seconds when BPM is null', () => {
      expect(getMinRegionLength(null, 4, 4)).toBe(2);
    });

    it('returns 2 seconds when BPM is 0', () => {
      expect(getMinRegionLength(0, 4, 4)).toBe(2);
    });

    it('returns 2 seconds when BPM is negative', () => {
      expect(getMinRegionLength(-120, 4, 4)).toBe(2);
    });
  });

  describe('4/4 time signature', () => {
    it('calculates correct min length at 120 BPM', () => {
      // 4/4 at 120 BPM: 1 bar = 4 quarter notes = 2 seconds
      expect(getMinRegionLength(120, 4, 4)).toBe(2);
    });

    it('calculates correct min length at 60 BPM', () => {
      // 4/4 at 60 BPM: 1 bar = 4 quarter notes = 4 seconds
      expect(getMinRegionLength(60, 4, 4)).toBe(4);
    });

    it('calculates correct min length at 90 BPM', () => {
      // 4/4 at 90 BPM: 1 bar = 4 quarter notes = 2.667 seconds
      expect(getMinRegionLength(90, 4, 4)).toBeCloseTo(2.667, 2);
    });
  });

  describe('6/8 time signature', () => {
    it('calculates correct min length at 90 BPM', () => {
      // 6/8 at 90 BPM (quarter note):
      // 1 bar = 6 eighth notes = 3 quarter notes
      // At 90 quarter notes/min = 1.5 quarter notes/sec
      // 3 quarter notes / 1.5 = 2 seconds
      expect(getMinRegionLength(90, 6, 8)).toBe(2);
    });

    it('calculates correct min length at 120 BPM', () => {
      // 6/8 at 120 BPM (quarter note):
      // 1 bar = 6 eighth notes = 3 quarter notes
      // At 120 quarter notes/min = 2 quarter notes/sec
      // 3 quarter notes / 2 = 1.5 seconds
      expect(getMinRegionLength(120, 6, 8)).toBe(1.5);
    });
  });

  describe('3/4 time signature', () => {
    it('calculates correct min length at 120 BPM', () => {
      // 3/4 at 120 BPM: 1 bar = 3 quarter notes = 1.5 seconds
      expect(getMinRegionLength(120, 3, 4)).toBe(1.5);
    });

    it('calculates correct min length at 180 BPM', () => {
      // 3/4 at 180 BPM: 1 bar = 3 quarter notes = 1 second
      expect(getMinRegionLength(180, 3, 4)).toBe(1);
    });
  });

  describe('2/2 (cut time) time signature', () => {
    it('calculates correct min length at 60 BPM', () => {
      // 2/2 at 60 BPM (quarter note):
      // 1 bar = 2 half notes = 4 quarter notes
      // At 60 quarter notes/min = 1 quarter note/sec
      // 4 quarter notes = 4 seconds
      expect(getMinRegionLength(60, 2, 2)).toBe(4);
    });

    it('calculates correct min length at 120 BPM', () => {
      // 2/2 at 120 BPM: 1 bar = 4 quarter notes = 2 seconds
      expect(getMinRegionLength(120, 2, 2)).toBe(2);
    });
  });

  describe('12/8 time signature', () => {
    it('calculates correct min length at 60 BPM', () => {
      // 12/8 at 60 BPM (quarter note):
      // 1 bar = 12 eighth notes = 6 quarter notes
      // At 60 quarter notes/min = 1 quarter note/sec
      // 6 quarter notes = 6 seconds
      expect(getMinRegionLength(60, 12, 8)).toBe(6);
    });
  });
});
