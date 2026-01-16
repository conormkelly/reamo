/**
 * ChordStrips Component
 * Container for 7 diatonic chord strips (vertical columns) with key/scale selection
 * Landscape orientation recommended - strips arranged horizontally
 */

import { useState, useMemo, useCallback, type ReactElement } from 'react';
import {
  generateChordsForKey,
  DEFAULT_OCTAVE,
  DEFAULT_VELOCITY,
  type NoteName,
  type ScaleType,
} from '@/lib/music-theory';
import { ChordStrip } from './ChordStrip';
import { KeySelector } from './KeySelector';
import { ScaleSelector } from './ScaleSelector';
import { OctaveSelector } from './OctaveSelector';

export interface ChordStripsProps {
  /** MIDI channel (0-15) */
  channel: number;
  /** Callback to send note on */
  onNoteOn: (channel: number, note: number, velocity: number) => void;
  /** Initial key (default: C) */
  initialKey?: NoteName;
  /** Initial scale (default: major) */
  initialScale?: ScaleType;
  /** Initial octave (default: 3) */
  initialOctave?: number;
  className?: string;
}

export function ChordStrips({
  channel,
  onNoteOn,
  initialKey = 'C',
  initialScale = 'major',
  initialOctave = DEFAULT_OCTAVE,
  className = '',
}: ChordStripsProps): ReactElement {
  // State for key, scale, and octave
  const [rootKey, setRootKey] = useState<NoteName>(initialKey);
  const [scaleType, setScaleType] = useState<ScaleType>(initialScale);
  const [octave, setOctave] = useState(initialOctave);

  // Generate chords when key/scale/octave changes
  const chords = useMemo(
    () => generateChordsForKey(rootKey, scaleType, false, octave),
    [rootKey, scaleType, octave]
  );

  // Handle chord note on - send all notes in the chord
  const handleChordNoteOn = useCallback(
    (notes: number[], velocity: number) => {
      for (const note of notes) {
        onNoteOn(channel, note, velocity);
      }
    },
    [channel, onNoteOn]
  );

  // Handle chord note off - send velocity 0 for all notes
  const handleChordNoteOff = useCallback(
    (notes: number[]) => {
      for (const note of notes) {
        onNoteOn(channel, note, 0);
      }
    },
    [channel, onNoteOn]
  );

  return (
    <div className={`flex flex-col h-full ${className}`}>
      {/* Controls bar */}
      <div className="flex items-center gap-4 px-3 py-2 bg-bg-subtle border-b border-border-subtle">
        <KeySelector selectedKey={rootKey} onKeyChange={setRootKey} />
        <ScaleSelector selectedScale={scaleType} onScaleChange={setScaleType} />
        <OctaveSelector
          octave={octave}
          onOctaveChange={setOctave}
          minOctave={1}
          maxOctave={5}
        />
      </div>

      {/* Chord strips - horizontal row of vertical columns */}
      <div
        className="flex-1 flex flex-row gap-2 p-3 overflow-hidden"
        role="group"
        aria-label="Chord strips"
      >
        {chords.map((chord) => (
          <ChordStrip
            key={`${chord.degree}-${chord.root}`}
            chord={chord}
            onNoteOn={handleChordNoteOn}
            onNoteOff={handleChordNoteOff}
            velocity={DEFAULT_VELOCITY}
            className="flex-1 min-w-0 h-full"
          />
        ))}
      </div>
    </div>
  );
}
