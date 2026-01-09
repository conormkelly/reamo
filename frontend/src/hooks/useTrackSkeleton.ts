/**
 * Track Skeleton Hook
 * Provides access to the lightweight track list (name + GUID) for filtering/navigation.
 * The skeleton contains ALL tracks regardless of subscription state.
 *
 * @example
 * ```tsx
 * function TrackSearch() {
 *   const { skeleton, totalTracks, filterByName } = useTrackSkeleton();
 *   const [query, setQuery] = useState('');
 *   const filtered = filterByName(query);
 *
 *   return (
 *     <div>
 *       <input value={query} onChange={(e) => setQuery(e.target.value)} />
 *       <span>{filtered.length} / {totalTracks} tracks</span>
 *       {filtered.map((t) => <div key={t.g}>{t.n}</div>)}
 *     </div>
 *   );
 * }
 * ```
 */

import { useCallback, useMemo } from 'react';
import { useReaperStore } from '../store';
import { EMPTY_SKELETON, EMPTY_GUID_MAP } from '../store/stableRefs';
import type { SkeletonTrack } from '../core/WebSocketTypes';

export interface SkeletonTrackWithIndex extends SkeletonTrack {
  index: number;
}

export interface UseTrackSkeletonReturn {
  /** All tracks: name + GUID (lightweight, always complete) */
  skeleton: SkeletonTrack[];
  /** Total user track count (excludes master) */
  totalTracks: number;
  /** Filter skeleton by name (case-insensitive) */
  filterByName: (query: string) => SkeletonTrackWithIndex[];
  /** Get track index by GUID */
  getIndexByGuid: (guid: string) => number | undefined;
}

/**
 * Access the track skeleton for filtering and navigation.
 *
 * The skeleton is a lightweight list (name + GUID) of ALL tracks,
 * broadcast at 1Hz when track structure changes. Use it for:
 * - Building filter/search UI
 * - Track navigation
 * - Determining which GUIDs to subscribe to
 *
 * Usage:
 * ```tsx
 * const { skeleton, totalTracks, filterByName } = useTrackSkeleton();
 *
 * // Filter tracks by search query
 * const filtered = filterByName(searchQuery);
 *
 * // Subscribe to filtered tracks
 * useTrackSubscription(
 *   { mode: 'guids', guids: filtered.map(t => t.g) },
 *   { sendCommand }
 * );
 * ```
 */
export function useTrackSkeleton(): UseTrackSkeletonReturn {
  // Defensive selectors with stable fallbacks - state can be undefined briefly on mobile during hydration
  const skeleton = useReaperStore((state) => state?.trackSkeleton ?? EMPTY_SKELETON);
  const totalTracks = useReaperStore((state) => state?.totalTracks ?? 0);
  const guidToIndex = useReaperStore((state) => state?.guidToIndex ?? EMPTY_GUID_MAP);

  // Filter skeleton by name (case-insensitive)
  const filterByName = useCallback(
    (query: string): SkeletonTrackWithIndex[] => {
      if (!query.trim()) {
        // Return all tracks with indices
        return skeleton.map((t, i) => ({ ...t, index: i }));
      }

      const lower = query.toLowerCase();
      return skeleton
        .map((t, i) => ({ ...t, index: i }))
        .filter((t) => t.n.toLowerCase().includes(lower));
    },
    [skeleton]
  );

  // Get track index by GUID
  const getIndexByGuid = useCallback(
    (guid: string): number | undefined => {
      return guidToIndex.get(guid);
    },
    [guidToIndex]
  );

  return useMemo(
    () => ({
      skeleton,
      totalTracks,
      filterByName,
      getIndexByGuid,
    }),
    [skeleton, totalTracks, filterByName, getIndexByGuid]
  );
}
