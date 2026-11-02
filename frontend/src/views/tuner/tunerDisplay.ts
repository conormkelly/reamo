/**
 * What the tuner screen shows for a reading, from the analyser's flags.
 *
 * The rule the screen keeps: green ("in tune") only for a reading that is
 * `stable` (the pitch has held still: the reading to tune by), inside the
 * backend's in-tune window (a pitch and |cents| < 2, `inTune`), with one
 * note sounding. Any other reading with a pitch shows its note and a grey
 * needle, as the cents are still moving.
 *
 * - starting: a note has begun but the analyser holds its name back for its
 *   first ~0.1 s (a wrong octave, even briefly, is worse): the note area is
 *   dimmed with no name, and there is no needle, as there is no pitch.
 * - settling: the note's attack; its name is known, the cents not yet.
 * - multiple: several notes sound; the reading, if any, is one of them.
 */

export interface DisplayInput {
  /** Hz, 0 for no pitch */
  freq: number;
  /** Cents from the note shown (after holdNote) */
  cents: number;
  /** The backend's in-tune window */
  inTune: boolean;
  starting: boolean;
  settling: boolean;
  stable: boolean;
  multiple: boolean;
  /** Why the chosen source can't be tuned, as REAPER says it */
  problem: string | null;
  /** REAPER's audio device isn't running */
  deviceClosed: boolean;
}

/** How the note shows: no note, a note on its way (dimmed, no name), a note, a note in tune. */
export type NoteLook = 'none' | 'starting' | 'shown' | 'inTune';

/** The needle: none (no pitch), grey (the pitch is moving), or a stable reading's colour. */
export type NeedleTone = 'hidden' | 'moving' | 'inTune' | 'close' | 'off';

export interface TunerDisplay {
  note: NoteLook;
  needle: NeedleTone;
  /** Shown in place of the frequency; null to show the frequency */
  message: string | null;
  /** For screen readers: changes only when a stable reading's verdict does */
  announcement: 'In tune' | 'Sharp' | 'Flat' | null;
}

/**
 * What shows while REAPER's audio device isn't running: true whether REAPER
 * closed it while stopped (its preferences can say to; play reopens it) or
 * the device failed or was unplugged, which REAPER doesn't tell apart.
 */
export const DEVICE_CLOSED_TEXT = "REAPER's audio device isn't running. If it closes when stopped, press play.";
export const SEVERAL_NOTES_TEXT = 'Several notes — let one string ring';
export const STARTING_TEXT = 'Hearing a note…';
export const NO_INPUT_TEXT = 'No input detected';

/** A stable reading this close (in cents) but not in tune shows as close; further, as off. */
const CLOSE_CENTS = 10;
/** The backend's in-tune window (tuner_generator.zig), checked again on the cents shown. */
const IN_TUNE_CENTS = 2;

export function tunerDisplay(r: DisplayInput): TunerDisplay {
  const pitched = r.freq > 0;
  const message = r.problem
    ? r.problem
    : r.deviceClosed
      ? DEVICE_CLOSED_TEXT
      : r.multiple
        ? SEVERAL_NOTES_TEXT
        : r.starting && !pitched
          ? STARTING_TEXT
          : pitched
            ? null
            : NO_INPUT_TEXT;

  if (!pitched) {
    const starting = r.starting && !r.problem && !r.deviceClosed;
    return { note: starting ? 'starting' : 'none', needle: 'hidden', message, announcement: null };
  }

  const toTuneBy = r.stable && !r.settling && !r.multiple;
  if (!toTuneBy) return { note: 'shown', needle: 'moving', message, announcement: null };

  const inTune = r.inTune && Math.abs(r.cents) < IN_TUNE_CENTS;
  if (inTune) return { note: 'inTune', needle: 'inTune', message, announcement: 'In tune' };
  return {
    note: 'shown',
    needle: Math.abs(r.cents) < CLOSE_CENTS ? 'close' : 'off',
    message,
    announcement: r.cents > 0 ? 'Sharp' : 'Flat',
  };
}

/** The note the screen last showed, for one source. */
export interface HeldNote {
  source: string;
  noteName: string;
  octave: number;
  /** MIDI note number */
  midiNote: number;
}

export interface NoteReading {
  freq: number;
  /** MIDI note number */
  note: number;
  noteName: string;
  octave: number;
  cents: number;
}

/**
 * Only move to another note once the pitch is within this many cents of
 * it. The analyser names the note nearest its smoothed pitch, with no
 * hysteresis at the ±50 cent boundary (its name hold only keeps a new
 * note's name back at the onset), so a string tuned about a quarter tone
 * off would otherwise swap names, and the needle ends, many times a second.
 */
const NOTE_SWITCH_CENTS = 40;

/**
 * The note to show for a reading, given the one shown before: the same
 * note, with cents from it, until the pitch is clearly another's. Nothing
 * is held across silence or from one source to another.
 */
export function holdNote(
  held: HeldNote | null,
  source: string | null,
  r: NoteReading
): { held: HeldNote | null; noteName: string; octave: number; cents: number } {
  const shown = { noteName: r.noteName, octave: r.octave, cents: r.cents };
  if (!(r.freq > 0) || !r.noteName || source === null) return { held: null, ...shown };
  const own: HeldNote = { source, noteName: r.noteName, octave: r.octave, midiNote: r.note };
  if (!held || held.source !== source || held.midiNote === r.note || Math.abs(r.cents) < NOTE_SWITCH_CENTS) {
    return { held: own, ...shown };
  }
  // Cents from the held note: the pitch in semitones, less the held note.
  return {
    held,
    noteName: held.noteName,
    octave: held.octave,
    cents: (r.note + r.cents / 100 - held.midiNote) * 100,
  };
}
