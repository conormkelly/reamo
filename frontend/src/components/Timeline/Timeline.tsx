/**
 * Timeline Component
 * Visual timeline showing regions and markers for navigation and selection
 */

import { useRef, useCallback, useMemo, useEffect, type ReactElement } from 'react';
import { useReaperStore } from '../../store';
import { computeDisplayRegions, computeDragPreview } from '../../store/slices/regionEditSlice';
import { useReaper } from '../ReaperProvider';
import {
  useTimeSignature,
  useBarOffset,
  useVisibleRegions,
  useVisibleMarkers,
  useVisibleMediaItems,
  useMarkerClusters,
  useReducedMotion,
  type MarkerClusterData,
  type UseViewportReturn,
} from '../../hooks';
import { transport, timeSelection as timeSelCmd, marker as markerCmd, action } from '../../core/WebSocketCommands';
import { usePlayheadDrag, useMarkerDrag, useRegionDrag, useEdgeScroll, useTimelineSelectors, useItemTapHandler, useTimelineViewport, useTimelinePointerEvents } from './hooks';
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
   * Tracks to show as multi-track lanes.
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
    optimisticSelectTrack,
    optimisticToggleItemSelected,
    optimisticUnselectAllItems,
  } = useTimelineSelectors();

  // Time signature and bar offset from hooks
  const { beatsPerBar, denominator } = useTimeSignature();
  const barOffset = useBarOffset();

  // Accessibility: reduced motion preference
  const prefersReducedMotion = useReducedMotion();

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

  const containerRef = useRef<HTMLDivElement>(null);

  // Viewport, follow-playhead, coordinate conversion, pan/pinch gestures
  const {
    viewport, containerWidth, timelineStart, duration,
    baseTimelineStart, baseDuration,
    timeToPercent, viewportTimeToPercent, playheadPercent,
    positionToTime, pauseFollow,
    panGesture, pinchGesture,
  } = useTimelineViewport({
    containerRef,
    positionSeconds,
    displayRegions,
    markers,
    items,
    externalViewport,
    followPlayhead,
    pauseFollowPlayhead,
    prefersReducedMotion,
    selectionModeActive,
    timelineMode,
  });

  // Marker navigation callbacks
  const handlePrevMarker = useCallback(() => {
    sendCommand(action.execute(40172)); // Go to previous marker/project start
  }, [sendCommand]);

  const handleNextMarker = useCallback(() => {
    sendCommand(action.execute(40173)); // Go to next marker/project end
  }, [sendCommand]);

  // Playhead drag hook
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

  // Item tap detection
  const handleItemTap = useItemTapHandler({
    containerRef,
    viewport,
    items,
    trackSkeleton,
    multiTrackLanes,
    multiTrackIndices,
    viewFilterTrackGuid,
    itemSelectionModeActive,
    enterItemSelectionMode,
    setViewFilterTrack,
    setSelectedMarkerId,
    sendCommand,
    optimisticSelectTrack,
    optimisticToggleItemSelected,
    optimisticUnselectAllItems,
  });

  // Pointer event routing
  const { handlePointerDown, handlePointerMove, handlePointerUp, selectionPreview } =
    useTimelinePointerEvents({
      containerRef,
      timelineMode,
      selectionModeActive,
      panGesture,
      pinchGesture,
      isDraggingPlayhead,
      handleRegionPointerDown,
      handleRegionPointerMove,
      handleRegionPointerUp,
      handleItemTap,
      positionToTime,
      followPlayhead,
      pauseFollow,
      setTimeSelection,
      navigateTo,
      findNearestBoundary,
    });

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
