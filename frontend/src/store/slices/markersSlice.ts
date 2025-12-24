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

  // Marker script detection (for name/color editing)
  markerScriptInstalled: boolean;
  markerScriptChecked: boolean;

  // Selected marker state (for MarkerInfoBar)
  selectedMarkerId: number | null;
  pendingMarkerEdits: PendingMarkerEdits | null;
  isMarkerLocked: boolean; // Locks auto-advance during editing

  // Actions
  setMarkers: (markers: Marker[]) => void;
  clearMarkers: () => void;
  setMarkerScriptInstalled: (installed: boolean) => void;
  setMarkerScriptChecked: (checked: boolean) => void;
  setSelectedMarkerId: (id: number | null) => void;
  setPendingMarkerEdits: (edits: PendingMarkerEdits | null) => void;
  setMarkerLocked: (locked: boolean) => void;
}

export const createMarkersSlice: StateCreator<MarkersSlice> = (set) => ({
  // Initial state
  markers: [],
  markerScriptInstalled: true, // WebSocket extension handles marker editing directly
  markerScriptChecked: true,
  selectedMarkerId: null,
  pendingMarkerEdits: null,
  isMarkerLocked: false,

  // Actions
  setMarkers: (markers) => set({ markers }),
  clearMarkers: () => set({ markers: [] }),
  setMarkerScriptInstalled: (installed) => set({ markerScriptInstalled: installed }),
  setMarkerScriptChecked: (checked) => set({ markerScriptChecked: checked }),
  setSelectedMarkerId: (id) => set({ selectedMarkerId: id }),
  setPendingMarkerEdits: (edits) => set({ pendingMarkerEdits: edits }),
  setMarkerLocked: (locked) => set({ isMarkerLocked: locked }),
});
