/**
 * Sends Hook
 * Provides access to send routing data for tracks.
 * Used by Mixer view's Sends mode to show gold faders controlling send levels.
 */

import { useMemo } from 'react';
import { useReaperStore } from '../store';
import { EMPTY_SENDS } from '../store/stableRefs';
import { useTrackSkeleton } from './useTrackSkeleton';
import type { WSSendSlot } from '../core/WebSocketTypes';

export interface SendDestination {
  /** Destination track index */
  trackIdx: number;
  /** Destination track name (from skeleton) */
  name: string;
}

export interface UseSendsReturn {
  /** All sends in the project */
  sends: WSSendSlot[];
  /** Unique send destination tracks (aux/cue buses) */
  destinations: SendDestination[];
  /** Get sends from a specific source track */
  getSendsFromTrack: (srcTrackIdx: number) => WSSendSlot[];
  /** Get a specific send by source track and destination track */
  getSendByDestination: (srcTrackIdx: number, destTrackIdx: number) => WSSendSlot | undefined;
}

/**
 * Access send routing data for the Mixer's Sends mode.
 *
 * @example
 * ```tsx
 * function SendsMode() {
 *   const { destinations, getSendByDestination } = useSends();
 *   const [selectedDest, setSelectedDest] = useState<number | null>(null);
 *
 *   return (
 *     <select onChange={(e) => setSelectedDest(Number(e.target.value))}>
 *       {destinations.map((d) => (
 *         <option key={d.trackIdx} value={d.trackIdx}>{d.name}</option>
 *       ))}
 *     </select>
 *   );
 * }
 * ```
 */
export function useSends(): UseSendsReturn {
  const sends = useReaperStore((state) => state?.sends ?? EMPTY_SENDS);
  const { skeleton } = useTrackSkeleton();

  // Build unique destinations list with track names
  const destinations = useMemo((): SendDestination[] => {
    // Collect unique destination track indices
    const destSet = new Set<number>();
    for (const send of sends) {
      destSet.add(send.destTrackIdx);
    }

    // Map to destination objects with names from skeleton
    const dests: SendDestination[] = [];
    for (const destIdx of destSet) {
      const skeletonTrack = skeleton[destIdx];
      dests.push({
        trackIdx: destIdx,
        name: skeletonTrack?.n ?? `Track ${destIdx}`,
      });
    }

    // Sort by track index
    dests.sort((a, b) => a.trackIdx - b.trackIdx);

    return dests;
  }, [sends, skeleton]);

  // Get sends from a specific source track
  const getSendsFromTrack = useMemo(() => {
    return (srcTrackIdx: number): WSSendSlot[] => {
      return sends.filter((s) => s.srcTrackIdx === srcTrackIdx);
    };
  }, [sends]);

  // Get a specific send by source and destination
  const getSendByDestination = useMemo(() => {
    return (srcTrackIdx: number, destTrackIdx: number): WSSendSlot | undefined => {
      return sends.find(
        (s) => s.srcTrackIdx === srcTrackIdx && s.destTrackIdx === destTrackIdx
      );
    };
  }, [sends]);

  return useMemo(
    () => ({
      sends,
      destinations,
      getSendsFromTrack,
      getSendByDestination,
    }),
    [sends, destinations, getSendsFromTrack, getSendByDestination]
  );
}
