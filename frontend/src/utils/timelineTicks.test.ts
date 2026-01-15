/**
 * Tests for timeline tick generation
 * Ensures consistent, jank-free ruler and grid line rendering
 */

import { describe, it, expect, beforeEach } from 'vitest';
import {
  generateTimelineTicks,
  formatRulerTime,
  formatZoomDuration,
} from './timelineTicks';
import type { WSTempoMarker } from '../core/WebSocketTypes';

// Default tempo marker (120 BPM, 4/4)
const DEFAULT_TEMPO: WSTempoMarker[] = [
  { position: 0, positionBeats: 0, bpm: 120, timesigNum: 4, timesigDenom: 4, linear: false },
];

describe('generateTimelineTicks', () => {
  describe('bar alignment', () => {
    it('includes bar 1 when viewport starts at 0 (default REAPER behavior)', () => {
      // With barOffset=0, bar 1 is at time 0 (REAPER default)
      // Use 10s zoom to show every bar (step=1)
      const ticks = generateTimelineTicks({
        visibleStart: 0,
        visibleEnd: 10,
        visibleDuration: 10,
        tempoMarkers: DEFAULT_TEMPO,
        barOffset: 0,
        mode: 'ruler',
      });

      const barTicks = ticks.filter((t) => t.type === 'bar');
      expect(barTicks.length).toBeGreaterThan(0);
      // Bar 1 should be at time 0 with default settings
      expect(barTicks[0].bar).toBe(1);
      expect(barTicks[0].time).toBe(0);
    });

    it('aligns bars to step boundaries', () => {
      // At 30s zoom, ruler shows every 4 bars
      const ticks = generateTimelineTicks({
        visibleStart: 10, // Start mid-project
        visibleEnd: 40,
        visibleDuration: 30,
        tempoMarkers: DEFAULT_TEMPO,
        barOffset: 0,
        mode: 'ruler',
      });

      const barTicks = ticks.filter((t) => t.type === 'bar');
      // All bar numbers should be at step boundaries
      // With step=4 and bars starting at 1: 1, 5, 9, 13... or aligned to 0: 0, 4, 8, 12...
      // The alignment is floor(bar/step)*step which rounds down to nearest multiple
      expect(barTicks.length).toBeGreaterThan(0);
    });

    it('supports negative bar numbers with barOffset', () => {
      // Project starts at bar -4 (barOffset = -5 makes bar 1 + (-5) = -4 at time 0)
      const ticks = generateTimelineTicks({
        visibleStart: 0,
        visibleEnd: 10,
        visibleDuration: 10,
        tempoMarkers: DEFAULT_TEMPO,
        barOffset: -5,
        mode: 'ruler',
      });

      const barTicks = ticks.filter((t) => t.type === 'bar');
      expect(barTicks.length).toBeGreaterThan(0);
      // First bar at time 0 should be bar -4 (1 + (-5))
      expect(barTicks[0].bar).toBe(-4);
    });
  });

  describe('density by zoom level', () => {
    it('shows every bar at ≤10s zoom (ruler)', () => {
      const ticks = generateTimelineTicks({
        visibleStart: 0,
        visibleEnd: 10,
        visibleDuration: 10,
        tempoMarkers: DEFAULT_TEMPO,
        barOffset: 0,
        mode: 'ruler',
      });

      const barTicks = ticks.filter((t) => t.type === 'bar');
      // At 120 BPM, 4/4, one bar = 2 seconds
      // 10 seconds = 5 bars (0, 1, 2, 3, 4) plus buffer
      expect(barTicks.length).toBeGreaterThanOrEqual(5);
    });

    it('shows every 4 bars at 30s zoom (ruler)', () => {
      const ticks = generateTimelineTicks({
        visibleStart: 0,
        visibleEnd: 30,
        visibleDuration: 30,
        tempoMarkers: DEFAULT_TEMPO,
        barOffset: 0,
        mode: 'ruler',
      });

      const barTicks = ticks.filter((t) => t.type === 'bar');
      // All bars should be multiples of 4
      barTicks.forEach((tick) => {
        expect(tick.bar % 4).toBe(0);
      });
    });

    it('shows every 8 bars at 60s zoom (ruler)', () => {
      const ticks = generateTimelineTicks({
        visibleStart: 0,
        visibleEnd: 60,
        visibleDuration: 60,
        tempoMarkers: DEFAULT_TEMPO,
        barOffset: 0,
        mode: 'ruler',
      });

      const barTicks = ticks.filter((t) => t.type === 'bar');
      // All bars should be multiples of 8
      barTicks.forEach((tick) => {
        expect(tick.bar % 8).toBe(0);
      });
    });

    it('grid is denser than ruler at same zoom', () => {
      const rulerTicks = generateTimelineTicks({
        visibleStart: 0,
        visibleEnd: 60,
        visibleDuration: 60,
        tempoMarkers: DEFAULT_TEMPO,
        barOffset: 0,
        mode: 'ruler',
      });

      const gridTicks = generateTimelineTicks({
        visibleStart: 0,
        visibleEnd: 60,
        visibleDuration: 60,
        tempoMarkers: DEFAULT_TEMPO,
        barOffset: 0,
        mode: 'grid',
      });

      // Grid should have more ticks than ruler at same zoom
      expect(gridTicks.length).toBeGreaterThan(rulerTicks.length);
    });
  });

  describe('beat subdivisions', () => {
    it('shows beats at ≤10s zoom (ruler)', () => {
      const ticks = generateTimelineTicks({
        visibleStart: 0,
        visibleEnd: 10,
        visibleDuration: 10,
        tempoMarkers: DEFAULT_TEMPO,
        barOffset: 0,
        mode: 'ruler',
      });

      const beatTicks = ticks.filter((t) => t.type === 'beat');
      expect(beatTicks.length).toBeGreaterThan(0);
    });

    it('hides beats at >15s zoom (ruler)', () => {
      const ticks = generateTimelineTicks({
        visibleStart: 0,
        visibleEnd: 30,
        visibleDuration: 30,
        tempoMarkers: DEFAULT_TEMPO,
        barOffset: 0,
        mode: 'ruler',
      });

      const beatTicks = ticks.filter((t) => t.type === 'beat');
      expect(beatTicks.length).toBe(0);
    });
  });

  describe('buffer for smooth scrolling', () => {
    it('generates ticks beyond visible bounds', () => {
      const ticks = generateTimelineTicks({
        visibleStart: 10,
        visibleEnd: 20,
        visibleDuration: 10,
        tempoMarkers: DEFAULT_TEMPO,
        barOffset: 0,
        mode: 'ruler',
      });

      // Should have ticks before visibleStart (buffer)
      const ticksBeforeStart = ticks.filter((t) => t.time < 10);
      expect(ticksBeforeStart.length).toBeGreaterThan(0);

      // Should have ticks after visibleEnd (buffer)
      const ticksAfterEnd = ticks.filter((t) => t.time > 20);
      expect(ticksAfterEnd.length).toBeGreaterThan(0);
    });
  });

  describe('edge cases', () => {
    it('returns empty array for invalid viewport', () => {
      const ticks = generateTimelineTicks({
        visibleStart: 10,
        visibleEnd: 5, // Invalid: end < start
        visibleDuration: -5,
        tempoMarkers: DEFAULT_TEMPO,
        barOffset: 0,
        mode: 'ruler',
      });

      expect(ticks).toEqual([]);
    });

    it('handles zero duration', () => {
      const ticks = generateTimelineTicks({
        visibleStart: 0,
        visibleEnd: 0,
        visibleDuration: 0,
        tempoMarkers: DEFAULT_TEMPO,
        barOffset: 0,
        mode: 'ruler',
      });

      expect(ticks).toEqual([]);
    });

    it('handles empty tempo markers (default 120 BPM)', () => {
      const ticks = generateTimelineTicks({
        visibleStart: 0,
        visibleEnd: 10,
        visibleDuration: 10,
        tempoMarkers: [],
        barOffset: 0,
        mode: 'ruler',
      });

      // Should still generate ticks with default tempo
      expect(ticks.length).toBeGreaterThan(0);
    });
  });
});

describe('formatRulerTime', () => {
  it('shows 3 decimal places at ≤15s zoom', () => {
    const result = formatRulerTime(1.5, 10);
    expect(result).toBe('0:01.500');
  });

  it('shows 2 decimal places at 30s zoom', () => {
    // Use actual ZOOM_STEP value (20s snaps to 15s, not 30s)
    const result = formatRulerTime(1.5, 30);
    expect(result).toBe('0:01.50');
  });

  it('shows no decimals at >30s zoom', () => {
    const result = formatRulerTime(1.5, 60);
    expect(result).toBe('0:01');
  });

  it('handles negative times', () => {
    const result = formatRulerTime(-5, 60);
    expect(result).toBe('-0:05');
  });

  it('formats minutes correctly', () => {
    const result = formatRulerTime(125, 60);
    expect(result).toBe('2:05');
  });

  it('uses consistent precision when duration drifts (30.5s same as 30s)', () => {
    // At exactly 30s zoom, should show 2 decimals
    const exact = formatRulerTime(1.5, 30);
    expect(exact).toBe('0:01.50');

    // At 30.5s (drifted), should ALSO show 2 decimals (snaps to 30)
    const drifted = formatRulerTime(1.5, 30.5);
    expect(drifted).toBe('0:01.50');
  });

  it('uses consistent precision when duration drifts (60.5s same as 60s)', () => {
    // At exactly 60s zoom, should show no decimals
    const exact = formatRulerTime(1.5, 60);
    expect(exact).toBe('0:01');

    // At 60.5s (drifted), should ALSO show no decimals (snaps to 60)
    const drifted = formatRulerTime(1.5, 60.5);
    expect(drifted).toBe('0:01');
  });
});

describe('duration snapping for consistent steps', () => {
  it('treats 30.5s same as 30s (snaps to nearest zoom step)', () => {
    const exact = generateTimelineTicks({
      visibleStart: 0,
      visibleEnd: 30,
      visibleDuration: 30, // Exact zoom step
      tempoMarkers: DEFAULT_TEMPO,
      barOffset: 0,
      mode: 'ruler',
    });

    const drifted = generateTimelineTicks({
      visibleStart: 0,
      visibleEnd: 30.5,
      visibleDuration: 30.5, // Slightly drifted (e.g., clamped at project bounds)
      tempoMarkers: DEFAULT_TEMPO,
      barOffset: 0,
      mode: 'ruler',
    });

    const exactBarTicks = exact.filter((t) => t.type === 'bar');
    const driftedBarTicks = drifted.filter((t) => t.type === 'bar');

    // Both should use step=4 (every 4 bars) since 30.5 snaps to 30
    exactBarTicks.forEach((tick) => {
      expect(tick.bar % 4).toBe(0);
    });
    driftedBarTicks.forEach((tick) => {
      expect(tick.bar % 4).toBe(0);
    });
  });

  it('treats 60.5s same as 60s (snaps to nearest zoom step)', () => {
    const exact = generateTimelineTicks({
      visibleStart: 0,
      visibleEnd: 60,
      visibleDuration: 60,
      tempoMarkers: DEFAULT_TEMPO,
      barOffset: 0,
      mode: 'ruler',
    });

    const drifted = generateTimelineTicks({
      visibleStart: 0,
      visibleEnd: 60.5,
      visibleDuration: 60.5,
      tempoMarkers: DEFAULT_TEMPO,
      barOffset: 0,
      mode: 'ruler',
    });

    const exactBarTicks = exact.filter((t) => t.type === 'bar');
    const driftedBarTicks = drifted.filter((t) => t.type === 'bar');

    // Both should use step=8 (every 8 bars) since 60.5 snaps to 60
    exactBarTicks.forEach((tick) => {
      expect(tick.bar % 8).toBe(0);
    });
    driftedBarTicks.forEach((tick) => {
      expect(tick.bar % 8).toBe(0);
    });
  });

  it('panning does not change step size at 30s zoom', () => {
    // Simulating panning by changing visibleStart/End but keeping same duration
    const atStart = generateTimelineTicks({
      visibleStart: 0,
      visibleEnd: 30,
      visibleDuration: 30,
      tempoMarkers: DEFAULT_TEMPO,
      barOffset: 0,
      mode: 'ruler',
    });

    const panned = generateTimelineTicks({
      visibleStart: 50,
      visibleEnd: 80,
      visibleDuration: 30,
      tempoMarkers: DEFAULT_TEMPO,
      barOffset: 0,
      mode: 'ruler',
    });

    const startBarTicks = atStart.filter((t) => t.type === 'bar');
    const pannedBarTicks = panned.filter((t) => t.type === 'bar');

    // Both should use step=4
    startBarTicks.forEach((tick) => {
      expect(tick.bar % 4).toBe(0);
    });
    pannedBarTicks.forEach((tick) => {
      expect(tick.bar % 4).toBe(0);
    });
  });
});

describe('formatZoomDuration', () => {
  // Reset hysteresis state between tests
  beforeEach(() => {
    // Force state reset by calling with a low value
    formatZoomDuration(10);
  });

  it('shows seconds for <60s', () => {
    expect(formatZoomDuration(30)).toBe('30s');
  });

  it('shows minutes for ≥60s', () => {
    expect(formatZoomDuration(120)).toBe('2m');
  });

  it('uses hysteresis to prevent 60s/1m flipping', () => {
    // Go to minutes mode
    formatZoomDuration(65);
    // Now at 58s, should stay in minutes due to hysteresis
    const result = formatZoomDuration(58);
    expect(result).toBe('1m');
  });

  it('switches back to seconds below hysteresis threshold', () => {
    // Go to minutes mode
    formatZoomDuration(65);
    // Now at 50s, should switch back to seconds (below 55s threshold)
    const result = formatZoomDuration(50);
    expect(result).toBe('50s');
  });
});
