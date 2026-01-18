/**
 * Markers state slice
 * Manages project markers for timeline display and navigation
 *
 * Contextual info bar: Marker selection is a transient overlay.
 * Item selection persists underneath - when marker is dismissed, item info restores.
 * Tapping an item clears marker selection (handled in Timeline.tsx).
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

export const createMarkersSlice: StateCreator<MarkersSlice, [], [], MarkersSlice> = (
  set
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
    // Marker selection is a transient overlay - does NOT clear item selection
    // Item selection persists underneath and is restored when marker is dismissed
    set({ selectedMarkerId: id });
  },
  setPendingMarkerEdits: (edits) => set({ pendingMarkerEdits: edits }),
  setMarkerLocked: (locked) => set({ isMarkerLocked: locked }),
});
