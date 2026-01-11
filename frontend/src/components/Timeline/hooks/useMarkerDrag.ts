/**
 * useMarkerDrag Hook
 * Manages marker drag and long-press interactions
 */

import { useState, useCallback, useEffect, useRef, type RefObject } from 'react';
import type { Marker } from '../../../core/types';
import { snapToGrid } from '../../../utils';

/** Long-press threshold for marker edit modal (ms) */
const MARKER_HOLD_THRESHOLD = 500;
/** Vertical distance to cancel drag (pixels) */
const VERTICAL_CANCEL_THRESHOLD = 50;

export interface UseMarkerDragOptions {
  /** Ref to the timeline container element */
  containerRef: RefObject<HTMLDivElement | null>;
  /** Viewport visible range start in seconds */
  viewportStart: number;
  /** Viewport visible range end in seconds */
  viewportEnd: number;
  /** Beats per minute (for grid snapping) */
  bpm: number | null;
  /** Convert time to percentage position (viewport-relative) */
  timeToPercent: (time: number) => number;
  /** Callback when long-press triggers edit modal */
  onEdit: (marker: Marker) => void;
  /** Callback when drag completes - receives marker ID and new position */
  onMove: (markerId: number, newPositionSeconds: number) => void;
  /** Callback when marker is tapped/selected (not dragged or long-pressed) */
  onSelect?: (markerId: number) => void;
}

export interface UseMarkerDragResult {
  /** Whether a marker drag is in progress */
  isDragging: boolean;
  /** The marker currently being dragged (null when not dragging) */
  draggedMarker: Marker | null;
  /** Preview position as percentage (null when not dragging) */
  previewPercent: number | null;
  /** Preview position as time in seconds (null when not dragging) */
  previewTime: number | null;
  /** Handler for pointer down on a marker */
  handlePointerDown: (e: React.PointerEvent, marker: Marker) => void;
  /** Handler for pointer move during drag */
  handlePointerMove: (e: React.PointerEvent) => void;
  /** Handler for pointer up to complete drag */
  handlePointerUp: (e: React.PointerEvent) => void;
}

export function useMarkerDrag({
  containerRef,
  viewportStart,
  viewportEnd,
  bpm,
  timeToPercent,
  onEdit,
  onMove,
  onSelect,
}: UseMarkerDragOptions): UseMarkerDragResult {
  const [isDragging, setIsDragging] = useState(false);
  const [draggedMarker, setDraggedMarker] = useState<Marker | null>(null);
  const [dragStartY, setDragStartY] = useState<number | null>(null);
  const [previewPercent, setPreviewPercent] = useState<number | null>(null);
  const [previewTime, setPreviewTime] = useState<number | null>(null);
  const holdTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Calculate viewport duration for position calculations
  const viewportDuration = viewportEnd - viewportStart;

  const handlePointerDown = useCallback(
    (e: React.PointerEvent, marker: Marker) => {
      e.stopPropagation();
      (e.target as HTMLElement).setPointerCapture(e.pointerId);

      setDraggedMarker(marker);
      setDragStartY(e.clientY);
      setPreviewPercent(timeToPercent(marker.position));
      setPreviewTime(marker.position);

      // Start long-press timer for edit modal
      holdTimerRef.current = setTimeout(() => {
        // Long press detected - open edit modal
        onEdit(marker);
        // Cancel any drag
        setIsDragging(false);
        setDraggedMarker(null);
        setDragStartY(null);
        setPreviewPercent(null);
        setPreviewTime(null);
      }, MARKER_HOLD_THRESHOLD);
    },
    [timeToPercent, onEdit]
  );

  const handlePointerMove = useCallback(
    (e: React.PointerEvent) => {
      if (!draggedMarker || !containerRef.current) return;

      // If moved significantly, we're dragging (cancel long-press timer)
      const rect = containerRef.current.getBoundingClientRect();
      const markerX = rect.left + (timeToPercent(draggedMarker.position) / 100) * rect.width;
      const movedSignificantly = Math.abs(e.clientX - markerX) > 5;

      if (movedSignificantly && holdTimerRef.current) {
        clearTimeout(holdTimerRef.current);
        holdTimerRef.current = null;
        setIsDragging(true);
      }

      if (!isDragging) return;

      const deltaY = dragStartY !== null ? Math.abs(e.clientY - dragStartY) : 0;
      const isOutsideVertically =
        e.clientY < rect.top - VERTICAL_CANCEL_THRESHOLD ||
        e.clientY > rect.bottom + VERTICAL_CANCEL_THRESHOLD;

      if (isOutsideVertically || deltaY > VERTICAL_CANCEL_THRESHOLD) {
        // Cancel - snap back to original position
        setPreviewPercent(timeToPercent(draggedMarker.position));
        return;
      }

      // Calculate time from drag position using VIEWPORT coordinates
      const rawPercent = ((e.clientX - rect.left) / rect.width) * 100;
      const rawTime = viewportStart + (rawPercent / 100) * viewportDuration;

      // Snap to grid (bar boundaries) if we have BPM
      // Note: This uses a single BPM - for tempo-aware snapping, use tempo/snap command
      const snappedTime = bpm ? snapToGrid(rawTime, bpm, 4) : rawTime;
      const snappedPercent = timeToPercent(snappedTime);

      setPreviewPercent(Math.max(0, Math.min(100, snappedPercent)));
      setPreviewTime(snappedTime);
    },
    [draggedMarker, isDragging, dragStartY, timeToPercent, containerRef, viewportStart, viewportDuration, bpm]
  );

  const handlePointerUp = useCallback(
    (e: React.PointerEvent) => {
      // Clear long-press timer (if it fired, draggedMarker is already null)
      const longPressWasPending = holdTimerRef.current !== null;
      if (holdTimerRef.current) {
        clearTimeout(holdTimerRef.current);
        holdTimerRef.current = null;
      }

      if (!draggedMarker || !containerRef.current) {
        setDraggedMarker(null);
        setDragStartY(null);
        setPreviewPercent(null);
        setPreviewTime(null);
        setIsDragging(false);
        return;
      }

      // Release pointer capture (may already be released on pointercancel)
      try {
        (e.target as HTMLElement).releasePointerCapture(e.pointerId);
      } catch {
        // Pointer capture already released
      }

      // If not dragging and long-press timer was still pending, this is a tap - select the marker
      if (!isDragging && longPressWasPending && onSelect) {
        onSelect(draggedMarker.id);
      }

      // If we were dragging, commit the move
      if (isDragging && previewPercent !== null) {
        const rect = containerRef.current.getBoundingClientRect();
        const deltaY = dragStartY !== null ? Math.abs(e.clientY - dragStartY) : 0;
        const isOutsideVertically =
          e.clientY < rect.top - VERTICAL_CANCEL_THRESHOLD ||
          e.clientY > rect.bottom + VERTICAL_CANCEL_THRESHOLD;

        // Only commit if not cancelled - use viewport coordinates
        if (!isOutsideVertically && deltaY <= VERTICAL_CANCEL_THRESHOLD) {
          const newTime = viewportStart + (previewPercent / 100) * viewportDuration;
          onMove(draggedMarker.id, newTime);
        }
      }

      // Reset state
      setIsDragging(false);
      setDraggedMarker(null);
      setDragStartY(null);
      setPreviewPercent(null);
      setPreviewTime(null);
    },
    [draggedMarker, isDragging, dragStartY, previewPercent, viewportStart, viewportDuration, containerRef, onMove, onSelect]
  );

  // Cleanup timer on unmount
  useEffect(() => {
    return () => {
      if (holdTimerRef.current) {
        clearTimeout(holdTimerRef.current);
      }
    };
  }, []);

  return {
    isDragging,
    draggedMarker,
    previewPercent,
    previewTime,
    handlePointerDown,
    handlePointerMove,
    handlePointerUp,
  };
}
