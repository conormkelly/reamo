/**
 * Time Selection Sync Hook
 *
 * LEGACY: This hook was used to sync REAPER's time selection via a cursor
 * movement workaround when using HTTP polling. With WebSocket, time selection
 * is provided directly in the transport event.
 *
 * This is now a no-op that maintains API compatibility.
 */

export interface UseTimeSelectionSyncReturn {
  /** Always false with WebSocket - no syncing needed */
  isSyncing: boolean;
}

/**
 * Hook that previously synced time selection via cursor hack.
 * Now a no-op since WebSocket provides time selection directly.
 */
export function useTimeSelectionSync(): UseTimeSelectionSyncReturn {
  return { isSyncing: false };
}
