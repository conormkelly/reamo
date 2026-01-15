/**
 * TimelineView - Dedicated full-screen timeline view
 *
 * "Arrangement view for touch" - see and edit project structure (items, regions, markers)
 *
 * Phase 3: Multi-track lanes with bank navigation
 * Phase 3.5: Filter and BankSelector (consistent with Mixer)
 *
 * Layout (from vision doc):
 * - Bank controls (prev/next, display)
 * - Region labels bar
 * - Track lanes (main timeline) ← MultiTrackLanes
 * - Marker pills
 * - Contextual info bar (marker/item)
 * - Quick Actions Toolbar (future, collapsible)
 */

import { useMemo, useState, useCallback, useRef, useEffect, type ReactElement } from 'react';
import { ViewHeader } from '../../components';
import {
  Timeline,
  RegionInfoBar,
  RegionEditActionBar,
  MarkerInfoBar,
  TimelineModeToggle,
  NavigateItemInfoBar,
} from '../../components';
import {
  BankNavigator,
  BankSelector,
  BankEditorModal,
  type CustomBank,
} from '../../components/Mixer';
import { TrackFilter } from '../../components/Track';
import { useReaperStore } from '../../store';
import { EMPTY_REGIONS, EMPTY_MARKERS, EMPTY_ITEMS } from '../../store/stableRefs';
import { useViewport, useTransport, useBankNavigation, useCustomBanks, useTrackSkeleton } from '../../hooks';

/** Duration to show track labels after bank switch (ms) */
const BANK_SWITCH_LABEL_DURATION = 1000;

/** Timeline height - taller to accommodate multi-track lanes */
const TIMELINE_HEIGHT = 200;

/** Number of track lanes to show per bank */
const LANE_COUNT = 4;

export function TimelineView(): ReactElement {
  const timelineMode = useReaperStore((s) => s.timelineMode);
  const regions = useReaperStore((s) => s?.regions ?? EMPTY_REGIONS);
  const markers = useReaperStore((s) => s?.markers ?? EMPTY_MARKERS);
  const items = useReaperStore((s) => s?.items ?? EMPTY_ITEMS);
  const openAddRegionModal = useReaperStore((s) => s.openAddRegionModal);
  const selectedMarkerId = useReaperStore((s) => s.selectedMarkerId);
  const itemSelectionModeActive = useReaperStore((s) => s.itemSelectionModeActive);
  const totalTracks = useReaperStore((s) => s?.totalTracks ?? 0);
  const { positionSeconds } = useTransport();

  // Get skeleton from hook (same pattern as Mixer)
  const { skeleton } = useTrackSkeleton();

  // Bank navigation - pages through tracks in groups of LANE_COUNT
  const bank = useBankNavigation({
    channelCount: LANE_COUNT,
    totalTracks,
    storageKey: 'reamo-timeline-bank',
  });

  // Custom banks from ProjExtState (shared with Mixer)
  const { banks: customBanks, saveBank, deleteBank } = useCustomBanks();
  const [selectedBankId, setSelectedBankId] = useState<string | null>(null);

  // Bank editor modal state
  const [bankModalOpen, setBankModalOpen] = useState(false);
  const [editingBank, setEditingBank] = useState<CustomBank | null>(null);

  // Track filter state
  const [filterQuery, setFilterQuery] = useState('');
  const [filterBankIndex, setFilterBankIndex] = useState(0);

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
  const filteredBankStart = filterBankIndex * LANE_COUNT;
  const filteredBankEnd = Math.min(filteredBankStart + LANE_COUNT, allFilteredIndices.length);
  const filteredTotalBanks = Math.ceil(allFilteredIndices.length / LANE_COUNT);

  // Get the track indices to display (filtered or regular bank)
  const displayTrackIndices = useMemo(() => {
    if (isFiltered) {
      return allFilteredIndices.slice(filteredBankStart, filteredBankEnd);
    }
    return bank.trackIndices;
  }, [isFiltered, allFilteredIndices, filteredBankStart, filteredBankEnd, bank.trackIndices]);

  // Get tracks for current display (skeleton indices are 0-based, displayTrackIndices are 1-based)
  const laneTracks = useMemo(() => {
    return displayTrackIndices.map((idx) => skeleton[idx]).filter(Boolean);
  }, [displayTrackIndices, skeleton]);

  // Bank display and navigation for filtered vs unfiltered
  const effectiveBankDisplay = isFiltered
    ? allFilteredIndices.length === 0
      ? '0 of 0'
      : `${filteredBankStart + 1}-${filteredBankEnd} of ${allFilteredIndices.length}`
    : bank.bankDisplay;

  const effectiveCanGoBack = isFiltered ? filterBankIndex > 0 : bank.canGoBack;
  const effectiveCanGoForward = isFiltered ? filterBankIndex < filteredTotalBanks - 1 : bank.canGoForward;

  // Bank management handlers
  const handleAddBank = useCallback(() => {
    setEditingBank(null);
    setBankModalOpen(true);
  }, []);

  const handleEditBank = useCallback(
    (bankId: string) => {
      const foundBank = customBanks.find((b) => b.id === bankId);
      if (foundBank) {
        setEditingBank(foundBank);
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
    async (bankToSave: CustomBank) => {
      await saveBank(bankToSave);
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

  // Track labels overlay state (hold bank display OR bank switch to show)
  const [showTrackLabels, setShowTrackLabels] = useState(false);
  const isHoldingRef = useRef(false);
  const autoHideTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const handleHoldStart = useCallback(() => {
    isHoldingRef.current = true;
    // Clear any auto-hide timer when user starts holding
    if (autoHideTimerRef.current) {
      clearTimeout(autoHideTimerRef.current);
      autoHideTimerRef.current = null;
    }
    setShowTrackLabels(true);
  }, []);

  const handleHoldEnd = useCallback(() => {
    isHoldingRef.current = false;
    setShowTrackLabels(false);
  }, []);

  // Show labels briefly on bank switch
  const showLabelsTemporarily = useCallback(() => {
    // Don't interrupt if user is holding
    if (isHoldingRef.current) return;

    // Clear existing timer
    if (autoHideTimerRef.current) {
      clearTimeout(autoHideTimerRef.current);
    }

    setShowTrackLabels(true);
    autoHideTimerRef.current = setTimeout(() => {
      // Only hide if not being held
      if (!isHoldingRef.current) {
        setShowTrackLabels(false);
      }
      autoHideTimerRef.current = null;
    }, BANK_SWITCH_LABEL_DURATION);
  }, []);

  // Cleanup timer on unmount
  useEffect(() => {
    return () => {
      if (autoHideTimerRef.current) {
        clearTimeout(autoHideTimerRef.current);
      }
    };
  }, []);

  // Wrap bank navigation to show labels (handles filtered vs unfiltered)
  const handleBankBack = useCallback(() => {
    if (isFiltered) {
      setFilterBankIndex((prev) => Math.max(0, prev - 1));
    } else {
      bank.goBack();
    }
    showLabelsTemporarily();
  }, [isFiltered, bank, showLabelsTemporarily]);

  const handleBankForward = useCallback(() => {
    if (isFiltered) {
      setFilterBankIndex((prev) => Math.min(filteredTotalBanks - 1, prev + 1));
    } else {
      bank.goForward();
    }
    showLabelsTemporarily();
  }, [isFiltered, bank, filteredTotalBanks, showLabelsTemporarily]);

  // Calculate project duration from content
  const projectDuration = useMemo(() => {
    let end = 0;

    for (const region of regions) {
      if (region.end > end) end = region.end;
    }
    for (const marker of markers) {
      if (marker.position > end) end = marker.position;
    }
    for (const item of items) {
      const itemEnd = item.position + item.length;
      if (itemEnd > end) end = itemEnd;
    }
    // Include playhead position
    if (positionSeconds > end) end = positionSeconds;

    // Add 5% padding at the end, minimum 30 seconds
    return Math.max(end * 1.05, 30);
  }, [regions, markers, items, positionSeconds]);

  // Shared viewport state
  const viewport = useViewport({
    projectDuration,
    initialRange: { start: 0, end: Math.min(30, projectDuration) },
  });

  return (
    <div className="h-full bg-bg-app text-text-primary p-3 flex flex-col">
      {/* Header - bank selector, mode toggle */}
      <ViewHeader currentView="timeline">
        <BankSelector
          selectedBankId={selectedBankId}
          banks={customBanks}
          onBankChange={setSelectedBankId}
          onAddBank={handleAddBank}
          onEditBank={handleEditBank}
          isFiltered={isFiltered}
        />
        <TimelineModeToggle />
      </ViewHeader>

      {/* Main timeline area - takes available space */}
      <div className="flex-1 flex flex-col min-h-0 mt-2">
        {/* Timeline canvas with multi-track lanes */}
        <div className="relative">
          <Timeline
            height={TIMELINE_HEIGHT}
            viewport={viewport}
            multiTrackLanes={laneTracks}
            multiTrackIndices={displayTrackIndices}
          />

          {/* Track labels overlay - shown when holding bank display or switching banks */}
          {showTrackLabels && laneTracks.length > 0 && (
            <div
              className="absolute inset-0 pointer-events-none z-30"
              style={{ top: 57 }} // Skip ruler (32px) + region labels bar (25px)
            >
              {laneTracks.map((track, laneIdx) => {
                const trackIdx = displayTrackIndices[laneIdx];
                const laneHeight = TIMELINE_HEIGHT / laneTracks.length;
                return (
                  <div
                    key={track.g}
                    className="absolute left-0 right-0 flex items-center justify-center"
                    style={{
                      top: laneIdx * laneHeight,
                      height: laneHeight,
                    }}
                  >
                    <div className="flex items-stretch rounded-lg overflow-hidden shadow-lg border-2 border-black/60">
                      {/* Track number - rounded left, dark background for contrast */}
                      <div className="bg-bg-deep px-3 py-1.5 flex items-center justify-center min-w-[36px] border-r border-black/40">
                        <span className="text-xs font-bold text-text-primary tabular-nums">
                          {trackIdx}
                        </span>
                      </div>
                      {/* Track name */}
                      <div className="bg-bg-surface/95 backdrop-blur-sm px-3 py-1.5 flex items-center">
                        <span className="text-sm font-medium text-text-primary">
                          {track.n}
                        </span>
                      </div>
                    </div>
                  </div>
                );
              })}
            </div>
          )}
        </div>

        {/* Region info bar */}
        <RegionInfoBar
          className="mt-3"
          onAddRegion={timelineMode === 'regions' ? openAddRegionModal : undefined}
        />
        <div className="mt-2">
          <RegionEditActionBar />
        </div>

        {/* Marker/Item Info - only shown in navigate mode */}
        {timelineMode === 'navigate' && (
          <section data-testid="navigate-info-section" className="mt-4 flex flex-col gap-2">
            {/* Marker info bar - shown when a marker is selected */}
            <MarkerInfoBar />
            {/* Item info bar - shown when in item selection mode */}
            {itemSelectionModeActive && <NavigateItemInfoBar />}
            {/* Fallback when nothing is active */}
            {selectedMarkerId === null && !itemSelectionModeActive && (
              <div
                data-testid="nothing-selected-message"
                className="px-3 py-2 text-text-muted text-sm text-center"
              >
                Tap a marker pill or item blob to select
              </div>
            )}
          </section>
        )}
      </div>

      {/* Footer - filter and bank navigation (same pattern as Mixer) */}
      <div className="pt-2 border-t border-border-subtle">
        <div className="flex items-center gap-3">
          {/* Track filter on left - takes remaining space */}
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
            onBack={handleBankBack}
            onForward={handleBankForward}
            onHoldStart={handleHoldStart}
            onHoldEnd={handleHoldEnd}
          />
        </div>
      </div>

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
