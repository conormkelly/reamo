/**
 * Tests for useTrackSkeleton — name filtering and GUID lookup.
 */

import { describe, it, expect, beforeEach } from 'vitest';
import { renderHook } from '@testing-library/react';
import { useReaperStore } from '../store';
import { useTrackSkeleton } from './useTrackSkeleton';
import { msg } from '../test';

describe('useTrackSkeleton', () => {
  beforeEach(() => {
    useReaperStore.setState({
      trackSkeleton: [],
      totalTracks: 0,
      guidToIndex: new Map(),
    });
  });

  describe('basic state', () => {
    it('returns skeleton and totalTracks from store', () => {
      useReaperStore.setState({
        trackSkeleton: [
          msg.skeletonTrack({ n: 'Master', g: '{M}' }),
          msg.skeletonTrack({ n: 'Guitar', g: '{1}' }),
          msg.skeletonTrack({ n: 'Bass', g: '{2}' }),
        ],
        totalTracks: 2,
      });

      const { result } = renderHook(() => useTrackSkeleton());
      expect(result.current.skeleton).toHaveLength(3);
      expect(result.current.totalTracks).toBe(2);
    });

    it('returns empty defaults when no data', () => {
      const { result } = renderHook(() => useTrackSkeleton());
      expect(result.current.skeleton).toHaveLength(0);
      expect(result.current.totalTracks).toBe(0);
    });
  });

  describe('filterByName', () => {
    it('returns all tracks with indices when query is empty', () => {
      useReaperStore.setState({
        trackSkeleton: [
          msg.skeletonTrack({ n: 'Master', g: '{M}' }),
          msg.skeletonTrack({ n: 'Guitar', g: '{1}' }),
          msg.skeletonTrack({ n: 'Bass', g: '{2}' }),
        ],
      });

      const { result } = renderHook(() => useTrackSkeleton());
      const filtered = result.current.filterByName('');
      expect(filtered).toHaveLength(3);
      expect(filtered[0].index).toBe(0);
      expect(filtered[1].index).toBe(1);
      expect(filtered[2].index).toBe(2);
    });

    it('filters case-insensitively', () => {
      useReaperStore.setState({
        trackSkeleton: [
          msg.skeletonTrack({ n: 'Master', g: '{M}' }),
          msg.skeletonTrack({ n: 'Guitar', g: '{1}' }),
          msg.skeletonTrack({ n: 'Bass Guitar', g: '{2}' }),
          msg.skeletonTrack({ n: 'Drums', g: '{3}' }),
        ],
      });

      const { result } = renderHook(() => useTrackSkeleton());
      const filtered = result.current.filterByName('guitar');
      expect(filtered).toHaveLength(2);
      expect(filtered.map((t) => t.n)).toEqual(['Guitar', 'Bass Guitar']);
    });

    it('preserves original indices after filtering', () => {
      useReaperStore.setState({
        trackSkeleton: [
          msg.skeletonTrack({ n: 'Master', g: '{M}' }),
          msg.skeletonTrack({ n: 'Guitar', g: '{1}' }),
          msg.skeletonTrack({ n: 'Bass', g: '{2}' }),
          msg.skeletonTrack({ n: 'Drums', g: '{3}' }),
        ],
      });

      const { result } = renderHook(() => useTrackSkeleton());
      const filtered = result.current.filterByName('Drums');
      expect(filtered).toHaveLength(1);
      expect(filtered[0].index).toBe(3);
    });

    it('returns empty for no matches', () => {
      useReaperStore.setState({
        trackSkeleton: [msg.skeletonTrack({ n: 'Guitar', g: '{1}' })],
      });

      const { result } = renderHook(() => useTrackSkeleton());
      expect(result.current.filterByName('Piano')).toHaveLength(0);
    });

    it('treats whitespace-only query as empty', () => {
      useReaperStore.setState({
        trackSkeleton: [
          msg.skeletonTrack({ n: 'Guitar', g: '{1}' }),
          msg.skeletonTrack({ n: 'Bass', g: '{2}' }),
        ],
      });

      const { result } = renderHook(() => useTrackSkeleton());
      expect(result.current.filterByName('   ')).toHaveLength(2);
    });
  });

  describe('getIndexByGuid', () => {
    it('returns track index for known GUID', () => {
      useReaperStore.setState({
        guidToIndex: new Map([
          ['{TRACK-1}', 1],
          ['{TRACK-2}', 2],
        ]),
      });

      const { result } = renderHook(() => useTrackSkeleton());
      expect(result.current.getIndexByGuid('{TRACK-1}')).toBe(1);
      expect(result.current.getIndexByGuid('{TRACK-2}')).toBe(2);
    });

    it('returns undefined for unknown GUID', () => {
      const { result } = renderHook(() => useTrackSkeleton());
      expect(result.current.getIndexByGuid('{UNKNOWN}')).toBeUndefined();
    });
  });
});
