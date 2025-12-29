/**
 * Toolbar state slice
 * Manages user-configured toolbar buttons and action toggle states
 */

import type { StateCreator } from 'zustand';

// Storage key for localStorage persistence
export const TOOLBAR_STORAGE_KEY = 'reamo-toolbar-config';

// Common fields for all toolbar actions
export interface ToolbarActionBase {
  id: string; // Unique ID for drag-and-drop ordering
  label: string;
  icon?: string; // Lucide icon name
  iconColor?: string; // Hex color, default "#000000"
  textColor?: string; // Hex color, default "#FFFFFF"
  backgroundColor?: string; // Hex color, default "#374151"
}

export type ToolbarAction =
  | (ToolbarActionBase & {
      type: 'reaper_action';
      commandId: number;
    })
  | (ToolbarActionBase & {
      type: 'reaper_action_name';
      name: string; // e.g., "_SWS_SAVESEL"
    })
  | (ToolbarActionBase & {
      type: 'midi_cc';
      cc: number; // 0-127
      value: number; // 0-127
      channel: number; // 0-15
    })
  | (ToolbarActionBase & {
      type: 'midi_pc';
      program: number; // 0-127
      channel: number; // 0-15
    });

// Toggle state values from REAPER
export type ToggleState = -1 | 0 | 1; // -1 = not a toggle, 0 = off, 1 = on

export interface ToolbarSlice {
  // State
  toolbarActions: ToolbarAction[];
  toggleStates: Map<number, ToggleState>;
  toolbarCollapsed: boolean;
  toolbarEditMode: boolean;

  // Actions
  setToolbarActions: (actions: ToolbarAction[]) => void;
  addToolbarAction: (action: ToolbarAction) => void;
  updateToolbarAction: (id: string, updates: Partial<ToolbarAction>) => void;
  removeToolbarAction: (id: string) => void;
  reorderToolbarActions: (fromIndex: number, toIndex: number) => void;

  // Toggle state management
  setToggleState: (commandId: number, state: ToggleState) => void;
  updateToggleStates: (states: Record<string, number>) => void;
  clearToggleStates: () => void;

  // UI state
  setToolbarCollapsed: (collapsed: boolean) => void;
  setToolbarEditMode: (editMode: boolean) => void;

  // Persistence
  loadToolbarFromStorage: () => void;
  saveToolbarToStorage: () => void;

  // Helpers
  getReaperActionCommandIds: () => number[];
}

export const createToolbarSlice: StateCreator<ToolbarSlice> = (set, get) => ({
  // Initial state
  toolbarActions: [],
  toggleStates: new Map(),
  toolbarCollapsed: false,
  toolbarEditMode: false,

  // Actions
  setToolbarActions: (actions) => {
    set({ toolbarActions: actions });
    get().saveToolbarToStorage();
  },

  addToolbarAction: (action) => {
    set((state) => ({
      toolbarActions: [...state.toolbarActions, action],
    }));
    get().saveToolbarToStorage();
  },

  updateToolbarAction: (id, updates) => {
    set((state) => ({
      toolbarActions: state.toolbarActions.map((a) =>
        a.id === id ? ({ ...a, ...updates } as ToolbarAction) : a
      ),
    }));
    get().saveToolbarToStorage();
  },

  removeToolbarAction: (id) => {
    set((state) => ({
      toolbarActions: state.toolbarActions.filter((a) => a.id !== id),
    }));
    get().saveToolbarToStorage();
  },

  reorderToolbarActions: (fromIndex, toIndex) => {
    set((state) => {
      const actions = [...state.toolbarActions];
      const [moved] = actions.splice(fromIndex, 1);
      actions.splice(toIndex, 0, moved);
      return { toolbarActions: actions };
    });
    get().saveToolbarToStorage();
  },

  // Toggle state management
  setToggleState: (commandId, state) => {
    set((store) => {
      const newMap = new Map(store.toggleStates);
      newMap.set(commandId, state);
      return { toggleStates: newMap };
    });
  },

  updateToggleStates: (states) => {
    set((store) => {
      const newMap = new Map(store.toggleStates);
      Object.entries(states).forEach(([id, state]) => {
        newMap.set(parseInt(id, 10), state as ToggleState);
      });
      return { toggleStates: newMap };
    });
  },

  clearToggleStates: () => {
    set({ toggleStates: new Map() });
  },

  // UI state
  setToolbarCollapsed: (collapsed) => set({ toolbarCollapsed: collapsed }),
  setToolbarEditMode: (editMode) => set({ toolbarEditMode: editMode }),

  // Persistence
  loadToolbarFromStorage: () => {
    try {
      const saved = localStorage.getItem(TOOLBAR_STORAGE_KEY);
      if (saved) {
        const actions = JSON.parse(saved) as ToolbarAction[];
        set({ toolbarActions: actions });
      }
    } catch (e) {
      console.error('Failed to load toolbar config:', e);
    }
  },

  saveToolbarToStorage: () => {
    try {
      const { toolbarActions } = get();
      localStorage.setItem(TOOLBAR_STORAGE_KEY, JSON.stringify(toolbarActions));
    } catch (e) {
      console.error('Failed to save toolbar config:', e);
    }
  },

  // Helpers
  getReaperActionCommandIds: () => {
    const { toolbarActions } = get();
    return toolbarActions
      .filter((a): a is ToolbarAction & { type: 'reaper_action' } => a.type === 'reaper_action')
      .map((a) => a.commandId);
  },
});
