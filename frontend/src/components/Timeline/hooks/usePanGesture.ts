/**
 * usePanGesture Hook
 * Manages viewport pan gesture for timeline navigation with momentum scrolling.
 *
 * Features:
 * - Velocity-based momentum after release
 * - Friction deceleration (0.965 per frame)
 * - Respects prefers-reduced-motion (instant stop)
 * - Vertical cancel threshold
 */

import { useState, useCallback, useRef, useEffect, type RefObject } from 'react';

/** Vertical distance to cancel pan gesture (pixels) - matches other drag hooks */
const VERTICAL_CANCEL_THRESHOLD = 50;

/** Friction coefficient per frame (60fps) - higher = more friction */
const FRICTION = 0.965;

/** Minimum velocity to continue momentum (seconds/frame) */
const VELOCITY_THRESHOLD = 0.0005;

/** Maximum velocity cap to prevent runaway scrolling (seconds/frame) */
const MAX_VELOCITY = 0.5;

/** Number of recent events to track for velocity calculation */
const VELOCITY_SAMPLE_COUNT = 5;

/** Maximum age of events to include in velocity calculation (ms) */
const VELOCITY_SAMPLE_WINDOW = 100;

/** Tracked pointer event for velocity calculation */
interface PointerSample {
  clientX: number;
  timestamp: number;
}

export interface UsePanGestureOptions {
  /** Ref to the timeline container element */
  containerRef: RefObject<HTMLDivElement | null>;
  /** Current visible duration in seconds */
  visibleDuration: number;
  /** Callback when viewport should pan (delta in seconds) */
  onPan: (deltaSeconds: number) => void;
  /** Whether pan gesture is disabled */
  disabled?: boolean;
  /** Whether to disable momentum (e.g., for reduced motion preference) */
  disableMomentum?: boolean;
}

export interface UsePanGestureResult {
  /** Whether a pan gesture is in progress */
  isPanning: boolean;
  /** Whether momentum animation is in progress */
  isMomentumActive: boolean;
  /** Whether the current gesture is cancelled (vertical drag off) */
  isCancelled: boolean;
  /** Handler for pointer down to start pan */
  handlePointerDown: (e: React.PointerEvent) => void;
  /** Handler for pointer move during pan */
  handlePointerMove: (e: React.PointerEvent) => void;
  /** Handler for pointer up to complete pan */
  handlePointerUp: (e: React.PointerEvent) => void;
  /** Stop any active momentum animation */
  stopMomentum: () => void;
}

export function usePanGesture({
  containerRef,
  visibleDuration,
  onPan,
  disabled = false,
  disableMomentum = false,
}: UsePanGestureOptions): UsePanGestureResult {
  const [isPanning, setIsPanning] = useState(false);
  const [isMomentumActive, setIsMomentumActive] = useState(false);
  const [isCancelled, setIsCancelled] = useState(false);

  // Use refs for values that change during gesture but shouldn't trigger re-renders
  const dragStartYRef = useRef<number | null>(null);
  const lastClientXRef = useRef<number | null>(null);

  // Velocity tracking
  const pointerSamplesRef = useRef<PointerSample[]>([]);
  const containerWidthRef = useRef<number>(0);

  // Momentum animation
  const rafIdRef = useRef<number | null>(null);
  const velocityRef = useRef<number>(0);

  // Refs to avoid stale closures in RAF loop
  const onPanRef = useRef(onPan);
  const disableMomentumRef = useRef(disableMomentum);

  useEffect(() => {
    onPanRef.current = onPan;
  }, [onPan]);

  useEffect(() => {
    disableMomentumRef.current = disableMomentum;
  }, [disableMomentum]);

  // Stop momentum animation
  const stopMomentum = useCallback(() => {
    if (rafIdRef.current !== null) {
      cancelAnimationFrame(rafIdRef.current);
      rafIdRef.current = null;
    }
    velocityRef.current = 0;
    setIsMomentumActive(false);
  }, []);

  // Momentum animation tick
  const momentumTick = useCallback(() => {
    const velocity = velocityRef.current;

    // Stop if velocity is below threshold
    if (Math.abs(velocity) < VELOCITY_THRESHOLD) {
      stopMomentum();
      return;
    }

    // Apply velocity
    onPanRef.current(velocity);

    // Apply friction
    velocityRef.current = velocity * FRICTION;

    // Schedule next frame
    rafIdRef.current = requestAnimationFrame(momentumTick);
  }, [stopMomentum]);

  // Calculate velocity from recent pointer samples
  const calculateVelocity = useCallback((): number => {
    const samples = pointerSamplesRef.current;
    if (samples.length < 2) return 0;

    const now = performance.now();
    // Filter to samples within the time window
    const recentSamples = samples.filter(
      (s) => now - s.timestamp <= VELOCITY_SAMPLE_WINDOW
    );

    if (recentSamples.length < 2) return 0;

    const first = recentSamples[0];
    const last = recentSamples[recentSamples.length - 1];
    const deltaTime = last.timestamp - first.timestamp;

    if (deltaTime <= 0) return 0;

    const deltaX = last.clientX - first.clientX;
    const containerWidth = containerWidthRef.current;

    if (containerWidth <= 0) return 0;

    // Convert to time velocity (seconds per millisecond, then per frame at 60fps)
    // Negative because dragging right = panning left (backward in time)
    const pixelsPerMs = deltaX / deltaTime;
    const secondsPerPixel = visibleDuration / containerWidth;
    const velocityPerMs = -pixelsPerMs * secondsPerPixel;
    const velocityPerFrame = velocityPerMs * (1000 / 60); // ~16.67ms per frame

    // Cap velocity to prevent runaway
    return Math.max(-MAX_VELOCITY, Math.min(MAX_VELOCITY, velocityPerFrame));
  }, [visibleDuration]);

  const handlePointerDown = useCallback(
    (e: React.PointerEvent) => {
      if (disabled || !containerRef.current) return;

      // Stop any active momentum
      stopMomentum();

      // Capture pointer for tracking outside element
      (e.target as HTMLElement).setPointerCapture(e.pointerId);

      // Store container width for velocity calculation
      containerWidthRef.current = containerRef.current.getBoundingClientRect().width;

      dragStartYRef.current = e.clientY;
      lastClientXRef.current = e.clientX;

      // Initialize velocity tracking
      pointerSamplesRef.current = [
        { clientX: e.clientX, timestamp: performance.now() },
      ];

      setIsPanning(true);
      setIsCancelled(false);
    },
    [disabled, containerRef, stopMomentum]
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
        // Clear velocity samples on cancel
        pointerSamplesRef.current = [];
        return;
      }

      // Clear cancelled state if user returns to valid area
      if (isCancelled) {
        setIsCancelled(false);
        // Restart velocity tracking
        pointerSamplesRef.current = [
          { clientX: e.clientX, timestamp: performance.now() },
        ];
      }

      // Track pointer for velocity calculation
      const now = performance.now();
      pointerSamplesRef.current.push({ clientX: e.clientX, timestamp: now });

      // Keep only recent samples
      if (pointerSamplesRef.current.length > VELOCITY_SAMPLE_COUNT) {
        pointerSamplesRef.current = pointerSamplesRef.current.slice(-VELOCITY_SAMPLE_COUNT);
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

      // Calculate velocity before resetting state
      const velocity = calculateVelocity();

      // Reset gesture state
      dragStartYRef.current = null;
      lastClientXRef.current = null;
      pointerSamplesRef.current = [];
      setIsPanning(false);

      // Start momentum if not cancelled and velocity is significant
      if (
        !isCancelled &&
        !disableMomentumRef.current &&
        Math.abs(velocity) >= VELOCITY_THRESHOLD
      ) {
        velocityRef.current = velocity;
        setIsMomentumActive(true);
        rafIdRef.current = requestAnimationFrame(momentumTick);
      }

      setIsCancelled(false);
    },
    [isPanning, isCancelled, calculateVelocity, momentumTick]
  );

  // Cleanup on unmount
  useEffect(() => {
    return () => {
      if (rafIdRef.current !== null) {
        cancelAnimationFrame(rafIdRef.current);
      }
    };
  }, []);

  return {
    isPanning,
    isMomentumActive,
    isCancelled,
    handlePointerDown,
    handlePointerMove,
    handlePointerUp,
    stopMomentum,
  };
}
