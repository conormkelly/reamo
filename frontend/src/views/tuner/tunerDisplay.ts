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
 *
 * A reading no longer arriving (`stale`) shows nothing of it: no note, no
 * needle, no verdict. Nor does the time before the first event (`heard`).
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
  /** An event has come since subscribing */
  heard: boolean;
  /** No event has come for a while: the reading may no longer be true */
  stale: boolean;
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
  /** A stable reading's verdict */
  announcement: 'In tune' | 'Sharp' | 'Flat' | null;
  /**
   * What a screen reader is told: a problem, several notes, or a stable
   * reading's verdict; '' otherwise. Not the passing states (a note
   * starting, silence between notes), which come with every pluck.
   */
  spoken: string;
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
/** True whether the connection or REAPER's main thread has stalled. */
export const WAITING_TEXT = 'Waiting for REAPER…';

/** A stable reading this close (in cents) but not in tune shows as close; further, as off. */
const CLOSE_CENTS = 10;
/**
 * The backend's in-tune window (tuner_generator.zig), checked again on the
 * cents as the meter shows them, to the tenth: "+2.0¢" is never green.
 */
const IN_TUNE_CENTS = 2;

export function tunerDisplay(r: DisplayInput): TunerDisplay {
  const shown = looks(r);
  const passing = shown.message === STARTING_TEXT || shown.message === NO_INPUT_TEXT;
  return { ...shown, spoken: shown.message !== null && !passing ? shown.message : (shown.announcement ?? '') };
}

const NOTHING = { note: 'none', needle: 'hidden', announcement: null } as const;

function looks(r: DisplayInput): Omit<TunerDisplay, 'spoken'> {
  // REAPER's reason, from a refused subscribe or the last event, stays.
  if (r.problem) return { ...NOTHING, message: r.problem };
  if (r.stale) return { ...NOTHING, message: WAITING_TEXT };
  if (!r.heard) return { ...NOTHING, message: '' };

  const pitched = r.freq > 0;
  const message = r.deviceClosed
    ? DEVICE_CLOSED_TEXT
    : r.multiple
      ? SEVERAL_NOTES_TEXT
      : r.starting && !pitched
        ? STARTING_TEXT
        : pitched
          ? null
          : NO_INPUT_TEXT;

  if (!pitched) {
    const starting = r.starting && !r.deviceClosed;
    return { note: starting ? 'starting' : 'none', needle: 'hidden', message, announcement: null };
  }

  const toTuneBy = r.stable && !r.settling && !r.multiple;
  if (!toTuneBy) return { note: 'shown', needle: 'moving', message, announcement: null };

  const inTune = r.inTune && Math.abs(Math.round(r.cents * 10) / 10) < IN_TUNE_CENTS;
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
 * note, with cents from it, while the pitch is near the boundary with its
 * neighbour. Only a neighbour: a pitch near a note further off (a slide, a
 * legato change) is that note. Nothing is held across silence or from one
 * source to another.
 */
export function holdNote(
  held: HeldNote | null,
  source: string | null,
  r: NoteReading
): { held: HeldNote | null; noteName: string; octave: number; cents: number } {
  const shown = { noteName: r.noteName, octave: r.octave, cents: r.cents };
  if (!(r.freq > 0) || !r.noteName || source === null) return { held: null, ...shown };
  const own: HeldNote = { source, noteName: r.noteName, octave: r.octave, midiNote: r.note };
  if (!held || held.source !== source || Math.abs(r.note - held.midiNote) !== 1 || Math.abs(r.cents) < NOTE_SWITCH_CENTS) {
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
