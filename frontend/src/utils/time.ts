/**
 * Time/Beat Conversion and Formatting Utilities
 * Handles REAPER's high-precision floats (e.g., 13.333333333333314)
 */

// ============ CORE CONVERSIONS ============

/**
 * Convert seconds to beats
 * @example secondsToBeats(2, 120) => 4 (2 seconds at 120 BPM = 4 beats)
 */
export function secondsToBeats(seconds: number, bpm: number): number {
  return seconds * (bpm / 60);
}

/**
 * Convert beats to seconds
 * @example beatsToSeconds(4, 120) => 2 (4 beats at 120 BPM = 2 seconds)
 */
export function beatsToSeconds(beats: number, bpm: number): number {
  return beats * (60 / bpm);
}

// ============ FORMATTING ============

export interface FormatTimeOptions {
  /** Decimal precision: 1 (deciseconds), 2 (centiseconds), or 3 (milliseconds). Default: 2 */
  precision?: 1 | 2 | 3;
  /** Show +/- sign for negative times. Default: false */
  showSign?: boolean;
}

/**
 * Format seconds as MM:SS.xxx
 * Handles REAPER's high-precision floats by rounding to specified precision
 *
 * @example formatTime(83.333333) => "1:23.33"
 * @example formatTime(83.333333, { precision: 3 }) => "1:23.333"
 * @example formatTime(83.333333, { precision: 1 }) => "1:23.3"
 * @example formatTime(-5.5, { showSign: true }) => "-0:05.50"
 */
export function formatTime(seconds: number, options?: FormatTimeOptions): string {
  const precision = options?.precision ?? 2;
  const showSign = options?.showSign ?? false;

  const absSeconds = Math.abs(seconds);
  const sign = showSign && seconds < 0 ? '-' : '';

  const mins = Math.floor(absSeconds / 60);

  if (precision === 3) {
    // Millisecond precision (e.g., "1:23.456")
    // Use Math.round to handle floating point errors (e.g., 17.485 becomes 17.4849999... in JS)
    const secs = Math.floor(absSeconds % 60);
    const ms = Math.round((absSeconds % 1) * 1000);
    return `${sign}${mins}:${secs.toString().padStart(2, '0')}.${ms.toString().padStart(3, '0')}`;
  } else if (precision === 1) {
    // Decisecond precision (e.g., "1:23.4") - used for drag previews
    const secs = (absSeconds % 60).toFixed(1);
    return `${sign}${mins}:${secs.padStart(4, '0')}`;
  } else {
    // Centisecond precision (e.g., "1:23.45")
    const secs = (absSeconds % 60).toFixed(2);
    return `${sign}${mins}:${secs.padStart(5, '0')}`;
  }
}

/**
 * Format seconds as Bar.Beat.Ticks (e.g., "5.2.50")
 * Uses REAPER's ticks format (0-99 representing percentage of beat)
 *
 * @param seconds - Time in seconds (always >= 0)
 * @param bpm - Beats per minute (quarter-note BPM, normalized)
 * @param barOffset - REAPER's bar numbering offset (projects can start at bar -4, 1, etc.)
 * @param beatsPerBar - Time signature numerator (default: 4)
 * @param denominator - Time signature denominator (default: 4)
 */
export function formatBeats(
  seconds: number,
  bpm: number,
  barOffset: number,
  beatsPerBar: number = 4,
  denominator: number = 4
): string {
  // BPM is in quarter notes, convert to denominator beats for bar calculation
  const quarterNoteBeats = secondsToBeats(seconds, bpm);
  const denominatorBeats = quarterNoteBeats * (denominator / 4);
  // Round to nearest tick (1/100 of a beat)
  const totalBeats = Math.round(denominatorBeats * 100) / 100;
  const calculatedBar = Math.floor(totalBeats / beatsPerBar) + 1;
  const actualBar = calculatedBar + barOffset;
  const beat = Math.floor(totalBeats % beatsPerBar) + 1; // 1-based like REAPER
  const ticks = Math.round((totalBeats % 1) * 100); // 0-99 ticks like REAPER
  return `${actualBar}.${beat}.${ticks.toString().padStart(2, '0')}`;
}

/**
 * Format duration in human-readable bars/beats (e.g., "8 bars 2 beats")
 * Rounds to nearest 16th note to avoid floating point errors
 *
 * @param denominator - Time signature denominator (default: 4)
 */
export function formatDuration(
  seconds: number,
  bpm: number,
  beatsPerBar: number = 4,
  denominator: number = 4
): string {
  // BPM is in quarter notes, convert to denominator beats
  const quarterNoteBeats = secondsToBeats(seconds, bpm);
  const denominatorBeats = quarterNoteBeats * (denominator / 4);
  // Round to nearest 16th note equivalent
  const totalBeats = Math.round(denominatorBeats * 4) / 4;
  const bars = Math.floor(totalBeats / beatsPerBar);
  const beats = Math.round(totalBeats % beatsPerBar);

  if (bars > 0 && beats > 0) {
    return `${bars} bar${bars !== 1 ? 's' : ''} ${beats} beat${beats !== 1 ? 's' : ''}`;
  } else if (bars > 0) {
    return `${bars} bar${bars !== 1 ? 's' : ''}`;
  } else {
    return `${beats} beat${beats !== 1 ? 's' : ''}`;
  }
}

/**
 * Format a time delta with +/- sign (e.g., "+2 bars", "-1 beat")
 * Used for showing resize/move changes
 *
 * @param denominator - Time signature denominator (default: 4)
 */
export function formatDelta(
  deltaSeconds: number,
  bpm: number,
  beatsPerBar: number = 4,
  denominator: number = 4
): string {
  const sign = deltaSeconds >= 0 ? '+' : '-';
  const absSeconds = Math.abs(deltaSeconds);
  // BPM is in quarter notes, convert to denominator beats
  const quarterNoteBeats = secondsToBeats(absSeconds, bpm);
  const denominatorBeats = quarterNoteBeats * (denominator / 4);
  const totalBeats = Math.round(denominatorBeats * 4) / 4;
  const bars = Math.floor(totalBeats / beatsPerBar);
  const beats = Math.round(totalBeats % beatsPerBar);

  if (bars > 0 && beats > 0) {
    return `${sign}${bars}b ${beats}`;
  } else if (bars > 0) {
    return `${sign}${bars} bar${bars !== 1 ? 's' : ''}`;
  } else if (beats > 0) {
    return `${sign}${beats} beat${beats !== 1 ? 's' : ''}`;
  } else {
    return '0';
  }
}

// ============ PARSING ============

/**
 * Extract bar number from REAPER's position string
 * Format: "bar.beat.ticks" like "-4.1.00" or "56.2.45"
 * @example parseReaperBar("-4.1.00") => -4
 * @example parseReaperBar("56.2.45") => 56
 */
export function parseReaperBar(positionBeats: string): number {
  const parts = positionBeats.split('.');
  return parseInt(parts[0], 10);
}

/**
 * Parse bar.beat.ticks format to total beats from bar 1
 * This is a pure function for modal forms that work with beats directly.
 *
 * @param barOffset - REAPER's bar numbering offset (projects can start at bar -4, 1, 5, etc.). Default: 0
 * @example parseBarBeatTicksToBeats("1.1", 4) => 0 (bar 1 beat 1 = 0 beats from start)
 * @example parseBarBeatTicksToBeats("2.1", 4) => 4 (bar 2 beat 1 = 4 beats in 4/4)
 * @example parseBarBeatTicksToBeats("5.1", 4, 4) => 0 (bar 5 with offset 4 = 0 beats from start)
 * @returns total beats from bar 1, beat 1, or null if invalid
 */
export function parseBarBeatTicksToBeats(
  input: string,
  beatsPerBar: number = 4,
  barOffset: number = 0
): number | null {
  const trimmed = input.trim();
  if (!trimmed) return null;

  const parts = trimmed.split('.');
  const displayBar = parseInt(parts[0], 10);
  if (isNaN(displayBar)) return null;

  // Remove bar offset to get the internal bar number
  const bar = displayBar - barOffset;

  let beat = 1; // Default to beat 1
  let tickFraction = 0;

  if (parts.length >= 2 && parts[1] !== '') {
    beat = parseInt(parts[1], 10);
    if (isNaN(beat) || beat < 1 || beat > beatsPerBar) {
      beat = Math.max(1, Math.min(beatsPerBar, beat || 1));
    }
  }

  if (parts.length >= 3 && parts[2] !== '') {
    const ticks = parseInt(parts[2], 10);
    if (!isNaN(ticks)) {
      // Ticks are 0-99 representing percentage of beat
      tickFraction = Math.max(0, Math.min(99, ticks)) / 100;
    }
  }

  // Calculate total beats from bar 1 (bar 1, beat 1 = 0 beats)
  const totalBeats = (bar - 1) * beatsPerBar + (beat - 1) + tickFraction;
  return totalBeats;
}

/**
 * Format beats to bar.beat.ticks string
 * This is a pure function for modal forms that work with beats directly.
 * Handles floating point precision by rounding.
 *
 * @param includeBeat - If true, always include beat (e.g., "1.1"). If false, omit beat when at beat 1 (e.g., "1")
 * @param barOffset - REAPER's bar numbering offset (projects can start at bar -4, 1, 5, etc.). Default: 0
 * @example formatBeatsToBarBeatTicks(0, 4) => "1.1" (0 beats = bar 1, beat 1)
 * @example formatBeatsToBarBeatTicks(4, 4) => "2.1" (4 beats = bar 2 in 4/4)
 * @example formatBeatsToBarBeatTicks(0, 4, true, 4) => "5.1" (0 beats with offset 4 = bar 5)
 */
export function formatBeatsToBarBeatTicks(
  totalBeats: number,
  beatsPerBar: number = 4,
  includeBeat: boolean = true,
  barOffset: number = 0
): string {
  // Handle floating point precision - round very small negatives to 0
  const roundedBeats = Math.abs(totalBeats) < 0.001 ? 0 : totalBeats;
  // Round to avoid floating point issues
  const snappedBeats = Math.round(roundedBeats * 100) / 100;

  const calculatedBar = Math.floor(snappedBeats / beatsPerBar) + 1;
  const bar = calculatedBar + barOffset; // Apply bar offset for display
  const beatInBar = snappedBeats - Math.floor(snappedBeats / beatsPerBar) * beatsPerBar;
  const beat = Math.floor(beatInBar) + 1;
  const ticks = Math.round((beatInBar % 1) * 100);

  if (ticks > 0) {
    return `${bar}.${beat}.${ticks.toString().padStart(2, '0')}`;
  }
  if (includeBeat) {
    return `${bar}.${beat}`;
  }
  return `${bar}`;
}

/**
 * Parse Bar.Beat.Ticks input to seconds
 * Uses REAPER's ticks format (0-99 representing percentage of beat)
 * @param denominator - Time signature denominator (default: 4)
 * @returns seconds or null if invalid input
 */
export function parseBarBeatToSeconds(
  input: string,
  bpm: number,
  barOffset: number,
  beatsPerBar: number = 4,
  denominator: number = 4
): number | null {
  const parts = input.trim().split('.');
  if (parts.length < 2) return null;

  const bar = parseInt(parts[0], 10);
  const beat = parseInt(parts[1], 10);
  const ticks = parts.length > 2 ? parseInt(parts[2], 10) : 0;

  if (isNaN(bar) || isNaN(beat) || isNaN(ticks)) return null;
  if (beat < 1 || beat > beatsPerBar) return null;
  if (ticks < 0 || ticks > 99) return null;

  // Calculate denominator beats, then convert to quarter notes for beatsToSeconds
  const adjustedBar = bar - barOffset;
  const totalDenominatorBeats = (adjustedBar - 1) * beatsPerBar + (beat - 1) + ticks / 100;
  // Convert denominator beats to quarter notes (BPM is in quarter notes)
  const quarterNoteBeats = totalDenominatorBeats * (4 / denominator);
  return beatsToSeconds(quarterNoteBeats, bpm);
}

/**
 * Parse duration string to seconds
 * Formats: "8" = 8 bars, "8.2" = 8 bars 2 beats, "0.4" = 4 beats
 * Plain number = bars (most intuitive for music)
 * @param denominator - Time signature denominator (default: 4)
 * @returns seconds or null if invalid
 */
export function parseDurationToSeconds(
  input: string,
  bpm: number,
  beatsPerBar: number = 4,
  denominator: number = 4
): number | null {
  const trimmed = input.trim();

  // Check for "X.Y" format (bars.beats)
  const barBeatMatch = trimmed.match(/^(\d+)\.(\d+)$/);
  if (barBeatMatch) {
    const bars = parseInt(barBeatMatch[1], 10);
    const beats = parseInt(barBeatMatch[2], 10);
    if (beats > beatsPerBar) return null; // Invalid beat count
    // Total denominator beats, convert to quarter notes for beatsToSeconds
    const totalDenominatorBeats = bars * beatsPerBar + beats;
    const quarterNoteBeats = totalDenominatorBeats * (4 / denominator);
    return beatsToSeconds(quarterNoteBeats, bpm);
  }

  // Plain number = bars
  const barsMatch = trimmed.match(/^(\d+)$/);
  if (barsMatch) {
    const bars = parseInt(barsMatch[1], 10);
    // Total denominator beats, convert to quarter notes for beatsToSeconds
    const totalDenominatorBeats = bars * beatsPerBar;
    const quarterNoteBeats = totalDenominatorBeats * (4 / denominator);
    return beatsToSeconds(quarterNoteBeats, bpm);
  }

  return null;
}

// ============ SNAPPING ============

/**
 * Snap time to nearest grid subdivision
 * @param seconds Time in seconds
 * @param bpm Beats per minute
 * @param subdivisions Subdivisions per beat (4 = 16th notes, 2 = 8th notes, 1 = quarter notes). Default: 4
 */
export function snapToGrid(
  seconds: number,
  bpm: number,
  subdivisions: number = 4
): number {
  const beatsPerSecond = bpm / 60;
  const subbeatsPerSecond = beatsPerSecond * subdivisions;
  const subbeat = Math.round(seconds * subbeatsPerSecond);
  return subbeat / subbeatsPerSecond;
}
