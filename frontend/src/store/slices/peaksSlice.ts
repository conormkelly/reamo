/**
 * Peaks state slice
 * Manages subscribed peak data from backend
 *
 * Peaks are pushed by the backend when:
 * 1. Client subscribes to a track (force_broadcast)
 * 2. Track items change (move, resize, take switch, etc.)
 *
 * No loading states - data arrives via event push.
 */

import type { StateCreator } from 'zustand';
import type { WSItemPeaks } from '../../core/WebSocketTypes';

export interface PeaksSlice {
  // State
  /** Track GUID currently subscribed to (null if none) */
  subscribedTrackGuid: string | null;
  /** Map from itemGuid to peaks data */
  peaksData: Map<string, WSItemPeaks>;

  // Actions
  /** Set subscription state (called when subscription changes) */
  setSubscribedTrack: (trackGuid: string | null) => void;
  /** Handle incoming peaks event */
  setPeaksData: (trackGuid: string, items: WSItemPeaks[]) => void;
  /** Clear all peaks data (called on unsubscribe) */
  clearPeaksData: () => void;
}

export const createPeaksSlice: StateCreator<PeaksSlice, [], [], PeaksSlice> = (set) => ({
  // Initial state
  subscribedTrackGuid: null,
  peaksData: new Map(),

  // Actions
  setSubscribedTrack: (trackGuid) =>
    set({
      subscribedTrackGuid: trackGuid,
      // Clear data when subscription changes
      peaksData: new Map(),
    }),

  setPeaksData: (trackGuid, items) =>
    set((state) => {
      // Only update if this is for our current subscription
      if (state.subscribedTrackGuid !== trackGuid) {
        return state;
      }
      // Replace all peaks data for this track
      const newPeaksData = new Map<string, WSItemPeaks>();
      for (const item of items) {
        newPeaksData.set(item.itemGuid, item);
      }
      return { peaksData: newPeaksData };
    }),

  clearPeaksData: () =>
    set({
      subscribedTrackGuid: null,
      peaksData: new Map(),
    }),
});
