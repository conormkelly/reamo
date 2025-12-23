/**
 * Hook for calculating bar offset for REAPER project alignment
 *
 * Bar offset accounts for projects that don't start at bar 1
 * (e.g., starting at bar -4 for a 4-bar count-in, or bar 69 for a late start).
 *
 * This calculation compares REAPER's reported bar position with what we
 * calculate from seconds/BPM, giving us the offset to apply when formatting.
 */

import { useMemo } from 'react';
import { useReaperStore } from '../store';
import { useTimeSignature } from './useTimeSignature';
import { parseReaperBar, secondsToBeats } from '../utils';

export function useBarOffset(): number {
  const bpm = useReaperStore((s) => s.bpm);
  const positionBeats = useReaperStore((s) => s.positionBeats);
  const positionSeconds = useReaperStore((s) => s.positionSeconds);
  const { beatsPerBar, denominator } = useTimeSignature();

  return useMemo(() => {
    if (!bpm || !positionBeats || positionSeconds <= 0) return 0;

    // Get the bar number REAPER reports (e.g., "2.3.50" -> 2)
    const actualBar = parseReaperBar(positionBeats);

    // Calculate what bar we'd expect from just the seconds/BPM
    // BPM is in quarter notes, convert to denominator beats
    const quarterNoteBeats = secondsToBeats(positionSeconds, bpm);
    const denominatorBeats = quarterNoteBeats * (denominator / 4);

    // Round to nearest 16th note equivalent to avoid floating point issues
    const totalBeats = Math.round(denominatorBeats * 4) / 4;
    const calculatedBar = Math.floor(totalBeats / beatsPerBar) + 1;

    // The difference tells us where bar 1 actually is in the project
    return actualBar - calculatedBar;
  }, [bpm, positionBeats, positionSeconds, beatsPerBar, denominator]);
}
