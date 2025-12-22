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
  parseBarBeatTicksToBeats,
  formatBeatsToBarBeatTicks,
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

// ============ BEATS-BASED UTILITIES (for modal forms) ============

describe('parseBarBeatTicksToBeats - parse bar.beat.ticks to total beats', () => {
  describe('4/4 time signature', () => {
    const beatsPerBar = 4

    it('parses 1.1 to 0 beats (bar 1, beat 1 = start)', () => {
      expect(parseBarBeatTicksToBeats('1.1', beatsPerBar)).toBe(0)
    })

    it('parses 1 to 0 beats (just bar number)', () => {
      expect(parseBarBeatTicksToBeats('1', beatsPerBar)).toBe(0)
    })

    it('parses 2.1 to 4 beats (bar 2 in 4/4)', () => {
      expect(parseBarBeatTicksToBeats('2.1', beatsPerBar)).toBe(4)
    })

    it('parses 1.2 to 1 beat', () => {
      expect(parseBarBeatTicksToBeats('1.2', beatsPerBar)).toBe(1)
    })

    it('parses 1.3 to 2 beats', () => {
      expect(parseBarBeatTicksToBeats('1.3', beatsPerBar)).toBe(2)
    })

    it('parses 1.4 to 3 beats', () => {
      expect(parseBarBeatTicksToBeats('1.4', beatsPerBar)).toBe(3)
    })

    it('parses 1.2.50 to 1.5 beats (beat 2, tick 50 = half beat)', () => {
      expect(parseBarBeatTicksToBeats('1.2.50', beatsPerBar)).toBe(1.5)
    })

    it('parses 1.1.25 to 0.25 beats', () => {
      expect(parseBarBeatTicksToBeats('1.1.25', beatsPerBar)).toBe(0.25)
    })

    it('parses 3.2.75 correctly', () => {
      // Bar 3, beat 2, tick 75 = (3-1)*4 + (2-1) + 0.75 = 8 + 1 + 0.75 = 9.75
      expect(parseBarBeatTicksToBeats('3.2.75', beatsPerBar)).toBe(9.75)
    })

    it('returns null for empty input', () => {
      expect(parseBarBeatTicksToBeats('', beatsPerBar)).toBeNull()
    })

    it('returns null for non-numeric input', () => {
      expect(parseBarBeatTicksToBeats('abc', beatsPerBar)).toBeNull()
    })

    it('clamps beat to valid range (beat > beatsPerBar)', () => {
      // Beat 5 in 4/4 should clamp to beat 4
      const result = parseBarBeatTicksToBeats('1.5', beatsPerBar)
      expect(result).toBe(3) // Clamped to beat 4 = 3 beats from start
    })

    it('clamps beat to valid range (beat < 1)', () => {
      // Beat 0 should clamp to beat 1
      const result = parseBarBeatTicksToBeats('1.0', beatsPerBar)
      expect(result).toBe(0) // Clamped to beat 1 = 0 beats from start
    })

    it('clamps ticks to 0-99 range', () => {
      // Tick 150 should clamp to 99
      expect(parseBarBeatTicksToBeats('1.1.150', beatsPerBar)).toBe(0.99)
      // Tick -10 should clamp to 0
      expect(parseBarBeatTicksToBeats('1.1.-10', beatsPerBar)).toBe(0)
    })
  })

  describe('6/8 time signature', () => {
    const beatsPerBar = 6

    it('parses 1.1 to 0 beats', () => {
      expect(parseBarBeatTicksToBeats('1.1', beatsPerBar)).toBe(0)
    })

    it('parses 2.1 to 6 beats (1 bar in 6/8)', () => {
      expect(parseBarBeatTicksToBeats('2.1', beatsPerBar)).toBe(6)
    })

    it('parses 1.4 to 3 beats (beat 4 in 6/8)', () => {
      expect(parseBarBeatTicksToBeats('1.4', beatsPerBar)).toBe(3)
    })

    it('parses 1.6 to 5 beats (last beat of bar)', () => {
      expect(parseBarBeatTicksToBeats('1.6', beatsPerBar)).toBe(5)
    })

    it('parses 2.4.50 correctly', () => {
      // Bar 2, beat 4, tick 50 = 6 + 3 + 0.5 = 9.5
      expect(parseBarBeatTicksToBeats('2.4.50', beatsPerBar)).toBe(9.5)
    })
  })

  describe('3/4 time signature', () => {
    const beatsPerBar = 3

    it('parses 2.1 to 3 beats (1 bar in 3/4)', () => {
      expect(parseBarBeatTicksToBeats('2.1', beatsPerBar)).toBe(3)
    })

    it('parses 5.3 correctly', () => {
      // Bar 5, beat 3 = (5-1)*3 + (3-1) = 12 + 2 = 14
      expect(parseBarBeatTicksToBeats('5.3', beatsPerBar)).toBe(14)
    })
  })
})

describe('formatBeatsToBarBeatTicks - format beats to bar.beat.ticks string', () => {
  describe('4/4 time signature', () => {
    const beatsPerBar = 4

    it('formats 0 beats as 1.1 (bar 1, beat 1)', () => {
      expect(formatBeatsToBarBeatTicks(0, beatsPerBar)).toBe('1.1')
    })

    it('formats 4 beats as 2.1 (bar 2 in 4/4)', () => {
      expect(formatBeatsToBarBeatTicks(4, beatsPerBar)).toBe('2.1')
    })

    it('formats 1 beat as 1.2', () => {
      expect(formatBeatsToBarBeatTicks(1, beatsPerBar)).toBe('1.2')
    })

    it('formats 2 beats as 1.3', () => {
      expect(formatBeatsToBarBeatTicks(2, beatsPerBar)).toBe('1.3')
    })

    it('formats 3 beats as 1.4', () => {
      expect(formatBeatsToBarBeatTicks(3, beatsPerBar)).toBe('1.4')
    })

    it('formats 4.5 beats as 2.1.50 (bar 2, beat 1, tick 50)', () => {
      // 4.5 beats = 1 full bar (4 beats) + 0.5 beats into bar 2
      // 0.5 beats into bar = beat 1, tick 50
      expect(formatBeatsToBarBeatTicks(4.5, beatsPerBar)).toBe('2.1.50')
    })

    it('formats 0.25 beats as 1.1.25', () => {
      expect(formatBeatsToBarBeatTicks(0.25, beatsPerBar)).toBe('1.1.25')
    })

    it('formats 9.75 beats as 3.2.75', () => {
      expect(formatBeatsToBarBeatTicks(9.75, beatsPerBar)).toBe('3.2.75')
    })

    it('handles includeBeat=false (omits beat when at beat 1)', () => {
      expect(formatBeatsToBarBeatTicks(0, beatsPerBar, false)).toBe('1')
      expect(formatBeatsToBarBeatTicks(4, beatsPerBar, false)).toBe('2')
    })

    it('with includeBeat=false, ticks still show beat, but whole beats only show bar', () => {
      // When there are ticks, include beat (can't omit it without losing tick context)
      expect(formatBeatsToBarBeatTicks(0.5, beatsPerBar, false)).toBe('1.1.50')
      // When at a whole beat, includeBeat=false means only show bar
      // Note: This loses beat information - e.g., beat 2 of bar 1 shows as just "1"
      expect(formatBeatsToBarBeatTicks(1, beatsPerBar, false)).toBe('1')
    })
  })

  describe('6/8 time signature', () => {
    const beatsPerBar = 6

    it('formats 0 beats as 1.1', () => {
      expect(formatBeatsToBarBeatTicks(0, beatsPerBar)).toBe('1.1')
    })

    it('formats 6 beats as 2.1 (1 bar in 6/8)', () => {
      expect(formatBeatsToBarBeatTicks(6, beatsPerBar)).toBe('2.1')
    })

    it('formats 3 beats as 1.4 (beat 4 of 6)', () => {
      expect(formatBeatsToBarBeatTicks(3, beatsPerBar)).toBe('1.4')
    })

    it('formats 9.5 beats as 2.4.50', () => {
      expect(formatBeatsToBarBeatTicks(9.5, beatsPerBar)).toBe('2.4.50')
    })
  })

  describe('3/4 time signature', () => {
    const beatsPerBar = 3

    it('formats 3 beats as 2.1', () => {
      expect(formatBeatsToBarBeatTicks(3, beatsPerBar)).toBe('2.1')
    })

    it('formats 14 beats as 5.3', () => {
      expect(formatBeatsToBarBeatTicks(14, beatsPerBar)).toBe('5.3')
    })
  })

  describe('edge cases', () => {
    it('handles very small negative values (floating point errors)', () => {
      // -0.0001 should be treated as 0
      expect(formatBeatsToBarBeatTicks(-0.0001, 4)).toBe('1.1')
    })

    it('rounds correctly near beat boundaries', () => {
      // 0.999 should round to 1.00 = beat 2
      expect(formatBeatsToBarBeatTicks(0.999, 4)).toBe('1.2')
      // 0.994 should round to 0.99
      expect(formatBeatsToBarBeatTicks(0.994, 4)).toBe('1.1.99')
    })

    it('pads ticks with leading zero', () => {
      expect(formatBeatsToBarBeatTicks(0.05, 4)).toBe('1.1.05')
    })
  })

  describe('round-trip consistency', () => {
    it('parse -> format returns equivalent string', () => {
      const testCases = ['1.1', '2.1', '1.2.50', '3.4.25', '10.3']
      for (const input of testCases) {
        const beats = parseBarBeatTicksToBeats(input, 4)
        expect(beats).not.toBeNull()
        const formatted = formatBeatsToBarBeatTicks(beats!, 4)
        // Re-parse to compare numerically (handles "1.1" vs "1.1.00")
        const reparsed = parseBarBeatTicksToBeats(formatted, 4)
        expect(reparsed).toBeCloseTo(beats!, 2)
      }
    })

    it('format -> parse returns original beats', () => {
      const testCases = [0, 1, 4, 4.5, 9.75, 100]
      for (const beats of testCases) {
        const formatted = formatBeatsToBarBeatTicks(beats, 4)
        const parsed = parseBarBeatTicksToBeats(formatted, 4)
        expect(parsed).toBeCloseTo(beats, 2)
      }
    })
  })

  describe('barOffset support', () => {
    const beatsPerBar = 4

    describe('formatBeatsToBarBeatTicks with barOffset', () => {
      it('formats 0 beats with offset 4 as 5.1 (project starts at bar 5)', () => {
        expect(formatBeatsToBarBeatTicks(0, beatsPerBar, true, 4)).toBe('5.1')
      })

      it('formats 4 beats with offset 4 as 6.1', () => {
        expect(formatBeatsToBarBeatTicks(4, beatsPerBar, true, 4)).toBe('6.1')
      })

      it('formats 0 beats with negative offset as negative bar', () => {
        // Project starts at bar -4, offset = -5
        expect(formatBeatsToBarBeatTicks(0, beatsPerBar, true, -5)).toBe('-4.1')
      })

      it('formats with offset 0 same as without offset (backward compatible)', () => {
        expect(formatBeatsToBarBeatTicks(8, beatsPerBar, true, 0)).toBe('3.1')
        expect(formatBeatsToBarBeatTicks(8, beatsPerBar)).toBe('3.1')
      })

      it('formats with ticks and offset correctly', () => {
        expect(formatBeatsToBarBeatTicks(0.5, beatsPerBar, true, 4)).toBe('5.1.50')
      })
    })

    describe('parseBarBeatTicksToBeats with barOffset', () => {
      it('parses 5.1 with offset 4 as 0 beats (bar 5 = start)', () => {
        expect(parseBarBeatTicksToBeats('5.1', beatsPerBar, 4)).toBe(0)
      })

      it('parses 6.1 with offset 4 as 4 beats', () => {
        expect(parseBarBeatTicksToBeats('6.1', beatsPerBar, 4)).toBe(4)
      })

      it('parses -4.1 with offset -5 as 0 beats', () => {
        expect(parseBarBeatTicksToBeats('-4.1', beatsPerBar, -5)).toBe(0)
      })

      it('parses with offset 0 same as without offset (backward compatible)', () => {
        expect(parseBarBeatTicksToBeats('3.1', beatsPerBar, 0)).toBe(8)
        expect(parseBarBeatTicksToBeats('3.1', beatsPerBar)).toBe(8)
      })

      it('parses with ticks and offset correctly', () => {
        expect(parseBarBeatTicksToBeats('5.1.50', beatsPerBar, 4)).toBe(0.5)
      })
    })

    describe('round-trip with barOffset', () => {
      it('format -> parse returns original beats with offset', () => {
        const offset = 4
        const testCases = [0, 1, 4, 4.5, 9.75]
        for (const beats of testCases) {
          const formatted = formatBeatsToBarBeatTicks(beats, beatsPerBar, true, offset)
          const parsed = parseBarBeatTicksToBeats(formatted, beatsPerBar, offset)
          expect(parsed).toBeCloseTo(beats, 2)
        }
      })

      it('works with negative offset', () => {
        const offset = -5
        const testCases = [0, 4, 8.5]
        for (const beats of testCases) {
          const formatted = formatBeatsToBarBeatTicks(beats, beatsPerBar, true, offset)
          const parsed = parseBarBeatTicksToBeats(formatted, beatsPerBar, offset)
          expect(parsed).toBeCloseTo(beats, 2)
        }
      })

      it('works with 6/8 time and offset', () => {
        const beatsPerBar6 = 6
        const offset = 3
        const beats = 12 // 2 bars in 6/8
        const formatted = formatBeatsToBarBeatTicks(beats, beatsPerBar6, true, offset)
        expect(formatted).toBe('6.1') // bar 3 + offset 3 = bar 6
        const parsed = parseBarBeatTicksToBeats(formatted, beatsPerBar6, offset)
        expect(parsed).toBe(12)
      })
    })
  })
})
