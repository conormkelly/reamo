/**
 * useRegionDrag Hook
 * Manages region drag interactions (move + resize) with vertical-cancel behavior
 *
 * Vertical-cancel: When the user drags their finger/pointer too far up or down
 * from the start position, the drag is cancelled and the region returns to its
 * original position. This matches the behavior of usePlayheadDrag and useMarkerDrag.
 *
 * KEY DESIGN: All region references use region.id (REAPER's markrgnidx),
 * NOT array indices. This ensures stability when server pushes updates.
 */

import { useState, useRef, useCallback, useEffect, type RefObject } from 'react';
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
  /** Time signature denominator (4 = quarter, 8 = eighth). Default: 4 */
  denominator?: number;
  /** Display regions (with pending changes, used for rendering) */
  displayRegions: Region[];
  /** Base display regions (original positions, used for snap calculations) */
  baseDisplayRegions: Region[];
  /** Currently selected region IDs */
  selectedRegionIds: number[];
  /** Original regions from REAPER */
  regions: Region[];
  /** Convert time to percentage */
  timeToPercent: (time: number) => number;
  /** Convert clientX to time */
  positionToTime: (clientX: number) => number;

  // Store state
  regionDragType: DragType;
  regionDragId: number | null;
  dragStartTime: number | null;
  dragCurrentTime: number | null;

  // Store actions (all use region ID, not array index)
  isRegionSelected: (id: number) => boolean;
  selectRegion: (id: number) => void;
  deselectRegion: (id: number) => void;
  clearSelection: () => void;
  startDrag: (type: DragType, id: number, x: number, time: number) => void;
  updateDrag: (x: number, time: number) => void;
  endDrag: () => void;
  cancelDrag: () => void;
  resizeRegion: (id: number, edge: 'start' | 'end', newTime: number, regions: Region[], bpm: number | null) => void;
  moveRegion: (ids: number[], delta: number, regions: Region[]) => void;

  // Callbacks
  onEditRegion?: (region: Region) => void;
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
  /** Find region at a given clientX position, returns region or null */
  findRegionAtPosition: (clientX: number) => Region | null;
  /** Determine drag type based on click position within a region */
  detectDragType: (clientX: number, region: Region) => DragType;
}

export function useRegionDrag({
  containerRef,
  timelineStart: _timelineStart,
  duration: _duration,
  bpm,
  denominator = 4,
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
  onEditRegion,
}: UseRegionDragOptions): UseRegionDragResult {
  // Local state for vertical-cancel
  const [dragStartY, setDragStartY] = useState<number | null>(null);
  const [isCancelled, setIsCancelled] = useState(false);

  // Track if region was already selected when tap started (for toggle behavior)
  const wasSelectedOnTapStartRef = useRef<boolean>(false);

  // Long-press timer for edit modal
  const holdTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Cleanup hold timer on unmount to prevent state updates after unmount
  useEffect(() => {
    return () => {
      if (holdTimerRef.current) {
        clearTimeout(holdTimerRef.current);
      }
    };
  }, []);

  // Find region at position (returns the region itself, not an index)
  const findRegionAtPosition = useCallback(
    (clientX: number): Region | null => {
      if (!containerRef.current) return null;
      const time = positionToTime(clientX);

      for (const region of displayRegions) {
        if (time >= region.start && time < region.end) {
          return region;
        }
      }
      return null;
    },
    [displayRegions, positionToTime, containerRef]
  );

  // Determine drag type based on click position
  const detectDragType = useCallback(
    (clientX: number, region: Region): DragType => {
      if (!containerRef.current) return 'move';

      const rect = containerRef.current.getBoundingClientRect();

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
    [timeToPercent, containerRef]
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
      const region = findRegionAtPosition(e.clientX);

      if (region !== null) {
        const regionId = region.id;
        const wasSelected = isRegionSelected(regionId);
        const dragType = detectDragType(e.clientX, region);

        // Track selection state at tap start for toggle behavior in pointerUp
        wasSelectedOnTapStartRef.current = wasSelected;

        // If already selected and tapped again, start long-press timer for edit modal
        if (wasSelected && selectedRegionIds.length === 1) {
          holdTimerRef.current = setTimeout(() => {
            if (onEditRegion) {
              onEditRegion(region);
            }
            // Cancel any drag
            cancelDrag();
            setDragStartY(null);
            setIsCancelled(false);
          }, REGION_HOLD_THRESHOLD);
        }

        // Start drag operation with region ID
        startDrag(dragType, regionId, e.clientX, time);
        setDragStartY(e.clientY);
        setIsCancelled(false);

        // Select the region if not already selected
        if (!wasSelected) {
          selectRegion(regionId);
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
      findRegionAtPosition,
      isRegionSelected,
      detectDragType,
      selectedRegionIds,
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

      if (regionDragType === 'none' || regionDragId === null) return;

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
        const idsToMove = selectedRegionIds.length > 0
          ? selectedRegionIds
          : [regionDragId];

        // Use baseDisplayRegions (positions BEFORE the drag), not displayRegions (preview)
        const primaryRegion = baseDisplayRegions.find(r => r.id === regionDragId);
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
          baseDisplayRegions.forEach((region) => {
            if (!idsToMove.includes(region.id)) {
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

      // For resize operations, snap to beat grid based on time signature denominator
      const snappedTime = bpm ? snapToGrid(time, bpm, denominator / 4) : time;
      updateDrag(e.clientX, snappedTime);
    },
    [
      positionToTime,
      regionDragType,
      regionDragId,
      dragStartTime,
      isVerticalCancelActive,
      updateDrag,
      selectedRegionIds,
      baseDisplayRegions,
      bpm,
      denominator,
    ]
  );

  const handlePointerUp = useCallback(
    (e: React.PointerEvent) => {
      // Clear hold timer
      if (holdTimerRef.current) {
        clearTimeout(holdTimerRef.current);
        holdTimerRef.current = null;
      }

      if (regionDragType !== 'none' && regionDragId !== null && dragStartTime !== null && dragCurrentTime !== null) {
        const delta = dragCurrentTime - dragStartTime;
        const wasDragging = Math.abs(delta) > 0.05; // More than 50ms movement

        // Don't commit if cancelled
        if (isCancelled) {
          // Just end drag without committing
          endDrag();
          setDragStartY(null);
          setIsCancelled(false);
          // Release pointer capture (may already be released on pointercancel)
          try {
            (e.target as HTMLElement).releasePointerCapture(e.pointerId);
          } catch {
            // Pointer capture already released
          }
          return;
        }

        if (wasDragging) {
          // regionDragId IS the region ID we need
          if (regionDragType === 'resize-start') {
            resizeRegion(regionDragId, 'start', dragCurrentTime, regions, bpm);
          } else if (regionDragType === 'resize-end') {
            resizeRegion(regionDragId, 'end', dragCurrentTime, regions, bpm);
          } else if (regionDragType === 'move') {
            // selectedRegionIds ARE the IDs we need
            const idsToMove = selectedRegionIds.length > 0
              ? selectedRegionIds
              : [regionDragId];

            // Move region(s) - selection is cleared since display order may change after reordering
            moveRegion(idsToMove, delta, regions);
            clearSelection();
          }
        } else {
          // Was just a tap - toggle selection only if it was already selected before tap started
          if (wasSelectedOnTapStartRef.current) {
            deselectRegion(regionDragId);
          }
        }
      }

      endDrag();
      setDragStartY(null);
      setIsCancelled(false);
      // Release pointer capture (may already be released on pointercancel)
      try {
        (e.target as HTMLElement).releasePointerCapture(e.pointerId);
      } catch {
        // Pointer capture already released
      }
    },
    [
      regionDragType,
      regionDragId,
      dragStartTime,
      dragCurrentTime,
      isCancelled,
      selectedRegionIds,
      regions,
      bpm,
      resizeRegion,
      moveRegion,
      clearSelection,
      deselectRegion,
      endDrag,
    ]
  );

  return {
    handlePointerDown,
    handlePointerMove,
    handlePointerUp,
    isCancelled,
    findRegionAtPosition,
    detectDragType,
  };
}
