/**
 * FX State slice
 * Manages FX chain data broadcast at 5Hz from the extension
 * This is a flat list of all FX across all tracks (flattened data model)
 */

import type { StateCreator } from 'zustand';
import type { WSFxSlot } from '../../core/WebSocketTypes';

export interface FxStateSlice {
  // State
  fx: WSFxSlot[];

  // Actions
  setFx: (fx: WSFxSlot[]) => void;
}

/**
 * Get FX for a specific track
 */
export function getFxForTrack(fx: WSFxSlot[], trackIdx: number): WSFxSlot[] {
  return fx.filter((f) => f.trackIdx === trackIdx);
}

export const createFxStateSlice: StateCreator<FxStateSlice> = (set) => ({
  // Initial state
  fx: [],

  // Actions
  setFx: (fx) => set({ fx }),
});
