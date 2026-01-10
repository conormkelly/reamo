/**
 * usePanGesture Hook
 * Manages viewport pan gesture for timeline navigation
 * Follows patterns from usePlayheadDrag and useRegionDrag
 */

import { useState, useCallback, useRef, type RefObject } from 'react';

/** Vertical distance to cancel pan gesture (pixels) - matches other drag hooks */
const VERTICAL_CANCEL_THRESHOLD = 50;

export interface UsePanGestureOptions {
  /** Ref to the timeline container element */
  containerRef: RefObject<HTMLDivElement | null>;
  /** Current visible duration in seconds */
  visibleDuration: number;
  /** Callback when viewport should pan (delta in seconds) */
  onPan: (deltaSeconds: number) => void;
  /** Whether pan gesture is disabled */
  disabled?: boolean;
}

export interface UsePanGestureResult {
  /** Whether a pan gesture is in progress */
  isPanning: boolean;
  /** Whether the current gesture is cancelled (vertical drag off) */
  isCancelled: boolean;
  /** Handler for pointer down to start pan */
  handlePointerDown: (e: React.PointerEvent) => void;
  /** Handler for pointer move during pan */
  handlePointerMove: (e: React.PointerEvent) => void;
  /** Handler for pointer up to complete pan */
  handlePointerUp: (e: React.PointerEvent) => void;
}

export function usePanGesture({
  containerRef,
  visibleDuration,
  onPan,
  disabled = false,
}: UsePanGestureOptions): UsePanGestureResult {
  const [isPanning, setIsPanning] = useState(false);
  const [isCancelled, setIsCancelled] = useState(false);

  // Use refs for values that change during gesture but shouldn't trigger re-renders
  const dragStartYRef = useRef<number | null>(null);
  const lastClientXRef = useRef<number | null>(null);

  const handlePointerDown = useCallback(
    (e: React.PointerEvent) => {
      if (disabled || !containerRef.current) return;

      // Capture pointer for tracking outside element
      (e.target as HTMLElement).setPointerCapture(e.pointerId);

      dragStartYRef.current = e.clientY;
      lastClientXRef.current = e.clientX;
      setIsPanning(true);
      setIsCancelled(false);
    },
    [disabled, containerRef]
  );

  const handlePointerMove = useCallback(
    (e: React.PointerEvent) => {
      if (!isPanning || !containerRef.current) return;
      if (dragStartYRef.current === null || lastClientXRef.current === null) return;

      const rect = containerRef.current.getBoundingClientRect();

      // Check vertical cancel condition
      const deltaY = Math.abs(e.clientY - dragStartYRef.current);
      const isOutsideVertically =
        e.clientY < rect.top - VERTICAL_CANCEL_THRESHOLD ||
        e.clientY > rect.bottom + VERTICAL_CANCEL_THRESHOLD;

      if (isOutsideVertically || deltaY > VERTICAL_CANCEL_THRESHOLD) {
        // Mark as cancelled - stop panning but keep tracking for potential recovery
        setIsCancelled(true);
        return;
      }

      // Clear cancelled state if user returns to valid area
      if (isCancelled) {
        setIsCancelled(false);
      }

      // Calculate pan delta
      const deltaX = e.clientX - lastClientXRef.current;
      lastClientXRef.current = e.clientX;

      if (deltaX === 0) return;

      // Convert pixel delta to time delta
      // Negative because dragging right = moving backward in time (earlier content comes into view)
      const timeDelta = -(deltaX / rect.width) * visibleDuration;

      onPan(timeDelta);
    },
    [isPanning, isCancelled, containerRef, visibleDuration, onPan]
  );

  const handlePointerUp = useCallback(
    (e: React.PointerEvent) => {
      if (!isPanning) return;

      // Release pointer capture
      try {
        (e.target as HTMLElement).releasePointerCapture(e.pointerId);
      } catch {
        // Already released
      }

      // Reset state
      dragStartYRef.current = null;
      lastClientXRef.current = null;
      setIsPanning(false);
      setIsCancelled(false);
    },
    [isPanning]
  );

  return {
    isPanning,
    isCancelled,
    handlePointerDown,
    handlePointerMove,
    handlePointerUp,
  };
}
