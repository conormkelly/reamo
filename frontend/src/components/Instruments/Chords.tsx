/**
 * Chords Component (Chord Pads)
 * Container for 7 diatonic chord columns
 * Landscape orientation recommended - columns arranged horizontally
 */

import { useState, useMemo, useCallback, useRef, type ReactElement } from 'react';
import {
  generateChordsForKey,
  findClosestVoicing,
  type NoteName,
  type ScaleType,
  type Chord,
} from '@/lib/music-theory';
import { ChordColumn } from './ChordColumn';

/**
 * Common chord progressions by degree (1-indexed)
 * Maps from current chord degree to commonly following degrees
 */
const COMMON_PROGRESSIONS: Record<number, number[]> = {
  1: [4, 5, 6],     // I → IV, V, vi
  2: [5, 4],        // ii → V, IV
  3: [6, 4],        // iii → vi, IV
  4: [5, 1, 2],     // IV → V, I, ii
  5: [1, 6],        // V → I, vi
  6: [4, 2, 5],     // vi → IV, ii, V
  7: [1, 3],        // vii° → I, iii
};

export interface ChordsProps {
  /** MIDI channel (0-15) */
  channel: number;
  /** Callback to send note on */
  onNoteOn: (channel: number, note: number, velocity: number) => void;
  /** Root key (C, D, E, etc.) */
  rootKey: NoteName;
  /** Scale type (major, minor, etc.) */
  scaleType: ScaleType;
  /** Chord octave */
  octave: number;
  /** Show progression hints */
  showHints: boolean;
  /** Enable adaptive voicing (voice leading) */
  adaptiveVoicing: boolean;
  /** Enable strum mode */
  strumEnabled: boolean;
  /** Strum delay in ms */
  strumDelay: number;
  className?: string;
}

export function Chords({
  channel,
  onNoteOn,
  rootKey,
  scaleType,
  octave,
  showHints,
  adaptiveVoicing,
  strumEnabled,
  strumDelay,
  className = '',
}: ChordsProps): ReactElement {
  // Internal state
  const lastVoicingRef = useRef<number[]>([]);
  const currentNotesRef = useRef<number[]>([]); // Notes currently sounding (for correct note-off)

  // Track currently active chord for hints
  const [activeChord, setActiveChord] = useState<Chord | null>(null);

  // Calculate suggested next chords based on active chord
  const suggestedDegrees = useMemo(() => {
    if (!activeChord || !showHints) return new Set<number>();
    return new Set(COMMON_PROGRESSIONS[activeChord.degree] || []);
  }, [activeChord, showHints]);

  // Generate chords when key/scale/octave changes
  const chords = useMemo(
    () => generateChordsForKey(rootKey, scaleType, false, octave),
    [rootKey, scaleType, octave]
  );

  // Bass octave is one below chord octave
  const bassOctave = octave - 1;

  // Handle chord note on - send all notes in the chord (with optional strum and adaptive voicing)
  const handleChordNoteOn = useCallback(
    (notes: number[], velocity: number, chord: Chord) => {
      setActiveChord(chord);

      // Determine which notes to play (adaptive voicing or root position)
      let notesToPlay = notes;
      if (adaptiveVoicing && lastVoicingRef.current.length > 0) {
        notesToPlay = findClosestVoicing(notes, lastVoicingRef.current);
      }

      // Store the notes we're playing for correct note-off
      currentNotesRef.current = notesToPlay;
      lastVoicingRef.current = notesToPlay;

      if (strumEnabled && strumDelay > 0) {
        // Strum mode: play notes with delay (low to high = upstroke)
        const sortedNotes = [...notesToPlay].sort((a, b) => a - b);
        sortedNotes.forEach((note, index) => {
          setTimeout(() => {
            onNoteOn(channel, note, velocity);
          }, index * strumDelay);
        });
      } else {
        // Normal mode: play all notes simultaneously
        for (const note of notesToPlay) {
          onNoteOn(channel, note, velocity);
        }
      }
    },
    [channel, onNoteOn, strumEnabled, strumDelay, adaptiveVoicing]
  );

  // Handle chord note off - send velocity 0 for all notes that were played
  const handleChordNoteOff = useCallback(
    (_notes: number[]) => {
      setActiveChord(null);
      // Use the notes that were actually played (may be inverted)
      for (const note of currentNotesRef.current) {
        onNoteOn(channel, note, 0);
      }
      currentNotesRef.current = [];
    },
    [channel, onNoteOn]
  );

  // Handle bass note on
  const handleBassNoteOn = useCallback(
    (note: number, velocity: number) => {
      onNoteOn(channel, note, velocity);
    },
    [channel, onNoteOn]
  );

  // Handle bass note off
  const handleBassNoteOff = useCallback(
    (note: number) => {
      onNoteOn(channel, note, 0);
    },
    [channel, onNoteOn]
  );

  return (
    <div
      className={`flex flex-row gap-2 p-3 overflow-hidden ${className}`}
      role="group"
      aria-label="Chord Pads"
    >
      {chords.map((chord) => (
        <ChordColumn
          key={`${chord.degree}-${chord.root}`}
          chord={chord}
          bassOctave={bassOctave}
          onNoteOn={handleChordNoteOn}
          onNoteOff={handleChordNoteOff}
          onBassNoteOn={handleBassNoteOn}
          onBassNoteOff={handleBassNoteOff}
          isActive={activeChord?.degree === chord.degree}
          isSuggestedNext={suggestedDegrees.has(chord.degree)}
          className="flex-1 min-w-0 h-full"
        />
      ))}
    </div>
  );
}
