/**
 * useRegionDrag Hook
 * Manages region drag interactions (move + resize) with vertical-cancel behavior
 *
 * Vertical-cancel: When the user drags their finger/pointer too far up or down
 * from the start position, the drag is cancelled and the region returns to its
 * original position. This matches the behavior of usePlayheadDrag and useMarkerDrag.
 */

import { useState, useRef, useCallback, type RefObject } from 'react';
import type { Region } from '../../../core/types';
import type { DragType } from '../../../store';
import { snapToGrid } from '../../../utils';

/** Vertical distance to cancel drag (pixels) */
const VERTICAL_CANCEL_THRESHOLD = 50;

/** Edge handle hit zone size in pixels */
const EDGE_HANDLE_SIZE = 20;

/** Long-press threshold for region edit modal (ms) */
const REGION_HOLD_THRESHOLD = 500;

export interface UseRegionDragOptions {
  /** Ref to the timeline container element */
  containerRef: RefObject<HTMLDivElement | null>;
  /** Timeline start time in seconds */
  timelineStart: number;
  /** Timeline duration in seconds */
  duration: number;
  /** Current BPM (for snapping) */
  bpm: number | null;
  /** Display regions (with pending changes, used for rendering) */
  displayRegions: Region[];
  /** Base display regions (original positions, used for snap calculations) */
  baseDisplayRegions: Region[];
  /** Currently selected region indices */
  selectedRegionIndices: number[];
  /** Original regions from REAPER */
  regions: Region[];
  /** Convert time to percentage */
  timeToPercent: (time: number) => number;
  /** Convert clientX to time */
  positionToTime: (clientX: number) => number;

  // Store state
  regionDragType: DragType;
  regionDragIndex: number | null;
  dragStartTime: number | null;
  dragCurrentTime: number | null;

  // Store actions
  isRegionSelected: (index: number) => boolean;
  selectRegion: (index: number) => void;
  deselectRegion: (index: number) => void;
  clearSelection: () => void;
  startDrag: (type: DragType, index: number, x: number, time: number) => void;
  updateDrag: (x: number, time: number) => void;
  endDrag: () => void;
  cancelDrag: () => void;
  resizeRegion: (index: number, edge: 'start' | 'end', newTime: number, regions: Region[], bpm: number | null) => void;
  moveRegion: (indices: number[], delta: number, regions: Region[]) => void;
  getDisplayRegions: (regions: Region[]) => Region[];

  // Callbacks
  onEditRegion?: (region: Region, index: number) => void;
}

export interface UseRegionDragResult {
  /** Handler for pointer down on the timeline */
  handlePointerDown: (e: React.PointerEvent) => void;
  /** Handler for pointer move during drag */
  handlePointerMove: (e: React.PointerEvent) => void;
  /** Handler for pointer up to complete drag */
  handlePointerUp: (e: React.PointerEvent) => void;
  /** Whether the current drag is cancelled (pointer moved too far vertically) */
  isCancelled: boolean;
  /** Find region index at a given clientX position */
  findRegionIndexAtPosition: (clientX: number) => number | null;
  /** Determine drag type based on click position within a region */
  detectDragType: (clientX: number, regionIndex: number) => DragType;
}

export function useRegionDrag({
  containerRef,
  timelineStart: _timelineStart,
  duration: _duration,
  bpm,
  displayRegions,
  baseDisplayRegions,
  selectedRegionIndices,
  regions,
  timeToPercent,
  positionToTime,
  regionDragType,
  regionDragIndex,
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
  getDisplayRegions,
  onEditRegion,
}: UseRegionDragOptions): UseRegionDragResult {
  // Local state for vertical-cancel
  const [dragStartY, setDragStartY] = useState<number | null>(null);
  const [isCancelled, setIsCancelled] = useState(false);

  // Track if region was already selected when tap started (for toggle behavior)
  const wasSelectedOnTapStartRef = useRef<boolean>(false);

  // Long-press timer for edit modal
  const holdTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Find region index at position
  const findRegionIndexAtPosition = useCallback(
    (clientX: number): number | null => {
      if (!containerRef.current) return null;
      const time = positionToTime(clientX);

      for (let i = 0; i < displayRegions.length; i++) {
        const region = displayRegions[i];
        if (time >= region.start && time < region.end) {
          return i;
        }
      }
      return null;
    },
    [displayRegions, positionToTime, containerRef]
  );

  // Determine drag type based on click position
  const detectDragType = useCallback(
    (clientX: number, regionIndex: number): DragType => {
      if (!containerRef.current) return 'move';

      const rect = containerRef.current.getBoundingClientRect();
      const region = displayRegions[regionIndex];
      if (!region) return 'move';

      const startPercent = timeToPercent(region.start);
      const endPercent = timeToPercent(region.end);

      const startX = rect.left + (startPercent / 100) * rect.width;
      const endX = rect.left + (endPercent / 100) * rect.width;

      if (Math.abs(clientX - startX) < EDGE_HANDLE_SIZE) {
        return 'resize-start';
      }
      if (Math.abs(clientX - endX) < EDGE_HANDLE_SIZE) {
        return 'resize-end';
      }
      return 'move';
    },
    [displayRegions, timeToPercent, containerRef]
  );

  // Check if pointer is outside vertical cancel threshold
  const isVerticalCancelActive = useCallback(
    (clientY: number): boolean => {
      if (!containerRef.current || dragStartY === null) return false;

      const rect = containerRef.current.getBoundingClientRect();
      const deltaY = Math.abs(clientY - dragStartY);
      const isOutsideVertically =
        clientY < rect.top - VERTICAL_CANCEL_THRESHOLD ||
        clientY > rect.bottom + VERTICAL_CANCEL_THRESHOLD;

      return isOutsideVertically || deltaY > VERTICAL_CANCEL_THRESHOLD;
    },
    [containerRef, dragStartY]
  );

  const handlePointerDown = useCallback(
    (e: React.PointerEvent) => {
      const time = positionToTime(e.clientX);
      const regionIndex = findRegionIndexAtPosition(e.clientX);

      if (regionIndex !== null) {
        const wasSelected = isRegionSelected(regionIndex);
        const dragType = detectDragType(e.clientX, regionIndex);

        // Track selection state at tap start for toggle behavior in pointerUp
        wasSelectedOnTapStartRef.current = wasSelected;

        // If already selected and tapped again, start long-press timer for edit modal
        if (wasSelected && selectedRegionIndices.length === 1) {
          holdTimerRef.current = setTimeout(() => {
            const region = displayRegions[regionIndex];
            if (region && onEditRegion) {
              onEditRegion(region, regionIndex);
            }
            // Cancel any drag
            cancelDrag();
            setDragStartY(null);
            setIsCancelled(false);
          }, REGION_HOLD_THRESHOLD);
        }

        // Start drag operation
        startDrag(dragType, regionIndex, e.clientX, time);
        setDragStartY(e.clientY);
        setIsCancelled(false);

        // Select the region if not already selected
        if (!wasSelected) {
          selectRegion(regionIndex);
        }
      } else {
        // Tapped on empty area - clear selection
        clearSelection();
      }

      // Capture pointer
      (e.target as HTMLElement).setPointerCapture(e.pointerId);
    },
    [
      positionToTime,
      findRegionIndexAtPosition,
      isRegionSelected,
      detectDragType,
      selectedRegionIndices,
      displayRegions,
      startDrag,
      selectRegion,
      clearSelection,
      cancelDrag,
      onEditRegion,
    ]
  );

  const handlePointerMove = useCallback(
    (e: React.PointerEvent) => {
      const time = positionToTime(e.clientX);

      if (regionDragType === 'none' || regionDragIndex === null) return;

      // Clear long-press timer if we moved
      if (holdTimerRef.current) {
        clearTimeout(holdTimerRef.current);
        holdTimerRef.current = null;
      }

      // Check for vertical cancel
      const shouldCancel = isVerticalCancelActive(e.clientY);
      setIsCancelled(shouldCancel);

      if (shouldCancel && dragStartTime !== null) {
        // Reset to original position to show cancel state
        updateDrag(e.clientX, dragStartTime);
        return;
      }

      // For move operations, snap to valid insertion points only
      if (regionDragType === 'move' && dragStartTime !== null) {
        const indicesToMove = selectedRegionIndices.length > 0
          ? selectedRegionIndices
          : [regionDragIndex];

        // Use baseDisplayRegions (positions BEFORE the drag), not displayRegions (preview)
        const primaryRegion = baseDisplayRegions[regionDragIndex];
        if (primaryRegion) {
          // Calculate where the region's start would be after the move
          const delta = time - dragStartTime;
          const newStart = primaryRegion.start + delta;
          const regionDuration = primaryRegion.end - primaryRegion.start;

          // Build valid insertion points accounting for gap closure
          const snapPoints: number[] = [0];

          // Always include the region's own position (allows "canceling" by returning to original)
          snapPoints.push(primaryRegion.start);

          let lastEnd = 0;
          baseDisplayRegions.forEach((region, index) => {
            if (!indicesToMove.includes(index)) {
              if (region.start < primaryRegion.start) {
                // Regions BEFORE: their starts are valid as-is
                snapPoints.push(region.start);
              } else {
                // Regions AFTER: adjust for gap closure
                snapPoints.push(region.start - regionDuration);
              }
              if (region.end > lastEnd) {
                lastEnd = region.end;
              }
            }
          });

          // Add the adjusted end position
          if (lastEnd > 0) {
            const adjustedLastEnd = lastEnd - regionDuration;
            snapPoints.push(adjustedLastEnd);
          }

          // Snap to nearest valid point
          let snappedStart = snapPoints[0];
          let minDist = Infinity;

          for (const point of snapPoints) {
            const dist = Math.abs(newStart - point);
            if (dist < minDist) {
              minDist = dist;
              snappedStart = point;
            }
          }

          // Adjust time to produce snapped position
          const snappedDelta = snappedStart - primaryRegion.start;
          const snappedTime = dragStartTime + snappedDelta;
          updateDrag(e.clientX, snappedTime);
          return;
        }
      }

      // For resize operations, snap to bar boundaries (4 beats)
      const snappedTime = bpm ? snapToGrid(time, bpm, 4) : time;
      updateDrag(e.clientX, snappedTime);
    },
    [
      positionToTime,
      regionDragType,
      regionDragIndex,
      dragStartTime,
      isVerticalCancelActive,
      updateDrag,
      selectedRegionIndices,
      baseDisplayRegions,
      bpm,
    ]
  );

  const handlePointerUp = useCallback(
    (e: React.PointerEvent) => {
      // Clear hold timer
      if (holdTimerRef.current) {
        clearTimeout(holdTimerRef.current);
        holdTimerRef.current = null;
      }

      if (regionDragType !== 'none' && regionDragIndex !== null && dragStartTime !== null && dragCurrentTime !== null) {
        const delta = dragCurrentTime - dragStartTime;
        const wasDragging = Math.abs(delta) > 0.05; // More than 50ms movement

        // Don't commit if cancelled
        if (isCancelled) {
          // Just end drag without committing
          endDrag();
          setDragStartY(null);
          setIsCancelled(false);
          (e.target as HTMLElement).releasePointerCapture(e.pointerId);
          return;
        }

        if (wasDragging) {
          // Get the region from baseDisplayRegions (original positions)
          const region = baseDisplayRegions[regionDragIndex];
          if (region) {
            // Convert display index to region index via _pendingKey
            const regionIndex = (region as { _pendingKey?: number })._pendingKey ?? regionDragIndex;

            if (regionDragType === 'resize-start') {
              resizeRegion(regionIndex, 'start', dragCurrentTime, regions, bpm);
            } else if (regionDragType === 'resize-end') {
              resizeRegion(regionIndex, 'end', dragCurrentTime, regions, bpm);
            } else if (regionDragType === 'move') {
              // Convert display indices to region indices
              const displayIndicesToMove = selectedRegionIndices.length > 0
                ? selectedRegionIndices
                : [regionDragIndex];

              const regionIndicesToMove = displayIndicesToMove.map(displayIdx => {
                const r = baseDisplayRegions[displayIdx] as { _pendingKey?: number };
                return r._pendingKey ?? displayIdx;
              });

              // Move region(s)
              moveRegion(regionIndicesToMove, delta, regions);

              // After move, find new display indices and update selection
              setTimeout(() => {
                const updatedDisplayRegions = getDisplayRegions(regions);
                const newDisplayIndices = regionIndicesToMove
                  .map(regIdx => {
                    return updatedDisplayRegions.findIndex(
                      r => (r as { _pendingKey?: number })._pendingKey === regIdx
                    );
                  })
                  .filter(idx => idx !== -1);

                // Update selection to the new display indices
                if (newDisplayIndices.length > 0) {
                  clearSelection();
                  newDisplayIndices.forEach(idx => selectRegion(idx));
                }
              }, 0);
            }
          }
        } else {
          // Was just a tap - toggle selection only if it was already selected before tap started
          if (wasSelectedOnTapStartRef.current) {
            deselectRegion(regionDragIndex);
          }
        }
      }

      endDrag();
      setDragStartY(null);
      setIsCancelled(false);
      (e.target as HTMLElement).releasePointerCapture(e.pointerId);
    },
    [
      regionDragType,
      regionDragIndex,
      dragStartTime,
      dragCurrentTime,
      isCancelled,
      baseDisplayRegions,
      selectedRegionIndices,
      regions,
      bpm,
      resizeRegion,
      moveRegion,
      getDisplayRegions,
      clearSelection,
      selectRegion,
      deselectRegion,
      endDrag,
    ]
  );

  return {
    handlePointerDown,
    handlePointerMove,
    handlePointerUp,
    isCancelled,
    findRegionIndexAtPosition,
    detectDragType,
  };
}
