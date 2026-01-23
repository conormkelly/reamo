/**
 * InstrumentsView - Touch instruments for MIDI input
 * Supports: Drum Pads, Piano with mod/pitch wheels, Chord Pads
 *
 * Phase 2 responsive refactor:
 * - Uses ViewLayout for consistent structure
 * - Soft OrientationHint instead of hard orientation blocks
 * - All instruments work in both orientations
 *
 * @see docs/architecture/UX_GUIDELINES.md §9 (Instruments Orientation Strategy)
 */

import { useState, useEffect, useCallback, useRef, useMemo, type ReactElement } from 'react';
import { ViewHeader, ViewLayout, OrientationHint, type OverflowMenuItem } from '../../components';
import { useIsLandscape, useContainerQuery } from '../../hooks';
import { useReaper } from '../../components/ReaperProvider';
import {
  InstrumentSelector,
  ChannelSelector,
  DrumPadGrid,
  PianoKeyboard,
  ModWheel,
  PitchBendWheel,
  OctaveSelector,
  KeySelector,
  ScaleSelector,
  Chords,
  type InstrumentType,
} from '../../components/Instruments';
import { DEFAULT_OCTAVE, SCALE_TYPES, SCALE_DISPLAY_NAMES, type NoteName, type ScaleType } from '@/lib/music-theory';
import { midi } from '../../core/WebSocketCommands';

/** Preferred orientation per instrument */
const INSTRUMENT_PREFERENCES: Record<InstrumentType, 'landscape' | 'portrait'> = {
  drums: 'portrait',
  piano: 'landscape',
  chords: 'landscape',
};

// localStorage keys for persistence
const STORAGE_KEY_INSTRUMENT = 'reamo_instruments_selected';
const STORAGE_KEY_DRUMS_CHANNEL = 'reamo_instruments_drums_channel';
const STORAGE_KEY_PIANO_CHANNEL = 'reamo_instruments_piano_channel';
const STORAGE_KEY_PIANO_OCTAVE = 'reamo_instruments_piano_octave';
const STORAGE_KEY_CHORDS_CHANNEL = 'reamo_instruments_chords_channel';
const STORAGE_KEY_CHORDS_KEY = 'reamo_instruments_chords_key';
const STORAGE_KEY_CHORDS_SCALE = 'reamo_instruments_chords_scale';
const STORAGE_KEY_CHORDS_OCTAVE = 'reamo_instruments_chords_octave';
const STORAGE_KEY_CHORDS_HINTS = 'reamo_instruments_chords_hints';
const STORAGE_KEY_CHORDS_VOICELEAD = 'reamo_instruments_chords_voicelead';
const STORAGE_KEY_CHORDS_STRUM = 'reamo_instruments_chords_strum';
const STORAGE_KEY_CHORDS_STRUM_DELAY = 'reamo_instruments_chords_strum_delay';

/** Load instrument type from localStorage */
function loadInstrument(): InstrumentType {
  try {
    const stored = localStorage.getItem(STORAGE_KEY_INSTRUMENT);
    if (stored === 'drums' || stored === 'piano' || stored === 'chords') return stored;
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

/** Load channel for chords from localStorage */
function loadChordsChannel(): number {
  try {
    const stored = localStorage.getItem(STORAGE_KEY_CHORDS_CHANNEL);
    if (stored !== null) {
      const parsed = parseInt(stored, 10);
      if (!isNaN(parsed) && parsed >= 0 && parsed <= 15) {
        return parsed;
      }
    }
  } catch {
    // Ignore localStorage errors
  }
  return 0; // Default to channel 1 (0-indexed: 0) for chords
}

/** Save channel for chords to localStorage */
function saveChordsChannel(channel: number): void {
  try {
    localStorage.setItem(STORAGE_KEY_CHORDS_CHANNEL, String(channel));
  } catch {
    // Ignore localStorage errors
  }
}

/** Load chord key from localStorage */
function loadChordsKey(): NoteName {
  try {
    const stored = localStorage.getItem(STORAGE_KEY_CHORDS_KEY);
    if (stored) return stored as NoteName;
  } catch {
    // Ignore
  }
  return 'C';
}

/** Save chord key to localStorage */
function saveChordsKey(key: NoteName): void {
  try {
    localStorage.setItem(STORAGE_KEY_CHORDS_KEY, key);
  } catch {
    // Ignore
  }
}

/** Load chord scale from localStorage */
function loadChordsScale(): ScaleType {
  try {
    const stored = localStorage.getItem(STORAGE_KEY_CHORDS_SCALE);
    if (stored) return stored as ScaleType;
  } catch {
    // Ignore
  }
  return 'major';
}

/** Save chord scale to localStorage */
function saveChordsScale(scale: ScaleType): void {
  try {
    localStorage.setItem(STORAGE_KEY_CHORDS_SCALE, scale);
  } catch {
    // Ignore
  }
}

/** Load chord octave from localStorage */
function loadChordsOctave(): number {
  try {
    const stored = localStorage.getItem(STORAGE_KEY_CHORDS_OCTAVE);
    if (stored !== null) {
      const parsed = parseInt(stored, 10);
      if (!isNaN(parsed) && parsed >= 1 && parsed <= 5) return parsed;
    }
  } catch {
    // Ignore
  }
  return DEFAULT_OCTAVE;
}

/** Save chord octave to localStorage */
function saveChordsOctave(octave: number): void {
  try {
    localStorage.setItem(STORAGE_KEY_CHORDS_OCTAVE, String(octave));
  } catch {
    // Ignore
  }
}

/** Load chord hints setting from localStorage */
function loadChordsHints(): boolean {
  try {
    const stored = localStorage.getItem(STORAGE_KEY_CHORDS_HINTS);
    if (stored !== null) return stored === 'true';
  } catch {
    // Ignore
  }
  return true; // Default on
}

/** Save chord hints setting to localStorage */
function saveChordsHints(enabled: boolean): void {
  try {
    localStorage.setItem(STORAGE_KEY_CHORDS_HINTS, String(enabled));
  } catch {
    // Ignore
  }
}

/** Load voice leading setting from localStorage */
function loadChordsVoiceLead(): boolean {
  try {
    const stored = localStorage.getItem(STORAGE_KEY_CHORDS_VOICELEAD);
    if (stored !== null) return stored === 'true';
  } catch {
    // Ignore
  }
  return false;
}

/** Save voice leading setting to localStorage */
function saveChordsVoiceLead(enabled: boolean): void {
  try {
    localStorage.setItem(STORAGE_KEY_CHORDS_VOICELEAD, String(enabled));
  } catch {
    // Ignore
  }
}

/** Load strum setting from localStorage */
function loadChordsStrum(): boolean {
  try {
    const stored = localStorage.getItem(STORAGE_KEY_CHORDS_STRUM);
    if (stored !== null) return stored === 'true';
  } catch {
    // Ignore
  }
  return false;
}

/** Save strum setting to localStorage */
function saveChordsStrum(enabled: boolean): void {
  try {
    localStorage.setItem(STORAGE_KEY_CHORDS_STRUM, String(enabled));
  } catch {
    // Ignore
  }
}

/** Load strum delay from localStorage */
function loadChordsStrumDelay(): number {
  try {
    const stored = localStorage.getItem(STORAGE_KEY_CHORDS_STRUM_DELAY);
    if (stored !== null) {
      const parsed = parseInt(stored, 10);
      if (!isNaN(parsed) && parsed >= 10 && parsed <= 100) return parsed;
    }
  } catch {
    // Ignore
  }
  return 30;
}

/** Save strum delay to localStorage */
function saveChordsStrumDelay(delay: number): void {
  try {
    localStorage.setItem(STORAGE_KEY_CHORDS_STRUM_DELAY, String(delay));
  } catch {
    // Ignore
  }
}

export function InstrumentsView(): ReactElement {
  const { sendCommand } = useReaper();
  const isLandscape = useIsLandscape();

  // State
  const [selectedInstrument, setSelectedInstrument] = useState<InstrumentType>(loadInstrument);
  const [drumsChannel, setDrumsChannel] = useState<number>(loadDrumsChannel);
  const [pianoChannel, setPianoChannel] = useState<number>(loadPianoChannel);
  const [pianoOctave, setPianoOctave] = useState<number>(loadPianoOctave);
  const [chordsChannel, setChordsChannel] = useState<number>(loadChordsChannel);

  // Chords settings
  const [chordsKey, setChordsKey] = useState<NoteName>(loadChordsKey);
  const [chordsScale, setChordsScale] = useState<ScaleType>(loadChordsScale);
  const [chordsOctave, setChordsOctave] = useState<number>(loadChordsOctave);
  const [chordsHints, setChordsHints] = useState<boolean>(loadChordsHints);
  const [chordsVoiceLead, setChordsVoiceLead] = useState<boolean>(loadChordsVoiceLead);
  const [chordsStrum, setChordsStrum] = useState<boolean>(loadChordsStrum);
  const [chordsStrumDelay, setChordsStrumDelay] = useState<number>(loadChordsStrumDelay);

  // Header responsive behavior - collapse controls to overflow menu on narrow viewports
  const headerControlsRef = useRef<HTMLDivElement>(null);
  const isHeaderNarrow = useContainerQuery(headerControlsRef, 400);

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

  // Persist chords channel
  useEffect(() => {
    saveChordsChannel(chordsChannel);
  }, [chordsChannel]);

  // Persist chord settings
  useEffect(() => {
    saveChordsKey(chordsKey);
  }, [chordsKey]);

  useEffect(() => {
    saveChordsScale(chordsScale);
  }, [chordsScale]);

  useEffect(() => {
    saveChordsOctave(chordsOctave);
  }, [chordsOctave]);

  useEffect(() => {
    saveChordsHints(chordsHints);
  }, [chordsHints]);

  useEffect(() => {
    saveChordsVoiceLead(chordsVoiceLead);
  }, [chordsVoiceLead]);

  useEffect(() => {
    saveChordsStrum(chordsStrum);
  }, [chordsStrum]);

  useEffect(() => {
    saveChordsStrumDelay(chordsStrumDelay);
  }, [chordsStrumDelay]);

  // Get current channel based on selected instrument
  const currentChannel =
    selectedInstrument === 'drums'
      ? drumsChannel
      : selectedInstrument === 'piano'
        ? pianoChannel
        : chordsChannel;

  // Handle channel change based on instrument
  const handleChannelChange = useCallback(
    (channel: number) => {
      if (selectedInstrument === 'drums') {
        setDrumsChannel(channel);
      } else if (selectedInstrument === 'piano') {
        setPianoChannel(channel);
      } else if (selectedInstrument === 'chords') {
        setChordsChannel(channel);
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

  // Render the current instrument - works in both orientations
  const renderInstrument = () => {
    switch (selectedInstrument) {
      case 'drums':
        // In landscape: constrain grid to square aspect ratio, centered
        // In portrait: fills available space naturally
        return isLandscape ? (
          <div className="flex-1 flex items-center justify-center">
            <div className="h-full aspect-square max-w-full">
              <DrumPadGrid channel={currentChannel} onNoteOn={handleNoteOn} className="h-full" />
            </div>
          </div>
        ) : (
          <DrumPadGrid channel={currentChannel} onNoteOn={handleNoteOn} className="flex-1" />
        );

      case 'piano':
        // In portrait: horizontal scroll for keyboard, wheels on sides
        // In landscape: standard horizontal layout
        return (
          <div className="flex-1 flex gap-2 overflow-visible">
            {/* Mod Wheel */}
            <ModWheel onChange={handleModWheel} className="w-12 h-full shrink-0" />

            {/* Piano Keyboard */}
            <div className="flex-1 min-w-0 flex flex-col gap-2 overflow-visible">
              {/* Octave selector - more prominent in portrait */}
              <div className="shrink-0 flex justify-center">
                <OctaveSelector
                  octave={pianoOctave}
                  onOctaveChange={setPianoOctave}
                  minOctave={1}
                  maxOctave={7}
                />
              </div>
              {/* Keyboard - scrollable container in portrait */}
              <div className={`flex-1 min-h-0 ${!isLandscape ? 'overflow-x-auto overflow-y-hidden overscroll-x-contain' : 'overflow-visible'}`}>
                <PianoKeyboard
                  octave={pianoOctave}
                  numOctaves={2}
                  onNoteOn={handlePianoNoteOn}
                  onNoteOff={handlePianoNoteOff}
                  className={`h-full ${!isLandscape ? 'min-w-[500px]' : ''}`}
                />
              </div>
            </div>

            {/* Pitch Bend Wheel */}
            <PitchBendWheel onChange={handlePitchBendWheel} className="w-12 h-full shrink-0" />
          </div>
        );

      case 'chords':
        // In portrait: horizontal scroll with snap
        // In landscape: standard horizontal layout
        return !isLandscape ? (
          <div className="flex-1 min-h-0 overflow-x-auto overflow-y-hidden overscroll-x-contain snap-x snap-mandatory">
            <Chords
              channel={currentChannel}
              onNoteOn={handleNoteOn}
              rootKey={chordsKey}
              scaleType={chordsScale}
              octave={chordsOctave}
              showHints={chordsHints}
              adaptiveVoicing={chordsVoiceLead}
              strumEnabled={chordsStrum}
              strumDelay={chordsStrumDelay}
              className="h-full min-w-[700px]"
            />
          </div>
        ) : (
          <Chords
            channel={currentChannel}
            onNoteOn={handleNoteOn}
            rootKey={chordsKey}
            scaleType={chordsScale}
            octave={chordsOctave}
            showHints={chordsHints}
            adaptiveVoicing={chordsVoiceLead}
            strumEnabled={chordsStrum}
            strumDelay={chordsStrumDelay}
            className="flex-1"
          />
        );

      default:
        return null;
    }
  };

  // Settings popover state for Chord Pads (used in wide mode)
  const [showChordsSettings, setShowChordsSettings] = useState(false);

  // Count active modes for badge
  const activeModeCount = [chordsHints, chordsVoiceLead, chordsStrum].filter(Boolean).length;

  // Build overflow items for Chords header when narrow
  // Priority (last to collapse → first to collapse):
  // 1. Key selector (most frequently changed) - always visible
  // 2. Scale selector - collapses when narrow
  // 3. Octave selector - collapses when narrow
  // 4. Settings (hints, voice lead, strum) - collapses to overflow
  const chordsOverflowItems = useMemo((): OverflowMenuItem[] => {
    if (selectedInstrument !== 'chords' || !isHeaderNarrow) return [];

    const items: OverflowMenuItem[] = [
      // Scale options - cycle through scales
      {
        id: 'scale',
        label: `Scale: ${SCALE_DISPLAY_NAMES[chordsScale]}`,
        onSelect: () => {
          const currentIdx = SCALE_TYPES.indexOf(chordsScale);
          const nextIdx = (currentIdx + 1) % SCALE_TYPES.length;
          setChordsScale(SCALE_TYPES[nextIdx]);
        },
      },
      // Octave options - cycle through octaves
      {
        id: 'octave',
        label: `Octave: ${chordsOctave}`,
        onSelect: () => {
          setChordsOctave(chordsOctave >= 5 ? 1 : chordsOctave + 1);
        },
      },
      // Separator-like divider via label
      {
        id: 'hints',
        label: `Hints ${chordsHints ? '✓' : ''}`,
        isActive: chordsHints,
        onSelect: () => setChordsHints(!chordsHints),
      },
      {
        id: 'voicelead',
        label: `Voice Lead ${chordsVoiceLead ? '✓' : ''}`,
        isActive: chordsVoiceLead,
        onSelect: () => setChordsVoiceLead(!chordsVoiceLead),
      },
      {
        id: 'strum',
        label: `Strum ${chordsStrum ? '✓' : ''}`,
        isActive: chordsStrum,
        onSelect: () => setChordsStrum(!chordsStrum),
      },
    ];

    return items;
  }, [selectedInstrument, isHeaderNarrow, chordsScale, chordsOctave, chordsHints, chordsVoiceLead, chordsStrum]);

  // Render header controls based on selected instrument
  const renderHeaderControls = () => {
    if (selectedInstrument === 'chords') {
      return (
        <div ref={headerControlsRef} className="flex items-center gap-2 w-full">
          {/* Key selector - always visible (most frequently changed) */}
          <KeySelector selectedKey={chordsKey} onKeyChange={setChordsKey} />

          {/* Scale and Octave - hidden when narrow, moved to overflow menu */}
          {!isHeaderNarrow && (
            <>
              <ScaleSelector selectedScale={chordsScale} onScaleChange={setChordsScale} />
              <OctaveSelector
                octave={chordsOctave}
                onOctaveChange={setChordsOctave}
                minOctave={1}
                maxOctave={5}
              />
            </>
          )}

          {/* Settings gear - only visible when wide (in narrow mode, settings go to overflow) */}
          {!isHeaderNarrow && (
            <div className="relative">
              <button
                type="button"
                onClick={() => setShowChordsSettings(!showChordsSettings)}
                className={`
                  p-1.5 rounded transition-colors relative
                  ${showChordsSettings
                    ? 'bg-accent-primary text-white'
                    : 'bg-bg-surface text-text-secondary border border-border-subtle hover:bg-bg-subtle'}
                `}
                aria-label="Chord settings"
                aria-expanded={showChordsSettings}
              >
                <svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    strokeWidth={2}
                    d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"
                  />
                  <path
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    strokeWidth={2}
                    d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"
                  />
                </svg>
                {activeModeCount > 0 && (
                  <span className="absolute -top-1 -right-1 w-4 h-4 bg-accent-primary text-white text-[10px] rounded-full flex items-center justify-center">
                    {activeModeCount}
                  </span>
                )}
              </button>

              {/* Settings popover */}
              {showChordsSettings && (
                <>
                  {/* Backdrop to close */}
                  <div
                    className="fixed inset-0 z-10"
                    onClick={() => setShowChordsSettings(false)}
                  />
                  <div className="absolute right-0 top-full mt-1 z-20 bg-bg-surface border border-border-subtle rounded-lg shadow-lg p-3 min-w-[180px]">
                    <div className="flex flex-col gap-2">
                      <label className="flex items-center justify-between gap-3 cursor-pointer">
                        <span className="text-sm text-text-primary">Hints</span>
                        <input
                          type="checkbox"
                          checked={chordsHints}
                          onChange={(e) => setChordsHints(e.target.checked)}
                          className="w-4 h-4 accent-accent-primary"
                        />
                      </label>
                      <label className="flex items-center justify-between gap-3 cursor-pointer">
                        <span className="text-sm text-text-primary">Voice Lead</span>
                        <input
                          type="checkbox"
                          checked={chordsVoiceLead}
                          onChange={(e) => setChordsVoiceLead(e.target.checked)}
                          className="w-4 h-4 accent-accent-primary"
                        />
                      </label>
                      <label className="flex items-center justify-between gap-3 cursor-pointer">
                        <span className="text-sm text-text-primary">Strum</span>
                        <input
                          type="checkbox"
                          checked={chordsStrum}
                          onChange={(e) => setChordsStrum(e.target.checked)}
                          className="w-4 h-4 accent-accent-primary"
                        />
                      </label>
                      {chordsStrum && (
                        <div className="flex items-center gap-2 pt-1 border-t border-border-subtle">
                          <span className="text-xs text-text-secondary">Delay</span>
                          <input
                            type="range"
                            min="10"
                            max="100"
                            value={chordsStrumDelay}
                            onChange={(e) => setChordsStrumDelay(Number(e.target.value))}
                            className="flex-1 h-1 accent-accent-primary"
                          />
                          <span className="text-xs text-text-secondary w-8">{chordsStrumDelay}ms</span>
                        </div>
                      )}
                    </div>
                  </div>
                </>
              )}
            </div>
          )}

          {/* Spacer pushes instrument/channel to right */}
          <div className="flex-1" />

          {/* Right side: same position as Piano/Drums */}
          <ChannelSelector channel={currentChannel} onChannelChange={handleChannelChange} />
          <InstrumentSelector
            selectedInstrument={selectedInstrument}
            onInstrumentChange={setSelectedInstrument}
          />
        </div>
      );
    }

    return (
      <div className="flex items-center gap-3 w-full">
        {/* Spacer pushes to right */}
        <div className="flex-1" />
        <ChannelSelector channel={currentChannel} onChannelChange={handleChannelChange} />
        <InstrumentSelector
          selectedInstrument={selectedInstrument}
          onInstrumentChange={setSelectedInstrument}
        />
      </div>
    );
  };

  // Determine if we should show orientation hint
  const preferredOrientation = INSTRUMENT_PREFERENCES[selectedInstrument];
  const showOrientationHint =
    (preferredOrientation === 'landscape' && !isLandscape) ||
    (preferredOrientation === 'portrait' && isLandscape);

  return (
    <ViewLayout
      viewId="instruments"
      className="bg-bg-app text-text-primary"
      header={
        <ViewHeader
          currentView="instruments"
          overflowItems={chordsOverflowItems}
        >
          {renderHeaderControls()}
        </ViewHeader>
      }
      scrollable={false}
    >
      {/* Instrument content area with orientation hint */}
      <div className="h-full flex flex-col p-2 overflow-visible relative">
        {/* Soft orientation hint - dismissible */}
        {showOrientationHint && (
          <OrientationHint
            preferred={preferredOrientation}
            className="absolute top-2 left-2 right-2 z-elevated"
          />
        )}

        {/* The actual instrument */}
        {renderInstrument()}
      </div>
    </ViewLayout>
  );
}
