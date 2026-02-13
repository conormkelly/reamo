/**
 * Tests for useSends — destination aggregation and send lookup.
 */

import { describe, it, expect, beforeEach } from 'vitest';
import { renderHook } from '@testing-library/react';
import { useReaperStore } from '../store';
import { useSends } from './useSends';
import { msg } from '../test';

describe('useSends', () => {
  beforeEach(() => {
    useReaperStore.setState({
      sends: [],
      trackSkeleton: [],
      totalTracks: 0,
      guidToIndex: new Map(),
    });
  });

  describe('destinations', () => {
    it('collects unique destination tracks sorted by index', () => {
      useReaperStore.setState({
        sends: [
          msg.wsSendSlot({ srcTrackIdx: 1, destTrackIdx: 5 }),
          msg.wsSendSlot({ srcTrackIdx: 2, destTrackIdx: 5 }),
          msg.wsSendSlot({ srcTrackIdx: 1, destTrackIdx: 3 }),
        ],
        trackSkeleton: [
          msg.skeletonTrack({ n: 'Master', g: '{M}' }),
          msg.skeletonTrack({ n: 'Track 1', g: '{1}' }),
          msg.skeletonTrack({ n: 'Track 2', g: '{2}' }),
          msg.skeletonTrack({ n: 'Bus A', g: '{3}' }),
          msg.skeletonTrack({ n: 'Track 4', g: '{4}' }),
          msg.skeletonTrack({ n: 'Bus B', g: '{5}' }),
        ],
      });

      const { result } = renderHook(() => useSends());
      expect(result.current.destinations).toHaveLength(2);
      expect(result.current.destinations[0]).toEqual({ trackIdx: 3, name: 'Bus A' });
      expect(result.current.destinations[1]).toEqual({ trackIdx: 5, name: 'Bus B' });
    });

    it('falls back to "Track N" when skeleton is missing', () => {
      useReaperStore.setState({
        sends: [msg.wsSendSlot({ srcTrackIdx: 1, destTrackIdx: 10 })],
        trackSkeleton: [],
      });

      const { result } = renderHook(() => useSends());
      expect(result.current.destinations[0].name).toBe('Track 10');
    });

    it('returns empty destinations when no sends', () => {
      const { result } = renderHook(() => useSends());
      expect(result.current.destinations).toEqual([]);
    });
  });

  describe('getSendsFromTrack', () => {
    it('filters sends by source track', () => {
      useReaperStore.setState({
        sends: [
          msg.wsSendSlot({ srcTrackIdx: 1, destTrackIdx: 5 }),
          msg.wsSendSlot({ srcTrackIdx: 2, destTrackIdx: 5 }),
          msg.wsSendSlot({ srcTrackIdx: 1, destTrackIdx: 3 }),
        ],
      });

      const { result } = renderHook(() => useSends());
      expect(result.current.getSendsFromTrack(1)).toHaveLength(2);
      expect(result.current.getSendsFromTrack(2)).toHaveLength(1);
      expect(result.current.getSendsFromTrack(99)).toHaveLength(0);
    });
  });

  describe('getSendByDestination', () => {
    it('finds specific send by source and destination', () => {
      useReaperStore.setState({
        sends: [
          msg.wsSendSlot({ srcTrackIdx: 1, destTrackIdx: 5, volume: 0.75 }),
          msg.wsSendSlot({ srcTrackIdx: 1, destTrackIdx: 3, volume: 0.5 }),
        ],
      });

      const { result } = renderHook(() => useSends());
      const send = result.current.getSendByDestination(1, 3);
      expect(send).toBeDefined();
      expect(send?.volume).toBe(0.5);
    });

    it('returns undefined when send does not exist', () => {
      const { result } = renderHook(() => useSends());
      expect(result.current.getSendByDestination(1, 99)).toBeUndefined();
    });
  });
});
