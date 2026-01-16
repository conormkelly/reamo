/**
 * ChordStrip Component
 * Individual vertical chord strip with touch handling
 * Sends all chord notes on press, releases on lift
 */

import { useState, useCallback, type ReactElement, type PointerEvent } from 'react';
import type { Chord } from '@/lib/music-theory';

export interface ChordStripProps {
  /** Chord data with MIDI notes and display info */
  chord: Chord;
  /** Callback when chord notes should sound */
  onNoteOn: (notes: number[], velocity: number) => void;
  /** Callback when chord notes should stop */
  onNoteOff: (notes: number[]) => void;
  /** Fixed velocity for all notes */
  velocity: number;
  /** Whether this strip is currently active */
  isActive?: boolean;
  className?: string;
}

/** Color mappings by chord quality */
const QUALITY_COLORS: Record<string, string> = {
  major: 'bg-blue-700',
  minor: 'bg-purple-700',
  diminished: 'bg-red-800',
  augmented: 'bg-orange-700',
  major7: 'bg-blue-600',
  minor7: 'bg-purple-600',
  dominant7: 'bg-amber-700',
  diminished7: 'bg-red-700',
  half_diminished7: 'bg-rose-800',
};

export function ChordStrip({
  chord,
  onNoteOn,
  onNoteOff,
  velocity,
  isActive: externalIsActive,
  className = '',
}: ChordStripProps): ReactElement {
  const [internalIsActive, setInternalIsActive] = useState(false);
  const isActive = externalIsActive ?? internalIsActive;

  const handlePointerDown = useCallback(
    (e: PointerEvent) => {
      e.preventDefault();
      e.stopPropagation();

      // Capture pointer for reliable release detection
      (e.target as HTMLElement).setPointerCapture(e.pointerId);

      setInternalIsActive(true);
      onNoteOn(chord.midiNotes, velocity);
    },
    [chord.midiNotes, velocity, onNoteOn]
  );

  const handlePointerUp = useCallback(
    (e: PointerEvent) => {
      e.preventDefault();

      // Release pointer capture
      (e.target as HTMLElement).releasePointerCapture(e.pointerId);

      setInternalIsActive(false);
      onNoteOff(chord.midiNotes);
    },
    [chord.midiNotes, onNoteOff]
  );

  const handlePointerCancel = useCallback(
    (e: PointerEvent) => {
      (e.target as HTMLElement).releasePointerCapture(e.pointerId);
      setInternalIsActive(false);
      onNoteOff(chord.midiNotes);
    },
    [chord.midiNotes, onNoteOff]
  );

  const bgColor = QUALITY_COLORS[chord.quality] || 'bg-gray-700';

  return (
    <button
      type="button"
      className={`
        relative flex flex-col items-center justify-center gap-2
        px-2 py-4 rounded-lg
        text-white font-medium
        select-none touch-none
        transition-all duration-75
        ${bgColor}
        ${isActive ? 'brightness-125 scale-[0.98]' : 'hover:brightness-110'}
        ${className}
      `}
      onPointerDown={handlePointerDown}
      onPointerUp={handlePointerUp}
      onPointerCancel={handlePointerCancel}
      aria-label={`${chord.displayName} chord (${chord.romanNumeral})`}
      aria-pressed={isActive}
    >
      {/* Chord name - large and prominent */}
      <span className="text-xl font-bold">{chord.displayName}</span>

      {/* Roman numeral - below chord name */}
      <span className="text-sm opacity-70">{chord.romanNumeral}</span>
    </button>
  );
}
