/**
 * Viewport Hook
 * Manages timeline viewport state (visible time range, zoom, pan)
 *
 * @example
 * ```tsx
 * function Timeline() {
 *   const { visibleRange, pan, zoomIn, zoomOut, timeToPercent } = useViewport({
 *     projectDuration: 180,
 *     initialRange: { start: 0, end: 30 },
 *   });
 *
 *   const handleDrag = (deltaX: number, containerWidth: number) => {
 *     const timeDelta = (deltaX / containerWidth) * (visibleRange.end - visibleRange.start);
 *     pan(-timeDelta); // Negative: dragging right moves backward in time
 *   };
 *
 *   return <div style={{ left: `${timeToPercent(marker.position)}%` }} />;
 * }
 * ```
 */

import { useState, useCallback, useMemo } from 'react';

/** Time range in seconds */
export interface TimeRange {
  start: number;
  end: number;
}

export interface UseViewportOptions {
  /** Total project duration in seconds */
  projectDuration: number;
  /** Initial visible range (default: first 30 seconds) */
  initialRange?: TimeRange;
}

export interface UseViewportReturn {
  /** Current visible time range */
  visibleRange: TimeRange;
  /** Current zoom level index (into ZOOM_STEPS) */
  zoomLevel: number;
  /** Duration of visible range in seconds */
  visibleDuration: number;
  /** Pan viewport by delta seconds (positive = forward in time) */
  pan: (deltaSeconds: number) => void;
  /** Zoom in (show less time, more detail) */
  zoomIn: () => void;
  /** Zoom out (show more time, less detail) */
  zoomOut: () => void;
  /** Set visible range directly */
  setVisibleRange: (range: TimeRange) => void;
  /** Reset to initial range */
  reset: () => void;
  /** Fit viewport to content range */
  fitToContent: (contentRange: TimeRange) => void;
  /** Convert time (seconds) to percent within visible range */
  timeToPercent: (time: number) => number;
  /** Convert percent within visible range to time (seconds) */
  percentToTime: (percent: number) => number;
  /** Check if a time range overlaps with visible range (with optional buffer) */
  isInView: (start: number, end: number, buffer?: number) => boolean;
  /** Zoom steps array (seconds visible at each level) */
  zoomSteps: readonly number[];
}

/**
 * Discrete zoom steps (seconds visible at each level)
 * Range from 1 second (precision editing) to 1 hour (overview)
 * Finer steps at close zoom for accurate cursor-based edits (trim to cursor, etc.)
 */
export const ZOOM_STEPS = [1, 2, 3, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600] as const;

/** Default visible duration (30 seconds - good mobile default) */
const DEFAULT_DURATION = 30;

/**
 * Find the zoom level index that best matches a duration
 */
function findZoomLevel(duration: number): number {
  // Find the step closest to the given duration
  let bestIdx = 0;
  let bestDiff = Math.abs(ZOOM_STEPS[0] - duration);

  for (let i = 1; i < ZOOM_STEPS.length; i++) {
    const diff = Math.abs(ZOOM_STEPS[i] - duration);
    if (diff < bestDiff) {
      bestDiff = diff;
      bestIdx = i;
    }
  }

  return bestIdx;
}

/**
 * Clamp a range to valid bounds [0, projectDuration]
 */
function clampRange(range: TimeRange, projectDuration: number): TimeRange {
  const duration = range.end - range.start;

  // If range is larger than project, show entire project
  if (duration >= projectDuration) {
    return { start: 0, end: projectDuration };
  }

  // Clamp start to [0, projectDuration - duration]
  let start = Math.max(0, range.start);
  start = Math.min(start, Math.max(0, projectDuration - duration));

  return { start, end: start + duration };
}

/**
 * Hook for managing timeline viewport state
 */
export function useViewport(options: UseViewportOptions): UseViewportReturn {
  const { projectDuration } = options;

  // Calculate initial range
  const initialRange = useMemo(() => {
    if (options.initialRange) {
      return clampRange(options.initialRange, projectDuration);
    }
    const duration = Math.min(DEFAULT_DURATION, projectDuration);
    return { start: 0, end: duration };
  }, [options.initialRange, projectDuration]);

  // State: visible range
  const [visibleRange, setVisibleRangeInternal] = useState<TimeRange>(initialRange);

  // Derived: zoom level and duration
  const visibleDuration = visibleRange.end - visibleRange.start;
  const zoomLevel = useMemo(() => findZoomLevel(visibleDuration), [visibleDuration]);

  // Set visible range with clamping
  const setVisibleRange = useCallback(
    (range: TimeRange) => {
      setVisibleRangeInternal(clampRange(range, projectDuration));
    },
    [projectDuration]
  );

  // Pan by delta seconds
  const pan = useCallback(
    (deltaSeconds: number) => {
      setVisibleRangeInternal((prev) => {
        const newRange = {
          start: prev.start + deltaSeconds,
          end: prev.end + deltaSeconds,
        };
        return clampRange(newRange, projectDuration);
      });
    },
    [projectDuration]
  );

  // Zoom in (next smaller duration step)
  const zoomIn = useCallback(() => {
    setVisibleRangeInternal((prev) => {
      const currentLevel = findZoomLevel(prev.end - prev.start);
      const newLevel = Math.max(0, currentLevel - 1);
      const newDuration = ZOOM_STEPS[newLevel];

      // Keep center point fixed during zoom
      const center = (prev.start + prev.end) / 2;
      const newRange = {
        start: center - newDuration / 2,
        end: center + newDuration / 2,
      };

      return clampRange(newRange, projectDuration);
    });
  }, [projectDuration]);

  // Zoom out (next larger duration step)
  const zoomOut = useCallback(() => {
    setVisibleRangeInternal((prev) => {
      const currentLevel = findZoomLevel(prev.end - prev.start);
      const newLevel = Math.min(ZOOM_STEPS.length - 1, currentLevel + 1);
      const newDuration = ZOOM_STEPS[newLevel];

      // Keep center point fixed during zoom
      const center = (prev.start + prev.end) / 2;
      const newRange = {
        start: center - newDuration / 2,
        end: center + newDuration / 2,
      };

      return clampRange(newRange, projectDuration);
    });
  }, [projectDuration]);

  // Reset to initial range
  const reset = useCallback(() => {
    setVisibleRangeInternal(initialRange);
  }, [initialRange]);

  // Fit to content range (with padding)
  const fitToContent = useCallback(
    (contentRange: TimeRange) => {
      const contentDuration = contentRange.end - contentRange.start;
      // Add 5% padding
      const paddedDuration = contentDuration * 1.1;
      const paddedStart = contentRange.start - contentDuration * 0.05;

      const newRange = {
        start: paddedStart,
        end: paddedStart + paddedDuration,
      };

      setVisibleRangeInternal(clampRange(newRange, projectDuration));
    },
    [projectDuration]
  );

  // Convert time to percent within visible range
  const timeToPercent = useCallback(
    (time: number): number => {
      if (visibleDuration === 0) return 0;
      return ((time - visibleRange.start) / visibleDuration) * 100;
    },
    [visibleRange.start, visibleDuration]
  );

  // Convert percent to time
  const percentToTime = useCallback(
    (percent: number): number => {
      return visibleRange.start + (percent / 100) * visibleDuration;
    },
    [visibleRange.start, visibleDuration]
  );

  // Check if a range is in view (with optional buffer)
  const isInView = useCallback(
    (start: number, end: number, buffer = 0): boolean => {
      const bufferedStart = visibleRange.start - buffer;
      const bufferedEnd = visibleRange.end + buffer;
      return start < bufferedEnd && end > bufferedStart;
    },
    [visibleRange.start, visibleRange.end]
  );

  return {
    visibleRange,
    zoomLevel,
    visibleDuration,
    pan,
    zoomIn,
    zoomOut,
    setVisibleRange,
    reset,
    fitToContent,
    timeToPercent,
    percentToTime,
    isInView,
    zoomSteps: ZOOM_STEPS,
  };
}
