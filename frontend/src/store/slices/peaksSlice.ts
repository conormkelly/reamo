/**
 * Peaks state slice
 * Manages subscribed peak data from backend for multi-track waveform rendering
 *
 * Peaks are pushed by the backend when:
 * 1. Client subscribes to tracks (force_broadcast)
 * 2. Track items change (move, resize, take switch, etc.)
 *
 * Supports two subscription modes:
 * - Range mode: subscribe to track indices [start, end] (for sequential bank navigation)
 * - GUID mode: subscribe to specific track GUIDs (for filtered/custom bank views)
 *
 * Data is stored in a track-keyed map for O(1) lookup:
 *   peaksByTrack: Map<trackIdx, Map<itemGuid, WSItemPeaks>>
 */

import type { StateCreator } from 'zustand';
import type { WSItemPeaks, PeaksEventPayload } from '../../core/WebSocketTypes';

/** Subscription mode for peaks */
export type PeaksSubscriptionMode = 'range' | 'guids' | null;

export interface PeaksSlice {
  // Subscription state
  /** Current subscription mode */
  peaksSubscriptionMode: PeaksSubscriptionMode;
  /** Range subscription bounds (when mode = 'range') */
  peaksSubscribedRange: { start: number; end: number } | null;
  /** GUID list (when mode = 'guids') */
  peaksSubscribedGuids: string[] | null;

  // Data state - keyed by track index for efficient per-lane lookup
  /** Map from track index → (itemGuid → peaks data) */
  peaksByTrack: Map<number, Map<string, WSItemPeaks>>;

  // Actions
  /** Set range subscription state */
  setPeaksSubscriptionRange: (start: number, end: number) => void;
  /** Set GUID subscription state */
  setPeaksSubscriptionGuids: (guids: string[]) => void;
  /** Handle incoming peaks event (track-keyed map format) */
  handlePeaksEvent: (payload: PeaksEventPayload) => void;
  /** Clear all peaks data and subscription (called on unsubscribe) */
  clearPeaksSubscription: () => void;

  // Selectors (helpers for components)
  /** Get peaks for a specific track by index */
  getPeaksForTrack: (trackIdx: number) => Map<string, WSItemPeaks> | undefined;
  /** Get peaks for a specific item */
  getPeaksForItem: (trackIdx: number, itemGuid: string) => WSItemPeaks | undefined;
}

export const createPeaksSlice: StateCreator<PeaksSlice, [], [], PeaksSlice> = (set, get) => ({
  // Initial state
  peaksSubscriptionMode: null,
  peaksSubscribedRange: null,
  peaksSubscribedGuids: null,
  peaksByTrack: new Map(),

  // Actions
  setPeaksSubscriptionRange: (start, end) =>
    set({
      peaksSubscriptionMode: 'range',
      peaksSubscribedRange: { start, end },
      peaksSubscribedGuids: null,
      // Don't clear data - let the event handler update it
    }),

  setPeaksSubscriptionGuids: (guids) =>
    set({
      peaksSubscriptionMode: 'guids',
      peaksSubscribedRange: null,
      peaksSubscribedGuids: guids,
      // Don't clear data - let the event handler update it
    }),

  handlePeaksEvent: (payload) =>
    set((state) => {
      // Parse the track-keyed map from the event
      const newPeaksByTrack = new Map<number, Map<string, WSItemPeaks>>();

      // Copy existing data for tracks not in this event (LRU cache behavior)
      for (const [trackIdx, items] of state.peaksByTrack) {
        newPeaksByTrack.set(trackIdx, items);
      }

      // Update with new data from event
      for (const [trackIdxStr, trackData] of Object.entries(payload.tracks)) {
        const trackIdx = parseInt(trackIdxStr, 10);
        if (isNaN(trackIdx)) continue;

        const itemsMap = new Map<string, WSItemPeaks>();
        for (const item of trackData.items) {
          itemsMap.set(item.itemGuid, item);
        }
        newPeaksByTrack.set(trackIdx, itemsMap);
      }

      return { peaksByTrack: newPeaksByTrack };
    }),

  clearPeaksSubscription: () =>
    set({
      peaksSubscriptionMode: null,
      peaksSubscribedRange: null,
      peaksSubscribedGuids: null,
      peaksByTrack: new Map(),
    }),

  // Selectors
  getPeaksForTrack: (trackIdx) => get().peaksByTrack.get(trackIdx),

  getPeaksForItem: (trackIdx, itemGuid) => {
    const trackPeaks = get().peaksByTrack.get(trackIdx);
    return trackPeaks?.get(itemGuid);
  },
});
