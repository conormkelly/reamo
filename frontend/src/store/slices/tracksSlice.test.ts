/**
 * Tests for tracksSlice — track state management.
 *
 * Key contracts:
 * - setTrackCount trims tracks beyond the new count
 * - updateTrack/updateTracks merge into existing record
 * - removeTrack deletes by index
 * - setTrackSkeleton builds guidToIndex map
 * - updateMeters only writes when peak/clip changes
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
    });
  });

  // ===========================================================================
  // setTrackCount
  // ===========================================================================

  describe('setTrackCount', () => {
    it('sets the track count', () => {
      useReaperStore.getState().setTrackCount(5);
      expect(useReaperStore.getState().trackCount).toBe(5);
    });

    it('trims tracks beyond the new count', () => {
      useReaperStore.setState({
        tracks: {
          1: makeTrack({ index: 1 }),
          2: makeTrack({ index: 2 }),
          3: makeTrack({ index: 3 }),
        },
      });
      useReaperStore.getState().setTrackCount(2);
      const tracks = useReaperStore.getState().tracks;
      expect(tracks[1]).toBeDefined();
      expect(tracks[2]).toBeDefined();
      expect(tracks[3]).toBeUndefined();
    });

    it('keeps tracks at or below the count', () => {
      useReaperStore.setState({
        tracks: {
          1: makeTrack({ index: 1 }),
          2: makeTrack({ index: 2 }),
        },
      });
      useReaperStore.getState().setTrackCount(5);
      const tracks = useReaperStore.getState().tracks;
      expect(tracks[1]).toBeDefined();
      expect(tracks[2]).toBeDefined();
    });
  });

  // ===========================================================================
  // updateTrack / updateTracks
  // ===========================================================================

  describe('updateTrack', () => {
    it('adds a track by index', () => {
      useReaperStore.getState().updateTrack(makeTrack({ index: 3, name: 'Guitar' }));
      expect(useReaperStore.getState().tracks[3]?.name).toBe('Guitar');
    });

    it('replaces existing track at same index', () => {
      useReaperStore.getState().updateTrack(makeTrack({ index: 1, name: 'Old' }));
      useReaperStore.getState().updateTrack(makeTrack({ index: 1, name: 'New' }));
      expect(useReaperStore.getState().tracks[1]?.name).toBe('New');
    });
  });

  describe('updateTracks', () => {
    it('merges multiple tracks', () => {
      useReaperStore.getState().updateTracks([
        makeTrack({ index: 1, name: 'A' }),
        makeTrack({ index: 2, name: 'B' }),
      ]);
      const tracks = useReaperStore.getState().tracks;
      expect(tracks[1]?.name).toBe('A');
      expect(tracks[2]?.name).toBe('B');
    });

    it('preserves existing tracks not in update', () => {
      useReaperStore.getState().updateTrack(makeTrack({ index: 5, name: 'Existing' }));
      useReaperStore.getState().updateTracks([makeTrack({ index: 1, name: 'New' })]);
      expect(useReaperStore.getState().tracks[5]?.name).toBe('Existing');
    });
  });

  // ===========================================================================
  // removeTrack / clearTracks
  // ===========================================================================

  describe('removeTrack', () => {
    it('removes a track by index', () => {
      useReaperStore.getState().updateTrack(makeTrack({ index: 2 }));
      useReaperStore.getState().removeTrack(2);
      expect(useReaperStore.getState().tracks[2]).toBeUndefined();
    });
  });

  describe('clearTracks', () => {
    it('removes all tracks and resets count', () => {
      useReaperStore.setState({
        tracks: { 1: makeTrack({ index: 1 }), 2: makeTrack({ index: 2 }) },
        trackCount: 2,
      });
      useReaperStore.getState().clearTracks();
      expect(useReaperStore.getState().tracks).toEqual({});
      expect(useReaperStore.getState().trackCount).toBe(0);
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

    it('falls back to meter.i when guid not in guidToIndex', () => {
      useReaperStore.setState({
        tracks: {
          2: makeTrack({ index: 2, lastMeterPeak: 0, clipped: false }),
        },
        guidToIndex: new Map(), // Empty — no GUID mapping
      });
      useReaperStore.getState().updateMeters({
        '{UNKNOWN}': { i: 2, l: 0.7, r: 0.4, c: false },
      });
      expect(useReaperStore.getState().tracks[2]?.lastMeterPeak).toBe(0.7);
    });

    it('ignores meters for tracks not in store', () => {
      const tracksBefore = useReaperStore.getState().tracks;
      useReaperStore.getState().updateMeters({
        '{NONEXISTENT}': { i: 99, l: 0.5, r: 0.5, c: false },
      });
      expect(useReaperStore.getState().tracks).toBe(tracksBefore);
    });
  });
});
