/**
 * usePeaksSubscription Hook
 * Subscribes to peaks data for multiple tracks via WebSocket
 *
 * Supports two subscription modes:
 * - Range mode: Subscribe to track indices [start, end] (for sequential bank navigation)
 * - GUID mode: Subscribe to specific track GUIDs (for filtered/custom bank views)
 *
 * Backend pushes peaks events when items change. Events are track-keyed maps.
 *
 * @example
 * ```tsx
 * // Range mode (for timeline view)
 * function TimelineWaveforms({ range }: { range: { start: number; end: number } }) {
 *   const { peaksByTrack } = usePeaksSubscription({ range });
 *
 *   // peaksByTrack is Map<trackIdx, Map<itemGuid, WSItemPeaks>>
 *   return <MultiTrackWaveforms peaksByTrack={peaksByTrack} />;
 * }
 *
 * // GUID mode (for filtered bank view)
 * function FilteredWaveforms({ guids }: { guids: string[] }) {
 *   const { peaksByTrack } = usePeaksSubscription({ guids });
 *   // ...
 * }
 * ```
 */

import { useEffect, useRef } from 'react';
import { useReaper } from '../components/ReaperProvider';
import { useReaperStore } from '../store';
import { peaks } from '../core/WebSocketCommands';
import type { WSItemPeaks } from '../core/WebSocketTypes';

/** Default number of peaks per item (for timeline blobs) */
const DEFAULT_SAMPLE_COUNT = 30;

/** Subscription options */
export interface UsePeaksSubscriptionOptions {
  /** Range mode: subscribe to track indices [start, end] */
  range?: { start: number; end: number };
  /** GUID mode: subscribe to specific track GUIDs */
  guids?: string[];
  /** Number of peaks per item (default 30) */
  sampleCount?: number;
}

/** Return value from usePeaksSubscription */
export interface UsePeaksSubscriptionResult {
  /** Map from track index to (itemGuid -> peaks data) */
  peaksByTrack: Map<number, Map<string, WSItemPeaks>>;
  /** Get peaks for a specific track */
  getPeaksForTrack: (trackIdx: number) => Map<string, WSItemPeaks> | undefined;
  /** Get peaks for a specific item */
  getPeaksForItem: (trackIdx: number, itemGuid: string) => WSItemPeaks | undefined;
}

// Empty map for stable reference when no data
const EMPTY_PEAKS_MAP = new Map<number, Map<string, WSItemPeaks>>();

/**
 * Hook to subscribe to peaks for multiple tracks
 *
 * @param options - Subscription options (range or guids mode)
 * @returns Object with peaksByTrack map and helper functions
 */
export function usePeaksSubscription(
  options: UsePeaksSubscriptionOptions | null
): UsePeaksSubscriptionResult {
  const { sendCommand, connected } = useReaper();
  const setPeaksSubscriptionRange = useReaperStore((s) => s.setPeaksSubscriptionRange);
  const setPeaksSubscriptionGuids = useReaperStore((s) => s.setPeaksSubscriptionGuids);
  const clearPeaksSubscription = useReaperStore((s) => s.clearPeaksSubscription);
  const peaksByTrack = useReaperStore((s) => s.peaksByTrack);
  const getPeaksForTrack = useReaperStore((s) => s.getPeaksForTrack);
  const getPeaksForItem = useReaperStore((s) => s.getPeaksForItem);

  // Track previous subscription to avoid duplicate commands
  const prevOptionsRef = useRef<string | null>(null);

  // Create a stable key for comparison
  const optionsKey = options
    ? JSON.stringify({
        range: options.range,
        guids: options.guids,
        sampleCount: options.sampleCount,
      })
    : null;

  useEffect(() => {
    // Skip if not connected
    if (!connected) {
      return;
    }

    // Check if subscription changed
    if (prevOptionsRef.current === optionsKey) {
      return;
    }

    // Unsubscribe from previous
    if (prevOptionsRef.current !== null) {
      sendCommand(peaks.unsubscribe());
    }

    // Update ref
    prevOptionsRef.current = optionsKey;

    // Subscribe with new options or clear if null
    if (options) {
      const sampleCount = options.sampleCount ?? DEFAULT_SAMPLE_COUNT;

      if (options.range) {
        // Range mode
        setPeaksSubscriptionRange(options.range.start, options.range.end);
        sendCommand(peaks.subscribe({ range: options.range, sampleCount }));
      } else if (options.guids && options.guids.length > 0) {
        // GUID mode
        setPeaksSubscriptionGuids(options.guids);
        sendCommand(peaks.subscribe({ guids: options.guids, sampleCount }));
      }
    } else {
      clearPeaksSubscription();
    }

    // Cleanup on unmount
    return () => {
      if (prevOptionsRef.current !== null) {
        sendCommand(peaks.unsubscribe());
        clearPeaksSubscription();
        prevOptionsRef.current = null;
      }
    };
  }, [
    optionsKey,
    options,
    connected,
    sendCommand,
    setPeaksSubscriptionRange,
    setPeaksSubscriptionGuids,
    clearPeaksSubscription,
  ]);

  return {
    peaksByTrack: peaksByTrack || EMPTY_PEAKS_MAP,
    getPeaksForTrack,
    getPeaksForItem,
  };
}
