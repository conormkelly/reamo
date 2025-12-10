/**
 * Tracks state slice
 * Manages track list and individual track state
 */

import type { StateCreator } from 'zustand';
import type { Track } from '../../core/types';

export interface TracksSlice {
  // State
  trackCount: number;
  tracks: Record<number, Track>; // Using Record instead of Map for Zustand compatibility

  // Actions
  setTrackCount: (count: number) => void;
  updateTrack: (track: Track) => void;
  updateTracks: (tracks: Track[]) => void;
  removeTrack: (index: number) => void;
  clearTracks: () => void;
}

export const createTracksSlice: StateCreator<TracksSlice> = (set) => ({
  // Initial state
  trackCount: 0,
  tracks: {},

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
});
