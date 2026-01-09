/**
 * Meter Subscription Hook
 * @deprecated Use useTrackSubscription instead. Metering now follows track subscriptions.
 *
 * This hook is a no-op stub for backward compatibility during migration.
 * It will be removed in a future version.
 *
 * @example
 * ```tsx
 * // DON'T use this hook - it's deprecated and does nothing
 * // useMeterSubscription([0, 1, 2], { sendCommand });
 *
 * // DO use useTrackSubscription instead:
 * useTrackSubscription(
 *   { mode: 'range', start: 0, end: 15 },
 *   { sendCommand, includeMaster: true }
 * );
 * ```
 */

import { useEffect } from 'react';
import type { WSCommand } from '../core/WebSocketCommands';

export interface UseMeterSubscriptionOptions {
  /** Debounce delay in ms (default: 150) */
  debounceMs?: number;
  /** Whether subscriptions are enabled (default: true) */
  enabled?: boolean;
  /** Function to send commands (from useReaperConnection) */
  sendCommand?: (cmd: WSCommand) => void;
}

/**
 * @deprecated Use useTrackSubscription instead. Metering now follows track subscriptions.
 *
 * This hook is a no-op stub. The meter/subscribe command no longer exists.
 * Use useTrackSubscription which handles both track data and meters.
 */
export function useMeterSubscription(
  _trackIndices: number[],
  _options: UseMeterSubscriptionOptions = {}
): void {
  // Log deprecation warning once per component mount
  useEffect(() => {
    console.warn(
      '[useMeterSubscription] DEPRECATED: This hook is a no-op. ' +
        'Use useTrackSubscription instead. Metering now follows track subscriptions automatically.'
    );
  }, []);
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
