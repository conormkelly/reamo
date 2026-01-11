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
  BankEditorModal,
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
  useCustomBanks,
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

  // Custom banks from ProjExtState
  const { banks: customBanks, saveBank, deleteBank } = useCustomBanks();
  const [selectedBankId, setSelectedBankId] = useState<string | null>(null);

  // Bank editor modal state
  const [bankModalOpen, setBankModalOpen] = useState(false);
  const [editingBank, setEditingBank] = useState<CustomBank | null>(null);

  // Track filter state
  const [filterQuery, setFilterQuery] = useState('');
  const [filterBankIndex, setFilterBankIndex] = useState(0);

  // Get skeleton for custom bank filtering
  const { skeleton } = useTrackSkeleton();

  // Check if we have any active filtering (custom bank or text filter)
  const hasTextFilter = filterQuery.trim().length > 0;
  const hasCustomBank = selectedBankId !== null;
  const isFiltered = hasTextFilter || hasCustomBank;

  // Get selected custom bank
  const selectedBank = useMemo(
    () => (selectedBankId ? customBanks.find((b) => b.id === selectedBankId) : null),
    [selectedBankId, customBanks]
  );

  // Filter tracks: first by bank (smart or custom), then by text query
  // Uses skeleton - it has ALL tracks regardless of subscription state
  // Keep full track data (with GUIDs) for subscription
  const allFilteredTracks = useMemo(() => {
    if (!isFiltered) return [];

    // Start with all tracks (exclude master at index 0)
    let baseTracks = skeleton.slice(1).map((t, i) => ({ ...t, index: i + 1 }));

    // If bank selected, filter by bank type
    if (selectedBank) {
      if (selectedBank.type === 'smart' && selectedBank.pattern) {
        // Smart bank: filter by pattern (case-insensitive substring match)
        const pattern = selectedBank.pattern.toLowerCase();
        baseTracks = baseTracks.filter((t) => t.n.toLowerCase().includes(pattern));
      } else {
        // Custom bank: filter by specific GUIDs
        const bankGuids = new Set(selectedBank.trackGuids);
        baseTracks = baseTracks.filter((t) => bankGuids.has(t.g));
      }
    }

    // Apply text filter if present (on top of bank filter)
    if (hasTextFilter) {
      const lower = filterQuery.toLowerCase();
      baseTracks = baseTracks.filter((t) => t.n.toLowerCase().includes(lower));
    }

    return baseTracks;
  }, [isFiltered, skeleton, selectedBank, hasTextFilter, filterQuery]);

  // Extract indices for display logic
  const allFilteredIndices = useMemo(
    () => allFilteredTracks.map((t) => t.index),
    [allFilteredTracks]
  );

  // Reset filter bank when filter or bank changes
  useEffect(() => {
    setFilterBankIndex(0);
  }, [filterQuery, selectedBankId]);

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

  // Bank management handlers
  const handleAddBank = useCallback(() => {
    setEditingBank(null);
    setBankModalOpen(true);
  }, []);

  const handleEditBank = useCallback(
    (bankId: string) => {
      const bank = customBanks.find((b) => b.id === bankId);
      if (bank) {
        setEditingBank(bank);
        setBankModalOpen(true);
      }
    },
    [customBanks]
  );

  const handleCloseModal = useCallback(() => {
    setBankModalOpen(false);
    setEditingBank(null);
  }, []);

  const handleSaveBank = useCallback(
    async (bank: CustomBank) => {
      await saveBank(bank);
    },
    [saveBank]
  );

  const handleDeleteBank = useCallback(
    async (bankId: string) => {
      await deleteBank(bankId);
      // If we're deleting the currently selected bank, go back to All Tracks
      if (selectedBankId === bankId) {
        setSelectedBankId(null);
      }
    },
    [deleteBank, selectedBankId]
  );

  // Calculate prefetch range for filtered results (same logic as useBankNavigation)
  const filteredPrefetchBanks = channelCount <= 3 ? 4 : channelCount <= 6 ? 2 : 1;
  const filteredPrefetchCount = filteredPrefetchBanks * channelCount;
  const filteredPrefetchStart = Math.max(0, filteredBankStart - filteredPrefetchCount);
  const filteredPrefetchEnd = Math.min(allFilteredTracks.length, filteredBankEnd + filteredPrefetchCount);

  // Get GUIDs for filtered tracks to subscribe to (current bank + prefetch)
  const filteredGuidsToSubscribe = useMemo(() => {
    if (!isFiltered || allFilteredTracks.length === 0) return [];
    return allFilteredTracks.slice(filteredPrefetchStart, filteredPrefetchEnd).map((t) => t.g);
  }, [isFiltered, allFilteredTracks, filteredPrefetchStart, filteredPrefetchEnd]);

  // Subscribe to tracks - range mode for unfiltered, GUID mode for filtered
  useEffect(() => {
    if (totalTracks === 0) return;

    if (isFiltered) {
      // Filtered: subscribe to specific GUIDs (scattered tracks)
      if (filteredGuidsToSubscribe.length > 0) {
        sendCommand(
          track.subscribe({
            guids: filteredGuidsToSubscribe,
            includeMaster: true,
          })
        );
      }
    } else {
      // Unfiltered: subscribe to range (contiguous tracks)
      sendCommand(
        track.subscribe({
          range: { start: prefetchStart, end: prefetchEnd },
          includeMaster: true,
        })
      );
    }
  }, [sendCommand, isFiltered, filteredGuidsToSubscribe, prefetchStart, prefetchEnd, totalTracks]);

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

      {/* Bank editor modal */}
      <BankEditorModal
        isOpen={bankModalOpen}
        onClose={handleCloseModal}
        onSave={handleSaveBank}
        onDelete={handleDeleteBank}
        editBank={editingBank}
      />
    </div>
  );
}
