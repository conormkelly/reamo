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
import { Info, Wrench } from 'lucide-react';
import { ViewHeader, ViewLayout, Toolbar, ToolbarHeaderControls, SecondaryPanel, type SecondaryPanelTabConfig, type BankNavProps, type SearchProps } from '../../components';
import {
  Timeline,
  RegionInfoBar,
  RegionEditActionBar,
  MarkerInfoBar,
  TimelineModeToggle,
  NavigateItemInfoBar,
} from '../../components';
import {
  BankSelector,
  BankEditorModal,
  FolderNavSheet,
  isBuiltinBank,
  type CustomBank,
  type BuiltinBankId,
} from '../../components/Mixer';
import { useReaperStore } from '../../store';
import { EMPTY_REGIONS, EMPTY_MARKERS, EMPTY_ITEMS } from '../../store/stableRefs';
import {
  useViewport,
  useTransport,
  useBankNavigation,
  useCustomBanks,
  useTrackSkeleton,
  useFolderHierarchy,
  useAvailableContentHeight,
} from '../../hooks';
import { usePeaksSubscription } from '../../hooks/usePeaksSubscription';
import {
  TIMELINE_OVERHEAD_NAVIGATE,
  TIMELINE_OVERHEAD_REGIONS,
  TIMELINE_CONTENT_PADDING,
  MIN_TIMELINE_HEIGHT,
  MAX_TIMELINE_PERCENT,
} from '../../constants/layout';

/** Duration to show track labels after bank switch (ms) */
const BANK_SWITCH_LABEL_DURATION = 1000;

export function TimelineView(): ReactElement {
  // Container ref for responsive height measurement
  const contentContainerRef = useRef<HTMLDivElement>(null);

  // Lane count from user preference (1-8)
  const laneCount = useReaperStore((s) => s.timelineLaneCount);
  const timelineMode = useReaperStore((s) => s.timelineMode);

  // Responsive height measurement - tracks container size and panel transitions
  // Also provides layout context for side rail mode detection
  const { availableHeight, isLandscapeConstrained } = useAvailableContentHeight({
    containerRef: contentContainerRef,
    viewId: 'timeline',
  });

  // Dynamic timeline height based on measured container height and mode
  // Budget = availableHeight - container padding - timeline overhead
  const timelineHeight = useMemo(() => {
    // Overhead differs between navigate (has footer) and regions mode
    const overhead = timelineMode === 'navigate'
      ? TIMELINE_OVERHEAD_NAVIGATE
      : TIMELINE_OVERHEAD_REGIONS;

    if (availableHeight === 0) return MIN_TIMELINE_HEIGHT; // Initial render before measurement

    // Available budget for timeline canvas = container height - padding - overhead
    const canvasBudget = availableHeight - TIMELINE_CONTENT_PADDING - overhead;

    return Math.min(
      Math.max(MIN_TIMELINE_HEIGHT, canvasBudget), // Floor: minimum usable height
      availableHeight * MAX_TIMELINE_PERCENT        // Ceiling: prevent overflow
    );
  }, [availableHeight, timelineMode]);
  const regions = useReaperStore((s) => s?.regions ?? EMPTY_REGIONS);
  const markers = useReaperStore((s) => s?.markers ?? EMPTY_MARKERS);
  const items = useReaperStore((s) => s?.items ?? EMPTY_ITEMS);
  const openAddRegionModal = useReaperStore((s) => s.openAddRegionModal);
  const selectedMarkerId = useReaperStore((s) => s.selectedMarkerId);
  const itemSelectionModeActive = useReaperStore((s) => s.itemSelectionModeActive);
  const totalTracks = useReaperStore((s) => s?.totalTracks ?? 0);
  const setSideRailBankNav = useReaperStore((s) => s.setSideRailBankNav);
  const setSideRailBankNavCallbacks = useReaperStore((s) => s.setSideRailBankNavCallbacks);
  const setSideRailInfo = useReaperStore((s) => s.setSideRailInfo);
  const { positionSeconds } = useTransport();

  // Get skeleton from hook (same pattern as Mixer)
  const { skeleton } = useTrackSkeleton();

  // Bank navigation - pages through tracks in groups of laneCount
  // Destructure to get stable function references (like MixerView does)
  const {
    trackIndices: bankTrackIndices,
    prefetchStart,
    prefetchEnd,
    canGoBack,
    canGoForward,
    goBack,
    goForward,
    bankDisplay,
    totalCount,
  } = useBankNavigation({
    channelCount: laneCount,
    totalTracks,
    storageKey: 'reamo-timeline-bank',
  });

  // Custom banks from ProjExtState (shared with Mixer)
  const { banks: customBanks, saveBank, deleteBank } = useCustomBanks();
  const [selectedBankId, setSelectedBankId] = useState<string | null>(null);

  // Bank editor modal state
  const [bankModalOpen, setBankModalOpen] = useState(false);
  const [editingBank, setEditingBank] = useState<CustomBank | null>(null);

  // Folder navigation state (same as Mixer)
  const [folderPath, setFolderPath] = useState<string[]>([]);
  const [folderSheetOpen, setFolderSheetOpen] = useState(false);
  const { getChildren: getFolderChildren, validatePath } = useFolderHierarchy();

  // Track filter state
  const [filterQuery, setFilterQuery] = useState('');
  const [filterBankIndex, setFilterBankIndex] = useState(0);

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

  // Reset filter bank when filter or bank changes
  useEffect(() => {
    setFilterBankIndex(0);
  }, [filterQuery, selectedBankId]);

  // Reset folder path when switching away from Folders bank
  // Open folder sheet when switching TO Folders bank
  useEffect(() => {
    if (selectedBankId === 'builtin:folders') {
      setFolderSheetOpen(true);
    } else {
      setFolderPath([]);
      setFolderSheetOpen(false);
    }
  }, [selectedBankId]);

  // Validate folder path when skeleton changes (in case folder was deleted)
  useEffect(() => {
    if (folderPath.length === 0) return;
    const validPath = validatePath(folderPath);
    if (validPath.length !== folderPath.length) {
      setFolderPath(validPath);
    }
  }, [folderPath, validatePath]);

  // Calculate filtered banking
  const filteredBankStart = filterBankIndex * laneCount;
  const filteredBankEnd = Math.min(filteredBankStart + laneCount, allFilteredIndices.length);
  const filteredTotalBanks = Math.ceil(allFilteredIndices.length / laneCount);

  // Get the track indices to display (filtered or regular bank)
  const displayTrackIndices = useMemo(() => {
    if (isFiltered) {
      return allFilteredIndices.slice(filteredBankStart, filteredBankEnd);
    }
    return bankTrackIndices;
  }, [isFiltered, allFilteredIndices, filteredBankStart, filteredBankEnd, bankTrackIndices]);

  // Get tracks for current display (skeleton indices are 0-based, displayTrackIndices are 1-based)
  const laneTracks = useMemo(() => {
    return displayTrackIndices.map((idx) => skeleton[idx]).filter(Boolean);
  }, [displayTrackIndices, skeleton]);

  // Bank display and navigation for filtered vs unfiltered
  const effectiveBankDisplay = isFiltered
    ? allFilteredIndices.length === 0
      ? '0 of 0'
      : filteredBankStart + 1 === filteredBankEnd
        ? `${filteredBankStart + 1} / ${allFilteredIndices.length}`
        : `${filteredBankStart + 1}-${filteredBankEnd} / ${allFilteredIndices.length}`
    : bankDisplay;

  const effectiveCanGoBack = isFiltered ? filterBankIndex > 0 : canGoBack;
  const effectiveCanGoForward = isFiltered ? filterBankIndex < filteredTotalBanks - 1 : canGoForward;

  // Calculate project duration from content (needed for viewport)
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

  // Shared viewport state (needed for peaks subscription)
  const viewport = useViewport({
    projectDuration,
    initialRange: { start: 0, end: projectDuration }, // Default to full project (zoom-to-fit)
  });

  // Track timeline container width for adaptive peak resolution
  const timelineContainerRef = useRef<HTMLDivElement>(null);
  const [containerWidth, setContainerWidth] = useState(400); // Default mobile width

  useEffect(() => {
    const container = timelineContainerRef.current;
    if (!container) return;

    // Initial measurement
    setContainerWidth(container.clientWidth);

    // Update on resize
    const resizeObserver = new ResizeObserver((entries) => {
      for (const entry of entries) {
        setContainerWidth(entry.contentRect.width);
      }
    });
    resizeObserver.observe(container);

    return () => resizeObserver.disconnect();
  }, []);

  // Subscribe to peaks for waveform rendering
  // - Range mode for unfiltered (sequential bank navigation with prefetch)
  // - GUID mode for filtered (sparse track selection)
  // - Viewport for adaptive peak resolution (more peaks when zoomed in)
  const peaksSubscriptionOptions = useMemo(() => {
    if (laneTracks.length === 0) return null;

    // Viewport for adaptive peak resolution
    const peaksViewport = {
      start: viewport.visibleRange.start,
      end: viewport.visibleRange.end,
      widthPx: containerWidth,
    };

    if (isFiltered) {
      // Filtered: subscribe by GUID (sparse tracks)
      const guids = laneTracks.map((t) => t.g);
      return { guids, sampleCount: 30, viewport: peaksViewport };
    } else {
      // Unfiltered: subscribe by range with prefetch
      return {
        range: { start: prefetchStart, end: prefetchEnd },
        sampleCount: 30,
        viewport: peaksViewport,
      };
    }
  }, [isFiltered, laneTracks, prefetchStart, prefetchEnd, viewport.visibleRange, containerWidth]);

  const { assemblePeaksForViewport, hasTilesForTake } = usePeaksSubscription(peaksSubscriptionOptions);

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
      goBack();
    }
    showLabelsTemporarily();
  }, [isFiltered, goBack, showLabelsTemporarily]);

  const handleBankForward = useCallback(() => {
    if (isFiltered) {
      setFilterBankIndex((prev) => Math.min(filteredTotalBanks - 1, prev + 1));
    } else {
      goForward();
    }
    showLabelsTemporarily();
  }, [isFiltered, goForward, filteredTotalBanks, showLabelsTemporarily]);

  // Header content
  const headerContent = (
    <ViewHeader currentView="timeline">
      <BankSelector
        selectedBankId={selectedBankId}
        banks={customBanks}
        onBankChange={setSelectedBankId}
        onAddBank={handleAddBank}
        onEditBank={handleEditBank}
        onFolderNavClick={() => setFolderSheetOpen(true)}
      />
      <TimelineModeToggle />
    </ViewHeader>
  );

  // Info tab content - changes based on mode
  const infoTabContent = useMemo(() => {
    if (timelineMode === 'regions') {
      // Regions mode: show RegionInfoBar + RegionEditActionBar
      return (
        <>
          <RegionInfoBar onAddRegion={openAddRegionModal} />
          <div className="mt-2">
            <RegionEditActionBar />
          </div>
        </>
      );
    } else {
      // Navigate mode: show marker/item info or fallback
      return (
        <section data-testid="navigate-info-section" className="flex flex-col gap-2">
          <MarkerInfoBar />
          {selectedMarkerId === null && itemSelectionModeActive && <NavigateItemInfoBar />}
          {selectedMarkerId === null && !itemSelectionModeActive && (
            <div
              data-testid="nothing-selected-message"
              className="px-3 py-2 bg-bg-surface/50 rounded-lg text-text-muted text-sm text-center"
            >
              Tap a marker pill or item
            </div>
          )}
        </section>
      );
    }
  }, [timelineMode, openAddRegionModal, selectedMarkerId, itemSelectionModeActive]);

  // Toolbar tab content
  const toolbarTabContent = useMemo(() => (
    <div className="flex flex-col gap-2 px-3">
      <ToolbarHeaderControls />
      <Toolbar size="sm" />
    </div>
  ), []);

  // Secondary panel tab configuration - Info and Toolbar (filter/nav now in header)
  const secondaryTabs: SecondaryPanelTabConfig[] = useMemo(() => [
    {
      id: 'info',
      icon: Info,
      label: 'Info',
      content: infoTabContent,
    },
    {
      id: 'toolbar',
      icon: Wrench,
      label: 'Toolbar',
      content: toolbarTabContent,
    },
  ], [infoTabContent, toolbarTabContent]);

  // Bank navigation props for SecondaryPanel header
  // Use filtered count when filtering, otherwise use bank total count
  const effectiveTotalCount = isFiltered ? allFilteredIndices.length : totalCount;
  const bankNavProps: BankNavProps = useMemo(() => ({
    bankDisplay: effectiveBankDisplay,
    compactDisplay: String(effectiveTotalCount),
    canGoBack: effectiveCanGoBack,
    canGoForward: effectiveCanGoForward,
    onBack: handleBankBack,
    onForward: handleBankForward,
    onHoldStart: handleHoldStart,
    onHoldEnd: handleHoldEnd,
  }), [effectiveBankDisplay, effectiveTotalCount, effectiveCanGoBack, effectiveCanGoForward, handleBankBack, handleBankForward, handleHoldStart, handleHoldEnd]);

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
        onBack: handleBankBack,
        onForward: handleBankForward,
      });
      // Provide info content for side rail actions button
      // Combine info and toolbar content for timeline
      setSideRailInfo({
        content: (
          <div className="flex flex-col gap-4">
            <div>
              <h3 className="text-sm font-medium text-text-secondary mb-2">Info</h3>
              {infoTabContent}
            </div>
            <div>
              <h3 className="text-sm font-medium text-text-secondary mb-2">Toolbar</h3>
              {toolbarTabContent}
            </div>
          </div>
        ),
        label: 'Timeline Info & Toolbar',
      });
    }

    // Cleanup when unmounting or leaving landscape-constrained mode
    return () => {
      if (isLandscapeConstrained) {
        setSideRailBankNav(null);
        setSideRailBankNavCallbacks({ onBack: null, onForward: null });
        setSideRailInfo(null);
      }
    };
  }, [isLandscapeConstrained, effectiveBankDisplay, effectiveTotalCount, effectiveCanGoBack, effectiveCanGoForward, handleBankBack, handleBankForward, setSideRailBankNav, setSideRailBankNavCallbacks, setSideRailInfo, infoTabContent, toolbarTabContent]);

  // Search props for SecondaryPanel header
  const searchProps: SearchProps = useMemo(() => ({
    value: filterQuery,
    onChange: setFilterQuery,
    placeholder: 'Filter tracks...',
  }), [filterQuery, setFilterQuery]);

  // Footer content - SecondaryPanel with search and bank nav in header
  const footerContent = (
    <SecondaryPanel viewId="timeline" tabs={secondaryTabs} bankNav={bankNavProps} search={searchProps} />
  );

  return (
    <>
      <ViewLayout
        viewId="timeline"
        className="bg-bg-app text-text-primary p-3"
        header={headerContent}
        footer={isLandscapeConstrained ? undefined : footerContent}
        scrollable={false}
      >
        {/* Main timeline area - containerRef for height measurement */}
        <div ref={contentContainerRef} className="flex flex-col h-full mt-2">
          {/* Timeline canvas with multi-track lanes */}
          <div ref={timelineContainerRef} className="relative shrink-0">
            <Timeline
              height={timelineHeight}
              viewport={viewport}
              multiTrackLanes={laneTracks}
              multiTrackIndices={displayTrackIndices}
              assemblePeaksForViewport={assemblePeaksForViewport}
              hasTilesForTake={hasTilesForTake}
            />

            {/* Track labels overlay - shown when holding bank display or switching banks */}
            {showTrackLabels && laneTracks.length > 0 && (
              <div
                className="absolute inset-0 pointer-events-none z-30"
                style={{ top: 57 }} // Skip ruler (32px) + region labels bar (25px)
              >
                {laneTracks.map((track, laneIdx) => {
                  const trackIdx = displayTrackIndices[laneIdx];
                  const laneHeight = timelineHeight / laneTracks.length;
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
        </div>
      </ViewLayout>

      {/* Bank editor modal - rendered outside ViewLayout (uses portal) */}
      <BankEditorModal
        isOpen={bankModalOpen}
        onClose={handleCloseModal}
        onSave={handleSaveBank}
        onDelete={handleDeleteBank}
        editBank={editingBank}
      />

      {/* Folder navigation sheet - shown when Folders bank is selected */}
      <FolderNavSheet
        isOpen={folderSheetOpen}
        onClose={() => setFolderSheetOpen(false)}
        folderPath={folderPath}
        onNavigate={setFolderPath}
      />
    </>
  );
}
