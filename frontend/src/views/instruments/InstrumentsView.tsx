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
import { ViewHeader, ViewLayout } from '../../components';
import { BottomSheet } from '../../components/Modal/BottomSheet';
import { useIsLandscape } from '../../hooks';
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
import { DEFAULT_OCTAVE, type NoteName, type ScaleType } from '@/lib/music-theory';
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
              <DrumPadGrid channel={currentChannel} onNoteOn={handleNoteOn} onNoteOff={handleNoteOff} className="h-full w-full" />
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
        // Landscape: all 7 chords flex to fill
        // Portrait: paginated with large touch-friendly page buttons
        return isLandscape ? (
          <Chords
            channel={currentChannel}
            onNoteOn={handleNoteOn}
            rootKey={chordsKey}
            scaleType={chordsScale}
            octave={chordsOctave}
            adaptiveVoicing={chordsVoiceLead}
            strumEnabled={chordsStrum}
            strumDelay={chordsStrumDelay}
            className="flex-1"
          />
        ) : (
          <div className="flex-1 min-h-0 flex flex-col" ref={chordsContainerRef}>
            <Chords
              channel={currentChannel}
              onNoteOn={handleNoteOn}
              rootKey={chordsKey}
              scaleType={chordsScale}
              octave={chordsOctave}
              adaptiveVoicing={chordsVoiceLead}
              strumEnabled={chordsStrum}
              strumDelay={chordsStrumDelay}
              visibleChords={chordsPages[chordsPage]}
              columnSlots={chordsColsPerPage}
              className="flex-1"
            />
            {/* Prev/Next page buttons — large touch targets */}
            {chordsPages.length > 1 && (
              <div className="flex gap-2 px-3 pb-1 pt-1.5 shrink-0">
                <button
                  type="button"
                  onClick={() => setChordsPage((p) => Math.max(0, p - 1))}
                  disabled={chordsPage === 0}
                  className="flex-1 py-2.5 rounded-lg text-sm font-medium transition-colors bg-bg-elevated text-text-secondary disabled:opacity-30"
                >
                  &#9664; Prev
                </button>
                <span className="flex items-center text-xs text-text-tertiary tabular-nums">
                  {chordsPage + 1}/{chordsPages.length}
                </span>
                <button
                  type="button"
                  onClick={() => setChordsPage((p) => Math.min(chordsPages.length - 1, p + 1))}
                  disabled={chordsPage === chordsPages.length - 1}
                  className="flex-1 py-2.5 rounded-lg text-sm font-medium transition-colors bg-bg-elevated text-text-secondary disabled:opacity-30"
                >
                  Next &#9654;
                </button>
              </div>
            )}
          </div>
        );

      default:
        return null;
    }
  };

  // Chord settings bottom sheet state
  const [showChordsSettings, setShowChordsSettings] = useState(false);

  // Chord pagination (portrait) — measure container to determine columns per page
  const chordsContainerRef = useRef<HTMLDivElement>(null);
  const [chordsColsPerPage, setChordsColsPerPage] = useState(4);
  const [chordsPage, setChordsPage] = useState(0);
  const TOTAL_CHORDS = 7;

  useEffect(() => {
    if (isLandscape || selectedInstrument !== 'chords') return;
    const el = chordsContainerRef.current;
    if (!el) return;
    const measure = () => {
      const available = el.clientWidth - 24; // p-3 padding
      const minColWidth = 80;
      const gap = 8;
      const cols = Math.max(2, Math.min(TOTAL_CHORDS, Math.floor((available + gap) / (minColWidth + gap))));
      setChordsColsPerPage(cols);
    };
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, [isLandscape, selectedInstrument]);

  // Build page arrays from column count
  const chordsPages = useMemo(() => {
    const pages: number[][] = [];
    for (let i = 0; i < TOTAL_CHORDS; i += chordsColsPerPage) {
      pages.push(Array.from({ length: Math.min(chordsColsPerPage, TOTAL_CHORDS - i) }, (_, k) => i + k));
    }
    return pages;
  }, [chordsColsPerPage]);

  // Clamp page if cols-per-page changed and current page is now out of range
  useEffect(() => {
    if (chordsPage >= chordsPages.length) {
      setChordsPage(chordsPages.length - 1);
    }
  }, [chordsPage, chordsPages.length]);

  // Render header controls based on selected instrument
  const renderHeaderControls = () => {
    if (selectedInstrument === 'chords') {
      return (
        <div className="flex items-center gap-2 w-full">
          {/* Settings gear opens bottom sheet with all chord settings */}
          <button
            type="button"
            onClick={() => setShowChordsSettings(true)}
            className="p-1.5 rounded transition-colors bg-bg-surface text-text-secondary border border-border-subtle hover:bg-bg-subtle"
            aria-label="Chord settings"
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
          </button>

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
        <ViewHeader currentView="instruments">
          {renderHeaderControls()}
        </ViewHeader>
      }
      scrollable={false}
    >
      {/* Instrument content area */}
      <div className="h-full flex flex-col p-2 overflow-visible">
        {renderInstrument()}
      </div>

      {/* Chord settings bottom sheet */}
      <BottomSheet isOpen={showChordsSettings} onClose={() => setShowChordsSettings(false)}>
        <div className="p-4 space-y-5">
          <h3 className="text-lg font-semibold text-text-primary">Chord Settings</h3>

          {/* Key */}
          <div className="flex items-center justify-between">
            <label className="text-sm text-text-secondary">Key</label>
            <KeySelector selectedKey={chordsKey} onKeyChange={setChordsKey} />
          </div>

          {/* Scale */}
          <div className="flex items-center justify-between">
            <label className="text-sm text-text-secondary">Scale</label>
            <ScaleSelector selectedScale={chordsScale} onScaleChange={setChordsScale} />
          </div>

          {/* Octave */}
          <div className="flex items-center justify-between">
            <label className="text-sm text-text-secondary">Octave</label>
            <OctaveSelector
              octave={chordsOctave}
              onOctaveChange={setChordsOctave}
              minOctave={1}
              maxOctave={5}
            />
          </div>

          {/* Voice Leading toggle */}
          <div className="flex items-center justify-between">
            <div>
              <label className="text-sm text-text-secondary">Voice Leading</label>
              <p className="text-xs text-text-tertiary">Smooth transitions between chords</p>
            </div>
            <button
              type="button"
              onClick={() => setChordsVoiceLead(!chordsVoiceLead)}
              className={`w-11 h-6 rounded-full transition-colors relative ${
                chordsVoiceLead ? 'bg-primary' : 'bg-bg-elevated border border-border-subtle'
              }`}
            >
              <div className={`absolute top-0.5 w-5 h-5 rounded-full bg-white shadow transition-transform ${
                chordsVoiceLead ? 'translate-x-5' : 'translate-x-0.5'
              }`} />
            </button>
          </div>

          {/* Strum toggle */}
          <div className="flex items-center justify-between">
            <div>
              <label className="text-sm text-text-secondary">Strum</label>
              <p className="text-xs text-text-tertiary">Arpeggiate chord notes</p>
            </div>
            <button
              type="button"
              onClick={() => setChordsStrum(!chordsStrum)}
              className={`w-11 h-6 rounded-full transition-colors relative ${
                chordsStrum ? 'bg-primary' : 'bg-bg-elevated border border-border-subtle'
              }`}
            >
              <div className={`absolute top-0.5 w-5 h-5 rounded-full bg-white shadow transition-transform ${
                chordsStrum ? 'translate-x-5' : 'translate-x-0.5'
              }`} />
            </button>
          </div>

          {/* Strum delay slider (only when strum enabled) */}
          {chordsStrum && (
            <div className="flex items-center justify-between gap-4">
              <label className="text-sm text-text-secondary shrink-0">Strum Delay</label>
              <div className="flex items-center gap-2 flex-1">
                <input
                  type="range"
                  min={10}
                  max={100}
                  step={5}
                  value={chordsStrumDelay}
                  onChange={(e) => setChordsStrumDelay(Number(e.target.value))}
                  className="flex-1 accent-primary"
                />
                <span className="text-xs text-text-tertiary w-10 text-right">{chordsStrumDelay}ms</span>
              </div>
            </div>
          )}
        </div>
      </BottomSheet>
    </ViewLayout>
  );
}
