/**
 * useBatchPeaksFetch Hook
 * Fetches peaks for multiple items with concurrency control
 *
 * Used by TimelineWaveformOverlay to efficiently load waveforms
 * for all visible items on the selected track.
 */

import { useState, useEffect, useRef, useCallback } from 'react';
import { useReaper } from '../components/ReaperProvider';
import type { WSItem, PeaksResponsePayload, ResponseMessage } from '../core/WebSocketTypes';
import { peaksCache, buildPeaksCacheKey } from '../core/PeaksCache';

/** Result for a single item */
export interface PeaksFetchResult {
  peaks: PeaksResponsePayload | null;
  loading: boolean;
  error: string | null;
}

/** Map of itemKey to fetch result */
export type BatchPeaksResult = Map<string, PeaksFetchResult>;

/** Build item key for the map - uses GUID for stability, plus content properties that affect peaks */
function itemKey(item: WSItem): string {
  return `${item.guid}:${item.length.toFixed(3)}:${item.activeTakeIdx}`;
}

/**
 * Hook to fetch peaks for multiple items with concurrency control
 *
 * @param items - Array of items to fetch peaks for
 * @param enabled - Whether fetching is enabled (e.g., only in navigate mode)
 * @param width - Number of peak samples to request
 * @param maxConcurrent - Max simultaneous requests (default 3)
 * @returns Map of item keys to peaks/loading/error state
 */
export function useBatchPeaksFetch(
  items: WSItem[],
  enabled: boolean,
  width: number = 100,
  maxConcurrent: number = 3
): BatchPeaksResult {
  const { sendAsync, connected } = useReaper();
  const [results, setResults] = useState<BatchPeaksResult>(new Map());

  // Track in-flight requests to manage concurrency
  const inFlightRef = useRef<Set<string>>(new Set());
  const queueRef = useRef<WSItem[]>([]);

  // Process the next item in queue
  const processQueue = useCallback(async () => {
    if (!connected || inFlightRef.current.size >= maxConcurrent) return;

    const nextItem = queueRef.current.shift();
    if (!nextItem) return;

    const key = itemKey(nextItem);

    // Skip if already in flight
    if (inFlightRef.current.has(key)) {
      processQueue();
      return;
    }

    inFlightRef.current.add(key);

    // Mark as loading
    setResults((prev) => {
      const next = new Map(prev);
      next.set(key, { peaks: null, loading: true, error: null });
      return next;
    });

    try {
      const response = (await sendAsync('item/getPeaks', {
        trackIdx: nextItem.trackIdx,
        itemIdx: nextItem.itemIdx,
        width,
      })) as ResponseMessage;

      if (!response.success) {
        setResults((prev) => {
          const next = new Map(prev);
          next.set(key, {
            peaks: null,
            loading: false,
            error: response.error?.message ?? 'Failed to fetch peaks',
          });
          return next;
        });
      } else {
        const peaksData = response.payload as unknown as PeaksResponsePayload;

        // Cache the result
        const cacheKey = buildPeaksCacheKey(
          peaksData.itemGUID,
          peaksData.takeGUID,
          peaksData.length,
          peaksData.startOffset,
          peaksData.playrate
        );
        peaksCache.set(cacheKey, peaksData);

        setResults((prev) => {
          const next = new Map(prev);
          next.set(key, { peaks: peaksData, loading: false, error: null });
          return next;
        });
      }
    } catch (err) {
      setResults((prev) => {
        const next = new Map(prev);
        next.set(key, {
          peaks: null,
          loading: false,
          error: err instanceof Error ? err.message : 'Failed to fetch peaks',
        });
        return next;
      });
    } finally {
      inFlightRef.current.delete(key);
      // Process next in queue
      processQueue();
    }
  }, [connected, sendAsync, width, maxConcurrent]);

  // Effect to populate queue and check cache
  useEffect(() => {
    if (!enabled || !connected) {
      setResults(new Map());
      queueRef.current = [];
      return;
    }

    // Filter items: skip MIDI items, keep items with at least one take
    // Note: activeTakeGuid/activeTakeIsMidi are sparse fields not always populated
    const validItems = items.filter(
      (item) => item.takeCount > 0 && !item.activeTakeIsMidi
    );

    // Check cache and build queue
    const newResults = new Map<string, PeaksFetchResult>();
    const toFetch: WSItem[] = [];

    for (const item of validItems) {
      const key = itemKey(item);

      // Check if already loading or has result from previous render
      const existingResult = results.get(key);
      if (existingResult?.peaks) {
        // Already have peaks from previous fetch
        newResults.set(key, existingResult);
      } else if (inFlightRef.current.has(key)) {
        // Already loading - keep previous state
        if (existingResult) {
          newResults.set(key, existingResult);
        } else {
          newResults.set(key, { peaks: null, loading: true, error: null });
        }
      } else {
        // Need to fetch
        newResults.set(key, { peaks: null, loading: true, error: null });
        toFetch.push(item);
      }
    }

    setResults(newResults);
    queueRef.current = toFetch;

    // Start processing queue
    for (let i = 0; i < maxConcurrent; i++) {
      processQueue();
    }
  }, [items, enabled, connected, processQueue, maxConcurrent]);

  return results;
}
