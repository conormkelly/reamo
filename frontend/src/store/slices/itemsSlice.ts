/**
 * Items state slice
 * Manages project items for Navigate/Items Mode
 *
 * Selection model (multi-select):
 * - Selection is derived from items.filter(i => i.selected), not local state
 * - REAPER is source of truth for selection (polled at 5Hz)
 * - Use item/toggleSelect command to toggle selection (preserves other selections)
 * - Use item/select for single-select (clears others)
 * - Use item/unselectAll to clear all
 *
 * Item Selection Mode:
 * - Entered by tapping aggregate blobs on timeline
 * - Reveals individual items on filtered track for selection
 * - Track dropdown filters view (doesn't auto-select)
 * - Exited via X button or by clearing all selection
 *
 * View filter (viewFilterTrackGuid):
 * - Controls which track's items are shown with waveforms (vs grey blobs)
 * - Independent of selection - can view one track while having items selected across many
 * - Auto-set when entering item selection mode
 * - Changed via dropdown in info bar (filter only, no auto-select)
 * - Uses GUID for stability across track reordering
 *
 * Mutual exclusion: selecting an item clears marker selection (handled by components)
 */

import type { StateCreator } from 'zustand';
import type { WSItem } from '../../core/WebSocketTypes';
import type { MarkersSlice } from './markersSlice';

// Combined slice type for mutual exclusion access
type StoreWithMarkers = ItemsSlice & MarkersSlice;

export interface ItemsSlice {
  // State
  items: WSItem[];
  /**
   * Whether we're in item selection mode (showing individual items vs aggregate blobs).
   * Enter by tapping aggregate blob, exit via X button.
   */
  itemSelectionModeActive: boolean;
  /**
   * Track GUID for view filtering (which track's items show as waveforms).
   * - null: show aggregate grey blobs for all items
   * - GUID: show only that track's items (with waveforms), hide others
   * Uses GUID for stability across track reordering.
   */
  viewFilterTrackGuid: string | null;

  // Derived (computed from items, for convenience)
  // Note: These are getter functions, not stored state
  getSelectedItems: () => WSItem[];
  getSelectedItemGuid: () => string | null; // First selected item's GUID, for backwards compat

  // Actions
  setItems: (items: WSItem[]) => void;
  /** Enter item selection mode and set the view filter track. */
  enterItemSelectionMode: (trackGuid: string) => void;
  /** Exit item selection mode and clear the view filter. */
  exitItemSelectionMode: () => void;
  /** Set the view filter track by GUID. Pass null to clear filter (show all as grey blobs). */
  setViewFilterTrack: (trackGuid: string | null) => void;
  /**
   * @deprecated Use sendCommand(itemCmd.toggleSelect(guid)) directly from components.
   * Selection is now driven by REAPER's selection state, not local state.
   */
  clearItemSelection: () => void;
}

export const createItemsSlice: StateCreator<StoreWithMarkers, [], [], ItemsSlice> = (
  set,
  get
) => ({
  // Initial state
  items: [],
  itemSelectionModeActive: false,
  viewFilterTrackGuid: null,

  // Derived getters
  getSelectedItems: () => get().items.filter((i) => i.selected),
  getSelectedItemGuid: () => {
    const selected = get().items.filter((i) => i.selected);
    return selected.length === 1 ? selected[0].guid : null;
  },

  // Actions
  setItems: (items) => set({ items }),

  enterItemSelectionMode: (trackGuid) =>
    set({
      itemSelectionModeActive: true,
      viewFilterTrackGuid: trackGuid,
    }),

  exitItemSelectionMode: () =>
    set({
      itemSelectionModeActive: false,
      viewFilterTrackGuid: null,
    }),

  setViewFilterTrack: (trackGuid) => set({ viewFilterTrackGuid: trackGuid }),

  // Deprecated - selection is now managed by REAPER
  // This action is kept for backwards compat but does nothing
  // Use sendCommand(itemCmd.unselectAll()) to clear selection
  clearItemSelection: () => {
    // No-op: selection is driven by REAPER's item.selected field
    // Components should use sendCommand(itemCmd.unselectAll()) instead
  },
});
