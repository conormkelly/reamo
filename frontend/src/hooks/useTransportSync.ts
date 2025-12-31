/**
 * useTransportSync - Clock-synchronized transport display hook
 *
 * Provides ±15ms visual accuracy for beat indicators over WiFi.
 * Uses the TransportSyncEngine singleton for NTP-style clock sync.
 *
 * @example
 * function BeatIndicator() {
 *   const canvasRef = useRef<HTMLCanvasElement>(null);
 *
 *   useTransportSync((state) => {
 *     const ctx = canvasRef.current?.getContext('2d');
 *     if (!ctx) return;
 *     // Draw beat indicator based on state.phase (0-1)
 *     ctx.fillRect(0, 0, state.phase * 100, 10);
 *   });
 *
 *   return <canvas ref={canvasRef} />;
 * }
 */

import { useLayoutEffect } from 'react';
import {
  transportSyncEngine,
  type TransportSyncSubscriber,
  type TransportSyncState,
} from '../core/TransportSyncEngine';

export type { TransportSyncState, TransportSyncSubscriber };

/**
 * Subscribe to transport sync updates at 60fps.
 *
 * @param callback - Called with synchronized transport state on each frame.
 *                   Should update DOM directly via refs, not trigger React re-renders.
 * @param deps - Optional dependency array (callback is re-subscribed when deps change)
 */
export function useTransportSync(
  callback: TransportSyncSubscriber,
  deps: React.DependencyList = []
): void {
  useLayoutEffect(() => {
    return transportSyncEngine.subscribe(callback);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);
}

/**
 * Get a one-time snapshot of current transport sync state.
 * Useful for initialization or non-animated reads.
 */
export function getTransportSyncState(): TransportSyncState {
  return transportSyncEngine.getState();
}

/**
 * Check if clock is synchronized.
 */
export function isTransportSynced(): boolean {
  return transportSyncEngine.isSynced();
}

/**
 * Get sync metrics for debugging.
 */
export function getTransportSyncMetrics() {
  return transportSyncEngine.getMetrics();
}

/**
 * Force clock resync.
 */
export function resyncTransport(): void {
  transportSyncEngine.resync();
}
