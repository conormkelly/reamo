/**
 * DrumPad Component
 * Individual drum pad with pointer event handling and visual feedback
 * Uses Pointer Events API for unified touch/mouse handling
 */

import { useState, useCallback, useRef, type ReactElement, type PointerEvent } from 'react';

export interface DrumPadProps {
  /** MIDI note number (0-127) */
  note: number;
  /** Display label for the pad */
  label: string;
  /** Callback when note is triggered */
  onNoteOn: (note: number, velocity: number) => void;
  /** Optional custom background color */
  color?: string;
  className?: string;
}

/** Default velocity for MVP (0-127) */
const DEFAULT_VELOCITY = 100;

/** Minimum ms between triggers to debounce */
const DEBOUNCE_MS = 20;

export function DrumPad({
  note,
  label,
  onNoteOn,
  color,
  className = '',
}: DrumPadProps): ReactElement {
  const [isActive, setIsActive] = useState(false);
  // Track last trigger time to debounce
  const lastTriggerRef = useRef<number>(0);

  // Handle pointer down - trigger note on (only event we care about for drums)
  const handlePointerDown = useCallback(
    (e: PointerEvent) => {
      e.preventDefault();
      e.stopPropagation();

      // Debounce: ignore if triggered too recently
      const now = Date.now();
      if (now - lastTriggerRef.current < DEBOUNCE_MS) {
        return;
      }
      lastTriggerRef.current = now;

      setIsActive(true);
      onNoteOn(note, DEFAULT_VELOCITY);
    },
    [note, onNoteOn]
  );

  // Handle pointer up - just clear visual state (no MIDI for drums)
  const handlePointerUp = useCallback(() => {
    setIsActive(false);
  }, []);

  return (
    <button
      type="button"
      className={`
        relative flex items-center justify-center
        rounded-lg border-2 border-border-subtle
        text-text-primary font-medium text-sm
        select-none touch-none
        transition-transform duration-75
        ${isActive ? 'scale-95 brightness-125' : 'hover:brightness-110'}
        ${className}
      `}
      style={{
        backgroundColor: color || 'var(--color-bg-elevated)',
        borderColor: isActive ? 'var(--color-primary)' : undefined,
      }}
      onPointerDown={handlePointerDown}
      onPointerUp={handlePointerUp}
      onPointerCancel={handlePointerUp}
      onPointerLeave={handlePointerUp}
      aria-label={`${label} (MIDI note ${note})`}
    >
      <span className="truncate px-1">{label}</span>
    </button>
  );
}
