/**
 * Region Edit state slice
 *
 * Simplified: manages timeline mode toggle and region selection only.
 * All region edits (create, update, delete) go directly to REAPER
 * via WebSocket commands. REAPER's native undo handles reversibility.
 */

import type { StateCreator } from 'zustand';

// Re-export types for consumers
export type { TimelineMode, RegionEditSlice } from './regionEditSlice.types';

import type { RegionEditSlice, RegionEditSharedState } from './regionEditSlice.types';

/** Combined store type for proper typing of get() */
type RegionEditStore = RegionEditSharedState & RegionEditSlice;

export const createRegionEditSlice: StateCreator<RegionEditStore, [], [], RegionEditSlice> = (set, get) => ({
  // Initial state
  timelineMode: 'navigate',
  selectedRegionIds: [],

  // Mode actions
  setTimelineMode: (mode) => {
    // When entering regions mode, auto-select the region at current playhead position
    let autoSelectedIds: number[] = [];
    if (mode === 'regions') {
      const { positionSeconds, regions } = get();

      // Find region containing the playhead (start <= position < end)
      const region = regions.find(
        (r) => r.start <= positionSeconds && positionSeconds < r.end
      );
      if (region) {
        autoSelectedIds = [region.id];
      }
    }

    set({ timelineMode: mode, selectedRegionIds: autoSelectedIds });
  },

  // Selection actions (all use region ID)
  selectRegion: (id) => set({ selectedRegionIds: [id] }),

  addToSelection: (id) => {
    const current = get().selectedRegionIds;
    if (!current.includes(id)) {
      set({ selectedRegionIds: [...current, id].sort((a, b) => a - b) });
    }
  },

  deselectRegion: (id) => {
    const current = get().selectedRegionIds;
    set({ selectedRegionIds: current.filter((i) => i !== id) });
  },

  clearSelection: () => set({ selectedRegionIds: [] }),

  isRegionSelected: (id) => get().selectedRegionIds.includes(id),
});
