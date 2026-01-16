/**
 * Chord Generation Tests
 */

import { describe, it, expect } from 'vitest';
import {
  detectChordQuality,
  getRomanNumeral,
  intervalsToMidi,
  buildDiatonicChord,
  generateDiatonicChords,
  generateChordsForKey,
} from './chords';
import { createScale } from './scales';

describe('chords', () => {
  describe('detectChordQuality', () => {
    describe('triads', () => {
      it('detects major triad (0,4,7)', () => {
        expect(detectChordQuality([0, 4, 7])).toBe('major');
      });

      it('detects minor triad (0,3,7)', () => {
        expect(detectChordQuality([0, 3, 7])).toBe('minor');
      });

      it('detects diminished triad (0,3,6)', () => {
        expect(detectChordQuality([0, 3, 6])).toBe('diminished');
      });

      it('detects augmented triad (0,4,8)', () => {
        expect(detectChordQuality([0, 4, 8])).toBe('augmented');
      });

      it('handles unordered intervals', () => {
        expect(detectChordQuality([7, 0, 4])).toBe('major');
        expect(detectChordQuality([7, 3, 0])).toBe('minor');
      });
    });

    describe('7th chords', () => {
      it('detects major 7th (0,4,7,11)', () => {
        expect(detectChordQuality([0, 4, 7, 11])).toBe('major7');
      });

      it('detects minor 7th (0,3,7,10)', () => {
        expect(detectChordQuality([0, 3, 7, 10])).toBe('minor7');
      });

      it('detects dominant 7th (0,4,7,10)', () => {
        expect(detectChordQuality([0, 4, 7, 10])).toBe('dominant7');
      });

      it('detects diminished 7th (0,3,6,9)', () => {
        expect(detectChordQuality([0, 3, 6, 9])).toBe('diminished7');
      });

      it('detects half-diminished 7th (0,3,6,10)', () => {
        expect(detectChordQuality([0, 3, 6, 10])).toBe('half_diminished7');
      });
    });
  });

  describe('getRomanNumeral', () => {
    it('returns uppercase for major chords', () => {
      expect(getRomanNumeral(1, 'major')).toBe('I');
      expect(getRomanNumeral(4, 'major')).toBe('IV');
      expect(getRomanNumeral(5, 'major')).toBe('V');
    });

    it('returns lowercase for minor chords', () => {
      expect(getRomanNumeral(2, 'minor')).toBe('ii');
      expect(getRomanNumeral(3, 'minor')).toBe('iii');
      expect(getRomanNumeral(6, 'minor')).toBe('vi');
    });

    it('returns lowercase with degree symbol for diminished', () => {
      expect(getRomanNumeral(7, 'diminished')).toBe('vii°');
    });

    it('returns uppercase with plus for augmented', () => {
      expect(getRomanNumeral(3, 'augmented')).toBe('III+');
    });

    it('handles 7th chord notations', () => {
      expect(getRomanNumeral(1, 'major7')).toBe('IM7');
      expect(getRomanNumeral(2, 'minor7')).toBe('ii7');
      expect(getRomanNumeral(5, 'dominant7')).toBe('V7');
      expect(getRomanNumeral(7, 'half_diminished7')).toBe('viiø7');
    });
  });

  describe('intervalsToMidi', () => {
    it('converts C major triad at octave 3 to correct MIDI notes', () => {
      // C3 = MIDI 48
      const midiNotes = intervalsToMidi('C', [0, 4, 7], 3);
      expect(midiNotes).toEqual([48, 52, 55]); // C3, E3, G3
    });

    it('converts C major triad at octave 4 (middle C) to correct MIDI notes', () => {
      // C4 = MIDI 60
      const midiNotes = intervalsToMidi('C', [0, 4, 7], 4);
      expect(midiNotes).toEqual([60, 64, 67]); // C4, E4, G4
    });

    it('converts G major triad at octave 3 to correct MIDI notes', () => {
      // G3 = MIDI 55
      const midiNotes = intervalsToMidi('G', [0, 4, 7], 3);
      expect(midiNotes).toEqual([55, 59, 62]); // G3, B3, D4
    });

    it('handles 7th chord intervals', () => {
      // C major 7th at octave 3
      const midiNotes = intervalsToMidi('C', [0, 4, 7, 11], 3);
      expect(midiNotes).toEqual([48, 52, 55, 59]); // C3, E3, G3, B3
    });

    it('handles different root notes', () => {
      // F major at octave 3 (F3 = MIDI 53)
      const midiNotes = intervalsToMidi('F', [0, 4, 7], 3);
      expect(midiNotes).toEqual([53, 57, 60]); // F3, A3, C4
    });
  });

  describe('buildDiatonicChord', () => {
    it('builds C major I chord correctly', () => {
      const scale = createScale('C', 'major');
      const chord = buildDiatonicChord(scale, 1);

      expect(chord.root).toBe('C');
      expect(chord.quality).toBe('major');
      expect(chord.displayName).toBe('C');
      expect(chord.romanNumeral).toBe('I');
      expect(chord.intervals).toEqual([0, 4, 7]);
      expect(chord.degree).toBe(1);
    });

    it('builds C major ii chord correctly (D minor)', () => {
      const scale = createScale('C', 'major');
      const chord = buildDiatonicChord(scale, 2);

      expect(chord.root).toBe('D');
      expect(chord.quality).toBe('minor');
      expect(chord.displayName).toBe('Dm');
      expect(chord.romanNumeral).toBe('ii');
      expect(chord.intervals).toEqual([0, 3, 7]);
      expect(chord.degree).toBe(2);
    });

    it('builds C major iii chord correctly (E minor)', () => {
      const scale = createScale('C', 'major');
      const chord = buildDiatonicChord(scale, 3);

      expect(chord.root).toBe('E');
      expect(chord.quality).toBe('minor');
      expect(chord.displayName).toBe('Em');
      expect(chord.romanNumeral).toBe('iii');
    });

    it('builds C major IV chord correctly (F major)', () => {
      const scale = createScale('C', 'major');
      const chord = buildDiatonicChord(scale, 4);

      expect(chord.root).toBe('F');
      expect(chord.quality).toBe('major');
      expect(chord.displayName).toBe('F');
      expect(chord.romanNumeral).toBe('IV');
    });

    it('builds C major V chord correctly (G major)', () => {
      const scale = createScale('C', 'major');
      const chord = buildDiatonicChord(scale, 5);

      expect(chord.root).toBe('G');
      expect(chord.quality).toBe('major');
      expect(chord.displayName).toBe('G');
      expect(chord.romanNumeral).toBe('V');
    });

    it('builds C major vi chord correctly (A minor)', () => {
      const scale = createScale('C', 'major');
      const chord = buildDiatonicChord(scale, 6);

      expect(chord.root).toBe('A');
      expect(chord.quality).toBe('minor');
      expect(chord.displayName).toBe('Am');
      expect(chord.romanNumeral).toBe('vi');
    });

    it('builds C major vii° chord correctly (B diminished)', () => {
      const scale = createScale('C', 'major');
      const chord = buildDiatonicChord(scale, 7);

      expect(chord.root).toBe('B');
      expect(chord.quality).toBe('diminished');
      expect(chord.displayName).toBe('Bdim');
      expect(chord.romanNumeral).toBe('vii°');
      expect(chord.intervals).toEqual([0, 3, 6]);
    });

    it('builds 7th chords when include7th is true', () => {
      const scale = createScale('C', 'major');
      const chord = buildDiatonicChord(scale, 1, true);

      expect(chord.intervals).toHaveLength(4);
      expect(chord.quality).toBe('major7');
    });

    it('throws error for invalid degree', () => {
      const scale = createScale('C', 'major');
      expect(() => buildDiatonicChord(scale, 0)).toThrow();
      expect(() => buildDiatonicChord(scale, 8)).toThrow();
    });

    it('generates correct MIDI notes at specified octave', () => {
      const scale = createScale('C', 'major');
      const chord = buildDiatonicChord(scale, 1, false, 4);

      // C4 major = MIDI 60, 64, 67
      expect(chord.midiNotes).toEqual([60, 64, 67]);
    });
  });

  describe('generateDiatonicChords', () => {
    it('generates 7 chords for C major', () => {
      const scale = createScale('C', 'major');
      const chords = generateDiatonicChords(scale);

      expect(chords).toHaveLength(7);
    });

    it('generates correct chord progression for C major', () => {
      const scale = createScale('C', 'major');
      const chords = generateDiatonicChords(scale);

      expect(chords[0].displayName).toBe('C');
      expect(chords[1].displayName).toBe('Dm');
      expect(chords[2].displayName).toBe('Em');
      expect(chords[3].displayName).toBe('F');
      expect(chords[4].displayName).toBe('G');
      expect(chords[5].displayName).toBe('Am');
      expect(chords[6].displayName).toBe('Bdim');
    });

    it('generates correct chord qualities for major scale', () => {
      const scale = createScale('C', 'major');
      const chords = generateDiatonicChords(scale);

      expect(chords[0].quality).toBe('major'); // I
      expect(chords[1].quality).toBe('minor'); // ii
      expect(chords[2].quality).toBe('minor'); // iii
      expect(chords[3].quality).toBe('major'); // IV
      expect(chords[4].quality).toBe('major'); // V
      expect(chords[5].quality).toBe('minor'); // vi
      expect(chords[6].quality).toBe('diminished'); // vii°
    });

    it('generates correct chord progression for G major', () => {
      const scale = createScale('G', 'major');
      const chords = generateDiatonicChords(scale);

      expect(chords[0].displayName).toBe('G');
      expect(chords[1].displayName).toBe('Am');
      expect(chords[2].displayName).toBe('Bm');
      expect(chords[3].displayName).toBe('C');
      expect(chords[4].displayName).toBe('D');
      expect(chords[5].displayName).toBe('Em');
      expect(chords[6].displayName).toBe('F#dim');
    });

    it('generates correct chord progression for A minor', () => {
      const scale = createScale('A', 'natural_minor');
      const chords = generateDiatonicChords(scale);

      expect(chords[0].displayName).toBe('Am');
      expect(chords[1].displayName).toBe('Bdim');
      expect(chords[2].displayName).toBe('C');
      expect(chords[3].displayName).toBe('Dm');
      expect(chords[4].displayName).toBe('Em');
      expect(chords[5].displayName).toBe('F');
      expect(chords[6].displayName).toBe('G');
    });

    it('generates correct chord qualities for natural minor', () => {
      const scale = createScale('A', 'natural_minor');
      const chords = generateDiatonicChords(scale);

      expect(chords[0].quality).toBe('minor'); // i
      expect(chords[1].quality).toBe('diminished'); // ii°
      expect(chords[2].quality).toBe('major'); // III
      expect(chords[3].quality).toBe('minor'); // iv
      expect(chords[4].quality).toBe('minor'); // v
      expect(chords[5].quality).toBe('major'); // VI
      expect(chords[6].quality).toBe('major'); // VII
    });

    it('generates 7th chords when requested', () => {
      const scale = createScale('C', 'major');
      const chords = generateDiatonicChords(scale, true);

      expect(chords[0].quality).toBe('major7'); // Imaj7
      expect(chords[1].quality).toBe('minor7'); // ii7
      expect(chords[4].quality).toBe('dominant7'); // V7
    });

    it('handles dorian mode', () => {
      const scale = createScale('D', 'dorian');
      const chords = generateDiatonicChords(scale);

      expect(chords[0].quality).toBe('minor'); // i
      expect(chords[3].quality).toBe('major'); // IV (characteristic of Dorian)
    });
  });

  describe('generateChordsForKey', () => {
    it('is a convenience wrapper for createScale + generateDiatonicChords', () => {
      const chordsViaHelper = generateChordsForKey('C', 'major');
      const scale = createScale('C', 'major');
      const chordsViaDirect = generateDiatonicChords(scale);

      expect(chordsViaHelper).toHaveLength(chordsViaDirect.length);
      expect(chordsViaHelper[0].displayName).toBe(chordsViaDirect[0].displayName);
      expect(chordsViaHelper[6].displayName).toBe(chordsViaDirect[6].displayName);
    });

    it('passes through include7th parameter', () => {
      const chords = generateChordsForKey('C', 'major', true);
      expect(chords[0].intervals).toHaveLength(4);
    });

    it('passes through octave parameter', () => {
      const chords = generateChordsForKey('C', 'major', false, 4);
      expect(chords[0].midiNotes[0]).toBe(60); // C4
    });
  });

  describe('edge cases', () => {
    it('handles all 12 keys for major scale', () => {
      const keys = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'] as const;

      for (const key of keys) {
        const chords = generateChordsForKey(key, 'major');
        expect(chords).toHaveLength(7);
        expect(chords[0].root).toBe(key);
        expect(chords[0].quality).toBe('major');
      }
    });

    it('generates consistent MIDI note spacing', () => {
      const chords = generateChordsForKey('C', 'major', false, 3);

      // All triads should have notes spanning roughly an octave
      for (const chord of chords) {
        const span = chord.midiNotes[2] - chord.midiNotes[0];
        expect(span).toBeGreaterThanOrEqual(6); // Diminished = 6
        expect(span).toBeLessThanOrEqual(8); // Augmented = 8
      }
    });
  });
});
