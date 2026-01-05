/**
 * Sends State slice
 * Manages send routing data broadcast at 5Hz from the extension
 * This is a flat list of all sends across all tracks (flattened data model)
 */

import type { StateCreator } from 'zustand';
import type { WSSendSlot } from '../../core/WebSocketTypes';

export interface SendsStateSlice {
  // State
  sends: WSSendSlot[];

  // Actions
  setSends: (sends: WSSendSlot[]) => void;
}

/**
 * Get sends originating from a specific track
 */
export function getSendsFromTrack(sends: WSSendSlot[], srcTrackIdx: number): WSSendSlot[] {
  return sends.filter((s) => s.srcTrackIdx === srcTrackIdx);
}

/**
 * Get sends going to a specific track (receives)
 */
export function getSendsToTrack(sends: WSSendSlot[], destTrackIdx: number): WSSendSlot[] {
  return sends.filter((s) => s.destTrackIdx === destTrackIdx);
}

export const createSendsStateSlice: StateCreator<SendsStateSlice> = (set) => ({
  // Initial state
  sends: [],

  // Actions
  setSends: (sends) => set({ sends }),
});
