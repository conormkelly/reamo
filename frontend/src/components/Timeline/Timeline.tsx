/**
 * Timeline Component
 * Visual timeline showing regions and markers for navigation and selection
 */

import { useState, useRef, useCallback, useMemo, useEffect, type ReactElement } from 'react';
import { useReaperStore } from '../../store';
import { computeDisplayRegions, computeDragPreview } from '../../store/slices/regionEditSlice';
import type { WSItem } from '../../core/WebSocketTypes';
import { useReaper } from '../ReaperProvider';
import {
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
import { transport, timeSelection as timeSelCmd, marker as markerCmd, action, item as itemCmd, track as trackCmd } from '../../core/WebSocketCommands';
import { usePlayheadDrag, useMarkerDrag, useRegionDrag, usePanGesture, usePinchGesture, useEdgeScroll, useTimelineSelectors } from './hooks';
import { TimelineRegionLabels, TimelineRegionBlocks } from './TimelineRegions';
import { MultiTrackLanes } from './MultiTrackLanes';
import type { SkeletonTrack } from '../../core/WebSocketTypes';
import { ClusteredMarkerLines, ClusteredMarkerPills } from './TimelineMarkers';
import { TimelineGridLines } from './TimelineGridLines';
import { TimelineRuler } from './TimelineRuler';
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
  /**
   * Tracks to show as multi-track lanes (Phase 2).
   * When provided, renders multiple track lanes instead of single-track item density overlay.
   */
  multiTrackLanes?: SkeletonTrack[];
  /** Track indices corresponding to multiTrackLanes (1-based, from bank) */
  multiTrackIndices?: number[];
  /** Function to assemble peaks for an item within the current viewport (tile-based) */
  assemblePeaksForViewport?: (
    takeGuid: string,
    itemPosition: number,
    itemLength: number
  ) => import('../../core/WebSocketTypes').StereoPeak[] | import('../../core/WebSocketTypes').MonoPeak[] | null;
  /** Function to check if tiles exist for a take */
  hasTilesForTake?: (takeGuid: string) => boolean;
}

// Vertical distance to cancel gesture (drag off timeline)
const VERTICAL_CANCEL_THRESHOLD = 50;

// Tap detection threshold (pixels) - movement less than this is considered a tap
const TAP_THRESHOLD = 10;

export function Timeline({ className = '', height = 120, isSyncing = false, viewport: externalViewport, multiTrackLanes, multiTrackIndices, assemblePeaksForViewport, hasTilesForTake }: TimelineProps): ReactElement {
  const { sendCommand } = useReaper();
  const {
    positionSeconds, regions, markers, items, trackSkeleton, bpm, tempoMarkers,
    storedTimeSelection, setStoredTimeSelection,
    timelineMode, selectedRegionIds, pendingChanges, hasPendingChanges,
    selectRegion, deselectRegion, clearSelection, isRegionSelected,
    resizeRegion, moveRegion, startDrag, updateDrag, endDrag, cancelDrag,
    regionDragType, regionDragId, dragCurrentTime, dragStartTime,
    insertionPoint, resizeEdgePosition,
    viewFilterTrackGuid, itemSelectionModeActive, enterItemSelectionMode, setViewFilterTrack,
    setSelectedMarkerId,
    openMarkerEditModal, openMakeSelectionModal,
    selectionModeActive, toggleSelectionMode,
    followPlayhead, setFollowPlayhead, pauseFollowPlayhead,
    setMarkerLocked,
  } = useTimelineSelectors();

  // Time signature and bar offset from hooks
  const { beatsPerBar, denominator } = useTimeSignature();
  const barOffset = useBarOffset();

  // Accessibility: reduced motion preference
  const prefersReducedMotion = useReducedMotion();

  // Helper: convert track GUID → trackIdx using skeleton (moves in Phase 3)
  const getTrackIdxFromGuid = useCallback(
    (guid: string): number | null => {
      const idx = trackSkeleton.findIndex((t) => t.g === guid);
      return idx >= 0 ? idx : null;
    },
    [trackSkeleton]
  );

  // Filter out invalid 0-width selections
  const timeSelectionSeconds = useMemo(() => {
    if (!storedTimeSelection) return null;
    // Don't show selections with negligible width (less than 0.01 seconds)
    if (Math.abs(storedTimeSelection.endSeconds - storedTimeSelection.startSeconds) < 0.01) return null;
    return { start: storedTimeSelection.startSeconds, end: storedTimeSelection.endSeconds };
  }, [storedTimeSelection]);

  // Base display regions (with pending changes but WITHOUT drag preview) - used for snap calculations
  // Uses pure function directly with explicit dependencies (no hidden store reads)
  const baseDisplayRegions = useMemo(() => {
    if (timelineMode === 'regions') {
      return computeDisplayRegions(regions, pendingChanges);
    }
    return regions;
  }, [timelineMode, regions, pendingChanges]);

  // Get regions to display (with pending changes and drag preview applied in region mode)
  // Uses pure function directly with explicit dependencies (no hidden store reads)
  const dragPreviewResult = useMemo(() => {
    if (timelineMode === 'regions' && regionDragType !== 'none') {
      return computeDragPreview(
        regions,
        pendingChanges,
        { dragType: regionDragType, dragRegionId: regionDragId, dragStartTime, dragCurrentTime },
        bpm,
        denominator
      );
    }
    return null;
  }, [timelineMode, regions, pendingChanges, regionDragType, regionDragId, dragStartTime, dragCurrentTime, bpm, denominator]);

  const displayRegions = useMemo(() => {
    if (timelineMode === 'regions') {
      // Use drag preview when actively dragging, otherwise show pending changes
      if (dragPreviewResult) {
        return dragPreviewResult.regions;
      }
      return baseDisplayRegions;
    }
    return regions;
  }, [timelineMode, regions, baseDisplayRegions, dragPreviewResult]);

  // Sync drag preview indicator positions to store (for rendering insertion point, resize edge)
  // This effect runs after the pure computation, keeping the store in sync without hidden deps
  useEffect(() => {
    useReaperStore.setState({
      insertionPoint: dragPreviewResult?.insertionPoint ?? null,
      resizeEdgePosition: dragPreviewResult?.resizeEdgePosition ?? null,
    });
  }, [dragPreviewResult]);

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
    initialRange: { start: 0, end: duration }, // Default to full project (zoom-to-fit)
  });
  const viewport = externalViewport ?? internalViewport;

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

  // Pause follow when user pans - uses store action directly
  const pauseFollow = pauseFollowPlayhead;

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
  // When following playhead, zoom centers on playhead instead of pinch midpoint
  const pinchGesture = usePinchGesture({
    containerRef,
    visibleRange: viewport.visibleRange,
    setVisibleRange: viewport.setVisibleRange,
    projectDuration: duration,
    disabled: false, // Pinch always works
    centerOnTime: followPlayhead ? positionSeconds : undefined,
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
        // Don't pause follow when following playhead - zoom is already centered on it
        if (!followPlayhead) {
          pauseFollow();
        }
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
    [positionToTime, isDraggingPlayhead, timelineMode, handleRegionPointerDown, selectionModeActive, panGesture, pinchGesture, pauseFollow, followPlayhead]
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
              const containerHeight = rect.height;
              const relativeY = e.clientY - rect.top;

              // Multi-track lanes mode: determine which lane was clicked
              if (multiTrackLanes && multiTrackLanes.length > 0 && multiTrackIndices && multiTrackIndices.length > 0) {
                const laneCount = multiTrackLanes.length;
                const laneHeight = containerHeight / laneCount;
                const laneIdx = Math.floor(relativeY / laneHeight);

                // Validate lane index
                if (laneIdx < 0 || laneIdx >= laneCount) {
                  panStartPositionRef.current = null;
                  return;
                }

                // Use passed track indices directly (slot-based for sequential banks)
                const clickedTrackGuid = multiTrackLanes[laneIdx]?.g;
                const clickedTrackIdx = multiTrackIndices[laneIdx];
                if (clickedTrackIdx === undefined) {
                  panStartPositionRef.current = null;
                  return;
                }

                // Check if click is within item strip in this lane (60% height, centered)
                const itemHeightPercent = 0.6;
                const itemTopOffset = laneHeight * (1 - itemHeightPercent) / 2;
                const relativeYInLane = relativeY - (laneIdx * laneHeight);
                const isWithinItemStrip = relativeYInLane >= itemTopOffset &&
                                          relativeYInLane <= itemTopOffset + (laneHeight * itemHeightPercent);

                // Find items at this time position ON THIS TRACK ONLY
                const itemsAtTime = items.filter(
                  (item) =>
                    item.trackIdx === clickedTrackIdx &&
                    item.position <= clickTime &&
                    item.position + item.length >= clickTime
                );

                // Tap on empty lane space (outside item strip OR no item at position)
                // → Clear all selections, select only this track
                if (!isWithinItemStrip || itemsAtTime.length === 0) {
                  // Clear marker selection (mutual exclusion)
                  setSelectedMarkerId(null);
                  // Clear all track and item selections, then select this track only
                  sendCommand(trackCmd.unselectAll());
                  sendCommand(itemCmd.unselectAll());
                  sendCommand(trackCmd.setSelected(clickedTrackIdx, 1));
                  // Set visual highlight for the selected track
                  if (clickedTrackGuid) {
                    setViewFilterTrack(clickedTrackGuid);
                  }
                  panStartPositionRef.current = null;
                  return;
                }

                // Tap on item → toggle item selection + select item's track
                if (itemsAtTime.length > 0) {
                  // Clear marker selection (mutual exclusion)
                  setSelectedMarkerId(null);

                  // Enter item selection mode if not already active
                  if (!itemSelectionModeActive && clickedTrackGuid) {
                    enterItemSelectionMode(clickedTrackGuid);
                  }

                  // Sort by position, take first (earliest) item and toggle selection
                  const firstItem = itemsAtTime.sort((a, b) => a.position - b.position)[0];
                  sendCommand(itemCmd.toggleSelect(firstItem.guid));

                  // Select the item's track (clears other track selections)
                  sendCommand(trackCmd.unselectAll());
                  sendCommand(trackCmd.setSelected(clickedTrackIdx, 1));
                }
              } else {
                // Single-track mode: original logic
                // Check if tap is within item blob vertical bounds (25% height, centered)
                const blobHeight = containerHeight * 0.25;
                const topOffset = (containerHeight - blobHeight) / 2;
                const isWithinBlobYBounds = relativeY >= topOffset && relativeY <= topOffset + blobHeight;

                if (!isWithinBlobYBounds) {
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
                  const trackGuid = trackSkeleton[firstTrackIdx]?.g;

                  // Clear marker selection (mutual exclusion)
                  setSelectedMarkerId(null);

                  if (!itemSelectionModeActive) {
                    // Not in item selection mode yet - enter it
                    if (trackGuid) {
                      enterItemSelectionMode(trackGuid);
                    }
                  } else {
                    // Already in item selection mode - only select items on the FILTERED track
                    const filterTrackIdx = viewFilterTrackGuid
                      ? getTrackIdxFromGuid(viewFilterTrackGuid)
                      : null;

                    if (filterTrackIdx !== null && byTrack.has(filterTrackIdx)) {
                      const trackItemsAtTime = byTrack.get(filterTrackIdx)!;
                      const firstItem = trackItemsAtTime.sort((a, b) => a.position - b.position)[0];
                      sendCommand(itemCmd.toggleSelect(firstItem.guid));
                    }
                  }
                }
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
      setSelectedMarkerId,
      viewport,
      trackSkeleton,
      itemSelectionModeActive,
      enterItemSelectionMode,
      setViewFilterTrack,
      viewFilterTrackGuid,
      getTrackIdxFromGuid,
      sendCommand,
      multiTrackLanes,
      multiTrackIndices,
    ]
  );

  // Marker drag hook
  const handleMarkerMoveFromDrag = useCallback(
    (markerId: number, newPositionSeconds: number) => {
      sendCommand(markerCmd.update(markerId, { position: newPositionSeconds }));
    },
    [sendCommand]
  );
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
      {/* Ruler - bar numbers and time at top */}
      <TimelineRuler
        renderTimeToPercent={renderTimeToPercent}
        visibleRange={viewport.visibleRange}
        visibleDuration={viewport.visibleDuration}
        tempoMarkers={tempoMarkers}
        barOffset={barOffset}
      />

      {/* Region labels bar (color bar + text) + playhead preview pill */}
      <div className="relative h-[25px] bg-bg-deep overflow-hidden">
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
        {/* Grid lines - bar/beat markers based on tempo (behind everything) */}
        <TimelineGridLines
          renderTimeToPercent={renderTimeToPercent}
          visibleRange={viewport.visibleRange}
          visibleDuration={viewport.visibleDuration}
          tempoMarkers={tempoMarkers}
          barOffset={barOffset}
        />

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

        {/* Items layer - multi-track lanes showing items across visible tracks */}
        {timelineMode === 'navigate' && multiTrackLanes && multiTrackLanes.length > 0 && multiTrackIndices && (
          <MultiTrackLanes
            tracks={multiTrackLanes}
            trackIndices={multiTrackIndices}
            items={visibleItems}
            timelineStart={viewport.visibleRange.start}
            timelineEnd={viewport.visibleRange.end}
            height={height}
            focusedTrackGuid={viewFilterTrackGuid}
            assemblePeaksForViewport={assemblePeaksForViewport}
            hasTilesForTake={hasTilesForTake}
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
          onSelectionModeToggle={toggleSelectionMode}
          onSelectionLongPress={openMakeSelectionModal}
          // Zoom controls - center on playhead when following
          visibleDuration={viewport.visibleDuration}
          onZoomIn={() => viewport.zoomIn(followPlayhead ? positionSeconds : undefined)}
          onZoomOut={() => viewport.zoomOut(followPlayhead ? positionSeconds : undefined)}
          onFitToContent={() => viewport.fitToContent({ start: baseTimelineStart, end: baseTimelineStart + baseDuration })}
        />
      )}
    </div>
  );
}
