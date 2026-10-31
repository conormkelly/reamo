/**
 * Layout preferences slice
 * Header-menu toggles: recording actions bar, pinned master, add-track button,
 * piano wheels. Each setter saves them to localStorage.
 */

import type { StateCreator } from 'zustand';

export interface StudioLayoutState {
  showRecordingActions: boolean; // Show recording actions bar during recording
  pinMasterTrack: boolean; // Pin master track to left of mixer (don't scroll)
  showAddTrackButton: boolean; // Show + button in mixer to create tracks
  showPianoWheels: boolean; // Show mod wheel and pitch bend on piano instrument

  // Actions
  setShowRecordingActions: (show: boolean) => void;
  setPinMasterTrack: (pinned: boolean) => void;
  setShowAddTrackButton: (show: boolean) => void;
  setShowPianoWheels: (show: boolean) => void;
  loadLayoutFromStorage: () => void;
  saveLayoutToStorage: () => void;
  resetLayoutToDefaults: () => void;
}

const STORAGE_KEY = 'reamo_studio_layout';

const getDefaultState = () => ({
  showRecordingActions: true,
  pinMasterTrack: true, // Master pinned by default
  showAddTrackButton: true, // Show + button in mixer by default
  showPianoWheels: true // Show mod/pitch wheels by default
});

export const createStudioLayoutSlice: StateCreator<StudioLayoutState> = (set, get) => ({
  ...getDefaultState(),

  setShowRecordingActions: (show) => {
    set({ showRecordingActions: show });
    get().saveLayoutToStorage();
  },

  setPinMasterTrack: (pinned) => {
    set({ pinMasterTrack: pinned });
    get().saveLayoutToStorage();
  },

  setShowAddTrackButton: (show) => {
    set({ showAddTrackButton: show });
    get().saveLayoutToStorage();
  },

  setShowPianoWheels: (show) => {
    set({ showPianoWheels: show });
    get().saveLayoutToStorage();
  },

  loadLayoutFromStorage: () => {
    try {
      const stored = localStorage.getItem(STORAGE_KEY);
      if (stored) {
        const parsed = JSON.parse(stored);
        set({
          showRecordingActions: parsed.showRecordingActions ?? true,
          pinMasterTrack: parsed.pinMasterTrack ?? true,
          showAddTrackButton: parsed.showAddTrackButton ?? true,
          showPianoWheels: parsed.showPianoWheels ?? true
        });
      }
    } catch (err) {
      console.error('Failed to load layout preferences from storage:', err);
      // Fall back to defaults on error
      set(getDefaultState());
    }
  },

  saveLayoutToStorage: () => {
    try {
      const state = get();
      localStorage.setItem(STORAGE_KEY, JSON.stringify({
        showRecordingActions: state.showRecordingActions,
        pinMasterTrack: state.pinMasterTrack,
        showAddTrackButton: state.showAddTrackButton,
        showPianoWheels: state.showPianoWheels
      }));
    } catch (err) {
      console.error('Failed to save layout preferences to storage:', err);
    }
  },

  resetLayoutToDefaults: () => {
    set(getDefaultState());
    get().saveLayoutToStorage();
  }
});
