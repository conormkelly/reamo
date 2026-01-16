/**
 * InstrumentsView - Touch instruments for MIDI input
 * Supports: Drum Pads, Piano with mod/pitch wheels
 */

import { useState, useEffect, useCallback, type ReactElement } from 'react';
import { ViewHeader } from '../../components';
import { useReaper } from '../../components/ReaperProvider';
import {
  InstrumentSelector,
  ChannelSelector,
  DrumPadGrid,
  PianoKeyboard,
  ModWheel,
  PitchBendWheel,
  OctaveSelector,
  type InstrumentType,
} from '../../components/Instruments';
import { midi } from '../../core/WebSocketCommands';

/** Hook to detect portrait orientation */
function useIsPortrait(): boolean {
  const [isPortrait, setIsPortrait] = useState(
    () => typeof window !== 'undefined' && window.innerHeight > window.innerWidth
  );

  useEffect(() => {
    const checkOrientation = () => {
      setIsPortrait(window.innerHeight > window.innerWidth);
    };

    window.addEventListener('resize', checkOrientation);
    window.addEventListener('orientationchange', checkOrientation);

    return () => {
      window.removeEventListener('resize', checkOrientation);
      window.removeEventListener('orientationchange', checkOrientation);
    };
  }, []);

  return isPortrait;
}

// localStorage keys for persistence
const STORAGE_KEY_INSTRUMENT = 'reamo_instruments_selected';
const STORAGE_KEY_DRUMS_CHANNEL = 'reamo_instruments_drums_channel';
const STORAGE_KEY_PIANO_CHANNEL = 'reamo_instruments_piano_channel';
const STORAGE_KEY_PIANO_OCTAVE = 'reamo_instruments_piano_octave';

/** Load instrument type from localStorage */
function loadInstrument(): InstrumentType {
  try {
    const stored = localStorage.getItem(STORAGE_KEY_INSTRUMENT);
    if (stored === 'drums' || stored === 'piano') return stored;
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

/** Load channel for piano from localStorage */
function loadPianoChannel(): number {
  try {
    const stored = localStorage.getItem(STORAGE_KEY_PIANO_CHANNEL);
    if (stored !== null) {
      const parsed = parseInt(stored, 10);
      if (!isNaN(parsed) && parsed >= 0 && parsed <= 15) {
        return parsed;
      }
    }
  } catch {
    // Ignore localStorage errors
  }
  return 0; // Default to channel 1 (0-indexed: 0) for piano
}

/** Save channel for piano to localStorage */
function savePianoChannel(channel: number): void {
  try {
    localStorage.setItem(STORAGE_KEY_PIANO_CHANNEL, String(channel));
  } catch {
    // Ignore localStorage errors
  }
}

/** Load octave for piano from localStorage */
function loadPianoOctave(): number {
  try {
    const stored = localStorage.getItem(STORAGE_KEY_PIANO_OCTAVE);
    if (stored !== null) {
      const parsed = parseInt(stored, 10);
      if (!isNaN(parsed) && parsed >= 0 && parsed <= 8) {
        return parsed;
      }
    }
  } catch {
    // Ignore localStorage errors
  }
  return 4; // Default to octave 4 (middle C)
}

/** Save octave for piano to localStorage */
function savePianoOctave(octave: number): void {
  try {
    localStorage.setItem(STORAGE_KEY_PIANO_OCTAVE, String(octave));
  } catch {
    // Ignore localStorage errors
  }
}

export function InstrumentsView(): ReactElement {
  const { sendCommand } = useReaper();
  const isPortrait = useIsPortrait();

  // State
  const [selectedInstrument, setSelectedInstrument] = useState<InstrumentType>(loadInstrument);
  const [drumsChannel, setDrumsChannel] = useState<number>(loadDrumsChannel);
  const [pianoChannel, setPianoChannel] = useState<number>(loadPianoChannel);
  const [pianoOctave, setPianoOctave] = useState<number>(loadPianoOctave);

  // Persist instrument selection
  useEffect(() => {
    saveInstrument(selectedInstrument);
  }, [selectedInstrument]);

  // Persist drums channel
  useEffect(() => {
    saveDrumsChannel(drumsChannel);
  }, [drumsChannel]);

  // Persist piano channel
  useEffect(() => {
    savePianoChannel(pianoChannel);
  }, [pianoChannel]);

  // Persist piano octave
  useEffect(() => {
    savePianoOctave(pianoOctave);
  }, [pianoOctave]);

  // Get current channel based on selected instrument
  const currentChannel =
    selectedInstrument === 'drums' ? drumsChannel : selectedInstrument === 'piano' ? pianoChannel : 0;

  // Handle channel change based on instrument
  const handleChannelChange = useCallback(
    (channel: number) => {
      if (selectedInstrument === 'drums') {
        setDrumsChannel(channel);
      } else if (selectedInstrument === 'piano') {
        setPianoChannel(channel);
      }
    },
    [selectedInstrument]
  );

  // MIDI handlers
  const handleNoteOn = useCallback(
    (channel: number, note: number, velocity: number) => {
      sendCommand(midi.noteOn(note, velocity, channel));
    },
    [sendCommand]
  );

  const handleNoteOff = useCallback(
    (channel: number, note: number) => {
      // Send note-off as note-on with velocity 0
      sendCommand(midi.noteOn(note, 0, channel));
    },
    [sendCommand]
  );

  const handleCC = useCallback(
    (channel: number, cc: number, value: number) => {
      sendCommand(midi.cc(cc, value, channel));
    },
    [sendCommand]
  );

  const handlePitchBend = useCallback(
    (channel: number, value: number) => {
      sendCommand(midi.pitchBend(value, channel));
    },
    [sendCommand]
  );

  // Piano-specific handlers bound to current channel
  const handlePianoNoteOn = useCallback(
    (note: number, velocity: number) => {
      handleNoteOn(pianoChannel, note, velocity);
    },
    [pianoChannel, handleNoteOn]
  );

  const handlePianoNoteOff = useCallback(
    (note: number) => {
      handleNoteOff(pianoChannel, note);
    },
    [pianoChannel, handleNoteOff]
  );

  const handleModWheel = useCallback(
    (value: number) => {
      handleCC(pianoChannel, 1, value); // CC1 = Mod Wheel
    },
    [pianoChannel, handleCC]
  );

  const handlePitchBendWheel = useCallback(
    (value: number) => {
      handlePitchBend(pianoChannel, value);
    },
    [pianoChannel, handlePitchBend]
  );

  // Render the current instrument
  const renderInstrument = () => {
    switch (selectedInstrument) {
      case 'drums':
        // Show portrait warning in landscape mode
        if (!isPortrait) {
          return (
            <div className="flex-1 flex items-center justify-center">
              <div className="text-center text-text-secondary">
                <svg
                  className="w-16 h-16 mx-auto mb-4 text-text-muted"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    strokeWidth={1.5}
                    d="M5 4h10a1 1 0 011 1v16a1 1 0 01-1 1H5a1 1 0 01-1-1V5a1 1 0 011-1z"
                  />
                  <path
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    strokeWidth={1.5}
                    d="M19 12l2-2m-2 2l2 2"
                  />
                </svg>
                <p className="text-lg font-medium">Rotate to portrait</p>
                <p className="text-sm mt-1">Drum pads work best in portrait orientation</p>
              </div>
            </div>
          );
        }
        return (
          <DrumPadGrid channel={currentChannel} onNoteOn={handleNoteOn} className="flex-1" />
        );
      case 'piano':
        // Show landscape warning in portrait mode
        if (isPortrait) {
          return (
            <div className="flex-1 flex items-center justify-center">
              <div className="text-center text-text-secondary">
                <svg
                  className="w-16 h-16 mx-auto mb-4 text-text-muted"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    strokeWidth={1.5}
                    d="M4 5h16a1 1 0 011 1v10a1 1 0 01-1 1H4a1 1 0 01-1-1V6a1 1 0 011-1z"
                  />
                  <path
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    strokeWidth={1.5}
                    d="M12 19l-2 2m2-2l2 2"
                  />
                </svg>
                <p className="text-lg font-medium">Rotate to landscape</p>
                <p className="text-sm mt-1">Piano keyboard works best in landscape orientation</p>
              </div>
            </div>
          );
        }
        return (
          <div className="flex-1 flex gap-2 overflow-visible">
            {/* Mod Wheel */}
            <ModWheel onChange={handleModWheel} className="w-12 h-full" />

            {/* Piano Keyboard */}
            <div className="flex-1 flex flex-col gap-2 overflow-visible">
              {/* Octave selector */}
              <div className="flex justify-center">
                <OctaveSelector
                  octave={pianoOctave}
                  onOctaveChange={setPianoOctave}
                  minOctave={1}
                  maxOctave={7}
                />
              </div>
              {/* Keyboard */}
              <PianoKeyboard
                octave={pianoOctave}
                numOctaves={2}
                onNoteOn={handlePianoNoteOn}
                onNoteOff={handlePianoNoteOff}
                className="flex-1"
              />
            </div>

            {/* Pitch Bend Wheel */}
            <PitchBendWheel onChange={handlePitchBendWheel} className="w-12 h-full" />
          </div>
        );
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
      <div className="flex-1 min-h-0 flex flex-col p-2 overflow-visible">{renderInstrument()}</div>
    </div>
  );
}
