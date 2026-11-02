/**
 * TunerView - Chromatic tuner for instrument tuning
 *
 * Subscribes to the tuner on a track (REAPER reads the hardware input the
 * track records from, armed or not). Shows:
 * - Note name and octave (large display)
 * - Cents deviation meter (-50 to +50)
 * - Frequency, or what stands in for it: why the track's input can't be
 *   tuned (REAPER's own message), that REAPER's audio device isn't
 *   running, that several notes sound, or that a note is starting
 * - Track selector (defaults to the first track); choosing the track
 *   already chosen asks REAPER again, after the user has fixed its input
 *
 * The analyser's flags decide what shows (tunerDisplay.ts): green only for
 * a stable reading in the in-tune window.
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
import { holdNote, tunerDisplay, type HeldNote } from './tunerDisplay';

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
    subscribedGuid,
    freq,
    note,
    noteName,
    octave,
    cents,
    inTune,
    starting,
    settling,
    stable,
    multiple,
    state,
    problem,
    referenceHz,
    setReferenceHz,
    thresholdDb,
    setThresholdDb,
  } = useTuner();

  // Track selection state - initialize from localStorage to survive orientation changes
  const [selectedTrackGuid, setSelectedTrackGuid] = useState<string | null>(() => loadSelectedTrack());
  const [showTrackSelector, setShowTrackSelector] = useState(false);
  const [showSettings, setShowSettings] = useState(false);

  // The note shown, held across the boundary to the next one (holdNote).
  // holdNote gives the same for the same input, so a second render of one
  // reading shows the same.
  const heldNoteRef = useRef<HeldNote | null>(null);
  const shown = holdNote(heldNoteRef.current, subscribedGuid, { freq, note, noteName, octave, cents });
  heldNoteRef.current = shown.held;

  const display = tunerDisplay({
    freq,
    cents: shown.cents,
    inTune,
    starting,
    settling,
    stable,
    multiple,
    problem: problem?.message ?? null,
    deviceClosed: state === 'deviceClosed',
  });

  // Get track skeleton for track selection
  const tracks = useReaperStore((s) => s.trackSkeleton ?? EMPTY_SKELETON);

  // Filter to non-master tracks
  const trackList = tracks.filter((t) => t.g !== 'master');

  // Get track name for current selection
  const selectedTrack = trackList.find((t) => t.g === selectedTrackGuid);
  const trackName = selectedTrack?.n || 'Select Track';

  // Auto-select track on mount (prefer saved track, then first track)
  useEffect(() => {
    if (trackList.length === 0) return;

    // Check if current selection is still valid
    const currentValid = selectedTrackGuid && trackList.some((t) => t.g === selectedTrackGuid);
    if (currentValid) return;

    const defaultTrack = trackList[0]?.g ?? null;
    if (defaultTrack) {
      setSelectedTrackGuid(defaultTrack);
      saveSelectedTrack(defaultTrack);
    }
  }, [selectedTrackGuid, trackList]);

  // Subscribe/unsubscribe when selected track changes
  useEffect(() => {
    if (!selectedTrackGuid) return;

    void subscribe(selectedTrackGuid);

    return () => {
      unsubscribe();
    };
  }, [selectedTrackGuid, subscribe, unsubscribe]);

  // Handle track selection. The track already chosen is asked for again:
  // REAPER may have refused it, and the user fixed its input since.
  const handleTrackSelect = useCallback(
    (guid: string) => {
      if (guid === selectedTrackGuid) void subscribe(guid);
      setSelectedTrackGuid(guid);
      saveSelectedTrack(guid);
      setShowTrackSelector(false);
    },
    [selectedTrackGuid, subscribe]
  );

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
      {/* Centred by auto margins, so on a short screen it scrolls rather
          than being clipped top and bottom */}
      <div className="h-full overflow-y-auto overscroll-contain flex flex-col p-4">
        <div className="my-auto flex flex-col items-center gap-4">
          <TunerNote noteName={shown.noteName} octave={shown.octave} look={display.note} />
          <TunerMeter cents={shown.cents} tone={display.needle} />
          {/* One line: the frequency, or the message standing in for it.
              Only the message is a live region: the frequency changes 30
              times a second, so a screen reader is told the verdict of a
              stable reading instead. */}
          <div className="text-text-muted text-sm text-center max-w-xs">
            <div role="status">
              {display.message ?? <span className="sr-only">{display.announcement ?? ''}</span>}
            </div>
            {display.message === null && <div className="tabular-nums">{freq.toFixed(2)} Hz</div>}
          </div>
        </div>
      </div>

      {/* Track selector bottom sheet */}
      <BottomSheet
        isOpen={showTrackSelector}
        onClose={() => setShowTrackSelector(false)}
        ariaLabel="Select Track"
      >
        <h2 className="text-lg font-semibold text-text-primary px-4 pb-3">Select Track</h2>
        <div className="max-h-[60dvh] overflow-y-auto">
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
