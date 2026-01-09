/**
 * Track Subscription Hook
 * Subscribes to track updates (data + meters) for visible tracks.
 * Replaces the obsolete useMeterSubscription - metering now follows track subscriptions.
 *
 * Supports two modes:
 * - Range mode: { start, end } for scrolling mixer
 * - GUID mode: string[] for filtered/search views
 *
 * @example
 * ```tsx
 * // Range mode - for scrolling mixer
 * const { sendCommand } = useReaperConnection();
 * useTrackSubscription(
 *   { mode: 'range', start: 0, end: 15 },
 *   { sendCommand, includeMaster: true }
 * );
 *
 * // GUID mode - for filtered views
 * const filteredGuids = skeleton.filter(t => t.n.includes(query)).map(t => t.g);
 * useTrackSubscription(
 *   { mode: 'guids', guids: filteredGuids },
 *   { sendCommand, includeMaster: true }
 * );
 * ```
 */

import { useEffect, useRef, useCallback } from 'react';
import { useReaperStore } from '../store';
import { track, type WSCommand } from '../core/WebSocketCommands';

export interface UseTrackSubscriptionOptions {
  /** Debounce delay in ms (default: 150) */
  debounceMs?: number;
  /** Whether subscriptions are enabled (default: true) */
  enabled?: boolean;
  /** Include master track in subscription (default: false) */
  includeMaster?: boolean;
  /** Function to send commands (from useReaperConnection) */
  sendCommand?: (cmd: WSCommand) => void;
}

export type TrackSubscription =
  | { mode: 'range'; start: number; end: number }
  | { mode: 'guids'; guids: string[] };

/**
 * Subscribe to track updates for the specified range or GUIDs.
 *
 * Usage (range mode - for scrolling mixer):
 * ```tsx
 * const { sendCommand } = useReaperConnection();
 * useTrackSubscription(
 *   { mode: 'range', start: 0, end: 15 },
 *   { sendCommand, includeMaster: true }
 * );
 * ```
 *
 * Usage (GUID mode - for filtered views):
 * ```tsx
 * const filteredGuids = skeleton.filter(t => t.n.includes(query)).map(t => t.g);
 * useTrackSubscription(
 *   { mode: 'guids', guids: filteredGuids },
 *   { sendCommand, includeMaster: true }
 * );
 * ```
 *
 * The hook will:
 * - Debounce subscription updates (default 150ms)
 * - Send track/subscribe when subscription changes
 * - Send track/unsubscribe on unmount
 * - Re-subscribe on reconnection
 */
export function useTrackSubscription(
  subscription: TrackSubscription,
  options: UseTrackSubscriptionOptions = {}
): void {
  const { debounceMs = 150, enabled = true, includeMaster = false, sendCommand } = options;

  const connected = useReaperStore((state) => state.connected);

  // Track previous subscription to detect changes
  const prevSubscriptionRef = useRef<TrackSubscription | null>(null);
  const debounceTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const mountedRef = useRef(true);
  const wasConnectedRef = useRef(false);

  // Compare subscriptions
  const subscriptionsEqual = useCallback(
    (a: TrackSubscription | null, b: TrackSubscription): boolean => {
      if (!a) return false;
      if (a.mode !== b.mode) return false;

      if (a.mode === 'range' && b.mode === 'range') {
        return a.start === b.start && a.end === b.end;
      }

      if (a.mode === 'guids' && b.mode === 'guids') {
        if (a.guids.length !== b.guids.length) return false;
        const sortedA = [...a.guids].sort();
        const sortedB = [...b.guids].sort();
        return sortedA.every((v, i) => v === sortedB[i]);
      }

      return false;
    },
    []
  );

  // Send subscription command
  const sendSubscription = useCallback(
    (sub: TrackSubscription) => {
      if (!connected || !mountedRef.current || !sendCommand) {
        return;
      }

      if (sub.mode === 'range') {
        sendCommand(
          track.subscribe({
            range: { start: sub.start, end: sub.end },
            includeMaster,
          })
        );
      } else {
        sendCommand(
          track.subscribe({
            guids: sub.guids,
            includeMaster,
          })
        );
      }

      prevSubscriptionRef.current = sub;
    },
    [connected, sendCommand, includeMaster]
  );

  // Debounced subscription update
  useEffect(() => {
    if (!enabled) return;

    // Clear any pending debounce
    if (debounceTimerRef.current) {
      clearTimeout(debounceTimerRef.current);
      debounceTimerRef.current = null;
    }

    // Skip if subscription hasn't changed
    if (subscriptionsEqual(prevSubscriptionRef.current, subscription)) {
      return;
    }

    // Debounce the subscription update
    debounceTimerRef.current = setTimeout(() => {
      sendSubscription(subscription);
    }, debounceMs);

    return () => {
      if (debounceTimerRef.current) {
        clearTimeout(debounceTimerRef.current);
        debounceTimerRef.current = null;
      }
    };
  }, [subscription, enabled, debounceMs, subscriptionsEqual, sendSubscription]);

  // Re-subscribe when connection is established
  useEffect(() => {
    const justConnected = connected && !wasConnectedRef.current;
    wasConnectedRef.current = connected;

    if (justConnected && enabled && sendCommand) {
      // Send directly on reconnect
      if (subscription.mode === 'range') {
        sendCommand(
          track.subscribe({
            range: { start: subscription.start, end: subscription.end },
            includeMaster,
          })
        );
      } else if (subscription.guids.length > 0) {
        sendCommand(
          track.subscribe({
            guids: subscription.guids,
            includeMaster,
          })
        );
      }
      prevSubscriptionRef.current = subscription;
    }
  }, [connected, enabled, subscription, sendCommand, includeMaster]);

  // Unsubscribe on unmount
  useEffect(() => {
    mountedRef.current = true;

    return () => {
      mountedRef.current = false;
      // Clear any pending debounce
      if (debounceTimerRef.current) {
        clearTimeout(debounceTimerRef.current);
      }
      // Unsubscribe - backend also cleans up on disconnect,
      // but explicit unsubscribe is cleaner for component unmount
      if (connected && sendCommand) {
        sendCommand(track.unsubscribe());
      }
    };
  }, [connected, sendCommand]);
}

/**
 * Helper to create a range subscription from virtualizer bounds.
 *
 * @param startIndex - First visible item index
 * @param endIndex - Last visible item index
 * @param buffer - Extra items to include beyond visible range (default: 5)
 * @returns TrackSubscription in range mode
 */
export function createRangeSubscription(
  startIndex: number,
  endIndex: number,
  buffer: number = 5
): TrackSubscription {
  return {
    mode: 'range',
    start: Math.max(0, startIndex - buffer),
    end: endIndex + buffer,
  };
}
