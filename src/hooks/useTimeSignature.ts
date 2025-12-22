/**
 * Hook for accessing parsed time signature values from the store
 *
 * Provides beatsPerBar (numerator) and denominator directly from the store,
 * eliminating the need to parse the "4/4" string in each component.
 */

import { useReaperStore } from '../store';

export interface UseTimeSignatureReturn {
  /** Number of beats per bar (numerator), e.g., 6 for 6/8 */
  beatsPerBar: number;
  /** Note value that gets one beat (denominator), e.g., 8 for 6/8 */
  denominator: number;
}

export function useTimeSignature(): UseTimeSignatureReturn {
  const beatsPerBar = useReaperStore((s) => s.timeSignatureNumerator);
  const denominator = useReaperStore((s) => s.timeSignatureDenominator);
  return { beatsPerBar, denominator };
}
