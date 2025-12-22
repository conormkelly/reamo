/**
 * Tests for transportSlice - BPM normalization for different time signatures
 *
 * REAPER's fullBeatPosition counts in denominator beats:
 * - 4/4: fullBeatPosition is in quarter notes
 * - 6/8: fullBeatPosition is in eighth notes
 * - 3/4: fullBeatPosition is in quarter notes
 *
 * We normalize BPM to quarter-note BPM for consistent display.
 */

import { describe, it, expect, beforeEach } from 'vitest'
import { useReaperStore } from '../index'
import type { BeatPosition } from '../../core/types'

describe('transportSlice - BPM Normalization', () => {
  beforeEach(() => {
    // Reset store to initial state
    useReaperStore.setState({
      bpm: null,
      timeSignatureNumerator: 4,
      timeSignatureDenominator: 4,
      fullBeatPosition: 0,
    })
  })

  describe('4/4 time signature', () => {
    it('calculates BPM correctly at 120 BPM', () => {
      const store = useReaperStore.getState()

      // At 120 BPM in 4/4, position 6 seconds = 12 quarter notes
      // fullBeatPosition / positionSeconds * 60 = 12/6*60 = 120
      const beatPos: BeatPosition = {
        playState: 1,
        positionSeconds: 6,
        fullBeatPosition: 12, // 12 quarter notes
        measureCount: 3,
        beatsInMeasure: 0,
        timeSignatureNumerator: 4,
        timeSignatureDenominator: 4,
      }

      store.updateBeatPosition(beatPos)

      expect(useReaperStore.getState().bpm).toBeCloseTo(120, 0)
      expect(useReaperStore.getState().timeSignatureNumerator).toBe(4)
      expect(useReaperStore.getState().timeSignatureDenominator).toBe(4)
    })

    it('calculates BPM correctly at 90 BPM', () => {
      const store = useReaperStore.getState()

      // At 90 BPM in 4/4, position 4 seconds = 6 quarter notes
      const beatPos: BeatPosition = {
        playState: 1,
        positionSeconds: 4,
        fullBeatPosition: 6,
        measureCount: 1,
        beatsInMeasure: 2,
        timeSignatureNumerator: 4,
        timeSignatureDenominator: 4,
      }

      store.updateBeatPosition(beatPos)

      expect(useReaperStore.getState().bpm).toBeCloseTo(90, 0)
    })
  })

  describe('6/8 time signature', () => {
    it('normalizes BPM to quarter-note BPM (90 quarter = 180 eighth)', () => {
      const store = useReaperStore.getState()

      // At 90 BPM (quarter) in 6/8:
      // - 180 eighth notes per minute
      // - At position 6 seconds: 18 eighth notes
      // - Raw BPM = 18/6*60 = 180 (eighth-note BPM)
      // - Normalized = 180 * (4/8) = 90 (quarter-note BPM)
      const beatPos: BeatPosition = {
        playState: 1,
        positionSeconds: 6,
        fullBeatPosition: 18, // 18 eighth notes
        measureCount: 3,
        beatsInMeasure: 0,
        timeSignatureNumerator: 6,
        timeSignatureDenominator: 8,
      }

      store.updateBeatPosition(beatPos)

      // Should be 90, not 180
      expect(useReaperStore.getState().bpm).toBeCloseTo(90, 0)
      expect(useReaperStore.getState().timeSignatureNumerator).toBe(6)
      expect(useReaperStore.getState().timeSignatureDenominator).toBe(8)
    })

    it('normalizes BPM correctly at 60 quarter-note BPM', () => {
      const store = useReaperStore.getState()

      // At 60 BPM (quarter) in 6/8:
      // - 120 eighth notes per minute
      // - At position 10 seconds: 20 eighth notes
      // - Raw BPM = 20/10*60 = 120 (eighth-note BPM)
      // - Normalized = 120 * (4/8) = 60 (quarter-note BPM)
      const beatPos: BeatPosition = {
        playState: 1,
        positionSeconds: 10,
        fullBeatPosition: 20,
        measureCount: 3,
        beatsInMeasure: 2,
        timeSignatureNumerator: 6,
        timeSignatureDenominator: 8,
      }

      store.updateBeatPosition(beatPos)

      expect(useReaperStore.getState().bpm).toBeCloseTo(60, 0)
    })

    it('matches REAPER example: 90 BPM at position 6s with 18 beats', () => {
      const store = useReaperStore.getState()

      // Real REAPER data from user's 6/8 project at 90 BPM
      // BEATPOS 1 6.000000000000 18.000000000000 2 4.00000000 6 8
      const beatPos: BeatPosition = {
        playState: 1,
        positionSeconds: 6.0,
        fullBeatPosition: 18.0,
        measureCount: 2,
        beatsInMeasure: 4.0,
        timeSignatureNumerator: 6,
        timeSignatureDenominator: 8,
      }

      store.updateBeatPosition(beatPos)

      // User reported seeing 180 BPM before fix, should be 90 now
      expect(useReaperStore.getState().bpm).toBeCloseTo(90, 0)
    })
  })

  describe('12/8 time signature', () => {
    it('normalizes BPM correctly', () => {
      const store = useReaperStore.getState()

      // At 60 BPM (quarter) in 12/8:
      // - 120 eighth notes per minute
      // - At position 6 seconds: 12 eighth notes
      // - Raw BPM = 12/6*60 = 120 (eighth-note BPM)
      // - Normalized = 120 * (4/8) = 60 (quarter-note BPM)
      const beatPos: BeatPosition = {
        playState: 1,
        positionSeconds: 6,
        fullBeatPosition: 12,
        measureCount: 1,
        beatsInMeasure: 0,
        timeSignatureNumerator: 12,
        timeSignatureDenominator: 8,
      }

      store.updateBeatPosition(beatPos)

      expect(useReaperStore.getState().bpm).toBeCloseTo(60, 0)
      expect(useReaperStore.getState().timeSignatureNumerator).toBe(12)
      expect(useReaperStore.getState().timeSignatureDenominator).toBe(8)
    })
  })

  describe('3/4 time signature', () => {
    it('calculates BPM correctly (no normalization needed)', () => {
      const store = useReaperStore.getState()

      // At 120 BPM in 3/4, position 4 seconds = 8 quarter notes
      const beatPos: BeatPosition = {
        playState: 1,
        positionSeconds: 4,
        fullBeatPosition: 8,
        measureCount: 2,
        beatsInMeasure: 2,
        timeSignatureNumerator: 3,
        timeSignatureDenominator: 4,
      }

      store.updateBeatPosition(beatPos)

      expect(useReaperStore.getState().bpm).toBeCloseTo(120, 0)
      expect(useReaperStore.getState().timeSignatureNumerator).toBe(3)
      expect(useReaperStore.getState().timeSignatureDenominator).toBe(4)
    })
  })

  describe('2/4 time signature', () => {
    it('calculates BPM correctly', () => {
      const store = useReaperStore.getState()

      // At 100 BPM in 2/4, position 6 seconds = 10 quarter notes
      const beatPos: BeatPosition = {
        playState: 1,
        positionSeconds: 6,
        fullBeatPosition: 10,
        measureCount: 5,
        beatsInMeasure: 0,
        timeSignatureNumerator: 2,
        timeSignatureDenominator: 4,
      }

      store.updateBeatPosition(beatPos)

      expect(useReaperStore.getState().bpm).toBeCloseTo(100, 0)
    })
  })

  describe('2/2 (cut time) time signature', () => {
    it('normalizes BPM for half-note denominator', () => {
      const store = useReaperStore.getState()

      // At 60 BPM (quarter) in 2/2:
      // - 30 half notes per minute
      // - At position 4 seconds: 2 half notes
      // - Raw BPM = 2/4*60 = 30 (half-note BPM)
      // - Normalized = 30 * (4/2) = 60 (quarter-note BPM)
      const beatPos: BeatPosition = {
        playState: 1,
        positionSeconds: 4,
        fullBeatPosition: 2, // 2 half notes
        measureCount: 1,
        beatsInMeasure: 0,
        timeSignatureNumerator: 2,
        timeSignatureDenominator: 2,
      }

      store.updateBeatPosition(beatPos)

      expect(useReaperStore.getState().bpm).toBeCloseTo(60, 0)
      expect(useReaperStore.getState().timeSignatureNumerator).toBe(2)
      expect(useReaperStore.getState().timeSignatureDenominator).toBe(2)
    })
  })

  describe('Edge cases', () => {
    it('does not update BPM when position is too small', () => {
      const store = useReaperStore.getState()

      // Position less than 0.1 seconds should not update BPM
      const beatPos: BeatPosition = {
        playState: 1,
        positionSeconds: 0.05,
        fullBeatPosition: 0.1,
        measureCount: 1,
        beatsInMeasure: 0.1,
        timeSignatureNumerator: 4,
        timeSignatureDenominator: 4,
      }

      store.updateBeatPosition(beatPos)

      expect(useReaperStore.getState().bpm).toBeNull()
    })

    it('rejects unreasonable BPM values (too low)', () => {
      const store = useReaperStore.getState()

      // This would calculate to 15 BPM which is below threshold
      const beatPos: BeatPosition = {
        playState: 1,
        positionSeconds: 60,
        fullBeatPosition: 15,
        measureCount: 3,
        beatsInMeasure: 3,
        timeSignatureNumerator: 4,
        timeSignatureDenominator: 4,
      }

      store.updateBeatPosition(beatPos)

      expect(useReaperStore.getState().bpm).toBeNull()
    })

    it('rejects unreasonable BPM values (too high)', () => {
      const store = useReaperStore.getState()

      // This would calculate to 400 BPM which is above threshold
      const beatPos: BeatPosition = {
        playState: 1,
        positionSeconds: 1,
        fullBeatPosition: 6.67,
        measureCount: 1,
        beatsInMeasure: 2,
        timeSignatureNumerator: 4,
        timeSignatureDenominator: 4,
      }

      store.updateBeatPosition(beatPos)

      expect(useReaperStore.getState().bpm).toBeNull()
    })

    it('updates time signature even when BPM cannot be calculated', () => {
      const store = useReaperStore.getState()

      // Position too small for BPM, but time signature should update
      const beatPos: BeatPosition = {
        playState: 1,
        positionSeconds: 0.01,
        fullBeatPosition: 0.01,
        measureCount: 1,
        beatsInMeasure: 0.01,
        timeSignatureNumerator: 6,
        timeSignatureDenominator: 8,
      }

      store.updateBeatPosition(beatPos)

      expect(useReaperStore.getState().timeSignatureNumerator).toBe(6)
      expect(useReaperStore.getState().timeSignatureDenominator).toBe(8)
    })
  })
})
