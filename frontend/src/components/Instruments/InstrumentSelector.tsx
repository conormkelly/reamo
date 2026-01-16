/**
 * InstrumentSelector Component
 * Dropdown to select instrument type (Drum Pads, future: Piano, Chord Strips)
 */

import type { ReactElement } from 'react';

/** Available instrument types */
export type InstrumentType = 'drums' | 'piano';
// Future: | 'chords'

/** Metadata for instrument types */
const INSTRUMENT_META: Record<InstrumentType, { label: string }> = {
  drums: { label: 'Drum Pads' },
  piano: { label: 'Piano' },
  // Future:
  // chords: { label: 'Chord Strips' },
};

/** All available instruments in display order */
const INSTRUMENT_ORDER: InstrumentType[] = ['drums', 'piano'];

export interface InstrumentSelectorProps {
  /** Currently selected instrument type */
  selectedInstrument: InstrumentType;
  /** Callback when instrument selection changes */
  onInstrumentChange: (type: InstrumentType) => void;
  className?: string;
}

export function InstrumentSelector({
  selectedInstrument,
  onInstrumentChange,
  className = '',
}: InstrumentSelectorProps): ReactElement {
  return (
    <select
      value={selectedInstrument}
      onChange={(e) => onInstrumentChange(e.target.value as InstrumentType)}
      className={`
        bg-bg-surface text-text-primary text-sm
        border border-border-subtle rounded
        px-2 py-1.5
        focus:outline-none focus:ring-2 focus:ring-focus-ring
        ${className}
      `}
      aria-label="Select instrument type"
    >
      {INSTRUMENT_ORDER.map((type) => (
        <option key={type} value={type}>
          {INSTRUMENT_META[type].label}
        </option>
      ))}
    </select>
  );
}
