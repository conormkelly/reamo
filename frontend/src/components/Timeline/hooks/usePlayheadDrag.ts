/**
 * usePlayheadDrag Hook
 * Manages playhead drag interactions with vertical-cancel behavior
 */

import { useState, useCallback, type RefObject } from 'react';

/** Vertical distance to cancel playhead drag (pixels) */
const VERTICAL_CANCEL_THRESHOLD = 50;

export interface UsePlayheadDragOptions {
  /** Ref to the timeline container element */
  containerRef: RefObject<HTMLDivElement | null>;
  /** Current playhead position as percentage (0-100) */
  playheadPercent: number;
  /** Timeline start time in seconds */
  timelineStart: number;
  /** Timeline duration in seconds */
  duration: number;
  /** Callback when drag completes successfully */
  onSeek: (seconds: number) => void;
}

export interface UsePlayheadDragResult {
  /** Whether a playhead drag is in progress */
  isDragging: boolean;
  /** Preview position as percentage (null when not dragging) */
  previewPercent: number | null;
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
  timelineStart,
  duration,
  onSeek,
}: UsePlayheadDragOptions): UsePlayheadDragResult {
  const [isDragging, setIsDragging] = useState(false);
  const [dragStartY, setDragStartY] = useState<number | null>(null);
  const [previewPercent, setPreviewPercent] = useState<number | null>(null);

  const handlePointerDown = useCallback(
    (e: React.PointerEvent) => {
      e.stopPropagation();
      (e.target as HTMLElement).setPointerCapture(e.pointerId);

      setIsDragging(true);
      setDragStartY(e.clientY);
      setPreviewPercent(playheadPercent);
    },
    [playheadPercent]
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
        return;
      }

      // Update preview position
      const percent = ((e.clientX - rect.left) / rect.width) * 100;
      setPreviewPercent(Math.max(0, Math.min(100, percent)));
    },
    [isDragging, dragStartY, playheadPercent, containerRef]
  );

  const handlePointerUp = useCallback(
    (e: React.PointerEvent) => {
      if (!isDragging || !containerRef.current) return;

      (e.target as HTMLElement).releasePointerCapture(e.pointerId);

      const rect = containerRef.current.getBoundingClientRect();
      const deltaY = dragStartY !== null ? Math.abs(e.clientY - dragStartY) : 0;
      const isOutsideVertically =
        e.clientY < rect.top - VERTICAL_CANCEL_THRESHOLD ||
        e.clientY > rect.bottom + VERTICAL_CANCEL_THRESHOLD;

      // Only commit if not cancelled
      if (
        !isOutsideVertically &&
        deltaY <= VERTICAL_CANCEL_THRESHOLD &&
        previewPercent !== null
      ) {
        const newTime = timelineStart + (previewPercent / 100) * duration;
        onSeek(newTime);
      }

      // Reset state
      setIsDragging(false);
      setDragStartY(null);
      setPreviewPercent(null);
    },
    [isDragging, dragStartY, previewPercent, timelineStart, duration, onSeek, containerRef]
  );

  return {
    isDragging,
    previewPercent,
    handlePointerDown,
    handlePointerMove,
    handlePointerUp,
  };
}
