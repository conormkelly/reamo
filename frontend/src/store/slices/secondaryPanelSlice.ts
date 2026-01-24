/**
 * Secondary Panel state slice
 * Manages expanded/collapsed state and active tab for each view's secondary panel
 */

import type { StateCreator } from 'zustand';

/** Storage key for localStorage persistence */
const STORAGE_KEY = 'reamo-secondary-panel';

/** View identifiers that have secondary panels */
export type SecondaryPanelViewId = 'timeline' | 'mixer';

/** Default tab for each view */
const DEFAULT_TABS: Record<SecondaryPanelViewId, string> = {
  timeline: 'info',
  mixer: 'info',
};

export interface SecondaryPanelSlice {
  // State: per-view expanded and active tab
  secondaryPanelExpanded: Record<SecondaryPanelViewId, boolean>;
  secondaryPanelActiveTab: Record<SecondaryPanelViewId, string>;

  // Actions
  setSecondaryPanelExpanded: (viewId: SecondaryPanelViewId, expanded: boolean) => void;
  setSecondaryPanelActiveTab: (viewId: SecondaryPanelViewId, tabId: string) => void;

  // Persistence
  loadSecondaryPanelFromStorage: () => void;
}

export const createSecondaryPanelSlice: StateCreator<SecondaryPanelSlice> = (set, get) => ({
  // Initial state: expanded by default, info tab selected
  secondaryPanelExpanded: {
    timeline: true,
    mixer: true,
  },
  secondaryPanelActiveTab: {
    timeline: 'info',
    mixer: 'info',
  },

  setSecondaryPanelExpanded: (viewId, expanded) => {
    set((state) => ({
      secondaryPanelExpanded: {
        ...state.secondaryPanelExpanded,
        [viewId]: expanded,
      },
    }));
    // Persist to localStorage
    saveToStorage(get());
  },

  setSecondaryPanelActiveTab: (viewId, tabId) => {
    set((state) => ({
      secondaryPanelActiveTab: {
        ...state.secondaryPanelActiveTab,
        [viewId]: tabId,
      },
    }));
    // Persist to localStorage
    saveToStorage(get());
  },

  loadSecondaryPanelFromStorage: () => {
    try {
      const saved = localStorage.getItem(STORAGE_KEY);
      if (saved) {
        const parsed = JSON.parse(saved) as {
          expanded?: Partial<Record<SecondaryPanelViewId, boolean>>;
          activeTab?: Partial<Record<SecondaryPanelViewId, string>>;
        };

        set({
          secondaryPanelExpanded: {
            timeline: parsed.expanded?.timeline ?? true,
            mixer: parsed.expanded?.mixer ?? true,
          },
          secondaryPanelActiveTab: {
            timeline: parsed.activeTab?.timeline ?? DEFAULT_TABS.timeline,
            mixer: parsed.activeTab?.mixer ?? DEFAULT_TABS.mixer,
          },
        });
      }
    } catch (e) {
      console.error('Failed to load secondary panel state:', e);
    }
  },
});

/** Helper to save state to localStorage */
function saveToStorage(state: SecondaryPanelSlice) {
  try {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        expanded: state.secondaryPanelExpanded,
        activeTab: state.secondaryPanelActiveTab,
      })
    );
  } catch (e) {
    console.error('Failed to save secondary panel state:', e);
  }
}
