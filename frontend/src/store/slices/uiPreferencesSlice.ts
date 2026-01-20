/**
 * UI Preferences Slice
 * Manages global UI preferences stored in localStorage and shared across components
 */

import type { StateCreator } from 'zustand';

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
  /** Auto-refresh when new version detected (PWA cache busting) */
  autoUpdateEnabled: boolean;

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
  setAutoUpdateEnabled: (enabled: boolean) => void;
  toggleAutoUpdateEnabled: () => void;
  loadUIPrefsFromStorage: () => void;
}

interface StoredPrefs {
  showTabBar?: boolean;
  showPersistentTransport?: boolean;
  transportPosition?: 'left' | 'right';
  notesFontSize?: number;
  followPlayheadReEnable?: FollowPlayheadReEnable;
  autoUpdateEnabled?: boolean;
}

const DEFAULT_PREFS = {
  showTabBar: true,
  showPersistentTransport: true,
  transportPosition: 'left' as const,
  notesFontSize: 16,
  followPlayheadReEnable: 'on-playback' as FollowPlayheadReEnable,
  autoUpdateEnabled: true,
};

function saveToStorage(prefs: StoredPrefs): void {
  try {
    localStorage.setItem(UI_PREFS_KEY, JSON.stringify(prefs));
  } catch (e) {
    console.warn('Failed to save UI preferences:', e);
  }
}

export const createUIPreferencesSlice: StateCreator<UIPreferencesState> = (set, get) => ({
  ...DEFAULT_PREFS,

  setShowTabBar: (show) => {
    set({ showTabBar: show });
    saveToStorage({
      showTabBar: show,
      showPersistentTransport: get().showPersistentTransport,
      transportPosition: get().transportPosition,
      notesFontSize: get().notesFontSize,
      followPlayheadReEnable: get().followPlayheadReEnable,
      autoUpdateEnabled: get().autoUpdateEnabled,
    });
  },

  setShowPersistentTransport: (show) => {
    set({ showPersistentTransport: show });
    saveToStorage({
      showTabBar: get().showTabBar,
      showPersistentTransport: show,
      transportPosition: get().transportPosition,
      notesFontSize: get().notesFontSize,
      followPlayheadReEnable: get().followPlayheadReEnable,
      autoUpdateEnabled: get().autoUpdateEnabled,
    });
  },

  setTransportPosition: (position) => {
    set({ transportPosition: position });
    saveToStorage({
      showTabBar: get().showTabBar,
      showPersistentTransport: get().showPersistentTransport,
      transportPosition: position,
      notesFontSize: get().notesFontSize,
      followPlayheadReEnable: get().followPlayheadReEnable,
      autoUpdateEnabled: get().autoUpdateEnabled,
    });
  },

  toggleTabBar: () => {
    const newValue = !get().showTabBar;
    set({ showTabBar: newValue });
    saveToStorage({
      showTabBar: newValue,
      showPersistentTransport: get().showPersistentTransport,
      transportPosition: get().transportPosition,
      notesFontSize: get().notesFontSize,
      followPlayheadReEnable: get().followPlayheadReEnable,
      autoUpdateEnabled: get().autoUpdateEnabled,
    });
  },

  togglePersistentTransport: () => {
    const newValue = !get().showPersistentTransport;
    set({ showPersistentTransport: newValue });
    saveToStorage({
      showTabBar: get().showTabBar,
      showPersistentTransport: newValue,
      transportPosition: get().transportPosition,
      notesFontSize: get().notesFontSize,
      followPlayheadReEnable: get().followPlayheadReEnable,
      autoUpdateEnabled: get().autoUpdateEnabled,
    });
  },

  toggleTransportPosition: () => {
    const newValue = get().transportPosition === 'left' ? 'right' : 'left';
    set({ transportPosition: newValue });
    saveToStorage({
      showTabBar: get().showTabBar,
      showPersistentTransport: get().showPersistentTransport,
      transportPosition: newValue,
      notesFontSize: get().notesFontSize,
      followPlayheadReEnable: get().followPlayheadReEnable,
      autoUpdateEnabled: get().autoUpdateEnabled,
    });
  },

  setNotesFontSize: (size) => {
    const clamped = Math.max(8, Math.min(48, size));
    set({ notesFontSize: clamped });
    saveToStorage({
      showTabBar: get().showTabBar,
      showPersistentTransport: get().showPersistentTransport,
      transportPosition: get().transportPosition,
      notesFontSize: clamped,
      followPlayheadReEnable: get().followPlayheadReEnable,
      autoUpdateEnabled: get().autoUpdateEnabled,
    });
  },

  adjustNotesFontSize: (delta) => {
    const newSize = Math.max(8, Math.min(48, get().notesFontSize + delta));
    set({ notesFontSize: newSize });
    saveToStorage({
      showTabBar: get().showTabBar,
      showPersistentTransport: get().showPersistentTransport,
      transportPosition: get().transportPosition,
      notesFontSize: newSize,
      followPlayheadReEnable: get().followPlayheadReEnable,
      autoUpdateEnabled: get().autoUpdateEnabled,
    });
  },

  setFollowPlayheadReEnable: (mode) => {
    set({ followPlayheadReEnable: mode });
    saveToStorage({
      showTabBar: get().showTabBar,
      showPersistentTransport: get().showPersistentTransport,
      transportPosition: get().transportPosition,
      notesFontSize: get().notesFontSize,
      followPlayheadReEnable: mode,
      autoUpdateEnabled: get().autoUpdateEnabled,
    });
  },

  setAutoUpdateEnabled: (enabled) => {
    set({ autoUpdateEnabled: enabled });
    saveToStorage({
      showTabBar: get().showTabBar,
      showPersistentTransport: get().showPersistentTransport,
      transportPosition: get().transportPosition,
      notesFontSize: get().notesFontSize,
      followPlayheadReEnable: get().followPlayheadReEnable,
      autoUpdateEnabled: enabled,
    });
  },

  toggleAutoUpdateEnabled: () => {
    const newValue = !get().autoUpdateEnabled;
    set({ autoUpdateEnabled: newValue });
    saveToStorage({
      showTabBar: get().showTabBar,
      showPersistentTransport: get().showPersistentTransport,
      transportPosition: get().transportPosition,
      notesFontSize: get().notesFontSize,
      followPlayheadReEnable: get().followPlayheadReEnable,
      autoUpdateEnabled: newValue,
    });
  },

  loadUIPrefsFromStorage: () => {
    try {
      const stored = localStorage.getItem(UI_PREFS_KEY);
      if (stored) {
        const parsed = JSON.parse(stored) as StoredPrefs;
        set({
          showTabBar: parsed.showTabBar ?? DEFAULT_PREFS.showTabBar,
          showPersistentTransport: parsed.showPersistentTransport ?? DEFAULT_PREFS.showPersistentTransport,
          transportPosition: parsed.transportPosition ?? DEFAULT_PREFS.transportPosition,
          notesFontSize: parsed.notesFontSize ?? DEFAULT_PREFS.notesFontSize,
          followPlayheadReEnable: parsed.followPlayheadReEnable ?? DEFAULT_PREFS.followPlayheadReEnable,
          autoUpdateEnabled: parsed.autoUpdateEnabled ?? DEFAULT_PREFS.autoUpdateEnabled,
        });
      }
    } catch (e) {
      console.warn('Failed to load UI preferences:', e);
    }
  },
});
