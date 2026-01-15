/**
 * TimelineRuler Component
 * Renders tempo-aware ruler above the timeline canvas, REAPER-style
 *
 * Format:
 * - Bar.beat on top (e.g. "0.1", "4.1") - 0-indexed bars
 * - Time below in smaller text (e.g. "0:00.000")
 * - Tick line extending down
 *
 * Uses unified tick generator for consistent alignment with grid lines.
 */

import type { ReactElement } from 'react';
import { useMemo } from 'react';
import { generateTimelineTicks, formatRulerTime } from '../../utils/timelineTicks';
import type { WSTempoMarker } from '../../core/WebSocketTypes';

interface Props {
  renderTimeToPercent: (time: number) => number;
  visibleRange: { start: number; end: number };
  visibleDuration: number;
  tempoMarkers: WSTempoMarker[];
  barOffset: number;
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
      generateTimelineTicks({
        visibleStart: visibleRange.start,
        visibleEnd: visibleRange.end,
        visibleDuration,
        tempoMarkers,
        barOffset,
        mode: 'ruler',
      }),
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

        // Skip ticks far outside visible bounds (after buffer filtering)
        if (leftPercent < -10 || leftPercent > 110) return null;

        if (tick.type === 'bar') {
          return (
            <div
              key={tick.key}
              className="absolute top-0 bottom-0 flex flex-col"
              style={{ left: `${leftPercent}%` }}
            >
              {/* Bar.beat label on top (0-indexed bar display) */}
              <span className="text-[10px] text-text-secondary font-mono pl-0.5 leading-tight whitespace-nowrap">
                {tick.bar}.1
              </span>
              {/* Time below in smaller text */}
              <span className="text-[8px] text-text-muted font-mono pl-0.5 leading-tight whitespace-nowrap">
                {formatRulerTime(tick.time, visibleDuration)}
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
