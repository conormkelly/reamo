/**
 * Timeline Component
 * Visual timeline showing regions and markers for navigation and selection
 */

import { useState, useRef, useCallback, useMemo, useEffect, type ReactElement } from 'react';
import { useReaperStore } from '../../store';
import { EMPTY_REGIONS, EMPTY_MARKERS, EMPTY_ITEMS, EMPTY_TRACKS, EMPTY_SKELETON } from '../../store/stableRefs';
import type { WSItem } from '../../core/WebSocketTypes';
import { useReaper } from '../ReaperProvider';
import {
  useTransport,
  useTransportAnimation,
  useTimeSignature,
  useBarOffset,
  useViewport,
  useVisibleRegions,
  useVisibleMarkers,
  useVisibleMediaItems,
  useMarkerClusters,
  useReducedMotion,
  type MarkerClusterData,
  type UseViewportReturn,
} from '../../hooks';
import { transport, timeSelection as timeSelCmd, marker as markerCmd, action, item as itemCmd } from '../../core/WebSocketCommands';
import { usePlayheadDrag, useMarkerDrag, useRegionDrag, usePanGesture, usePinchGesture, useEdgeScroll } from './hooks';
import { TimelineRegionLabels, TimelineRegionBlocks } from './TimelineRegions';
import { ItemsDensityOverlay } from './ItemDensityBlobs';
import { TimelineWaveformOverlay } from './TimelineWaveformOverlay';
import { ClusteredMarkerLines, ClusteredMarkerPills } from './TimelineMarkers';
import { TimelinePlayhead, PlayheadDragPreview, PlayheadPreviewPill, MarkerDragPreview } from './TimelinePlayhead';
import { TimelineFooter } from './TimelineFooter';
import { formatBeats, formatDelta } from '../../utils';
import { timeToBarBeat, formatBarBeat } from '../../core/tempoUtils';
import { findNearestSnapTarget } from './snapUtils';

export interface TimelineProps {
  className?: string;
  /** Minimum height in pixels */
  height?: number;
  /** Whether time selection sync is in progress */
  isSyncing?: boolean;
  /** External viewport state (if provided, uses this instead of creating own) */
  viewport?: UseViewportReturn;
}

// Vertical distance to cancel gesture (drag off timeline)
const VERTICAL_CANCEL_THRESHOLD = 50;

// Tap detection threshold (pixels) - movement less than this is considered a tap
const TAP_THRESHOLD = 10;

export function Timeline({ className = '', height = 120, isSyncing = false, viewport: externalViewport }: TimelineProps): ReactElement {
  const { sendCommand } = useReaper();
  const { positionSeconds } = useTransport();
  // Defensive selectors with stable fallbacks - state can be undefined briefly on mobile during hydration
  const regions = useReaperStore((state) => state?.regions ?? EMPTY_REGIONS);
  const markers = useReaperStore((state) => state?.markers ?? EMPTY_MARKERS);
  const items = useReaperStore((state) => state?.items ?? EMPTY_ITEMS);
  const tracks = useReaperStore((state) => state?.tracks ?? EMPTY_TRACKS);
  const trackSkeleton = useReaperStore((state) => state?.trackSkeleton ?? EMPTY_SKELETON);
  const bpm = useReaperStore((state) => state.bpm);
  const tempoMarkers = useReaperStore((state) => state.tempoMarkers);
  const storedTimeSelection = useReaperStore((state) => state.timeSelection);
  const setStoredTimeSelection = useReaperStore((state) => state.setTimeSelection);

  // Time signature and bar offset from hooks
  const { beatsPerBar, denominator } = useTimeSignature();
  const barOffset = useBarOffset();

  // Accessibility: reduced motion preference
  const prefersReducedMotion = useReducedMotion();

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
  const getDisplayRegions = useReaperStore((state) => state.getDisplayRegions);
  const getDragPreviewRegions = useReaperStore((state) => state.getDragPreviewRegions);
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

  // Item selection state (for Navigate mode tap-to-select)
  const selectedItemGuid = useReaperStore((state) => state.selectedItemGuid);
  const selectItem = useReaperStore((state) => state.selectItem);

  // Filter out invalid 0-width selections
  const timeSelectionSeconds = useMemo(() => {
    if (!storedTimeSelection) return null;
    // Don't show selections with negligible width (less than 0.01 seconds)
    if (Math.abs(storedTimeSelection.endSeconds - storedTimeSelection.startSeconds) < 0.01) return null;
    return { start: storedTimeSelection.startSeconds, end: storedTimeSelection.endSeconds };
  }, [storedTimeSelection]);

  // Base display regions (with pending changes but WITHOUT drag preview) - used for snap calculations
  const baseDisplayRegions = useMemo(() => {
    if (timelineMode === 'regions') {
      return getDisplayRegions(regions);
    }
    return regions;
  }, [timelineMode, regions, getDisplayRegions, pendingChanges]);

  // Get regions to display (with pending changes and drag preview applied in region mode)
  const displayRegions = useMemo(() => {
    if (timelineMode === 'regions') {
      // Use drag preview when actively dragging, otherwise show pending changes
      if (regionDragType !== 'none') {
        return getDragPreviewRegions(regions);
      }
      return baseDisplayRegions;
    }
    return regions;
  }, [timelineMode, regions, baseDisplayRegions, getDragPreviewRegions, regionDragType, dragCurrentTime]);

  // Selected region IDs as a Set for efficient lookup
  // Now that we use ID-based keying, selectedRegionIds ARE the IDs we need
  const selectedRegionIdSet = useMemo(() => {
    return new Set(selectedRegionIds);
  }, [selectedRegionIds]);

  // The ID of the region being dragged (already an ID, not an index)
  const draggedRegionId = regionDragId;

  // Gesture state (navigate mode)
  // Simplified: tap = seek, horizontal drag = select, vertical drag off = cancel
  const [dragStart, setDragStart] = useState<number | null>(null);
  const [dragEnd, setDragEnd] = useState<number | null>(null);
  const [isCancelled, setIsCancelled] = useState(false);
  const containerRef = useRef<HTMLDivElement>(null);
  const [containerWidth, setContainerWidth] = useState(0);

  // Track pan gesture start position for tap detection
  const panStartPositionRef = useRef<{ x: number; y: number } | null>(null);

  // Track container width for marker clustering
  useEffect(() => {
    if (!containerRef.current) return;

    const updateWidth = () => {
      if (containerRef.current) {
        setContainerWidth(containerRef.current.offsetWidth);
      }
    };

    // Initial measurement
    updateWidth();

    // Use ResizeObserver for responsive updates
    const resizeObserver = new ResizeObserver(updateWidth);
    resizeObserver.observe(containerRef.current);

    return () => resizeObserver.disconnect();
  }, []);

  // Modal actions from store (modals rendered by ModalRoot)
  const openMarkerEditModal = useReaperStore((s) => s.openMarkerEditModal);
  const openMakeSelectionModal = useReaperStore((s) => s.openMakeSelectionModal);

  // Marker navigation callbacks
  const handlePrevMarker = useCallback(() => {
    sendCommand(action.execute(40172)); // Go to previous marker/project start
  }, [sendCommand]);

  const handleNextMarker = useCallback(() => {
    sendCommand(action.execute(40173)); // Go to next marker/project end
  }, [sendCommand]);

  // Track max playhead position reached during playback
  // This allows viewport to extend past the initial project end (like REAPER's soft-end behavior)
  const [maxPlayheadPosition, setMaxPlayheadPosition] = useState(0);

  // Calculate base timeline bounds (without drag targets - used as fallback when cancelled)
  const { baseTimelineStart, baseDuration } = useMemo(() => {
    const start = 0;
    let end = 0;

    // Use display regions (includes drag preview) to get current extent
    for (const region of displayRegions) {
      if (region.end > end) end = region.end;
    }
    for (const marker of markers) {
      if (marker.position > end) end = marker.position;
    }
    // Include items - they may extend beyond regions
    for (const item of items) {
      const itemEnd = item.position + item.length;
      if (itemEnd > end) end = itemEnd;
    }
    // Include playhead position to ensure it's always visible
    // (fixes race condition on initial load when regions/markers haven't synced yet)
    if (positionSeconds > end) end = positionSeconds;
    // Include max position reached during playback (soft-end like REAPER)
    if (maxPlayheadPosition > end) end = maxPlayheadPosition;

    // Add 5% padding at the end
    end = Math.max(end * 1.015, 10);

    return { baseTimelineStart: start, baseDuration: end - start };
  }, [displayRegions, markers, items, positionSeconds, maxPlayheadPosition]);

  // Use base bounds for hook calculations (stable positioning)
  const timelineStart = baseTimelineStart;
  const duration = baseDuration;

  // Viewport state for pan/zoom navigation
  // Use external viewport if provided (shared state from TimelineSection), otherwise create own
  const internalViewport = useViewport({
    projectDuration: duration,
    initialRange: { start: 0, end: Math.min(30, duration) }, // Default 30 seconds or full project
  });
  const viewport = externalViewport ?? internalViewport;

  // Selection mode toggle state (pan mode vs selection mode in navigate)
  const [selectionModeActive, setSelectionModeActive] = useState(false);

  // Follow playhead state
  const [followPlayhead, setFollowPlayhead] = useState(true);
  const followPlayheadReEnable = useReaperStore((s) => s.followPlayheadReEnable);
  const playState = useReaperStore((s) => s.playState);
  const isPlaying = playState === 1;
  const wasPlayingRef = useRef(false);

  // Re-enable follow on playback start (if preference allows)
  useEffect(() => {
    if (isPlaying && !wasPlayingRef.current && followPlayheadReEnable === 'on-playback') {
      setFollowPlayhead(true);
    }
    wasPlayingRef.current = isPlaying;
  }, [isPlaying, followPlayheadReEnable]);

  // Follow playhead using animation engine
  // Handles both smooth scrolling during playback AND jumps when stopped (marker nav, seeks)
  const lastFollowPanRef = useRef(0);
  const lastKnownPositionRef = useRef(0);
  const FOLLOW_THROTTLE_MS = 100; // Max 10 viewport updates per second
  const JUMP_THRESHOLD = 0.5; // Seconds - consider it a "jump" if position changes by more than this

  useTransportAnimation(
    (state) => {
      const playheadPos = state.position;

      // Track max position reached (extends project bounds like REAPER's soft-end)
      // Only update during playback to avoid resetting on seeks backward
      if (state.isPlaying && playheadPos > maxPlayheadPosition) {
        setMaxPlayheadPosition(playheadPos);
      }

      if (!followPlayhead) return;

      const { start, end } = viewport.visibleRange;
      const visibleDuration = end - start;

      // Detect jumps (marker nav, seeks) - these should always trigger a pan
      const positionDelta = Math.abs(playheadPos - lastKnownPositionRef.current);
      const isJump = positionDelta > JUMP_THRESHOLD;
      lastKnownPositionRef.current = playheadPos;

      // When stopped: only respond to jumps (marker navigation, seeks)
      // When playing: use threshold-based smooth follow
      if (!state.isPlaying && !isJump) return;

      // Throttle during playback (but not for jumps - those should be immediate)
      const now = performance.now();
      if (!isJump && now - lastFollowPanRef.current < FOLLOW_THROTTLE_MS) return;

      // Check if playhead is outside the middle 60% of viewport
      const leftThreshold = start + visibleDuration * 0.2;
      const rightThreshold = end - visibleDuration * 0.2;

      if (playheadPos < leftThreshold || playheadPos > rightThreshold) {
        // Center viewport on playhead (viewport hook handles clamping)
        viewport.setVisibleRange({
          start: playheadPos - visibleDuration / 2,
          end: playheadPos + visibleDuration / 2,
        });
        lastFollowPanRef.current = now;
      }
    },
    [followPlayhead, viewport, maxPlayheadPosition]
  );

  // Pause follow when user pans
  const pauseFollow = useCallback(() => {
    if (followPlayhead) {
      setFollowPlayhead(false);
    }
  }, [followPlayhead]);

  // Convert time to percentage position (using base values for stability)
  const timeToPercent = useCallback(
    (time: number) => {
      if (duration === 0) return 0;
      return ((time - timelineStart) / duration) * 100;
    },
    [timelineStart, duration]
  );

  // Playhead position and drag hook (must be before handlePointerDown which uses isDraggingPlayhead)
  // Use viewport-relative percent for drag calculations to match rendering
  // Simple viewport-relative conversion (without drag-extension logic which is only for region rendering)
  const viewportTimeToPercent = useCallback(
    (time: number) => {
      const { start, end } = viewport.visibleRange;
      const duration = end - start;
      if (duration === 0) return 0;
      return ((time - start) / duration) * 100;
    },
    [viewport.visibleRange]
  );
  const playheadPercent = viewportTimeToPercent(positionSeconds);
  const handlePlayheadSeek = useCallback(
    (newTime: number) => sendCommand(transport.seek(newTime)),
    [sendCommand]
  );
  const {
    isDragging: isDraggingPlayhead,
    previewTime: playheadPreviewTime,
    handlePointerDown: handlePlayheadPointerDown,
    handlePointerMove: handlePlayheadPointerMove,
    handlePointerUp: handlePlayheadPointerUp,
  } = usePlayheadDrag({
    containerRef,
    playheadPercent,
    playheadTime: positionSeconds,
    viewportStart: viewport.visibleRange.start,
    viewportEnd: viewport.visibleRange.end,
    bpm,
    timeToPercent: viewportTimeToPercent,
    onSeek: handlePlayheadSeek,
  });

  // Convert x position to time (using viewport coordinates)
  const positionToTime = useCallback(
    (clientX: number) => {
      if (!containerRef.current) return 0;
      const rect = containerRef.current.getBoundingClientRect();
      const percent = (clientX - rect.left) / rect.width;
      const { start, end } = viewport.visibleRange;
      return start + percent * (end - start);
    },
    [viewport.visibleRange]
  );

  // Region drag hook (handles move, resize with vertical-cancel)
  const {
    handlePointerDown: handleRegionPointerDown,
    handlePointerMove: handleRegionPointerMove,
    handlePointerUp: handleRegionPointerUp,
    isCancelled: isRegionDragCancelled,
  } = useRegionDrag({
    containerRef,
    timelineStart,
    duration,
    bpm,
    denominator,
    displayRegions,
    baseDisplayRegions,
    selectedRegionIds,
    regions,
    timeToPercent,
    positionToTime,
    regionDragType,
    regionDragId,
    dragStartTime,
    dragCurrentTime,
    isRegionSelected,
    selectRegion,
    deselectRegion,
    clearSelection,
    startDrag,
    updateDrag,
    endDrag,
    cancelDrag,
    resizeRegion,
    moveRegion,
  });

  // Pan gesture for viewport navigation (navigate mode, when not in selection mode)
  const panGesture = usePanGesture({
    containerRef,
    visibleDuration: viewport.visibleDuration,
    onPan: (delta) => {
      viewport.pan(delta);
      pauseFollow(); // Pause follow when user pans
    },
    disabled: timelineMode !== 'navigate' || selectionModeActive,
    disableMomentum: prefersReducedMotion,
  });

  // Pinch gesture for zooming (works in all modes)
  const pinchGesture = usePinchGesture({
    containerRef,
    visibleRange: viewport.visibleRange,
    setVisibleRange: viewport.setVisibleRange,
    projectDuration: duration,
    disabled: false, // Pinch always works
  });

  // Render-specific timeToPercent (uses VIEWPORT bounds for visible range)
  // Extends viewport during drag operations to show drag targets
  const renderTimeToPercent = useCallback(
    (time: number) => {
      // Calculate effective visible range, extending for drag operations
      let effectiveStart = viewport.visibleRange.start;
      let effectiveEnd = viewport.visibleRange.end;

      // Don't extend when resize drag is cancelled
      const isResizing = regionDragType === 'resize-start' || regionDragType === 'resize-end';
      const shouldExtend = !isResizing || !isRegionDragCancelled;

      if (shouldExtend) {
        // Extend for resize edge position
        if (resizeEdgePosition !== null) {
          effectiveStart = Math.min(effectiveStart, resizeEdgePosition);
          effectiveEnd = Math.max(effectiveEnd, resizeEdgePosition);
        }
        // Extend for insertion point
        if (insertionPoint !== null) {
          effectiveStart = Math.min(effectiveStart, insertionPoint);
          effectiveEnd = Math.max(effectiveEnd, insertionPoint);
        }
        // Extend for drag target
        if (dragCurrentTime !== null) {
          effectiveStart = Math.min(effectiveStart, dragCurrentTime);
          effectiveEnd = Math.max(effectiveEnd, dragCurrentTime);
        }
      }

      const effectiveDuration = effectiveEnd - effectiveStart;
      if (effectiveDuration === 0) return 0;
      return ((time - effectiveStart) / effectiveDuration) * 100;
    },
    [viewport.visibleRange, resizeEdgePosition, insertionPoint, dragCurrentTime, regionDragType, isRegionDragCancelled]
  );

  // Filter items to visible viewport range with buffer for smooth scrolling
  const VISIBILITY_BUFFER = 10; // seconds of buffer on each side

  const { visibleItems: visibleRegions } = useVisibleRegions(
    displayRegions,
    viewport.visibleRange,
    VISIBILITY_BUFFER
  );
  const { visibleItems: visibleMarkers } = useVisibleMarkers(
    markers,
    viewport.visibleRange,
    VISIBILITY_BUFFER
  );

  // Cluster markers based on zoom level (40px merge threshold)
  const { clusters: markerClusters } = useMarkerClusters({
    markers: visibleMarkers,
    visibleRange: viewport.visibleRange,
    containerWidth,
  });

  const { visibleItems: visibleItems } = useVisibleMediaItems(
    items,
    viewport.visibleRange,
    VISIBILITY_BUFFER
  );

  // Compute items on the selected track for waveform overlay
  const { coloredTrackItems, coloredTrackGuid } = useMemo(() => {
    if (!selectedItemGuid) return { coloredTrackItems: [], coloredTrackGuid: null };
    const selectedItem = visibleItems.find((item) => item.guid === selectedItemGuid);
    if (!selectedItem) return { coloredTrackItems: [], coloredTrackGuid: null };
    const trackIdx = selectedItem.trackIdx;
    const filteredItems = visibleItems.filter((item) => item.trackIdx === trackIdx);
    // Use trackSkeleton for GUID (always available), not tracks (requires subscription)
    const trackGuid = trackSkeleton[trackIdx]?.g ?? null;
    return { coloredTrackItems: filteredItems, coloredTrackGuid: trackGuid };
  }, [selectedItemGuid, visibleItems, trackSkeleton]);

  // Set time selection in REAPER via WebSocket
  const setTimeSelection = useCallback(
    (startSeconds: number, endSeconds: number) => {
      sendCommand(timeSelCmd.set(startSeconds, endSeconds));
      // Store locally (server updates will overwrite every ~30ms anyway)
      setStoredTimeSelection({
        startSeconds,
        endSeconds,
      });
    },
    [sendCommand, setStoredTimeSelection]
  );

  // Navigate to position
  const navigateTo = useCallback(
    (time: number) => {
      sendCommand(transport.seek(time));
    },
    [sendCommand]
  );

  // Find nearest snap target (region edge, marker, or playhead)
  const findNearestBoundary = useCallback(
    (time: number): number => {
      return findNearestSnapTarget(time, {
        regions,
        markers,
        playheadPosition: positionSeconds,
      });
    },
    [regions, markers, positionSeconds]
  );

  // Handle touch/mouse start
  const handlePointerDown = useCallback(
    (e: React.PointerEvent) => {
      // Always track pinch pointers (works in all modes)
      const pinchStarted = pinchGesture.handlePointerDown(e);
      if (pinchStarted) {
        // isPinchingRef is already set to true inside the hook
        pauseFollow(); // Don't follow playhead while user is zooming
        return; // Pinch takes priority
      }

      // Don't start timeline selection if dragging playhead
      if (isDraggingPlayhead) return;

      // Region editing mode - delegate to hook
      if (timelineMode === 'regions') {
        handleRegionPointerDown(e);
        return;
      }

      // Navigate mode
      if (timelineMode === 'navigate') {
        if (!selectionModeActive) {
          // Pan mode (default) - track start position for tap detection, then delegate
          panStartPositionRef.current = { x: e.clientX, y: e.clientY };
          panGesture.handlePointerDown(e);
          return;
        }
        // Selection mode - time selection gesture
        const time = positionToTime(e.clientX);
        setDragStart(time);
        setDragEnd(time);
        setIsCancelled(false);
        // Capture pointer for drag events
        (e.target as HTMLElement).setPointerCapture(e.pointerId);
      }
    },
    [positionToTime, isDraggingPlayhead, timelineMode, handleRegionPointerDown, selectionModeActive, panGesture, pinchGesture, pauseFollow]
  );

  // Handle touch/mouse move
  const handlePointerMove = useCallback(
    (e: React.PointerEvent) => {
      // Always update pinch pointers (even if not pinching yet, to track second finger)
      pinchGesture.handlePointerMove(e);

      // If pinching, skip other gesture handling
      if (pinchGesture.isPinchingRef.current) return;

      // Region editing mode - delegate to hook
      if (timelineMode === 'regions') {
        handleRegionPointerMove(e);
        return;
      }

      // Navigate mode
      if (timelineMode === 'navigate') {
        if (!selectionModeActive) {
          // Pan mode - delegate to pan gesture
          panGesture.handlePointerMove(e);
          return;
        }
        // Selection mode - time selection gesture
        if (dragStart === null || !containerRef.current) return;

        const time = positionToTime(e.clientX);
        setDragEnd(time);

        // Check if dragged off timeline (vertical cancel)
        const rect = containerRef.current.getBoundingClientRect();
        const isOutsideVertically =
          e.clientY < rect.top - VERTICAL_CANCEL_THRESHOLD ||
          e.clientY > rect.bottom + VERTICAL_CANCEL_THRESHOLD;

        if (isOutsideVertically) {
          setIsCancelled(true);
        } else {
          setIsCancelled(false);
        }
      }
    },
    [dragStart, positionToTime, timelineMode, handleRegionPointerMove, selectionModeActive, panGesture, pinchGesture]
  );

  // Handle touch/mouse end
  const handlePointerUp = useCallback(
    (e: React.PointerEvent) => {
      // Check if we were pinching BEFORE processing the pointer up
      const wasPinching = pinchGesture.isPinchingRef.current;

      // Always track pinch pointer removal
      pinchGesture.handlePointerUp(e);

      // If we were pinching, don't process as tap/other gesture
      // This handles both "still pinching" (2+ fingers) and "pinch just ended" (1 finger lifted)
      if (wasPinching) {
        return;
      }

      // Region editing mode - delegate to hook
      if (timelineMode === 'regions') {
        handleRegionPointerUp(e);
        return;
      }

      // Navigate mode
      if (timelineMode === 'navigate') {
        if (!selectionModeActive) {
          // Pan mode - delegate to pan gesture
          panGesture.handlePointerUp(e);

          // Check if it was a tap (minimal movement) - if so, check for item hit
          if (panStartPositionRef.current && containerRef.current) {
            const dx = Math.abs(e.clientX - panStartPositionRef.current.x);
            const dy = Math.abs(e.clientY - panStartPositionRef.current.y);

            if (dx < TAP_THRESHOLD && dy < TAP_THRESHOLD) {
              // It was a tap - check for item at this position
              const rect = containerRef.current.getBoundingClientRect();
              const clickPercent = (e.clientX - rect.left) / rect.width;
              const clickTime =
                viewport.visibleRange.start +
                clickPercent * (viewport.visibleRange.end - viewport.visibleRange.start);

              // Check if tap is within item blob vertical bounds (25% height, centered)
              // Item blobs render at topOffset to topOffset + blobHeight
              const containerHeight = rect.height;
              const blobHeight = containerHeight * 0.25;
              const topOffset = (containerHeight - blobHeight) / 2;
              const relativeY = e.clientY - rect.top;
              const isWithinBlobYBounds = relativeY >= topOffset && relativeY <= topOffset + blobHeight;

              if (!isWithinBlobYBounds) {
                // Tap is outside the blob strip - don't select item
                panStartPositionRef.current = null;
                return;
              }

              // Find items at this time position
              const itemsAtTime = items.filter(
                (item) =>
                  item.position <= clickTime && item.position + item.length >= clickTime
              );

              if (itemsAtTime.length > 0) {
                // Group by track, find first track (lowest index) with items
                const byTrack = new Map<number, WSItem[]>();
                itemsAtTime.forEach((item) => {
                  if (!byTrack.has(item.trackIdx)) byTrack.set(item.trackIdx, []);
                  byTrack.get(item.trackIdx)!.push(item);
                });

                // Get first track (lowest index)
                const firstTrackIdx = Math.min(...byTrack.keys());
                const trackItems = byTrack.get(firstTrackIdx)!;

                // Sort by position, take first (earliest) item
                const firstItem = trackItems.sort((a, b) => a.position - b.position)[0];

                // Select the item (use GUID for stable selection)
                selectItem(firstItem.guid);
                // Sync selection to REAPER so actions can be applied to this item
                sendCommand(itemCmd.select(firstItem.trackIdx, firstItem.itemIdx));
              }
            }
          }

          // Clear start position
          panStartPositionRef.current = null;
          return;
        }

        // Selection mode - time selection gesture
        if (dragStart === null) return;

        const endTime = positionToTime(e.clientX);
        const wasDraggingHorizontally = Math.abs(endTime - dragStart) > 0.1;

        // Check final cancel state
        const rect = containerRef.current?.getBoundingClientRect();
        const isOutsideVertically = rect && (
          e.clientY < rect.top - VERTICAL_CANCEL_THRESHOLD ||
          e.clientY > rect.bottom + VERTICAL_CANCEL_THRESHOLD
        );

        if (isCancelled || isOutsideVertically) {
          // Cancelled - do nothing
        } else if (wasDraggingHorizontally) {
          // Horizontal drag = create time selection
          let selStart = Math.min(dragStart, endTime);
          let selEnd = Math.max(dragStart, endTime);

          // Snap to boundaries
          selStart = findNearestBoundary(selStart);
          selEnd = findNearestBoundary(selEnd);

          setTimeSelection(selStart, selEnd);
        } else {
          // Tap (no horizontal movement) = navigate to nearest boundary
          navigateTo(findNearestBoundary(dragStart));
        }

        // Reset state
        setDragStart(null);
        setDragEnd(null);
        setIsCancelled(false);

        // Release pointer capture (may already be released on pointercancel)
        try {
          (e.target as HTMLElement).releasePointerCapture(e.pointerId);
        } catch {
          // Pointer capture already released
        }
      }
    },
    [
      dragStart,
      isCancelled,
      positionToTime,
      findNearestBoundary,
      setTimeSelection,
      navigateTo,
      timelineMode,
      handleRegionPointerUp,
      selectionModeActive,
      panGesture,
      pinchGesture,
      items,
      selectItem,
      viewport,
    ]
  );

  // Marker drag hook
  const handleMarkerMoveFromDrag = useCallback(
    (markerId: number, newPositionSeconds: number) => {
      sendCommand(markerCmd.update(markerId, { position: newPositionSeconds }));
    },
    [sendCommand]
  );
  // Get marker selection action from store
  const setSelectedMarkerId = useReaperStore((state) => state.setSelectedMarkerId);
  const setMarkerLocked = useReaperStore((state) => state.setMarkerLocked);

  // Cluster tap handler - zoom to expand or show popover
  const handleClusterTap = useCallback(
    (cluster: MarkerClusterData) => {
      if (cluster.count <= 5) {
        // Small cluster: select first marker to show info (popover can be added later)
        const firstMarker = cluster.markers[0];
        setSelectedMarkerId(firstMarker.id);
        setMarkerLocked(true);
      } else {
        // Large cluster: zoom in on the cluster
        const clusterStart = cluster.markers[0].position;
        const clusterEnd = cluster.markers[cluster.markers.length - 1].position;
        const padding = (clusterEnd - clusterStart) * 0.2 || 2; // At least 2 seconds padding
        viewport.fitToContent({
          start: clusterStart - padding,
          end: clusterEnd + padding,
        });
      }
    },
    [viewport, setSelectedMarkerId, setMarkerLocked]
  );

  // Handle marker selection (locks auto-advance)
  const handleMarkerSelect = useCallback(
    (markerId: number) => {
      setSelectedMarkerId(markerId);
      setMarkerLocked(true);
    },
    [setSelectedMarkerId, setMarkerLocked]
  );

  const {
    isDragging: isDraggingMarker,
    draggedMarker,
    previewTime: markerDragPreviewTime,
    handlePointerDown: handleMarkerPointerDown,
    handlePointerMove: handleMarkerPointerMove,
    handlePointerUp: handleMarkerPointerUp,
  } = useMarkerDrag({
    containerRef,
    viewportStart: viewport.visibleRange.start,
    viewportEnd: viewport.visibleRange.end,
    bpm,
    timeToPercent: viewportTimeToPercent,
    onEdit: openMarkerEditModal,
    onMove: handleMarkerMoveFromDrag,
    onSelect: handleMarkerSelect,
  });

  // Edge scroll for playhead/marker drag operations
  // When dragging near the container edge, auto-scroll the viewport
  const edgeScroll = useEdgeScroll({
    containerRef,
    visibleDuration: viewport.visibleDuration,
    onPan: viewport.pan,
    enabled: isDraggingPlayhead || isDraggingMarker,
  });

  // Wrap playhead pointer handlers to include edge scroll
  // Note: The hook uses refs for enabled check, so we always call updateEdgeScroll
  const handlePlayheadPointerMoveWithEdge = useCallback(
    (e: React.PointerEvent) => {
      handlePlayheadPointerMove(e);
      edgeScroll.updateEdgeScroll(e.clientX);
    },
    [handlePlayheadPointerMove, edgeScroll]
  );

  const handlePlayheadPointerUpWithEdge = useCallback(
    (e: React.PointerEvent) => {
      edgeScroll.stopEdgeScroll();
      handlePlayheadPointerUp(e);
    },
    [handlePlayheadPointerUp, edgeScroll]
  );

  // Wrap marker pointer handlers to include edge scroll
  const handleMarkerPointerMoveWithEdge = useCallback(
    (e: React.PointerEvent) => {
      handleMarkerPointerMove(e);
      edgeScroll.updateEdgeScroll(e.clientX);
    },
    [handleMarkerPointerMove, edgeScroll]
  );

  const handleMarkerPointerUpWithEdge = useCallback(
    (e: React.PointerEvent) => {
      edgeScroll.stopEdgeScroll();
      handleMarkerPointerUp(e);
    },
    [handleMarkerPointerUp, edgeScroll]
  );

  // Calculate selection preview bounds
  const selectionPreview = useMemo(() => {
    if (dragStart === null || dragEnd === null) return null;
    // Don't show if cancelled or no horizontal movement
    if (isCancelled) return null;
    if (Math.abs(dragEnd - dragStart) <= 0.1) return null;

    let start = Math.min(dragStart, dragEnd);
    let end = Math.max(dragStart, dragEnd);

    // Snap to boundaries for preview
    start = findNearestBoundary(start);
    end = findNearestBoundary(end);

    return { start, end };
  }, [dragStart, dragEnd, isCancelled, findNearestBoundary]);

  return (
    <div className={`${className}`}>
      {/* Top bar - region labels (color bar + text) + playhead preview pill */}
      <div className="relative h-[25px] bg-bg-deep rounded-t-lg overflow-hidden">
        <TimelineRegionLabels
          displayRegions={visibleRegions}
          timelineMode={timelineMode}
          selectedRegionIds={selectedRegionIdSet}
          pendingChanges={pendingChanges}
          draggedRegionId={draggedRegionId}
          regionDragType={regionDragType}
          renderTimeToPercent={renderTimeToPercent}
          containerWidth={containerWidth}
        />
        {/* Playhead preview pill - rendered here to avoid overflow clipping */}
        <PlayheadPreviewPill
          playheadPreviewPercent={playheadPreviewTime !== null ? renderTimeToPercent(playheadPreviewTime) : null}
          playheadPreviewTime={playheadPreviewTime}
          isDraggingPlayhead={isDraggingPlayhead}
          bpm={bpm}
          barOffset={barOffset}
          beatsPerBar={beatsPerBar}
          denominator={denominator}
        />
      </div>

      <div
        ref={containerRef}
        data-testid="timeline-canvas"
        data-scroll-x={viewport.visibleRange.start.toFixed(2)}
        data-zoom-level={viewport.zoomLevel}
        data-visible-duration={viewport.visibleDuration.toFixed(2)}
        data-selection-mode={selectionModeActive}
        className="relative bg-bg-surface overflow-hidden touch-none"
        style={{ height }}
        onPointerDown={handlePointerDown}
        onPointerMove={handlePointerMove}
        onPointerUp={handlePointerUp}
        onPointerCancel={handlePointerUp}
      >
        {/* Regions - blocks only (no color), labels in top bar */}
        <TimelineRegionBlocks
          displayRegions={visibleRegions}
          timelineMode={timelineMode}
          selectedRegionIds={selectedRegionIdSet}
          pendingChanges={pendingChanges}
          draggedRegionId={draggedRegionId}
          regionDragType={regionDragType}
          hasPendingChanges={hasPendingChanges}
          renderTimeToPercent={renderTimeToPercent}
        />

        {/* Items density overlay - shows where items are in navigate mode */}
        {timelineMode === 'navigate' && visibleItems.length > 0 && (
          <ItemsDensityOverlay
            items={visibleItems}
            timelineStart={viewport.visibleRange.start}
            timelineEnd={viewport.visibleRange.end}
            height={height}
            tracks={tracks}
            selectedItemGuid={selectedItemGuid}
          />
        )}

        {/* Waveforms for items on selected track */}
        {timelineMode === 'navigate' && coloredTrackItems.length > 0 && (
          <TimelineWaveformOverlay
            items={coloredTrackItems}
            trackGuid={coloredTrackGuid}
            timelineStart={viewport.visibleRange.start}
            timelineEnd={viewport.visibleRange.end}
            height={height}
            enabled={true}
          />
        )}

        {/* Stored Time Selection */}
        {timeSelectionSeconds && (
          <div
            data-testid="time-selection"
            className={`absolute top-0 bottom-0 border-l-2 border-r-2 pointer-events-none ${
              timelineMode === 'regions'
                ? 'bg-bg-disabled/5 border-border-subtle opacity-50'
                : 'bg-selection-overlay-bg border-selection-overlay-border'
            }`}
            style={{
              left: `${renderTimeToPercent(timeSelectionSeconds.start)}%`,
              width: `${renderTimeToPercent(timeSelectionSeconds.end) - renderTimeToPercent(timeSelectionSeconds.start)}%`,
            }}
          />
        )}

        {/* Markers - lines only, labels in bottom bar */}
        <ClusteredMarkerLines
          clusters={markerClusters}
          timelineMode={timelineMode}
          renderTimeToPercent={renderTimeToPercent}
        />

        {/* Selection Preview */}
        {selectionPreview && (
          <div
            data-testid="selection-preview"
            className="absolute top-0 bottom-0 bg-selection-preview border-l-2 border-r-2 border-selection-border pointer-events-none"
            style={{
              left: `${renderTimeToPercent(selectionPreview.start)}%`,
              width: `${renderTimeToPercent(selectionPreview.end) - renderTimeToPercent(selectionPreview.start)}%`,
            }}
          />
        )}

        {/* Insertion Point Indicator (for move operations) */}
        {insertionPoint !== null && regionDragType === 'move' && (
          <div
            data-testid="insertion-indicator"
            className="absolute top-0 bottom-0 pointer-events-none z-20"
            style={{ left: `${renderTimeToPercent(insertionPoint)}%` }}
          >
            {/* Main insertion line */}
            <div className="absolute top-0 bottom-0 left-0 w-1 bg-insert-indicator shadow-lg shadow-insert-indicator/50" />
            {/* Top arrow indicator */}
            <div className="absolute -top-1 left-1/2 -translate-x-1/2 w-0 h-0 border-l-[6px] border-r-[6px] border-t-[8px] border-l-transparent border-r-transparent border-t-insert-indicator" />
            {/* Bottom arrow indicator */}
            <div className="absolute -bottom-1 left-1/2 -translate-x-1/2 w-0 h-0 border-l-[6px] border-r-[6px] border-b-[8px] border-l-transparent border-r-transparent border-b-insert-indicator" />
            {/* Position pill showing bar position at bottom - uses tempo map for accuracy */}
            <div className="absolute bottom-1 -translate-x-1/2 z-40">
              <div className="bg-bg-deep border border-insert-indicator rounded px-2 py-1 text-xs text-text-primary font-mono whitespace-nowrap shadow-lg">
                {tempoMarkers.length > 0
                  ? formatBarBeat(timeToBarBeat(insertionPoint, tempoMarkers, barOffset))
                  : bpm
                    ? formatBeats(insertionPoint, bpm, barOffset, beatsPerBar, denominator)
                    : `${insertionPoint.toFixed(1)}s`}
              </div>
            </div>
          </div>
        )}

        {/* Resize Edge Position Indicator - hidden when drag is cancelled */}
        {resizeEdgePosition !== null && (regionDragType === 'resize-start' || regionDragType === 'resize-end') && regionDragId !== null && !isRegionDragCancelled && (
          (() => {
            const originalRegion = regions.find(r => r.id === regionDragId);
            const originalEdge = regionDragType === 'resize-start' ? originalRegion?.start : originalRegion?.end;
            const delta = originalEdge !== undefined ? resizeEdgePosition - originalEdge : 0;
            const showDelta = Math.abs(delta) > 0.01 && bpm;

            return (
              <div
                className="absolute top-0 bottom-0 pointer-events-none z-20"
                style={{ left: `${renderTimeToPercent(resizeEdgePosition)}%` }}
              >
                {/* Main edge line */}
                <div className="absolute top-0 bottom-0 left-0 w-1 bg-insert-indicator shadow-lg shadow-insert-indicator/50" />
                {/* Top arrow indicator */}
                <div className="absolute -top-1 left-1/2 -translate-x-1/2 w-0 h-0 border-l-[6px] border-r-[6px] border-t-[8px] border-l-transparent border-r-transparent border-t-insert-indicator" />
                {/* Bottom arrow indicator */}
                <div className="absolute -bottom-1 left-1/2 -translate-x-1/2 w-0 h-0 border-l-[6px] border-r-[6px] border-b-[8px] border-l-transparent border-r-transparent border-b-insert-indicator" />
                {/* Delta pill showing change amount */}
                {showDelta && (
                  <div className="absolute top-8 -translate-x-1/2 z-40">
                    <div className={`rounded px-2 py-0.5 text-xs font-mono whitespace-nowrap shadow-lg ${
                      delta < 0 ? 'bg-delta-negative-bg text-delta-negative-text border border-delta-negative-border' : 'bg-delta-positive-bg text-delta-positive-text border border-delta-positive-border'
                    }`}>
                      {formatDelta(delta, bpm!, beatsPerBar, denominator)}
                    </div>
                  </div>
                )}
                {/* Position pill showing bar position at bottom - uses tempo map for accuracy */}
                <div className="absolute bottom-1 -translate-x-1/2 z-40">
                  <div className="bg-bg-deep border border-insert-indicator rounded px-2 py-1 text-xs text-text-primary font-mono whitespace-nowrap shadow-lg">
                    {tempoMarkers.length > 0
                      ? formatBarBeat(timeToBarBeat(resizeEdgePosition, tempoMarkers, barOffset))
                      : bpm
                        ? formatBeats(resizeEdgePosition, bpm, barOffset, beatsPerBar, denominator)
                        : `${resizeEdgePosition.toFixed(1)}s`}
                  </div>
                </div>
              </div>
            );
          })()
        )}

        {/* Playhead with grab handle */}
        <TimelinePlayhead
          positionSeconds={positionSeconds}
          timelineMode={timelineMode}
          isSyncing={isSyncing}
          isDraggingPlayhead={isDraggingPlayhead}
          renderTimeToPercent={renderTimeToPercent}
          handlePlayheadPointerDown={handlePlayheadPointerDown}
          handlePlayheadPointerMove={handlePlayheadPointerMoveWithEdge}
          handlePlayheadPointerUp={handlePlayheadPointerUpWithEdge}
        />

        {/* Preview playhead line/triangle during drag */}
        <PlayheadDragPreview
          playheadPreviewPercent={playheadPreviewTime !== null ? renderTimeToPercent(playheadPreviewTime) : null}
          isDraggingPlayhead={isDraggingPlayhead}
        />

        {/* Preview marker during drag */}
        <MarkerDragPreview
          draggedMarker={draggedMarker}
          isDraggingMarker={isDraggingMarker}
          markerDragPreviewPercent={markerDragPreviewTime !== null ? renderTimeToPercent(markerDragPreviewTime) : null}
          markerDragPreviewTime={markerDragPreviewTime}
          bpm={bpm}
          barOffset={barOffset}
          beatsPerBar={beatsPerBar}
          denominator={denominator}
        />


        {/* Empty state - show only if no visible content */}
        {visibleRegions.length === 0 && visibleMarkers.length === 0 && (
          <div className="absolute inset-0 flex items-center justify-center text-text-muted text-sm">
            {displayRegions.length === 0 && markers.length === 0
              ? 'No regions or markers'
              : 'Pan to see content'}
          </div>
        )}

        {/* Syncing indicator */}
        {isSyncing && (
          <div className="absolute inset-0 flex items-center justify-center z-50 pointer-events-none">
            <div className="px-3 py-1.5 bg-bg-deep/90 border border-sync-border rounded-full text-sync-text text-xs font-medium animate-pulse">
              Syncing...
            </div>
          </div>
        )}
      </div>

      {/* Bottom bar - selection indicator and marker pills */}
      <div className={`relative h-5 bg-bg-deep overflow-hidden ${timelineMode !== 'navigate' ? 'rounded-b-lg' : ''}`}>
        {/* Time selection indicator - top half */}
        {timeSelectionSeconds && (
          <div
            className={`absolute top-0 h-1/2 ${
              timelineMode === 'regions' ? 'bg-bg-hover opacity-40' : 'bg-selection-indicator'
            }`}
            style={{
              left: `${renderTimeToPercent(timeSelectionSeconds.start)}%`,
              width: `${renderTimeToPercent(timeSelectionSeconds.end) - renderTimeToPercent(timeSelectionSeconds.start)}%`,
            }}
          />
        )}
        {/* Marker pills - offset by 1px to center on 2px-wide marker line */}
        <ClusteredMarkerPills
          clusters={markerClusters}
          timelineMode={timelineMode}
          renderTimeToPercent={renderTimeToPercent}
          draggedMarker={draggedMarker}
          isDraggingMarker={isDraggingMarker}
          handleMarkerPointerDown={handleMarkerPointerDown}
          handleMarkerPointerMove={handleMarkerPointerMoveWithEdge}
          handleMarkerPointerUp={handleMarkerPointerUpWithEdge}
          onClusterTap={handleClusterTap}
        />
      </div>

      {/* Footer controls - only in navigate mode */}
      {timelineMode === 'navigate' && (
        <TimelineFooter
          // Marker navigation
          onPrevMarker={handlePrevMarker}
          onNextMarker={handleNextMarker}
          // Mode toggles
          followPlayhead={followPlayhead}
          onFollowPlayheadToggle={() => {
            if (!followPlayhead) {
              // Turning follow ON - stop momentum and center viewport on playhead
              panGesture.stopMomentum();
              const visibleDuration = viewport.visibleDuration;
              viewport.setVisibleRange({
                start: positionSeconds - visibleDuration / 2,
                end: positionSeconds + visibleDuration / 2,
              });
            }
            setFollowPlayhead(!followPlayhead);
          }}
          selectionModeActive={selectionModeActive}
          onSelectionModeToggle={() => setSelectionModeActive(!selectionModeActive)}
          onSelectionLongPress={openMakeSelectionModal}
          // Zoom controls
          visibleDuration={viewport.visibleDuration}
          onZoomIn={() => viewport.zoomIn()}
          onZoomOut={() => viewport.zoomOut()}
          onFitToContent={() => viewport.fitToContent({ start: baseTimelineStart, end: baseTimelineStart + baseDuration })}
        />
      )}
    </div>
  );
}
