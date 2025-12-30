/**
 * Tempo Map Utilities
 * Convert between time (seconds) and bar.beat positions using tempo markers
 */

import type { WSTempoMarker } from './WebSocketTypes';

export interface BarBeat {
  bar: number; // 1-based bar number (before bar offset applied)
  beat: number; // 1-based beat within bar
  ticks: number; // 0-99 (percentage through beat)
}

/**
 * Convert time in seconds to bar.beat position
 * Uses tempo markers to calculate position-aware bar/beat
 */
export function timeToBarBeat(
  timeSeconds: number,
  tempoMarkers: WSTempoMarker[],
  barOffset: number = 0
): BarBeat {
  // If no tempo markers or time is 0, use simple calculation
  if (tempoMarkers.length === 0) {
    // Default 120 BPM, 4/4 time
    const beatsPerSecond = 120 / 60;
    const totalBeats = timeSeconds * beatsPerSecond;
    const bar = Math.floor(totalBeats / 4) + 1;
    const beatInBar = (totalBeats % 4) + 1;
    const wholeBeat = Math.floor(beatInBar);
    const ticks = Math.round((beatInBar - Math.floor(beatInBar)) * 100);
    return { bar: bar + barOffset, beat: wholeBeat, ticks };
  }

  // Find which tempo segment we're in
  let totalBars = 0;
  let currentBpm = tempoMarkers[0].bpm;
  let currentNum = tempoMarkers[0].timesigNum;
  let currentDenom = tempoMarkers[0].timesigDenom;

  for (let i = 0; i < tempoMarkers.length; i++) {
    const marker = tempoMarkers[i];
    const nextMarker = tempoMarkers[i + 1];
    const segmentStart = marker.position;
    const segmentEnd = nextMarker ? nextMarker.position : Infinity;

    // Update tempo/time sig at this marker
    currentBpm = marker.bpm;
    currentNum = marker.timesigNum;
    currentDenom = marker.timesigDenom;

    if (timeSeconds < segmentEnd) {
      // Time falls within this segment
      const timeInSegment = timeSeconds - segmentStart;

      // Calculate beats in this segment
      // BPM is in quarter notes, adjust for time signature denominator
      const quarterNotesPerSecond = currentBpm / 60;
      const beatsPerSecond = quarterNotesPerSecond * (currentDenom / 4);
      const beatsInSegment = timeInSegment * beatsPerSecond;

      // Convert beats to bars
      const barsInSegment = beatsInSegment / currentNum;
      const wholeBars = Math.floor(barsInSegment);
      const fractionalBar = barsInSegment - wholeBars;

      // Convert fractional bar to beat.ticks
      const beatFloat = fractionalBar * currentNum + 1;
      const wholeBeat = Math.floor(beatFloat);
      const ticks = Math.round((beatFloat - wholeBeat) * 100);

      return {
        bar: totalBars + wholeBars + 1 + barOffset,
        beat: wholeBeat,
        ticks,
      };
    }

    // Calculate bars in this completed segment
    const segmentDuration = segmentEnd - segmentStart;
    const quarterNotesPerSecond = currentBpm / 60;
    const beatsPerSecond = quarterNotesPerSecond * (currentDenom / 4);
    const beatsInSegment = segmentDuration * beatsPerSecond;
    totalBars += beatsInSegment / currentNum;
  }

  // Shouldn't reach here, but return end of last segment
  return { bar: Math.floor(totalBars) + 1 + barOffset, beat: 1, ticks: 0 };
}

/**
 * Convert bar.beat position to time in seconds
 * Uses tempo markers to calculate position-aware time
 */
export function barBeatToTime(
  barBeat: BarBeat,
  tempoMarkers: WSTempoMarker[],
  barOffset: number = 0
): number {
  // Adjust bar for offset
  const targetBar = barBeat.bar - barOffset;
  const targetBeat = barBeat.beat;
  const targetTicks = barBeat.ticks;

  // If no tempo markers, use simple calculation
  if (tempoMarkers.length === 0) {
    // Default 120 BPM, 4/4 time
    const beatsPerSecond = 120 / 60;
    const totalBeats = (targetBar - 1) * 4 + (targetBeat - 1) + targetTicks / 100;
    return totalBeats / beatsPerSecond;
  }

  // Walk through tempo segments
  let currentTime = 0;
  let barsRemaining = targetBar - 1; // Bars to traverse (0-based)

  for (let i = 0; i < tempoMarkers.length; i++) {
    const marker = tempoMarkers[i];
    const nextMarker = tempoMarkers[i + 1];
    const segmentStart = marker.position;
    const segmentEnd = nextMarker ? nextMarker.position : Infinity;
    const segmentDuration = nextMarker ? segmentEnd - segmentStart : Infinity;

    const bpm = marker.bpm;
    const num = marker.timesigNum;
    const denom = marker.timesigDenom;

    // Calculate how many bars fit in this segment
    const quarterNotesPerSecond = bpm / 60;
    const beatsPerSecond = quarterNotesPerSecond * (denom / 4);
    const beatsInSegment = segmentDuration * beatsPerSecond;
    const barsInSegment = beatsInSegment / num;

    if (barsRemaining < barsInSegment || !nextMarker) {
      // Target bar is within this segment
      // Calculate time for remaining bars + beat + ticks
      const beatsToTraverse = barsRemaining * num + (targetBeat - 1) + targetTicks / 100;
      const timeOffset = beatsToTraverse / beatsPerSecond;
      return segmentStart + timeOffset;
    }

    // Move past this segment
    barsRemaining -= Math.floor(barsInSegment);
    currentTime = segmentEnd;
  }

  return currentTime;
}

/**
 * Parse a bar.beat.ticks string (e.g., "8.1.00") to BarBeat
 */
export function parseBarBeat(str: string): BarBeat | null {
  const parts = str.split('.');
  if (parts.length < 2 || parts.length > 3) return null;

  const bar = parseInt(parts[0], 10);
  const beat = parseInt(parts[1], 10);
  const ticks = parts.length === 3 ? parseInt(parts[2], 10) : 0;

  if (isNaN(bar) || isNaN(beat) || isNaN(ticks)) return null;

  return { bar, beat, ticks };
}

/**
 * Format BarBeat as string (e.g., "8.1.00")
 */
export function formatBarBeat(bb: BarBeat): string {
  return `${bb.bar}.${bb.beat}.${String(bb.ticks).padStart(2, '0')}`;
}
