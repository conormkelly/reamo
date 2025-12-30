/**
 * Tests for ripple edit operations
 */

import { describe, it, expect } from 'vitest';
import { getMinRegionLength, snapToBeats } from './rippleOperations';

describe('snapToBeats', () => {
  describe('4/4 time signature (quarter note = beat)', () => {
    const denominator = 4;
    const bpm = 120;

    it('snaps to quarter note grid', () => {
      // At 120 BPM, quarter notes are at 0, 0.5, 1.0, 1.5, 2.0...
      expect(snapToBeats(0.45, bpm, denominator)).toBeCloseTo(0.5, 2);
      expect(snapToBeats(0.6, bpm, denominator)).toBeCloseTo(0.5, 2);
      expect(snapToBeats(0.8, bpm, denominator)).toBeCloseTo(1.0, 2);
    });

    it('handles exact beat positions', () => {
      expect(snapToBeats(0.5, bpm, denominator)).toBeCloseTo(0.5, 2);
      expect(snapToBeats(1.0, bpm, denominator)).toBeCloseTo(1.0, 2);
    });
  });

  describe('6/8 time signature (eighth note = beat)', () => {
    const denominator = 8;
    const bpm = 90; // quarter-note BPM

    it('snaps to eighth note grid (not quarter notes)', () => {
      // At 90 BPM (quarter), eighth notes are at:
      // 0, 0.333, 0.667, 1.0, 1.333, 1.667, 2.0...
      // (180 eighths per minute = 0.333s per eighth)
      const eighthNoteDuration = 60 / (bpm * 2); // 0.333s

      // 0.3s should snap to 0.333s (first eighth), not 0.0s (quarter)
      expect(snapToBeats(0.3, bpm, denominator)).toBeCloseTo(eighthNoteDuration, 2);

      // 0.5s should snap to 0.333s or 0.667s - it's exactly between so either is valid
      const snapped = snapToBeats(0.5, bpm, denominator);
      expect([0.333, 0.667].some(v => Math.abs(snapped - v) < 0.01)).toBe(true);
    });

    it('snaps differently than 4/4 at same position', () => {
      // This is the key behavioral change: same time snaps to different grid
      // In 4/4 at 90 BPM: quarter notes at 0, 0.667, 1.333...
      // In 6/8 at 90 BPM: eighth notes at 0, 0.333, 0.667, 1.0...

      // 0.4s in 4/4 snaps to 0.667 (nearest quarter)
      const snap4_4 = snapToBeats(0.4, bpm, 4);
      // 0.4s in 6/8 snaps to 0.333 (nearest eighth)
      const snap6_8 = snapToBeats(0.4, bpm, 8);

      expect(snap4_4).toBeCloseTo(0.667, 2);
      expect(snap6_8).toBeCloseTo(0.333, 2);
    });
  });

  describe('2/2 time signature (half note = beat)', () => {
    const denominator = 2;
    const bpm = 120; // quarter-note BPM

    it('snaps to half note grid (every 2 quarters)', () => {
      // At 120 BPM, half notes are at 0, 1.0, 2.0, 3.0...
      expect(snapToBeats(0.4, bpm, denominator)).toBeCloseTo(0, 2);
      expect(snapToBeats(0.6, bpm, denominator)).toBeCloseTo(1.0, 2);
      expect(snapToBeats(1.3, bpm, denominator)).toBeCloseTo(1.0, 2);
    });
  });

  describe('default denominator', () => {
    it('defaults to quarter notes when denominator not specified', () => {
      const bpm = 120;
      // Should behave like denominator=4
      expect(snapToBeats(0.45, bpm)).toBeCloseTo(0.5, 2);
    });
  });
});

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
