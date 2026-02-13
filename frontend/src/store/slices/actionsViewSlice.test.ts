/**
 * Tests for actionsViewSlice — section management, button CRUD, and persistence.
 *
 * Key contracts:
 * - Section CRUD + reorder
 * - Auto-collapse behavior
 * - Button CRUD within sections
 * - localStorage round-trip with migration
 * - getActionsReaperActionRefs across all sections
 */

import { describe, it, expect, beforeEach, beforeAll } from 'vitest';
import { useReaperStore } from '../index';
import type { ActionsSection } from './actionsViewSlice';
import { ACTIONS_VIEW_STORAGE_KEY } from './actionsViewSlice';
import type { ToolbarAction } from './toolbarSlice';

// Node 25+ has a broken native localStorage that shadows jsdom's.
beforeAll(() => {
  const store = new Map<string, string>();
  Object.defineProperty(globalThis, 'localStorage', {
    value: {
      getItem: (key: string) => store.get(key) ?? null,
      setItem: (key: string, value: string) => store.set(key, String(value)),
      removeItem: (key: string) => store.delete(key),
      clear: () => store.clear(),
      get length() { return store.size; },
      key: (i: number) => [...store.keys()][i] ?? null,
    },
    configurable: true,
    writable: true,
  });
});

function makeAction(overrides?: Partial<ToolbarAction & { type: 'reaper_action' }>): ToolbarAction {
  return {
    id: 'act-1',
    type: 'reaper_action',
    label: 'Test',
    actionId: '40012',
    sectionId: 0,
    ...overrides,
  };
}

describe('actionsViewSlice', () => {
  beforeEach(() => {
    useReaperStore.setState({
      actionsSections: [],
      actionsEditMode: false,
      actionsToggleStates: new Map(),
      actionsVerticalAlign: 'bottom',
      actionsAutoCollapse: false,
    });
    localStorage.removeItem(ACTIONS_VIEW_STORAGE_KEY);
  });

  // ===========================================================================
  // Section management
  // ===========================================================================

  describe('addSection', () => {
    it('creates section with generated id and defaults', () => {
      useReaperStore.getState().addSection({ name: 'Transport' });
      const sections = useReaperStore.getState().actionsSections;
      expect(sections).toHaveLength(1);
      expect(sections[0].name).toBe('Transport');
      expect(sections[0].collapsed).toBe(false);
      expect(sections[0].align).toBe('left');
      expect(sections[0].actions).toEqual([]);
      expect(sections[0].id).toMatch(/^sec_/);
    });
  });

  describe('updateSection', () => {
    it('updates section properties', () => {
      useReaperStore.getState().addSection({ name: 'Old' });
      const id = useReaperStore.getState().actionsSections[0].id;
      useReaperStore.getState().updateSection(id, { name: 'New', color: '#ff0000' });
      expect(useReaperStore.getState().actionsSections[0].name).toBe('New');
      expect(useReaperStore.getState().actionsSections[0].color).toBe('#ff0000');
    });
  });

  describe('removeSection', () => {
    it('removes section by id', () => {
      useReaperStore.getState().addSection({ name: 'A' });
      useReaperStore.getState().addSection({ name: 'B' });
      const idToRemove = useReaperStore.getState().actionsSections[0].id;
      useReaperStore.getState().removeSection(idToRemove);
      expect(useReaperStore.getState().actionsSections).toHaveLength(1);
      expect(useReaperStore.getState().actionsSections[0].name).toBe('B');
    });
  });

  describe('reorderSections', () => {
    it('moves section from one position to another', () => {
      useReaperStore.getState().addSection({ name: 'A' });
      useReaperStore.getState().addSection({ name: 'B' });
      useReaperStore.getState().addSection({ name: 'C' });
      useReaperStore.getState().reorderSections(2, 0);
      const names = useReaperStore.getState().actionsSections.map((s) => s.name);
      expect(names).toEqual(['C', 'A', 'B']);
    });
  });

  describe('toggleSectionCollapse', () => {
    it('toggles collapsed state', () => {
      useReaperStore.getState().addSection({ name: 'Test' });
      const id = useReaperStore.getState().actionsSections[0].id;
      useReaperStore.getState().toggleSectionCollapse(id);
      expect(useReaperStore.getState().actionsSections[0].collapsed).toBe(true);
      useReaperStore.getState().toggleSectionCollapse(id);
      expect(useReaperStore.getState().actionsSections[0].collapsed).toBe(false);
    });

    it('auto-collapses other sections when enabled', () => {
      useReaperStore.getState().setActionsAutoCollapse(true);
      useReaperStore.getState().addSection({ name: 'A' });
      useReaperStore.getState().addSection({ name: 'B' });
      const sections = useReaperStore.getState().actionsSections;
      const idA = sections[0].id;
      const idB = sections[1].id;

      // Collapse A first, then open B — A should stay collapsed, B opens
      useReaperStore.getState().toggleSectionCollapse(idA); // collapse A
      useReaperStore.getState().toggleSectionCollapse(idB); // collapse B
      useReaperStore.getState().toggleSectionCollapse(idB); // open B → A stays collapsed

      const result = useReaperStore.getState().actionsSections;
      expect(result.find((s) => s.id === idA)?.collapsed).toBe(true);
      expect(result.find((s) => s.id === idB)?.collapsed).toBe(false);
    });
  });

  // ===========================================================================
  // Button management within sections
  // ===========================================================================

  describe('addActionToSection', () => {
    it('appends action to section', () => {
      useReaperStore.getState().addSection({ name: 'Test' });
      const secId = useReaperStore.getState().actionsSections[0].id;
      useReaperStore.getState().addActionToSection(secId, makeAction({ id: 'btn-1' }));
      expect(useReaperStore.getState().actionsSections[0].actions).toHaveLength(1);
    });
  });

  describe('removeActionFromSection', () => {
    it('removes action by id from section', () => {
      useReaperStore.getState().addSection({ name: 'Test' });
      const secId = useReaperStore.getState().actionsSections[0].id;
      useReaperStore.getState().addActionToSection(secId, makeAction({ id: 'keep' }));
      useReaperStore.getState().addActionToSection(secId, makeAction({ id: 'remove' }));
      useReaperStore.getState().removeActionFromSection(secId, 'remove');
      const actions = useReaperStore.getState().actionsSections[0].actions;
      expect(actions).toHaveLength(1);
      expect(actions[0].id).toBe('keep');
    });
  });

  describe('reorderActionsInSection', () => {
    it('reorders actions within a section', () => {
      useReaperStore.getState().addSection({ name: 'Test' });
      const secId = useReaperStore.getState().actionsSections[0].id;
      useReaperStore.getState().addActionToSection(secId, makeAction({ id: 'a', label: 'A' }));
      useReaperStore.getState().addActionToSection(secId, makeAction({ id: 'b', label: 'B' }));
      useReaperStore.getState().addActionToSection(secId, makeAction({ id: 'c', label: 'C' }));
      useReaperStore.getState().reorderActionsInSection(secId, 0, 2);
      const ids = useReaperStore.getState().actionsSections[0].actions.map((a) => a.id);
      expect(ids).toEqual(['b', 'c', 'a']);
    });
  });

  // ===========================================================================
  // Persistence
  // ===========================================================================

  describe('loadActionsViewFromStorage', () => {
    it('loads saved sections from localStorage', () => {
      const sections: ActionsSection[] = [{
        id: 'sec_test',
        name: 'Saved',
        collapsed: false,
        align: 'center',
        buttonSize: 'lg',
        buttonSpacing: 'sm',
        actions: [],
      }];
      localStorage.setItem(ACTIONS_VIEW_STORAGE_KEY, JSON.stringify({
        sections,
        verticalAlign: 'top',
        autoCollapse: true,
      }));

      useReaperStore.getState().loadActionsViewFromStorage();
      const s = useReaperStore.getState();
      expect(s.actionsSections).toHaveLength(1);
      expect(s.actionsSections[0].name).toBe('Saved');
      expect(s.actionsVerticalAlign).toBe('top');
      expect(s.actionsAutoCollapse).toBe(true);
    });

    it('migrates old sections missing newer properties', () => {
      // Old format: no align, buttonSize, buttonSpacing
      localStorage.setItem(ACTIONS_VIEW_STORAGE_KEY, JSON.stringify({
        sections: [{
          id: 'old',
          name: 'Old',
          collapsed: false,
          actions: [],
        }],
      }));

      useReaperStore.getState().loadActionsViewFromStorage();
      const section = useReaperStore.getState().actionsSections[0];
      expect(section.align).toBe('left');
      expect(section.buttonSize).toBe('md');
      expect(section.buttonSpacing).toBe('md');
    });

    it('handles corrupted localStorage gracefully', () => {
      localStorage.setItem(ACTIONS_VIEW_STORAGE_KEY, '{{{invalid');
      expect(() => useReaperStore.getState().loadActionsViewFromStorage()).not.toThrow();
    });
  });

  describe('saveActionsViewToStorage', () => {
    it('persists sections, verticalAlign, and autoCollapse', () => {
      useReaperStore.getState().addSection({ name: 'Test' });
      useReaperStore.getState().setActionsVerticalAlign('center');
      useReaperStore.getState().setActionsAutoCollapse(true);

      const saved = JSON.parse(localStorage.getItem(ACTIONS_VIEW_STORAGE_KEY) ?? '{}');
      expect(saved.sections).toHaveLength(1);
      expect(saved.verticalAlign).toBe('center');
      expect(saved.autoCollapse).toBe(true);
    });
  });

  // ===========================================================================
  // getActionsReaperActionRefs
  // ===========================================================================

  describe('getActionsReaperActionRefs', () => {
    it('collects numeric and named actions across all sections', () => {
      useReaperStore.getState().addSection({ name: 'A' });
      useReaperStore.getState().addSection({ name: 'B' });
      const sections = useReaperStore.getState().actionsSections;

      useReaperStore.getState().addActionToSection(sections[0].id, makeAction({ id: '1', actionId: '40012', sectionId: 0 }));
      useReaperStore.getState().addActionToSection(sections[1].id, makeAction({ id: '2', actionId: '_SWS_FOO', sectionId: 0 }));

      const { actions, namedActions } = useReaperStore.getState().getActionsReaperActionRefs();
      expect(actions).toEqual([{ c: 40012, s: 0 }]);
      expect(namedActions).toEqual([{ n: '_SWS_FOO', s: 0 }]);
    });
  });
});
