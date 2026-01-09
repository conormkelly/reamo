/**
 * usePeakHold - Peak hold behavior for audio meters
 *
 * Holds the highest peak value for a duration before dropping.
 * Mimics REAPER's native meter behavior where you can see "sound came through".
 *
 * @param currentPeak - Current peak value in dB
 * @param holdDurationMs - How long to hold peak before dropping (default: 1000ms)
 * @returns The held peak value to display
 *
 * @example
 * ```tsx
 * function PeakMeter({ peakDb }: { peakDb: number }) {
 *   const heldPeak = usePeakHold(peakDb, 1000);
 *   return (
 *     <div className="meter">
 *       <div className="current" style={{ height: `${peakDb + 60}%` }} />
 *       <div className="peak-indicator" style={{ bottom: `${heldPeak + 60}%` }} />
 *     </div>
 *   );
 * }
 * ```
 */

import { useState, useEffect, useRef } from 'react';

export function usePeakHold(currentPeak: number, holdDurationMs: number = 1000): number {
  const [heldPeak, setHeldPeak] = useState(currentPeak);
  const timeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const currentPeakRef = useRef(currentPeak);

  // Keep ref in sync so timeout callback can read latest value
  currentPeakRef.current = currentPeak;

  // Update heldPeak when current exceeds it
  useEffect(() => {
    if (currentPeak > heldPeak) {
      setHeldPeak(currentPeak);
    }
  }, [currentPeak, heldPeak]);

  // Schedule drop whenever heldPeak changes (including initial)
  useEffect(() => {
    timeoutRef.current = setTimeout(() => {
      setHeldPeak(currentPeakRef.current);
    }, holdDurationMs);

    return () => {
      if (timeoutRef.current) {
        clearTimeout(timeoutRef.current);
      }
    };
  }, [heldPeak, holdDurationMs]);

  return heldPeak;
}
