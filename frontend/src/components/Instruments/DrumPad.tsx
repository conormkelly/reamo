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
const DEBOUNCE_MS = 10; // Reduced from 20ms for better responsiveness

// Debug logging for touch issues
const DEBUG_TOUCH = true;

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
      const timeSinceLast = now - lastTriggerRef.current;

      if (timeSinceLast < DEBOUNCE_MS) {
        if (DEBUG_TOUCH) {
          console.log(`[DrumPad ${label}] BLOCKED: ${timeSinceLast}ms since last (debounce=${DEBOUNCE_MS}ms)`);
        }
        return;
      }

      if (DEBUG_TOUCH) {
        console.log(`[DrumPad ${label}] TRIGGERED: pointerType=${e.pointerType}, timeSinceLast=${timeSinceLast}ms`);
      }

      lastTriggerRef.current = now;

      // Send MIDI first, then update visual state (prioritize responsiveness)
      onNoteOn(note, DEFAULT_VELOCITY);
      setIsActive(true);
    },
    [note, onNoteOn, label]
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
      onContextMenu={(e) => e.preventDefault()}
      aria-label={`${label} (MIDI note ${note})`}
    >
      <span className="truncate px-1">{label}</span>
    </button>
  );
}
