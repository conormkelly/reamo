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
  selectedItemKey: string | null; // "{trackIdx}:{itemIdx}" format
  selectedTrackIdx: number | null; // Track filter for Items Mode view

  // Actions
  setItems: (items: WSItem[]) => void;
  selectItem: (trackIdx: number, itemIdx: number) => void;
  clearItemSelection: () => void;
  setSelectedTrack: (trackIdx: number | null) => void;
}

/**
 * Create a unique key for an item
 */
export function makeItemKey(trackIdx: number, itemIdx: number): string {
  return `${trackIdx}:${itemIdx}`;
}

/**
 * Parse an item key back to trackIdx and itemIdx
 */
export function parseItemKey(key: string): { trackIdx: number; itemIdx: number } | null {
  const parts = key.split(':');
  if (parts.length !== 2) return null;
  const trackIdx = parseInt(parts[0], 10);
  const itemIdx = parseInt(parts[1], 10);
  if (isNaN(trackIdx) || isNaN(itemIdx)) return null;
  return { trackIdx, itemIdx };
}

export const createItemsSlice: StateCreator<StoreWithMarkers, [], [], ItemsSlice> = (
  set,
  get
) => ({
  // Initial state
  items: [],
  selectedItemKey: null,
  selectedTrackIdx: null,

  // Actions
  setItems: (items) => set({ items }),

  selectItem: (trackIdx, itemIdx) => {
    // Mutual exclusion: clear marker selection when selecting an item
    get().setSelectedMarkerId(null);
    set({ selectedItemKey: makeItemKey(trackIdx, itemIdx) });
  },

  clearItemSelection: () => set({ selectedItemKey: null }),

  setSelectedTrack: (trackIdx) => set({ selectedTrackIdx: trackIdx }),
});
