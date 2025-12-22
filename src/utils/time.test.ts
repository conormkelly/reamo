/**
 * Tests for time.ts - Time/Beat Conversion and Formatting Utilities
 *
 * Tests various time signatures including:
 * - 4/4 (common time)
 * - 3/4 (waltz time)
 * - 6/8 (compound duple)
 * - 12/8 (compound quadruple)
 * - 2/4 (cut time)
 * - 5/4 (irregular)
 */

import { describe, it, expect } from 'vitest'
import {
  secondsToBeats,
  beatsToSeconds,
  formatBeats,
  formatDuration,
  formatDelta,
  parseBarBeatToSeconds,
  parseDurationToSeconds,
  snapToGrid,
} from './time'

describe('Core Conversions', () => {
  describe('secondsToBeats', () => {
    it('converts seconds to quarter-note beats at 120 BPM', () => {
      expect(secondsToBeats(1, 120)).toBe(2) // 1 second = 2 beats at 120 BPM
      expect(secondsToBeats(2, 120)).toBe(4)
      expect(secondsToBeats(0.5, 120)).toBe(1)
    })

    it('converts seconds to quarter-note beats at 90 BPM', () => {
      expect(secondsToBeats(1, 90)).toBe(1.5) // 1 second = 1.5 beats at 90 BPM
      expect(secondsToBeats(2, 90)).toBe(3)
    })

    it('converts seconds to quarter-note beats at 60 BPM', () => {
      expect(secondsToBeats(1, 60)).toBe(1) // 1 second = 1 beat at 60 BPM
      expect(secondsToBeats(4, 60)).toBe(4)
    })
  })

  describe('beatsToSeconds', () => {
    it('converts beats to seconds at 120 BPM', () => {
      expect(beatsToSeconds(2, 120)).toBe(1)
      expect(beatsToSeconds(4, 120)).toBe(2)
    })

    it('converts beats to seconds at 90 BPM', () => {
      expect(beatsToSeconds(1.5, 90)).toBe(1)
      expect(beatsToSeconds(3, 90)).toBe(2)
    })

    it('is inverse of secondsToBeats', () => {
      const bpm = 120
      const seconds = 2.5
      expect(beatsToSeconds(secondsToBeats(seconds, bpm), bpm)).toBeCloseTo(seconds)
    })
  })
})

describe('formatBeats - Bar.Beat.Sub formatting', () => {
  // All tests use quarter-note BPM (normalized)

  describe('4/4 time signature', () => {
    const beatsPerBar = 4
    const denominator = 4
    const barOffset = 0

    it('formats position 0 as 1.1.00', () => {
      expect(formatBeats(0, 120, barOffset, beatsPerBar, denominator)).toBe('1.1.00')
    })

    it('formats one bar (2 seconds at 120 BPM) as 2.1.00', () => {
      // At 120 BPM, 4 beats = 2 seconds = 1 bar
      expect(formatBeats(2, 120, barOffset, beatsPerBar, denominator)).toBe('2.1.00')
    })

    it('formats half bar as 1.3.00', () => {
      // 2 beats at 120 BPM = 1 second = beat 3 of bar 1
      expect(formatBeats(1, 120, barOffset, beatsPerBar, denominator)).toBe('1.3.00')
    })

    it('formats with positive bar offset', () => {
      // If project starts at bar 5, offset = 4
      expect(formatBeats(0, 120, 4, beatsPerBar, denominator)).toBe('5.1.00')
    })

    it('formats with negative bar offset', () => {
      // If project starts at bar -4, offset = -5
      expect(formatBeats(0, 120, -5, beatsPerBar, denominator)).toBe('-4.1.00')
    })
  })

  describe('3/4 time signature (waltz)', () => {
    const beatsPerBar = 3
    const denominator = 4
    const barOffset = 0
    const bpm = 120 // quarter-note BPM

    it('formats position 0 as 1.1.00', () => {
      expect(formatBeats(0, bpm, barOffset, beatsPerBar, denominator)).toBe('1.1.00')
    })

    it('formats one bar (3 beats = 1.5 seconds at 120 BPM) as 2.1.00', () => {
      // At 120 BPM (quarter), 3 beats = 1.5 seconds = 1 bar in 3/4
      expect(formatBeats(1.5, bpm, barOffset, beatsPerBar, denominator)).toBe('2.1.00')
    })

    it('formats 4 bars correctly', () => {
      // 4 bars in 3/4 = 12 beats = 6 seconds at 120 BPM
      expect(formatBeats(6, bpm, barOffset, beatsPerBar, denominator)).toBe('5.1.00')
    })
  })

  describe('6/8 time signature (compound duple)', () => {
    const beatsPerBar = 6 // 6 eighth notes per bar
    const denominator = 8
    const barOffset = 0
    const bpm = 90 // quarter-note BPM (90 quarter = 180 eighth per minute)

    it('formats position 0 as 1.1.00', () => {
      expect(formatBeats(0, bpm, barOffset, beatsPerBar, denominator)).toBe('1.1.00')
    })

    it('formats one bar correctly', () => {
      // In 6/8 at 90 BPM (quarter):
      // - 1 quarter note = 60/90 = 0.667 seconds
      // - 1 eighth note = 0.333 seconds
      // - 1 bar = 6 eighths = 2 seconds
      expect(formatBeats(2, bpm, barOffset, beatsPerBar, denominator)).toBe('2.1.00')
    })

    it('formats half bar (3 eighth notes) as 1.4.00', () => {
      // 3 eighths = 1 second at 90 BPM quarter-note
      expect(formatBeats(1, bpm, barOffset, beatsPerBar, denominator)).toBe('1.4.00')
    })

    it('formats bar 2 beat 5 correctly', () => {
      // Bar 2, beat 5 = 1 bar + 4 beats = 6 + 4 = 10 eighths
      // 10 eighths = 10 * 0.333 = 3.33 seconds
      const seconds = (10 / 180) * 60 // 10 eighths at 180 eighths/minute
      expect(formatBeats(seconds, bpm, barOffset, beatsPerBar, denominator)).toBe('2.5.00')
    })

    it('formats 10 bars 4 beats correctly (matches REAPER example)', () => {
      // Region length: 10 bars 4 beats in 6/8
      // = 10*6 + 4 = 64 eighth notes
      // At 90 BPM quarter (180 eighth/min): 64 eighths * (60/180) = 21.33 seconds
      const seconds = (64 / 180) * 60
      // formatDuration shows "10 bars 4 beats"
      expect(formatDuration(seconds, bpm, beatsPerBar, denominator)).toBe('10 bars 4 beats')
    })
  })

  describe('12/8 time signature (compound quadruple)', () => {
    const beatsPerBar = 12 // 12 eighth notes per bar
    const denominator = 8
    const barOffset = 0
    const bpm = 60 // quarter-note BPM

    it('formats one bar correctly', () => {
      // In 12/8 at 60 BPM quarter (120 eighth/min):
      // 1 bar = 12 eighths = 12 * (60/120) = 6 seconds
      expect(formatBeats(6, bpm, barOffset, beatsPerBar, denominator)).toBe('2.1.00')
    })
  })

  describe('2/4 time signature', () => {
    const beatsPerBar = 2
    const denominator = 4
    const barOffset = 0
    const bpm = 120

    it('formats one bar (2 beats = 1 second) correctly', () => {
      expect(formatBeats(1, bpm, barOffset, beatsPerBar, denominator)).toBe('2.1.00')
    })
  })

  describe('5/4 time signature (irregular)', () => {
    const beatsPerBar = 5
    const denominator = 4
    const barOffset = 0
    const bpm = 120

    it('formats one bar (5 beats = 2.5 seconds) correctly', () => {
      expect(formatBeats(2.5, bpm, barOffset, beatsPerBar, denominator)).toBe('2.1.00')
    })
  })
})

describe('formatDuration - human-readable bars/beats', () => {
  describe('4/4 time signature', () => {
    const beatsPerBar = 4
    const denominator = 4
    const bpm = 120

    it('formats 1 bar correctly', () => {
      // 1 bar = 4 beats = 2 seconds at 120 BPM
      expect(formatDuration(2, bpm, beatsPerBar, denominator)).toBe('1 bar')
    })

    it('formats 8 bars correctly', () => {
      // 8 bars = 32 beats = 16 seconds at 120 BPM
      expect(formatDuration(16, bpm, beatsPerBar, denominator)).toBe('8 bars')
    })

    it('formats bars and beats correctly', () => {
      // 2 bars 2 beats = 10 beats = 5 seconds
      expect(formatDuration(5, bpm, beatsPerBar, denominator)).toBe('2 bars 2 beats')
    })

    it('formats beats only correctly', () => {
      // 2 beats = 1 second at 120 BPM
      expect(formatDuration(1, bpm, beatsPerBar, denominator)).toBe('2 beats')
    })
  })

  describe('6/8 time signature', () => {
    const beatsPerBar = 6
    const denominator = 8
    const bpm = 90 // quarter-note BPM

    it('formats 1 bar (6 eighths = 2 seconds) correctly', () => {
      expect(formatDuration(2, bpm, beatsPerBar, denominator)).toBe('1 bar')
    })

    it('formats 10 bars 4 beats correctly', () => {
      // 10 bars 4 beats = 64 eighths
      // At 180 eighths/min: 64 * (60/180) = 21.33 seconds
      const seconds = (64 / 180) * 60
      expect(formatDuration(seconds, bpm, beatsPerBar, denominator)).toBe('10 bars 4 beats')
    })

    it('formats 3 beats correctly', () => {
      // 3 eighth notes at 180 eighths/min = 1 second
      expect(formatDuration(1, bpm, beatsPerBar, denominator)).toBe('3 beats')
    })
  })

  describe('3/4 time signature', () => {
    const beatsPerBar = 3
    const denominator = 4
    const bpm = 120

    it('formats 1 bar (3 beats = 1.5 seconds) correctly', () => {
      expect(formatDuration(1.5, bpm, beatsPerBar, denominator)).toBe('1 bar')
    })

    it('formats 4 bars 2 beats correctly', () => {
      // 4 bars 2 beats = 14 beats = 7 seconds at 120 BPM
      expect(formatDuration(7, bpm, beatsPerBar, denominator)).toBe('4 bars 2 beats')
    })
  })
})

describe('formatDelta - signed bar/beat changes', () => {
  describe('4/4 time signature', () => {
    const beatsPerBar = 4
    const denominator = 4
    const bpm = 120

    it('formats positive delta correctly', () => {
      // +1 bar = 2 seconds
      expect(formatDelta(2, bpm, beatsPerBar, denominator)).toBe('+1 bar')
    })

    it('formats negative delta correctly', () => {
      // -2 bars = -4 seconds
      expect(formatDelta(-4, bpm, beatsPerBar, denominator)).toBe('-2 bars')
    })

    it('formats zero delta correctly', () => {
      expect(formatDelta(0, bpm, beatsPerBar, denominator)).toBe('0')
    })
  })

  describe('6/8 time signature', () => {
    const beatsPerBar = 6
    const denominator = 8
    const bpm = 90

    it('formats positive bar delta correctly', () => {
      // +1 bar = 6 eighths = 2 seconds
      expect(formatDelta(2, bpm, beatsPerBar, denominator)).toBe('+1 bar')
    })

    it('formats beat delta correctly', () => {
      // +3 beats = 3 eighths = 1 second
      expect(formatDelta(1, bpm, beatsPerBar, denominator)).toBe('+3 beats')
    })
  })
})

describe('parseBarBeatToSeconds', () => {
  describe('4/4 time signature', () => {
    const beatsPerBar = 4
    const denominator = 4
    const bpm = 120
    const barOffset = 0

    it('parses 1.1.00 to 0 seconds', () => {
      expect(parseBarBeatToSeconds('1.1.00', bpm, barOffset, beatsPerBar, denominator)).toBe(0)
    })

    it('parses 2.1.00 to 2 seconds (1 bar)', () => {
      expect(parseBarBeatToSeconds('2.1.00', bpm, barOffset, beatsPerBar, denominator)).toBe(2)
    })

    it('parses 1.3.00 to 1 second (2 beats)', () => {
      expect(parseBarBeatToSeconds('1.3.00', bpm, barOffset, beatsPerBar, denominator)).toBe(1)
    })

    it('handles bar offset correctly', () => {
      // Bar 5 with offset 4 = bar 1 in absolute terms
      expect(parseBarBeatToSeconds('5.1.00', bpm, 4, beatsPerBar, denominator)).toBe(0)
    })

    it('returns null for invalid input', () => {
      expect(parseBarBeatToSeconds('invalid', bpm, barOffset, beatsPerBar, denominator)).toBeNull()
      expect(parseBarBeatToSeconds('1', bpm, barOffset, beatsPerBar, denominator)).toBeNull()
      expect(parseBarBeatToSeconds('1.5.00', bpm, barOffset, beatsPerBar, denominator)).toBeNull() // beat > beatsPerBar
    })

    it('is inverse of formatBeats', () => {
      const seconds = 5.5
      const formatted = formatBeats(seconds, bpm, barOffset, beatsPerBar, denominator)
      const parsed = parseBarBeatToSeconds(formatted, bpm, barOffset, beatsPerBar, denominator)
      // Should be close (within 16th note precision)
      expect(parsed).not.toBeNull()
      expect(Math.abs(parsed! - seconds)).toBeLessThan(0.15)
    })
  })

  describe('6/8 time signature', () => {
    const beatsPerBar = 6
    const denominator = 8
    const bpm = 90
    const barOffset = 0

    it('parses 2.1.00 to 2 seconds (1 bar)', () => {
      expect(parseBarBeatToSeconds('2.1.00', bpm, barOffset, beatsPerBar, denominator)).toBeCloseTo(2, 1)
    })

    it('parses 2.5.00 correctly', () => {
      // Bar 2, beat 5 = 10 eighths = 10 * (60/180) = 3.33 seconds
      const expected = (10 / 180) * 60
      expect(parseBarBeatToSeconds('2.5.00', bpm, barOffset, beatsPerBar, denominator)).toBeCloseTo(expected, 1)
    })

    it('returns null for beat > 6', () => {
      expect(parseBarBeatToSeconds('1.7.00', bpm, barOffset, beatsPerBar, denominator)).toBeNull()
    })
  })
})

describe('parseDurationToSeconds', () => {
  describe('4/4 time signature', () => {
    const beatsPerBar = 4
    const denominator = 4
    const bpm = 120

    it('parses "8" as 8 bars = 16 seconds', () => {
      expect(parseDurationToSeconds('8', bpm, beatsPerBar, denominator)).toBe(16)
    })

    it('parses "1" as 1 bar = 2 seconds', () => {
      expect(parseDurationToSeconds('1', bpm, beatsPerBar, denominator)).toBe(2)
    })

    it('parses "2.2" as 2 bars 2 beats = 5 seconds', () => {
      expect(parseDurationToSeconds('2.2', bpm, beatsPerBar, denominator)).toBe(5)
    })

    it('parses "0.2" as 2 beats = 1 second', () => {
      expect(parseDurationToSeconds('0.2', bpm, beatsPerBar, denominator)).toBe(1)
    })
  })

  describe('6/8 time signature', () => {
    const beatsPerBar = 6
    const denominator = 8
    const bpm = 90

    it('parses "1" as 1 bar = 2 seconds', () => {
      expect(parseDurationToSeconds('1', bpm, beatsPerBar, denominator)).toBeCloseTo(2, 1)
    })

    it('parses "10.4" as 10 bars 4 beats', () => {
      // 64 eighths * (60/180) = 21.33 seconds
      const expected = (64 / 180) * 60
      expect(parseDurationToSeconds('10.4', bpm, beatsPerBar, denominator)).toBeCloseTo(expected, 1)
    })

    it('returns null for beats > 6', () => {
      expect(parseDurationToSeconds('1.7', bpm, beatsPerBar, denominator)).toBeNull()
    })
  })

  describe('3/4 time signature', () => {
    const beatsPerBar = 3
    const denominator = 4
    const bpm = 120

    it('parses "1" as 1 bar = 1.5 seconds', () => {
      expect(parseDurationToSeconds('1', bpm, beatsPerBar, denominator)).toBe(1.5)
    })

    it('parses "4.2" as 4 bars 2 beats = 7 seconds', () => {
      expect(parseDurationToSeconds('4.2', bpm, beatsPerBar, denominator)).toBe(7)
    })
  })
})

describe('snapToGrid', () => {
  it('snaps to quarter notes (subdivisions = 1)', () => {
    const bpm = 120
    expect(snapToGrid(0.45, bpm, 1)).toBeCloseTo(0.5, 2) // Snap to beat 1
    expect(snapToGrid(0.6, bpm, 1)).toBeCloseTo(0.5, 2)
  })

  it('snaps to 16th notes (subdivisions = 4)', () => {
    const bpm = 120
    // At 120 BPM, 1 16th = 0.125 seconds
    expect(snapToGrid(0.1, bpm, 4)).toBeCloseTo(0.125, 2)
    expect(snapToGrid(0.2, bpm, 4)).toBeCloseTo(0.25, 2)
  })

  it('snaps to 8th notes (subdivisions = 2)', () => {
    const bpm = 120
    // At 120 BPM, 1 8th = 0.25 seconds
    expect(snapToGrid(0.2, bpm, 2)).toBeCloseTo(0.25, 2)
    expect(snapToGrid(0.35, bpm, 2)).toBeCloseTo(0.25, 2)
  })
})

describe('Edge cases and precision', () => {
  it('handles very long durations', () => {
    // 5 minutes = 300 seconds at 120 BPM = 600 beats = 150 bars in 4/4
    expect(formatDuration(300, 120, 4, 4)).toBe('150 bars')
  })

  it('handles fractional beats with rounding', () => {
    // REAPER often sends high-precision floats like 13.333333333333314
    // Our functions should round to nearest 16th note
    const bpm = 120
    const weirdValue = 13.333333333333314
    const result = formatBeats(weirdValue, bpm, 0, 4, 4)
    // Should match clean format X.Y.ZZ without floating point decimals
    expect(result).toMatch(/^-?\d+\.\d+\.\d{2}$/)
    // The bar and beat numbers should be integers (no decimal points in the numbers)
    const [bar, beat, sub] = result.split('.')
    expect(parseInt(bar)).not.toBeNaN()
    expect(parseInt(beat)).not.toBeNaN()
    expect(parseInt(sub)).not.toBeNaN()
  })

  it('handles ticks correctly', () => {
    // Test various tick positions (0-99 like REAPER)
    const bpm = 120
    // At 120 BPM: 1 beat = 0.5 seconds
    // 0.125 seconds = 0.25 beats = 25 ticks
    expect(formatBeats(0.125, bpm, 0, 4, 4)).toBe('1.1.25')
    // 0.25 seconds = 0.5 beats = 50 ticks
    expect(formatBeats(0.25, bpm, 0, 4, 4)).toBe('1.1.50')
    // 0.375 seconds = 0.75 beats = 75 ticks
    expect(formatBeats(0.375, bpm, 0, 4, 4)).toBe('1.1.75')
  })
})
