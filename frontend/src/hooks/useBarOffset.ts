/**
 * Hook for getting the project's bar offset from REAPER
 *
 * Bar offset accounts for projects that don't start at bar 1
 * (e.g., starting at bar -4 for a 4-bar count-in, or bar 69 for a late start).
 *
 * This value is now sent directly from the REAPER extension via WebSocket.
 */

import { useReaperStore } from '../store';

export function useBarOffset(): number {
  return useReaperStore((s) => s.barOffset);
}
