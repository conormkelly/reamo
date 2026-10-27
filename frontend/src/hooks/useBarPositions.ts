/**
 * useBarPositions - Convert between ruler bar.beat positions and seconds.
 *
 * REAPER does the conversion (tempo/barsToTime, tempo/timeToBeats), through
 * the project's tempo map, time signatures and start measure. Converting on
 * the phone with the tempo at the playhead is only right in a project with
 * one tempo and one meter. A position REAPER can't convert gives null, for
 * the caller to report: guessing would put the edit in the wrong place.
 */

import { useCallback } from 'react';
import { useReaper } from './useReaper';
import { tempo as tempoCmd } from '../core/WebSocketCommands';

export interface BarPosition {
  bar: number;
  /** 1-based beat in the bar */
  beat: number;
  /** Hundredths of a beat, 0-99 */
  ticks: number;
}

/** Parse "bar", "bar.beat" or "bar.beat.ticks" as shown on the ruler. */
export function parseBarPosition(text: string): BarPosition | null {
  const parts = text.trim().split('.');
  if (parts.length > 3 || !/^-?\d+$/.test(parts[0])) return null;
  if (parts.slice(1).some((p) => !/^\d+$/.test(p))) return null;
  const bar = parseInt(parts[0], 10);
  const beat = parts.length >= 2 ? parseInt(parts[1], 10) : 1;
  const ticks = parts.length >= 3 ? parseInt(parts[2], 10) : 0;
  if (beat < 1 || ticks > 99) return null;
  return { bar, beat, ticks };
}

export interface UseBarPositionsReturn {
  /** Seconds at a ruler position, or null if it isn't one REAPER can place */
  barsToSeconds: (text: string) => Promise<number | null>;
  /** Ruler label for a time ("17.2", "17.2.50"), or null */
  secondsToBars: (seconds: number) => Promise<string | null>;
  /** Length in seconds of the bar containing a time, and of one of its beats, or null */
  barLengthAt: (seconds: number) => Promise<{ bar: number; beat: number } | null>;
}

export function useBarPositions(): UseBarPositionsReturn {
  const { sendAsync } = useReaper();

  const barsToSeconds = useCallback(
    async (text: string): Promise<number | null> => {
      const pos = parseBarPosition(text);
      if (!pos) return null;
      try {
        const cmd = tempoCmd.barsToTime(pos.bar, pos.beat, pos.ticks);
        const resp = (await sendAsync(cmd.command, cmd.params)) as
          | { success?: boolean; payload?: { time?: unknown } }
          | undefined;
        const time = resp?.payload?.time;
        return resp?.success && typeof time === 'number' ? time : null;
      } catch {
        return null;
      }
    },
    [sendAsync]
  );

  const secondsToBars = useCallback(
    async (seconds: number): Promise<string | null> => {
      try {
        const cmd = tempoCmd.timeToBeats(seconds);
        const resp = (await sendAsync(cmd.command, cmd.params)) as
          | { success?: boolean; payload?: { bars?: unknown } }
          | undefined;
        const bars = resp?.payload?.bars;
        return resp?.success && typeof bars === 'string' ? bars.replace(/\.00$/, '') : null;
      } catch {
        return null;
      }
    },
    [sendAsync]
  );

  const barLengthAt = useCallback(
    async (seconds: number): Promise<{ bar: number; beat: number } | null> => {
      try {
        const cmd = tempoCmd.getBarDuration(seconds);
        const resp = (await sendAsync(cmd.command, cmd.params)) as
          | { success?: boolean; payload?: { duration?: unknown; durationBeats?: unknown } }
          | undefined;
        const bar = resp?.payload?.duration;
        const beats = resp?.payload?.durationBeats;
        if (!resp?.success || typeof bar !== 'number' || typeof beats !== 'number' || !(bar > 0) || !(beats > 0)) {
          return null;
        }
        return { bar, beat: bar / beats };
      } catch {
        return null;
      }
    },
    [sendAsync]
  );

  return { barsToSeconds, secondsToBars, barLengthAt };
}
