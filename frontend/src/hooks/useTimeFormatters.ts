/**
 * Hook providing pre-bound time formatting functions
 *
 * This hook returns formatting functions that are already configured with
 * the current BPM, time signature, and bar offset - so components don't
 * need to pass all those parameters manually.
 *
 * They use the tempo at the playhead, which is only right everywhere in a
 * project with one tempo and meter. Convert a position the user types (to
 * move or select something) with useBarPositions, which asks REAPER.
 *
 * @example
 * ```tsx
 * function PositionDisplay({ seconds }: { seconds: number }) {
 *   const { formatBeats, formatDuration } = useTimeFormatters();
 *   return (
 *     <div>
 *       <span>Position: {formatBeats(seconds)}</span>
 *       <span>Duration: {formatDuration(seconds)}</span>
 *     </div>
 *   );
 * }
 * ```
 */

import { useMemo } from 'react';
import { useReaperStore } from '../store';
import { useTimeSignature } from './useTimeSignature';
import { useBarOffset } from './useBarOffset';
import {
  formatBeats,
  formatDuration,
  formatDelta,
  formatTime,
} from '../utils';

export interface UseTimeFormattersReturn {
  /** Format seconds as bar.beat.sub (e.g., "2.3.2") */
  formatBeats: (seconds: number) => string;
  /** Format seconds as duration (e.g., "8 bars 2 beats") */
  formatDuration: (seconds: number) => string;
  /** Format delta seconds as relative change (e.g., "+2 bars") */
  formatDelta: (deltaSeconds: number) => string;
  /** Current BPM (null if not calculated yet) */
  bpm: number | null;
  /** Beats per bar (numerator) */
  beatsPerBar: number;
  /** Denominator of time signature */
  denominator: number;
  /** Bar offset for project alignment */
  barOffset: number;
}

export function useTimeFormatters(): UseTimeFormattersReturn {
  const bpm = useReaperStore((s) => s.bpm);
  const { beatsPerBar, denominator } = useTimeSignature();
  const barOffset = useBarOffset();

  return useMemo(
    () => ({
      formatBeats: (seconds: number) =>
        bpm
          ? formatBeats(seconds, bpm, barOffset, beatsPerBar, denominator)
          : formatTime(seconds),

      formatDuration: (seconds: number) =>
        bpm
          ? formatDuration(seconds, bpm, beatsPerBar, denominator)
          : `${seconds.toFixed(2)}s`,

      formatDelta: (deltaSeconds: number) =>
        bpm
          ? formatDelta(deltaSeconds, bpm, beatsPerBar, denominator)
          : `${deltaSeconds.toFixed(2)}s`,

      bpm,
      beatsPerBar,
      denominator,
      barOffset,
    }),
    [bpm, beatsPerBar, denominator, barOffset]
  );
}
