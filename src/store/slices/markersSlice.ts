/**
 * Markers state slice
 * Manages project markers for timeline display and navigation
 */

import type { StateCreator } from 'zustand';
import type { Marker } from '../../core/types';

export interface MarkersSlice {
  // State
  markers: Marker[];

  // Actions
  setMarkers: (markers: Marker[]) => void;
  clearMarkers: () => void;
}

export const createMarkersSlice: StateCreator<MarkersSlice> = (set) => ({
  // Initial state
  markers: [],

  // Actions
  setMarkers: (markers) => set({ markers }),
  clearMarkers: () => set({ markers: [] }),
});
