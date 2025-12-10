/**
 * Transport state slice
 * Manages playback state, position, and transport controls
 */

import type { StateCreator } from 'zustand';
import type { PlayState, TransportState, BeatPosition } from '../../core/types';

export interface TransportSlice {
  // State
  playState: PlayState;
  positionSeconds: number;
  positionString: string;
  positionBeats: string;
  isRepeat: boolean;
  bpm: number | null;
  fullBeatPosition: number;
  timeSignature: string;

  // Actions
  updateTransport: (transport: TransportState) => void;
  updateBeatPosition: (beatPos: BeatPosition) => void;
  setPlayState: (state: PlayState) => void;
  setPosition: (seconds: number) => void;
  setRepeat: (repeat: boolean) => void;
  setBpm: (bpm: number | null) => void;
}

export const createTransportSlice: StateCreator<TransportSlice> = (set, get) => ({
  // Initial state
  playState: 0,
  positionSeconds: 0,
  positionString: '0:00.000',
  positionBeats: '1.1.00',
  isRepeat: false,
  bpm: null,
  fullBeatPosition: 0,
  timeSignature: '4/4',

  // Actions
  updateTransport: (transport) =>
    set({
      playState: transport.playState,
      positionSeconds: transport.positionSeconds,
      positionString: transport.positionString,
      positionBeats: transport.positionBeats,
      isRepeat: transport.isRepeat,
    }),

  updateBeatPosition: (beatPos) => {
    const timeSignature = `${beatPos.timeSignatureNumerator}/${beatPos.timeSignatureDenominator}`;

    // Calculate BPM from beat position if we have a valid position
    // BPM = (beats / seconds) * 60
    let newBpm = get().bpm;
    if (beatPos.positionSeconds > 0.1) {
      const calculatedBpm = (beatPos.fullBeatPosition / beatPos.positionSeconds) * 60;
      // Only update if it's a reasonable BPM (20-300)
      if (calculatedBpm >= 20 && calculatedBpm <= 300) {
        newBpm = calculatedBpm;
      }
    }

    set({
      fullBeatPosition: beatPos.fullBeatPosition,
      timeSignature,
      bpm: newBpm,
    });
  },

  setPlayState: (playState) => set({ playState }),
  setPosition: (positionSeconds) => set({ positionSeconds }),
  setRepeat: (isRepeat) => set({ isRepeat }),
  setBpm: (bpm) => set({ bpm }),
});
