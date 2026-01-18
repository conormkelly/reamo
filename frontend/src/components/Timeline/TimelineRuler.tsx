/**
 * TimelineRuler Component
 * Renders tempo-aware ruler above the timeline canvas, REAPER-style
 *
 * Format:
 * - Bar.beat on top (e.g. "0.1", "4.1", "8.3") - 0-indexed bars
 * - Time below in smaller text (e.g. "0:00.000")
 * - Tick line extending down
 *
 * Features:
 * - Long-press on any label seeks playhead to that position
 * - At close zoom (≤3 bars), shows beat labels for precision navigation
 *
 * Uses unified tick generator for consistent alignment with grid lines.
 */

import type { ReactElement } from 'react';
import { useMemo, useCallback, memo } from 'react';
import { generateTimelineTicks, formatRulerTime, type TimelineTick } from '../../utils/timelineTicks';
import type { WSTempoMarker } from '../../core/WebSocketTypes';
import { useLongPress } from '../../hooks/useLongPress';
import { useReaper } from '../ReaperProvider';
import { transport } from '../../core/WebSocketCommands';

/** Individual labeled tick (bar or beat) with long-press to seek */
interface LabeledTickProps {
  tick: TimelineTick;
  leftPercent: number;
  visibleDuration: number;
  onSeek: (time: number) => void;
}

const RulerLabeledTick = memo(function RulerLabeledTick({
  tick,
  leftPercent,
  visibleDuration,
  onSeek,
}: LabeledTickProps): ReactElement {
  const { handlers } = useLongPress({
    onLongPress: () => onSeek(tick.time),
    duration: 400,
  });

  // Format: bar.beat (e.g., "8.1" for bar, "8.3" for beat 3)
  const beatNum = tick.type === 'bar' ? 1 : tick.beat ?? 1;
  const isBar = tick.type === 'bar';

  return (
    <div
      key={tick.key}
      className="absolute top-0 bottom-0 flex flex-col select-none touch-none"
      style={{ left: `${leftPercent}%` }}
      {...handlers}
    >
      {/* Bar.beat label - bars are more prominent than beat labels */}
      <span
        className={`font-mono pl-0.5 leading-tight whitespace-nowrap cursor-pointer ${
          isBar ? 'text-[10px] text-text-secondary' : 'text-[9px] text-text-muted'
        }`}
      >
        {tick.bar}.{beatNum}
      </span>
      {/* Time below - only show for bar ticks to reduce clutter */}
      {isBar && (
        <span className="text-[8px] text-text-muted font-mono pl-0.5 leading-tight whitespace-nowrap">
          {formatRulerTime(tick.time, visibleDuration)}
        </span>
      )}
      {/* Tick line extending down - taller for bars */}
      <div className={`absolute bottom-0 w-px ${isBar ? 'h-[8px] bg-text-muted' : 'h-[6px] bg-text-disabled'}`} />
    </div>
  );
});

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
  const { sendCommand } = useReaper();

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

  // Seek to position on long-press
  const handleSeek = useCallback(
    (time: number) => {
      sendCommand(transport.seek(time));
    },
    [sendCommand]
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

        // Ticks with labels get full rendering with long-press navigation
        if (tick.showLabel) {
          return (
            <RulerLabeledTick
              key={tick.key}
              tick={tick}
              leftPercent={leftPercent}
              visibleDuration={visibleDuration}
              onSeek={handleSeek}
            />
          );
        }

        // Beat tick without label (just a short tick line)
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
