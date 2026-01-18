/**
 * Playlist state slice
 * Manages playlists for region-based looped playback
 */

import type { StateCreator } from 'zustand';
import type {
  PlaylistEventPayload,
  WSPlaylist,
} from '../../core/WebSocketTypes';

export interface PlaylistSlice {
  // State from server events
  playlists: WSPlaylist[];
  activePlaylistIndex: number | null;
  currentEntryIndex: number | null;
  loopsRemaining: number | null;
  currentLoopIteration: number | null;
  isPlaylistActive: boolean;
  isPaused: boolean;
  advanceAfterLoop: boolean;

  // Actions
  setPlaylistState: (payload: PlaylistEventPayload) => void;
  clearPlaylistState: () => void;
}

export const createPlaylistSlice: StateCreator<PlaylistSlice> = (set) => ({
  // Initial state
  playlists: [],
  activePlaylistIndex: null,
  currentEntryIndex: null,
  loopsRemaining: null,
  currentLoopIteration: null,
  isPlaylistActive: false,
  isPaused: false,
  advanceAfterLoop: false,

  // Actions
  setPlaylistState: (payload) =>
    set({
      playlists: payload.playlists,
      activePlaylistIndex: payload.activePlaylistIndex,
      currentEntryIndex: payload.currentEntryIndex,
      loopsRemaining: payload.loopsRemaining,
      currentLoopIteration: payload.currentLoopIteration,
      isPlaylistActive: payload.isPlaylistActive,
      isPaused: payload.isPaused,
      advanceAfterLoop: payload.advanceAfterLoop,
    }),

  clearPlaylistState: () =>
    set({
      playlists: [],
      activePlaylistIndex: null,
      currentEntryIndex: null,
      loopsRemaining: null,
      currentLoopIteration: null,
      isPlaylistActive: false,
      isPaused: false,
      advanceAfterLoop: false,
    }),
});
