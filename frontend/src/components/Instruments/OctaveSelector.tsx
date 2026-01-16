/**
 * OctaveSelector Component
 * Buttons to shift piano keyboard octave up/down
 */

import { type ReactElement } from 'react';

export interface OctaveSelectorProps {
  /** Current octave (0-8) */
  octave: number;
  /** Callback when octave changes */
  onOctaveChange: (octave: number) => void;
  /** Minimum octave (default 0) */
  minOctave?: number;
  /** Maximum octave (default 8) */
  maxOctave?: number;
  className?: string;
}

export function OctaveSelector({
  octave,
  onOctaveChange,
  minOctave = 0,
  maxOctave = 8,
  className = '',
}: OctaveSelectorProps): ReactElement {
  const canGoDown = octave > minOctave;
  const canGoUp = octave < maxOctave;

  return (
    <div className={`flex items-center gap-1 ${className}`}>
      <button
        type="button"
        onClick={() => canGoDown && onOctaveChange(octave - 1)}
        disabled={!canGoDown}
        className={`
          w-7 h-7 rounded flex items-center justify-center
          text-sm font-bold
          ${canGoDown ? 'bg-bg-elevated hover:bg-bg-hover text-text-primary' : 'bg-bg-subtle text-text-disabled cursor-not-allowed'}
          transition-colors
        `}
        aria-label="Octave down"
      >
        −
      </button>
      <span className="min-w-[2.5rem] text-center text-sm font-medium text-text-secondary">
        C{octave}
      </span>
      <button
        type="button"
        onClick={() => canGoUp && onOctaveChange(octave + 1)}
        disabled={!canGoUp}
        className={`
          w-7 h-7 rounded flex items-center justify-center
          text-sm font-bold
          ${canGoUp ? 'bg-bg-elevated hover:bg-bg-hover text-text-primary' : 'bg-bg-subtle text-text-disabled cursor-not-allowed'}
          transition-colors
        `}
        aria-label="Octave up"
      >
        +
      </button>
    </div>
  );
}
