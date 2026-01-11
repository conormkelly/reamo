/**
 * MixerView - Dedicated mixer with banked faders
 *
 * Features:
 * - Responsive channel count based on screen width
 * - Bank-based navigation (no scroll to prevent accidental fader changes)
 * - Mode switching: Volume (max faders) / Mix (full controls) / Sends (gold faders)
 * - Always-visible master track
 */

import { useState, useEffect, useRef, useCallback, useMemo, type ReactElement } from 'react';
import { ViewHeader } from '../../components';
import {
  MixerStrip,
  BankNavigator,
  MixerModeSelector,
  SendStrip,
  SendDestinationSelector,
  BankSelector,
  type MixerMode,
  type CustomBank,
} from '../../components/Mixer';
import { TrackFilter } from '../../components/Track';
import { MixerLockButton } from '../../components/Actions';
import {
  useResponsiveChannelCount,
  useBankNavigation,
  useTrackSkeleton,
  useSends,
} from '../../hooks';
import { useReaper } from '../../components/ReaperProvider';
import { track } from '../../core/WebSocketCommands';
import { useReaperStore } from '../../store';
import { EMPTY_TRACKS } from '../../store/stableRefs';

/** Storage key for mixer mode preference */
const MODE_STORAGE_KEY = 'reamo-mixer-mode';

/** Fader heights by mode */
const FADER_HEIGHTS: Record<MixerMode, number> = {
  volume: 220,
  mix: 160,
  sends: 180,
};

export function MixerView(): ReactElement {
  const containerRef = useRef<HTMLDivElement>(null);
  const { sendCommand } = useReaper();
  const { totalTracks } = useTrackSkeleton();
  const tracks = useReaperStore((state) => state?.tracks ?? EMPTY_TRACKS);

  // Responsive channel count
  const { channelCount } = useResponsiveChannelCount({
    containerRef,
    showMaster: true,
  });

  // Bank navigation
  const {
    trackIndices,
    prefetchStart,
    prefetchEnd,
    canGoBack,
    canGoForward,
    goBack,
    goForward,
    bankDisplay,
  } = useBankNavigation({
    channelCount,
    totalTracks,
  });

  // Mode state with localStorage persistence
  const [mode, setMode] = useState<MixerMode>(() => {
    try {
      const stored = localStorage.getItem(MODE_STORAGE_KEY);
      if (stored === 'volume' || stored === 'mix' || stored === 'sends') {
        return stored;
      }
    } catch {
      // Ignore localStorage errors
    }
    return 'volume';
  });

  // Persist mode to localStorage
  useEffect(() => {
    try {
      localStorage.setItem(MODE_STORAGE_KEY, mode);
    } catch {
      // Ignore localStorage errors
    }
  }, [mode]);

  // Sends mode state
  const { destinations } = useSends();
  const [selectedDestIdx, setSelectedDestIdx] = useState<number | null>(null);

  // Auto-select first destination when entering sends mode or when destinations change
  useEffect(() => {
    if (mode === 'sends' && destinations.length > 0) {
      // If no destination selected, or selected destination no longer exists, select first
      if (selectedDestIdx === null || !destinations.find((d) => d.trackIdx === selectedDestIdx)) {
        setSelectedDestIdx(destinations[0].trackIdx);
      }
    }
  }, [mode, destinations, selectedDestIdx]);

  // Get the name of the selected destination for SendStrip
  const selectedDestName = destinations.find((d) => d.trackIdx === selectedDestIdx)?.name ?? '';

  // Custom banks state (skeleton - non-functional for now)
  const [customBanks] = useState<CustomBank[]>([]);
  const [selectedBankId, setSelectedBankId] = useState<string | null>(null);

  // Track filter state
  const [filterQuery, setFilterQuery] = useState('');
  const [filterBankIndex, setFilterBankIndex] = useState(0);

  const isFiltered = filterQuery.trim().length > 0;

  // Filter ALL tracks by query (case-insensitive name match)
  const allFilteredIndices = useMemo(() => {
    if (!isFiltered) return [];
    const query = filterQuery.toLowerCase().trim();
    const indices: number[] = [];
    // Filter all non-master tracks (1 to totalTracks)
    for (let i = 1; i <= totalTracks; i++) {
      const track = tracks[i];
      if (track?.name?.toLowerCase().includes(query)) {
        indices.push(i);
      }
    }
    return indices;
  }, [filterQuery, totalTracks, tracks, isFiltered]);

  // Reset filter bank when filter changes
  useEffect(() => {
    setFilterBankIndex(0);
  }, [filterQuery]);

  // Calculate filtered banking
  const filteredBankStart = filterBankIndex * channelCount;
  const filteredBankEnd = Math.min(filteredBankStart + channelCount, allFilteredIndices.length);
  const filteredTotalBanks = Math.ceil(allFilteredIndices.length / channelCount);

  // Get the track indices to display
  const displayTrackIndices = useMemo(() => {
    if (isFiltered) {
      return allFilteredIndices.slice(filteredBankStart, filteredBankEnd);
    }
    return trackIndices;
  }, [isFiltered, allFilteredIndices, filteredBankStart, filteredBankEnd, trackIndices]);

  // Bank display and navigation for filtered vs unfiltered
  // When filtered, show range within filtered results: "1-6 of 10" (showing 1-6 of 10 matches)
  const effectiveBankDisplay = isFiltered
    ? allFilteredIndices.length === 0
      ? '0 of 0'
      : `${filteredBankStart + 1}-${filteredBankEnd} of ${allFilteredIndices.length}`
    : bankDisplay;

  const effectiveCanGoBack = isFiltered ? filterBankIndex > 0 : canGoBack;
  const effectiveCanGoForward = isFiltered ? filterBankIndex < filteredTotalBanks - 1 : canGoForward;

  const handleBack = useCallback(() => {
    if (isFiltered) {
      setFilterBankIndex((prev) => Math.max(0, prev - 1));
    } else {
      goBack();
    }
  }, [isFiltered, goBack]);

  const handleForward = useCallback(() => {
    if (isFiltered) {
      setFilterBankIndex((prev) => Math.min(filteredTotalBanks - 1, prev + 1));
    } else {
      goForward();
    }
  }, [isFiltered, goForward, filteredTotalBanks]);

  // Bank management handlers (skeleton - non-functional for now)
  const handleAddBank = useCallback(() => {
    // TODO: Open modal to create new bank
    console.log('Add bank - not yet implemented');
  }, []);

  const handleEditBank = useCallback((bankId: string) => {
    // TODO: Open modal to edit bank
    console.log('Edit bank:', bankId, '- not yet implemented');
  }, []);

  // Subscribe to prefetch range (current bank + adjacent banks for smooth navigation)
  const subscribeToBank = useCallback(() => {
    if (totalTracks === 0) return;

    // Subscribe to prefetch range plus master - includes adjacent banks to prevent flash on navigation
    sendCommand(
      track.subscribe({
        range: { start: prefetchStart, end: prefetchEnd },
        includeMaster: true,
      })
    );
  }, [sendCommand, prefetchStart, prefetchEnd, totalTracks]);

  // Subscribe when bank changes
  useEffect(() => {
    subscribeToBank();
  }, [subscribeToBank]);

  // Check if we have data for a track
  const hasTrackData = (trackIndex: number): boolean => {
    return !!tracks[trackIndex];
  };

  // Fader height based on mode
  const faderHeight = FADER_HEIGHTS[mode];

  // Show dB labels:
  // - Always show in Volume mode (bigger faders = more room)
  // - Hide on narrow screens (3 or fewer channels) for Mix/Sends to prevent strip resizing
  const showDbLabel = mode === 'volume' || channelCount > 3;

  return (
    <div
      ref={containerRef}
      className="h-full bg-bg-app text-text-primary p-3 flex flex-col"
    >
      {/* Header - settings, bank selector, lock, connection */}
      <ViewHeader currentView="mixer">
        <BankSelector
          selectedBankId={selectedBankId}
          banks={customBanks}
          onBankChange={setSelectedBankId}
          onAddBank={handleAddBank}
          onEditBank={handleEditBank}
          isFiltered={isFiltered}
        />
        <MixerLockButton />
      </ViewHeader>

      {/* Main mixer area */}
      <div className="flex-1 flex items-start justify-center gap-2 overflow-hidden pb-2">
        {/* Master track - always visible, on left */}
        <div className={`border-r pr-2 ${mode === 'sends' ? 'border-amber-500/30' : 'border-border-subtle'}`}>
          {hasTrackData(0) ? (
            mode === 'sends' && selectedDestIdx !== null ? (
              <SendStrip
                trackIndex={0}
                destTrackIdx={selectedDestIdx}
                destName={selectedDestName}
                faderHeight={faderHeight}
                showDbLabel={showDbLabel}
              />
            ) : (
              <MixerStrip
                trackIndex={0}
                mode={mode}
                faderHeight={faderHeight}
                showDbLabel={showDbLabel}
              />
            )
          ) : (
            // Loading placeholder for master
            <div
              className="bg-bg-surface/50 rounded-lg animate-pulse"
              style={{ width: 80, height: faderHeight + 100 }}
            />
          )}
        </div>

        {/* Channel strips */}
        <div className="flex gap-2">
          {displayTrackIndices.map((trackIndex) => (
            <div key={trackIndex}>
              {hasTrackData(trackIndex) ? (
                mode === 'sends' && selectedDestIdx !== null ? (
                  <SendStrip
                    trackIndex={trackIndex}
                    destTrackIdx={selectedDestIdx}
                    destName={selectedDestName}
                    faderHeight={faderHeight}
                    showDbLabel={showDbLabel}
                  />
                ) : (
                  <MixerStrip
                    trackIndex={trackIndex}
                    mode={mode}
                    faderHeight={faderHeight}
                    showDbLabel={showDbLabel}
                  />
                )
              ) : (
                // Loading placeholder
                <div
                  className="bg-bg-surface/50 rounded-lg animate-pulse"
                  style={{ width: 80, height: faderHeight + 100 }}
                />
              )}
            </div>
          ))}
        </div>
      </div>

      {/* Footer controls */}
      <div className={`pt-2 border-t ${mode === 'sends' ? 'border-amber-500/30' : 'border-border-subtle'}`}>
        {/* Track filter - above mode controls */}
        <TrackFilter
          value={filterQuery}
          onChange={setFilterQuery}
          placeholder="Filter tracks..."
          hideCount
          className="mb-2"
        />

        {/* Mode selector left, destination selector center (sends mode), bank navigator right */}
        <div className="flex items-center justify-between">
          <MixerModeSelector mode={mode} onModeChange={setMode} />
          {/* Destination selector (sends mode only) */}
          {mode === 'sends' && selectedDestIdx !== null && (
            <SendDestinationSelector
              selectedDestIdx={selectedDestIdx}
              onDestinationChange={setSelectedDestIdx}
            />
          )}
          <BankNavigator
            bankDisplay={effectiveBankDisplay}
            canGoBack={effectiveCanGoBack}
            canGoForward={effectiveCanGoForward}
            onBack={handleBack}
            onForward={handleForward}
          />
        </div>
      </div>

      {/* Empty state */}
      {totalTracks === 0 && (
        <div className="absolute inset-0 flex items-center justify-center">
          <div className="text-text-muted text-center">
            <p className="text-lg mb-2">No tracks in project</p>
            <p className="text-sm">Add tracks in REAPER to see them here</p>
          </div>
        </div>
      )}
    </div>
  );
}
