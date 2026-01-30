/**
 * useCurrentMarker hook
 * Tracks the most recently passed marker based on playhead position
 * Provides auto-advance logic: shows the marker just passed (not upcoming)
 *
 * Selection triggers:
 * - Tapping marker pill on timeline
 * - Playhead crossing marker during playback
 * - Prev/Next marker buttons (via position matching)
 *
 * @example
 * ```tsx
 * function MarkerDisplay() {
 *   const { currentMarker, selectMarker, isLocked, setLocked } = useCurrentMarker();
 *
 *   return (
 *     <div>
 *       {currentMarker && <span>{currentMarker.name}</span>}
 *       <button onClick={() => setLocked(!isLocked)}>
 *         {isLocked ? 'Unlock' : 'Lock'}
 *       </button>
 *     </div>
 *   );
 * }
 * ```
 */

import { useEffect, useRef } from 'react';
import { useReaperStore } from '../store';
import type { Marker } from '../core/types';

/** Epsilon for matching marker positions (10ms) */
const POSITION_EPSILON = 0.01;

export interface UseCurrentMarkerReturn {
  /** The currently selected/active marker (null if none) */
  currentMarker: Marker | null;
  /** Select a marker by ID (locks auto-advance) */
  selectMarker: (id: number | null) => void;
  /** Whether auto-advance is locked due to pending edits */
  isLocked: boolean;
  /** Lock/unlock auto-advance manually */
  setLocked: (locked: boolean) => void;
}

/**
 * Hook that tracks which marker the playhead has most recently passed.
 * Auto-advances to show the marker just crossed, unless locked.
 *
 * Note: REAPER's Prev/Next marker actions also stop at time selection
 * boundaries and region start/ends, so we check if playhead is AT a
 * marker position (within epsilon) rather than assuming navigation
 * always lands on a marker.
 */
export function useCurrentMarker(): UseCurrentMarkerReturn {
  const markers = useReaperStore((s) => s.markers);
  const positionSeconds = useReaperStore((s) => s.positionSeconds);
  const playState = useReaperStore((s) => s.playState);
  const selectedMarkerId = useReaperStore((s) => s.selectedMarkerId);
  const isMarkerLocked = useReaperStore((s) => s.isMarkerLocked);
  const setSelectedMarkerId = useReaperStore((s) => s.setSelectedMarkerId);
  const setMarkerLocked = useReaperStore((s) => s.setMarkerLocked);

  // Track last position to detect crossing
  const lastPositionRef = useRef<number>(positionSeconds);
  const isPlayingRef = useRef<boolean>(playState === 1 || playState === 5 || playState === 6);

  // Update on playback position change (auto-advance)
  useEffect(() => {
    /**
     * Find a marker that's at the current position (within epsilon).
     * Used for Prev/Next button navigation where playhead lands exactly on a marker.
     */
    const getMarkerAtPosition = (position: number): Marker | null => {
      if (markers.length === 0) return null;

      for (const marker of markers) {
        if (Math.abs(marker.position - position) <= POSITION_EPSILON) {
          return marker;
        }
      }
      return null;
    };

    /**
     * Find the marker that the playhead has most recently passed.
     * Used for determining which marker to show during continuous playback.
     */
    const getActiveMarker = (): Marker | null => {
      if (markers.length === 0) return null;

      // Sort markers by position
      const sortedMarkers = [...markers].sort((a, b) => a.position - b.position);

      // Find the last marker before or at current position
      let activeMarker: Marker | null = null;
      for (const marker of sortedMarkers) {
        if (marker.position <= positionSeconds + POSITION_EPSILON) {
          activeMarker = marker;
        } else {
          break;
        }
      }

      return activeMarker;
    };
    const isPlaying = playState === 1 || playState === 5 || playState === 6;
    const wasPlaying = isPlayingRef.current;
    isPlayingRef.current = isPlaying;

    // Don't auto-advance if locked (user is editing)
    if (isMarkerLocked) {
      lastPositionRef.current = positionSeconds;
      return;
    }

    const lastPos = lastPositionRef.current;
    const positionDelta = Math.abs(positionSeconds - lastPos);
    lastPositionRef.current = positionSeconds;

    // First priority: check if we're exactly at a marker position
    // This handles Prev/Next navigation regardless of play state
    const markerAtPosition = getMarkerAtPosition(positionSeconds);
    if (markerAtPosition && markerAtPosition.id !== selectedMarkerId) {
      setSelectedMarkerId(markerAtPosition.id);
      return;
    }

    // When stopped and not at a marker: don't update
    // (we might be at a region boundary or time selection edge)
    if (!isPlaying) {
      return;
    }

    // During playback: detect seeks or marker crossings
    // A seek is a large position jump (>0.5s in either direction) or play start
    const isSeek = positionDelta > 0.5;
    const isPlayStart = !wasPlaying;

    if (isSeek || isPlayStart) {
      // On seek or play start, update to most recently passed marker
      const activeMarker = getActiveMarker();
      if (activeMarker && activeMarker.id !== selectedMarkerId) {
        setSelectedMarkerId(activeMarker.id);
      }
      return;
    }

    // Normal playback: check if we crossed any markers
    if (positionDelta > POSITION_EPSILON) {
      const sortedMarkers = [...markers].sort((a, b) => a.position - b.position);
      for (const marker of sortedMarkers) {
        if (marker.position > lastPos && marker.position <= positionSeconds) {
          // We crossed this marker
          setSelectedMarkerId(marker.id);
          break;
        }
      }
    }
  }, [positionSeconds, playState, markers, isMarkerLocked, selectedMarkerId, setSelectedMarkerId]);

  // Get current marker from selection
  const currentMarker = selectedMarkerId !== null
    ? markers.find((m) => m.id === selectedMarkerId) ?? null
    : null;

  const selectMarker = (id: number | null) => {
    setSelectedMarkerId(id);
    // Lock when user manually selects
    if (id !== null) {
      setMarkerLocked(true);
    }
  };

  return {
    currentMarker,
    selectMarker,
    isLocked: isMarkerLocked,
    setLocked: setMarkerLocked,
  };
}
