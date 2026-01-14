/**
 * Markers state slice
 * Manages project markers for timeline display and navigation
 *
 * Mutual exclusion: selecting a marker clears item selection (and vice versa)
 */

import type { StateCreator } from 'zustand';
import type { Marker } from '../../core/types';
import type { ItemsSlice } from './itemsSlice';

// Combined slice type for mutual exclusion access
type StoreWithItems = MarkersSlice & ItemsSlice;

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

export const createMarkersSlice: StateCreator<StoreWithItems, [], [], MarkersSlice> = (
  set,
  get
) => ({
  // Initial state
  markers: [],
  selectedMarkerId: null,
  pendingMarkerEdits: null,
  isMarkerLocked: false,

  // Actions
  setMarkers: (markers) => set({ markers }),
  clearMarkers: () => set({ markers: [] }),
  setSelectedMarkerId: (id) => {
    // Mutual exclusion: clear item selection when selecting a marker (if not null)
    if (id !== null) {
      get().clearItemSelection();
    }
    set({ selectedMarkerId: id });
  },
  setPendingMarkerEdits: (edits) => set({ pendingMarkerEdits: edits }),
  setMarkerLocked: (locked) => set({ isMarkerLocked: locked }),
});
