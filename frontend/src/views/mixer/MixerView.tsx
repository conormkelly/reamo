/**
 * MixerView - Dedicated mixer with banked faders
 *
 * Features:
 * - Responsive channel count based on screen width
 * - Bank-based navigation (no scroll to prevent accidental fader changes)
 * - Always-visible master track
 * - Track filtering via search or custom banks
 */

import { useState, useEffect, useRef, useCallback, useMemo, type ReactElement } from 'react';
import { ViewHeader } from '../../components';
import {
  MixerStrip,
  BankNavigator,
  BankSelector,
  BankEditorModal,
  TrackInfoBar,
  type CustomBank,
} from '../../components/Mixer';
import { TrackFilter } from '../../components/Track';
import { MixerLockButton } from '../../components/Actions';
import {
  useResponsiveChannelCount,
  useBankNavigation,
  useTrackSkeleton,
  useCustomBanks,
} from '../../hooks';
import { useReaper } from '../../components/ReaperProvider';
import { track } from '../../core/WebSocketCommands';
import { useReaperStore } from '../../store';
import { EMPTY_TRACKS } from '../../store/stableRefs';

/** Storage key for info-selected track */
const INFO_SELECTED_STORAGE_KEY = 'reamo-mixer-info-selected';

/** Fader height for volume mode */
const FADER_HEIGHT = 220;

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

  // Custom banks from ProjExtState
  const { banks: customBanks, saveBank, deleteBank } = useCustomBanks();
  const [selectedBankId, setSelectedBankId] = useState<string | null>(null);

  // Bank editor modal state
  const [bankModalOpen, setBankModalOpen] = useState(false);
  const [editingBank, setEditingBank] = useState<CustomBank | null>(null);

  // Track filter state
  const [filterQuery, setFilterQuery] = useState('');
  const [filterBankIndex, setFilterBankIndex] = useState(0);

  // Track info selection state (which track shows in InfoBar) - persisted in localStorage
  const [infoSelectedTrackIdx, setInfoSelectedTrackIdx] = useState<number | null>(() => {
    try {
      const stored = localStorage.getItem(INFO_SELECTED_STORAGE_KEY);
      if (stored !== null) {
        const parsed = parseInt(stored, 10);
        return isNaN(parsed) ? null : parsed;
      }
    } catch {
      // Ignore localStorage errors
    }
    return null;
  });

  // Persist info selection to localStorage
  useEffect(() => {
    try {
      if (infoSelectedTrackIdx !== null) {
        localStorage.setItem(INFO_SELECTED_STORAGE_KEY, String(infoSelectedTrackIdx));
      } else {
        localStorage.removeItem(INFO_SELECTED_STORAGE_KEY);
      }
    } catch {
      // Ignore localStorage errors
    }
  }, [infoSelectedTrackIdx]);

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
      <div className="flex-1 flex items-center justify-center gap-2 overflow-hidden pb-2">
        {/* Master track - always visible, on left */}
        <div className="border-r pr-2 border-border-subtle">
          {hasTrackData(0) ? (
            <MixerStrip
              trackIndex={0}
              mode="volume"
              faderHeight={FADER_HEIGHT}
              showDbLabel={true}
              isInfoSelected={infoSelectedTrackIdx === 0}
              onSelectForInfo={setInfoSelectedTrackIdx}
            />
          ) : (
            // Loading placeholder for master
            <div
              className="bg-bg-surface/50 rounded-lg animate-pulse"
              style={{ width: 80, height: FADER_HEIGHT + 100 }}
            />
          )}
        </div>

        {/* Channel strips */}
        <div className="flex gap-2">
          {displayTrackIndices.map((trackIndex) => (
            <div key={trackIndex}>
              {hasTrackData(trackIndex) ? (
                <MixerStrip
                  trackIndex={trackIndex}
                  mode="volume"
                  faderHeight={FADER_HEIGHT}
                  showDbLabel={true}
                  isInfoSelected={infoSelectedTrackIdx === trackIndex}
                  onSelectForInfo={setInfoSelectedTrackIdx}
                />
              ) : (
                // Loading placeholder
                <div
                  className="bg-bg-surface/50 rounded-lg animate-pulse"
                  style={{ width: 80, height: FADER_HEIGHT + 100 }}
                />
              )}
            </div>
          ))}
        </div>
      </div>

      {/* Track info bar - shows when a track is selected */}
      <TrackInfoBar
        selectedTrackIdx={infoSelectedTrackIdx}
        className="mt-2"
      />

      {/* Footer controls - filter and bank navigation inline */}
      <div className="pt-2 border-t border-border-subtle">
        <div className="flex items-center gap-3">
          {/* Track filter on left - takes remaining space, pushes bank nav right */}
          <TrackFilter
            value={filterQuery}
            onChange={setFilterQuery}
            placeholder="Filter..."
            hideCount
            className="flex-1"
          />

          {/* Bank navigator on right */}
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
