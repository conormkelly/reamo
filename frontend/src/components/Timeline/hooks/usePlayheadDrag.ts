/**
 * usePlayheadDrag Hook
 * Manages playhead drag interactions with vertical-cancel behavior
 */

import { useState, useCallback, type RefObject } from 'react';
import { snapToGrid } from '../../../utils';

/** Vertical distance to cancel playhead drag (pixels) */
const VERTICAL_CANCEL_THRESHOLD = 50;

export interface UsePlayheadDragOptions {
  /** Ref to the timeline container element */
  containerRef: RefObject<HTMLDivElement | null>;
  /** Current playhead position as percentage (0-100) - viewport-relative */
  playheadPercent: number;
  /** Current playhead position in seconds */
  playheadTime: number;
  /** Viewport visible range start in seconds */
  viewportStart: number;
  /** Viewport visible range end in seconds */
  viewportEnd: number;
  /** BPM for grid snapping (null disables snapping) */
  bpm: number | null;
  /** Convert time to percentage position (viewport-relative) */
  timeToPercent: (time: number) => number;
  /** Callback when drag completes successfully */
  onSeek: (seconds: number) => void;
}

export interface UsePlayheadDragResult {
  /** Whether a playhead drag is in progress */
  isDragging: boolean;
  /** Preview position as percentage (null when not dragging) */
  previewPercent: number | null;
  /** Preview time in seconds (null when not dragging) - use this for display to avoid precision loss */
  previewTime: number | null;
  /** Handler for pointer down on playhead */
  handlePointerDown: (e: React.PointerEvent) => void;
  /** Handler for pointer move during drag */
  handlePointerMove: (e: React.PointerEvent) => void;
  /** Handler for pointer up to complete drag */
  handlePointerUp: (e: React.PointerEvent) => void;
}

export function usePlayheadDrag({
  containerRef,
  playheadPercent,
  playheadTime,
  viewportStart,
  viewportEnd,
  bpm,
  timeToPercent,
  onSeek,
}: UsePlayheadDragOptions): UsePlayheadDragResult {
  const [isDragging, setIsDragging] = useState(false);
  const [dragStartY, setDragStartY] = useState<number | null>(null);
  const [previewPercent, setPreviewPercent] = useState<number | null>(null);
  const [previewTime, setPreviewTime] = useState<number | null>(null);

  // Calculate viewport duration for position calculations
  const viewportDuration = viewportEnd - viewportStart;

  const handlePointerDown = useCallback(
    (e: React.PointerEvent) => {
      e.stopPropagation();
      (e.target as HTMLElement).setPointerCapture(e.pointerId);

      setIsDragging(true);
      setDragStartY(e.clientY);
      setPreviewPercent(playheadPercent);
      setPreviewTime(playheadTime);
    },
    [playheadPercent, playheadTime]
  );

  const handlePointerMove = useCallback(
    (e: React.PointerEvent) => {
      if (!isDragging || !containerRef.current) return;

      const rect = containerRef.current.getBoundingClientRect();
      const deltaY = dragStartY !== null ? Math.abs(e.clientY - dragStartY) : 0;
      const isOutsideVertically =
        e.clientY < rect.top - VERTICAL_CANCEL_THRESHOLD ||
        e.clientY > rect.bottom + VERTICAL_CANCEL_THRESHOLD;

      if (isOutsideVertically || deltaY > VERTICAL_CANCEL_THRESHOLD) {
        // Show cancel state - preview snaps back to current playhead
        setPreviewPercent(playheadPercent);
        setPreviewTime(playheadTime);
        return;
      }

      // Calculate time from drag position using VIEWPORT coordinates
      const rawPercent = ((e.clientX - rect.left) / rect.width) * 100;
      const rawTime = viewportStart + (rawPercent / 100) * viewportDuration;

      // Snap to grid (bar boundaries) if we have BPM
      const snappedTime = bpm ? snapToGrid(rawTime, bpm, 4) : rawTime;
      const snappedPercent = timeToPercent(snappedTime);

      setPreviewPercent(Math.max(0, Math.min(100, snappedPercent)));
      setPreviewTime(snappedTime);
    },
    [isDragging, dragStartY, playheadPercent, playheadTime, containerRef, viewportStart, viewportDuration, bpm, timeToPercent]
  );

  const handlePointerUp = useCallback(
    (e: React.PointerEvent) => {
      if (!isDragging || !containerRef.current) return;

      // Release pointer capture (may already be released on pointercancel)
      try {
        (e.target as HTMLElement).releasePointerCapture(e.pointerId);
      } catch {
        // Pointer capture already released
      }

      const rect = containerRef.current.getBoundingClientRect();
      const deltaY = dragStartY !== null ? Math.abs(e.clientY - dragStartY) : 0;
      const isOutsideVertically =
        e.clientY < rect.top - VERTICAL_CANCEL_THRESHOLD ||
        e.clientY > rect.bottom + VERTICAL_CANCEL_THRESHOLD;

      // Only commit if not cancelled
      if (
        !isOutsideVertically &&
        deltaY <= VERTICAL_CANCEL_THRESHOLD &&
        previewTime !== null
      ) {
        onSeek(previewTime);
      }

      // Reset state
      setIsDragging(false);
      setDragStartY(null);
      setPreviewPercent(null);
      setPreviewTime(null);
    },
    [isDragging, dragStartY, previewTime, onSeek, containerRef]
  );

  return {
    isDragging,
    previewPercent,
    previewTime,
    handlePointerDown,
    handlePointerMove,
    handlePointerUp,
  };
}
