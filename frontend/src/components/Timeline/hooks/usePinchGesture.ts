/**
 * usePinchGesture Hook
 * Handles two-finger pinch-to-zoom gesture for timeline viewport.
 *
 * Features:
 * - Continuous zoom (not discrete steps)
 * - Zoom centered on pinch midpoint
 * - Works alongside pan gesture (pinch takes priority)
 * - Min/max zoom limits (1s min for precision editing, project duration max)
 *
 * @example
 * ```tsx
 * function Timeline() {
 *   const containerRef = useRef<HTMLDivElement>(null);
 *   const [visibleRange, setVisibleRange] = useState({ start: 0, end: 30 });
 *
 *   const pinch = usePinchGesture({
 *     containerRef,
 *     visibleRange,
 *     setVisibleRange,
 *     projectDuration: 120,
 *   });
 *
 *   // Use the hook's isPinchingRef directly - no local copy needed!
 *
 *   const handlePointerDown = (e: React.PointerEvent) => {
 *     const pinchStarted = pinch.handlePointerDown(e);
 *     if (pinchStarted) {
 *       return; // Pinch takes priority over other gestures
 *     }
 *     // ... handle other gestures (pan, tap, etc.)
 *   };
 *
 *   const handlePointerMove = (e: React.PointerEvent) => {
 *     pinch.handlePointerMove(e); // Always update pinch state
 *     if (pinch.isPinchingRef.current) return; // Skip other gestures while pinching
 *     // ... handle other gestures
 *   };
 *
 *   const handlePointerUp = (e: React.PointerEvent) => {
 *     pinch.handlePointerUp(e);
 *     // isPinchingRef.current is now updated - check directly
 *     if (pinch.isPinchingRef.current) return; // Still pinching (2+ fingers)
 *     // ... handle other gestures
 *   };
 *
 *   return (
 *     <div
 *       ref={containerRef}
 *       onPointerDown={handlePointerDown}
 *       onPointerMove={handlePointerMove}
 *       onPointerUp={handlePointerUp}
 *     />
 *   );
 * }
 * ```
 */

import { useCallback, useRef, useState, type RefObject } from 'react';
import type { TimeRange } from '../../../hooks/useViewport';

/** Minimum visible duration (1 second - precision editing) */
const MIN_DURATION = 1;

/** Minimum distance between fingers to consider a pinch (pixels) */
const MIN_PINCH_DISTANCE = 10;

interface ActivePointer {
  id: number;
  clientX: number;
  clientY: number;
}

export interface UsePinchGestureOptions {
  /** Ref to the timeline container element */
  containerRef: RefObject<HTMLDivElement | null>;
  /** Current visible range */
  visibleRange: TimeRange;
  /** Callback to set new visible range */
  setVisibleRange: (range: TimeRange) => void;
  /** Project duration for clamping */
  projectDuration: number;
  /** Whether pinch gesture is disabled */
  disabled?: boolean;
}

export interface UsePinchGestureResult {
  /** Ref to whether a pinch gesture is in progress (read .current for real-time value) */
  isPinchingRef: React.RefObject<boolean>;
  /** State-based pinch indicator (triggers re-renders, use for conditional rendering) */
  isPinching: boolean;
  /** Call on pointer down - returns true if pinch started */
  handlePointerDown: (e: React.PointerEvent) => boolean;
  /** Call on pointer move */
  handlePointerMove: (e: React.PointerEvent) => void;
  /** Call on pointer up/cancel */
  handlePointerUp: (e: React.PointerEvent) => void;
}

/**
 * Calculate distance between two points
 */
function getDistance(p1: ActivePointer, p2: ActivePointer): number {
  const dx = p2.clientX - p1.clientX;
  const dy = p2.clientY - p1.clientY;
  return Math.sqrt(dx * dx + dy * dy);
}

/**
 * Calculate midpoint between two points (in client coords)
 */
function getMidpoint(p1: ActivePointer, p2: ActivePointer): { x: number; y: number } {
  return {
    x: (p1.clientX + p2.clientX) / 2,
    y: (p1.clientY + p2.clientY) / 2,
  };
}

export function usePinchGesture({
  containerRef,
  visibleRange,
  setVisibleRange,
  projectDuration,
  disabled = false,
}: UsePinchGestureOptions): UsePinchGestureResult {
  // Track active pointers (up to 2)
  const pointersRef = useRef<Map<number, ActivePointer>>(new Map());

  // Track initial pinch state
  const initialDistanceRef = useRef<number | null>(null);
  const initialDurationRef = useRef<number | null>(null);
  const initialCenterTimeRef = useRef<number | null>(null);

  // Track if we're currently pinching (ref for real-time access, state for re-renders)
  const isPinchingRef = useRef(false);
  const [isPinching, setIsPinching] = useState(false);

  // Convert client X to time
  const clientXToTime = useCallback(
    (clientX: number): number => {
      if (!containerRef.current) return visibleRange.start;
      const rect = containerRef.current.getBoundingClientRect();
      const percent = (clientX - rect.left) / rect.width;
      return visibleRange.start + percent * (visibleRange.end - visibleRange.start);
    },
    [containerRef, visibleRange]
  );

  const handlePointerDown = useCallback(
    (e: React.PointerEvent): boolean => {
      if (disabled) return false;

      const pointers = pointersRef.current;

      // Add this pointer
      pointers.set(e.pointerId, {
        id: e.pointerId,
        clientX: e.clientX,
        clientY: e.clientY,
      });

      // If we now have 2 pointers, start pinch
      if (pointers.size === 2) {
        const [p1, p2] = Array.from(pointers.values());
        const distance = getDistance(p1, p2);

        if (distance >= MIN_PINCH_DISTANCE) {
          initialDistanceRef.current = distance;
          initialDurationRef.current = visibleRange.end - visibleRange.start;

          // Calculate center time (the time at the pinch midpoint)
          const midpoint = getMidpoint(p1, p2);
          initialCenterTimeRef.current = clientXToTime(midpoint.x);

          isPinchingRef.current = true;
          setIsPinching(true);
          return true; // Pinch started
        }
      }

      return false;
    },
    [disabled, visibleRange, clientXToTime]
  );

  const handlePointerMove = useCallback(
    (e: React.PointerEvent) => {
      const pointers = pointersRef.current;

      // Update pointer position
      if (pointers.has(e.pointerId)) {
        pointers.set(e.pointerId, {
          id: e.pointerId,
          clientX: e.clientX,
          clientY: e.clientY,
        });
      }

      // Only process if we're pinching with 2 pointers
      if (!isPinchingRef.current || pointers.size !== 2) return;
      if (
        initialDistanceRef.current === null ||
        initialDurationRef.current === null ||
        initialCenterTimeRef.current === null
      )
        return;

      const [p1, p2] = Array.from(pointers.values());
      const currentDistance = getDistance(p1, p2);

      if (currentDistance < MIN_PINCH_DISTANCE) return;

      // Calculate scale factor (distance ratio)
      // Larger distance = zoomed in (smaller duration)
      const scale = initialDistanceRef.current / currentDistance;

      // Calculate new duration
      let newDuration = initialDurationRef.current * scale;

      // Clamp duration (min 5s, max = project duration so you can always zoom to see everything)
      newDuration = Math.max(MIN_DURATION, Math.min(projectDuration, newDuration));

      // Calculate new range centered on the initial pinch midpoint
      // The time at initialCenterTimeRef should stay at the same screen position
      const midpoint = getMidpoint(p1, p2);
      if (!containerRef.current) return;

      const rect = containerRef.current.getBoundingClientRect();
      const centerPercent = (midpoint.x - rect.left) / rect.width;

      // The center time should be at centerPercent of the new range
      const newStart = initialCenterTimeRef.current - centerPercent * newDuration;
      const newEnd = newStart + newDuration;

      // Clamp to project bounds
      let clampedStart = newStart;
      let clampedEnd = newEnd;

      if (clampedStart < 0) {
        clampedStart = 0;
        clampedEnd = newDuration;
      }
      if (clampedEnd > projectDuration) {
        clampedEnd = projectDuration;
        clampedStart = Math.max(0, projectDuration - newDuration);
      }

      setVisibleRange({ start: clampedStart, end: clampedEnd });
    },
    [containerRef, projectDuration, setVisibleRange]
  );

  const handlePointerUp = useCallback((e: React.PointerEvent) => {
    const pointers = pointersRef.current;

    // Remove this pointer
    pointers.delete(e.pointerId);

    // If we were pinching and now have < 2 pointers, end pinch
    if (isPinchingRef.current && pointers.size < 2) {
      isPinchingRef.current = false;
      setIsPinching(false);
      initialDistanceRef.current = null;
      initialDurationRef.current = null;
      initialCenterTimeRef.current = null;
    }
  }, []);

  return {
    isPinchingRef,
    isPinching,
    handlePointerDown,
    handlePointerMove,
    handlePointerUp,
  };
}
