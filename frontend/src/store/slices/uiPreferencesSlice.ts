/**
 * UI Preferences Slice
 * Manages global UI preferences stored in localStorage and shared across components
 */

import type { StateCreator } from 'zustand';
import { type ViewId, VIEW_ORDER } from '../../viewRegistry';

const UI_PREFS_KEY = 'reamo_ui_preferences';

/** When to re-enable follow playhead after user interaction */
export type FollowPlayheadReEnable = 'on-playback' | 'explicit-only';

export interface UIPreferencesState {
  showTabBar: boolean;
  showPersistentTransport: boolean;
  transportPosition: 'left' | 'right';
  notesFontSize: number;
  /** When to automatically re-enable follow playhead */
  followPlayheadReEnable: FollowPlayheadReEnable;
  /** Number of track lanes to show in timeline view (1-8) */
  timelineLaneCount: number;
  /** Views hidden from tab bar and side rail */
  hiddenViews: ViewId[];
  /** Custom view order for tab bar and side rail */
  viewOrder: ViewId[];

  // Actions
  setShowTabBar: (show: boolean) => void;
  setShowPersistentTransport: (show: boolean) => void;
  setTransportPosition: (position: 'left' | 'right') => void;
  toggleTabBar: () => void;
  togglePersistentTransport: () => void;
  toggleTransportPosition: () => void;
  setNotesFontSize: (size: number) => void;
  adjustNotesFontSize: (delta: number) => void;
  setFollowPlayheadReEnable: (mode: FollowPlayheadReEnable) => void;
  setTimelineLaneCount: (count: number) => void;
  toggleViewVisibility: (viewId: ViewId) => void;
  reorderView: (fromIndex: number, toIndex: number) => void;
  loadUIPrefsFromStorage: () => void;
}

interface StoredPrefs {
  showTabBar?: boolean;
  showPersistentTransport?: boolean;
  transportPosition?: 'left' | 'right';
  notesFontSize?: number;
  followPlayheadReEnable?: FollowPlayheadReEnable;
  timelineLaneCount?: number;
  hiddenViews?: ViewId[];
  viewOrder?: ViewId[];
}

const DEFAULT_PREFS = {
  showTabBar: true,
  showPersistentTransport: true,
  transportPosition: 'left' as const,
  notesFontSize: 16,
  followPlayheadReEnable: 'on-playback' as FollowPlayheadReEnable,
  timelineLaneCount: 4,
  hiddenViews: [] as ViewId[],
  viewOrder: [...VIEW_ORDER],
};

/** Snapshot all preferences from current state and persist to localStorage */
function saveToStorage(get: () => UIPreferencesState): void {
  try {
    const s = get();
    localStorage.setItem(UI_PREFS_KEY, JSON.stringify({
      showTabBar: s.showTabBar,
      showPersistentTransport: s.showPersistentTransport,
      transportPosition: s.transportPosition,
      notesFontSize: s.notesFontSize,
      followPlayheadReEnable: s.followPlayheadReEnable,
      timelineLaneCount: s.timelineLaneCount,
      hiddenViews: s.hiddenViews,
      viewOrder: s.viewOrder,
    } satisfies StoredPrefs));
  } catch (e) {
    console.warn('Failed to save UI preferences:', e);
  }
}

export const createUIPreferencesSlice: StateCreator<UIPreferencesState> = (set, get) => ({
  ...DEFAULT_PREFS,

  setShowTabBar: (show) => {
    set({ showTabBar: show });
    saveToStorage(get);
  },

  setShowPersistentTransport: (show) => {
    set({ showPersistentTransport: show });
    saveToStorage(get);
  },

  setTransportPosition: (position) => {
    set({ transportPosition: position });
    saveToStorage(get);
  },

  toggleTabBar: () => {
    set({ showTabBar: !get().showTabBar });
    saveToStorage(get);
  },

  togglePersistentTransport: () => {
    set({ showPersistentTransport: !get().showPersistentTransport });
    saveToStorage(get);
  },

  toggleTransportPosition: () => {
    set({ transportPosition: get().transportPosition === 'left' ? 'right' : 'left' });
    saveToStorage(get);
  },

  setNotesFontSize: (size) => {
    set({ notesFontSize: Math.max(8, Math.min(48, size)) });
    saveToStorage(get);
  },

  adjustNotesFontSize: (delta) => {
    set({ notesFontSize: Math.max(8, Math.min(48, get().notesFontSize + delta)) });
    saveToStorage(get);
  },

  setFollowPlayheadReEnable: (mode) => {
    set({ followPlayheadReEnable: mode });
    saveToStorage(get);
  },

  setTimelineLaneCount: (count) => {
    set({ timelineLaneCount: Math.max(1, Math.min(8, count)) });
    saveToStorage(get);
  },

  toggleViewVisibility: (viewId) => {
    const current = get().hiddenViews;
    const newHidden = current.includes(viewId)
      ? current.filter(v => v !== viewId)
      : [...current, viewId];
    set({ hiddenViews: newHidden });
    saveToStorage(get);
  },

  reorderView: (fromIndex, toIndex) => {
    const order = [...get().viewOrder];
    const clamped = Math.max(0, Math.min(order.length - 1, toIndex));
    const [moved] = order.splice(fromIndex, 1);
    order.splice(clamped, 0, moved);
    set({ viewOrder: order });
    saveToStorage(get);
  },

  loadUIPrefsFromStorage: () => {
    try {
      const stored = localStorage.getItem(UI_PREFS_KEY);
      if (stored) {
        const parsed = JSON.parse(stored) as StoredPrefs;
        // Validate stored viewOrder contains all views (handles added/removed views across versions)
        let viewOrder = DEFAULT_PREFS.viewOrder;
        if (parsed.viewOrder && parsed.viewOrder.length === VIEW_ORDER.length &&
            VIEW_ORDER.every(v => parsed.viewOrder!.includes(v))) {
          viewOrder = parsed.viewOrder;
        }
        set({
          showTabBar: parsed.showTabBar ?? DEFAULT_PREFS.showTabBar,
          showPersistentTransport: parsed.showPersistentTransport ?? DEFAULT_PREFS.showPersistentTransport,
          transportPosition: parsed.transportPosition ?? DEFAULT_PREFS.transportPosition,
          notesFontSize: parsed.notesFontSize ?? DEFAULT_PREFS.notesFontSize,
          followPlayheadReEnable: parsed.followPlayheadReEnable ?? DEFAULT_PREFS.followPlayheadReEnable,
          timelineLaneCount: parsed.timelineLaneCount ?? DEFAULT_PREFS.timelineLaneCount,
          hiddenViews: parsed.hiddenViews ?? DEFAULT_PREFS.hiddenViews,
          viewOrder,
        });
      }
    } catch (e) {
      console.warn('Failed to load UI preferences:', e);
    }
  },
});
