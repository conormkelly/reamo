/**
 * MixerView - Dedicated mixer with banked faders
 *
 * Features:
 * - Responsive channel count based on screen width
 * - Bank-based navigation (no scroll to prevent accidental fader changes)
 * - Optional pinned master track (Settings → Mixer → Pin MASTER)
 * - Track filtering via search or custom banks
 */

import { useState, useEffect, useRef, useCallback, useMemo, type ReactElement } from 'react';
import { ViewHeader, ViewLayout, SecondaryPanel, type SecondaryPanelTabConfig, type BankNavProps, type SearchProps } from '../../components';
import {
  MixerStrip,
  MixerStripCompact,
  BankSelector,
  BankEditorModal,
  TrackInfoBar,
  RoutingModal,
  CreateTrackModal,
  FolderNavSheet,
  QuickFilterDropdown,
  isBuiltinBank,
  type CustomBank,
  type BuiltinBankId,
} from '../../components/Mixer';
import { Plus, Info } from 'lucide-react';
import {
  useResponsiveChannelCount,
  useBankNavigation,
  useTrackSkeleton,
  useCustomBanks,
  useFolderHierarchy,
  useAvailableContentHeight,
} from '../../hooks';
import { useReaper } from '../../components/ReaperProvider';
import { track } from '../../core/WebSocketCommands';
import { useReaperStore } from '../../store';
import { EMPTY_TRACKS, EMPTY_STRING_ARRAY } from '../../store/stableRefs';
import {
  STRIP_OVERHEAD_FULL,
  STRIP_OVERHEAD_COMPACT,
  MIN_FADER_PORTRAIT,
  MIN_FADER_LANDSCAPE,
  MAX_FADER_PERCENT,
  MIXER_CONTENT_PADDING,
} from '../../constants/layout';

/** Storage key for info-selected track */
const INFO_SELECTED_STORAGE_KEY = 'reamo-mixer-info-selected';

export function MixerView(): ReactElement {
  const containerRef = useRef<HTMLDivElement>(null);
  const { sendCommand } = useReaper();
  const { totalTracks } = useTrackSkeleton();
  const tracks = useReaperStore((state) => state?.tracks ?? EMPTY_TRACKS);
  const pinMasterTrack = useReaperStore((state) => state.pinMasterTrack);
  const showAddTrackButton = useReaperStore((state) => state.showAddTrackButton);
  const setSecondaryPanelExpanded = useReaperStore((state) => state.setSecondaryPanelExpanded);
  const setSideRailBankNav = useReaperStore((state) => state.setSideRailBankNav);
  const setSideRailBankNavCallbacks = useReaperStore((state) => state.setSideRailBankNavCallbacks);
  const setSideRailInfo = useReaperStore((state) => state.setSideRailInfo);
  const setSideRailSearch = useReaperStore((state) => state.setSideRailSearch);

  // Responsive height measurement - tracks container size and panel transitions
  // Also provides layout context for side rail mode detection
  const { availableHeight, isLandscape, isLandscapeConstrained } = useAvailableContentHeight({
    containerRef,
    viewId: 'mixer',
  });

  // Dynamic fader height based on measured container height and orientation
  // Budget = availableHeight - container padding - strip overhead
  // The strip must fit entirely within this budget
  const faderHeight = useMemo(() => {
    const minFader = isLandscape ? MIN_FADER_LANDSCAPE : MIN_FADER_PORTRAIT;
    const overhead = isLandscape ? STRIP_OVERHEAD_COMPACT : STRIP_OVERHEAD_FULL;

    if (availableHeight === 0) return minFader; // Initial render before measurement

    // Total budget for strip = container height minus padding
    const stripBudget = availableHeight - MIXER_CONTENT_PADDING;
    // Fader height = budget minus non-fader overhead
    const calculated = stripBudget - overhead;

    return Math.min(
      Math.max(minFader, calculated), // Floor: touch usability minimum
      stripBudget * MAX_FADER_PERCENT  // Ceiling: prevent overflow in edge cases
    );
  }, [availableHeight, isLandscape]);

  // Responsive channel count - accounts for pinned master taking space
  const { channelCount } = useResponsiveChannelCount({
    containerRef,
    masterPinned: pinMasterTrack,
  });

  // Bank navigation - include master in banks when not pinned
  const {
    trackIndices,
    prefetchStart,
    prefetchEnd,
    canGoBack,
    canGoForward,
    goBack,
    goForward,
    bankDisplay,
    totalCount,
  } = useBankNavigation({
    channelCount,
    totalTracks,
    includeMaster: !pinMasterTrack,
  });

  // Custom banks from ProjExtState
  const { banks: customBanks, saveBank, deleteBank } = useCustomBanks();

  // Filter state from store (persisted across view switches)
  const viewFilters = useReaperStore((s) => s.viewFilters.mixer);
  const setSelectedBankId = useReaperStore((s) => s.setSelectedBankId);
  const setFilterQuery = useReaperStore((s) => s.setFilterQuery);
  const setFilterBankIndex = useReaperStore((s) => s.setFilterBankIndex);
  const setFolderPath = useReaperStore((s) => s.setFolderPath);
  // Destructure for convenience
  const { selectedBankId, filterQuery, filterBankIndex, folderPath } = viewFilters;

  // Folder navigation state (sheet visibility is ephemeral, path is persisted)
  // Declared before handleSetSelectedBankId which uses setFolderSheetOpen
  const [folderSheetOpen, setFolderSheetOpen] = useState(false);
  const { getChildren: getFolderChildren, validatePath } = useFolderHierarchy();

  // Wrapped setters that bind viewId
  // handleSetSelectedBankId also handles folder sheet side effects (open/close sheet, clear path)
  const handleSetSelectedBankId = useCallback((bankId: string | null) => {
    setSelectedBankId('mixer', bankId);
    // Open folder sheet when switching TO Folders bank, close and clear path otherwise
    if (bankId === 'builtin:folders') {
      setFolderSheetOpen(true);
    } else {
      setFolderPath('mixer', []);
      setFolderSheetOpen(false);
    }
  }, [setSelectedBankId, setFolderPath]);
  const handleSetFilterQuery = useCallback((query: string) => {
    setFilterQuery('mixer', query);
  }, [setFilterQuery]);
  const handleSetFilterBankIndex = useCallback((index: number) => {
    setFilterBankIndex('mixer', index);
  }, [setFilterBankIndex]);
  const handleSetFolderPath = useCallback((path: string[]) => {
    setFolderPath('mixer', path);
  }, [setFolderPath]);

  // Bank editor modal state
  const [bankModalOpen, setBankModalOpen] = useState(false);
  const [editingBank, setEditingBank] = useState<CustomBank | null>(null);

  // Routing modal state
  const [routingModalOpen, setRoutingModalOpen] = useState(false);
  const [routingTrackIdx, setRoutingTrackIdx] = useState<number>(0);

  // Create track modal state
  const [createTrackModalOpen, setCreateTrackModalOpen] = useState(false);

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

  // Check if we have any active filtering (built-in bank, custom bank, or text filter)
  const hasTextFilter = filterQuery.trim().length > 0;
  const hasBuiltinBank = isBuiltinBank(selectedBankId);
  const hasCustomBank = selectedBankId !== null && !hasBuiltinBank;
  const isFiltered = hasTextFilter || hasBuiltinBank || hasCustomBank;

  // Get selected custom bank (not applicable for built-in banks)
  const selectedBank = useMemo(
    () => (hasCustomBank ? customBanks.find((b) => b.id === selectedBankId) : null),
    [hasCustomBank, selectedBankId, customBanks]
  );

  // Filter tracks: first by bank (built-in, smart, or custom), then by text query
  // Uses skeleton - it has ALL tracks regardless of subscription state
  // Keep full track data (with GUIDs) for subscription
  const allFilteredTracks = useMemo(() => {
    if (!isFiltered) return [];

    // Start with all tracks (exclude master at index 0)
    let baseTracks = skeleton.slice(1).map((t, i) => ({ ...t, index: i + 1 }));

    // Built-in bank filtering (uses skeleton filter fields)
    if (hasBuiltinBank) {
      const builtinId = selectedBankId as BuiltinBankId;

      // Special handling for Folders bank with path navigation
      if (builtinId === 'builtin:folders' && folderPath.length > 0) {
        // Navigate into folder: show only direct children of current folder
        const currentFolderGuid = folderPath[folderPath.length - 1];
        const childIndices = new Set(getFolderChildren(currentFolderGuid));
        baseTracks = baseTracks.filter((t) => childIndices.has(t.index));
      } else {
        // Standard bank filtering
        baseTracks = baseTracks.filter((t) => {
          switch (builtinId) {
            case 'builtin:muted':
              return t.m === true;
            case 'builtin:soloed':
              return t.sl !== null && t.sl !== 0;
            case 'builtin:armed':
              return t.r === true;
            case 'builtin:selected':
              return t.sel === true;
            case 'builtin:folders':
              return t.fd === 1; // folder_depth 1 = parent folder
            case 'builtin:with-sends':
              return t.sc > 0;
            case 'builtin:clipped':
              return t.cl === true;
            case 'builtin:with-items':
              return t.ic > 0;
            default:
              return true;
          }
        });
      }
    }
    // Custom bank filtering
    else if (selectedBank) {
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
  }, [isFiltered, skeleton, hasBuiltinBank, selectedBankId, selectedBank, hasTextFilter, filterQuery, folderPath, getFolderChildren]);

  // Extract indices for display logic
  const allFilteredIndices = useMemo(
    () => allFilteredTracks.map((t) => t.index),
    [allFilteredTracks]
  );

  // Note: filterBankIndex reset on filter/bank change is now handled in viewFilterSlice
  // Note: folder sheet open/close on bank change is handled in handleSetSelectedBankId

  // Validate folder path when skeleton changes (in case folder was deleted)
  useEffect(() => {
    if (folderPath.length === 0) return;
    const validPath = validatePath(folderPath);
    if (validPath.length !== folderPath.length) {
      handleSetFolderPath(validPath);
    }
  }, [folderPath, validatePath, handleSetFolderPath]);

  // Calculate filtered banking
  const filteredTotalBanks = Math.ceil(allFilteredIndices.length / channelCount);

  // Clamp filter bank index when filtered results shrink (e.g., unmuting the last track on page 2)
  useEffect(() => {
    if (isFiltered && filterBankIndex > 0 && filterBankIndex >= filteredTotalBanks) {
      handleSetFilterBankIndex(Math.max(0, filteredTotalBanks - 1));
    }
  }, [isFiltered, filterBankIndex, filteredTotalBanks, handleSetFilterBankIndex]);

  const filteredBankStart = filterBankIndex * channelCount;
  const filteredBankEnd = Math.min(filteredBankStart + channelCount, allFilteredIndices.length);

  // Get the track indices to display
  const displayTrackIndices = useMemo(() => {
    if (isFiltered) {
      return allFilteredIndices.slice(filteredBankStart, filteredBankEnd);
    }
    return trackIndices;
  }, [isFiltered, allFilteredIndices, filteredBankStart, filteredBankEnd, trackIndices]);

  // Bank display and navigation for filtered vs unfiltered
  // When filtered, show range within filtered results: "1-6 of 10" (showing 1-6 of 10 matches)
  // Single track: "1 / 10" instead of redundant "1-1 / 10"
  const effectiveBankDisplay = isFiltered
    ? allFilteredIndices.length === 0
      ? '0 of 0'
      : filteredBankStart + 1 === filteredBankEnd
        ? `${filteredBankStart + 1} / ${allFilteredIndices.length}`
        : `${filteredBankStart + 1}-${filteredBankEnd} / ${allFilteredIndices.length}`
    : bankDisplay;

  const effectiveCanGoBack = isFiltered ? filterBankIndex > 0 : canGoBack;
  const effectiveCanGoForward = isFiltered ? filterBankIndex < filteredTotalBanks - 1 : canGoForward;

  const handleBack = useCallback(() => {
    if (isFiltered) {
      handleSetFilterBankIndex(Math.max(0, filterBankIndex - 1));
    } else {
      goBack();
    }
  }, [isFiltered, goBack, filterBankIndex, handleSetFilterBankIndex]);

  const handleForward = useCallback(() => {
    if (isFiltered) {
      handleSetFilterBankIndex(Math.min(filteredTotalBanks - 1, filterBankIndex + 1));
    } else {
      goForward();
    }
  }, [isFiltered, goForward, filteredTotalBanks, filterBankIndex, handleSetFilterBankIndex]);

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

  // Routing modal handler
  const handleShowRouting = useCallback((trackIdx: number) => {
    setRoutingTrackIdx(trackIdx);
    setRoutingModalOpen(true);
  }, []);

  // Folder click handler - open folder sheet and navigate to folder
  const handleFolderClick = useCallback((folderGuid: string) => {
    handleSetSelectedBankId('builtin:folders');
    handleSetFolderPath([folderGuid]);
    setFolderSheetOpen(true);
  }, [handleSetSelectedBankId, handleSetFolderPath]);

  // Handle track selection for info panel - also expands panel if collapsed
  const handleSelectForInfo = useCallback((trackIndex: number) => {
    setInfoSelectedTrackIdx(trackIndex);
    setSecondaryPanelExpanded('mixer', true);
  }, [setSecondaryPanelExpanded]);

  // Handle track selection from folder sheet
  const handleFolderSheetSelectTrack = useCallback((trackIndex: number) => {
    handleSelectForInfo(trackIndex);
  }, [handleSelectForInfo]);

  // Info tab content — horizontal for portrait bottom panel, vertical for landscape side panel
  const infoTabContent = useMemo(() => (
    <TrackInfoBar
      selectedTrackIdx={infoSelectedTrackIdx}
      onShowRouting={handleShowRouting}
      onFolderClick={handleFolderClick}
      layout="horizontal"
    />
  ), [infoSelectedTrackIdx, handleShowRouting, handleFolderClick]);

  const infoTabContentVertical = useMemo(() => (
    <TrackInfoBar
      selectedTrackIdx={infoSelectedTrackIdx}
      onShowRouting={handleShowRouting}
      onFolderClick={handleFolderClick}
      layout="vertical"
    />
  ), [infoSelectedTrackIdx, handleShowRouting, handleFolderClick]);

  // Secondary panel tab configuration - just Info tab (filter/nav now in header)
  const secondaryTabs: SecondaryPanelTabConfig[] = useMemo(() => [
    {
      id: 'info',
      icon: Info,
      label: 'Track Info',
      content: infoTabContent,
    },
  ], [infoTabContent]);

  // Bank navigation props for SecondaryPanel header
  // Use filtered count when filtering, otherwise use bank total count
  const effectiveTotalCount = isFiltered ? allFilteredIndices.length : totalCount;
  const bankNavProps: BankNavProps = useMemo(() => ({
    bankDisplay: effectiveBankDisplay,
    compactDisplay: String(effectiveTotalCount),
    canGoBack: effectiveCanGoBack,
    canGoForward: effectiveCanGoForward,
    onBack: handleBack,
    onForward: handleForward,
  }), [effectiveBankDisplay, effectiveTotalCount, effectiveCanGoBack, effectiveCanGoForward, handleBack, handleForward]);

  // Sync bank nav state to side rail when in landscape-constrained mode
  useEffect(() => {
    if (isLandscapeConstrained) {
      // Populate side rail with bank nav state
      setSideRailBankNav({
        bankDisplay: effectiveBankDisplay,
        compactDisplay: String(effectiveTotalCount),
        canGoBack: effectiveCanGoBack,
        canGoForward: effectiveCanGoForward,
      });
      setSideRailBankNavCallbacks({
        onBack: handleBack,
        onForward: handleForward,
      });
      // Provide info content for side rail actions button (vertical layout for narrow panel)
      setSideRailInfo({
        content: infoTabContentVertical,
        label: 'Track Info',
      });
      // Sync search to context rail
      setSideRailSearch({
        value: filterQuery,
        onChange: handleSetFilterQuery,
        placeholder: 'Filter tracks...',
      });
    }

    // Cleanup when unmounting or leaving landscape-constrained mode
    return () => {
      if (isLandscapeConstrained) {
        setSideRailBankNav(null);
        setSideRailBankNavCallbacks({ onBack: null, onForward: null });
        setSideRailInfo(null);
        setSideRailSearch(null);
      }
    };
  }, [isLandscapeConstrained, effectiveBankDisplay, effectiveTotalCount, effectiveCanGoBack, effectiveCanGoForward, handleBack, handleForward, setSideRailBankNav, setSideRailBankNavCallbacks, setSideRailInfo, setSideRailSearch, infoTabContentVertical, filterQuery, handleSetFilterQuery]);

  // Search props for SecondaryPanel header
  const searchProps: SearchProps = useMemo(() => ({
    value: filterQuery,
    onChange: handleSetFilterQuery,
    placeholder: 'Filter tracks...',
  }), [filterQuery, handleSetFilterQuery]);

  // Handle bank change - delegate to wrapped handler
  const handleBankChange = handleSetSelectedBankId;

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
        handleSetSelectedBankId(null);
      }
    },
    [deleteBank, selectedBankId, handleSetSelectedBankId]
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

  // Compute extra GUIDs for info-selected track when it's outside visible range
  // This keeps track data flowing even when the selected track is paged out
  // Uses EMPTY_STRING_ARRAY for stable reference when no extra GUIDs needed
  const extraGuidsForInfoTrack = useMemo((): readonly string[] => {
    if (infoSelectedTrackIdx === null || infoSelectedTrackIdx < 0) return EMPTY_STRING_ARRAY;

    // Get the GUID for the info-selected track from skeleton
    const trackSkeleton = skeleton[infoSelectedTrackIdx];
    if (!trackSkeleton?.g) return EMPTY_STRING_ARRAY;

    const infoGuid = trackSkeleton.g;

    if (isFiltered) {
      // In filtered mode: check if GUID is already in the subscription list
      if (filteredGuidsToSubscribe.includes(infoGuid)) return EMPTY_STRING_ARRAY;
      return [infoGuid];
    } else {
      // In range mode: check if index is outside prefetch range
      if (infoSelectedTrackIdx >= prefetchStart && infoSelectedTrackIdx <= prefetchEnd) return EMPTY_STRING_ARRAY;
      return [infoGuid];
    }
  }, [infoSelectedTrackIdx, skeleton, isFiltered, filteredGuidsToSubscribe, prefetchStart, prefetchEnd]);

  // Subscribe to tracks - range mode for unfiltered, GUID mode for filtered
  // When master is pinned, explicitly include it (it's outside the bank range)
  // When master is not pinned, it's included in the range naturally when on first banks
  // extraGuids keeps info-selected track subscribed even when paged out
  useEffect(() => {
    if (totalTracks === 0) return;

    if (isFiltered) {
      // Filtered: subscribe to specific GUIDs (scattered tracks)
      if (filteredGuidsToSubscribe.length > 0) {
        sendCommand(
          track.subscribe({
            guids: filteredGuidsToSubscribe,
            extraGuids: extraGuidsForInfoTrack.length > 0 ? extraGuidsForInfoTrack : undefined,
            includeMaster: pinMasterTrack,
          })
        );
      }
    } else {
      // Unfiltered: subscribe to range (contiguous tracks)
      sendCommand(
        track.subscribe({
          range: { start: prefetchStart, end: prefetchEnd },
          extraGuids: extraGuidsForInfoTrack.length > 0 ? extraGuidsForInfoTrack : undefined,
          includeMaster: pinMasterTrack,
        })
      );
    }
  }, [sendCommand, isFiltered, filteredGuidsToSubscribe, extraGuidsForInfoTrack, prefetchStart, prefetchEnd, totalTracks, pinMasterTrack]);

  // Check if we have data for a track
  const hasTrackData = (trackIndex: number): boolean => {
    return !!tracks[trackIndex];
  };

  return (
    <ViewLayout
      viewId="mixer"
      header={
        <ViewHeader currentView="mixer">
          <BankSelector
            selectedBankId={selectedBankId}
            banks={customBanks}
            onBankChange={handleBankChange}
            onAddBank={handleAddBank}
            onEditBank={handleEditBank}
            onFolderNavClick={() => setFolderSheetOpen(true)}
          />
          <QuickFilterDropdown
            selectedFilterId={hasBuiltinBank && selectedBankId !== 'builtin:folders' ? selectedBankId as BuiltinBankId : null}
            skeleton={skeleton}
            onFilterChange={(filterId) => handleSetSelectedBankId(filterId)}
            className="ml-1"
          />
        </ViewHeader>
      }
      footer={isLandscapeConstrained ? undefined : <SecondaryPanel viewId="mixer" tabs={secondaryTabs} bankNav={bankNavProps} search={searchProps} />}
      scrollable={false}
      className="bg-bg-app text-text-primary p-view"
    >
      {/* Main mixer area - containerRef for height/width measurement */}
      <div
        ref={containerRef}
        className="h-full flex items-center justify-center gap-2 relative overflow-hidden pb-3"
      >
        {/* Master track - pinned on left when enabled */}
        {pinMasterTrack && (
          <div className="border-r pr-2 border-border-subtle">
            {hasTrackData(0) ? (
              isLandscape ? (
                <MixerStripCompact
                  trackIndex={0}
                  faderHeight={faderHeight}
                  isInfoSelected={infoSelectedTrackIdx === 0}
                  onSelectForInfo={handleSelectForInfo}
                />
              ) : (
                <MixerStrip
                  trackIndex={0}
                  mode="volume"
                  faderHeight={faderHeight}
                  showDbLabel={true}
                  isInfoSelected={infoSelectedTrackIdx === 0}
                  onSelectForInfo={handleSelectForInfo}
                />
              )
            ) : (
              // Loading placeholder for master
              <div
                className="bg-bg-surface/50 rounded-lg animate-pulse"
                style={{ width: isLandscape ? 82 : 80, height: faderHeight + (isLandscape ? STRIP_OVERHEAD_COMPACT : STRIP_OVERHEAD_FULL) }}
              />
            )}
          </div>
        )}

        {/* Channel strips */}
        <div className="flex gap-3">
          {displayTrackIndices.map((trackIndex) => (
            <div key={trackIndex}>
              {hasTrackData(trackIndex) ? (
                isLandscape ? (
                  <MixerStripCompact
                    trackIndex={trackIndex}
                    faderHeight={faderHeight}
                    isInfoSelected={infoSelectedTrackIdx === trackIndex}
                    onSelectForInfo={handleSelectForInfo}
                  />
                ) : (
                  <MixerStrip
                    trackIndex={trackIndex}
                    mode="volume"
                    faderHeight={faderHeight}
                    showDbLabel={true}
                    isInfoSelected={infoSelectedTrackIdx === trackIndex}
                    onSelectForInfo={handleSelectForInfo}
                  />
                )
              ) : (
                // Loading placeholder
                <div
                  className="bg-bg-surface/50 rounded-lg animate-pulse"
                  style={{ width: isLandscape ? 82 : 80, height: faderHeight + (isLandscape ? STRIP_OVERHEAD_COMPACT : STRIP_OVERHEAD_FULL) }}
                />
              )}
            </div>
          ))}
        </div>

        {/* Empty filter state - when filter/bank active but no matches */}
        {isFiltered && displayTrackIndices.length === 0 && (
          <div className="text-text-muted text-sm">No tracks matching filter</div>
        )}

        {/* Create track button */}
        {showAddTrackButton && (
          <button
            onClick={() => setCreateTrackModalOpen(true)}
            className="self-center p-2 text-text-muted hover:text-text-primary transition-colors"
            title="Create track"
          >
            <Plus size={24} />
          </button>
        )}

        {/* Empty state - positioned absolutely within the content area */}
        {totalTracks === 0 && (
          <div className="absolute inset-0 flex items-center justify-center">
            <div className="text-text-muted text-center">
              <p className="text-lg mb-2">No tracks in project</p>
              <p className="text-sm">Add tracks in REAPER to see them here</p>
            </div>
          </div>
        )}
      </div>

      {/* Bank editor modal */}
      <BankEditorModal
        isOpen={bankModalOpen}
        onClose={handleCloseModal}
        onSave={handleSaveBank}
        onDelete={handleDeleteBank}
        editBank={editingBank}
      />

      {/* Routing modal */}
      <RoutingModal
        isOpen={routingModalOpen}
        onClose={() => setRoutingModalOpen(false)}
        trackIndex={routingTrackIdx}
      />

      {/* Create track modal */}
      <CreateTrackModal
        isOpen={createTrackModalOpen}
        onClose={() => setCreateTrackModalOpen(false)}
      />

      {/* Folder navigation sheet - derived open state ensures sheet closes on project change
          (when store subscription resets selectedBankId to null) */}
      <FolderNavSheet
        isOpen={folderSheetOpen && selectedBankId === 'builtin:folders'}
        onClose={() => setFolderSheetOpen(false)}
        folderPath={folderPath}
        onNavigate={handleSetFolderPath}
        onSelectTrack={handleFolderSheetSelectTrack}
      />

    </ViewLayout>
  );
}
