/**
 * Tests for playlistSlice — playlist state management.
 */

import { describe, it, expect, beforeEach } from 'vitest';
import { useReaperStore } from '../index';

describe('playlistSlice', () => {
  beforeEach(() => {
    useReaperStore.getState().clearPlaylistState();
  });

  describe('setPlaylistState', () => {
    it('sets all playlist fields from payload', () => {
      useReaperStore.getState().setPlaylistState({
        playlists: [{
          name: 'Setlist',
          entries: [{ regionId: 0, loopCount: 2 }],
          stopAfterLast: true,
        }],
        activePlaylistIndex: 0,
        currentEntryIndex: 0,
        loopsRemaining: 2,
        currentLoopIteration: 1,
        isPlaylistActive: true,
        isPaused: false,
        advanceAfterLoop: true,
      });

      const s = useReaperStore.getState();
      expect(s.playlists).toHaveLength(1);
      expect(s.playlists[0].name).toBe('Setlist');
      expect(s.activePlaylistIndex).toBe(0);
      expect(s.currentEntryIndex).toBe(0);
      expect(s.loopsRemaining).toBe(2);
      expect(s.currentLoopIteration).toBe(1);
      expect(s.isPlaylistActive).toBe(true);
      expect(s.isPaused).toBe(false);
      expect(s.advanceAfterLoop).toBe(true);
    });

    it('handles null indices (no active playlist)', () => {
      useReaperStore.getState().setPlaylistState({
        playlists: [],
        activePlaylistIndex: null,
        currentEntryIndex: null,
        loopsRemaining: null,
        currentLoopIteration: null,
        isPlaylistActive: false,
        isPaused: false,
        advanceAfterLoop: false,
      });

      const s = useReaperStore.getState();
      expect(s.activePlaylistIndex).toBeNull();
      expect(s.currentEntryIndex).toBeNull();
      expect(s.isPlaylistActive).toBe(false);
    });
  });

  describe('clearPlaylistState', () => {
    it('resets all fields to initial values', () => {
      // First set some state
      useReaperStore.getState().setPlaylistState({
        playlists: [{ name: 'Test', entries: [], stopAfterLast: false }],
        activePlaylistIndex: 0,
        currentEntryIndex: 0,
        loopsRemaining: 5,
        currentLoopIteration: 3,
        isPlaylistActive: true,
        isPaused: true,
        advanceAfterLoop: true,
      });

      // Then clear
      useReaperStore.getState().clearPlaylistState();
      const s = useReaperStore.getState();
      expect(s.playlists).toEqual([]);
      expect(s.activePlaylistIndex).toBeNull();
      expect(s.isPlaylistActive).toBe(false);
      expect(s.isPaused).toBe(false);
    });
  });
});
