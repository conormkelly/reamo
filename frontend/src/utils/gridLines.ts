/**
 * Grid Line Generator
 * Generates tempo-aware bar/beat grid lines for timeline rendering
 */

import { barBeatToTime, timeToBarBeat } from '../core/tempoUtils';
import type { WSTempoMarker } from '../core/WebSocketTypes';

export interface GridLine {
  time: number;
  type: 'bar' | 'beat';
  key: string;
}

/**
 * Generate grid lines for the visible viewport
 *
 * Adaptive density based on zoom level:
 * - ≤15s: every beat
 * - ≤60s: every bar
 * - ≤300s: every 4 bars
 * - >300s: every 8 bars
 */
export function generateGridLines(
  visibleStart: number,
  visibleEnd: number,
  visibleDuration: number,
  tempoMarkers: WSTempoMarker[],
  barOffset: number
): GridLine[] {
  const lines: GridLine[] = [];

  // Skip if viewport is invalid
  if (visibleDuration <= 0 || visibleEnd <= visibleStart) {
    return lines;
  }

  // Determine step size based on zoom
  let barStep = 1;
  let showBeats = false;
  if (visibleDuration <= 15) {
    showBeats = true;
  } else if (visibleDuration <= 60) {
    barStep = 1;
  } else if (visibleDuration <= 300) {
    barStep = 4;
  } else {
    barStep = 8;
  }

  // Find bar range - clamp to non-negative time
  const clampedStart = Math.max(0, visibleStart);
  const startBarBeat = timeToBarBeat(clampedStart, tempoMarkers, barOffset);
  const endBarBeat = timeToBarBeat(visibleEnd, tempoMarkers, barOffset);

  // Round start down to nearest step boundary
  const firstBar = Math.floor((startBarBeat.bar - 1) / barStep) * barStep + 1;

  // Get time signature from first tempo marker (or default 4/4)
  const beatsPerBar = tempoMarkers[0]?.timesigNum ?? 4;

  // Generate bar lines
  for (let bar = firstBar; bar <= endBarBeat.bar + 1; bar += barStep) {
    const time = barBeatToTime({ bar, beat: 1, ticks: 0 }, tempoMarkers, barOffset);

    // Skip lines before visible range or at negative time
    if (time < 0 || time < visibleStart) {
      continue;
    }
    // Stop if past visible range
    if (time > visibleEnd) {
      break;
    }

    lines.push({ time, type: 'bar', key: `bar-${bar}` });

    // Add beat subdivisions if zoomed in enough
    if (showBeats && barStep === 1) {
      for (let beat = 2; beat <= beatsPerBar; beat++) {
        const beatTime = barBeatToTime({ bar, beat, ticks: 0 }, tempoMarkers, barOffset);
        if (beatTime >= visibleStart && beatTime <= visibleEnd && beatTime >= 0) {
          lines.push({ time: beatTime, type: 'beat', key: `beat-${bar}-${beat}` });
        }
      }
    }
  }

  return lines;
}
