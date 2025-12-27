/**
 * usePeaksFetch Hook
 * Fetches and caches waveform peak data for an item
 */

import { useState, useEffect, useRef } from 'react';
import { useReaper } from '../components/ReaperProvider';
import type { WSItem, PeaksResponsePayload, ResponseMessage } from '../core/WebSocketTypes';
import { peaksCache, buildPeaksCacheKey } from '../core/PeaksCache';

export interface UsePeaksFetchResult {
  /** The fetched peaks data */
  peaks: PeaksResponsePayload | null;
  /** Whether peaks are currently being fetched */
  loading: boolean;
  /** Error message if fetch failed */
  error: string | null;
}

/**
 * Hook to fetch and cache peaks for an item
 *
 * @param item - The item to fetch peaks for, or null to skip
 * @param width - Optional width hint for the number of peaks to fetch
 * @returns Peaks data, loading state, and error
 */
export function usePeaksFetch(
  item: WSItem | null,
  width?: number
): UsePeaksFetchResult {
  const { connection } = useReaper();
  const [peaks, setPeaks] = useState<PeaksResponsePayload | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Track the current item to avoid stale updates
  const currentItemRef = useRef<string | null>(null);

  useEffect(() => {
    // Skip if no item
    if (!item) {
      setPeaks(null);
      setLoading(false);
      setError(null);
      currentItemRef.current = null;
      return;
    }

    // Get active take
    const activeTake = item.takes[item.activeTakeIdx];
    if (!activeTake) {
      setPeaks(null);
      setLoading(false);
      setError('No active take');
      currentItemRef.current = null;
      return;
    }

    // Skip MIDI items
    if (activeTake.isMIDI) {
      setPeaks(null);
      setLoading(false);
      setError(null);
      currentItemRef.current = null;
      return;
    }

    // Create cache key
    // Note: We don't have startOffset and playrate in WSItem, so we use defaults
    // The actual values come from the backend response
    const itemKey = `${item.guid}:${activeTake.guid}:${item.length}`;
    currentItemRef.current = itemKey;

    // Check cache first - use item.guid and take.guid as simplified key
    // Full cache with startOffset/playrate is handled in response
    const cacheKey = buildPeaksCacheKey(
      item.guid,
      activeTake.guid,
      item.length,
      0, // Will be updated from response
      1 // Will be updated from response
    );

    const cached = peaksCache.get(cacheKey);
    if (cached) {
      setPeaks(cached);
      setLoading(false);
      setError(null);
      return;
    }

    // Fetch peaks from server
    if (!connection) {
      setError('Not connected');
      return;
    }

    setLoading(true);
    setError(null);

    connection
      .sendAsync('item/getPeaks', {
        trackIdx: item.trackIdx,
        itemIdx: item.itemIdx,
        width: width ?? 100,
      })
      .then((response) => {
        // Check if this is still the current item
        if (currentItemRef.current !== itemKey) {
          return;
        }

        const resp = response as ResponseMessage;
        if (!resp.success) {
          setError(resp.error?.message ?? 'Failed to fetch peaks');
          setLoading(false);
          return;
        }

        const peaksData = resp.payload as unknown as PeaksResponsePayload;

        // Cache the result with actual values from response
        const fullCacheKey = buildPeaksCacheKey(
          peaksData.itemGUID,
          peaksData.takeGUID,
          peaksData.length,
          peaksData.startOffset,
          peaksData.playrate
        );
        peaksCache.set(fullCacheKey, peaksData);

        setPeaks(peaksData);
        setLoading(false);
      })
      .catch((err) => {
        // Check if this is still the current item
        if (currentItemRef.current !== itemKey) {
          return;
        }

        setError(err.message ?? 'Failed to fetch peaks');
        setLoading(false);
      });
  }, [item, connection, width]);

  return { peaks, loading, error };
}
