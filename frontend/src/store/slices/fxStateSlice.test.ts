/**
 * Tests for fxStateSlice + fxChainSlice + fxParamSlice — FX state management.
 *
 * Three FX-related slices combined in one test file since they work together:
 * - fxStateSlice: broadcast FX data (5Hz flat list)
 * - fxChainSlice: per-track FX chain subscription
 * - fxParamSlice: per-FX parameter subscription with skeleton caching
 */

import { describe, it, expect, beforeEach } from 'vitest';
import { useReaperStore } from '../index';
import { getFxForTrack } from './fxStateSlice';
import { msg } from '../../test';

describe('fxStateSlice', () => {
  beforeEach(() => {
    useReaperStore.setState({ fx: [] });
  });

  it('sets FX list', () => {
    useReaperStore.getState().setFx([
      msg.wsFxSlot({ trackIdx: 1, fxIndex: 0, name: 'ReaEQ' }),
      msg.wsFxSlot({ trackIdx: 1, fxIndex: 1, name: 'ReaComp' }),
      msg.wsFxSlot({ trackIdx: 2, fxIndex: 0, name: 'ReaVerb' }),
    ]);
    expect(useReaperStore.getState().fx).toHaveLength(3);
  });

  it('replaces FX on update', () => {
    useReaperStore.getState().setFx([msg.wsFxSlot({ name: 'Old' })]);
    useReaperStore.getState().setFx([msg.wsFxSlot({ name: 'New' })]);
    expect(useReaperStore.getState().fx).toHaveLength(1);
    expect(useReaperStore.getState().fx[0].name).toBe('New');
  });
});

describe('getFxForTrack helper', () => {
  it('filters FX by track index', () => {
    const fx = [
      msg.wsFxSlot({ trackIdx: 1, name: 'EQ' }),
      msg.wsFxSlot({ trackIdx: 2, name: 'Comp' }),
      msg.wsFxSlot({ trackIdx: 1, name: 'Verb' }),
    ];
    expect(getFxForTrack(fx, 1).map(f => f.name)).toEqual(['EQ', 'Verb']);
    expect(getFxForTrack(fx, 2)).toHaveLength(1);
    expect(getFxForTrack(fx, 99)).toHaveLength(0);
  });
});

describe('fxChainSlice', () => {
  beforeEach(() => {
    useReaperStore.setState({
      fxChainSubscribedGuid: null,
      fxChainList: [],
    });
  });

  describe('setFxChainSubscription', () => {
    it('sets subscription and clears old data', () => {
      useReaperStore.setState({
        fxChainList: [msg.wsFxChainSlot({ name: 'Stale' })],
      });
      useReaperStore.getState().setFxChainSubscription('{GUID-1}');
      const s = useReaperStore.getState();
      expect(s.fxChainSubscribedGuid).toBe('{GUID-1}');
      expect(s.fxChainList).toEqual([]);
    });
  });

  describe('handleFxChainEvent', () => {
    it('updates chain when event matches subscription', () => {
      useReaperStore.getState().setFxChainSubscription('{GUID-1}');
      useReaperStore.getState().handleFxChainEvent({
        trackGuid: '{GUID-1}',
        fx: [
          msg.wsFxChainSlot({ name: 'ReaEQ', fxIndex: 0 }),
          msg.wsFxChainSlot({ name: 'ReaComp', fxIndex: 1 }),
        ],
      });
      expect(useReaperStore.getState().fxChainList).toHaveLength(2);
    });

    it('ignores event for different track', () => {
      useReaperStore.getState().setFxChainSubscription('{GUID-1}');
      useReaperStore.getState().handleFxChainEvent({
        trackGuid: '{GUID-OTHER}',
        fx: [msg.wsFxChainSlot({ name: 'Ignored' })],
      });
      expect(useReaperStore.getState().fxChainList).toEqual([]);
    });

    it('ignores event when not subscribed', () => {
      useReaperStore.getState().handleFxChainEvent({
        trackGuid: '{GUID-1}',
        fx: [msg.wsFxChainSlot()],
      });
      expect(useReaperStore.getState().fxChainList).toEqual([]);
    });
  });

  describe('clearFxChainSubscription', () => {
    it('clears subscription and data', () => {
      useReaperStore.getState().setFxChainSubscription('{GUID-1}');
      useReaperStore.getState().handleFxChainEvent({
        trackGuid: '{GUID-1}',
        fx: [msg.wsFxChainSlot()],
      });
      useReaperStore.getState().clearFxChainSubscription();
      const s = useReaperStore.getState();
      expect(s.fxChainSubscribedGuid).toBeNull();
      expect(s.fxChainList).toEqual([]);
    });
  });
});

describe('fxParamSlice', () => {
  beforeEach(() => {
    useReaperStore.getState().clearFxParamSubscription();
    // Clear the cache by resetting it
    useReaperStore.setState({ _fxParamSkeletonCache: new Map() });
  });

  describe('setFxParamSubscription', () => {
    it('sets subscription state', () => {
      useReaperStore.getState().setFxParamSubscription('{T1}', '{FX1}', 'ReaEQ');
      const sub = useReaperStore.getState().fxParamSubscription;
      expect(sub).toEqual({ trackGuid: '{T1}', fxGuid: '{FX1}', fxName: 'ReaEQ' });
    });

    it('marks skeleton as loading when no cache', () => {
      useReaperStore.getState().setFxParamSubscription('{T1}', '{FX1}', 'ReaEQ');
      expect(useReaperStore.getState().fxParamSkeletonLoading).toBe(true);
      expect(useReaperStore.getState().fxParamSkeleton).toBeNull();
    });

    it('loads skeleton from cache when available', () => {
      // Prime the cache
      useReaperStore.getState().setCachedSkeleton('{T1}', '{FX1}', ['Freq', 'Gain'], 42);

      useReaperStore.getState().setFxParamSubscription('{T1}', '{FX1}', 'ReaEQ');
      const s = useReaperStore.getState();
      expect(s.fxParamSkeleton).toEqual(['Freq', 'Gain']);
      expect(s.fxParamSkeletonHash).toBe(42);
      expect(s.fxParamSkeletonLoading).toBe(false);
    });
  });

  describe('handleFxParamsEvent', () => {
    beforeEach(() => {
      useReaperStore.getState().setFxParamSubscription('{T1}', '{FX1}', 'ReaEQ');
      // Set skeleton to avoid triggering refresh
      useReaperStore.getState().setFxParamSkeleton(['Freq', 'Gain', 'Q'], 123);
    });

    it('updates parameter values', () => {
      useReaperStore.getState().handleFxParamsEvent({
        trackGuid: '{T1}',
        fxGuid: '{FX1}',
        paramCount: 3,
        nameHash: 123,
        values: { '0': [0.5, '500 Hz'], '1': [0.75, '+3.0 dB'] },
      });
      const vals = useReaperStore.getState().fxParamValues;
      expect(vals.get(0)).toEqual({ value: 0.5, formatted: '500 Hz' });
      expect(vals.get(1)).toEqual({ value: 0.75, formatted: '+3.0 dB' });
    });

    it('ignores events for wrong track', () => {
      useReaperStore.getState().handleFxParamsEvent({
        trackGuid: '{OTHER}',
        fxGuid: '{FX1}',
        paramCount: 3,
        nameHash: 123,
        values: { '0': [0.9, '9k Hz'] },
      });
      expect(useReaperStore.getState().fxParamValues.size).toBe(0);
    });

    it('ignores events for wrong FX', () => {
      useReaperStore.getState().handleFxParamsEvent({
        trackGuid: '{T1}',
        fxGuid: '{WRONG-FX}',
        paramCount: 3,
        nameHash: 123,
        values: { '0': [0.9, '9k Hz'] },
      });
      expect(useReaperStore.getState().fxParamValues.size).toBe(0);
    });

    it('triggers skeleton refresh when hash changes', () => {
      useReaperStore.getState().handleFxParamsEvent({
        trackGuid: '{T1}',
        fxGuid: '{FX1}',
        paramCount: 3,
        nameHash: 999, // Different from 123
        values: {},
      });
      expect(useReaperStore.getState().fxParamSkeletonLoading).toBe(true);
    });
  });

  describe('handleFxParamsError', () => {
    it('clears subscription and sets error', () => {
      useReaperStore.getState().setFxParamSubscription('{T1}', '{FX1}', 'ReaEQ');
      useReaperStore.getState().handleFxParamsError({ error: 'FX_NOT_FOUND' });
      const s = useReaperStore.getState();
      expect(s.fxParamSubscription).toBeNull();
      expect(s.fxParamSkeletonError).toBe('FX not found');
    });
  });

  describe('needsSkeletonRefresh', () => {
    it('returns true when no skeleton loaded', () => {
      useReaperStore.getState().setFxParamSubscription('{T1}', '{FX1}', 'Test');
      expect(useReaperStore.getState().needsSkeletonRefresh(3, 100)).toBe(true);
    });

    it('returns false when hash and count match', () => {
      useReaperStore.getState().setFxParamSubscription('{T1}', '{FX1}', 'Test');
      useReaperStore.getState().setFxParamSkeleton(['A', 'B', 'C'], 100);
      expect(useReaperStore.getState().needsSkeletonRefresh(3, 100)).toBe(false);
    });

    it('returns true when hash differs', () => {
      useReaperStore.getState().setFxParamSubscription('{T1}', '{FX1}', 'Test');
      useReaperStore.getState().setFxParamSkeleton(['A', 'B'], 100);
      expect(useReaperStore.getState().needsSkeletonRefresh(2, 200)).toBe(true);
    });
  });

  describe('skeleton cache (LRU)', () => {
    it('caches and retrieves skeleton', () => {
      useReaperStore.getState().setCachedSkeleton('{T1}', '{FX1}', ['P1'], 10);
      const cached = useReaperStore.getState().getCachedSkeleton('{T1}', '{FX1}');
      expect(cached?.params).toEqual(['P1']);
      expect(cached?.hash).toBe(10);
    });

    it('returns undefined for uncached FX', () => {
      expect(useReaperStore.getState().getCachedSkeleton('{T1}', '{FX1}')).toBeUndefined();
    });
  });
});
