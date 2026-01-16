/**
 * PianoKey Component
 * Individual piano key with note-on/note-off handling
 * Uses Pointer Events API for unified touch/mouse handling
 */

import { useCallback, useRef, type ReactElement, type PointerEvent } from 'react';

export interface PianoKeyProps {
  /** MIDI note number (0-127) */
  note: number;
  /** Whether this is a black key */
  isBlack: boolean;
  /** Callback when note starts (pointer down) */
  onNoteOn: (note: number, velocity: number, pointerId: number) => void;
  /** Callback when note ends (pointer up) */
  onNoteOff: (note: number, pointerId: number) => void;
  /** Whether this key is currently active */
  isActive?: boolean;
  className?: string;
  /** Custom inline styles (for positioning black keys) */
  style?: React.CSSProperties;
}

/** Default velocity for piano keys */
const DEFAULT_VELOCITY = 100;

export function PianoKey({
  note,
  isBlack,
  onNoteOn,
  onNoteOff,
  isActive = false,
  className = '',
  style,
}: PianoKeyProps): ReactElement {
  const elementRef = useRef<HTMLButtonElement>(null);

  const handlePointerDown = useCallback(
    (e: PointerEvent) => {
      e.preventDefault();
      e.stopPropagation();
      // Capture pointer for this element to receive all events
      elementRef.current?.setPointerCapture(e.pointerId);
      onNoteOn(note, DEFAULT_VELOCITY, e.pointerId);
    },
    [note, onNoteOn]
  );

  const handlePointerUp = useCallback(
    (e: PointerEvent) => {
      elementRef.current?.releasePointerCapture(e.pointerId);
      onNoteOff(note, e.pointerId);
    },
    [note, onNoteOff]
  );

  const handlePointerCancel = useCallback(
    (e: PointerEvent) => {
      onNoteOff(note, e.pointerId);
    },
    [note, onNoteOff]
  );

  return (
    <button
      ref={elementRef}
      type="button"
      className={`
        touch-none select-none
        transition-colors duration-75
        ${
          isBlack
            ? `${isActive ? 'bg-primary' : 'bg-gray-900 hover:bg-gray-800'}`
            : `${isActive ? 'bg-blue-200' : 'bg-white hover:bg-gray-100'} border border-gray-300`
        }
        ${className}
      `}
      style={style}
      onPointerDown={handlePointerDown}
      onPointerUp={handlePointerUp}
      onPointerCancel={handlePointerCancel}
      onPointerLeave={handlePointerUp}
      aria-label={`Piano key MIDI note ${note}`}
    />
  );
}
