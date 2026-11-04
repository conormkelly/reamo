/**
 * Tracks state slice
 * Manages track list and individual track state
 */

import type { StateCreator } from 'zustand';
import type { Track } from '../../core/types';
import type { SkeletonTrack, MeterData } from '../../core/WebSocketTypes';

export interface TracksSlice {
  // State
  trackCount: number; // Number of subscribed tracks (for backward compat)
  tracks: Record<number, Track>; // Using Record instead of Map for Zustand compatibility
  mixerLocked: boolean; // Prevents accidental fader/button changes

  // Viewport-driven subscription state
  trackSkeleton: SkeletonTrack[]; // All tracks: name + GUID (for filtering/navigation)
  totalTracks: number; // User track count from backend (excludes master)
  guidToIndex: Map<string, number>; // GUID → index for O(1) lookup

  // Track layout hold: while a track control is dragged, each row keeps the
  // track it showed when the drag began, so nothing shifts under the finger.
  /** Number of drags holding the layout; the layout is held while > 0 */
  trackLayoutHolds: number;
  /** The latest skeleton received during the hold, applied when it ends */
  heldTrackSkeleton: SkeletonTrack[] | null;
  /** The latest tracks event received during the hold, applied when it ends */
  heldTracksEvent: { tracks: Record<number, Track>; total: number } | null;
  /** GUIDs of held rows whose tracks a skeleton received during the hold no longer lists */
  removedHeldTrackGuids: ReadonlySet<string>;

  // Actions
  setMixerLocked: (locked: boolean) => void;
  toggleMixerLock: () => void;

  // Viewport-driven subscription actions
  setTrackSkeleton: (skeleton: SkeletonTrack[]) => void;
  /**
   * Apply a tracks event: the subscribed tracks keyed by index, and the user
   * track total. While the layout is held, values reach the rows by GUID and
   * the event's layout is applied when the hold ends.
   */
  applyTracksEvent: (tracks: Record<number, Track>, total: number) => void;
  /**
   * Hold the track layout until the returned release is called. Holds count:
   * the latest skeleton and tracks event are applied once every hold is
   * released. The release is safe to call more than once.
   */
  holdTrackLayout: () => () => void;
  updateMeters: (meters: Record<string, MeterData>) => void;
  /** Optimistically update skeleton sel flags (bridges gap until next LOW tier poll) */
  optimisticSelectTrack: (trackGuid: string) => void;
}

const EMPTY_GUID_SET: ReadonlySet<string> = new Set();

/** The state a skeleton sets: the list, its GUID index and the user track count. */
function skeletonState(skeleton: SkeletonTrack[]) {
  const guidToIndex = new Map<string, number>();
  skeleton.forEach((t, i) => guidToIndex.set(t.g, i));
  // totalTracks comes from the skeleton too (minus master at index 0), so
  // subscription logic works as soon as it arrives on connect.
  const totalTracks = Math.max(0, skeleton.length - 1);
  return { trackSkeleton: skeleton, guidToIndex, totalTracks };
}

function tracksEventState(tracks: Record<number, Track>, total: number) {
  return { tracks, trackCount: Object.keys(tracks).length, totalTracks: total };
}

export const createTracksSlice: StateCreator<TracksSlice> = (set, get) => ({
  // Initial state
  trackCount: 0,
  tracks: {},
  mixerLocked: false,

  // Viewport-driven subscription initial state
  trackSkeleton: [],
  totalTracks: 0,
  guidToIndex: new Map(),

  trackLayoutHolds: 0,
  heldTrackSkeleton: null,
  heldTracksEvent: null,
  removedHeldTrackGuids: EMPTY_GUID_SET,

  // Actions
  setMixerLocked: (locked) => set({ mixerLocked: locked }),

  toggleMixerLock: () => set((state) => ({ mixerLocked: !state.mixerLocked })),

  // Viewport-driven subscription actions
  setTrackSkeleton: (skeleton) => {
    const { trackLayoutHolds, tracks, removedHeldTrackGuids } = get();
    if (trackLayoutHolds === 0) {
      set(skeletonState(skeleton));
      return;
    }
    // Rows keep their tracks; note each held row whose track is gone.
    const listed = new Set(skeleton.map((t) => t.g));
    const removed = new Set(removedHeldTrackGuids);
    for (const t of Object.values(tracks)) {
      if (!listed.has(t.guid)) removed.add(t.guid);
    }
    set({
      heldTrackSkeleton: skeleton,
      removedHeldTrackGuids: removed.size === removedHeldTrackGuids.size ? removedHeldTrackGuids : removed,
    });
  },

  applyTracksEvent: (incoming, total) => {
    const { trackLayoutHolds, tracks } = get();
    if (trackLayoutHolds === 0) {
      set(tracksEventState(incoming, total));
      return;
    }
    // Each held row takes its own track's values. A track on no held row
    // waits for the hold to end; a held row missing from the event keeps
    // its last values.
    const rowByGuid = new Map<string, number>();
    for (const [key, t] of Object.entries(tracks)) rowByGuid.set(t.guid, Number(key));
    const rows = { ...tracks };
    for (const t of Object.values(incoming)) {
      const row = rowByGuid.get(t.guid);
      if (row !== undefined) rows[row] = { ...t, index: row };
    }
    set({ tracks: rows, heldTracksEvent: { tracks: incoming, total } });
  },

  holdTrackLayout: () => {
    set((state) => ({ trackLayoutHolds: state.trackLayoutHolds + 1 }));
    let released = false;
    return () => {
      if (released) return;
      released = true;
      const { trackLayoutHolds, heldTrackSkeleton, heldTracksEvent } = get();
      if (trackLayoutHolds > 1) {
        set({ trackLayoutHolds: trackLayoutHolds - 1 });
        return;
      }
      set({
        trackLayoutHolds: 0,
        heldTrackSkeleton: null,
        heldTracksEvent: null,
        removedHeldTrackGuids: EMPTY_GUID_SET,
        ...(heldTrackSkeleton ? skeletonState(heldTrackSkeleton) : {}),
        ...(heldTracksEvent ? tracksEventState(heldTracksEvent.tracks, heldTracksEvent.total) : {}),
      });
    };
  },

  updateMeters: (meters) => {
    // A meter reaches the row showing its track's GUID, so it stays on the
    // right row while the skeleton lags the tracks or the layout is held.
    const { tracks } = get();
    let updatedTracks: Record<number, Track> | null = null;

    for (const [key, track] of Object.entries(tracks)) {
      const meter = meters[track.guid];
      if (!meter) continue;
      const peak = Math.max(meter.l, meter.r);
      // Only update if values changed (avoid unnecessary re-renders)
      if (track.lastMeterPeak !== peak || track.clipped !== meter.c) {
        updatedTracks ??= { ...tracks };
        updatedTracks[Number(key)] = {
          ...track,
          lastMeterPeak: peak,
          lastMeterPos: peak,
          clipped: meter.c,
        };
      }
    }

    if (updatedTracks) {
      set({ tracks: updatedTracks });
    }
  },

  optimisticSelectTrack: (trackGuid) => {
    const { trackSkeleton, heldTrackSkeleton } = get();
    const select = (skeleton: SkeletonTrack[]) => skeleton.map((t) => ({ ...t, sel: t.g === trackGuid }));
    set({
      trackSkeleton: select(trackSkeleton),
      ...(heldTrackSkeleton ? { heldTrackSkeleton: select(heldTrackSkeleton) } : {}),
    });
  },
});
