/**
 * PianoKeyboard Component
 * Multi-octave piano keyboard with multi-touch support
 * Uses flex layout with black keys positioned relative to white key slots
 */

import { useState, useCallback, useRef, Fragment, type ReactElement } from 'react';
import { PianoKey } from './PianoKey';

export interface PianoKeyboardProps {
  /** Base octave (0-8, default 4 = middle C) */
  octave: number;
  /** Number of octaves to display (1-2) */
  numOctaves?: number;
  /** Callback when note starts */
  onNoteOn: (note: number, velocity: number) => void;
  /** Callback when note ends */
  onNoteOff: (note: number) => void;
  className?: string;
}

/**
 * Piano octave structure: white keys with optional black key overlays
 * Each entry: [whiteSemitone, blackSemitone | null]
 * Black key overlaps to the RIGHT of its white key slot
 */
const OCTAVE_STRUCTURE: [number, number | null][] = [
  [0, 1], // C with C#
  [2, 3], // D with D#
  [4, null], // E (no black key to right)
  [5, 6], // F with F#
  [7, 8], // G with G#
  [9, 10], // A with A#
  [11, null], // B (no black key to right)
];

export function PianoKeyboard({
  octave,
  numOctaves = 1,
  onNoteOn,
  onNoteOff,
  className = '',
}: PianoKeyboardProps): ReactElement {
  // Track which pointer is playing which note
  const pointerToNoteRef = useRef<Map<number, number>>(new Map());
  // Track active notes for visual feedback
  const [activeNotes, setActiveNotes] = useState<Set<number>>(new Set());

  const handleNoteOn = useCallback(
    (note: number, velocity: number, pointerId: number) => {
      // If this pointer was already playing a note, send note-off first
      const prevNote = pointerToNoteRef.current.get(pointerId);
      if (prevNote !== undefined && prevNote !== note) {
        onNoteOff(prevNote);
        setActiveNotes((prev) => {
          const next = new Set(prev);
          next.delete(prevNote);
          return next;
        });
      }

      pointerToNoteRef.current.set(pointerId, note);
      setActiveNotes((prev) => new Set(prev).add(note));
      onNoteOn(note, velocity);
    },
    [onNoteOn, onNoteOff]
  );

  const handleNoteOff = useCallback(
    (note: number, pointerId: number) => {
      const activeNote = pointerToNoteRef.current.get(pointerId);
      if (activeNote === note) {
        pointerToNoteRef.current.delete(pointerId);
        setActiveNotes((prev) => {
          const next = new Set(prev);
          next.delete(note);
          return next;
        });
        onNoteOff(note);
      }
    },
    [onNoteOff]
  );

  return (
    <div
      className={`flex w-full h-full overflow-visible ${className}`}
      role="group"
      aria-label="Piano keyboard"
    >
      {/* Render each octave */}
      {Array.from({ length: numOctaves }, (_, octIdx) => {
        const baseNote = (octave + octIdx) * 12;

        return (
          <Fragment key={octIdx}>
            {OCTAVE_STRUCTURE.map(([whiteSemitone, blackSemitone], slotIdx) => {
              const whiteNote = baseNote + whiteSemitone;
              const blackNote = blackSemitone !== null ? baseNote + blackSemitone : null;

              // Skip if note exceeds MIDI range
              if (whiteNote > 127) return null;

              return (
                <div key={slotIdx} className="flex-1 relative h-full overflow-visible">
                  {/* White key - fills the slot */}
                  <PianoKey
                    note={whiteNote}
                    isBlack={false}
                    isActive={activeNotes.has(whiteNote)}
                    onNoteOn={handleNoteOn}
                    onNoteOff={handleNoteOff}
                    className="w-full h-full rounded-b-md"
                  />

                  {/* Black key - overlaps to the right */}
                  {blackNote !== null && blackNote <= 127 && (
                    <PianoKey
                      note={blackNote}
                      isBlack={true}
                      isActive={activeNotes.has(blackNote)}
                      onNoteOn={handleNoteOn}
                      onNoteOff={handleNoteOff}
                      className="absolute top-0 rounded-b-md"
                      style={{
                        right: '-30%',
                        width: '60%',
                        height: '60%',
                        zIndex: 10,
                      }}
                    />
                  )}
                </div>
              );
            })}
          </Fragment>
        );
      })}
    </div>
  );
}
