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

  // Actions
  setConnected: (connected: boolean) => void;
  setConnectionStatus: (status: ConnectionStatus) => void;
  setRetryCount: (count: number) => void;
  setErrorCount: (count: number) => void;
  setLastError: (error: string | null) => void;
  updateConnectionStatus: (connected: boolean, errorCount: number) => void;
}

export const createConnectionSlice: StateCreator<ConnectionSlice> = (set) => ({
  // Initial state
  connected: false,
  connectionStatus: 'idle',
  retryCount: 0,
  errorCount: 0,
  lastError: null,

  // Actions
  setConnected: (connected) => set({ connected }),
  setConnectionStatus: (connectionStatus) => set({ connectionStatus }),
  setRetryCount: (retryCount) => set({ retryCount }),
  setErrorCount: (errorCount) => set({ errorCount }),
  setLastError: (lastError) => set({ lastError }),
  updateConnectionStatus: (connected, errorCount) =>
    set({ connected, errorCount }),
});
