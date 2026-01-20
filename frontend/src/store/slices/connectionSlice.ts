/**
 * Connection state slice
 * Manages connection status to REAPER
 *
 * Full connection status is exposed for UI (connecting, retrying, gave_up, etc.)
 * while `connected` boolean is kept for backward compatibility.
 */

import type { StateCreator } from 'zustand';
import type { ConnectionStatus } from '../../core/websocketMachine';

export interface ConnectionSlice {
  // State
  connected: boolean;
  connectionStatus: ConnectionStatus;
  retryCount: number;
  errorCount: number;
  lastError: string | null;
  /** True when a new version is available (PWA cache busting) */
  updateAvailable: boolean;

  // Actions
  setConnected: (connected: boolean) => void;
  setConnectionStatus: (status: ConnectionStatus) => void;
  setRetryCount: (count: number) => void;
  setErrorCount: (count: number) => void;
  setLastError: (error: string | null) => void;
  updateConnectionStatus: (connected: boolean, errorCount: number) => void;
  setUpdateAvailable: (available: boolean) => void;
}

export const createConnectionSlice: StateCreator<ConnectionSlice> = (set) => ({
  // Initial state
  connected: false,
  connectionStatus: 'idle',
  retryCount: 0,
  errorCount: 0,
  lastError: null,
  updateAvailable: false,

  // Actions
  setConnected: (connected) => set({ connected }),
  setConnectionStatus: (connectionStatus) => set({ connectionStatus }),
  setRetryCount: (retryCount) => set({ retryCount }),
  setErrorCount: (errorCount) => set({ errorCount }),
  setLastError: (lastError) => set({ lastError }),
  updateConnectionStatus: (connected, errorCount) =>
    set({ connected, errorCount }),
  setUpdateAvailable: (updateAvailable) => set({ updateAvailable }),
});
