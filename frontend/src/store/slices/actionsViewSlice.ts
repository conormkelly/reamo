/**
 * ActionsView state slice
 * Manages user-configured action sections with buttons for the ActionsView
 */

import type { StateCreator } from 'zustand';
import type { ToolbarAction, ToggleState } from './toolbarSlice';

// Storage key for localStorage persistence (separate from toolbar)
export const ACTIONS_VIEW_STORAGE_KEY = 'reamo-actions-view-config';

// Alignment types
export type SectionAlign = 'left' | 'center' | 'right';
export type VerticalAlign = 'top' | 'center' | 'bottom';

// Size options for buttons and spacing
export type SizeOption = 'sm' | 'md' | 'lg';

// A section is a named group of action buttons
export interface ActionsSection {
  id: string; // Unique ID (e.g., "sec_1704000000_abc123")
  name: string; // Display name (e.g., "Transport", "FX", "Navigation")
  icon?: string; // Optional Lucide icon name
  color?: string; // Optional accent color (hex)
  collapsed: boolean; // Section can be collapsed
  align: SectionAlign; // Button alignment within section
  buttonSize: SizeOption; // Button size: sm/md/lg
  buttonSpacing: SizeOption; // Gap between buttons: sm/md/lg
  actions: ToolbarAction[]; // Buttons in this section (reuse existing type)
}

export interface ActionsViewSlice {
  // State
  actionsSections: ActionsSection[];
  actionsEditMode: boolean;
  actionsToggleStates: Map<number, ToggleState>;
  actionsVerticalAlign: VerticalAlign; // Global vertical alignment for sections
  actionsAutoCollapse: boolean; // Auto-collapse other sections when one opens

  // Section management
  addSection: (data: { name: string; icon?: string; color?: string }) => void;
  updateSection: (id: string, updates: Partial<Pick<ActionsSection, 'name' | 'icon' | 'color' | 'buttonSize' | 'buttonSpacing'>>) => void;
  removeSection: (id: string) => void;
  reorderSections: (fromIndex: number, toIndex: number) => void;
  toggleSectionCollapse: (id: string) => void;
  setSectionAlign: (id: string, align: SectionAlign) => void;
  setActionsVerticalAlign: (align: VerticalAlign) => void;
  setActionsAutoCollapse: (enabled: boolean) => void;

  // Button management within sections
  addActionToSection: (sectionId: string, action: ToolbarAction) => void;
  updateActionInSection: (
    sectionId: string,
    actionId: string,
    updates: Partial<ToolbarAction>
  ) => void;
  removeActionFromSection: (sectionId: string, actionId: string) => void;
  reorderActionsInSection: (sectionId: string, fromIndex: number, toIndex: number) => void;

  // Toggle states (shared pattern with toolbar)
  setActionsToggleState: (commandId: number, state: ToggleState) => void;
  updateActionsToggleStates: (states: Record<string, number>) => void;
  clearActionsToggleStates: () => void;

  // UI state
  setActionsEditMode: (editMode: boolean) => void;

  // Persistence
  loadActionsViewFromStorage: () => void;
  saveActionsViewToStorage: () => void;

  // Helpers
  getActionsReaperCommandIds: () => number[];
}

// Generate unique ID for sections and actions
function generateId(prefix: string): string {
  const timestamp = Date.now();
  const random = Math.random().toString(36).substring(2, 9);
  return `${prefix}_${timestamp}_${random}`;
}

export const createActionsViewSlice: StateCreator<ActionsViewSlice> = (set, get) => ({
  // Initial state
  actionsSections: [],
  actionsEditMode: false,
  actionsToggleStates: new Map(),
  actionsVerticalAlign: 'bottom' as VerticalAlign,
  actionsAutoCollapse: false,

  // Section management
  addSection: ({ name, icon, color }) => {
    const newSection: ActionsSection = {
      id: generateId('sec'),
      name,
      icon,
      color,
      collapsed: false,
      align: 'left' as SectionAlign,
      buttonSize: 'md' as SizeOption,
      buttonSpacing: 'md' as SizeOption,
      actions: [],
    };
    set((state) => ({
      actionsSections: [...state.actionsSections, newSection],
    }));
    get().saveActionsViewToStorage();
  },

  updateSection: (id, updates) => {
    set((state) => ({
      actionsSections: state.actionsSections.map((s) => (s.id === id ? { ...s, ...updates } : s)),
    }));
    get().saveActionsViewToStorage();
  },

  removeSection: (id) => {
    set((state) => ({
      actionsSections: state.actionsSections.filter((s) => s.id !== id),
    }));
    get().saveActionsViewToStorage();
  },

  reorderSections: (fromIndex, toIndex) => {
    set((state) => {
      const sections = [...state.actionsSections];
      const [moved] = sections.splice(fromIndex, 1);
      sections.splice(toIndex, 0, moved);
      return { actionsSections: sections };
    });
    get().saveActionsViewToStorage();
  },

  toggleSectionCollapse: (id) => {
    const { actionsAutoCollapse, actionsSections } = get();
    const section = actionsSections.find((s) => s.id === id);
    const isOpening = section?.collapsed === true;

    set((state) => ({
      actionsSections: state.actionsSections.map((s) => {
        if (s.id === id) {
          return { ...s, collapsed: !s.collapsed };
        }
        // Auto-collapse others when opening a section (if enabled)
        if (actionsAutoCollapse && isOpening && !s.collapsed) {
          return { ...s, collapsed: true };
        }
        return s;
      }),
    }));
    get().saveActionsViewToStorage();
  },

  setSectionAlign: (id, align) => {
    set((state) => ({
      actionsSections: state.actionsSections.map((s) =>
        s.id === id ? { ...s, align } : s
      ),
    }));
    get().saveActionsViewToStorage();
  },

  setActionsVerticalAlign: (align) => {
    set({ actionsVerticalAlign: align });
    get().saveActionsViewToStorage();
  },

  setActionsAutoCollapse: (enabled) => {
    set({ actionsAutoCollapse: enabled });
    get().saveActionsViewToStorage();
  },

  // Button management within sections
  addActionToSection: (sectionId, action) => {
    set((state) => ({
      actionsSections: state.actionsSections.map((s) =>
        s.id === sectionId ? { ...s, actions: [...s.actions, action] } : s
      ),
    }));
    get().saveActionsViewToStorage();
  },

  updateActionInSection: (sectionId, actionId, updates) => {
    set((state) => ({
      actionsSections: state.actionsSections.map((s) =>
        s.id === sectionId
          ? {
              ...s,
              actions: s.actions.map((a) =>
                a.id === actionId ? ({ ...a, ...updates } as ToolbarAction) : a
              ),
            }
          : s
      ),
    }));
    get().saveActionsViewToStorage();
  },

  removeActionFromSection: (sectionId, actionId) => {
    set((state) => ({
      actionsSections: state.actionsSections.map((s) =>
        s.id === sectionId ? { ...s, actions: s.actions.filter((a) => a.id !== actionId) } : s
      ),
    }));
    get().saveActionsViewToStorage();
  },

  reorderActionsInSection: (sectionId, fromIndex, toIndex) => {
    set((state) => ({
      actionsSections: state.actionsSections.map((s) => {
        if (s.id !== sectionId) return s;
        const actions = [...s.actions];
        const [moved] = actions.splice(fromIndex, 1);
        actions.splice(toIndex, 0, moved);
        return { ...s, actions };
      }),
    }));
    get().saveActionsViewToStorage();
  },

  // Toggle state management (same pattern as toolbar)
  setActionsToggleState: (commandId, state) => {
    set((store) => {
      const newMap = new Map(store.actionsToggleStates);
      newMap.set(commandId, state);
      return { actionsToggleStates: newMap };
    });
  },

  updateActionsToggleStates: (states) => {
    set((store) => {
      const newMap = new Map(store.actionsToggleStates);
      Object.entries(states).forEach(([id, state]) => {
        newMap.set(parseInt(id, 10), state as ToggleState);
      });
      return { actionsToggleStates: newMap };
    });
  },

  clearActionsToggleStates: () => {
    set({ actionsToggleStates: new Map() });
  },

  // UI state
  setActionsEditMode: (editMode) => set({ actionsEditMode: editMode }),

  // Persistence
  loadActionsViewFromStorage: () => {
    try {
      const saved = localStorage.getItem(ACTIONS_VIEW_STORAGE_KEY);
      if (saved) {
        const data = JSON.parse(saved) as {
          sections: ActionsSection[];
          verticalAlign?: VerticalAlign;
          autoCollapse?: boolean;
        };
        if (data.sections && Array.isArray(data.sections)) {
          // Migrate old sections that don't have newer properties
          const sections = data.sections.map((s) => ({
            ...s,
            align: s.align || ('left' as SectionAlign),
            buttonSize: s.buttonSize || ('md' as SizeOption),
            buttonSpacing: s.buttonSpacing || ('md' as SizeOption),
          }));
          set({
            actionsSections: sections,
            actionsVerticalAlign: data.verticalAlign || 'bottom',
            actionsAutoCollapse: data.autoCollapse ?? false,
          });
        }
      }
    } catch (e) {
      console.error('Failed to load actions view config:', e);
    }
  },

  saveActionsViewToStorage: () => {
    try {
      const { actionsSections, actionsVerticalAlign, actionsAutoCollapse } = get();
      localStorage.setItem(
        ACTIONS_VIEW_STORAGE_KEY,
        JSON.stringify({
          sections: actionsSections,
          verticalAlign: actionsVerticalAlign,
          autoCollapse: actionsAutoCollapse,
        })
      );
    } catch (e) {
      console.error('Failed to save actions view config:', e);
    }
  },

  // Helpers
  getActionsReaperCommandIds: () => {
    const { actionsSections } = get();
    const commandIds: number[] = [];
    for (const section of actionsSections) {
      for (const action of section.actions) {
        if (action.type === 'reaper_action') {
          commandIds.push(action.commandId);
        }
      }
    }
    return commandIds;
  },
});
