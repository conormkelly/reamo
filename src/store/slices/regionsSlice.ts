/**
 * Regions state slice
 * Manages project regions for navigation and display
 */

import type { StateCreator } from 'zustand';
import type { Region } from '../../core/types';

export interface RegionsSlice {
  // State
  regions: Region[];

  // Actions
  setRegions: (regions: Region[]) => void;
  clearRegions: () => void;
}

export const createRegionsSlice: StateCreator<RegionsSlice> = (set) => ({
  // Initial state
  regions: [],

  // Actions
  // Sort regions by start time to ensure consistent indexing with displayRegions
  setRegions: (regions) => set({ regions: [...regions].sort((a, b) => a.start - b.start) }),
  clearRegions: () => set({ regions: [] }),
});
