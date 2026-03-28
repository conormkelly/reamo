/**
 * Chords Component (Chord Pads)
 * Container for 7 diatonic chord columns
 * Landscape orientation recommended - columns arranged horizontally
 */

import { useMemo, useCallback, useRef, type ReactElement } from 'react';
import {
  generateChordsForKey,
  findClosestVoicing,
  type NoteName,
  type ScaleType,
  type Chord,
} from '@/lib/music-theory';
import { ChordColumn } from './ChordColumn';

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
  /** Enable adaptive voicing (voice leading) */
  adaptiveVoicing: boolean;
  /** Enable strum mode */
  strumEnabled: boolean;
  /** Strum delay in ms */
  strumDelay: number;
  /** Optional subset of chord indices to display (for pagination) */
  visibleChords?: number[];
  /** Fixed number of column slots (for consistent sizing across pages) */
  columnSlots?: number;
  className?: string;
}

export function Chords({
  channel,
  onNoteOn,
  rootKey,
  scaleType,
  octave,
  adaptiveVoicing,
  strumEnabled,
  strumDelay,
  visibleChords,
  columnSlots,
  className = '',
}: ChordsProps): ReactElement {
  // Internal state
  const lastVoicingRef = useRef<number[]>([]);
  const currentNotesRef = useRef<number[]>([]); // Notes currently sounding (for correct note-off)

  // Generate chords when key/scale/octave changes
  const chords = useMemo(
    () => generateChordsForKey(rootKey, scaleType, false, octave),
    [rootKey, scaleType, octave]
  );

  // Filter to visible chords if specified
  const displayChords = visibleChords
    ? visibleChords.map((i) => chords[i]).filter(Boolean)
    : chords;

  // Bass octave is one below chord octave
  const bassOctave = octave - 1;

  // Handle chord note on - send all notes in the chord (with optional strum and adaptive voicing)
  const handleChordNoteOn = useCallback(
    (notes: number[], velocity: number, _chord: Chord) => {
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

  // When columnSlots is set, each column gets a fixed fraction of width
  // so columns are identical size across pages even if last page has fewer
  const slotStyle = columnSlots
    ? { width: `calc((100% - ${(columnSlots - 1) * 8}px) / ${columnSlots})` }
    : undefined;

  return (
    <div
      className={`flex flex-row gap-2 p-3 overflow-hidden ${className}`}
      role="group"
      aria-label="Chord Pads"
    >
      {displayChords.map((chord) => (
        <ChordColumn
          key={`${chord.degree}-${chord.root}`}
          chord={chord}
          bassOctave={bassOctave}
          onNoteOn={handleChordNoteOn}
          onNoteOff={handleChordNoteOff}
          onBassNoteOn={handleBassNoteOn}
          onBassNoteOff={handleBassNoteOff}
          className={columnSlots ? 'shrink-0 h-full' : 'flex-1 min-w-0 h-full'}
          style={slotStyle}
        />
      ))}
    </div>
  );
}
