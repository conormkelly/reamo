/**
 * useTimelineSelectors — Consolidated store selectors for Timeline
 *
 * Groups all useReaperStore() selector calls + useTransport() used by the
 * Timeline component. Each selector remains an individual useReaperStore() call
 * to preserve Zustand's referential equality optimisation.
 */

import { useReaperStore } from '../../../store';
import { EMPTY_REGIONS, EMPTY_MARKERS, EMPTY_ITEMS, EMPTY_SKELETON } from '../../../store/stableRefs';
import { useTransport } from '../../../hooks';

export function useTimelineSelectors() {
  // Transport position (separate hook, not a store selector)
  const { positionSeconds } = useTransport();

  // Defensive selectors with stable fallbacks - state can be undefined briefly on mobile during hydration
  const regions = useReaperStore((state) => state?.regions ?? EMPTY_REGIONS);
  const markers = useReaperStore((state) => state?.markers ?? EMPTY_MARKERS);
  const items = useReaperStore((state) => state?.items ?? EMPTY_ITEMS);
  const trackSkeleton = useReaperStore((state) => state?.trackSkeleton ?? EMPTY_SKELETON);
  const bpm = useReaperStore((state) => state.bpm);
  const tempoMarkers = useReaperStore((state) => state.tempoMarkers);
  const storedTimeSelection = useReaperStore((state) => state.timeSelection);
  const setStoredTimeSelection = useReaperStore((state) => state.setTimeSelection);

  // Region editing state
  const timelineMode = useReaperStore((state) => state.timelineMode);
  const selectedRegionIds = useReaperStore((state) => state.selectedRegionIds);
  const pendingChanges = useReaperStore((state) => state.pendingChanges);
  const hasPendingChanges = useReaperStore((state) => state.hasPendingChanges);
  const selectRegion = useReaperStore((state) => state.selectRegion);
  const deselectRegion = useReaperStore((state) => state.deselectRegion);
  const clearSelection = useReaperStore((state) => state.clearSelection);
  const isRegionSelected = useReaperStore((state) => state.isRegionSelected);
  const resizeRegion = useReaperStore((state) => state.resizeRegion);
  const moveRegion = useReaperStore((state) => state.moveRegion);
  const startDrag = useReaperStore((state) => state.startDrag);
  const updateDrag = useReaperStore((state) => state.updateDrag);
  const endDrag = useReaperStore((state) => state.endDrag);
  const cancelDrag = useReaperStore((state) => state.cancelDrag);
  const regionDragType = useReaperStore((state) => state.dragType);
  const regionDragId = useReaperStore((state) => state.dragRegionId);
  const dragCurrentTime = useReaperStore((state) => state.dragCurrentTime);
  const dragStartTime = useReaperStore((state) => state.dragStartTime);
  const insertionPoint = useReaperStore((state) => state.insertionPoint);
  const resizeEdgePosition = useReaperStore((state) => state.resizeEdgePosition);

  // Focused track GUID for highlight in multi-track lanes
  const viewFilterTrackGuid = useReaperStore((state) => state.viewFilterTrackGuid);

  // Item selection mode state
  const itemSelectionModeActive = useReaperStore((state) => state.itemSelectionModeActive);
  const enterItemSelectionMode = useReaperStore((state) => state.enterItemSelectionMode);
  const setViewFilterTrack = useReaperStore((state) => state.setViewFilterTrack);

  // Marker selection action (needed for mutual exclusion with item selection)
  const setSelectedMarkerId = useReaperStore((state) => state.setSelectedMarkerId);

  // Modal actions from store (modals rendered by ModalRoot)
  const openMarkerEditModal = useReaperStore((s) => s.openMarkerEditModal);
  const openMakeSelectionModal = useReaperStore((s) => s.openMakeSelectionModal);

  // Selection mode toggle state (pan mode vs selection mode in navigate)
  const selectionModeActive = useReaperStore((s) => s.selectionModeActive);
  const toggleSelectionMode = useReaperStore((s) => s.toggleSelectionMode);

  // Follow playhead state - managed in store with auto-enable via subscription
  const followPlayhead = useReaperStore((s) => s.followPlayhead);
  const setFollowPlayhead = useReaperStore((s) => s.setFollowPlayhead);
  const pauseFollowPlayhead = useReaperStore((s) => s.pauseFollowPlayhead);

  // Marker lock action
  const setMarkerLocked = useReaperStore((state) => state.setMarkerLocked);

  // Optimistic track selection (bridges 1Hz skeleton poll gap)
  const optimisticSelectTrack = useReaperStore((state) => state.optimisticSelectTrack);

  return {
    positionSeconds,
    regions,
    markers,
    items,
    trackSkeleton,
    bpm,
    tempoMarkers,
    storedTimeSelection,
    setStoredTimeSelection,
    timelineMode,
    selectedRegionIds,
    pendingChanges,
    hasPendingChanges,
    selectRegion,
    deselectRegion,
    clearSelection,
    isRegionSelected,
    resizeRegion,
    moveRegion,
    startDrag,
    updateDrag,
    endDrag,
    cancelDrag,
    regionDragType,
    regionDragId,
    dragCurrentTime,
    dragStartTime,
    insertionPoint,
    resizeEdgePosition,
    viewFilterTrackGuid,
    itemSelectionModeActive,
    enterItemSelectionMode,
    setViewFilterTrack,
    setSelectedMarkerId,
    openMarkerEditModal,
    openMakeSelectionModal,
    selectionModeActive,
    toggleSelectionMode,
    followPlayhead,
    setFollowPlayhead,
    pauseFollowPlayhead,
    setMarkerLocked,
    optimisticSelectTrack,
  };
}
