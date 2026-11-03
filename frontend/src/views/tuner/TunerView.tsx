/**
 * TunerView - Chromatic tuner for instrument tuning
 *
 * Tunes one source at a time: the master output, or a track (REAPER reads
 * the hardware input the track records from, armed or not). Shows:
 * - Note name and octave (large display)
 * - Cents deviation meter (-50 to +50)
 * - Frequency, or what stands in for it: why the track's input can't be
 *   tuned (REAPER's own message), that REAPER's audio device isn't
 *   running, that several notes sound, that a note is starting, or that
 *   readings have stopped arriving
 * - Source selector: the master output, then the tracks (defaults to the
 *   first track). Choosing the source already chosen asks REAPER again,
 *   after the user has fixed its input.
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
import { useSettled } from './useSettled';

/** The GUID the master output is tuned by (and its entry in the track skeleton). */
const MASTER = 'master';
const MASTER_LABEL = 'Master output';
/** How long what a screen reader is told must hold before it is said. */
const SPOKEN_SETTLE_MS = 300;

// Load the chosen source's GUID from localStorage
function loadSelectedTrack(): string | null {
  try {
    return localStorage.getItem('tuner-track') || null;
  } catch {
    return null;
  }
}

// Save the chosen source's GUID to localStorage
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

function trackLabel(guid: string, name: string): string {
  return name || `Track ${guid.slice(1, 8)}`;
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
    heard,
    stale,
    problem,
    referenceHz,
    setReferenceHz,
    thresholdDb,
    setThresholdDb,
  } = useTuner();

  // Source selection state - initialize from localStorage to survive orientation changes
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
    heard,
    stale,
  });

  const spoken = useSettled(display.spoken, SPOKEN_SETTLE_MS);

  // The track skeleton always holds the master once it has arrived
  const tracks = useReaperStore((s) => s.trackSkeleton ?? EMPTY_SKELETON);
  const skeletonLoaded = tracks.length > 0;

  // The tracks; the master is offered apart, first, as the master output
  const trackList = tracks.filter((t) => t.g !== MASTER);

  // Name of the current selection
  const selectedTrack = trackList.find((t) => t.g === selectedTrackGuid);
  const sourceName =
    selectedTrackGuid === MASTER
      ? MASTER_LABEL
      : selectedTrack
        ? trackLabel(selectedTrack.g, selectedTrack.n)
        : 'Select source';

  // Choose a source: the saved one while it is still there, else the first
  // track, else the master output. Waits for the track list, so a saved
  // track isn't taken for gone before the list arrives.
  useEffect(() => {
    if (!skeletonLoaded) return;
    const currentValid =
      selectedTrackGuid === MASTER || (selectedTrackGuid !== null && trackList.some((t) => t.g === selectedTrackGuid));
    if (currentValid) return;

    const fallback = trackList[0]?.g ?? MASTER;
    setSelectedTrackGuid(fallback);
    saveSelectedTrack(fallback);
  }, [selectedTrackGuid, trackList, skeletonLoaded]);

  // Subscribe/unsubscribe when the chosen source changes
  useEffect(() => {
    if (!selectedTrackGuid) return;

    void subscribe(selectedTrackGuid);

    return () => {
      unsubscribe();
    };
  }, [selectedTrackGuid, subscribe, unsubscribe]);

  // Handle source selection. The source already chosen is asked for again:
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
            {/* Source selector button */}
            <button
              onClick={() => setShowTrackSelector(true)}
              aria-haspopup="dialog"
              className="flex items-center gap-2 px-3 py-1.5 rounded-lg bg-bg-elevated hover:bg-bg-hover transition-colors text-sm font-medium"
            >
              <span className="truncate max-w-[140px]">{sourceName}</span>
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
              A screen reader is told only what tunerDisplay says to speak,
              once it has held (useSettled): not the frequency, which
              changes 30 times a second, nor a verdict wavering at an edge. */}
          <div className="text-text-muted text-sm text-center max-w-xs min-h-5">
            {display.message ?? <span className="tabular-nums">{freq.toFixed(2)} Hz</span>}
            <div role="status" className="sr-only">
              {spoken}
            </div>
          </div>
        </div>
      </div>

      {/* Source selector bottom sheet */}
      <BottomSheet isOpen={showTrackSelector} onClose={() => setShowTrackSelector(false)} ariaLabel="Tune">
        <h2 className="text-lg font-semibold text-text-primary px-4 pb-3">Tune</h2>
        <div className="max-h-[60dvh] overflow-y-auto">
          <div className="flex flex-col">
            <SourceOption
              label={MASTER_LABEL}
              selected={selectedTrackGuid === MASTER}
              onSelect={() => handleTrackSelect(MASTER)}
            />
            <div className="mx-4 my-1 border-t border-border-muted" role="separator" />
            {trackList.length === 0 ? (
              <p className="text-center text-text-tertiary py-6">No tracks</p>
            ) : (
              trackList.map((track) => (
                <SourceOption
                  key={track.g}
                  label={trackLabel(track.g, track.n)}
                  selected={track.g === selectedTrackGuid}
                  onSelect={() => handleTrackSelect(track.g)}
                />
              ))
            )}
          </div>
        </div>
      </BottomSheet>
    </ViewLayout>
  );
}

function SourceOption({
  label,
  selected,
  onSelect,
}: {
  label: string;
  selected: boolean;
  onSelect: () => void;
}): ReactElement {
  return (
    <button
      onClick={onSelect}
      aria-current={selected ? 'true' : undefined}
      className={`flex items-center justify-between px-4 py-3 hover:bg-bg-hover transition-colors ${
        selected ? 'bg-bg-elevated' : ''
      }`}
    >
      <span className="truncate">{label}</span>
      {selected && (
        <span className="text-primary" aria-hidden="true">
          ✓
        </span>
      )}
    </button>
  );
}
