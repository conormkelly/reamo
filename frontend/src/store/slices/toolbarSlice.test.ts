/**
 * Tests for toolbarSlice — toolbar actions, toggle states, and localStorage persistence.
 *
 * Key contracts:
 * - CRUD operations on toolbar actions
 * - Reorder preserves all items
 * - Toggle state keyed by "sectionId:actionId"
 * - Named command → ID reverse lookup for toggle state updates
 * - localStorage round-trip (loadToolbarFromStorage / saveToolbarToStorage)
 * - Default actions populated on first load
 * - getReaperActionRefs splits numeric vs named actions
 */

import { describe, it, expect, beforeEach, beforeAll } from 'vitest';
import { useReaperStore } from '../index';
import type { ToolbarAction } from './toolbarSlice';
import { makeToggleKey, TOOLBAR_STORAGE_KEY, TOOLBAR_SETTINGS_KEY } from './toolbarSlice';

// Node 25+ has a broken native localStorage that shadows jsdom's.
// Provide a proper in-memory implementation for tests.
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
    id: 'test-1',
    type: 'reaper_action',
    label: 'Test',
    actionId: '40012',
    sectionId: 0,
    ...overrides,
  };
}

describe('toolbarSlice', () => {
  beforeEach(() => {
    useReaperStore.setState({
      toolbarActions: [],
      toggleStates: new Map(),
      toggleNameToId: new Map(),
      toolbarCollapsed: false,
      toolbarEditMode: false,
      toolbarAlign: 'left',
      toolbarCurrentPage: 0,
    });
    localStorage.removeItem(TOOLBAR_STORAGE_KEY);
    localStorage.removeItem(TOOLBAR_SETTINGS_KEY);
  });

  // ===========================================================================
  // CRUD
  // ===========================================================================

  describe('setToolbarActions', () => {
    it('replaces all actions', () => {
      useReaperStore.getState().setToolbarActions([
        makeAction({ id: 'a', label: 'A' }),
        makeAction({ id: 'b', label: 'B' }),
      ]);
      expect(useReaperStore.getState().toolbarActions).toHaveLength(2);
    });

    it('persists to localStorage', () => {
      useReaperStore.getState().setToolbarActions([makeAction()]);
      expect(localStorage.getItem(TOOLBAR_STORAGE_KEY)).not.toBeNull();
    });
  });

  describe('addToolbarAction', () => {
    it('appends action to list', () => {
      useReaperStore.getState().addToolbarAction(makeAction({ id: 'first' }));
      useReaperStore.getState().addToolbarAction(makeAction({ id: 'second' }));
      const actions = useReaperStore.getState().toolbarActions;
      expect(actions).toHaveLength(2);
      expect(actions[1].id).toBe('second');
    });
  });

  describe('updateToolbarAction', () => {
    it('updates matching action by id', () => {
      useReaperStore.getState().setToolbarActions([makeAction({ id: 'x', label: 'Old' })]);
      useReaperStore.getState().updateToolbarAction('x', { label: 'New' });
      expect(useReaperStore.getState().toolbarActions[0].label).toBe('New');
    });
  });

  describe('removeToolbarAction', () => {
    it('removes action by id', () => {
      useReaperStore.getState().setToolbarActions([
        makeAction({ id: 'keep' }),
        makeAction({ id: 'remove' }),
      ]);
      useReaperStore.getState().removeToolbarAction('remove');
      expect(useReaperStore.getState().toolbarActions).toHaveLength(1);
      expect(useReaperStore.getState().toolbarActions[0].id).toBe('keep');
    });
  });

  describe('reorderToolbarActions', () => {
    it('moves action from one position to another', () => {
      useReaperStore.getState().setToolbarActions([
        makeAction({ id: 'a', label: 'A' }),
        makeAction({ id: 'b', label: 'B' }),
        makeAction({ id: 'c', label: 'C' }),
      ]);
      useReaperStore.getState().reorderToolbarActions(0, 2);
      const ids = useReaperStore.getState().toolbarActions.map((a) => a.id);
      expect(ids).toEqual(['b', 'c', 'a']);
    });
  });

  // ===========================================================================
  // Toggle states
  // ===========================================================================

  describe('makeToggleKey', () => {
    it('creates section-aware key', () => {
      expect(makeToggleKey(0, '40012')).toBe('0:40012');
      expect(makeToggleKey(32060, '_SWS_FOO')).toBe('32060:_SWS_FOO');
    });
  });

  describe('setToggleState', () => {
    it('sets toggle state by section and action id', () => {
      useReaperStore.getState().setToggleState(0, '40012', 1);
      expect(useReaperStore.getState().toggleStates.get('0:40012')).toBe(1);
    });
  });

  describe('updateToggleStates', () => {
    it('updates multiple toggle states from backend entries', () => {
      useReaperStore.getState().updateToggleStates([
        { s: 0, c: 40012, v: 1 },
        { s: 0, c: 40013, v: 0 },
      ]);
      const states = useReaperStore.getState().toggleStates;
      expect(states.get('0:40012')).toBe(1);
      expect(states.get('0:40013')).toBe(0);
    });

    it('uses named command as key when nameToId mapping exists', () => {
      // First establish the name-to-id mapping
      useReaperStore.getState().updateToggleStates(
        [],
        [{ n: '_SWS_SAVESEL', s: 0, c: 12345 }]
      );

      // Now update with commandId — should resolve to named command key
      useReaperStore.getState().updateToggleStates([
        { s: 0, c: 12345, v: 1 },
      ]);
      expect(useReaperStore.getState().toggleStates.get('0:_SWS_SAVESEL')).toBe(1);
    });

    it('falls back to numeric key when no name mapping', () => {
      useReaperStore.getState().updateToggleStates([
        { s: 0, c: 99999, v: -1 },
      ]);
      expect(useReaperStore.getState().toggleStates.get('0:99999')).toBe(-1);
    });
  });

  describe('clearToggleStates', () => {
    it('clears all toggle states and name mappings', () => {
      useReaperStore.getState().setToggleState(0, '40012', 1);
      useReaperStore.getState().clearToggleStates();
      expect(useReaperStore.getState().toggleStates.size).toBe(0);
      expect(useReaperStore.getState().toggleNameToId.size).toBe(0);
    });
  });

  // ===========================================================================
  // UI state
  // ===========================================================================

  describe('UI state', () => {
    it('sets edit mode', () => {
      useReaperStore.getState().setToolbarEditMode(true);
      expect(useReaperStore.getState().toolbarEditMode).toBe(true);
    });

    it('sets current page', () => {
      useReaperStore.getState().setToolbarCurrentPage(2);
      expect(useReaperStore.getState().toolbarCurrentPage).toBe(2);
    });

    it('persists collapsed state to localStorage', () => {
      useReaperStore.getState().setToolbarCollapsed(true);
      const settings = JSON.parse(localStorage.getItem(TOOLBAR_SETTINGS_KEY) ?? '{}');
      expect(settings.collapsed).toBe(true);
    });

    it('persists align to localStorage', () => {
      useReaperStore.getState().setToolbarAlign('center');
      const settings = JSON.parse(localStorage.getItem(TOOLBAR_SETTINGS_KEY) ?? '{}');
      expect(settings.align).toBe('center');
    });
  });

  // ===========================================================================
  // Persistence
  // ===========================================================================

  describe('loadToolbarFromStorage', () => {
    it('loads saved actions from localStorage', () => {
      const actions = [makeAction({ id: 'saved', label: 'Saved' })];
      localStorage.setItem(TOOLBAR_STORAGE_KEY, JSON.stringify(actions));

      useReaperStore.getState().loadToolbarFromStorage();
      expect(useReaperStore.getState().toolbarActions).toHaveLength(1);
      expect(useReaperStore.getState().toolbarActions[0].label).toBe('Saved');
    });

    it('populates default actions on first load (no saved data)', () => {
      useReaperStore.getState().loadToolbarFromStorage();
      const actions = useReaperStore.getState().toolbarActions;
      expect(actions.length).toBeGreaterThan(0);
      // Check that a known default exists
      expect(actions.some((a) => a.label === 'Split')).toBe(true);
    });

    it('saves defaults to localStorage on first load', () => {
      useReaperStore.getState().loadToolbarFromStorage();
      expect(localStorage.getItem(TOOLBAR_STORAGE_KEY)).not.toBeNull();
    });

    it('loads settings (align, collapsed)', () => {
      localStorage.setItem(TOOLBAR_SETTINGS_KEY, JSON.stringify({ align: 'right', collapsed: true }));
      useReaperStore.getState().loadToolbarFromStorage();
      expect(useReaperStore.getState().toolbarAlign).toBe('right');
      expect(useReaperStore.getState().toolbarCollapsed).toBe(true);
    });

    it('handles corrupted localStorage gracefully', () => {
      localStorage.setItem(TOOLBAR_STORAGE_KEY, 'not-valid-json{{{');
      // Should not throw
      expect(() => useReaperStore.getState().loadToolbarFromStorage()).not.toThrow();
    });
  });

  // ===========================================================================
  // getReaperActionRefs
  // ===========================================================================

  describe('getReaperActionRefs', () => {
    it('returns numeric actions with section', () => {
      useReaperStore.setState({
        toolbarActions: [
          makeAction({ id: 'a', actionId: '40012', sectionId: 0 }),
          makeAction({ id: 'b', actionId: '40013', sectionId: 32060 }),
        ],
      });
      const { actions } = useReaperStore.getState().getReaperActionRefs();
      expect(actions).toEqual([
        { c: 40012, s: 0 },
        { c: 40013, s: 32060 },
      ]);
    });

    it('returns named actions separately', () => {
      useReaperStore.setState({
        toolbarActions: [
          makeAction({ id: 'a', actionId: '_SWS_SAVESEL', sectionId: 0 }),
          makeAction({ id: 'b', actionId: '40012', sectionId: 0 }),
        ],
      });
      const { actions, namedActions } = useReaperStore.getState().getReaperActionRefs();
      expect(actions).toHaveLength(1);
      expect(namedActions).toEqual([{ n: '_SWS_SAVESEL', s: 0 }]);
    });

    it('excludes non-reaper_action types', () => {
      useReaperStore.setState({
        toolbarActions: [
          {
            id: 'midi',
            type: 'midi_cc' as const,
            label: 'CC',
            cc: 1,
            value: 127,
            channel: 0,
          },
        ],
      });
      const { actions, namedActions } = useReaperStore.getState().getReaperActionRefs();
      expect(actions).toHaveLength(0);
      expect(namedActions).toHaveLength(0);
    });
  });
});
