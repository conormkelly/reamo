/**
 * Grid Line Generator
 * Re-exports from unified timelineTicks for backwards compatibility
 */

import { generateTimelineTicks, type TimelineTick } from './timelineTicks';
import type { WSTempoMarker } from '../core/WebSocketTypes';

export interface GridLine {
  time: number;
  type: 'bar' | 'beat';
  key: string;
}

/**
 * Generate grid lines for the visible viewport
 * Uses unified tick generator for consistency with ruler
 */
export function generateGridLines(
  visibleStart: number,
  visibleEnd: number,
  visibleDuration: number,
  tempoMarkers: WSTempoMarker[],
  barOffset: number,
  bpm?: number,
  timesigNum?: number,
  timesigDenom?: number,
): GridLine[] {
  const ticks = generateTimelineTicks({
    visibleStart,
    visibleEnd,
    visibleDuration,
    tempoMarkers,
    barOffset,
    mode: 'grid',
    bpm,
    timesigNum,
    timesigDenom,
  });

  // Convert to GridLine format (drop bar number, not needed for grid rendering)
  return ticks.map((tick: TimelineTick) => ({
    time: tick.time,
    type: tick.type,
    key: tick.key,
  }));
}
