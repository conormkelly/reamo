/**
 * Type definitions for region editing state
 *
 * Simplified: regions mode provides mode toggle + selection only.
 * All edits go directly to REAPER via WebSocket commands.
 */

import type { Region } from '../../core/types';

/**
 * Properties from other slices that RegionEditSlice needs access to.
 * Used to properly type the StateCreator so get() returns the correct type.
 */
export interface RegionEditSharedState {
  positionSeconds: number;
  regions: Region[];
}

/** Timeline mode: navigate (default) or regions (selection + editing) */
export type TimelineMode = 'navigate' | 'regions';

export interface RegionEditSlice {
  // Mode state
  timelineMode: TimelineMode;

  // Selection state (region IDs, not array indices)
  selectedRegionIds: number[];

  // Mode actions
  setTimelineMode: (mode: TimelineMode) => void;

  // Selection actions (all use region ID, not array index)
  selectRegion: (id: number) => void;
  addToSelection: (id: number) => void;
  deselectRegion: (id: number) => void;
  clearSelection: () => void;
  isRegionSelected: (id: number) => boolean;
}
