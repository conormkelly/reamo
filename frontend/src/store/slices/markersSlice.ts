/**
 * Markers state slice
 * Manages project markers for timeline display and navigation
 */

import type { StateCreator } from 'zustand';
import type { Marker } from '../../core/types';

export interface PendingMarkerEdits {
  name?: string;
  color?: number;
}

export interface MarkersSlice {
  // State
  markers: Marker[];

  // Selected marker state (for MarkerInfoBar)
  selectedMarkerId: number | null;
  pendingMarkerEdits: PendingMarkerEdits | null;
  isMarkerLocked: boolean; // Locks auto-advance during editing

  // Actions
  setMarkers: (markers: Marker[]) => void;
  clearMarkers: () => void;
  setSelectedMarkerId: (id: number | null) => void;
  setPendingMarkerEdits: (edits: PendingMarkerEdits | null) => void;
  setMarkerLocked: (locked: boolean) => void;
}

export const createMarkersSlice: StateCreator<MarkersSlice> = (set) => ({
  // Initial state
  markers: [],
  selectedMarkerId: null,
  pendingMarkerEdits: null,
  isMarkerLocked: false,

  // Actions
  setMarkers: (markers) => set({ markers }),
  clearMarkers: () => set({ markers: [] }),
  setSelectedMarkerId: (id) => set({ selectedMarkerId: id }),
  setPendingMarkerEdits: (edits) => set({ pendingMarkerEdits: edits }),
  setMarkerLocked: (locked) => set({ isMarkerLocked: locked }),
});
