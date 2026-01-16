/**
 * InstrumentsView - Touch instruments for MIDI input
 * MVP: Drum Pads with instrument selector and channel selector
 */

import { useState, useEffect, useCallback, type ReactElement } from 'react';
import { ViewHeader } from '../../components';
import { useReaper } from '../../components/ReaperProvider';
import {
  InstrumentSelector,
  ChannelSelector,
  DrumPadGrid,
  type InstrumentType,
} from '../../components/Instruments';
import { midi } from '../../core/WebSocketCommands';

// localStorage keys for persistence
const STORAGE_KEY_INSTRUMENT = 'reamo_instruments_selected';
const STORAGE_KEY_DRUMS_CHANNEL = 'reamo_instruments_drums_channel';

/** Load instrument type from localStorage */
function loadInstrument(): InstrumentType {
  try {
    const stored = localStorage.getItem(STORAGE_KEY_INSTRUMENT);
    if (stored === 'drums') return stored;
    // Future: add more instrument types
  } catch {
    // Ignore localStorage errors
  }
  return 'drums';
}

/** Save instrument type to localStorage */
function saveInstrument(type: InstrumentType): void {
  try {
    localStorage.setItem(STORAGE_KEY_INSTRUMENT, type);
  } catch {
    // Ignore localStorage errors
  }
}

/** Load channel for drums from localStorage */
function loadDrumsChannel(): number {
  try {
    const stored = localStorage.getItem(STORAGE_KEY_DRUMS_CHANNEL);
    if (stored !== null) {
      const parsed = parseInt(stored, 10);
      if (!isNaN(parsed) && parsed >= 0 && parsed <= 15) {
        return parsed;
      }
    }
  } catch {
    // Ignore localStorage errors
  }
  return 9; // Default to channel 10 (0-indexed: 9) for drums
}

/** Save channel for drums to localStorage */
function saveDrumsChannel(channel: number): void {
  try {
    localStorage.setItem(STORAGE_KEY_DRUMS_CHANNEL, String(channel));
  } catch {
    // Ignore localStorage errors
  }
}

export function InstrumentsView(): ReactElement {
  const { sendCommand } = useReaper();

  // State
  const [selectedInstrument, setSelectedInstrument] = useState<InstrumentType>(loadInstrument);
  const [drumsChannel, setDrumsChannel] = useState<number>(loadDrumsChannel);

  // Persist instrument selection
  useEffect(() => {
    saveInstrument(selectedInstrument);
  }, [selectedInstrument]);

  // Persist drums channel
  useEffect(() => {
    saveDrumsChannel(drumsChannel);
  }, [drumsChannel]);

  // Get current channel based on selected instrument
  const currentChannel = selectedInstrument === 'drums' ? drumsChannel : 0;

  // Handle channel change based on instrument
  const handleChannelChange = useCallback(
    (channel: number) => {
      if (selectedInstrument === 'drums') {
        setDrumsChannel(channel);
      }
      // Future: handle other instrument channels
    },
    [selectedInstrument]
  );

  // MIDI handler - drums are one-shots, no note-off needed
  const handleNoteOn = useCallback(
    (channel: number, note: number, velocity: number) => {
      sendCommand(midi.noteOn(note, velocity, channel));
    },
    [sendCommand]
  );

  // Render the current instrument
  const renderInstrument = () => {
    switch (selectedInstrument) {
      case 'drums':
        return (
          <DrumPadGrid
            channel={currentChannel}
            onNoteOn={handleNoteOn}
            className="flex-1"
          />
        );
      // Future: case 'piano': return <PianoKeys ... />; (will need note-off)
      // Future: case 'chords': return <ChordStrips ... />;
      default:
        return null;
    }
  };

  return (
    <div data-view="instruments" className="h-full bg-bg-app text-text-primary flex flex-col">
      <ViewHeader currentView="instruments">
        <div className="flex items-center gap-3">
          <InstrumentSelector
            selectedInstrument={selectedInstrument}
            onInstrumentChange={setSelectedInstrument}
          />
          <ChannelSelector channel={currentChannel} onChannelChange={handleChannelChange} />
        </div>
      </ViewHeader>

      {/* Instrument content area */}
      <div className="flex-1 min-h-0 flex flex-col p-2">{renderInstrument()}</div>
    </div>
  );
}
