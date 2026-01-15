/**
 * Timeline Tick Generator
 * Unified utility for generating ruler and grid ticks with consistent alignment
 *
 * Key principles:
 * 1. Bar numbers come directly from REAPER (via barOffset), can be negative
 * 2. Step alignment is based on bar number, works with negative bars
 * 3. Visibility filtering includes buffer to prevent edge jank
 * 4. Ticks generated from first aligned bar before viewport to last after
 *
 * Note: REAPER projects can start at any bar number (e.g., -4.1) and any time.
 * The barOffset from the project determines what bar number appears at time 0.
 * With default settings (barOffset=0), bar 1 is at time 0. Users can change this.
 */

import { barBeatToTime, timeToBarBeat } from '../core/tempoUtils';
import type { WSTempoMarker } from '../core/WebSocketTypes';

/**
 * Discrete zoom steps from useViewport
 * Used to snap visibleDuration to prevent threshold flipping during pan
 */
const ZOOM_STEPS = [5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600] as const;

/**
 * Snap a duration to the nearest zoom step
 * This prevents threshold flipping when visibleDuration drifts slightly
 * (e.g., 30.5 instead of 30 due to clamping at project bounds)
 */
function snapToZoomStep(duration: number): number {
  let bestStep: number = ZOOM_STEPS[0];
  let bestDiff = Math.abs(ZOOM_STEPS[0] - duration);

  for (let i = 1; i < ZOOM_STEPS.length; i++) {
    const diff = Math.abs(ZOOM_STEPS[i] - duration);
    if (diff < bestDiff) {
      bestDiff = diff;
      bestStep = ZOOM_STEPS[i];
    }
  }

  return bestStep;
}

export interface TimelineTick {
  /** Time position in seconds */
  time: number;
  /** Bar number from REAPER (includes barOffset, can be negative) */
  bar: number;
  /** Tick type: bar line or beat subdivision */
  type: 'bar' | 'beat';
  /** Beat number within bar (only for beat type) */
  beat?: number;
  /** Unique key for React rendering */
  key: string;
}

export interface TickGeneratorOptions {
  /** Viewport start time in seconds */
  visibleStart: number;
  /** Viewport end time in seconds */
  visibleEnd: number;
  /** Visible duration in seconds (for density calculation) */
  visibleDuration: number;
  /** Tempo markers from REAPER */
  tempoMarkers: WSTempoMarker[];
  /** Bar offset (project setting) */
  barOffset: number;
  /** Mode: 'ruler' uses sparser density than 'grid' */
  mode: 'ruler' | 'grid';
}

/**
 * Calculate bar step size based on zoom level and mode
 *
 * Important: Duration is snapped to the nearest ZOOM_STEP to prevent
 * threshold flipping when visibleDuration drifts slightly during panning
 * (e.g., 30.5 instead of 30 due to clamping at project bounds).
 *
 * Ruler (sparser - labels need more space):
 * - ≤10s: every bar with beat ticks
 * - ≤15s: every 2 bars
 * - ≤30s: every 4 bars
 * - ≤60s: every 8 bars
 * - ≤120s: every 16 bars
 * - >120s: every 32 bars
 *
 * Grid (denser - just lines):
 * - ≤15s: every bar with beat lines
 * - ≤60s: every bar
 * - ≤300s: every 4 bars
 * - >300s: every 8 bars
 */
function getBarStepAndBeats(
  visibleDuration: number,
  mode: 'ruler' | 'grid'
): { barStep: number; showBeats: boolean } {
  // Snap to nearest zoom step to prevent threshold flipping
  const snappedDuration = snapToZoomStep(visibleDuration);

  if (mode === 'ruler') {
    if (snappedDuration <= 10) return { barStep: 1, showBeats: true };
    if (snappedDuration <= 15) return { barStep: 2, showBeats: false };
    if (snappedDuration <= 30) return { barStep: 4, showBeats: false };
    if (snappedDuration <= 60) return { barStep: 8, showBeats: false };
    if (snappedDuration <= 120) return { barStep: 16, showBeats: false };
    return { barStep: 32, showBeats: false };
  } else {
    // Grid mode
    if (snappedDuration <= 15) return { barStep: 1, showBeats: true };
    if (snappedDuration <= 60) return { barStep: 1, showBeats: false };
    if (snappedDuration <= 300) return { barStep: 4, showBeats: false };
    return { barStep: 8, showBeats: false };
  }
}

/**
 * Generate timeline ticks for ruler or grid
 *
 * Algorithm:
 * 1. Find the bar range for the viewport (with buffer)
 * 2. Calculate first bar aligned to step boundary
 * 3. Generate ticks from first bar to end of viewport
 * 4. Filter to visible range (with buffer to prevent jank)
 *
 * Note: Bar numbers from timeToBarBeat already include barOffset (can be negative).
 * We use them directly for display without conversion.
 */
export function generateTimelineTicks(options: TickGeneratorOptions): TimelineTick[] {
  const { visibleStart, visibleEnd, visibleDuration, tempoMarkers, barOffset, mode } = options;

  // Skip if viewport is invalid
  if (visibleDuration <= 0 || visibleEnd <= visibleStart) {
    return [];
  }

  const { barStep, showBeats } = getBarStepAndBeats(visibleDuration, mode);

  // Get time signature from first tempo marker (or default 4/4)
  const beatsPerBar = tempoMarkers[0]?.timesigNum ?? 4;

  // Calculate visibility buffer (10% of visible duration) to prevent edge jank
  const buffer = visibleDuration * 0.1;
  const bufferedStart = Math.max(0, visibleStart - buffer);
  const bufferedEnd = visibleEnd + buffer;

  // Find bar at buffered start - bar number already includes barOffset
  const startBarBeat = timeToBarBeat(bufferedStart, tempoMarkers, barOffset);
  const startBar = startBarBeat.bar;

  // Calculate first bar aligned to step boundary
  // Works with negative bars: floor(-3/4)*4 = floor(-0.75)*4 = -1*4 = -4
  const firstBar = Math.floor(startBar / barStep) * barStep;

  // Find bar at buffered end
  const endBarBeat = timeToBarBeat(bufferedEnd, tempoMarkers, barOffset);
  const endBar = endBarBeat.bar;

  const ticks: TimelineTick[] = [];

  // Generate ticks from first aligned bar to end
  for (let bar = firstBar; bar <= endBar + barStep; bar += barStep) {
    const time = barBeatToTime({ bar, beat: 1, ticks: 0 }, tempoMarkers, barOffset);

    // Skip negative times (before project start)
    if (time < 0) continue;

    // Skip if past buffered range
    if (time > bufferedEnd) break;

    // Add bar tick - bar number is from REAPER (includes barOffset)
    ticks.push({
      time,
      bar,
      type: 'bar',
      key: `bar-${bar}`,
    });

    // Add beat subdivisions if enabled
    if (showBeats) {
      for (let beat = 2; beat <= beatsPerBar; beat++) {
        const beatTime = barBeatToTime({ bar, beat, ticks: 0 }, tempoMarkers, barOffset);

        // Skip if outside buffered range or negative
        if (beatTime < 0 || beatTime < bufferedStart || beatTime > bufferedEnd) continue;

        ticks.push({
          time: beatTime,
          bar,
          type: 'beat',
          beat,
          key: `beat-${bar}-${beat}`,
        });
      }
    }
  }

  return ticks;
}

/**
 * Format time for ruler display
 * Precision adapts to zoom level:
 * - ≤15s: 3 decimal places (0:00.000)
 * - ≤30s: 2 decimal places (0:00.00)
 * - >30s: no decimals (0:00)
 *
 * Note: Duration is snapped to nearest ZOOM_STEP to prevent format flipping
 * when visibleDuration drifts (e.g., 30.5 vs 30).
 */
export function formatRulerTime(seconds: number, visibleDuration: number): string {
  const mins = Math.floor(Math.abs(seconds) / 60);
  const secs = Math.abs(seconds) % 60;
  const sign = seconds < 0 ? '-' : '';

  // Snap to nearest zoom step to prevent format flipping
  const snappedDuration = snapToZoomStep(visibleDuration);

  if (snappedDuration <= 15) {
    return `${sign}${mins}:${secs.toFixed(3).padStart(6, '0')}`;
  } else if (snappedDuration <= 30) {
    return `${sign}${mins}:${secs.toFixed(2).padStart(5, '0')}`;
  } else {
    return `${sign}${mins}:${Math.floor(secs).toString().padStart(2, '0')}`;
  }
}

/**
 * Format visible duration for zoom display
 * Uses hysteresis to prevent 60s/1m flipping
 */
let lastFormatWasMinutes = false;

export function formatZoomDuration(seconds: number): string {
  // Hysteresis: once we switch to minutes, stay there until clearly below threshold
  const switchToMinutesAt = 60;
  const switchToSecondsAt = 55; // 5 second hysteresis band

  if (seconds >= switchToMinutesAt) {
    lastFormatWasMinutes = true;
  } else if (seconds < switchToSecondsAt) {
    lastFormatWasMinutes = false;
  }
  // Between 55-60: keep previous format

  if (lastFormatWasMinutes && seconds >= switchToSecondsAt) {
    if (seconds < 3600) {
      const minutes = Math.round(seconds / 60);
      return `${minutes}m`;
    }
    const hours = Math.round(seconds / 3600);
    return `${hours}h`;
  }

  return `${Math.round(seconds)}s`;
}
