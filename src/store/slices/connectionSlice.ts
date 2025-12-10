/**
 * Connection state slice
 * Manages connection status to REAPER
 */

import type { StateCreator } from 'zustand';

export interface ConnectionSlice {
  // State
  connected: boolean;
  errorCount: number;
  lastError: string | null;

  // Actions
  setConnected: (connected: boolean) => void;
  setErrorCount: (count: number) => void;
  setLastError: (error: string | null) => void;
  updateConnectionStatus: (connected: boolean, errorCount: number) => void;
}

export const createConnectionSlice: StateCreator<ConnectionSlice> = (set) => ({
  // Initial state
  connected: false,
  errorCount: 0,
  lastError: null,

  // Actions
  setConnected: (connected) => set({ connected }),
  setErrorCount: (errorCount) => set({ errorCount }),
  setLastError: (lastError) => set({ lastError }),
  updateConnectionStatus: (connected, errorCount) =>
    set({ connected, errorCount }),
});
