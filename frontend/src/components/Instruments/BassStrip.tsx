/**
 * BassStrip Component
 * Vertical strip with Root, 5th, and Octave bass notes
 * Notes are based on the currently active chord's root
 */

import { useState, useCallback, type ReactElement, type PointerEvent } from 'react';

/** Velocity range for X-position mapping */
const MIN_VELOCITY = 30;
const MAX_VELOCITY = 127;

/** Bass note types */
type BassNoteType = 'root' | 'fifth' | 'octave';

/** Intervals from root for each bass note type */
const BASS_INTERVALS: Record<BassNoteType, number> = {
  root: 0,
  fifth: 7,
  octave: 12,
};

/** Display labels for bass notes */
const BASS_LABELS: Record<BassNoteType, string> = {
  root: 'Root',
  fifth: '5th',
  octave: '8va',
};

export interface BassStripProps {
  /** Root MIDI note number (in bass octave) */
  rootNote: number;
  /** Callback when note should sound */
  onNoteOn: (note: number, velocity: number) => void;
  /** Callback when note should stop */
  onNoteOff: (note: number) => void;
  /** Whether bass strip is enabled (has an active chord) */
  enabled?: boolean;
  /** Minimum velocity (left edge) */
  minVelocity?: number;
  /** Maximum velocity (right edge) */
  maxVelocity?: number;
  className?: string;
}

/**
 * Calculate velocity from X position within element
 */
function calculateVelocityFromX(
  clientX: number,
  rect: DOMRect,
  minVel: number,
  maxVel: number
): number {
  const relativeX = Math.max(0, Math.min(1, (clientX - rect.left) / rect.width));
  const velocity = Math.round(minVel + relativeX * (maxVel - minVel));
  return Math.max(1, Math.min(127, velocity));
}

interface BassButtonProps {
  noteType: BassNoteType;
  midiNote: number;
  onNoteOn: (note: number, velocity: number) => void;
  onNoteOff: (note: number) => void;
  enabled: boolean;
  minVelocity: number;
  maxVelocity: number;
}

function BassButton({
  noteType,
  midiNote,
  onNoteOn,
  onNoteOff,
  enabled,
  minVelocity,
  maxVelocity,
}: BassButtonProps): ReactElement {
  const [isActive, setIsActive] = useState(false);
  const [lastVelocity, setLastVelocity] = useState<number | null>(null);

  const handlePointerDown = useCallback(
    (e: PointerEvent) => {
      if (!enabled) return;

      e.preventDefault();
      e.stopPropagation();

      const target = e.currentTarget as HTMLElement;
      const rect = target.getBoundingClientRect();
      const velocity = calculateVelocityFromX(e.clientX, rect, minVelocity, maxVelocity);

      target.setPointerCapture(e.pointerId);

      setIsActive(true);
      setLastVelocity(velocity);
      onNoteOn(midiNote, velocity);
    },
    [enabled, midiNote, minVelocity, maxVelocity, onNoteOn]
  );

  const handlePointerUp = useCallback(
    (e: PointerEvent) => {
      e.preventDefault();
      (e.currentTarget as HTMLElement).releasePointerCapture(e.pointerId);

      setIsActive(false);
      setLastVelocity(null);
      if (enabled) {
        onNoteOff(midiNote);
      }
    },
    [enabled, midiNote, onNoteOff]
  );

  const handlePointerCancel = useCallback(
    (e: PointerEvent) => {
      (e.currentTarget as HTMLElement).releasePointerCapture(e.pointerId);
      setIsActive(false);
      setLastVelocity(null);
      if (enabled) {
        onNoteOff(midiNote);
      }
    },
    [enabled, midiNote, onNoteOff]
  );

  return (
    <button
      type="button"
      className={`
        relative flex-1 flex items-center justify-center
        rounded-lg text-white font-medium
        select-none touch-none
        transition-all duration-75
        ${enabled ? 'bg-amber-800' : 'bg-gray-700 opacity-50'}
        ${isActive && enabled ? 'brightness-125 scale-[0.98]' : enabled ? 'hover:brightness-110' : ''}
      `}
      onPointerDown={handlePointerDown}
      onPointerUp={handlePointerUp}
      onPointerCancel={handlePointerCancel}
      aria-label={`Bass ${BASS_LABELS[noteType]}`}
      aria-pressed={isActive}
      disabled={!enabled}
    >
      <span className="text-sm font-bold">{BASS_LABELS[noteType]}</span>

      {isActive && lastVelocity !== null && (
        <span className="absolute bottom-1 text-xs opacity-60">{lastVelocity}</span>
      )}

      {/* Subtle gradient for velocity hint */}
      <div
        className="absolute inset-0 rounded-lg pointer-events-none opacity-20"
        style={{
          background: 'linear-gradient(to right, rgba(0,0,0,0.3), rgba(255,255,255,0.1))',
        }}
      />
    </button>
  );
}

export function BassStrip({
  rootNote,
  onNoteOn,
  onNoteOff,
  enabled = true,
  minVelocity = MIN_VELOCITY,
  maxVelocity = MAX_VELOCITY,
  className = '',
}: BassStripProps): ReactElement {
  const bassNoteTypes: BassNoteType[] = ['root', 'fifth', 'octave'];

  return (
    <div
      className={`flex flex-col gap-1 ${className}`}
      role="group"
      aria-label="Bass strip"
    >
      {bassNoteTypes.map((noteType) => (
        <BassButton
          key={noteType}
          noteType={noteType}
          midiNote={rootNote + BASS_INTERVALS[noteType]}
          onNoteOn={onNoteOn}
          onNoteOff={onNoteOff}
          enabled={enabled}
          minVelocity={minVelocity}
          maxVelocity={maxVelocity}
        />
      ))}
    </div>
  );
}
