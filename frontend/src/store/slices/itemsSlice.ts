/**
 * Items state slice
 * Manages project items and selection for Navigate/Items Mode
 *
 * Mutual exclusion: selecting an item clears marker selection (and vice versa)
 */

import type { StateCreator } from 'zustand';
import type { WSItem } from '../../core/WebSocketTypes';
import type { MarkersSlice } from './markersSlice';

// Combined slice type for mutual exclusion access
type StoreWithMarkers = ItemsSlice & MarkersSlice;

export interface ItemsSlice {
  // State
  items: WSItem[];
  selectedItemGuid: string | null; // Stable GUID for selected item
  selectedTrackIdx: number | null; // Track filter for Items Mode view

  // Actions
  setItems: (items: WSItem[]) => void;
  selectItem: (itemGuid: string) => void;
  clearItemSelection: () => void;
  setSelectedTrack: (trackIdx: number | null) => void;
}

export const createItemsSlice: StateCreator<StoreWithMarkers, [], [], ItemsSlice> = (
  set,
  get
) => ({
  // Initial state
  items: [],
  selectedItemGuid: null,
  selectedTrackIdx: null,

  // Actions
  setItems: (items) => set({ items }),

  selectItem: (itemGuid) => {
    // Mutual exclusion: clear marker selection when selecting an item
    get().setSelectedMarkerId(null);
    set({ selectedItemGuid: itemGuid });
  },

  clearItemSelection: () => set({ selectedItemGuid: null }),

  setSelectedTrack: (trackIdx) => set({ selectedTrackIdx: trackIdx }),
});
