/**
 * Tracks Hook
 * Provides access to all tracks
 */

import { useMemo } from 'react';
import { useReaperStore } from '../store';
import type { Track } from '../core/types';

export interface UseTracksReturn {
  /** Total track count (excluding master) */
  trackCount: number;
  /** All tracks as an array (sorted by index) */
  tracks: Track[];
  /** Get a specific track by index */
  getTrack: (index: number) => Track | undefined;
  /** Master track (index 0) */
  masterTrack: Track | undefined;
  /** User tracks (index 1+) */
  userTracks: Track[];
}

/**
 * Hook for accessing all tracks
 */
export function useTracks(): UseTracksReturn {
  const trackCount = useReaperStore((state) => state.trackCount);
  const tracksRecord = useReaperStore((state) => state.tracks);

  // Convert record to sorted array
  const tracks = useMemo(() => {
    return Object.values(tracksRecord).sort((a, b) => a.index - b.index);
  }, [tracksRecord]);

  // Get track by index
  const getTrack = useMemo(() => {
    return (index: number) => tracksRecord[index];
  }, [tracksRecord]);

  // Master track
  const masterTrack = useMemo(() => tracksRecord[0], [tracksRecord]);

  // User tracks (excluding master)
  const userTracks = useMemo(() => {
    return tracks.filter((t) => t.index > 0);
  }, [tracks]);

  return {
    trackCount,
    tracks,
    getTrack,
    masterTrack,
    userTracks,
  };
}
