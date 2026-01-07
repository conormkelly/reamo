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

  // Actions
  setTrackCount: (count: number) => void;
  updateTrack: (track: Track) => void;
  updateTracks: (tracks: Track[]) => void;
  removeTrack: (index: number) => void;
  clearTracks: () => void;
  setMixerLocked: (locked: boolean) => void;
  toggleMixerLock: () => void;

  // Viewport-driven subscription actions
  setTrackSkeleton: (skeleton: SkeletonTrack[]) => void;
  setTotalTracks: (total: number) => void;
  updateMeters: (meters: Record<string, MeterData>) => void;
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

  // Actions
  setTrackCount: (trackCount) =>
    set((state) => {
      // Remove tracks beyond the new count
      const newTracks = { ...state.tracks };
      for (const key of Object.keys(newTracks)) {
        const index = parseInt(key, 10);
        if (index > trackCount) {
          delete newTracks[index];
        }
      }
      return { trackCount, tracks: newTracks };
    }),

  updateTrack: (track) =>
    set((state) => ({
      tracks: {
        ...state.tracks,
        [track.index]: track,
      },
    })),

  updateTracks: (tracks) =>
    set((state) => {
      const newTracks = { ...state.tracks };
      for (const track of tracks) {
        newTracks[track.index] = track;
      }
      return { tracks: newTracks };
    }),

  removeTrack: (index) =>
    set((state) => {
      const newTracks = { ...state.tracks };
      delete newTracks[index];
      return { tracks: newTracks };
    }),

  clearTracks: () => set({ tracks: {}, trackCount: 0 }),

  setMixerLocked: (locked) => set({ mixerLocked: locked }),

  toggleMixerLock: () => set((state) => ({ mixerLocked: !state.mixerLocked })),

  // Viewport-driven subscription actions
  setTrackSkeleton: (skeleton) => {
    // Build guidToIndex map from skeleton
    const guidToIndex = new Map<string, number>();
    skeleton.forEach((t, i) => guidToIndex.set(t.g, i));
    // Also set totalTracks from skeleton (minus master at index 0)
    // This allows subscription logic to work immediately on connect
    const userTrackCount = Math.max(0, skeleton.length - 1);
    set({ trackSkeleton: skeleton, guidToIndex, totalTracks: userTrackCount });
  },

  setTotalTracks: (total) => set({ totalTracks: total }),

  updateMeters: (meters) => {
    const { tracks, guidToIndex } = get();
    const updatedTracks = { ...tracks };
    let hasChanges = false;

    for (const [guid, meter] of Object.entries(meters)) {
      // Look up index by GUID, fall back to meter.i if not found
      const idx = guidToIndex.get(guid) ?? meter.i;
      if (updatedTracks[idx]) {
        const peak = Math.max(meter.l, meter.r);
        // Only update if values changed (avoid unnecessary re-renders)
        if (
          updatedTracks[idx].lastMeterPeak !== peak ||
          updatedTracks[idx].clipped !== meter.c
        ) {
          updatedTracks[idx] = {
            ...updatedTracks[idx],
            lastMeterPeak: peak,
            lastMeterPos: peak,
            clipped: meter.c,
          };
          hasChanges = true;
        }
      }
    }

    if (hasChanges) {
      set({ tracks: updatedTracks });
    }
  },
});
