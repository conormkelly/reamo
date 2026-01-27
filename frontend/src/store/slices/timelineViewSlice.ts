/**
 * Timeline View state slice
 * Manages timeline-specific view state like follow playhead mode
 *
 * Note: The auto-enable on playback start logic is handled via a store subscription
 * in setupTimelineSubscriptions(), not via React effects. This follows zustand best
 * practices and avoids the "setState in effect" anti-pattern.
 */

import type { StateCreator } from 'zustand';

/** Shared state from other slices that this slice needs access to */
export interface TimelineViewSharedState {
  playState: number;
  followPlayheadReEnable: 'on-playback' | 'explicit-only';
}

export interface TimelineViewSlice {
  // State
  /** Whether the timeline viewport follows the playhead */
  followPlayhead: boolean;
  /** Track previous play state for detecting playback start */
  _prevPlayState: number;

  // Actions
  /** Set follow playhead mode */
  setFollowPlayhead: (follow: boolean) => void;
  /** Pause follow playhead (called when user pans) */
  pauseFollowPlayhead: () => void;
  /** Toggle follow playhead mode and snap to playhead if enabling */
  toggleFollowPlayhead: () => void;
}

type TimelineViewStore = TimelineViewSharedState & TimelineViewSlice;

export const createTimelineViewSlice: StateCreator<TimelineViewStore, [], [], TimelineViewSlice> = (set, get) => ({
  // Initial state
  followPlayhead: true, // Default: follow playhead
  _prevPlayState: 0,

  // Actions
  setFollowPlayhead: (follow) => set({ followPlayhead: follow }),

  pauseFollowPlayhead: () => {
    if (get().followPlayhead) {
      set({ followPlayhead: false });
    }
  },

  toggleFollowPlayhead: () => {
    set({ followPlayhead: !get().followPlayhead });
  },
});

/**
 * Setup store subscription for auto-enabling follow playhead on playback start.
 *
 * This must be called after the store is created (in store/index.ts or App.tsx).
 * The subscription watches playState changes and enables follow when:
 * - playback starts (playState transitions from 0 to 1)
 * - user preference is 'on-playback'
 *
 * This approach avoids calling setState inside a React effect, which is flagged
 * by the react-hooks/set-state-in-effect ESLint rule.
 */
export function setupTimelineSubscriptions(store: {
  getState: () => TimelineViewStore;
  subscribe: (listener: (state: TimelineViewStore, prevState: TimelineViewStore) => void) => () => void;
}): () => void {
  return store.subscribe((state, prevState) => {
    // Detect playback start: not playing → playing
    const wasPlaying = prevState.playState === 1;
    const isPlaying = state.playState === 1;

    if (isPlaying && !wasPlaying && state.followPlayheadReEnable === 'on-playback') {
      // Auto-enable follow playhead on playback start
      store.getState().setFollowPlayhead(true);
    }
  });
}
