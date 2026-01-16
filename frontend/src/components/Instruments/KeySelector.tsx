/**
 * KeySelector Component
 * Dropdown to select musical key (root note) for chord generation
 * Shows both enharmonic names for black keys (e.g., "C# / Db")
 */

import type { ReactElement } from 'react';
import { NOTE_NAMES, type NoteName } from '@/lib/music-theory';

/** Display names showing both enharmonic options for black keys */
const KEY_DISPLAY_NAMES: Record<NoteName, string> = {
  C: 'C',
  'C#': 'C# / Db',
  D: 'D',
  'D#': 'D# / Eb',
  E: 'E',
  F: 'F',
  'F#': 'F# / Gb',
  G: 'G',
  'G#': 'G# / Ab',
  A: 'A',
  'A#': 'A# / Bb',
  B: 'B',
};

export interface KeySelectorProps {
  /** Currently selected key (root note) */
  selectedKey: NoteName;
  /** Callback when key changes */
  onKeyChange: (key: NoteName) => void;
  className?: string;
}

export function KeySelector({
  selectedKey,
  onKeyChange,
  className = '',
}: KeySelectorProps): ReactElement {
  return (
    <div className={`flex items-center gap-1.5 ${className}`}>
      <label htmlFor="chord-key" className="text-text-secondary text-sm">
        Key
      </label>
      <select
        id="chord-key"
        value={selectedKey}
        onChange={(e) => onKeyChange(e.target.value as NoteName)}
        className="
          bg-bg-surface text-text-primary text-sm
          border border-border-subtle rounded
          px-1.5 py-1.5
          focus:outline-none focus:ring-2 focus:ring-focus-ring
        "
        aria-label="Musical key"
      >
        {NOTE_NAMES.map((note) => (
          <option key={note} value={note}>
            {KEY_DISPLAY_NAMES[note]}
          </option>
        ))}
      </select>
    </div>
  );
}
