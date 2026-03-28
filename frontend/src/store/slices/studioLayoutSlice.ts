/**
 * Studio Layout Slice
 * Manages collapsible section state, ordering, and layout preferences for Studio view
 */

import type { StateCreator } from 'zustand';

export type SectionId = 'project' | 'toolbar' | 'timeline' | 'mixer';

export interface SectionConfig {
  collapsed: boolean;
  order: number;
}

export interface StudioLayoutState {
  sections: Record<SectionId, SectionConfig>;
  hideCollapsed: boolean; // Eye toggle - hide collapsed sections entirely
  showRecordingActions: boolean; // Show recording actions bar during recording
  layoutLocked: boolean; // Lock layout - prevent drag/collapse
  pinMasterTrack: boolean; // Pin master track to left of mixer (don't scroll)
  showAddTrackButton: boolean; // Show + button in mixer to create tracks
  showPianoWheels: boolean; // Show mod wheel and pitch bend on piano instrument

  // Actions
  toggleSection: (id: SectionId) => void;
  setHideCollapsed: (hide: boolean) => void;
  setShowRecordingActions: (show: boolean) => void;
  setLayoutLocked: (locked: boolean) => void;
  setPinMasterTrack: (pinned: boolean) => void;
  setShowAddTrackButton: (show: boolean) => void;
  setShowPianoWheels: (show: boolean) => void;
  reorderLayoutSections: (fromIndex: number, toIndex: number) => void;
  loadLayoutFromStorage: () => void;
  saveLayoutToStorage: () => void;
  resetLayoutToDefaults: () => void;
}

const STORAGE_KEY = 'reamo_studio_layout';

// Mobile detection
const isMobile = () => typeof window !== 'undefined' && window.innerWidth <= 768;

// Default state - mobile gets only Timeline expanded, desktop gets all sections expanded
const getDefaultSections = (): Record<SectionId, SectionConfig> => {
  const mobile = isMobile();
  return {
    project: { collapsed: mobile, order: 0 },     // Desktop: expanded, Mobile: collapsed
    toolbar: { collapsed: mobile, order: 1 },     // Desktop: expanded, Mobile: collapsed
    timeline: { collapsed: false, order: 2 },     // Desktop: expanded, Mobile: expanded (always expanded)
    mixer: { collapsed: mobile, order: 3 }        // Desktop: expanded, Mobile: collapsed
  };
};

const getDefaultState = () => ({
  sections: getDefaultSections(),
  hideCollapsed: false,
  showRecordingActions: true,
  layoutLocked: false,
  pinMasterTrack: true, // Master pinned by default
  showAddTrackButton: true, // Show + button in mixer by default
  showPianoWheels: true // Show mod/pitch wheels by default
});

export const createStudioLayoutSlice: StateCreator<StudioLayoutState> = (set, get) => ({
  ...getDefaultState(),

  toggleSection: (id) => {
    set((state) => ({
      sections: {
        ...state.sections,
        [id]: {
          ...state.sections[id],
          collapsed: !state.sections[id].collapsed
        }
      }
    }));
    get().saveLayoutToStorage();
  },

  setHideCollapsed: (hide) => {
    set({ hideCollapsed: hide });
    get().saveLayoutToStorage();
  },

  setShowRecordingActions: (show) => {
    set({ showRecordingActions: show });
    get().saveLayoutToStorage();
  },

  setLayoutLocked: (locked) => {
    set({ layoutLocked: locked });
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

  reorderLayoutSections: (fromIndex, toIndex) => {
    const state = get();
    const sectionIds = (Object.keys(state.sections) as SectionId[]).sort(
      (a, b) => state.sections[a].order - state.sections[b].order
    );

    // Reorder array
    const [moved] = sectionIds.splice(fromIndex, 1);
    sectionIds.splice(toIndex, 0, moved);

    // Update order values
    const newSections = { ...state.sections };
    sectionIds.forEach((id, index) => {
      newSections[id] = { ...newSections[id], order: index };
    });

    set({ sections: newSections });
    get().saveLayoutToStorage();
  },

  loadLayoutFromStorage: () => {
    try {
      const stored = localStorage.getItem(STORAGE_KEY);
      if (stored) {
        const parsed = JSON.parse(stored);
        set({
          sections: parsed.sections || getDefaultSections(),
          hideCollapsed: parsed.hideCollapsed ?? false,
          showRecordingActions: parsed.showRecordingActions ?? true,
          layoutLocked: parsed.layoutLocked ?? false,
          pinMasterTrack: parsed.pinMasterTrack ?? true,
          showAddTrackButton: parsed.showAddTrackButton ?? true,
          showPianoWheels: parsed.showPianoWheels ?? true
        });
      }
    } catch (err) {
      console.error('Failed to load studio layout from storage:', err);
      // Fall back to defaults on error
      set(getDefaultState());
    }
  },

  saveLayoutToStorage: () => {
    try {
      const state = get();
      localStorage.setItem(STORAGE_KEY, JSON.stringify({
        sections: state.sections,
        hideCollapsed: state.hideCollapsed,
        showRecordingActions: state.showRecordingActions,
        layoutLocked: state.layoutLocked,
        pinMasterTrack: state.pinMasterTrack,
        showAddTrackButton: state.showAddTrackButton,
        showPianoWheels: state.showPianoWheels
      }));
    } catch (err) {
      console.error('Failed to save studio layout to storage:', err);
    }
  },

  resetLayoutToDefaults: () => {
    set(getDefaultState());
    get().saveLayoutToStorage();
  }
});
