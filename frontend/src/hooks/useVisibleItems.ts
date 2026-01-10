/**
 * Visible Items Hook
 * Filters items to visible time range with optional buffer for smooth scrolling
 *
 * @example
 * ```tsx
 * function TimelineRegions() {
 *   const regions = useReaperStore((s) => s.regions);
 *   const { visibleRange } = useViewport({ projectDuration });
 *
 *   const { visibleItems, count, total } = useVisibleItems({
 *     items: regions,
 *     getStart: (r) => r.start,
 *     getEnd: (r) => r.end,
 *     visibleRange,
 *     buffer: 10, // 10 second buffer each side
 *   });
 *
 *   return visibleItems.map((region) => <RegionBlock key={region.id} region={region} />);
 * }
 * ```
 */

import { useMemo } from 'react';
import type { TimeRange } from './useViewport';

export interface UseVisibleItemsOptions<T> {
  /** Array of items to filter */
  items: T[];
  /** Function to get start time from item */
  getStart: (item: T) => number;
  /** Function to get end time from item (if omitted, items are treated as points) */
  getEnd?: (item: T) => number;
  /** Current visible time range */
  visibleRange: TimeRange;
  /** Buffer in seconds to include beyond visible range (default: 10) */
  buffer?: number;
}

export interface UseVisibleItemsReturn<T> {
  /** Items within visible range (plus buffer) */
  visibleItems: T[];
  /** Number of visible items */
  count: number;
  /** Total number of items (before filtering) */
  total: number;
}

/** Default buffer in seconds */
const DEFAULT_BUFFER = 10;

/**
 * Hook for filtering items to visible time range
 *
 * Implements efficient filtering with buffer zone to prevent items from
 * "popping" during small pans. Memoized for performance.
 */
export function useVisibleItems<T>(options: UseVisibleItemsOptions<T>): UseVisibleItemsReturn<T> {
  const { items, getStart, getEnd, visibleRange, buffer = DEFAULT_BUFFER } = options;

  const result = useMemo(() => {
    const bufferedStart = visibleRange.start - buffer;
    const bufferedEnd = visibleRange.end + buffer;

    const visibleItems = items.filter((item) => {
      const start = getStart(item);
      const end = getEnd ? getEnd(item) : start; // Points use same start/end

      // Item overlaps with buffered range if:
      // item.start < bufferedEnd AND item.end > bufferedStart
      return start < bufferedEnd && end > bufferedStart;
    });

    return {
      visibleItems,
      count: visibleItems.length,
      total: items.length,
    };
  }, [items, getStart, getEnd, visibleRange.start, visibleRange.end, buffer]);

  return result;
}

/**
 * Convenience hook for filtering markers (point items)
 */
export function useVisibleMarkers<T extends { position: number }>(
  markers: T[],
  visibleRange: TimeRange,
  buffer = DEFAULT_BUFFER
): UseVisibleItemsReturn<T> {
  return useVisibleItems({
    items: markers,
    getStart: (m) => m.position,
    visibleRange,
    buffer,
  });
}

/**
 * Convenience hook for filtering regions (range items)
 */
export function useVisibleRegions<T extends { start: number; end: number }>(
  regions: T[],
  visibleRange: TimeRange,
  buffer = DEFAULT_BUFFER
): UseVisibleItemsReturn<T> {
  return useVisibleItems({
    items: regions,
    getStart: (r) => r.start,
    getEnd: (r) => r.end,
    visibleRange,
    buffer,
  });
}

/**
 * Convenience hook for filtering media items
 */
export function useVisibleMediaItems<T extends { position: number; length: number }>(
  items: T[],
  visibleRange: TimeRange,
  buffer = DEFAULT_BUFFER
): UseVisibleItemsReturn<T> {
  return useVisibleItems({
    items,
    getStart: (i) => i.position,
    getEnd: (i) => i.position + i.length,
    visibleRange,
    buffer,
  });
}
