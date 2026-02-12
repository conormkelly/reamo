/**
 * useTimelineViewport — Viewport, follow-playhead, and coordinate conversion
 *
 * Manages timeline bounds calculation, internal/external viewport merging,
 * follow-playhead animation, coordinate conversion utilities, and pan/pinch
 * gesture setup.
 *
 * containerRef is passed in from Timeline — the ref is a DOM concern of the
 * component, not a viewport concern, so Timeline owns it and passes it down.
 */

import { useState, useRef, useCallback, useMemo, useEffect, type RefObject } from 'react';
import {
  useTransportAnimation,
  useViewport,
  type UseViewportReturn,
} from '../../../hooks';
import { usePanGesture, type UsePanGestureResult } from './usePanGesture';
import { usePinchGesture, type UsePinchGestureResult } from './usePinchGesture';
import type { Region, Marker } from '../../../core/types';
import type { WSItem } from '../../../core/WebSocketTypes';
import type { TimelineMode } from '../../../store/slices/regionEditSlice.types';

export interface UseTimelineViewportParams {
  containerRef: RefObject<HTMLDivElement | null>;
  positionSeconds: number;
  displayRegions: readonly Region[];
  markers: readonly Marker[];
  items: readonly WSItem[];
  externalViewport?: UseViewportReturn;
  followPlayhead: boolean;
  pauseFollowPlayhead: () => void;
  prefersReducedMotion: boolean;
  selectionModeActive: boolean;
  timelineMode: TimelineMode;
}

export interface UseTimelineViewportReturn {
  viewport: UseViewportReturn;
  containerWidth: number;
  timelineStart: number;
  duration: number;
  baseTimelineStart: number;
  baseDuration: number;
  timeToPercent: (time: number) => number;
  viewportTimeToPercent: (time: number) => number;
  playheadPercent: number;
  positionToTime: (clientX: number) => number;
  pauseFollow: () => void;
  panGesture: UsePanGestureResult;
  pinchGesture: UsePinchGestureResult;
}

export function useTimelineViewport({
  containerRef,
  positionSeconds,
  displayRegions,
  markers,
  items,
  externalViewport,
  followPlayhead,
  pauseFollowPlayhead,
  prefersReducedMotion,
  selectionModeActive,
  timelineMode,
}: UseTimelineViewportParams): UseTimelineViewportReturn {
  // Track container width for marker clustering
  const [containerWidth, setContainerWidth] = useState(0);

  useEffect(() => {
    if (!containerRef.current) return;

    const updateWidth = () => {
      if (containerRef.current) {
        setContainerWidth(containerRef.current.offsetWidth);
      }
    };

    // Initial measurement
    updateWidth();

    // Use ResizeObserver for responsive updates
    const resizeObserver = new ResizeObserver(updateWidth);
    resizeObserver.observe(containerRef.current);

    return () => resizeObserver.disconnect();
  }, [containerRef]);

  // Track max playhead position reached during playback
  // This allows viewport to extend past the initial project end (like REAPER's soft-end behavior)
  const [maxPlayheadPosition, setMaxPlayheadPosition] = useState(0);

  // Calculate base timeline bounds (without drag targets - used as fallback when cancelled)
  const { baseTimelineStart, baseDuration } = useMemo(() => {
    const start = 0;
    let end = 0;

    // Use display regions (includes drag preview) to get current extent
    for (const region of displayRegions) {
      if (region.end > end) end = region.end;
    }
    for (const marker of markers) {
      if (marker.position > end) end = marker.position;
    }
    // Include items - they may extend beyond regions
    for (const item of items) {
      const itemEnd = item.position + item.length;
      if (itemEnd > end) end = itemEnd;
    }
    // Include playhead position to ensure it's always visible
    // (fixes race condition on initial load when regions/markers haven't synced yet)
    if (positionSeconds > end) end = positionSeconds;
    // Include max position reached during playback (soft-end like REAPER)
    if (maxPlayheadPosition > end) end = maxPlayheadPosition;

    // Add 5% padding at the end
    end = Math.max(end * 1.015, 10);

    return { baseTimelineStart: start, baseDuration: end - start };
  }, [displayRegions, markers, items, positionSeconds, maxPlayheadPosition]);

  // Use base bounds for hook calculations (stable positioning)
  const timelineStart = baseTimelineStart;
  const duration = baseDuration;

  // Viewport state for pan/zoom navigation
  // Use external viewport if provided (shared state from TimelineSection), otherwise create own
  const internalViewport = useViewport({
    projectDuration: duration,
    initialRange: { start: 0, end: duration }, // Default to full project (zoom-to-fit)
  });
  const viewport = externalViewport ?? internalViewport;

  // Follow playhead using animation engine
  // Handles both smooth scrolling during playback AND jumps when stopped (marker nav, seeks)
  const lastFollowPanRef = useRef(0);
  const lastKnownPositionRef = useRef(0);
  const FOLLOW_THROTTLE_MS = 100; // Max 10 viewport updates per second
  const JUMP_THRESHOLD = 0.5; // Seconds - consider it a "jump" if position changes by more than this

  useTransportAnimation(
    (state) => {
      const playheadPos = state.position;

      // Track max position reached (extends project bounds like REAPER's soft-end)
      // Only update during playback to avoid resetting on seeks backward
      if (state.isPlaying && playheadPos > maxPlayheadPosition) {
        setMaxPlayheadPosition(playheadPos);
      }

      if (!followPlayhead) return;

      const { start, end } = viewport.visibleRange;
      const visibleDuration = end - start;

      // Detect jumps (marker nav, seeks) - these should always trigger a pan
      const positionDelta = Math.abs(playheadPos - lastKnownPositionRef.current);
      const isJump = positionDelta > JUMP_THRESHOLD;
      lastKnownPositionRef.current = playheadPos;

      // When stopped: only respond to jumps (marker navigation, seeks)
      // When playing: use threshold-based smooth follow
      if (!state.isPlaying && !isJump) return;

      // Throttle during playback (but not for jumps - those should be immediate)
      const now = performance.now();
      if (!isJump && now - lastFollowPanRef.current < FOLLOW_THROTTLE_MS) return;

      // Check if playhead is outside the middle 60% of viewport
      const leftThreshold = start + visibleDuration * 0.2;
      const rightThreshold = end - visibleDuration * 0.2;

      if (playheadPos < leftThreshold || playheadPos > rightThreshold) {
        // Center viewport on playhead (viewport hook handles clamping)
        viewport.setVisibleRange({
          start: playheadPos - visibleDuration / 2,
          end: playheadPos + visibleDuration / 2,
        });
        lastFollowPanRef.current = now;
      }
    },
    [followPlayhead, viewport, maxPlayheadPosition]
  );

  // Pause follow when user pans - uses store action directly
  const pauseFollow = pauseFollowPlayhead;

  // Convert time to percentage position (using base values for stability)
  const timeToPercent = useCallback(
    (time: number) => {
      if (duration === 0) return 0;
      return ((time - timelineStart) / duration) * 100;
    },
    [timelineStart, duration]
  );

  // Simple viewport-relative conversion (without drag-extension logic which is only for region rendering)
  const viewportTimeToPercent = useCallback(
    (time: number) => {
      const { start, end } = viewport.visibleRange;
      const dur = end - start;
      if (dur === 0) return 0;
      return ((time - start) / dur) * 100;
    },
    [viewport.visibleRange]
  );

  const playheadPercent = viewportTimeToPercent(positionSeconds);

  // Convert x position to time (using viewport coordinates)
  const positionToTime = useCallback(
    (clientX: number) => {
      if (!containerRef.current) return 0;
      const rect = containerRef.current.getBoundingClientRect();
      const percent = (clientX - rect.left) / rect.width;
      const { start, end } = viewport.visibleRange;
      return start + percent * (end - start);
    },
    [containerRef, viewport.visibleRange]
  );

  // Pan gesture for viewport navigation (navigate mode, when not in selection mode)
  const panGesture = usePanGesture({
    containerRef,
    visibleDuration: viewport.visibleDuration,
    onPan: (delta) => {
      viewport.pan(delta);
      pauseFollow(); // Pause follow when user pans
    },
    disabled: timelineMode !== 'navigate' || selectionModeActive,
    disableMomentum: prefersReducedMotion,
  });

  // Pinch gesture for zooming (works in all modes)
  // When following playhead, zoom centers on playhead instead of pinch midpoint
  const pinchGesture = usePinchGesture({
    containerRef,
    visibleRange: viewport.visibleRange,
    setVisibleRange: viewport.setVisibleRange,
    projectDuration: duration,
    disabled: false, // Pinch always works
    centerOnTime: followPlayhead ? positionSeconds : undefined,
  });

  return {
    viewport,
    containerWidth,
    timelineStart,
    duration,
    baseTimelineStart,
    baseDuration,
    timeToPercent,
    viewportTimeToPercent,
    playheadPercent,
    positionToTime,
    pauseFollow,
    panGesture,
    pinchGesture,
  };
}
