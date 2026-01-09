/**
 * Toolbar state slice
 * Manages user-configured toolbar buttons and action toggle states
 */

import type { StateCreator } from 'zustand';

// Storage keys for localStorage persistence
export const TOOLBAR_STORAGE_KEY = 'reamo-toolbar-config';
export const TOOLBAR_SETTINGS_KEY = 'reamo-toolbar-settings';

// Toolbar alignment options
export type ToolbarAlign = 'left' | 'center' | 'right';

// Common fields for all toolbar actions
export interface ToolbarActionBase {
  id: string; // Unique ID for drag-and-drop ordering
  label: string;
  icon?: string; // Lucide icon name
  iconColor?: string; // Hex color, default "#000000"
  textColor?: string; // Hex color, default "#FFFFFF"
  backgroundColor?: string; // Hex color, default "#374151"
}

/**
 * Unified REAPER action type.
 * - actionId: Stable identifier - numeric string for native actions ("40001"),
 *   or named string for SWS/scripts ("_SWS_SAVESEL")
 * - sectionId: Action section (0=Main, 32060=MIDI Editor, etc.)
 *
 * For native REAPER actions, actionId is the numeric command ID as a string.
 * For SWS/ReaPack/scripts, actionId is the stable named command (starts with "_").
 */
export type ToolbarAction =
  | (ToolbarActionBase & {
      type: 'reaper_action';
      actionId: string; // "40001" (native) or "_SWS_SAVESEL" (SWS/script)
      sectionId: number; // 0 = main, 32060 = MIDI editor, etc.
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
  toggleStates: Map<string, ToggleState>; // Keyed by actionId (numeric string or named string)
  toggleNameToId: Map<string, number>; // Maps named commands to current numeric IDs (for change events)
  toolbarCollapsed: boolean;
  toolbarEditMode: boolean;
  toolbarAlign: ToolbarAlign;

  // Actions
  setToolbarActions: (actions: ToolbarAction[]) => void;
  addToolbarAction: (action: ToolbarAction) => void;
  updateToolbarAction: (id: string, updates: Partial<ToolbarAction>) => void;
  removeToolbarAction: (id: string) => void;
  reorderToolbarActions: (fromIndex: number, toIndex: number) => void;

  // Toggle state management
  setToggleState: (actionId: string, state: ToggleState) => void;
  updateToggleStates: (states: Record<string, number>, nameToId?: Record<string, number>) => void;
  clearToggleStates: () => void;

  // UI state
  setToolbarCollapsed: (collapsed: boolean) => void;
  setToolbarEditMode: (editMode: boolean) => void;
  setToolbarAlign: (align: ToolbarAlign) => void;

  // Persistence
  loadToolbarFromStorage: () => void;
  saveToolbarToStorage: () => void;

  // Helpers
  getReaperActionIds: () => { commandIds: number[]; names: string[] };
}

export const createToolbarSlice: StateCreator<ToolbarSlice> = (set, get) => ({
  // Initial state
  toolbarActions: [],
  toggleStates: new Map<string, ToggleState>(),
  toggleNameToId: new Map<string, number>(),
  toolbarCollapsed: false,
  toolbarEditMode: false,
  toolbarAlign: 'left' as ToolbarAlign,

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
  setToggleState: (actionId, state) => {
    set((store) => {
      const newMap = new Map(store.toggleStates);
      newMap.set(actionId, state);
      return { toggleStates: newMap };
    });
  },

  updateToggleStates: (states, nameToId) => {
    set((store) => {
      const newStates = new Map(store.toggleStates);
      const newNameToId = new Map(store.toggleNameToId);

      // Update name-to-id mapping if provided (from subscription response)
      if (nameToId) {
        Object.entries(nameToId).forEach(([name, numericId]) => {
          newNameToId.set(name, numericId);
        });
      }

      // Build reverse lookup: numeric ID -> named command
      // Used to translate change events (which use numeric IDs) back to named commands
      const idToName = new Map<number, string>();
      newNameToId.forEach((numericId, name) => {
        idToName.set(numericId, name);
      });

      // Update toggle states - translate numeric IDs to names if needed
      Object.entries(states).forEach(([id, state]) => {
        const numericId = parseInt(id, 10);
        // Check if this numeric ID maps to a named command
        const namedKey = !isNaN(numericId) ? idToName.get(numericId) : undefined;
        const key = namedKey ?? id;
        newStates.set(key, state as ToggleState);
      });

      return { toggleStates: newStates, toggleNameToId: newNameToId };
    });
  },

  clearToggleStates: () => {
    set({ toggleStates: new Map(), toggleNameToId: new Map() });
  },

  // UI state
  setToolbarCollapsed: (collapsed) => set({ toolbarCollapsed: collapsed }),
  setToolbarEditMode: (editMode) => set({ toolbarEditMode: editMode }),
  setToolbarAlign: (align) => {
    set({ toolbarAlign: align });
    // Persist settings separately from actions
    try {
      localStorage.setItem(TOOLBAR_SETTINGS_KEY, JSON.stringify({ align }));
    } catch (e) {
      console.error('Failed to save toolbar settings:', e);
    }
  },

  // Persistence
  loadToolbarFromStorage: () => {
    try {
      // Load actions
      const saved = localStorage.getItem(TOOLBAR_STORAGE_KEY);
      if (saved) {
        const actions = JSON.parse(saved) as ToolbarAction[];
        set({ toolbarActions: actions });
      }
      // Load settings
      const settings = localStorage.getItem(TOOLBAR_SETTINGS_KEY);
      if (settings) {
        const parsed = JSON.parse(settings) as { align?: ToolbarAlign };
        if (parsed.align) {
          set({ toolbarAlign: parsed.align });
        }
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
  /**
   * Get action IDs for toggle state subscription.
   * Returns both numeric commandIds (for native actions) and names (for SWS/scripts).
   */
  getReaperActionIds: () => {
    const { toolbarActions } = get();
    const reaperActions = toolbarActions.filter(
      (a): a is ToolbarAction & { type: 'reaper_action' } => a.type === 'reaper_action'
    );

    const commandIds = reaperActions
      .filter((a) => a.actionId && !a.actionId.startsWith('_'))
      .map((a) => parseInt(a.actionId, 10))
      .filter((id) => !isNaN(id));

    const names = reaperActions
      .filter((a) => a.actionId && a.actionId.startsWith('_'))
      .map((a) => a.actionId);

    return { commandIds, names };
  },
});
