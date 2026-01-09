/**
 * Virtualized Track Subscription Hook
 * Bridges the virtualizer viewport to track subscriptions.
 * Calculates subscription ranges from visible virtual items with buffer expansion.
 *
 * @example
 * ```tsx
 * const virtualizer = useVirtualizer({ ... });
 * const virtualItems = virtualizer.getVirtualItems();
 *
 * useVirtualizedSubscription({
 *   visibleStart: virtualItems[0]?.index ?? 0,
 *   visibleEnd: virtualItems[virtualItems.length - 1]?.index ?? 0,
 *   totalTracks,
 *   filteredSkeleton,
 *   filterActive: !!filter.trim(),
 *   includeMaster: true,
 *   sendCommand,
 * });
 * ```
 */

import { useEffect, useRef, useCallback } from 'react';
import { useReaperStore } from '../store';
import { track, type WSCommand } from '../core/WebSocketCommands';
import type { SkeletonTrackWithIndex } from './useTrackSkeleton';

export interface UseVirtualizedSubscriptionOptions {
  /** First visible virtual item index */
  visibleStart: number;
  /** Last visible virtual item index */
  visibleEnd: number;
  /** Total number of tracks (for clamping) */
  totalTracks: number;
  /** Filtered skeleton with GUIDs (from filterByName) */
  filteredSkeleton: SkeletonTrackWithIndex[];
  /** Whether filter is active */
  filterActive: boolean;
  /** Whether master is included in virtualized list (affects index mapping) */
  includeMaster: boolean;
  /** Function to send commands */
  sendCommand: (cmd: WSCommand) => void;
  /** Buffer beyond visible items for subscription (default: 30) */
  subscriptionBuffer?: number;
  /** Debounce delay in ms (default: 200) */
  debounceMs?: number;
}

/**
 * Subscribe to tracks based on virtualizer viewport position.
 *
 * This hook:
 * - Calculates subscription range from visible indices + buffer
 * - Switches between range mode (no filter) and GUID mode (with filter)
 * - Debounces updates to prevent subscription storms during scroll
 * - Always includes master track
 *
 * Usage:
 * ```tsx
 * useVirtualizedSubscription({
 *   visibleStart: virtualItems[0]?.index ?? 0,
 *   visibleEnd: virtualItems[virtualItems.length - 1]?.index ?? 0,
 *   totalTracks,
 *   filteredSkeleton,
 *   filterActive: !!filter.trim(),
 *   sendCommand,
 * });
 * ```
 */
export function useVirtualizedSubscription(
  options: UseVirtualizedSubscriptionOptions
): void {
  const {
    visibleStart,
    visibleEnd,
    totalTracks,
    filteredSkeleton,
    filterActive,
    includeMaster,
    sendCommand,
    subscriptionBuffer = 30,
    debounceMs = 200,
  } = options;

  const connected = useReaperStore((state) => state.connected);
  const debounceTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const prevSubscriptionRef = useRef<string | null>(null);
  const wasConnectedRef = useRef(false);

  // Build subscription key for change detection
  const buildSubscriptionKey = useCallback((): string => {
    if (filterActive) {
      // GUID mode: use visible GUIDs from filtered skeleton
      const startIdx = Math.max(0, visibleStart - subscriptionBuffer);
      const endIdx = Math.min(filteredSkeleton.length - 1, visibleEnd + subscriptionBuffer);
      const guids = filteredSkeleton
        .slice(startIdx, endIdx + 1)
        .filter((t) => t.g !== 'master')
        .map((t) => t.g);
      return `guids:${guids.sort().join(',')}`;
    } else {
      // Range mode: calculate track indices from virtual indices
      // When includeMaster: virtual 0 = track 0, virtual 1 = track 1
      // When !includeMaster: virtual 0 = track 1, virtual 1 = track 2
      const offset = includeMaster ? 0 : 1;
      const subStart = Math.max(1, visibleStart + offset - subscriptionBuffer);
      const subEnd = Math.min(totalTracks, visibleEnd + offset + subscriptionBuffer);
      return `range:${subStart}-${subEnd}:master=${includeMaster}`;
    }
  }, [visibleStart, visibleEnd, totalTracks, filteredSkeleton, filterActive, subscriptionBuffer, includeMaster]);

  // Send subscription command
  const sendSubscription = useCallback(() => {
    if (!connected || !sendCommand) return;

    if (filterActive) {
      // GUID mode - for filtered views
      const startIdx = Math.max(0, visibleStart - subscriptionBuffer);
      const endIdx = Math.min(
        Math.max(0, filteredSkeleton.length - 1),
        visibleEnd + subscriptionBuffer
      );
      const guids =
        filteredSkeleton.length > 0
          ? filteredSkeleton
              .slice(startIdx, endIdx + 1)
              .filter((t) => t.g !== 'master')
              .map((t) => t.g)
          : [];

      sendCommand(
        track.subscribe({
          guids,
          includeMaster: true,
        })
      );
    } else {
      // Range mode: calculate track indices from virtual indices
      // When includeMaster: virtual 0 = track 0, virtual 1 = track 1
      // When !includeMaster: virtual 0 = track 1, virtual 1 = track 2
      const offset = includeMaster ? 0 : 1;
      const subStart = Math.max(1, visibleStart + offset - subscriptionBuffer);
      const subEnd = Math.min(totalTracks, visibleEnd + offset + subscriptionBuffer);

      // Always send subscription - even if no user tracks, we need master track data
      sendCommand(
        track.subscribe({
          range: { start: subStart, end: Math.max(subEnd, subStart) },
          includeMaster: true,
        })
      );
    }
  }, [
    connected,
    sendCommand,
    visibleStart,
    visibleEnd,
    totalTracks,
    filteredSkeleton,
    filterActive,
    includeMaster,
    subscriptionBuffer,
  ]);

  // Debounced subscription update
  useEffect(() => {
    const subscriptionKey = buildSubscriptionKey();

    // Skip if subscription hasn't changed
    if (subscriptionKey === prevSubscriptionRef.current) {
      return;
    }

    // Clear any pending debounce
    if (debounceTimerRef.current) {
      clearTimeout(debounceTimerRef.current);
    }

    // Debounce the subscription update
    debounceTimerRef.current = setTimeout(() => {
      sendSubscription();
      prevSubscriptionRef.current = subscriptionKey;
    }, debounceMs);

    return () => {
      if (debounceTimerRef.current) {
        clearTimeout(debounceTimerRef.current);
      }
    };
  }, [buildSubscriptionKey, sendSubscription, debounceMs]);

  // Re-subscribe when connection is established
  useEffect(() => {
    const justConnected = connected && !wasConnectedRef.current;
    wasConnectedRef.current = connected;

    if (justConnected) {
      // Send immediately on reconnect
      sendSubscription();
      prevSubscriptionRef.current = buildSubscriptionKey();
    }
  }, [connected, sendSubscription, buildSubscriptionKey]);

  // Clear debounce timer on unmount (but don't unsubscribe - new subscription replaces old)
  // Unsubscribing causes data gaps and fader jumps when toggling modes
  useEffect(() => {
    return () => {
      if (debounceTimerRef.current) {
        clearTimeout(debounceTimerRef.current);
      }
    };
  }, []);
}
