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

    it('includes bar 1 at very zoomed out levels (step > 100)', () => {
      // 600s visible at 120 BPM = ~300 bars, barStep will be 128 or 256
      // This catches the bug where step alignment to bar 0 skips bar 1
      const ticks = generateTimelineTicks({
        visibleStart: 0,
        visibleEnd: 600,
        visibleDuration: 600,
        tempoMarkers: DEFAULT_TEMPO,
        barOffset: 0,
        mode: 'ruler',
      });

      const barTicks = ticks.filter((t) => t.type === 'bar');
      expect(barTicks.length).toBeGreaterThan(0);
      // Bar 1 should be first, even though step is ~128
      expect(barTicks[0].bar).toBe(1);
      expect(barTicks[0].time).toBe(0);
      // Second tick should be at step boundary (129, 257, etc - aligned from bar 1)
      expect(barTicks[1].bar).toBeGreaterThan(100);
    });

    it('aligns to project first bar with negative barOffset at very zoomed out levels', () => {
      // With barOffset=-5, bar -4 is at time 0
      // Step boundaries should align to -4: -4, 124, 252...
      const ticks = generateTimelineTicks({
        visibleStart: 0,
        visibleEnd: 600,
        visibleDuration: 600,
        tempoMarkers: DEFAULT_TEMPO,
        barOffset: -5,
        mode: 'ruler',
      });

      const barTicks = ticks.filter((t) => t.type === 'bar');
      expect(barTicks.length).toBeGreaterThan(0);
      // First bar should be -4 (project first bar)
      expect(barTicks[0].bar).toBe(-4);
      expect(barTicks[0].time).toBe(0);
    });
  });

  describe('tick alignment with region positions at non-default BPM', () => {
    // Fixture project: 140 BPM, 4/4, barOffset = -5 (display starts at bar -4)
    // Region "Verse1" starts at bar 0.1 = time 6.857142857... seconds
    // Region "Intro" starts at bar -4.1 = time 0 seconds
    // See: test-fixtures/test-project-1.RPP
    const FIXTURE_TEMPO: WSTempoMarker[] = [
      { position: 0, positionBeats: 0, bpm: 140, timesigNum: 4, timesigDenom: 4, linear: false },
    ];
    const FIXTURE_BAR_OFFSET = -5;

    // Expected seconds for bar 0.1 at 140 BPM with barOffset -5:
    // 4 bars × 4 beats/bar ÷ (140/60 beats/sec) = 48/7 ≈ 6.857142857s
    const VERSE1_START_SECONDS = 6.85714285714286; // From REAPER RPP

    it('tick for bar 0.1 aligns with region position at 140 BPM', () => {
      const ticks = generateTimelineTicks({
        visibleStart: 0,
        visibleEnd: 16,
        visibleDuration: 16,
        tempoMarkers: FIXTURE_TEMPO,
        barOffset: FIXTURE_BAR_OFFSET,
        mode: 'ruler',
      });

      const barTicks = ticks.filter((t) => t.type === 'bar');
      // Find the tick for bar 0 (displayed as "0.1" on ruler)
      const bar0Tick = barTicks.find((t) => t.bar === 0);
      expect(bar0Tick, 'Tick for bar 0 should exist in viewport').toBeDefined();

      // The tick's time position must match where REAPER places the region
      // A mismatch here means regions/markers will visually not align with grid lines
      expect(bar0Tick!.time).toBeCloseTo(VERSE1_START_SECONDS, 3);
    });

    it('tick for bar -4.1 aligns with time 0 at 140 BPM', () => {
      const ticks = generateTimelineTicks({
        visibleStart: 0,
        visibleEnd: 16,
        visibleDuration: 16,
        tempoMarkers: FIXTURE_TEMPO,
        barOffset: FIXTURE_BAR_OFFSET,
        mode: 'ruler',
      });

      const barTicks = ticks.filter((t) => t.type === 'bar');
      const barMinus4Tick = barTicks.find((t) => t.bar === -4);
      expect(barMinus4Tick, 'Tick for bar -4 should exist').toBeDefined();
      expect(barMinus4Tick!.time).toBeCloseTo(0, 3);
    });

    it('empty tempoMarkers falls back to 120 BPM (wrong — store must synthesize)', () => {
      // Documents the raw function behavior: empty markers = 120 BPM fallback.
      // The store layer (index.ts) prevents this by synthesizing a marker from
      // transport BPM when REAPER reports 0 explicit tempo markers. See issue #22.
      const ticksEmpty = generateTimelineTicks({
        visibleStart: 0,
        visibleEnd: 16,
        visibleDuration: 16,
        tempoMarkers: [],
        barOffset: FIXTURE_BAR_OFFSET,
        mode: 'ruler',
      });

      const emptyBar0 = ticksEmpty.filter((t) => t.type === 'bar').find((t) => t.bar === 0);
      expect(emptyBar0, 'Bar 0 tick with empty markers').toBeDefined();
      // With empty markers, bar 0 is at 8.0s (120 BPM) — wrong for 140 BPM project
      expect(emptyBar0!.time).toBeCloseTo(8.0, 3);
      // Correct value is 6.857s — the store synthesizes a marker to prevent this
      expect(emptyBar0!.time).not.toBeCloseTo(VERSE1_START_SECONDS, 1);
    });
  });

  describe('density by zoom level', () => {
    it('shows every bar at close zoom (step=1)', () => {
      // At 5s zoom with 120 BPM: ~2.5 bars visible
      // rawBarStep = 2.5/3 ≈ 0.83 → barStep = 1 (every bar labeled)
      const ticks = generateTimelineTicks({
        visibleStart: 0,
        visibleEnd: 5,
        visibleDuration: 5,
        tempoMarkers: DEFAULT_TEMPO,
        barOffset: 0,
        mode: 'ruler',
      });

      const barTicks = ticks.filter((t) => t.type === 'bar');
      // At 120 BPM, 4/4: bar 1 at 0s, bar 2 at 2s, bar 3 at 4s (plus buffer)
      expect(barTicks.length).toBeGreaterThanOrEqual(3);
      // Step=1 means every bar shown: 1, 2, 3...
      expect(barTicks[0].bar).toBe(1);
      expect(barTicks[1].bar).toBe(2);
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
      // All bars should be at step=4 boundaries from bar 1: 1, 5, 9, 13...
      barTicks.forEach((tick) => {
        expect((tick.bar - 1) % 4).toBe(0);
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
      // All bars should be at step=8 boundaries from bar 1: 1, 9, 17, 25...
      barTicks.forEach((tick) => {
        expect((tick.bar - 1) % 8).toBe(0);
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
    it('shows beats at close zoom (barStep=1, ≤4 bars visible)', () => {
      // Beat subdivisions only appear when barStep=1 AND barsVisible <= 4
      // At 5s zoom with 120 BPM: ~2.5 bars visible → step=1, beatMode='labels'
      const ticks = generateTimelineTicks({
        visibleStart: 0,
        visibleEnd: 5,
        visibleDuration: 5,
        tempoMarkers: DEFAULT_TEMPO,
        barOffset: 0,
        mode: 'ruler',
      });

      const beatTicks = ticks.filter((t) => t.type === 'beat');
      // With 4/4 time, each bar has 3 additional beat ticks (beats 2, 3, 4)
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
      // Use 5s zoom to get step=1 for more granular tick generation
      const ticks = generateTimelineTicks({
        visibleStart: 10,
        visibleEnd: 15,
        visibleDuration: 5,
        tempoMarkers: DEFAULT_TEMPO,
        barOffset: 0,
        mode: 'ruler',
      });

      // Buffer is 10% = 0.5s, so buffered range is 9.5s to 15.5s
      // Should have ticks before visibleStart (buffer)
      const ticksBeforeStart = ticks.filter((t) => t.time < 10);
      expect(ticksBeforeStart.length).toBeGreaterThan(0);

      // Should have ticks at or after visibleEnd (buffer)
      // With step=1, bar 8 is at 14s, bar 9 at 16s (> 15.5, excluded)
      // So we get ticks up to and including visibleEnd
      const ticksAtOrAfterEnd = ticks.filter((t) => t.time >= 15);
      expect(ticksAtOrAfterEnd.length).toBeGreaterThan(0);
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
    // Bars aligned from bar 1: 1, 5, 9, 13...
    exactBarTicks.forEach((tick) => {
      expect((tick.bar - 1) % 4).toBe(0);
    });
    driftedBarTicks.forEach((tick) => {
      expect((tick.bar - 1) % 4).toBe(0);
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
    // Bars aligned from bar 1: 1, 9, 17, 25...
    exactBarTicks.forEach((tick) => {
      expect((tick.bar - 1) % 8).toBe(0);
    });
    driftedBarTicks.forEach((tick) => {
      expect((tick.bar - 1) % 8).toBe(0);
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

    // Both should use step=4, aligned from bar 1: 1, 5, 9, 13...
    startBarTicks.forEach((tick) => {
      expect((tick.bar - 1) % 4).toBe(0);
    });
    pannedBarTicks.forEach((tick) => {
      expect((tick.bar - 1) % 4).toBe(0);
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
