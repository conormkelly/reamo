/**
 * Tests for tracksSlice — track state management.
 *
 * Key contracts:
 * - setTrackSkeleton builds guidToIndex map
 * - updateMeters only writes when peak/clip changes, to the row showing the meter's GUID
 * - holdTrackLayout keeps each row on its track until every hold is released
 */

import { describe, it, expect, beforeEach } from 'vitest';
import { useReaperStore } from '../index';
import type { Track } from '../../core/types';
import type { SkeletonTrack } from '../../core/WebSocketTypes';

function makeTrack(overrides?: Partial<Track>): Track {
  return {
    index: 1,
    guid: '{GUID-1}',
    name: 'Track 1',
    flags: 0,
    volume: 1.0,
    pan: 0,
    lastMeterPeak: 0,
    lastMeterPos: 0,
    clipped: false,
    width: 0,
    panMode: 0,
    sendCount: 0,
    receiveCount: 0,
    hwOutCount: 0,
    fxCount: 0,
    color: 0,
    ...overrides,
  };
}

describe('tracksSlice', () => {
  beforeEach(() => {
    useReaperStore.setState({
      tracks: {},
      trackCount: 0,
      totalTracks: 0,
      trackSkeleton: [],
      guidToIndex: new Map(),
      mixerLocked: false,
      trackLayoutHolds: 0,
      heldTrackSkeleton: null,
      heldTracksEvent: null,
      removedHeldTrackGuids: new Set(),
    });
  });

  // ===========================================================================
  // Mixer lock
  // ===========================================================================

  describe('mixerLocked', () => {
    it('sets mixer lock state', () => {
      useReaperStore.getState().setMixerLocked(true);
      expect(useReaperStore.getState().mixerLocked).toBe(true);
    });

    it('toggles mixer lock', () => {
      useReaperStore.getState().toggleMixerLock();
      expect(useReaperStore.getState().mixerLocked).toBe(true);
      useReaperStore.getState().toggleMixerLock();
      expect(useReaperStore.getState().mixerLocked).toBe(false);
    });
  });

  // ===========================================================================
  // Track skeleton
  // ===========================================================================

  describe('setTrackSkeleton', () => {
    it('sets skeleton array', () => {
      const skeleton: SkeletonTrack[] = [
        { n: 'Master', g: '{MASTER}', m: false, sl: null, sel: false, r: false, fd: 0, sc: 0, hc: 0, cl: false, ic: 0, fm: 0, c: 0 },
        { n: 'Drums', g: '{DRUMS}', m: false, sl: null, sel: false, r: false, fd: 0, sc: 0, hc: 0, cl: false, ic: 0, fm: 0, c: 0 },
        { n: 'Bass', g: '{BASS}', m: false, sl: null, sel: false, r: false, fd: 0, sc: 0, hc: 0, cl: false, ic: 0, fm: 0, c: 0 },
      ];
      useReaperStore.getState().setTrackSkeleton(skeleton);
      expect(useReaperStore.getState().trackSkeleton).toHaveLength(3);
    });

    it('builds guidToIndex map from skeleton', () => {
      const skeleton: SkeletonTrack[] = [
        { n: 'Master', g: '{MASTER}', m: false, sl: null, sel: false, r: false, fd: 0, sc: 0, hc: 0, cl: false, ic: 0, fm: 0, c: 0 },
        { n: 'Drums', g: '{DRUMS}', m: false, sl: null, sel: false, r: false, fd: 0, sc: 0, hc: 0, cl: false, ic: 0, fm: 0, c: 0 },
      ];
      useReaperStore.getState().setTrackSkeleton(skeleton);
      const map = useReaperStore.getState().guidToIndex;
      expect(map.get('{MASTER}')).toBe(0);
      expect(map.get('{DRUMS}')).toBe(1);
    });

    it('sets totalTracks to skeleton length minus 1 (excludes master)', () => {
      const skeleton: SkeletonTrack[] = [
        { n: 'Master', g: '{M}', m: false, sl: null, sel: false, r: false, fd: 0, sc: 0, hc: 0, cl: false, ic: 0, fm: 0, c: 0 },
        { n: 'T1', g: '{T1}', m: false, sl: null, sel: false, r: false, fd: 0, sc: 0, hc: 0, cl: false, ic: 0, fm: 0, c: 0 },
        { n: 'T2', g: '{T2}', m: false, sl: null, sel: false, r: false, fd: 0, sc: 0, hc: 0, cl: false, ic: 0, fm: 0, c: 0 },
      ];
      useReaperStore.getState().setTrackSkeleton(skeleton);
      expect(useReaperStore.getState().totalTracks).toBe(2);
    });

    it('handles empty skeleton (totalTracks = 0)', () => {
      useReaperStore.getState().setTrackSkeleton([]);
      expect(useReaperStore.getState().totalTracks).toBe(0);
    });
  });

  // ===========================================================================
  // updateMeters
  // ===========================================================================

  describe('updateMeters', () => {
    beforeEach(() => {
      // Set up a track at index 1 with guid mapped
      useReaperStore.setState({
        tracks: {
          1: makeTrack({ index: 1, guid: '{G1}', lastMeterPeak: 0, clipped: false }),
        },
        guidToIndex: new Map([['{G1}', 1]]),
      });
    });

    it('updates peak from max of L/R channels', () => {
      useReaperStore.getState().updateMeters({
        '{G1}': { i: 1, l: 0.6, r: 0.8, c: false },
      });
      expect(useReaperStore.getState().tracks[1]?.lastMeterPeak).toBe(0.8);
    });

    it('updates clipped state', () => {
      useReaperStore.getState().updateMeters({
        '{G1}': { i: 1, l: 1.2, r: 0.3, c: true },
      });
      expect(useReaperStore.getState().tracks[1]?.clipped).toBe(true);
    });

    it('skips update when values unchanged', () => {
      // Set initial values matching what the meter update would produce
      useReaperStore.setState({
        tracks: {
          1: makeTrack({ index: 1, guid: '{G1}', lastMeterPeak: 0.5, lastMeterPos: 0.5, clipped: false }),
        },
      });
      const tracksBefore = useReaperStore.getState().tracks;
      useReaperStore.getState().updateMeters({
        '{G1}': { i: 1, l: 0.3, r: 0.5, c: false },
      });
      // Same reference means no state update occurred
      expect(useReaperStore.getState().tracks).toBe(tracksBefore);
    });

    it('puts a meter on the row showing its GUID, whatever index the meter or skeleton gives', () => {
      useReaperStore.setState({
        tracks: {
          2: makeTrack({ index: 2, guid: '{G2}', lastMeterPeak: 0, clipped: false }),
          3: makeTrack({ index: 3, guid: '{G3}', lastMeterPeak: 0, clipped: false }),
        },
        // A skeleton that lags the tracks: it still has the old order.
        guidToIndex: new Map([['{G2}', 3], ['{G3}', 2]]),
      });
      useReaperStore.getState().updateMeters({
        '{G2}': { i: 3, l: 0.7, r: 0.4, c: false },
        '{NEW}': { i: 2, l: 0.1, r: 0.1, c: false },
      });
      expect(useReaperStore.getState().tracks[2]?.lastMeterPeak).toBe(0.7);
      expect(useReaperStore.getState().tracks[3]?.lastMeterPeak).toBe(0);
    });

    it('ignores meters for tracks not in store', () => {
      const tracksBefore = useReaperStore.getState().tracks;
      useReaperStore.getState().updateMeters({
        '{NONEXISTENT}': { i: 99, l: 0.5, r: 0.5, c: false },
      });
      expect(useReaperStore.getState().tracks).toBe(tracksBefore);
    });
  });

  // ===========================================================================
  // Track layout hold
  // ===========================================================================

  describe('holdTrackLayout', () => {
    const skel = (...guids: string[]): SkeletonTrack[] =>
      guids.map((g) => ({ n: g, g, m: false, sl: null, sel: false, r: false, fd: 0, sc: 0, hc: 0, cl: false, ic: 0, fm: 0, c: 0 }));
    const rows = (...guids: string[]): Record<number, Track> =>
      Object.fromEntries(guids.map((g, i) => [i, makeTrack({ index: i, guid: g, name: g })]));
    const names = () => Object.values(useReaperStore.getState().tracks).map((t) => t.name);

    beforeEach(() => {
      useReaperStore.getState().setTrackSkeleton(skel('master', 'A', 'B'));
      useReaperStore.getState().applyTracksEvent(rows('master', 'A', 'B'), 2);
    });

    it('applies tracks events and skeletons straight away when nothing holds the layout', () => {
      useReaperStore.getState().applyTracksEvent(rows('master', 'N', 'A', 'B'), 3);
      useReaperStore.getState().setTrackSkeleton(skel('master', 'N', 'A', 'B'));
      expect(names()).toEqual(['master', 'N', 'A', 'B']);
      expect(useReaperStore.getState().totalTracks).toBe(3);
      expect(useReaperStore.getState().guidToIndex.get('A')).toBe(2);
    });

    it('keeps every row on its track and updates its values by GUID while held', () => {
      useReaperStore.getState().holdTrackLayout();
      const incoming = rows('master', 'N', 'A', 'B');
      incoming[3] = { ...incoming[3], volume: 0.25 };
      useReaperStore.getState().applyTracksEvent(incoming, 3);
      useReaperStore.getState().setTrackSkeleton(skel('master', 'N', 'A', 'B'));

      const state = useReaperStore.getState();
      expect(names()).toEqual(['master', 'A', 'B']);
      expect(state.tracks[2]).toMatchObject({ guid: 'B', index: 2, volume: 0.25 });
      expect(state.trackSkeleton.map((t) => t.g)).toEqual(['master', 'A', 'B']);
      expect(state.guidToIndex.get('A')).toBe(1);
      expect(state.totalTracks).toBe(2);
    });

    it('applies the latest held skeleton and tracks event when the hold is released', () => {
      const release = useReaperStore.getState().holdTrackLayout();
      useReaperStore.getState().applyTracksEvent(rows('master', 'N', 'A', 'B'), 3);
      useReaperStore.getState().setTrackSkeleton(skel('master', 'N', 'A', 'B'));
      useReaperStore.getState().applyTracksEvent(rows('master', 'A', 'N', 'B'), 3);
      release();

      const state = useReaperStore.getState();
      expect(names()).toEqual(['master', 'A', 'N', 'B']);
      expect(state.trackSkeleton.map((t) => t.g)).toEqual(['master', 'N', 'A', 'B']);
      expect(state.totalTracks).toBe(3);
      expect(state.trackCount).toBe(4);
      expect(state.trackLayoutHolds).toBe(0);
      expect(state.heldTrackSkeleton).toBeNull();
      expect(state.heldTracksEvent).toBeNull();
    });

    it('holds until every hold is released, and a second call of one release does not count', () => {
      const first = useReaperStore.getState().holdTrackLayout();
      const second = useReaperStore.getState().holdTrackLayout();
      useReaperStore.getState().applyTracksEvent(rows('master', 'N', 'A', 'B'), 3);

      first();
      first();
      expect(names()).toEqual(['master', 'A', 'B']);

      second();
      expect(names()).toEqual(['master', 'N', 'A', 'B']);
    });

    it('marks a held row whose track a skeleton no longer lists, until the hold ends', () => {
      const release = useReaperStore.getState().holdTrackLayout();
      useReaperStore.getState().applyTracksEvent(rows('master', 'B'), 1);
      expect(useReaperStore.getState().removedHeldTrackGuids.has('A')).toBe(false);

      useReaperStore.getState().setTrackSkeleton(skel('master', 'B'));
      expect([...useReaperStore.getState().removedHeldTrackGuids]).toEqual(['A']);
      // The row stays on A with its last values.
      expect(names()).toEqual(['master', 'A', 'B']);

      // A later skeleton listing it again does not clear the mark mid-hold.
      useReaperStore.getState().setTrackSkeleton(skel('master', 'A', 'B'));
      expect(useReaperStore.getState().removedHeldTrackGuids.has('A')).toBe(true);

      release();
      expect(useReaperStore.getState().removedHeldTrackGuids.size).toBe(0);
    });

    it('puts meters on the held rows by GUID', () => {
      useReaperStore.getState().holdTrackLayout();
      useReaperStore.getState().applyTracksEvent(rows('master', 'N', 'A', 'B'), 3);
      useReaperStore.getState().updateMeters({
        N: { i: 1, l: 0.9, r: 0.9, c: true },
        A: { i: 2, l: 0.5, r: 0.2, c: false },
      });
      const { tracks } = useReaperStore.getState();
      expect(tracks[1]).toMatchObject({ guid: 'A', lastMeterPeak: 0.5, clipped: false });
      expect(tracks[2]).toMatchObject({ guid: 'B', lastMeterPeak: 0 });
    });

    it('keeps an optimistic selection made during the hold once the held skeleton applies', () => {
      const release = useReaperStore.getState().holdTrackLayout();
      useReaperStore.getState().setTrackSkeleton(skel('master', 'N', 'A', 'B'));
      useReaperStore.getState().optimisticSelectTrack('A');
      release();
      expect(useReaperStore.getState().trackSkeleton.find((t) => t.g === 'A')?.sel).toBe(true);
    });
  });
});
