/**
 * Scale Utilities Tests
 */

import { describe, it, expect } from 'vitest';
import {
  SCALE_BITMASKS,
  getScaleDegrees,
  transposeScale,
  isInScale,
  semitoneFromNoteName,
  noteNameFromSemitone,
  createScale,
  getScaleNotes,
  getScaleDegreeNote,
  countScaleNotes,
  spellNote,
  spellScale,
  getSpelledScaleDegree,
} from './scales';

describe('scales', () => {
  describe('SCALE_BITMASKS', () => {
    it('has 12 scale types defined', () => {
      expect(Object.keys(SCALE_BITMASKS)).toHaveLength(12);
    });

    it('all bitmasks are valid 12-bit values', () => {
      for (const [name, bitmask] of Object.entries(SCALE_BITMASKS)) {
        expect(bitmask, `${name} should be <= 0xFFF`).toBeLessThanOrEqual(0xfff);
        expect(bitmask, `${name} should be > 0`).toBeGreaterThan(0);
      }
    });
  });

  describe('getScaleDegrees', () => {
    it('returns correct degrees for major scale', () => {
      // Major: W-W-H-W-W-W-H = 0,2,4,5,7,9,11
      expect(getScaleDegrees(SCALE_BITMASKS.major)).toEqual([0, 2, 4, 5, 7, 9, 11]);
    });

    it('returns correct degrees for natural minor scale', () => {
      // Natural minor: W-H-W-W-H-W-W = 0,2,3,5,7,8,10
      expect(getScaleDegrees(SCALE_BITMASKS.natural_minor)).toEqual([0, 2, 3, 5, 7, 8, 10]);
    });

    it('returns correct degrees for dorian mode', () => {
      // Dorian: W-H-W-W-W-H-W = 0,2,3,5,7,9,10
      expect(getScaleDegrees(SCALE_BITMASKS.dorian)).toEqual([0, 2, 3, 5, 7, 9, 10]);
    });

    it('returns 7 notes for heptatonic scales', () => {
      expect(getScaleDegrees(SCALE_BITMASKS.major)).toHaveLength(7);
      expect(getScaleDegrees(SCALE_BITMASKS.natural_minor)).toHaveLength(7);
      expect(getScaleDegrees(SCALE_BITMASKS.harmonic_minor)).toHaveLength(7);
      expect(getScaleDegrees(SCALE_BITMASKS.melodic_minor)).toHaveLength(7);
      expect(getScaleDegrees(SCALE_BITMASKS.dorian)).toHaveLength(7);
      expect(getScaleDegrees(SCALE_BITMASKS.phrygian)).toHaveLength(7);
      expect(getScaleDegrees(SCALE_BITMASKS.lydian)).toHaveLength(7);
      expect(getScaleDegrees(SCALE_BITMASKS.mixolydian)).toHaveLength(7);
      expect(getScaleDegrees(SCALE_BITMASKS.locrian)).toHaveLength(7);
    });

    it('returns 5 notes for pentatonic scales', () => {
      expect(getScaleDegrees(SCALE_BITMASKS.pentatonic_major)).toHaveLength(5);
      expect(getScaleDegrees(SCALE_BITMASKS.pentatonic_minor)).toHaveLength(5);
    });

    it('returns 6 notes for blues scale', () => {
      expect(getScaleDegrees(SCALE_BITMASKS.blues)).toHaveLength(6);
    });

    it('returns empty array for zero bitmask', () => {
      expect(getScaleDegrees(0)).toEqual([]);
    });

    it('returns all 12 notes for chromatic (0xFFF)', () => {
      expect(getScaleDegrees(0xfff)).toEqual([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]);
    });
  });

  describe('transposeScale', () => {
    it('returns same bitmask for 0 semitones', () => {
      expect(transposeScale(SCALE_BITMASKS.major, 0)).toBe(SCALE_BITMASKS.major);
    });

    it('returns same bitmask for 12 semitones (octave)', () => {
      expect(transposeScale(SCALE_BITMASKS.major, 12)).toBe(SCALE_BITMASKS.major);
    });

    it('transposes C major to G major correctly', () => {
      const cMajor = SCALE_BITMASKS.major;
      const gMajor = transposeScale(cMajor, 7); // G is 7 semitones up from C

      const gMajorDegrees = getScaleDegrees(gMajor);
      // G major: G(7), A(9), B(11), C(0), D(2), E(4), F#(6)
      expect(gMajorDegrees).toContain(6); // F# is in G major
      expect(gMajorDegrees).not.toContain(5); // F is not in G major
    });

    it('transposes C major to F major correctly', () => {
      const cMajor = SCALE_BITMASKS.major;
      const fMajor = transposeScale(cMajor, 5); // F is 5 semitones up from C

      const fMajorDegrees = getScaleDegrees(fMajor);
      // F major: F(5), G(7), A(9), Bb(10), C(0), D(2), E(4)
      expect(fMajorDegrees).toContain(10); // Bb is in F major
      expect(fMajorDegrees).not.toContain(11); // B is not in F major
    });

    it('handles negative transposition', () => {
      const cMajor = SCALE_BITMASKS.major;
      const gMajor = transposeScale(cMajor, -5); // 5 down = 7 up
      const gMajorFromUp = transposeScale(cMajor, 7);
      expect(gMajor).toBe(gMajorFromUp);
    });

    it('handles large transposition values', () => {
      const cMajor = SCALE_BITMASKS.major;
      expect(transposeScale(cMajor, 24)).toBe(cMajor); // 2 octaves = same
      expect(transposeScale(cMajor, 25)).toBe(transposeScale(cMajor, 1));
    });
  });

  describe('isInScale', () => {
    it('correctly identifies notes in C major', () => {
      const cMajor = SCALE_BITMASKS.major;
      // C major: C(0), D(2), E(4), F(5), G(7), A(9), B(11)
      expect(isInScale(cMajor, 0)).toBe(true); // C
      expect(isInScale(cMajor, 2)).toBe(true); // D
      expect(isInScale(cMajor, 4)).toBe(true); // E
      expect(isInScale(cMajor, 5)).toBe(true); // F
      expect(isInScale(cMajor, 7)).toBe(true); // G
      expect(isInScale(cMajor, 9)).toBe(true); // A
      expect(isInScale(cMajor, 11)).toBe(true); // B
    });

    it('correctly identifies notes NOT in C major', () => {
      const cMajor = SCALE_BITMASKS.major;
      expect(isInScale(cMajor, 1)).toBe(false); // C#
      expect(isInScale(cMajor, 3)).toBe(false); // D#
      expect(isInScale(cMajor, 6)).toBe(false); // F#
      expect(isInScale(cMajor, 8)).toBe(false); // G#
      expect(isInScale(cMajor, 10)).toBe(false); // A#
    });

    it('handles negative semitones', () => {
      const cMajor = SCALE_BITMASKS.major;
      expect(isInScale(cMajor, -12)).toBe(true); // C (octave below)
      expect(isInScale(cMajor, -1)).toBe(true); // B (one below C)
    });

    it('handles semitones > 11', () => {
      const cMajor = SCALE_BITMASKS.major;
      expect(isInScale(cMajor, 12)).toBe(true); // C (octave above)
      expect(isInScale(cMajor, 14)).toBe(true); // D (octave above)
    });
  });

  describe('semitoneFromNoteName', () => {
    it('returns correct semitones for all notes', () => {
      expect(semitoneFromNoteName('C')).toBe(0);
      expect(semitoneFromNoteName('C#')).toBe(1);
      expect(semitoneFromNoteName('D')).toBe(2);
      expect(semitoneFromNoteName('D#')).toBe(3);
      expect(semitoneFromNoteName('E')).toBe(4);
      expect(semitoneFromNoteName('F')).toBe(5);
      expect(semitoneFromNoteName('F#')).toBe(6);
      expect(semitoneFromNoteName('G')).toBe(7);
      expect(semitoneFromNoteName('G#')).toBe(8);
      expect(semitoneFromNoteName('A')).toBe(9);
      expect(semitoneFromNoteName('A#')).toBe(10);
      expect(semitoneFromNoteName('B')).toBe(11);
    });
  });

  describe('noteNameFromSemitone', () => {
    it('returns correct note names for 0-11', () => {
      expect(noteNameFromSemitone(0)).toBe('C');
      expect(noteNameFromSemitone(1)).toBe('C#');
      expect(noteNameFromSemitone(2)).toBe('D');
      expect(noteNameFromSemitone(3)).toBe('D#');
      expect(noteNameFromSemitone(4)).toBe('E');
      expect(noteNameFromSemitone(5)).toBe('F');
      expect(noteNameFromSemitone(6)).toBe('F#');
      expect(noteNameFromSemitone(7)).toBe('G');
      expect(noteNameFromSemitone(8)).toBe('G#');
      expect(noteNameFromSemitone(9)).toBe('A');
      expect(noteNameFromSemitone(10)).toBe('A#');
      expect(noteNameFromSemitone(11)).toBe('B');
    });

    it('handles values > 11 (wraps around)', () => {
      expect(noteNameFromSemitone(12)).toBe('C');
      expect(noteNameFromSemitone(13)).toBe('C#');
      expect(noteNameFromSemitone(24)).toBe('C');
    });

    it('handles negative values', () => {
      expect(noteNameFromSemitone(-1)).toBe('B');
      expect(noteNameFromSemitone(-12)).toBe('C');
    });

    it('is inverse of semitoneFromNoteName', () => {
      for (let i = 0; i < 12; i++) {
        const name = noteNameFromSemitone(i);
        expect(semitoneFromNoteName(name)).toBe(i);
      }
    });
  });

  describe('createScale', () => {
    it('creates C major scale correctly', () => {
      const scale = createScale('C', 'major');
      expect(scale.root).toBe('C');
      expect(scale.type).toBe('major');
      expect(scale.degrees).toEqual([0, 2, 4, 5, 7, 9, 11]);
    });

    it('creates G major scale correctly', () => {
      const scale = createScale('G', 'major');
      expect(scale.root).toBe('G');
      expect(scale.type).toBe('major');
      // G major: G(7), A(9), B(11), C(0), D(2), E(4), F#(6)
      expect(scale.degrees.sort((a, b) => a - b)).toEqual([0, 2, 4, 6, 7, 9, 11]);
    });

    it('creates A natural minor scale correctly', () => {
      const scale = createScale('A', 'natural_minor');
      expect(scale.root).toBe('A');
      expect(scale.type).toBe('natural_minor');
      // A minor: A(9), B(11), C(0), D(2), E(4), F(5), G(7)
      expect(scale.degrees.sort((a, b) => a - b)).toEqual([0, 2, 4, 5, 7, 9, 11]);
    });

    it('creates D dorian scale correctly', () => {
      const scale = createScale('D', 'dorian');
      expect(scale.root).toBe('D');
      expect(scale.type).toBe('dorian');
      // D dorian: D(2), E(4), F(5), G(7), A(9), B(11), C(0)
      expect(scale.degrees.sort((a, b) => a - b)).toEqual([0, 2, 4, 5, 7, 9, 11]);
    });
  });

  describe('getScaleNotes', () => {
    it('returns note names for C major', () => {
      const scale = createScale('C', 'major');
      const notes = getScaleNotes(scale);
      expect(notes).toEqual(['C', 'D', 'E', 'F', 'G', 'A', 'B']);
    });

    it('returns note names for G major', () => {
      const scale = createScale('G', 'major');
      const notes = getScaleNotes(scale);
      // Sorted by semitone, not scale degree
      expect(notes.sort()).toEqual(['A', 'B', 'C', 'D', 'E', 'F#', 'G'].sort());
    });
  });

  describe('getScaleDegreeNote', () => {
    it('returns correct notes for C major scale degrees', () => {
      const scale = createScale('C', 'major');
      expect(getScaleDegreeNote(scale, 1)).toBe('C'); // Root
      expect(getScaleDegreeNote(scale, 2)).toBe('D'); // 2nd
      expect(getScaleDegreeNote(scale, 3)).toBe('E'); // 3rd
      expect(getScaleDegreeNote(scale, 4)).toBe('F'); // 4th
      expect(getScaleDegreeNote(scale, 5)).toBe('G'); // 5th
      expect(getScaleDegreeNote(scale, 6)).toBe('A'); // 6th
      expect(getScaleDegreeNote(scale, 7)).toBe('B'); // 7th
    });

    it('returns correct notes for G major scale degrees', () => {
      const scale = createScale('G', 'major');
      expect(getScaleDegreeNote(scale, 1)).toBe('G'); // Root
      expect(getScaleDegreeNote(scale, 2)).toBe('A'); // 2nd
      expect(getScaleDegreeNote(scale, 3)).toBe('B'); // 3rd
      expect(getScaleDegreeNote(scale, 4)).toBe('C'); // 4th
      expect(getScaleDegreeNote(scale, 5)).toBe('D'); // 5th
      expect(getScaleDegreeNote(scale, 6)).toBe('E'); // 6th
      expect(getScaleDegreeNote(scale, 7)).toBe('F#'); // 7th
    });

    it('returns undefined for out of range degrees', () => {
      const scale = createScale('C', 'major');
      expect(getScaleDegreeNote(scale, 0)).toBeUndefined();
      expect(getScaleDegreeNote(scale, 8)).toBeUndefined();
      expect(getScaleDegreeNote(scale, -1)).toBeUndefined();
    });

    it('handles pentatonic scales (5 degrees)', () => {
      const scale = createScale('C', 'pentatonic_major');
      expect(getScaleDegreeNote(scale, 1)).toBe('C');
      expect(getScaleDegreeNote(scale, 5)).toBe('A');
      expect(getScaleDegreeNote(scale, 6)).toBeUndefined();
    });
  });

  describe('countScaleNotes', () => {
    it('counts 7 for heptatonic scales', () => {
      expect(countScaleNotes(SCALE_BITMASKS.major)).toBe(7);
      expect(countScaleNotes(SCALE_BITMASKS.natural_minor)).toBe(7);
    });

    it('counts 5 for pentatonic scales', () => {
      expect(countScaleNotes(SCALE_BITMASKS.pentatonic_major)).toBe(5);
      expect(countScaleNotes(SCALE_BITMASKS.pentatonic_minor)).toBe(5);
    });

    it('counts 6 for blues scale', () => {
      expect(countScaleNotes(SCALE_BITMASKS.blues)).toBe(6);
    });

    it('counts 0 for empty bitmask', () => {
      expect(countScaleNotes(0)).toBe(0);
    });

    it('counts 12 for chromatic', () => {
      expect(countScaleNotes(0xfff)).toBe(12);
    });
  });

  describe('spellNote', () => {
    it('spells natural notes correctly', () => {
      expect(spellNote('C', 0).display).toBe('C');
      expect(spellNote('D', 2).display).toBe('D');
      expect(spellNote('E', 4).display).toBe('E');
      expect(spellNote('F', 5).display).toBe('F');
      expect(spellNote('G', 7).display).toBe('G');
      expect(spellNote('A', 9).display).toBe('A');
      expect(spellNote('B', 11).display).toBe('B');
    });

    it('spells sharp notes correctly', () => {
      expect(spellNote('C', 1).display).toBe('C#');
      expect(spellNote('D', 3).display).toBe('D#');
      expect(spellNote('F', 6).display).toBe('F#');
      expect(spellNote('G', 8).display).toBe('G#');
      expect(spellNote('A', 10).display).toBe('A#');
    });

    it('spells flat notes correctly', () => {
      expect(spellNote('D', 1).display).toBe('Db');
      expect(spellNote('E', 3).display).toBe('Eb');
      expect(spellNote('G', 6).display).toBe('Gb');
      expect(spellNote('A', 8).display).toBe('Ab');
      expect(spellNote('B', 10).display).toBe('Bb');
    });

    it('returns correct semitone values', () => {
      expect(spellNote('E', 3).semitone).toBe(3);
      expect(spellNote('B', 10).semitone).toBe(10);
    });

    it('returns correct letter and accidental', () => {
      const eb = spellNote('E', 3);
      expect(eb.letter).toBe('E');
      expect(eb.accidental).toBe('b');
    });
  });

  describe('spellScale', () => {
    it('spells C major with all natural notes', () => {
      const spelled = spellScale('C', 'major');
      expect(spelled.map((n) => n.display)).toEqual(['C', 'D', 'E', 'F', 'G', 'A', 'B']);
    });

    it('spells C dorian with Eb and Bb (not D# and A#)', () => {
      const spelled = spellScale('C', 'dorian');
      // C Dorian: C, D, Eb, F, G, A, Bb
      expect(spelled.map((n) => n.display)).toEqual(['C', 'D', 'Eb', 'F', 'G', 'A', 'Bb']);
    });

    it('spells C natural minor with Eb, Ab, Bb', () => {
      const spelled = spellScale('C', 'natural_minor');
      // C minor: C, D, Eb, F, G, Ab, Bb
      expect(spelled.map((n) => n.display)).toEqual(['C', 'D', 'Eb', 'F', 'G', 'Ab', 'Bb']);
    });

    it('spells G major with F#', () => {
      const spelled = spellScale('G', 'major');
      // G major: G, A, B, C, D, E, F#
      expect(spelled.map((n) => n.display)).toEqual(['G', 'A', 'B', 'C', 'D', 'E', 'F#']);
    });

    it('spells F major with Bb', () => {
      const spelled = spellScale('F', 'major');
      // F major: F, G, A, Bb, C, D, E
      expect(spelled.map((n) => n.display)).toEqual(['F', 'G', 'A', 'Bb', 'C', 'D', 'E']);
    });

    it('spells D major with F# and C#', () => {
      const spelled = spellScale('D', 'major');
      // D major: D, E, F#, G, A, B, C#
      expect(spelled.map((n) => n.display)).toEqual(['D', 'E', 'F#', 'G', 'A', 'B', 'C#']);
    });

    it('ensures unique letters in each scale', () => {
      // Every heptatonic scale should use each letter exactly once
      const scales: Array<{ root: 'C' | 'G' | 'D' | 'F'; type: 'major' | 'natural_minor' | 'dorian' }> = [
        { root: 'C', type: 'major' },
        { root: 'G', type: 'major' },
        { root: 'D', type: 'major' },
        { root: 'F', type: 'major' },
        { root: 'C', type: 'natural_minor' },
        { root: 'C', type: 'dorian' },
      ];

      for (const { root, type } of scales) {
        const spelled = spellScale(root, type);
        const letters = spelled.map((n) => n.letter);
        const uniqueLetters = new Set(letters);
        expect(uniqueLetters.size, `${root} ${type} should have 7 unique letters`).toBe(7);
      }
    });

    it('uses enharmonic equivalents for D# (spells as Eb major)', () => {
      const spelled = spellScale('D#', 'major');
      // D# major should use Eb spelling: Eb, F, G, Ab, Bb, C, D
      expect(spelled.map((n) => n.display)).toEqual(['Eb', 'F', 'G', 'Ab', 'Bb', 'C', 'D']);
    });

    it('uses enharmonic equivalents for G# (spells as Ab major)', () => {
      const spelled = spellScale('G#', 'major');
      // G# major should use Ab spelling: Ab, Bb, C, Db, Eb, F, G
      expect(spelled.map((n) => n.display)).toEqual(['Ab', 'Bb', 'C', 'Db', 'Eb', 'F', 'G']);
    });

    it('uses enharmonic equivalents for A# (spells as Bb major)', () => {
      const spelled = spellScale('A#', 'major');
      // A# major should use Bb spelling: Bb, C, D, Eb, F, G, A
      expect(spelled.map((n) => n.display)).toEqual(['Bb', 'C', 'D', 'Eb', 'F', 'G', 'A']);
    });

    it('uses enharmonic equivalents for C# (spells as Db major)', () => {
      const spelled = spellScale('C#', 'major');
      // C# major should use Db spelling: Db, Eb, F, Gb, Ab, Bb, C
      expect(spelled.map((n) => n.display)).toEqual(['Db', 'Eb', 'F', 'Gb', 'Ab', 'Bb', 'C']);
    });

    it('keeps F# as F# (not Gb) since both have 6 accidentals', () => {
      const spelled = spellScale('F#', 'major');
      // F# major: F#, G#, A#, B, C#, D#, E#
      expect(spelled[0].display).toBe('F#');
      expect(spelled[6].display).toBe('E#'); // Not F
    });
  });

  describe('getSpelledScaleDegree', () => {
    it('returns correct spelled note for C dorian 3rd degree', () => {
      const note = getSpelledScaleDegree('C', 'dorian', 3);
      expect(note?.display).toBe('Eb');
    });

    it('returns correct spelled note for C dorian 7th degree', () => {
      const note = getSpelledScaleDegree('C', 'dorian', 7);
      expect(note?.display).toBe('Bb');
    });

    it('returns undefined for out of range degrees', () => {
      expect(getSpelledScaleDegree('C', 'major', 0)).toBeUndefined();
      expect(getSpelledScaleDegree('C', 'major', 8)).toBeUndefined();
    });
  });
});
