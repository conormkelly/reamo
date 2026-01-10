/**
 * useEdgeScroll Hook
 * Enables auto-scrolling when dragging near container edges
 *
 * During drag operations, detects when cursor is near the edge of the container
 * and triggers continuous viewport panning in that direction.
 * Speed accelerates the longer you hold at the edge.
 */

import { useRef, useCallback, useEffect } from 'react';
import type { RefObject } from 'react';

/** Width of edge zones that trigger scrolling (pixels) */
const EDGE_ZONE_WIDTH = 50;

/** Base scroll speed (seconds per second of real time) */
const BASE_SCROLL_SPEED = 2;

/** Maximum speed multiplier from depth in edge zone */
const MAX_DEPTH_MULTIPLIER = 2;

/** Maximum speed multiplier from time acceleration */
const MAX_TIME_MULTIPLIER = 4;

/** Time to reach max acceleration (ms) */
const ACCELERATION_TIME = 2000;

export interface UseEdgeScrollOptions {
  /** Ref to the container element */
  containerRef: RefObject<HTMLDivElement | null>;
  /** Duration of visible range (for speed scaling) */
  visibleDuration: number;
  /** Pan callback - receives delta in seconds */
  onPan: (deltaSeconds: number) => void;
  /** Whether edge scrolling is currently enabled */
  enabled: boolean;
}

export interface UseEdgeScrollResult {
  /** Call during pointer move to check edges and start/stop scrolling */
  updateEdgeScroll: (clientX: number) => void;
  /** Call to stop edge scrolling (on pointer up/cancel) */
  stopEdgeScroll: () => void;
}

export function useEdgeScroll({
  containerRef,
  visibleDuration,
  onPan,
  enabled,
}: UseEdgeScrollOptions): UseEdgeScrollResult {
  // Use refs to avoid stale closure issues
  const enabledRef = useRef(enabled);
  const visibleDurationRef = useRef(visibleDuration);
  const onPanRef = useRef(onPan);

  // Keep refs in sync with props
  useEffect(() => {
    enabledRef.current = enabled;
  }, [enabled]);

  useEffect(() => {
    visibleDurationRef.current = visibleDuration;
  }, [visibleDuration]);

  useEffect(() => {
    onPanRef.current = onPan;
  }, [onPan]);

  const rafIdRef = useRef<number | null>(null);
  const lastFrameTimeRef = useRef<number>(0);
  const scrollDirectionRef = useRef<number>(0);
  const depthMultiplierRef = useRef<number>(1);
  const scrollStartTimeRef = useRef<number>(0);

  // Stop animation loop
  const stopEdgeScroll = useCallback(() => {
    if (rafIdRef.current !== null) {
      cancelAnimationFrame(rafIdRef.current);
      rafIdRef.current = null;
    }
    scrollDirectionRef.current = 0;
    depthMultiplierRef.current = 1;
    scrollStartTimeRef.current = 0;
  }, []);

  // Animation tick - continuous panning while at edge
  const tick = useCallback((timestamp: number) => {
    // Check enabled via ref (always current)
    if (!enabledRef.current || scrollDirectionRef.current === 0) {
      rafIdRef.current = null;
      scrollDirectionRef.current = 0;
      return;
    }

    // Calculate delta time (capped to prevent huge jumps)
    const deltaMs =
      lastFrameTimeRef.current > 0
        ? Math.min(timestamp - lastFrameTimeRef.current, 50)
        : 16.67; // Default to ~60fps
    lastFrameTimeRef.current = timestamp;

    // Calculate time-based acceleration (ramps up over ACCELERATION_TIME)
    const scrollDuration = timestamp - scrollStartTimeRef.current;
    const timeProgress = Math.min(scrollDuration / ACCELERATION_TIME, 1);
    // Ease-in curve for smooth acceleration
    const timeMultiplier = 1 + timeProgress * timeProgress * (MAX_TIME_MULTIPLIER - 1);

    // Calculate pan amount
    // Scale speed based on visible duration (faster when zoomed out)
    const durationScale = Math.max(0.3, visibleDurationRef.current / 30);
    const deltaSeconds =
      scrollDirectionRef.current *
      BASE_SCROLL_SPEED *
      depthMultiplierRef.current *
      timeMultiplier *
      durationScale *
      (deltaMs / 1000);

    onPanRef.current(deltaSeconds);

    // Schedule next frame
    rafIdRef.current = requestAnimationFrame(tick);
  }, []);

  // Start animation loop
  const startEdgeScroll = useCallback(
    (timestamp: number) => {
      if (rafIdRef.current !== null) return; // Already running
      lastFrameTimeRef.current = 0;
      scrollStartTimeRef.current = timestamp;
      rafIdRef.current = requestAnimationFrame(tick);
    },
    [tick]
  );

  // Check cursor position and update scroll state
  const updateEdgeScroll = useCallback(
    (clientX: number) => {
      // Use ref for enabled check to avoid stale closure
      if (!enabledRef.current || !containerRef.current) {
        stopEdgeScroll();
        return;
      }

      const rect = containerRef.current.getBoundingClientRect();
      const leftEdge = rect.left + EDGE_ZONE_WIDTH;
      const rightEdge = rect.right - EDGE_ZONE_WIDTH;

      if (clientX < leftEdge) {
        // In left edge zone - scroll left (negative)
        const depth = Math.min((leftEdge - clientX) / EDGE_ZONE_WIDTH, 1);
        depthMultiplierRef.current = 1 + depth * (MAX_DEPTH_MULTIPLIER - 1);

        if (scrollDirectionRef.current !== -1) {
          // Direction changed or just started
          scrollDirectionRef.current = -1;
          startEdgeScroll(performance.now());
        }
      } else if (clientX > rightEdge) {
        // In right edge zone - scroll right (positive)
        const depth = Math.min((clientX - rightEdge) / EDGE_ZONE_WIDTH, 1);
        depthMultiplierRef.current = 1 + depth * (MAX_DEPTH_MULTIPLIER - 1);

        if (scrollDirectionRef.current !== 1) {
          // Direction changed or just started
          scrollDirectionRef.current = 1;
          startEdgeScroll(performance.now());
        }
      } else {
        // Not in edge zone - stop scrolling
        stopEdgeScroll();
      }
    },
    [containerRef, startEdgeScroll, stopEdgeScroll]
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
    updateEdgeScroll,
    stopEdgeScroll,
  };
}
