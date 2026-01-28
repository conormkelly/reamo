/**
 * View Filter state slice
 * Manages filter/bank state for Timeline and Mixer views.
 *
 * This slice ensures filter state (bank selection, search query, folder path) persists
 * when switching between views - a critical UX improvement for workflows that switch
 * frequently between Mixer and Timeline.
 *
 * SESSION-SCOPED: State persists in memory across view switches within a session.
 * On project change or app restart, state resets to defaults. This avoids complexity
 * of per-project localStorage persistence (storage limits, external project changes,
 * stale data from old projects).
 *
 * Pattern: Uses Record<ViewId, State> following secondaryPanelSlice.ts
 */

import type { StateCreator } from 'zustand';

/** Shared state from other slices that this slice needs access to */
export interface ViewFilterSharedState {
  projectName: string;
}

/** View identifiers that have filterable track lists */
export type FilterableViewId = 'timeline' | 'mixer';

/** Filter state for a single view */
export interface ViewFilterState {
  /** Selected bank ID (null = All Tracks, 'builtin:*' = built-in, string = custom) */
  selectedBankId: string | null;
  /** Text filter query */
  filterQuery: string;
  /** Current page within filtered results (0-indexed) */
  filterBankIndex: number;
  /** Folder navigation path (array of folder GUIDs for builtin:folders bank) */
  folderPath: string[];
}

/** Mixer-specific additional state */
export interface MixerViewState {
  /** Track index shown in landscape detail sheet */
  detailSheetTrackIdx: number | undefined;
}

/** Default filter state for a view */
const DEFAULT_FILTER_STATE: ViewFilterState = {
  selectedBankId: null,
  filterQuery: '',
  filterBankIndex: 0,
  folderPath: [],
};

/** Default mixer-specific state */
const DEFAULT_MIXER_STATE: MixerViewState = {
  detailSheetTrackIdx: undefined,
};

export interface ViewFilterSlice {
  // State: per-view filter state
  viewFilters: Record<FilterableViewId, ViewFilterState>;
  // Mixer-specific state (not duplicated per-view)
  mixerViewState: MixerViewState;

  // Actions - filter state
  setSelectedBankId: (viewId: FilterableViewId, bankId: string | null) => void;
  setFilterQuery: (viewId: FilterableViewId, query: string) => void;
  setFilterBankIndex: (viewId: FilterableViewId, index: number) => void;
  setFolderPath: (viewId: FilterableViewId, path: string[]) => void;
  resetViewFilter: (viewId: FilterableViewId) => void;

  // Actions - mixer-specific
  setDetailSheetTrackIdx: (idx: number | undefined) => void;

  // Reset all filters (called on project change)
  _resetAllViewFilters: () => void;
}

type ViewFilterStore = ViewFilterSharedState & ViewFilterSlice;

export const createViewFilterSlice: StateCreator<ViewFilterStore, [], [], ViewFilterSlice> = (set) => ({
  // Initial state
  viewFilters: {
    timeline: { ...DEFAULT_FILTER_STATE },
    mixer: { ...DEFAULT_FILTER_STATE },
  },
  mixerViewState: { ...DEFAULT_MIXER_STATE },

  // Actions
  setSelectedBankId: (viewId, bankId) => {
    set((state) => ({
      viewFilters: {
        ...state.viewFilters,
        [viewId]: {
          ...state.viewFilters[viewId],
          selectedBankId: bankId,
          // Reset filter bank index when bank changes (back to first page)
          filterBankIndex: 0,
        },
      },
    }));
  },

  setFilterQuery: (viewId, query) => {
    set((state) => ({
      viewFilters: {
        ...state.viewFilters,
        [viewId]: {
          ...state.viewFilters[viewId],
          filterQuery: query,
          // Reset filter bank index when query changes (back to first page)
          filterBankIndex: 0,
        },
      },
    }));
  },

  setFilterBankIndex: (viewId, index) => {
    set((state) => ({
      viewFilters: {
        ...state.viewFilters,
        [viewId]: {
          ...state.viewFilters[viewId],
          filterBankIndex: index,
        },
      },
    }));
  },

  setFolderPath: (viewId, path) => {
    set((state) => ({
      viewFilters: {
        ...state.viewFilters,
        [viewId]: {
          ...state.viewFilters[viewId],
          folderPath: path,
        },
      },
    }));
  },

  resetViewFilter: (viewId) => {
    set((state) => ({
      viewFilters: {
        ...state.viewFilters,
        [viewId]: { ...DEFAULT_FILTER_STATE },
      },
    }));
  },

  // Mixer-specific actions
  setDetailSheetTrackIdx: (idx) => {
    set({ mixerViewState: { detailSheetTrackIdx: idx } });
  },

  // Reset all filters (called on project change)
  _resetAllViewFilters: () => {
    set({
      viewFilters: {
        timeline: { ...DEFAULT_FILTER_STATE },
        mixer: { ...DEFAULT_FILTER_STATE },
      },
      mixerViewState: { ...DEFAULT_MIXER_STATE },
    });
  },
});

/**
 * Setup store subscription to reset view filters when project changes.
 *
 * This must be called after the store is created (in store/index.ts).
 * When the project changes, all filter state is reset to defaults since
 * filters are project-specific (track GUIDs, custom banks, folder structure).
 */
export function setupViewFilterSubscriptions(store: {
  getState: () => ViewFilterStore;
  subscribe: (listener: (state: ViewFilterStore, prevState: ViewFilterStore) => void) => () => void;
}): () => void {
  return store.subscribe((state, prevState) => {
    // Detect project change - reset filters for new project
    if (state.projectName !== prevState.projectName && state.projectName !== '') {
      store.getState()._resetAllViewFilters();
    }
  });
}
