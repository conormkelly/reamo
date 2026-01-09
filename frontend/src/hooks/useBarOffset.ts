/**
 * Hook for getting the project's bar offset from REAPER
 *
 * Bar offset accounts for projects that don't start at bar 1
 * (e.g., starting at bar -4 for a 4-bar count-in, or bar 69 for a late start).
 *
 * This value is now sent directly from the REAPER extension via WebSocket.
 *
 * @example
 * ```tsx
 * function BarDisplay({ seconds }: { seconds: number }) {
 *   const barOffset = useBarOffset();
 *   const bpm = useReaperStore((s) => s.bpm);
 *   const bar = bpm ? Math.floor(seconds / (60 / bpm) / 4) + barOffset : 0;
 *   return <span>Bar {bar}</span>;
 * }
 * ```
 */

import { useReaperStore } from '../store';

export function useBarOffset(): number {
  return useReaperStore((s) => s.barOffset);
}
