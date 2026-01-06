/**
 * Meter Subscription Hook
 * Subscribes to meter updates for visible track indices only.
 * Debounces updates to avoid excessive subscription churn during scroll.
 */

import { useEffect, useRef, useCallback } from 'react';
import { useReaperStore } from '../store';
import { meter, type WSCommand } from '../core/WebSocketCommands';

export interface UseMeterSubscriptionOptions {
  /** Debounce delay in ms (default: 150) */
  debounceMs?: number;
  /** Whether subscriptions are enabled (default: true) */
  enabled?: boolean;
  /** Function to send commands (from useReaperConnection) */
  sendCommand?: (cmd: WSCommand) => void;
}

/**
 * Subscribe to meter updates for the specified track indices.
 *
 * Usage:
 * ```tsx
 * const { sendCommand, connected } = useReaperConnection();
 * const visibleTracks = [0, 1, 2, 5, 6]; // from virtualized list
 * useMeterSubscription(visibleTracks, { sendCommand });
 * ```
 *
 * The hook will:
 * - Debounce subscription updates (default 150ms)
 * - Send meter/subscribe when visible tracks change
 * - Send meter/unsubscribe on unmount
 * - Skip subscription if not connected or no sendCommand provided
 */
export function useMeterSubscription(
  trackIndices: number[],
  options: UseMeterSubscriptionOptions = {}
): void {
  const { debounceMs = 150, enabled = true, sendCommand } = options;

  const connected = useReaperStore((state) => state.connected);

  // Track previous indices to detect changes
  const prevIndicesRef = useRef<number[]>([]);
  const debounceTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const mountedRef = useRef(true);
  const wasConnectedRef = useRef(false);

  // Compare arrays (order-insensitive)
  const arraysEqual = useCallback((a: number[], b: number[]): boolean => {
    if (a.length !== b.length) return false;
    const sortedA = [...a].sort((x, y) => x - y);
    const sortedB = [...b].sort((x, y) => x - y);
    return sortedA.every((v, i) => v === sortedB[i]);
  }, []);

  // Send subscription update
  const sendSubscription = useCallback(
    (indices: number[]) => {
      if (!connected || !mountedRef.current || !sendCommand) return;
      sendCommand(meter.subscribe(indices));
      prevIndicesRef.current = indices;
    },
    [connected, sendCommand]
  );

  // Debounced subscription update
  useEffect(() => {
    if (!enabled) return;

    // Clear any pending debounce
    if (debounceTimerRef.current) {
      clearTimeout(debounceTimerRef.current);
      debounceTimerRef.current = null;
    }

    // Skip if indices haven't changed
    if (arraysEqual(trackIndices, prevIndicesRef.current)) {
      return;
    }

    // Debounce the subscription update
    debounceTimerRef.current = setTimeout(() => {
      sendSubscription(trackIndices);
    }, debounceMs);

    return () => {
      if (debounceTimerRef.current) {
        clearTimeout(debounceTimerRef.current);
        debounceTimerRef.current = null;
      }
    };
  }, [trackIndices, enabled, debounceMs, arraysEqual, sendSubscription]);

  // Re-subscribe when connection is established
  useEffect(() => {
    const justConnected = connected && !wasConnectedRef.current;
    wasConnectedRef.current = connected;

    // Only send on reconnect, not on every trackIndices change
    if (justConnected && enabled && trackIndices.length > 0 && sendCommand) {
      // Send directly to avoid stale closure in sendSubscription
      sendCommand(meter.subscribe(trackIndices));
      prevIndicesRef.current = trackIndices;
    }
  }, [connected, enabled, trackIndices, sendCommand]);

  // Unsubscribe on unmount
  useEffect(() => {
    mountedRef.current = true;

    return () => {
      mountedRef.current = false;
      // Clear any pending debounce
      if (debounceTimerRef.current) {
        clearTimeout(debounceTimerRef.current);
      }
      // Unsubscribe - the backend will also clean up on disconnect,
      // but explicit unsubscribe is cleaner for component unmount
      if (connected && sendCommand) {
        sendCommand(meter.unsubscribe());
      }
    };
  }, [connected, sendCommand]);
}

/**
 * Helper to calculate visible track indices from a virtualized list.
 *
 * @param startIndex - First visible item index
 * @param endIndex - Last visible item index (exclusive)
 * @param buffer - Extra items to include beyond visible range (default: 5)
 * @param maxTracks - Total number of tracks
 * @returns Array of track indices to subscribe to
 */
export function getVisibleTrackIndices(
  startIndex: number,
  endIndex: number,
  buffer: number = 5,
  maxTracks: number
): number[] {
  const start = Math.max(0, startIndex - buffer);
  const end = Math.min(maxTracks, endIndex + buffer);

  const indices: number[] = [];
  for (let i = start; i < end; i++) {
    indices.push(i);
  }
  return indices;
}
