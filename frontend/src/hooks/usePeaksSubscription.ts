/**
 * usePeaksSubscription Hook
 * Subscribes to peaks data for multiple tracks via WebSocket
 *
 * Supports two subscription modes:
 * - Range mode: Subscribe to track indices [start, end] (for sequential bank navigation)
 * - GUID mode: Subscribe to specific track GUIDs (for filtered/custom bank views)
 *
 * Viewport updates are debounced (200ms) to avoid spamming during zoom/pan gestures.
 * Track subscription changes trigger immediate re-subscribe; viewport-only changes
 * use the lightweight peaks/updateViewport command after debounce.
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
import { peaks, type PeaksViewport } from '../core/WebSocketCommands';
import type { WSItemPeaks } from '../core/WebSocketTypes';

// Re-export for consumers
export type { PeaksViewport };

/** Default number of peaks per item (for timeline blobs, fallback when no viewport) */
const DEFAULT_SAMPLE_COUNT = 30;

/** Debounce delay for viewport updates (ms) - per architecture doc */
const VIEWPORT_DEBOUNCE_MS = 200;

/**
 * Calculate LOD level from viewport (must match backend peaks_subscriptions.zig)
 * This prevents sending viewport updates when LOD hasn't actually changed.
 *
 * LOD levels:
 * - 2 (Fine):   peakrate > 200 px/sec
 * - 1 (Medium): peakrate > 5 px/sec
 * - 0 (Coarse): peakrate <= 5 px/sec
 */
function calculateLOD(viewport: PeaksViewport): number {
  const duration = viewport.end - viewport.start;
  if (duration <= 0) return 1; // Default medium

  const peakrate = viewport.widthPx / duration;

  if (peakrate > 200) return 2; // Fine
  if (peakrate > 5) return 1; // Medium
  return 0; // Coarse
}

/** Subscription options */
export interface UsePeaksSubscriptionOptions {
  /** Range mode: subscribe to track indices [start, end] */
  range?: { start: number; end: number };
  /** GUID mode: subscribe to specific track GUIDs */
  guids?: string[];
  /** Number of peaks per item (default 30, used as fallback when no viewport) */
  sampleCount?: number;
  /** Viewport for adaptive resolution - when provided, peakrate is calculated from viewport */
  viewport?: PeaksViewport;
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

  // Track previous subscription (excluding viewport - that's handled separately)
  const prevSubscriptionRef = useRef<string | null>(null);
  // Track previous LOD level (only send viewport update when LOD changes)
  const prevLODRef = useRef<number | null>(null);
  // Debounce timer for viewport updates
  const viewportDebounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Subscription key: only tracks + sampleCount (NOT viewport)
  // Viewport changes don't require full re-subscription
  const subscriptionKey = options
    ? JSON.stringify({
        range: options.range,
        guids: options.guids,
        sampleCount: options.sampleCount,
      })
    : null;

  // Calculate current LOD - only send updates when this changes
  const currentLOD = options?.viewport ? calculateLOD(options.viewport) : null;

  // Effect 1: Track subscription changes (immediate)
  useEffect(() => {
    if (!connected) return;

    // Check if subscription changed (ignoring viewport)
    if (prevSubscriptionRef.current === subscriptionKey) {
      return;
    }

    // Unsubscribe from previous
    if (prevSubscriptionRef.current !== null) {
      sendCommand(peaks.unsubscribe());
    }

    prevSubscriptionRef.current = subscriptionKey;

    // Subscribe with new options or clear if null
    if (options) {
      const sampleCount = options.sampleCount ?? DEFAULT_SAMPLE_COUNT;

      if (options.range) {
        setPeaksSubscriptionRange(options.range.start, options.range.end);
        sendCommand(
          peaks.subscribe({
            range: options.range,
            sampleCount,
            viewport: options.viewport, // Include current viewport on initial subscribe
          })
        );
        // Track the LOD we sent with subscription
        prevLODRef.current = currentLOD;
      } else if (options.guids && options.guids.length > 0) {
        setPeaksSubscriptionGuids(options.guids);
        sendCommand(
          peaks.subscribe({
            guids: options.guids,
            sampleCount,
            viewport: options.viewport,
          })
        );
        prevLODRef.current = currentLOD;
      }
    } else {
      clearPeaksSubscription();
    }

    // Cleanup on unmount
    return () => {
      if (prevSubscriptionRef.current !== null) {
        sendCommand(peaks.unsubscribe());
        clearPeaksSubscription();
        prevSubscriptionRef.current = null;
      }
    };
  }, [
    subscriptionKey,
    options,
    connected,
    sendCommand,
    setPeaksSubscriptionRange,
    setPeaksSubscriptionGuids,
    clearPeaksSubscription,
    currentLOD,
  ]);

  // Effect 2: Debounced viewport updates (ONLY when LOD changes)
  // Pan at same zoom level doesn't send updates - only zoom that crosses LOD threshold
  useEffect(() => {
    // Skip if no active subscription or no viewport
    if (!connected || !options?.viewport || prevSubscriptionRef.current === null) {
      return;
    }

    // Skip if LOD hasn't changed - this is the key optimization!
    // Pan doesn't change LOD, so no updates sent during pan
    if (prevLODRef.current === currentLOD) {
      return;
    }

    // Clear any pending debounce
    if (viewportDebounceRef.current) {
      clearTimeout(viewportDebounceRef.current);
    }

    // Debounce viewport update (only sent when LOD changes)
    viewportDebounceRef.current = setTimeout(() => {
      if (options.viewport) {
        sendCommand(peaks.updateViewport(options.viewport));
        prevLODRef.current = currentLOD;
      }
      viewportDebounceRef.current = null;
    }, VIEWPORT_DEBOUNCE_MS);

    return () => {
      if (viewportDebounceRef.current) {
        clearTimeout(viewportDebounceRef.current);
        viewportDebounceRef.current = null;
      }
    };
  }, [currentLOD, options?.viewport, connected, sendCommand]);

  return {
    peaksByTrack: peaksByTrack || EMPTY_PEAKS_MAP,
    getPeaksForTrack,
    getPeaksForItem,
  };
}
