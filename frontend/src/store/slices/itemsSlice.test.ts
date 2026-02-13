/**
 * Tests for itemsSlice — item state and selection mode management.
 */

import { describe, it, expect, beforeEach } from 'vitest';
import { useReaperStore } from '../index';
import { msg } from '../../test';

describe('itemsSlice', () => {
  beforeEach(() => {
    useReaperStore.setState({
      items: [],
      itemSelectionModeActive: false,
      viewFilterTrackGuid: null,
    });
  });

  describe('setItems', () => {
    it('replaces items array', () => {
      useReaperStore.getState().setItems([
        msg.wsItem({ guid: '{A}', trackIdx: 1 }),
        msg.wsItem({ guid: '{B}', trackIdx: 2 }),
      ]);
      expect(useReaperStore.getState().items).toHaveLength(2);
    });

    it('clears items with empty array', () => {
      useReaperStore.getState().setItems([msg.wsItem()]);
      useReaperStore.getState().setItems([]);
      expect(useReaperStore.getState().items).toHaveLength(0);
    });
  });

  describe('getSelectedItems', () => {
    it('returns only selected items', () => {
      useReaperStore.getState().setItems([
        msg.wsItem({ guid: '{A}', selected: true }),
        msg.wsItem({ guid: '{B}', selected: false }),
        msg.wsItem({ guid: '{C}', selected: true }),
      ]);
      const selected = useReaperStore.getState().getSelectedItems();
      expect(selected).toHaveLength(2);
      expect(selected.map(i => i.guid)).toEqual(['{A}', '{C}']);
    });

    it('returns empty array when no items selected', () => {
      useReaperStore.getState().setItems([msg.wsItem({ selected: false })]);
      expect(useReaperStore.getState().getSelectedItems()).toHaveLength(0);
    });
  });

  describe('getSelectedItemGuid', () => {
    it('returns guid when exactly one item selected', () => {
      useReaperStore.getState().setItems([
        msg.wsItem({ guid: '{ONLY}', selected: true }),
        msg.wsItem({ guid: '{OTHER}', selected: false }),
      ]);
      expect(useReaperStore.getState().getSelectedItemGuid()).toBe('{ONLY}');
    });

    it('returns null when multiple items selected', () => {
      useReaperStore.getState().setItems([
        msg.wsItem({ guid: '{A}', selected: true }),
        msg.wsItem({ guid: '{B}', selected: true }),
      ]);
      expect(useReaperStore.getState().getSelectedItemGuid()).toBeNull();
    });

    it('returns null when no items selected', () => {
      useReaperStore.getState().setItems([msg.wsItem({ selected: false })]);
      expect(useReaperStore.getState().getSelectedItemGuid()).toBeNull();
    });
  });

  describe('item selection mode', () => {
    it('enters selection mode with track guid', () => {
      useReaperStore.getState().enterItemSelectionMode('{TRACK-1}');
      const s = useReaperStore.getState();
      expect(s.itemSelectionModeActive).toBe(true);
      expect(s.viewFilterTrackGuid).toBe('{TRACK-1}');
    });

    it('exits selection mode and clears filter', () => {
      useReaperStore.getState().enterItemSelectionMode('{TRACK-1}');
      useReaperStore.getState().exitItemSelectionMode();
      const s = useReaperStore.getState();
      expect(s.itemSelectionModeActive).toBe(false);
      expect(s.viewFilterTrackGuid).toBeNull();
    });

    it('sets view filter track independently', () => {
      useReaperStore.getState().setViewFilterTrack('{TRACK-2}');
      expect(useReaperStore.getState().viewFilterTrackGuid).toBe('{TRACK-2}');
      expect(useReaperStore.getState().itemSelectionModeActive).toBe(false);
    });
  });
});
