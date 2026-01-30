/**
 * TunerView - Chromatic tuner for instrument tuning
 *
 * Subscribes to a track's tuner JSFX and displays real-time pitch detection:
 * - Note name and octave (large display)
 * - Cents deviation meter (-50 to +50)
 * - Frequency display
 * - Track selector (defaults to first armed track)
 *
 * Uses ViewLayout for proper responsive layout handling.
 */

import { useEffect, useState, useCallback, useRef, type ReactElement } from 'react';
import { ChevronDown } from 'lucide-react';
import { ViewLayout } from '../../components/Layout/ViewLayout';
import { ViewHeader } from '../../components/Layout/ViewHeader';
import { BottomSheet } from '../../components/Modal/BottomSheet';
import { useTuner } from '../../hooks';
import { useReaperStore } from '../../store';
import { EMPTY_SKELETON } from '../../store/stableRefs';
import { TunerMeter } from './TunerMeter';
import { TunerNote } from './TunerNote';
import { TunerSettings } from './TunerSettings';

// Hysteresis threshold: only switch notes when within this many cents of the new note
// This prevents flickering at the ±50 cent boundary between adjacent notes
const NOTE_SWITCH_THRESHOLD = 40;

// Load reference Hz from localStorage
function loadReferenceHz(): number {
  try {
    const saved = localStorage.getItem('tuner-reference');
    if (saved) {
      const parsed = parseFloat(saved);
      if (!isNaN(parsed) && parsed >= 400 && parsed <= 480) {
        return parsed;
      }
    }
  } catch {
    // Ignore errors
  }
  return 440;
}

// Load threshold dB from localStorage (JSFX range: -90 to -30)
function loadThresholdDb(): number {
  try {
    const saved = localStorage.getItem('tuner-threshold');
    if (saved) {
      const parsed = parseInt(saved, 10);
      if (!isNaN(parsed) && parsed >= -90 && parsed <= -30) {
        return parsed;
      }
    }
  } catch {
    // Ignore errors
  }
  return -60;
}

// Load selected track GUID from localStorage
function loadSelectedTrack(): string | null {
  try {
    return localStorage.getItem('tuner-track') || null;
  } catch {
    return null;
  }
}

// Save selected track GUID to localStorage
function saveSelectedTrack(guid: string | null): void {
  try {
    if (guid) {
      localStorage.setItem('tuner-track', guid);
    } else {
      localStorage.removeItem('tuner-track');
    }
  } catch {
    // Ignore quota exceeded errors
  }
}

export function TunerView(): ReactElement {
  const {
    subscribe,
    unsubscribe,
    freq,
    note,
    noteName,
    octave,
    cents,
    inTune,
    referenceHz,
    setReferenceHz,
    thresholdDb,
    setThresholdDb,
  } = useTuner();

  // Track selection state - initialize from localStorage to survive orientation changes
  const [selectedTrackGuid, setSelectedTrackGuid] = useState<string | null>(() => loadSelectedTrack());
  const [showTrackSelector, setShowTrackSelector] = useState(false);
  const [showSettings, setShowSettings] = useState(false);

  // Hysteresis: track the "stable" displayed note to prevent flickering at boundaries
  // Only switch notes when clearly within the new note's range (|cents| < threshold)
  // Also store MIDI note number to recalculate cents when overriding
  const stableNoteRef = useRef<{ noteName: string; octave: number; midiNote: number } | null>(null);

  // Compute display values with hysteresis
  let displayNoteName = noteName;
  let displayOctave = octave;
  let displayCents = cents;

  if (freq > 0 && noteName) {
    const currentStable = stableNoteRef.current;
    const isSameNote = currentStable?.noteName === noteName && currentStable?.octave === octave;

    if (!currentStable) {
      // First note detected - set it as stable
      stableNoteRef.current = { noteName, octave, midiNote: note };
    } else if (isSameNote) {
      // Same note - keep it (no change needed)
    } else if (Math.abs(cents) < NOTE_SWITCH_THRESHOLD) {
      // Different note AND clearly within its range - switch
      stableNoteRef.current = { noteName, octave, midiNote: note };
    } else {
      // Different note but at boundary (|cents| >= threshold) - keep showing stable note
      displayNoteName = currentStable.noteName;
      displayOctave = currentStable.octave;
      // Recalculate cents relative to the stable note
      // actualPitch = incomingNote + incomingCents/100 (in semitones)
      // displayCents = (actualPitch - stableNote) * 100
      const actualPitch = note + cents / 100;
      displayCents = (actualPitch - currentStable.midiNote) * 100;
    }
  } else if (freq === 0) {
    // No signal - clear stable note
    stableNoteRef.current = null;
  }

  // Get track skeleton for track selection
  const tracks = useReaperStore((s) => s.trackSkeleton ?? EMPTY_SKELETON);

  // Filter to non-master tracks
  const trackList = tracks.filter((t) => t.g !== 'master');

  // Get armed tracks (prefer for auto-selection)
  const armedTracks = trackList.filter((t) => t.r);

  // Get track name for current selection
  const selectedTrack = trackList.find((t) => t.g === selectedTrackGuid);
  const trackName = selectedTrack?.n || 'Select Track';

  // Load settings from storage on mount
  useEffect(() => {
    if (!selectedTrackGuid) return;

    const storedRef = loadReferenceHz();
    if (storedRef !== referenceHz) {
      setReferenceHz(storedRef, selectedTrackGuid);
    }

    const storedThreshold = loadThresholdDb();
    if (storedThreshold !== thresholdDb) {
      setThresholdDb(storedThreshold, selectedTrackGuid);
    }
    // Only run on mount
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Auto-select track on mount (prefer saved track, then armed track, then first track)
  useEffect(() => {
    if (trackList.length === 0) return;

    // Check if current selection is still valid
    const currentValid = selectedTrackGuid && trackList.some((t) => t.g === selectedTrackGuid);
    if (currentValid) return;

    // Select: armed track > first track
    const defaultTrack = armedTracks[0]?.g ?? trackList[0]?.g ?? null;
    if (defaultTrack) {
      setSelectedTrackGuid(defaultTrack);
      saveSelectedTrack(defaultTrack);
    }
  }, [selectedTrackGuid, trackList, armedTracks]);

  // Subscribe/unsubscribe when selected track changes
  useEffect(() => {
    if (!selectedTrackGuid) return;

    subscribe(selectedTrackGuid);

    return () => {
      unsubscribe();
    };
  }, [selectedTrackGuid, subscribe, unsubscribe]);

  // Handle track selection
  const handleTrackSelect = useCallback((guid: string) => {
    setSelectedTrackGuid(guid);
    saveSelectedTrack(guid);
    setShowTrackSelector(false);
  }, []);

  // Handle reference Hz change
  const handleReferenceChange = useCallback(
    (hz: number) => {
      if (selectedTrackGuid) {
        setReferenceHz(hz, selectedTrackGuid);
      }
    },
    [selectedTrackGuid, setReferenceHz]
  );

  // Handle threshold dB change
  const handleThresholdChange = useCallback(
    (db: number) => {
      if (selectedTrackGuid) {
        setThresholdDb(db, selectedTrackGuid);
      }
    },
    [selectedTrackGuid, setThresholdDb]
  );

  // No signal state
  const hasSignal = freq > 0;

  return (
    <ViewLayout
      viewId="tuner"
      scrollable={false}
      className="bg-bg-app text-text-primary"
      header={
        <div className="p-3">
          <ViewHeader currentView="tuner">
            {/* Track selector button */}
            <button
              onClick={() => setShowTrackSelector(true)}
              className="flex items-center gap-2 px-3 py-1.5 rounded-lg bg-bg-elevated hover:bg-bg-hover transition-colors text-sm font-medium"
            >
              <span className="truncate max-w-[120px]">{trackName}</span>
              <ChevronDown size={16} className="text-text-tertiary shrink-0" />
            </button>
          </ViewHeader>
        </div>
      }
      footer={
        <div className="p-3 border-t border-border-muted">
          <TunerSettings
            referenceHz={referenceHz}
            onReferenceChange={handleReferenceChange}
            thresholdDb={thresholdDb}
            onThresholdChange={handleThresholdChange}
            showSettings={showSettings}
            onToggleSettings={() => setShowSettings(!showSettings)}
          />
        </div>
      }
    >
      {/* Main tuner content - always show skeleton, disabled when no signal */}
      <div className="h-full flex flex-col items-center justify-center p-4 gap-4">
        <TunerNote
          noteName={displayNoteName}
          octave={displayOctave}
          inTune={inTune}
          disabled={!hasSignal}
        />
        <TunerMeter cents={displayCents} inTune={inTune} disabled={!hasSignal} />
        <div className="text-text-muted text-sm">
          {hasSignal ? `${freq.toFixed(1)} Hz` : 'No input detected'}
        </div>
      </div>

      {/* Track selector bottom sheet */}
      <BottomSheet
        isOpen={showTrackSelector}
        onClose={() => setShowTrackSelector(false)}
        ariaLabel="Select Track"
      >
        <h2 className="text-lg font-semibold text-text-primary px-4 pb-3">Select Track</h2>
        <div className="max-h-[60vh] overflow-y-auto">
          {trackList.length === 0 ? (
            <p className="text-center text-text-tertiary py-8">No tracks available</p>
          ) : (
            <div className="flex flex-col">
              {trackList.map((track) => (
                <button
                  key={track.g}
                  onClick={() => handleTrackSelect(track.g)}
                  className={`flex items-center justify-between px-4 py-3 hover:bg-bg-hover transition-colors ${
                    track.g === selectedTrackGuid ? 'bg-bg-elevated' : ''
                  }`}
                >
                  <div className="flex items-center gap-3">
                    <span className="truncate">{track.n || `Track ${track.g.slice(1, 8)}`}</span>
                    {track.r && (
                      <span className="text-xs px-1.5 py-0.5 rounded bg-error/20 text-error">
                        Armed
                      </span>
                    )}
                  </div>
                  {track.g === selectedTrackGuid && (
                    <span className="text-primary">✓</span>
                  )}
                </button>
              ))}
            </div>
          )}
        </div>
      </BottomSheet>
    </ViewLayout>
  );
}
