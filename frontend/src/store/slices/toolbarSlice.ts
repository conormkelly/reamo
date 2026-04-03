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

/** Section-aware toggle state entry from backend */
export interface ToggleStateEntry {
  s: number; // sectionId
  c: number; // commandId
  v: number; // value (-1, 0, 1)
}

/** Section-aware name-to-id mapping entry from backend */
export interface NameToIdEntry {
  n: string; // named command
  s: number; // sectionId
  c: number; // commandId
}

/** Helper to create a toggle state key from sectionId and actionId */
export function makeToggleKey(sectionId: number, actionId: string): string {
  return `${sectionId}:${actionId}`;
}

export interface ToolbarSlice {
  // State
  toolbarActions: ToolbarAction[];
  toggleStates: Map<string, ToggleState>; // Keyed by "${sectionId}:${actionId}"
  toggleNameToId: Map<string, { sectionId: number; commandId: number }>; // Maps named commands to section+id
  toolbarCollapsed: boolean;
  toolbarEditMode: boolean;
  toolbarAlign: ToolbarAlign;
  toolbarCurrentPage: number; // 0-indexed page for paged grid view

  // Actions
  setToolbarActions: (actions: ToolbarAction[]) => void;
  addToolbarAction: (action: ToolbarAction) => void;
  updateToolbarAction: (id: string, updates: Partial<ToolbarAction>) => void;
  removeToolbarAction: (id: string) => void;
  reorderToolbarActions: (fromIndex: number, toIndex: number) => void;

  // Toggle state management
  setToggleState: (sectionId: number, actionId: string, state: ToggleState) => void;
  updateToggleStates: (states: ToggleStateEntry[], nameToId?: NameToIdEntry[]) => void;
  clearToggleStates: () => void;

  // UI state
  setToolbarCollapsed: (collapsed: boolean) => void;
  setToolbarEditMode: (editMode: boolean) => void;
  setToolbarAlign: (align: ToolbarAlign) => void;
  setToolbarCurrentPage: (page: number) => void;

  // Persistence
  loadToolbarFromStorage: () => void;
  saveToolbarToStorage: () => void;

  // Helpers - returns section-aware action references
  getReaperActionRefs: () => {
    actions: Array<{ c: number; s: number }>;
    namedActions: Array<{ n: string; s: number }>;
  };
}

/**
 * Default toolbar actions for first-time users.
 * Pre-populated with common item editing operations.
 */
const DEFAULT_TOOLBAR_ACTIONS: ToolbarAction[] = [
  { id: 'default-split', type: 'reaper_action', label: 'Split', actionId: '40012', sectionId: 0, icon: 'Scissors', iconColor: '#f59e0b' },
  { id: 'default-glue', type: 'reaper_action', label: 'Glue', actionId: '40362', sectionId: 0, icon: 'Combine', iconColor: '#3b82f6' },
  { id: 'default-delete', type: 'reaper_action', label: 'Delete', actionId: '40006', sectionId: 0, icon: 'Trash2', iconColor: '#ef4444' },
  { id: 'default-marker', type: 'reaper_action', label: 'Marker', actionId: '40157', sectionId: 0, icon: 'MapPin', iconColor: '#10b981' },
  { id: 'default-duplicate', type: 'reaper_action', label: 'Dupe', actionId: '41295', sectionId: 0, icon: 'Copy', iconColor: '#8b5cf6' },
];

export const createToolbarSlice: StateCreator<ToolbarSlice> = (set, get) => ({
  // Initial state
  toolbarActions: [],
  toggleStates: new Map<string, ToggleState>(),
  toggleNameToId: new Map<string, { sectionId: number; commandId: number }>(),
  toolbarCollapsed: false,
  toolbarEditMode: false,
  toolbarAlign: 'left' as ToolbarAlign,
  toolbarCurrentPage: 0,

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
  setToggleState: (sectionId, actionId, state) => {
    set((store) => {
      const newMap = new Map(store.toggleStates);
      newMap.set(makeToggleKey(sectionId, actionId), state);
      return { toggleStates: newMap };
    });
  },

  updateToggleStates: (states, nameToId) => {
    set((store) => {
      const newStates = new Map(store.toggleStates);
      const newNameToId = new Map(store.toggleNameToId);

      // Update name-to-id mapping if provided (from subscription response)
      if (nameToId) {
        nameToId.forEach((entry) => {
          newNameToId.set(entry.n, { sectionId: entry.s, commandId: entry.c });
        });
      }

      // Build reverse lookup: (sectionId, commandId) -> named command
      // Key format: "sectionId:commandId"
      const idToName = new Map<string, string>();
      newNameToId.forEach(({ sectionId, commandId }, name) => {
        idToName.set(`${sectionId}:${commandId}`, name);
      });

      // Update toggle states - use section-aware keys
      states.forEach((entry) => {
        // Check if this (sectionId, commandId) maps to a named command
        const lookupKey = `${entry.s}:${entry.c}`;
        const namedCommand = idToName.get(lookupKey);
        // Use named command as actionId if available, otherwise use numeric commandId
        const actionId = namedCommand ?? String(entry.c);
        const key = makeToggleKey(entry.s, actionId);
        newStates.set(key, entry.v as ToggleState);
      });

      return { toggleStates: newStates, toggleNameToId: newNameToId };
    });
  },

  clearToggleStates: () => {
    set({
      toggleStates: new Map(),
      toggleNameToId: new Map<string, { sectionId: number; commandId: number }>(),
    });
  },

  // UI state
  setToolbarEditMode: (editMode) => set({ toolbarEditMode: editMode }),
  setToolbarCollapsed: (collapsed) => {
    set({ toolbarCollapsed: collapsed });
    // Persist collapsed state with other settings
    try {
      const settings = localStorage.getItem(TOOLBAR_SETTINGS_KEY);
      const parsed = settings ? JSON.parse(settings) : {};
      localStorage.setItem(TOOLBAR_SETTINGS_KEY, JSON.stringify({ ...parsed, collapsed }));
    } catch (e) {
      console.error('Failed to save toolbar settings:', e);
    }
  },
  setToolbarAlign: (align) => {
    set({ toolbarAlign: align });
    // Persist settings separately from actions
    try {
      const settings = localStorage.getItem(TOOLBAR_SETTINGS_KEY);
      const parsed = settings ? JSON.parse(settings) : {};
      localStorage.setItem(TOOLBAR_SETTINGS_KEY, JSON.stringify({ ...parsed, align }));
    } catch (e) {
      console.error('Failed to save toolbar settings:', e);
    }
  },
  setToolbarCurrentPage: (page) => set({ toolbarCurrentPage: page }),

  // Persistence
  loadToolbarFromStorage: () => {
    try {
      // Load actions
      const saved = localStorage.getItem(TOOLBAR_STORAGE_KEY);
      if (saved) {
        const actions = JSON.parse(saved) as ToolbarAction[];
        set({ toolbarActions: actions });
      } else {
        // First-time user: populate with default actions
        set({ toolbarActions: DEFAULT_TOOLBAR_ACTIONS });
        // Save defaults to storage so they persist
        localStorage.setItem(TOOLBAR_STORAGE_KEY, JSON.stringify(DEFAULT_TOOLBAR_ACTIONS));
      }
      // Load settings
      const settings = localStorage.getItem(TOOLBAR_SETTINGS_KEY);
      if (settings) {
        const parsed = JSON.parse(settings) as { align?: ToolbarAlign; collapsed?: boolean };
        if (parsed.align) {
          set({ toolbarAlign: parsed.align });
        }
        if (parsed.collapsed !== undefined) {
          set({ toolbarCollapsed: parsed.collapsed });
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
   * Get section-aware action references for toggle state subscription.
   * Returns both numeric actions (for native REAPER actions) and namedActions (for SWS/scripts).
   */
  getReaperActionRefs: () => {
    const { toolbarActions } = get();
    const reaperActions = toolbarActions.filter(
      (a): a is ToolbarAction & { type: 'reaper_action' } => a.type === 'reaper_action'
    );

    // Section-aware numeric actions: {c: commandId, s: sectionId}
    const actions = reaperActions
      .filter((a) => a.actionId && !a.actionId.startsWith('_'))
      .map((a) => {
        const commandId = parseInt(a.actionId, 10);
        return { c: commandId, s: a.sectionId };
      })
      .filter((a) => !isNaN(a.c));

    // Section-aware named actions: {n: name, s: sectionId}
    const namedActions = reaperActions
      .filter((a) => a.actionId && a.actionId.startsWith('_'))
      .map((a) => ({ n: a.actionId, s: a.sectionId }));

    return { actions, namedActions };
  },
});
