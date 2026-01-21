/**
 * usePeaksSubscription Hook - TILE-BASED LOD VERSION
 *
 * Subscribes to tile-based peaks data for multiple tracks via WebSocket.
 * Backend sends tiles at appropriate LOD based on viewport zoom level.
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
 * function TimelineWaveforms({ range, viewport }: Props) {
 *   const { assemblePeaksForViewport, hasTilesForTake, currentLod } = usePeaksSubscription({
 *     range,
 *     viewport,
 *   });
 *
 *   // For each item, get assembled peaks
 *   const peaks = assemblePeaksForViewport(
 *     item.activeTakeGuid,
 *     item.position,
 *     item.length
 *   );
 * }
 * ```
 */

import { useEffect, useRef, useCallback } from 'react';
import { useReaper } from '../components/ReaperProvider';
import { useReaperStore } from '../store';
import { peaks, type PeaksViewport } from '../core/WebSocketCommands';
import type { LODLevel, StereoPeak, MonoPeak } from '../core/WebSocketTypes';
import { calculateLODFromViewport } from '../core/WebSocketTypes';

// Re-export for consumers
export type { PeaksViewport };

/** Default number of peaks per item (for timeline blobs, fallback when no viewport) */
const DEFAULT_SAMPLE_COUNT = 30;

/** Debounce delay for viewport updates (ms) - per architecture doc */
const VIEWPORT_DEBOUNCE_MS = 200;

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

/** Return value from usePeaksSubscription - TILE-BASED API */
export interface UsePeaksSubscriptionResult {
  /** Current LOD level (0-7, see docs/architecture/LOD_LEVELS.md) */
  currentLod: LODLevel;

  /**
   * Assemble peaks for an item within the current viewport.
   * Concatenates tiles that overlap the visible range.
   * @param takeGuid - The active take GUID (from item.activeTakeGuid)
   * @param itemPosition - Item start position in project time (seconds)
   * @param itemLength - Item length (seconds)
   * @returns Assembled peaks array, or null if no tiles available
   */
  assemblePeaksForViewport: (
    takeGuid: string,
    itemPosition: number,
    itemLength: number
  ) => StereoPeak[] | MonoPeak[] | null;

  /**
   * Check if any tiles exist for a take at the current LOD
   * @param takeGuid - The active take GUID
   * @returns true if tiles are cached for this take
   */
  hasTilesForTake: (takeGuid: string) => boolean;

  /** Number of tiles in cache (for debugging/status) */
  tileCacheSize: number;
}

/**
 * Hook to subscribe to tile-based peaks for multiple tracks
 *
 * @param options - Subscription options (range or guids mode)
 * @returns Object with tile-aware peak accessors
 */
export function usePeaksSubscription(
  options: UsePeaksSubscriptionOptions | null
): UsePeaksSubscriptionResult {
  const { sendCommand, connected } = useReaper();
  const setPeaksSubscriptionRange = useReaperStore((s) => s.setPeaksSubscriptionRange);
  const setPeaksSubscriptionGuids = useReaperStore((s) => s.setPeaksSubscriptionGuids);
  const clearPeaksSubscription = useReaperStore((s) => s.clearPeaksSubscription);
  const currentLod = useReaperStore((s) => s.currentLod);
  const tileCache = useReaperStore((s) => s.tileCache);
  const storeHasTilesForTake = useReaperStore((s) => s.hasTilesForTake);
  const storeAssemblePeaksForViewport = useReaperStore((s) => s.assemblePeaksForViewport);

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

  // Calculate current LOD from viewport
  const calculatedLOD = options?.viewport
    ? calculateLODFromViewport(options.viewport.start, options.viewport.end, options.viewport.widthPx)
    : null;

  // Use refs to access current values without adding to deps
  const optionsRef = useRef(options);
  optionsRef.current = options;
  const calculatedLODRef = useRef(calculatedLOD);
  calculatedLODRef.current = calculatedLOD;

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
    const currentOptions = optionsRef.current;
    if (currentOptions) {
      const sampleCount = currentOptions.sampleCount ?? DEFAULT_SAMPLE_COUNT;

      if (currentOptions.range) {
        setPeaksSubscriptionRange(currentOptions.range.start, currentOptions.range.end);
        sendCommand(
          peaks.subscribe({
            range: currentOptions.range,
            sampleCount,
            viewport: currentOptions.viewport,
          })
        );
        prevLODRef.current = calculatedLODRef.current;
      } else if (currentOptions.guids && currentOptions.guids.length > 0) {
        setPeaksSubscriptionGuids(currentOptions.guids);
        sendCommand(
          peaks.subscribe({
            guids: currentOptions.guids,
            sampleCount,
            viewport: currentOptions.viewport,
          })
        );
        prevLODRef.current = calculatedLODRef.current;
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
    connected,
    sendCommand,
    setPeaksSubscriptionRange,
    setPeaksSubscriptionGuids,
    clearPeaksSubscription,
  ]);

  // Viewport key for change detection (bounds + width)
  const viewportKey = options?.viewport
    ? `${options.viewport.start.toFixed(2)}-${options.viewport.end.toFixed(2)}-${options.viewport.widthPx}`
    : null;
  const prevViewportKeyRef = useRef<string | null>(null);

  // Effect 2: Debounced viewport updates (on ANY viewport change, not just LOD)
  // Backend needs updated bounds to generate tiles for expanded/shifted viewport.
  useEffect(() => {
    // Skip if no active subscription or no viewport
    if (!connected || !options?.viewport || prevSubscriptionRef.current === null) {
      return;
    }

    // Skip if viewport hasn't changed
    if (prevViewportKeyRef.current === viewportKey) {
      return;
    }

    // Clear any pending debounce
    if (viewportDebounceRef.current) {
      clearTimeout(viewportDebounceRef.current);
    }

    // Debounce viewport update
    viewportDebounceRef.current = setTimeout(() => {
      if (options.viewport) {
        sendCommand(peaks.updateViewport(options.viewport));
        prevViewportKeyRef.current = viewportKey;
        prevLODRef.current = calculatedLOD;
      }
      viewportDebounceRef.current = null;
    }, VIEWPORT_DEBOUNCE_MS);

    return () => {
      if (viewportDebounceRef.current) {
        clearTimeout(viewportDebounceRef.current);
        viewportDebounceRef.current = null;
      }
    };
  }, [viewportKey, calculatedLOD, options?.viewport, connected, sendCommand]);

  // Wrap the store's assemblePeaksForViewport to include current viewport
  const assemblePeaksForViewport = useCallback(
    (takeGuid: string, itemPosition: number, itemLength: number) => {
      if (!options?.viewport) return null;
      return storeAssemblePeaksForViewport(
        takeGuid,
        itemPosition,
        itemLength,
        options.viewport.start,
        options.viewport.end
      );
    },
    [storeAssemblePeaksForViewport, options?.viewport]
  );

  return {
    currentLod,
    assemblePeaksForViewport,
    hasTilesForTake: storeHasTilesForTake,
    tileCacheSize: tileCache.size,
  };
}
