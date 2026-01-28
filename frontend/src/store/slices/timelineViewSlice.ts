/**
 * Timeline View state slice
 * Manages timeline-specific view state like follow playhead mode, viewport position,
 * and selection mode toggle.
 *
 * SESSION-SCOPED: Viewport and selection mode state persists in memory across view
 * switches within a session. On project change or app restart, state resets to defaults.
 * This avoids complexity of per-project localStorage persistence.
 *
 * Note: The auto-enable on playback start logic is handled via a store subscription
 * in setupTimelineSubscriptions(), not via React effects. This follows zustand best
 * practices and avoids the "setState in effect" anti-pattern.
 */

import type { StateCreator } from 'zustand';

/** Viewport range in seconds */
export interface TimeRange {
  start: number;
  end: number;
}

/** Shared state from other slices that this slice needs access to */
export interface TimelineViewSharedState {
  playState: number;
  followPlayheadReEnable: 'on-playback' | 'explicit-only';
  projectName: string;
}

export interface TimelineViewSlice {
  // State - existing
  /** Whether the timeline viewport follows the playhead */
  followPlayhead: boolean;
  /** Track previous play state for detecting playback start */
  _prevPlayState: number;

  // State - viewport (session-scoped)
  /** Saved viewport range (null = use default/fit-to-project) */
  savedViewport: TimeRange | null;

  // State - selection mode (session-scoped)
  /** Whether selection mode is active (vs pan mode) in navigate timeline */
  selectionModeActive: boolean;

  // Actions - existing
  /** Set follow playhead mode */
  setFollowPlayhead: (follow: boolean) => void;
  /** Pause follow playhead (called when user pans) */
  pauseFollowPlayhead: () => void;
  /** Toggle follow playhead mode and snap to playhead if enabling */
  toggleFollowPlayhead: () => void;

  // Actions - viewport
  /** Save viewport range to persist across view switches */
  saveViewport: (range: TimeRange) => void;
  /** Clear saved viewport (resets to fit-to-project) */
  clearSavedViewport: () => void;

  // Actions - selection mode
  /** Set selection mode active state */
  setSelectionModeActive: (active: boolean) => void;
  /** Toggle selection mode */
  toggleSelectionMode: () => void;

  // Reset (called on project change)
  _resetTimelineViewState: () => void;
}

type TimelineViewStore = TimelineViewSharedState & TimelineViewSlice;

export const createTimelineViewSlice: StateCreator<TimelineViewStore, [], [], TimelineViewSlice> = (set, get) => ({
  // Initial state - existing
  followPlayhead: true, // Default: follow playhead
  _prevPlayState: 0,

  // Initial state - viewport
  savedViewport: null, // null = use default/fit-to-project

  // Initial state - selection mode
  selectionModeActive: false, // Default: pan mode

  // Actions - existing
  setFollowPlayhead: (follow) => set({ followPlayhead: follow }),

  pauseFollowPlayhead: () => {
    if (get().followPlayhead) {
      set({ followPlayhead: false });
    }
  },

  toggleFollowPlayhead: () => {
    set({ followPlayhead: !get().followPlayhead });
  },

  // Actions - viewport
  saveViewport: (range: TimeRange) => {
    set({ savedViewport: range });
  },

  clearSavedViewport: () => {
    set({ savedViewport: null });
  },

  // Actions - selection mode
  setSelectionModeActive: (active: boolean) => {
    set({ selectionModeActive: active });
  },

  toggleSelectionMode: () => {
    set({ selectionModeActive: !get().selectionModeActive });
  },

  // Reset (called on project change)
  _resetTimelineViewState: () => {
    set({
      savedViewport: null,
      selectionModeActive: false,
      // Note: followPlayhead is intentionally NOT reset - it's a user preference
    });
  },
});

/**
 * Setup store subscriptions for timeline view state.
 *
 * This must be called after the store is created (in store/index.ts or App.tsx).
 * The subscription handles:
 * 1. Auto-enable follow playhead on playback start (when preference is 'on-playback')
 * 2. Reset timeline view state when project changes
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

    // Detect project change - reset timeline view state for new project
    if (state.projectName !== prevState.projectName && state.projectName !== '') {
      store.getState()._resetTimelineViewState();
    }
  });
}
