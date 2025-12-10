/**
 * Transport state slice
 * Manages playback state, position, and transport controls
 */

import type { StateCreator } from 'zustand';
import type { PlayState, TransportState } from '../../core/types';

export interface TransportSlice {
  // State
  playState: PlayState;
  positionSeconds: number;
  positionString: string;
  positionBeats: string;
  isRepeat: boolean;

  // Actions
  updateTransport: (transport: TransportState) => void;
  setPlayState: (state: PlayState) => void;
  setPosition: (seconds: number) => void;
  setRepeat: (repeat: boolean) => void;
}

export const createTransportSlice: StateCreator<TransportSlice> = (set) => ({
  // Initial state
  playState: 0,
  positionSeconds: 0,
  positionString: '0:00.000',
  positionBeats: '1.1.00',
  isRepeat: false,

  // Actions
  updateTransport: (transport) =>
    set({
      playState: transport.playState,
      positionSeconds: transport.positionSeconds,
      positionString: transport.positionString,
      positionBeats: transport.positionBeats,
      isRepeat: transport.isRepeat,
    }),

  setPlayState: (playState) => set({ playState }),
  setPosition: (positionSeconds) => set({ positionSeconds }),
  setRepeat: (isRepeat) => set({ isRepeat }),
});
