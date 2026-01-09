/**
 * Tracks Hook
 * Provides access to all tracks
 */

import { useMemo } from 'react';
import { useReaperStore } from '../store';
import { EMPTY_TRACKS } from '../store/stableRefs';
import { isSelected, type Track } from '../core/types';

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
  /** Currently selected tracks */
  selectedTracks: Track[];
}

/**
 * Hook for accessing all tracks
 */
export function useTracks(): UseTracksReturn {
  // Defensive selectors with stable fallbacks - state can be undefined briefly on mobile during hydration
  const trackCount = useReaperStore((state) => state?.trackCount ?? 0);
  const tracksRecord = useReaperStore((state) => state?.tracks ?? EMPTY_TRACKS);

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

  // Selected tracks
  const selectedTracks = useMemo(() => {
    return tracks.filter((t) => isSelected(t));
  }, [tracks]);

  return {
    trackCount,
    tracks,
    getTrack,
    masterTrack,
    userTracks,
    selectedTracks,
  };
}
