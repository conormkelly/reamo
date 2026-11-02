/**
 * tunerDisplay: what each of the analyser's flags lets the screen show, and
 * that green, "in tune", needs a stable reading inside the in-tune window.
 */

import { describe, it, expect } from 'vitest';
import { tunerDisplay, holdNote, type DisplayInput, type HeldNote } from './tunerDisplay';

function reading(overrides: Partial<DisplayInput> = {}): DisplayInput {
  return {
    freq: 82.41,
    cents: 0.5,
    inTune: true,
    starting: false,
    settling: false,
    stable: true,
    multiple: false,
    problem: null,
    deviceClosed: false,
    ...overrides,
  };
}

const SILENCE: Partial<DisplayInput> = { freq: 0, cents: 0, inTune: false, stable: false };

describe('tunerDisplay', () => {
  it('shows green, note and needle, for a stable reading in the in-tune window', () => {
    const d = tunerDisplay(reading());
    expect(d.note).toBe('inTune');
    expect(d.needle).toBe('inTune');
    expect(d.message).toBeNull();
    expect(d.announcement).toBe('In tune');
  });

  // Each case below differs from the green one above by one thing.
  it.each<[string, Partial<DisplayInput>]>([
    ['the backend says in tune but the pitch has not held still', { stable: false }],
    ['the note is in its attack, even if also flagged stable', { settling: true }],
    ['the shown cents are inside the window but the backend says out of tune', { inTune: false, cents: 1 }],
    ['several notes sound', { multiple: true }],
    ['the reading is stable but outside the window', { inTune: false, cents: 3 }],
    ['the backend window says in tune but the shown cents are a held note’s', { cents: 45 }],
    ['there is no pitch', { freq: 0 }],
    ['the cents round to the 2.0 shown at the window’s edge', { cents: 1.96 }],
  ])('never shows green when %s', (_why, overrides) => {
    const d = tunerDisplay(reading(overrides));
    expect(d.note).not.toBe('inTune');
    expect(d.needle).not.toBe('inTune');
    expect(d.announcement).not.toBe('In tune');
  });

  it('shows no needle and a dimmed note while a note is starting (its name not known yet)', () => {
    const d = tunerDisplay(reading({ ...SILENCE, starting: true }));
    expect(d.note).toBe('starting');
    expect(d.needle).toBe('hidden');
    expect(d.message).toBe('Hearing a note…');
  });

  it('shows the note solid and the needle grey while the note settles, whatever its cents', () => {
    for (const cents of [0.5, -7, 30]) {
      const d = tunerDisplay(reading({ settling: true, stable: false, cents, inTune: Math.abs(cents) < 2 }));
      expect(d.note).toBe('shown');
      expect(d.needle).toBe('moving');
      expect(d.announcement).toBeNull();
    }
  });

  it('keeps the needle grey for a pitch that is moving after the attack (a peg turning)', () => {
    const d = tunerDisplay(reading({ stable: false, inTune: false, cents: -12 }));
    expect(d.note).toBe('shown');
    expect(d.needle).toBe('moving');
  });

  it('colours a stable needle by how far off it is: close under 10 cents, off from 10', () => {
    expect(tunerDisplay(reading({ inTune: false, cents: 2 })).needle).toBe('close');
    expect(tunerDisplay(reading({ inTune: false, cents: -9.9 })).needle).toBe('close');
    expect(tunerDisplay(reading({ inTune: false, cents: 10 })).needle).toBe('off');
    expect(tunerDisplay(reading({ inTune: false, cents: -31 })).needle).toBe('off');
    expect(tunerDisplay(reading({ inTune: false, cents: 2 })).note).toBe('shown');
  });

  it('says sharp or flat for a stable reading out of tune', () => {
    expect(tunerDisplay(reading({ inTune: false, cents: 6 })).announcement).toBe('Sharp');
    expect(tunerDisplay(reading({ inTune: false, cents: -6 })).announcement).toBe('Flat');
  });

  it('asks for one string when several notes sound, with or without a pitch', () => {
    for (const freq of [0, 82.41]) {
      const d = tunerDisplay(reading({ freq, multiple: true }));
      expect(d.message).toBe('Several notes — let one string ring');
      expect(d.needle).toBe(freq > 0 ? 'moving' : 'hidden');
      expect(d.announcement).toBeNull();
    }
  });

  it('shows no note or needle with no pitch, and says so', () => {
    const d = tunerDisplay(reading(SILENCE));
    expect(d.note).toBe('none');
    expect(d.needle).toBe('hidden');
    expect(d.message).toBe('No input detected');
  });

  it('tells a screen reader problems, several notes and a stable verdict, never the passing states', () => {
    expect(tunerDisplay(reading()).spoken).toBe('In tune');
    expect(tunerDisplay(reading({ inTune: false, cents: -6 })).spoken).toBe('Flat');
    expect(tunerDisplay(reading({ stable: false })).spoken).toBe('');
    expect(tunerDisplay(reading({ ...SILENCE, starting: true })).spoken).toBe('');
    expect(tunerDisplay(reading(SILENCE)).spoken).toBe('');
    expect(tunerDisplay(reading({ multiple: true })).spoken).toBe('Several notes — let one string ring');
    expect(tunerDisplay(reading({ ...SILENCE, problem: 'No record input.' })).spoken).toBe('No record input.');
    expect(tunerDisplay(reading({ ...SILENCE, deviceClosed: true })).spoken).toBe(
      "REAPER's audio device isn't running. If it closes when stopped, press play."
    );
  });

  it("puts why the tuner can't hear before anything a reading says", () => {
    expect(tunerDisplay(reading({ ...SILENCE, problem: 'No record input.', multiple: true })).message).toBe(
      'No record input.'
    );
    expect(tunerDisplay(reading({ ...SILENCE, deviceClosed: true, starting: true })).message).toBe(
      "REAPER's audio device isn't running. If it closes when stopped, press play."
    );
    expect(tunerDisplay(reading({ ...SILENCE, deviceClosed: true })).note).toBe('none');
  });
});

describe('holdNote', () => {
  const E2 = { freq: 82.41, note: 40, noteName: 'E', octave: 2, cents: 0 };
  // 49 cents over E2, read as F2 -51 → F2 at -49 after rounding
  const F2_LOW = { freq: 84.7, note: 41, noteName: 'F', octave: 2, cents: -49 };
  const F2 = { freq: 87.31, note: 41, noteName: 'F', octave: 2, cents: -10 };

  function after(held: HeldNote | null, source: string, r: typeof E2) {
    return holdNote(held, source, r);
  }

  it('keeps the note shown across the boundary, with cents from it, until the pitch is well inside the next', () => {
    const first = after(null, 'A', E2);
    const atBoundary = after(first.held, 'A', F2_LOW);
    expect(atBoundary.noteName).toBe('E');
    expect(atBoundary.octave).toBe(2);
    expect(atBoundary.cents).toBeCloseTo(51);
    const inside = after(atBoundary.held, 'A', F2);
    expect(inside.noteName).toBe('F');
    expect(inside.cents).toBe(-10);
  });

  it('holds only across the boundary to a neighbouring note, never onto a note further off', () => {
    const first = after(null, 'A', E2);
    // G2 at -45 cents: a slide of three semitones, not E2 +255
    const g2 = after(first.held, 'A', { freq: 95.5, note: 43, noteName: 'G', octave: 2, cents: -45 });
    expect(g2.noteName).toBe('G');
    expect(g2.cents).toBe(-45);
    // D#2 at +45 cents, below: a neighbour, so E2 -55 is held
    const below = after(first.held, 'A', { freq: 79.9, note: 39, noteName: 'D#', octave: 2, cents: 45 });
    expect(below.noteName).toBe('E');
    expect(below.cents).toBeCloseTo(-55);
  });

  it('holds nothing across silence', () => {
    const first = after(null, 'A', E2);
    const silent = after(first.held, 'A', { ...E2, freq: 0 });
    expect(silent.held).toBeNull();
    expect(after(silent.held, 'A', F2_LOW).noteName).toBe('F');
  });

  it("never holds one source's note on another", () => {
    const first = after(null, 'A', E2);
    const other = after(first.held, 'master', F2_LOW);
    expect(other.noteName).toBe('F');
    expect(other.cents).toBe(-49);
  });
});
