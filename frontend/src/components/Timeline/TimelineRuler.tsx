/**
 * TimelineRuler Component
 * Renders tempo-aware ruler above the timeline canvas, REAPER-style
 *
 * Format:
 * - Bar.beat on top (e.g. "1.1", "5.1")
 * - Time below in smaller text (e.g. "0:00.000")
 * - Tick line extending down
 *
 * Adaptive density based on zoom level (sparser than grid lines):
 * - ≤10s: every bar with beat subdivisions
 * - ≤15s: every 2 bars
 * - ≤30s: every 4 bars
 * - ≤60s: every 8 bars
 * - ≤120s: every 16 bars
 * - >120s: every 32 bars
 */

import type { ReactElement } from 'react';
import { useMemo } from 'react';
import { barBeatToTime, timeToBarBeat } from '../../core/tempoUtils';
import type { WSTempoMarker } from '../../core/WebSocketTypes';

interface RulerTick {
  time: number;
  bar: number;
  type: 'bar' | 'beat';
  beat?: number;
  key: string;
}

interface Props {
  renderTimeToPercent: (time: number) => number;
  visibleRange: { start: number; end: number };
  visibleDuration: number;
  tempoMarkers: WSTempoMarker[];
  barOffset: number;
}

/**
 * Format time based on zoom level
 * - ≤15s: 3 decimal places (0:00.000)
 * - ≤30s: 2 decimal places (0:00.00)
 * - >30s: no decimals (0:00)
 */
function formatTimeRuler(seconds: number, visibleDuration: number): string {
  const mins = Math.floor(Math.abs(seconds) / 60);
  const secs = Math.abs(seconds) % 60;
  const sign = seconds < 0 ? '-' : '';

  if (visibleDuration <= 15) {
    return `${sign}${mins}:${secs.toFixed(3).padStart(6, '0')}`;
  } else if (visibleDuration <= 30) {
    return `${sign}${mins}:${secs.toFixed(2).padStart(5, '0')}`;
  } else {
    return `${sign}${mins}:${Math.floor(secs).toString().padStart(2, '0')}`;
  }
}

/**
 * Generate ruler ticks for the visible viewport
 */
function generateRulerTicks(
  visibleStart: number,
  visibleEnd: number,
  visibleDuration: number,
  tempoMarkers: WSTempoMarker[],
  barOffset: number
): RulerTick[] {
  const ticks: RulerTick[] = [];

  // Skip if viewport is invalid
  if (visibleDuration <= 0 || visibleEnd <= visibleStart) {
    return ticks;
  }

  // Determine step size based on zoom - fewer labels than grid lines
  let barStep = 1;
  let showBeats = false;
  if (visibleDuration <= 10) {
    showBeats = true;
    barStep = 1;
  } else if (visibleDuration <= 15) {
    barStep = 2;
  } else if (visibleDuration <= 30) {
    barStep = 4;
  } else if (visibleDuration <= 60) {
    barStep = 8;
  } else if (visibleDuration <= 120) {
    barStep = 16;
  } else {
    barStep = 32;
  }

  // Find bar range - clamp to non-negative time
  const clampedStart = Math.max(0, visibleStart);
  const startBarBeat = timeToBarBeat(clampedStart, tempoMarkers, barOffset);
  const endBarBeat = timeToBarBeat(visibleEnd, tempoMarkers, barOffset);

  // Round start down to nearest step boundary (starting from bar 0)
  const firstBar = Math.floor(startBarBeat.bar / barStep) * barStep;

  // Get time signature from first tempo marker (or default 4/4)
  const beatsPerBar = tempoMarkers[0]?.timesigNum ?? 4;

  // Generate bar ticks
  for (let bar = firstBar; bar <= endBarBeat.bar + 1; bar += barStep) {
    const time = barBeatToTime({ bar, beat: 1, ticks: 0 }, tempoMarkers, barOffset);

    // Skip ticks before visible range or at negative time
    if (time < 0 || time < visibleStart) {
      continue;
    }
    // Stop if past visible range
    if (time > visibleEnd) {
      break;
    }

    ticks.push({ time, bar, type: 'bar', key: `bar-${bar}` });

    // Add beat subdivisions if zoomed in enough (show as small ticks without labels)
    if (showBeats && barStep === 1) {
      for (let beat = 2; beat <= beatsPerBar; beat++) {
        const beatTime = barBeatToTime({ bar, beat, ticks: 0 }, tempoMarkers, barOffset);
        if (beatTime >= visibleStart && beatTime <= visibleEnd && beatTime >= 0) {
          ticks.push({ time: beatTime, bar, type: 'beat', beat, key: `beat-${bar}-${beat}` });
        }
      }
    }
  }

  return ticks;
}

export function TimelineRuler({
  renderTimeToPercent,
  visibleRange,
  visibleDuration,
  tempoMarkers,
  barOffset,
}: Props): ReactElement {
  const ticks = useMemo(
    () =>
      generateRulerTicks(
        visibleRange.start,
        visibleRange.end,
        visibleDuration,
        tempoMarkers,
        barOffset
      ),
    [visibleRange.start, visibleRange.end, visibleDuration, tempoMarkers, barOffset]
  );

  return (
    <div
      data-testid="timeline-ruler"
      className="relative h-[32px] bg-bg-deep rounded-t-lg overflow-hidden"
      aria-hidden="true"
    >
      {ticks.map((tick) => {
        const leftPercent = renderTimeToPercent(tick.time);

        if (tick.type === 'bar') {
          return (
            <div
              key={tick.key}
              className="absolute top-0 bottom-0 flex flex-col"
              style={{ left: `${leftPercent}%` }}
            >
              {/* Bar.beat label on top */}
              <span className="text-[10px] text-text-secondary font-mono pl-0.5 leading-tight whitespace-nowrap">
                {tick.bar}.1
              </span>
              {/* Time below in smaller text */}
              <span className="text-[8px] text-text-muted font-mono pl-0.5 leading-tight whitespace-nowrap">
                {formatTimeRuler(tick.time, visibleDuration)}
              </span>
              {/* Tick line extending down */}
              <div className="absolute bottom-0 w-px h-[8px] bg-text-muted" />
            </div>
          );
        }

        // Beat tick (smaller, no label, just a short tick line)
        return (
          <div
            key={tick.key}
            className="absolute bottom-0"
            style={{ left: `${leftPercent}%` }}
          >
            <div className="w-px h-[4px] bg-text-disabled" />
          </div>
        );
      })}
    </div>
  );
}
