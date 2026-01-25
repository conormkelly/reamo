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
 * Includes fine steps (1-3s) for precision cursor-based editing
 */
const ZOOM_STEPS = [1, 2, 3, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600] as const;

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
  /** Whether this tick should show a label (for ruler) */
  showLabel: boolean;
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

/** Target number of labels/gridlines per screen width */
const TARGET_LABELS_RULER = 3; // Ruler needs more space for labels (sparser = less cluttered)
const TARGET_LABELS_GRID = 6; // Grid can be denser (just lines)

/** Round to nearest "nice" bar step (powers of 2 for musical alignment) */
const NICE_BAR_STEPS = [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096];

function roundToNiceBarStep(rawStep: number): number {
  // Find the nice step that's closest to (but >= ) the raw step
  for (const step of NICE_BAR_STEPS) {
    if (step >= rawStep) return step;
  }
  // For extremely large values, round to nearest power of 2
  return Math.pow(2, Math.ceil(Math.log2(rawStep)));
}

/**
 * Beat label display modes for close zoom levels
 * - 'none': No beat ticks
 * - 'ticks': Beat tick lines only (no labels)
 * - 'labels': Beat labels with navigation (for precision editing)
 */
type BeatDisplayMode = 'none' | 'ticks' | 'labels';

/**
 * Calculate bar step size dynamically based on actual bars visible
 *
 * Algorithm:
 * 1. Use actual bars visible (calculated from tempo map)
 * 2. Calculate raw bar step to achieve target label count
 * 3. Round to nearest "nice" bar step (power of 2)
 *
 * This scales to any project length and adapts to actual tempo!
 * A 60 BPM project shows half as many bars as 120 BPM for the same time range.
 *
 * Beat display modes:
 * - ≤3 bars: Show all beat labels (precision editing)
 * - ≤7 bars: Show beat tick lines only
 * - >7 bars: No beat subdivision
 */
function getBarStepAndBeats(
  barsVisible: number,
  mode: 'ruler' | 'grid'
): { barStep: number; beatMode: BeatDisplayMode } {
  // Target label counts differ by mode
  const targetLabels = mode === 'ruler' ? TARGET_LABELS_RULER : TARGET_LABELS_GRID;

  // Calculate raw bar step needed to hit target
  const rawBarStep = barsVisible / targetLabels;

  // Round to nice bar step (minimum 1)
  const barStep = Math.max(1, roundToNiceBarStep(rawBarStep));

  // Beat display depends on zoom level
  // Only show beat labels at very close zoom for precision editing
  let beatMode: BeatDisplayMode = 'none';
  if (barStep === 1) {
    if (barsVisible <= 1.5) {
      // Very close zoom (~1 bar, ~2-3s at 120 BPM): show beat labels for precision
      beatMode = 'labels';
    } else if (barsVisible <= 3) {
      // Close zoom (2-3 bars, ~4-6s at 120 BPM): show beat tick lines only
      beatMode = 'ticks';
    }
  }

  return { barStep, beatMode };
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

  // Get time signature from first tempo marker (or default 4/4)
  const beatsPerBar = tempoMarkers[0]?.timesigNum ?? 4;

  // Calculate visibility buffer (10% of visible duration) to prevent edge jank
  const buffer = visibleDuration * 0.1;
  const bufferedStart = Math.max(0, visibleStart - buffer);
  const bufferedEnd = visibleEnd + buffer;

  // Find bar at buffered start - bar number already includes barOffset
  const startBarBeat = timeToBarBeat(bufferedStart, tempoMarkers, barOffset);
  const startBar = startBarBeat.bar;

  // Find bar at buffered end
  const endBarBeat = timeToBarBeat(bufferedEnd, tempoMarkers, barOffset);
  const endBar = endBarBeat.bar;

  // Calculate actual bars visible using tempo map (not estimated!)
  // This adapts to actual project tempo - 60 BPM shows half as many bars as 120 BPM
  const barsVisible = Math.max(1, endBar - startBar);

  const { barStep, beatMode } = getBarStepAndBeats(barsVisible, mode);

  // Calculate first bar aligned to step boundary from project's first bar
  // With barOffset=0, projectFirstBar=1, so steps are: 1, 1+step, 1+2*step, ...
  // With barOffset=-5, projectFirstBar=-4, so steps are: -4, -4+step, -4+2*step, ...
  // This ensures the project's first bar is always on a step boundary
  const projectFirstBar = 1 + barOffset;
  const firstBar = Math.floor((startBar - projectFirstBar) / barStep) * barStep + projectFirstBar;

  const ticks: TimelineTick[] = [];

  // Generate ticks from first aligned bar to end
  for (let bar = firstBar; bar <= endBar + barStep; bar += barStep) {
    const time = barBeatToTime({ bar, beat: 1, ticks: 0 }, tempoMarkers, barOffset);

    // Skip negative times (before project start)
    if (time < 0) continue;

    // Skip if past buffered range
    if (time > bufferedEnd) break;

    // Add bar tick - bar number is from REAPER (includes barOffset)
    // Bar ticks always show labels
    ticks.push({
      time,
      bar,
      type: 'bar',
      showLabel: true,
      key: `bar-${bar}`,
    });

    // Add beat subdivisions if enabled
    if (beatMode !== 'none') {
      for (let beat = 2; beat <= beatsPerBar; beat++) {
        const beatTime = barBeatToTime({ bar, beat, ticks: 0 }, tempoMarkers, barOffset);

        // Skip if outside buffered range or negative
        if (beatTime < 0 || beatTime < bufferedStart || beatTime > bufferedEnd) continue;

        ticks.push({
          time: beatTime,
          bar,
          type: 'beat',
          beat,
          // Show labels at close zoom for precision navigation
          showLabel: beatMode === 'labels',
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
 * - ≤600s (10min): minutes:seconds (0:00)
 * - >600s: hours:minutes format (0h00m) for readability at large zooms
 *
 * Note: Duration is snapped to nearest ZOOM_STEP to prevent format flipping
 * when visibleDuration drifts (e.g., 30.5 vs 30).
 */
export function formatRulerTime(seconds: number, visibleDuration: number): string {
  const absSeconds = Math.abs(seconds);
  const sign = seconds < 0 ? '-' : '';

  // Snap to nearest zoom step to prevent format flipping
  const snappedDuration = snapToZoomStep(visibleDuration);

  if (snappedDuration <= 15) {
    const mins = Math.floor(absSeconds / 60);
    const secs = absSeconds % 60;
    return `${sign}${mins}:${secs.toFixed(3).padStart(6, '0')}`;
  } else if (snappedDuration <= 30) {
    const mins = Math.floor(absSeconds / 60);
    const secs = absSeconds % 60;
    return `${sign}${mins}:${secs.toFixed(2).padStart(5, '0')}`;
  } else if (snappedDuration <= 600) {
    // Up to 10min view: show minutes:seconds
    const mins = Math.floor(absSeconds / 60);
    const secs = Math.floor(absSeconds % 60);
    return `${sign}${mins}:${secs.toString().padStart(2, '0')}`;
  } else {
    // Large zoom (30min+): show hours and minutes for readability
    const hours = Math.floor(absSeconds / 3600);
    const mins = Math.floor((absSeconds % 3600) / 60);
    if (hours > 0) {
      return `${sign}${hours}h${mins.toString().padStart(2, '0')}m`;
    }
    return `${sign}${mins}m`;
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
