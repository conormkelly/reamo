/**
 * TunerNote - Large note name + octave display
 *
 * How it shows (tunerDisplay.ts decides):
 * - none: a faded A4, holding the layout, with no pitch
 * - starting: a dimmed dash, as a note has begun but its name isn't known yet
 * - shown: the note
 * - inTune: the note in green
 */

import type { ReactElement } from 'react';
import type { NoteLook } from './tunerDisplay';

export interface TunerNoteProps {
  noteName: string;
  octave: number;
  look: NoteLook;
}

const NAME_SIZE = { fontSize: 'clamp(64px, 20vw, 120px)', lineHeight: 1 } as const;
const OCTAVE_SIZE = { fontSize: 'clamp(24px, 8vw, 48px)', lineHeight: 1 } as const;

export function TunerNote({ noteName, octave, look }: TunerNoteProps): ReactElement {
  if (look === 'none' || look === 'starting' || !noteName) {
    const starting = look === 'starting';
    return (
      <div
        data-testid="tuner-note"
        data-look={look}
        aria-hidden="true"
        className={`flex items-baseline gap-2 ${starting ? 'opacity-40 motion-safe:animate-pulse' : 'opacity-20'}`}
      >
        <span className="font-bold text-text-muted" style={NAME_SIZE}>
          {starting ? '–' : 'A'}
        </span>
        {/* Same height as an octave, so the layout doesn't move */}
        <span className="font-medium text-text-muted" style={OCTAVE_SIZE}>
          {starting ? ' ' : '4'}
        </span>
      </div>
    );
  }

  return (
    <div data-testid="tuner-note" data-look={look} className="flex items-baseline gap-2">
      <span
        className={`font-bold transition-colors duration-150 ${look === 'inTune' ? 'text-success' : 'text-text-primary'}`}
        style={NAME_SIZE}
      >
        {noteName}
      </span>
      <span className="font-medium text-text-tertiary" style={OCTAVE_SIZE}>
        {octave}
      </span>
    </div>
  );
}
