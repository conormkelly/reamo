/**
 * useTimelinePointerEvents — Gesture routing for the timeline canvas
 *
 * Extracts handlePointerDown, handlePointerMove, handlePointerUp and their
 * shared state (dragStart, dragEnd, isCancelled, panStartPositionRef) from
 * Timeline.tsx. Also includes the selectionPreview memo.
 *
 * Phase 4 of the Timeline.tsx decomposition (see TIMELINE_REFACTOR.md).
 */

import { useState, useRef, useCallback, useMemo, type RefObject } from 'react';
import type { UsePanGestureResult } from './usePanGesture';
import type { UsePinchGestureResult } from './usePinchGesture';
import type { TimelineMode } from '../../../store/slices/regionEditSlice.types';

// Vertical distance to cancel gesture (drag off timeline)
const VERTICAL_CANCEL_THRESHOLD = 50;

// Tap detection threshold (pixels) - movement less than this is considered a tap
const TAP_THRESHOLD = 10;

export interface UseTimelinePointerEventsParams {
  containerRef: RefObject<HTMLDivElement | null>;
  timelineMode: TimelineMode;
  selectionModeActive: boolean;
  panGesture: UsePanGestureResult;
  pinchGesture: UsePinchGestureResult;
  isDraggingPlayhead: boolean;
  handleRegionPointerDown: (e: React.PointerEvent) => void;
  handleRegionPointerMove: (e: React.PointerEvent) => void;
  handleRegionPointerUp: (e: React.PointerEvent) => void;
  handleItemTap: (clientX: number, clientY: number) => boolean;
  positionToTime: (clientX: number) => number;
  followPlayhead: boolean;
  pauseFollow: () => void;
  setTimeSelection: (start: number, end: number) => void;
  navigateTo: (time: number) => void;
  findNearestBoundary: (time: number) => number;
}

export interface UseTimelinePointerEventsReturn {
  handlePointerDown: (e: React.PointerEvent) => void;
  handlePointerMove: (e: React.PointerEvent) => void;
  handlePointerUp: (e: React.PointerEvent) => void;
  selectionPreview: { start: number; end: number } | null;
}

export function useTimelinePointerEvents({
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
}: UseTimelinePointerEventsParams): UseTimelinePointerEventsReturn {
  // Gesture state (navigate mode)
  // Simplified: tap = seek, horizontal drag = select, vertical drag off = cancel
  const [dragStart, setDragStart] = useState<number | null>(null);
  const [dragEnd, setDragEnd] = useState<number | null>(null);
  const [isCancelled, setIsCancelled] = useState(false);

  // Track pan gesture start position for tap detection
  const panStartPositionRef = useRef<{ x: number; y: number } | null>(null);

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
    [dragStart, positionToTime, timelineMode, handleRegionPointerMove, selectionModeActive, panGesture, pinchGesture, containerRef]
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
          if (panStartPositionRef.current) {
            const dx = Math.abs(e.clientX - panStartPositionRef.current.x);
            const dy = Math.abs(e.clientY - panStartPositionRef.current.y);

            if (dx < TAP_THRESHOLD && dy < TAP_THRESHOLD) {
              handleItemTap(e.clientX, e.clientY);
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
      handleItemTap,
      containerRef,
    ]
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

  return {
    handlePointerDown,
    handlePointerMove,
    handlePointerUp,
    selectionPreview,
  };
}
