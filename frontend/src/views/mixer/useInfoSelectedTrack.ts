/**
 * useInfoSelectedTrack - The track the mixer's info bar shows.
 *
 * Held by GUID, not index: the info bar renames, duplicates and deletes
 * this track, and a track added or removed above it (in REAPER or from
 * another phone) shifts every index below. The index is derived from the
 * current skeleton, and is null when the track no longer exists.
 */

import { useState, useEffect, useMemo, useCallback } from 'react';
import type { SkeletonTrack } from '../../core/WebSocketTypes';

export const INFO_SELECTED_STORAGE_KEY = 'reamo-mixer-info-selected';

export interface UseInfoSelectedTrackReturn {
  /** Index of the selected track in the skeleton, or null */
  selectedIdx: number | null;
  /** GUID of the selected track ("master" for master), or null */
  selectedGuid: string | null;
  /** Select the track at this skeleton index, or clear with null */
  select: (trackIdx: number | null) => void;
}

/** A stored GUID: older versions stored a track number under the same key. */
function readStoredGuid(): string | null {
  try {
    const stored = localStorage.getItem(INFO_SELECTED_STORAGE_KEY);
    if (stored === null || /^\d+$/.test(stored)) return null;
    return stored;
  } catch {
    return null;
  }
}

export function useInfoSelectedTrack(skeleton: readonly SkeletonTrack[]): UseInfoSelectedTrackReturn {
  const [selectedGuid, setSelectedGuid] = useState<string | null>(readStoredGuid);

  useEffect(() => {
    try {
      if (selectedGuid !== null) {
        localStorage.setItem(INFO_SELECTED_STORAGE_KEY, selectedGuid);
      } else {
        localStorage.removeItem(INFO_SELECTED_STORAGE_KEY);
      }
    } catch {
      // Ignore localStorage errors
    }
  }, [selectedGuid]);

  const selectedIdx = useMemo(() => {
    if (selectedGuid === null) return null;
    const idx = skeleton.findIndex((t) => t.g === selectedGuid);
    return idx >= 0 ? idx : null;
  }, [selectedGuid, skeleton]);

  const select = useCallback(
    (trackIdx: number | null) => {
      setSelectedGuid(trackIdx === null ? null : (skeleton[trackIdx]?.g ?? null));
    },
    [skeleton]
  );

  return { selectedIdx, selectedGuid, select };
}
