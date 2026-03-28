/**
 * InstrumentsView - Touch instruments for MIDI input
 * Supports: Drum Pads, Piano with mod/pitch wheels, Chord Pads
 *
 * - Uses ViewLayout for consistent structure
 * - Soft OrientationHint instead of hard orientation blocks
 * - All instruments work in both orientations
 *
 * @see docs/architecture/UX_GUIDELINES.md §9 (Instruments Orientation Strategy)
 */

import { useState, useEffect, useCallback, useRef, useMemo, type ReactElement } from 'react';
import { MoveHorizontal } from 'lucide-react';
import { ViewHeader, ViewLayout, type OverflowMenuItem } from '../../components';
import { useIsLandscape, useContainerQuery } from '../../hooks';
import { useReaper } from '../../components/ReaperProvider';
import { useReaperStore } from '../../store';
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
  const showPianoWheels = useReaperStore((s) => s.showPianoWheels);

  // 8va/8vb momentary transposition (held = ±12 semitones)
  const [octaveTranspose, setOctaveTranspose] = useState(0);

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

  // Piano scroll indicator (portrait mode) — interactive touch scrollbar
  const pianoScrollRef = useRef<HTMLDivElement>(null);
  const scrollTrackRef = useRef<HTMLDivElement>(null);
  const [pianoScrollRatio, setPianoScrollRatio] = useState(0);
  const [pianoThumbWidth, setPianoThumbWidth] = useState(0);
  const [isDraggingScroll, setIsDraggingScroll] = useState(false);

  const handlePianoScroll = useCallback(() => {
    const el = pianoScrollRef.current;
    if (!el) return;
    const maxScroll = el.scrollWidth - el.clientWidth;
    if (maxScroll <= 0) return;
    setPianoScrollRatio(el.scrollLeft / maxScroll);
    setPianoThumbWidth(el.clientWidth / el.scrollWidth);
  }, []);

  // Scroll the keyboard to a position based on where the user touches/drags on the track
  const scrollToTrackPosition = useCallback((clientX: number) => {
    const track = scrollTrackRef.current;
    const scroll = pianoScrollRef.current;
    if (!track || !scroll) return;
    const rect = track.getBoundingClientRect();
    const thumbW = Math.max(scroll.clientWidth / scroll.scrollWidth, 0.15);
    // Map touch position to scroll ratio, centering the thumb on the finger
    const ratio = Math.max(0, Math.min(1, (clientX - rect.left - (rect.width * thumbW / 2)) / (rect.width * (1 - thumbW))));
    const maxScroll = scroll.scrollWidth - scroll.clientWidth;
    scroll.scrollLeft = ratio * maxScroll;
  }, []);

  // Double-tap scrollbar to reset to middle C
  const lastScrollTapRef = useRef(0);

  const scrollToOctave = useCallback((oct: number, smooth = true) => {
    const el = pianoScrollRef.current;
    if (!el) return;
    const whiteKeysPerOctave = 7;
    const totalWhiteKeys = 8 * whiteKeysPerOctave;
    const keyWidth = el.scrollWidth / totalWhiteKeys;
    const targetKey = oct * whiteKeysPerOctave;
    el.scrollTo({ left: targetKey * keyWidth, behavior: smooth ? 'smooth' : 'instant' });
  }, []);

  const handleScrollTrackPointerDown = useCallback((e: React.PointerEvent) => {
    e.preventDefault();
    e.stopPropagation();

    // Detect double-tap (within 300ms)
    const now = Date.now();
    if (now - lastScrollTapRef.current < 300) {
      // Reset to middle C
      setPianoOctave(4);
      scrollToOctave(4);
      lastScrollTapRef.current = 0;
      return;
    }
    lastScrollTapRef.current = now;

    (e.target as HTMLElement).setPointerCapture(e.pointerId);
    setIsDraggingScroll(true);
    scrollToTrackPosition(e.clientX);
  }, [scrollToTrackPosition, scrollToOctave]);

  const handleScrollTrackPointerMove = useCallback((e: React.PointerEvent) => {
    if (!isDraggingScroll) return;
    scrollToTrackPosition(e.clientX);
  }, [isDraggingScroll, scrollToTrackPosition]);

  const handleScrollTrackPointerUp = useCallback((e: React.PointerEvent) => {
    (e.target as HTMLElement).releasePointerCapture(e.pointerId);
    setIsDraggingScroll(false);
  }, []);

  // Initialize thumb width on mount / resize, and scroll to pianoOctave on first render
  const hasInitialScrolled = useRef(false);
  useEffect(() => {
    if (isLandscape || selectedInstrument !== 'piano') {
      hasInitialScrolled.current = false;
      return;
    }
    const el = pianoScrollRef.current;
    if (!el) return;
    const update = () => {
      const maxScroll = el.scrollWidth - el.clientWidth;
      setPianoThumbWidth(el.clientWidth / el.scrollWidth);
      if (maxScroll > 0) {
        // Scroll to saved octave on first render
        if (!hasInitialScrolled.current) {
          hasInitialScrolled.current = true;
          const whiteKeysPerOctave = 7;
          const totalWhiteKeys = 8 * whiteKeysPerOctave;
          const keyWidth = el.scrollWidth / totalWhiteKeys;
          const targetKey = pianoOctave * whiteKeysPerOctave;
          el.scrollLeft = targetKey * keyWidth;
        }
        setPianoScrollRatio(el.scrollLeft / maxScroll);
      }
    };
    update();
    const ro = new ResizeObserver(update);
    ro.observe(el);
    return () => ro.disconnect();
  }, [isLandscape, selectedInstrument, pianoOctave]);

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

  // Piano-specific handlers bound to current channel (applies 8va/8vb transposition)
  const octaveTransposeRef = useRef(0);
  octaveTransposeRef.current = octaveTranspose;

  // Track which transposition was used for each note-on, so note-off sends the same value
  const noteTransposeMap = useRef<Map<number, number>>(new Map());

  const handlePianoNoteOn = useCallback(
    (note: number, velocity: number) => {
      const transposed = Math.max(0, Math.min(127, note + octaveTransposeRef.current));
      noteTransposeMap.current.set(note, transposed);
      handleNoteOn(pianoChannel, transposed, velocity);
    },
    [pianoChannel, handleNoteOn]
  );

  const handlePianoNoteOff = useCallback(
    (note: number) => {
      const transposed = noteTransposeMap.current.get(note) ?? note;
      noteTransposeMap.current.delete(note);
      handleNoteOff(pianoChannel, transposed);
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
        // Constrain grid to square aspect ratio, centered in both orientations
        // Landscape: height-constrained, width derived
        // Portrait: width-constrained, height derived
        return (
          <div className="flex-1 flex items-center justify-center">
            <div className={isLandscape
              ? "h-[90%] aspect-square max-w-full"
              : "w-full aspect-square max-h-full"
            }>
              <DrumPadGrid channel={currentChannel} onNoteOn={handleNoteOn} className="h-full w-full" />
            </div>
          </div>
        );

      case 'piano':
        // In portrait: scrollable multi-octave keyboard with capped height, C labels for navigation
        // In landscape: standard horizontal layout with octave selector
        return isLandscape ? (
          <div className="flex-1 flex gap-2 overflow-visible">
            {showPianoWheels && <ModWheel onChange={handleModWheel} className="w-12 h-full shrink-0" />}
            <div className="flex-1 min-w-0 flex flex-col gap-2 overflow-visible">
              <div className="shrink-0 flex justify-center">
                <OctaveSelector
                  octave={pianoOctave}
                  onOctaveChange={setPianoOctave}
                  minOctave={0}
                  maxOctave={6}
                />
              </div>
              <div className="flex-1 min-h-0 overflow-visible">
                <PianoKeyboard
                  octave={pianoOctave}
                  numOctaves={2}
                  showNoteLabels
                  onNoteOn={handlePianoNoteOn}
                  onNoteOff={handlePianoNoteOff}
                  className="h-full"
                />
              </div>
            </div>
            {showPianoWheels && <PitchBendWheel onChange={handlePitchBendWheel} className="w-12 h-full shrink-0" />}
          </div>
        ) : (
          <div className="flex-1 flex flex-col items-center justify-center gap-3">
            {/* Octave selector + 8va/8vb buttons */}
            <div className="flex items-center gap-3">
              <button
                type="button"
                className={`px-2.5 py-1.5 rounded text-xs font-bold touch-none select-none transition-colors ${
                  octaveTranspose === -12
                    ? 'bg-primary text-white'
                    : 'bg-bg-elevated text-text-secondary active:bg-primary active:text-white'
                }`}
                onPointerDown={(e) => { e.preventDefault(); setOctaveTranspose(-12); }}
                onPointerUp={() => setOctaveTranspose(0)}
                onPointerCancel={() => setOctaveTranspose(0)}
                onPointerLeave={() => setOctaveTranspose(0)}
                aria-label="Octave down (8vb)"
              >
                8vb
              </button>
              <OctaveSelector
                octave={pianoOctave}
                onOctaveChange={(oct) => {
                  setPianoOctave(oct);
                  scrollToOctave(oct);
                }}
                minOctave={0}
                maxOctave={7}
              />
              <button
                type="button"
                className={`px-2.5 py-1.5 rounded text-xs font-bold touch-none select-none transition-colors ${
                  octaveTranspose === 12
                    ? 'bg-primary text-white'
                    : 'bg-bg-elevated text-text-secondary active:bg-primary active:text-white'
                }`}
                onPointerDown={(e) => { e.preventDefault(); setOctaveTranspose(12); }}
                onPointerUp={() => setOctaveTranspose(0)}
                onPointerCancel={() => setOctaveTranspose(0)}
                onPointerLeave={() => setOctaveTranspose(0)}
                aria-label="Octave up (8va)"
              >
                8va
              </button>
            </div>
            <div className="flex flex-col gap-2 w-full max-h-[320px] h-full">
              {/* Keyboard + wheels row */}
              <div className="flex gap-2 flex-1 min-h-0">
                {showPianoWheels && <ModWheel onChange={handleModWheel} className="w-12 h-full shrink-0" />}
                <div
                  ref={pianoScrollRef}
                  onScroll={handlePianoScroll}
                  className="flex-1 min-w-0 overflow-x-auto overflow-y-hidden overscroll-x-contain"
                  style={{ scrollbarWidth: 'none', WebkitOverflowScrolling: 'touch' }}
                >
                  <PianoKeyboard
                    octave={0}
                    numOctaves={8}
                    showNoteLabels
                    onNoteOn={handlePianoNoteOn}
                    onNoteOff={handlePianoNoteOff}
                    className="h-full min-w-[1600px]"
                  />
                </div>
                {showPianoWheels && <PitchBendWheel onChange={handlePitchBendWheel} className="w-12 h-full shrink-0" />}
              </div>

              {/* Interactive scroll bar — 44px touch target */}
              <div className="flex items-center gap-2 shrink-0">
                <MoveHorizontal size={16} className="text-text-tertiary shrink-0" />
                <div
                  ref={scrollTrackRef}
                  className="flex-1 h-11 flex items-center touch-none select-none cursor-pointer"
                  onPointerDown={handleScrollTrackPointerDown}
                  onPointerMove={handleScrollTrackPointerMove}
                  onPointerUp={handleScrollTrackPointerUp}
                  onPointerCancel={handleScrollTrackPointerUp}
                >
                  <div className="w-full h-3 bg-bg-elevated rounded-full relative overflow-hidden">
                    <div
                      className={`absolute top-0 h-full rounded-full ${isDraggingScroll ? 'bg-primary' : 'bg-text-tertiary'}`}
                      style={{
                        width: `${Math.max(pianoThumbWidth * 100, 15)}%`,
                        left: `${pianoScrollRatio * (100 - Math.max(pianoThumbWidth * 100, 15))}%`,
                      }}
                    />
                  </div>
                </div>
              </div>
            </div>
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

  return (
    <ViewLayout
      viewId="instruments"
      className="bg-bg-app text-text-primary p-view"
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
      {/* Instrument content area */}
      <div className="h-full flex flex-col p-2 overflow-visible">
        {renderInstrument()}
      </div>
    </ViewLayout>
  );
}
