/**
 * ClockView state slice
 * Manages customizable clock view layout: element visibility, order, and size scaling
 */

import type { StateCreator } from 'zustand';

// Storage key for localStorage persistence
export const CLOCK_VIEW_STORAGE_KEY = 'reamo-clock-view-config';

// Clock elements that can be configured
export type ClockElement = 'barBeatTicks' | 'timeDisplay' | 'bpmTimeSig' | 'transport' | 'recordingIndicator';

// Configuration for a single clock element
export interface ClockElementConfig {
  id: ClockElement;
  visible: boolean;
  order: number; // 0-4, determines vertical position
}

// Full clock view configuration
export interface ClockViewConfig {
  elements: ClockElementConfig[];
  // Size scales (0.5 - 2.0, default 1.0)
  barBeatTicksScale: number;
  timeDisplayScale: number;
  bpmTimeSigScale: number;
  transportScale: number;
}

// Default configuration
const DEFAULT_CONFIG: ClockViewConfig = {
  elements: [
    { id: 'barBeatTicks', visible: true, order: 0 },
    { id: 'timeDisplay', visible: true, order: 1 },
    { id: 'bpmTimeSig', visible: true, order: 2 },
    { id: 'transport', visible: true, order: 3 },
    { id: 'recordingIndicator', visible: true, order: 4 },
  ],
  barBeatTicksScale: 1.0,
  timeDisplayScale: 1.0,
  bpmTimeSigScale: 1.0,
  transportScale: 1.0,
};

// Scale key type for type-safe scale access
export type ScaleKey = 'barBeatTicksScale' | 'timeDisplayScale' | 'bpmTimeSigScale' | 'transportScale';

// Map element IDs to their scale keys
export const ELEMENT_SCALE_MAP: Record<ClockElement, ScaleKey | null> = {
  barBeatTicks: 'barBeatTicksScale',
  timeDisplay: 'timeDisplayScale',
  bpmTimeSig: 'bpmTimeSigScale',
  transport: 'transportScale',
  recordingIndicator: null, // Recording indicator doesn't have its own scale
};

export interface ClockViewSlice {
  // State
  clockConfig: ClockViewConfig;
  clockEditMode: boolean;

  // Element visibility
  setClockElementVisible: (id: ClockElement, visible: boolean) => void;

  // Element ordering
  reorderClockElements: (fromIndex: number, toIndex: number) => void;

  // Size scaling
  setClockScale: (key: ScaleKey, scale: number) => void;
  adjustClockScale: (key: ScaleKey, delta: number) => void;

  // UI state
  setClockEditMode: (editMode: boolean) => void;

  // Persistence
  loadClockViewFromStorage: () => void;
  saveClockViewToStorage: () => void;

  // Reset
  resetClockConfig: () => void;

  // Helpers
  getClockElementConfig: (id: ClockElement) => ClockElementConfig | undefined;
  getSortedClockElements: () => ClockElementConfig[];
}

// Clamp scale to valid range
function clampScale(scale: number): number {
  return Math.max(0.5, Math.min(2.0, scale));
}

export const createClockViewSlice: StateCreator<ClockViewSlice> = (set, get) => ({
  // Initial state
  clockConfig: { ...DEFAULT_CONFIG, elements: DEFAULT_CONFIG.elements.map(e => ({ ...e })) },
  clockEditMode: false,

  // Element visibility
  setClockElementVisible: (id, visible) => {
    set((state) => ({
      clockConfig: {
        ...state.clockConfig,
        elements: state.clockConfig.elements.map((el) =>
          el.id === id ? { ...el, visible } : el
        ),
      },
    }));
    get().saveClockViewToStorage();
  },

  // Element ordering
  reorderClockElements: (fromIndex, toIndex) => {
    set((state) => {
      // Get elements sorted by current order
      const sorted = [...state.clockConfig.elements].sort((a, b) => a.order - b.order);

      // Remove the item from its current position
      const [moved] = sorted.splice(fromIndex, 1);

      // Insert at new position
      sorted.splice(toIndex, 0, moved);

      // Reassign order values based on new positions
      const reordered = sorted.map((el, idx) => ({ ...el, order: idx }));

      return {
        clockConfig: {
          ...state.clockConfig,
          elements: reordered,
        },
      };
    });
    get().saveClockViewToStorage();
  },

  // Size scaling
  setClockScale: (key, scale) => {
    set((state) => ({
      clockConfig: {
        ...state.clockConfig,
        [key]: clampScale(scale),
      },
    }));
    get().saveClockViewToStorage();
  },

  adjustClockScale: (key, delta) => {
    const currentScale = get().clockConfig[key];
    get().setClockScale(key, currentScale + delta);
  },

  // UI state
  setClockEditMode: (editMode) => set({ clockEditMode: editMode }),

  // Persistence
  loadClockViewFromStorage: () => {
    try {
      const saved = localStorage.getItem(CLOCK_VIEW_STORAGE_KEY);
      if (saved) {
        const data = JSON.parse(saved) as Partial<ClockViewConfig>;

        // Merge with defaults to handle missing properties from old versions
        const elements = data.elements
          ? data.elements.map((el, idx) => ({
              id: el.id,
              visible: el.visible ?? true,
              order: el.order ?? idx,
            }))
          : DEFAULT_CONFIG.elements.map(e => ({ ...e }));

        // Ensure all default elements exist (in case new ones were added)
        for (const defaultEl of DEFAULT_CONFIG.elements) {
          if (!elements.find((e) => e.id === defaultEl.id)) {
            elements.push({ ...defaultEl, order: elements.length });
          }
        }

        set({
          clockConfig: {
            elements,
            barBeatTicksScale: clampScale(data.barBeatTicksScale ?? 1.0),
            timeDisplayScale: clampScale(data.timeDisplayScale ?? 1.0),
            bpmTimeSigScale: clampScale(data.bpmTimeSigScale ?? 1.0),
            transportScale: clampScale(data.transportScale ?? 1.0),
          },
        });
      }
    } catch (e) {
      console.error('Failed to load clock view config:', e);
    }
  },

  saveClockViewToStorage: () => {
    try {
      const { clockConfig } = get();
      localStorage.setItem(CLOCK_VIEW_STORAGE_KEY, JSON.stringify(clockConfig));
    } catch (e) {
      console.error('Failed to save clock view config:', e);
    }
  },

  // Reset
  resetClockConfig: () => {
    set({
      clockConfig: { ...DEFAULT_CONFIG, elements: DEFAULT_CONFIG.elements.map(e => ({ ...e })) },
    });
    get().saveClockViewToStorage();
  },

  // Helpers
  getClockElementConfig: (id) => {
    return get().clockConfig.elements.find((el) => el.id === id);
  },

  getSortedClockElements: () => {
    return [...get().clockConfig.elements].sort((a, b) => a.order - b.order);
  },
});
