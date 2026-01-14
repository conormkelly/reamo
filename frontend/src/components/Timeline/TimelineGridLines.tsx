/**
 * TimelineGridLines Component
 * Renders tempo-aware bar/beat grid lines on the timeline
 */

import type { ReactElement } from 'react';
import { useMemo } from 'react';
import { generateGridLines } from '../../utils/gridLines';
import type { WSTempoMarker } from '../../core/WebSocketTypes';

interface Props {
  renderTimeToPercent: (time: number) => number;
  visibleRange: { start: number; end: number };
  visibleDuration: number;
  tempoMarkers: WSTempoMarker[];
  barOffset: number;
}

export function TimelineGridLines({
  renderTimeToPercent,
  visibleRange,
  visibleDuration,
  tempoMarkers,
  barOffset,
}: Props): ReactElement {
  const gridLines = useMemo(
    () =>
      generateGridLines(
        visibleRange.start,
        visibleRange.end,
        visibleDuration,
        tempoMarkers,
        barOffset
      ),
    [visibleRange.start, visibleRange.end, visibleDuration, tempoMarkers, barOffset]
  );

  return (
    <div className="absolute inset-0 pointer-events-none" aria-hidden="true">
      {gridLines.map((line) => {
        const opacity = line.type === 'bar' ? 0.35 : 0.15;
        const color = `rgba(255, 255, 255, ${opacity})`;
        // Fine dashes: 2px dash, 4px gap
        const dashPattern = `repeating-linear-gradient(to bottom, ${color} 0px, ${color} 2px, transparent 2px, transparent 6px)`;

        return (
          <div
            key={line.key}
            className="absolute top-0 bottom-0"
            style={{
              left: `${renderTimeToPercent(line.time)}%`,
              width: line.type === 'bar' ? '1px' : '1px',
              background: dashPattern,
            }}
          />
        );
      })}
    </div>
  );
}
