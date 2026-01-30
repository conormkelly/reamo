/**
 * TunerNote - Large note name + octave display
 *
 * Shows the currently detected note with color-coded in-tune feedback.
 * Uses responsive sizing that scales with container.
 * Supports disabled state for "no signal" display.
 */

import type { ReactElement } from 'react';

export interface TunerNoteProps {
  noteName: string;
  octave: number;
  inTune: boolean;
  /** Show muted placeholder state (no signal) */
  disabled?: boolean;
}

export function TunerNote({ noteName, octave, inTune, disabled }: TunerNoteProps): ReactElement {
  const showPlaceholder = disabled || !noteName;

  // When disabled, show faded "A4" as a reference hint
  // Uses same font sizes as active state for consistent layout
  if (showPlaceholder) {
    return (
      <div className="flex items-baseline gap-2 opacity-20">
        <span
          className="font-bold text-text-muted"
          style={{
            fontSize: 'clamp(64px, 20vw, 120px)',
            lineHeight: 1,
          }}
        >
          A
        </span>
        <span
          className="font-medium text-text-muted"
          style={{
            fontSize: 'clamp(24px, 8vw, 48px)',
            lineHeight: 1,
          }}
        >
          4
        </span>
      </div>
    );
  }

  return (
    <div className="flex items-baseline gap-2">
      {/* Note name - large */}
      <span
        className={`font-bold transition-colors duration-150 ${
          inTune ? 'text-success' : 'text-text-primary'
        }`}
        style={{
          fontSize: 'clamp(64px, 20vw, 120px)',
          lineHeight: 1,
        }}
      >
        {noteName}
      </span>
      {/* Octave - smaller */}
      <span
        className="font-medium text-text-tertiary"
        style={{
          fontSize: 'clamp(24px, 8vw, 48px)',
          lineHeight: 1,
        }}
      >
        {octave}
      </span>
    </div>
  );
}
