/**
 * Tests for tempo map utilities
 *
 * These functions handle tempo-map-aware bar/beat conversion for projects
 * with tempo changes. Unlike time.ts (single BPM), these integrate through
 * the tempo map for accurate position calculation.
 */

import { describe, it, expect } from 'vitest';
import { timeToBarBeat, barBeatToTime, parseBarBeat, formatBarBeat } from './tempoUtils';
import type { WSTempoMarker } from './WebSocketTypes';

describe('timeToBarBeat', () => {
  describe('with no tempo markers (fallback)', () => {
    it('uses 120 BPM 4/4 default', () => {
      // At 120 BPM, 4/4: 1 bar = 2 seconds
      const result = timeToBarBeat(0, []);
      expect(result).toEqual({ bar: 1, beat: 1, ticks: 0 });
    });

    it('calculates bar 2 correctly', () => {
      // 2 seconds = 1 bar at 120 BPM
      const result = timeToBarBeat(2, []);
      expect(result).toEqual({ bar: 2, beat: 1, ticks: 0 });
    });

    it('calculates mid-bar position correctly', () => {
      // 1 second = beat 3 of bar 1 at 120 BPM (2 beats into bar)
      const result = timeToBarBeat(1, []);
      expect(result.bar).toBe(1);
      expect(result.beat).toBe(3);
    });
  });

  describe('with single tempo marker', () => {
    const markers: WSTempoMarker[] = [
      { position: 0, bpm: 90, timesigNum: 6, timesigDenom: 8, linear: false }
    ];

    it('handles 6/8 time signature correctly', () => {
      // At 90 BPM (quarter), 6/8: 1 bar = 6 eighths = 3 quarters = 2 seconds
      const result = timeToBarBeat(0, markers);
      expect(result).toEqual({ bar: 1, beat: 1, ticks: 0 });

      const bar2 = timeToBarBeat(2, markers);
      expect(bar2.bar).toBe(2);
      expect(bar2.beat).toBe(1);
    });

    it('calculates beat within bar correctly in 6/8', () => {
      // At 90 BPM: 1 eighth = 0.333s, beat 4 = 1 second
      const result = timeToBarBeat(1, markers);
      expect(result.bar).toBe(1);
      expect(result.beat).toBe(4);
    });
  });

  describe('with tempo change mid-project', () => {
    // Real-world example: 6/8@90 for first 50s, then 4/4@95
    const markers: WSTempoMarker[] = [
      { position: 0, bpm: 90, timesigNum: 6, timesigDenom: 8, linear: false },
      { position: 50, bpm: 95, timesigNum: 4, timesigDenom: 4, linear: false }
    ];

    it('calculates position in first tempo segment', () => {
      const result = timeToBarBeat(2, markers);
      // In 6/8@90: 2 seconds = 1 bar
      expect(result.bar).toBe(2);
    });

    it('calculates position after tempo change', () => {
      // At 50s: we've completed 25 bars of 6/8@90 (50/2 = 25 bars)
      // At 52s: 2 seconds into 4/4@95 = ~1.27 bars (4 beats * 95/60 = 6.33 beats/s, 2s = 12.67 beats = 3.17 bars)
      // Actually: at 95 BPM, 1 bar = 4 * (60/95) = 2.526s
      // 2 seconds into 4/4@95 ≈ 0.79 bars into bar 26
      const result = timeToBarBeat(52, markers);
      // Should be bar 26 (25 bars from first segment + partial bar)
      expect(result.bar).toBe(26);
    });
  });

  describe('with bar offset', () => {
    it('applies positive bar offset', () => {
      const result = timeToBarBeat(0, [], 4);
      expect(result.bar).toBe(5); // bar 1 + offset 4 = bar 5
    });

    it('applies negative bar offset', () => {
      const result = timeToBarBeat(0, [], -5);
      expect(result.bar).toBe(-4); // bar 1 + offset -5 = bar -4
    });
  });
});

describe('barBeatToTime', () => {
  describe('with no tempo markers (fallback)', () => {
    it('converts bar 1 beat 1 to 0 seconds', () => {
      const result = barBeatToTime({ bar: 1, beat: 1, ticks: 0 }, []);
      expect(result).toBe(0);
    });

    it('converts bar 2 to 2 seconds', () => {
      // At 120 BPM 4/4: 1 bar = 2 seconds
      const result = barBeatToTime({ bar: 2, beat: 1, ticks: 0 }, []);
      expect(result).toBe(2);
    });
  });

  describe('with single tempo marker', () => {
    const markers: WSTempoMarker[] = [
      { position: 0, bpm: 90, timesigNum: 6, timesigDenom: 8, linear: false }
    ];

    it('converts bar 2 correctly in 6/8', () => {
      // At 90 BPM 6/8: 1 bar = 2 seconds
      const result = barBeatToTime({ bar: 2, beat: 1, ticks: 0 }, markers);
      expect(result).toBeCloseTo(2, 1);
    });
  });

  describe('round-trip consistency', () => {
    const markers: WSTempoMarker[] = [
      { position: 0, bpm: 90, timesigNum: 6, timesigDenom: 8, linear: false }
    ];

    it('timeToBarBeat -> barBeatToTime returns original time', () => {
      const times = [0, 1, 2, 5, 10, 21.33];
      for (const time of times) {
        const barBeat = timeToBarBeat(time, markers);
        const recovered = barBeatToTime(barBeat, markers);
        expect(recovered).toBeCloseTo(time, 1);
      }
    });
  });
});

describe('parseBarBeat', () => {
  it('parses bar.beat format', () => {
    const result = parseBarBeat('8.1');
    expect(result).toEqual({ bar: 8, beat: 1, ticks: 0 });
  });

  it('parses bar.beat.ticks format', () => {
    const result = parseBarBeat('8.1.50');
    expect(result).toEqual({ bar: 8, beat: 1, ticks: 50 });
  });

  it('returns null for invalid input', () => {
    expect(parseBarBeat('invalid')).toBeNull();
    expect(parseBarBeat('8')).toBeNull(); // needs at least bar.beat
    expect(parseBarBeat('8.1.50.00')).toBeNull(); // too many parts
  });

  it('handles negative bar numbers', () => {
    const result = parseBarBeat('-4.1.00');
    expect(result).toEqual({ bar: -4, beat: 1, ticks: 0 });
  });
});

describe('formatBarBeat', () => {
  it('formats to bar.beat.ticks string', () => {
    expect(formatBarBeat({ bar: 8, beat: 1, ticks: 0 })).toBe('8.1.00');
    expect(formatBarBeat({ bar: 8, beat: 1, ticks: 50 })).toBe('8.1.50');
  });

  it('pads ticks with leading zero', () => {
    expect(formatBarBeat({ bar: 1, beat: 1, ticks: 5 })).toBe('1.1.05');
  });

  it('handles negative bar numbers', () => {
    expect(formatBarBeat({ bar: -4, beat: 1, ticks: 0 })).toBe('-4.1.00');
  });

  describe('round-trip with parseBarBeat', () => {
    it('parse -> format -> parse returns equivalent', () => {
      const inputs = ['1.1.00', '8.3.50', '100.4.99', '-4.1.00'];
      for (const input of inputs) {
        const parsed = parseBarBeat(input);
        expect(parsed).not.toBeNull();
        const formatted = formatBarBeat(parsed!);
        const reparsed = parseBarBeat(formatted);
        expect(reparsed).toEqual(parsed);
      }
    });
  });
});
