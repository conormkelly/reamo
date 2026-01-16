/**
 * DrumPadGrid Component
 * 4x4 grid of drum pads with multi-touch support
 * Default GM drum mapping
 */

import { useCallback, type ReactElement } from 'react';
import { DrumPad } from './DrumPad';

/** Drum pad configuration */
interface PadConfig {
  note: number;
  label: string;
  color?: string;
}

/**
 * Default 4x4 GM drum mapping
 * Layout (top to bottom, left to right):
 * | Crash | Ride  | HH Op | HH Cl |
 * | Tom1  | Tom2  | Tom3  | Tom4  |
 * | Snare | Snr2  | Side  | Clap  |
 * | Kick  | Kick2 | Pedal | Floor |
 */
const DEFAULT_PADS: PadConfig[] = [
  // Row 1: Cymbals
  { note: 49, label: 'Crash', color: '#4a5568' },
  { note: 51, label: 'Ride', color: '#4a5568' },
  { note: 46, label: 'HH Op', color: '#4a5568' },
  { note: 42, label: 'HH Cl', color: '#4a5568' },
  // Row 2: Toms
  { note: 48, label: 'Tom 1', color: '#553c9a' },
  { note: 47, label: 'Tom 2', color: '#553c9a' },
  { note: 45, label: 'Tom 3', color: '#553c9a' },
  { note: 43, label: 'Tom 4', color: '#553c9a' },
  // Row 3: Snares & Percussion
  { note: 38, label: 'Snare', color: '#9b2c2c' },
  { note: 40, label: 'Snr 2', color: '#9b2c2c' },
  { note: 37, label: 'Side', color: '#744210' },
  { note: 39, label: 'Clap', color: '#744210' },
  // Row 4: Kicks & Floor
  { note: 36, label: 'Kick', color: '#2c5282' },
  { note: 35, label: 'Kick2', color: '#2c5282' },
  { note: 44, label: 'Pedal', color: '#285e61' },
  { note: 41, label: 'Floor', color: '#553c9a' },
];

export interface DrumPadGridProps {
  /** MIDI channel (0-15) */
  channel: number;
  /** Callback to send note on */
  onNoteOn: (channel: number, note: number, velocity: number) => void;
  className?: string;
}

export function DrumPadGrid({
  channel,
  onNoteOn,
  className = '',
}: DrumPadGridProps): ReactElement {
  // Handle note on for a specific pad
  // Note: Drums are one-shots, no note-off needed
  const handleNoteOn = useCallback(
    (note: number, velocity: number) => {
      onNoteOn(channel, note, velocity);
    },
    [channel, onNoteOn]
  );

  return (
    <div
      className={`
        grid grid-cols-4 gap-2 p-2
        w-full h-full
        ${className}
      `}
      role="group"
      aria-label="Drum pad grid"
    >
      {DEFAULT_PADS.map((pad) => (
        <DrumPad
          key={pad.note}
          note={pad.note}
          label={pad.label}
          color={pad.color}
          onNoteOn={handleNoteOn}
          className="aspect-square"
        />
      ))}
    </div>
  );
}
