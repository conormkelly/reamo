/**
 * usePeaksSubscription Hook
 * Subscribes to peaks data for a track via WebSocket
 *
 * Unlike usePeaksFetch (pull-based), this hook uses the subscription system:
 * - Subscribe to a track GUID
 * - Backend pushes peaks events when items change
 * - No loading states - data arrives asynchronously
 *
 * @example
 * ```tsx
 * function TimelineWaveforms({ trackGuid }: { trackGuid: string | null }) {
 *   const peaksData = usePeaksSubscription(trackGuid);
 *
 *   // peaksData is a Map<itemGuid, WSItemPeaks>
 *   return peaksData.size > 0 ? <WaveformRenderer peaks={peaksData} /> : null;
 * }
 * ```
 */

import { useEffect, useRef } from 'react';
import { useReaper } from '../components/ReaperProvider';
import { useReaperStore } from '../store';
import { peaks } from '../core/WebSocketCommands';
import type { WSItemPeaks } from '../core/WebSocketTypes';

/** Default number of peaks per item (for timeline blobs) */
const DEFAULT_SAMPLE_COUNT = 30;

/**
 * Hook to subscribe to peaks for a track
 *
 * @param trackGuid - Track GUID to subscribe to, or null to unsubscribe
 * @param sampleCount - Number of peaks per item (default 30)
 * @returns Map of item GUIDs to peaks data
 */
export function usePeaksSubscription(
  trackGuid: string | null,
  sampleCount: number = DEFAULT_SAMPLE_COUNT
): Map<string, WSItemPeaks> {
  const { sendCommand, connected } = useReaper();
  const setSubscribedTrack = useReaperStore((s) => s.setSubscribedTrack);
  const clearPeaksData = useReaperStore((s) => s.clearPeaksData);
  const peaksData = useReaperStore((s) => s.peaksData);

  // Track previous subscription to avoid duplicate commands
  const prevTrackGuidRef = useRef<string | null>(null);

  useEffect(() => {
    // Skip if not connected
    if (!connected) {
      return;
    }

    // Check if subscription changed
    if (prevTrackGuidRef.current === trackGuid) {
      return;
    }

    // Unsubscribe from previous track
    if (prevTrackGuidRef.current !== null) {
      sendCommand(peaks.unsubscribe());
    }

    // Update ref
    prevTrackGuidRef.current = trackGuid;

    // Subscribe to new track or clear if null
    if (trackGuid) {
      setSubscribedTrack(trackGuid);
      sendCommand(peaks.subscribe(trackGuid, sampleCount));
    } else {
      clearPeaksData();
    }

    // Cleanup on unmount
    return () => {
      if (prevTrackGuidRef.current !== null) {
        sendCommand(peaks.unsubscribe());
        clearPeaksData();
        prevTrackGuidRef.current = null;
      }
    };
  }, [trackGuid, sampleCount, connected, sendCommand, setSubscribedTrack, clearPeaksData]);

  return peaksData;
}
