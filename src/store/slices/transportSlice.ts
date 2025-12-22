/**
 * Transport state slice
 * Manages playback state, position, and transport controls
 */

import type { StateCreator } from 'zustand';
import type { PlayState, TransportState, BeatPosition } from '../../core/types';

export interface TimeSelection {
  /** Start position in beats (tempo-independent) */
  startBeats: number;
  /** End position in beats (tempo-independent) */
  endBeats: number;
}

export interface TransportSlice {
  // State
  playState: PlayState;
  positionSeconds: number;
  positionString: string;
  positionBeats: string;
  isRepeat: boolean;
  isMetronome: boolean;
  isAutoPunch: boolean;
  isCountInRecord: boolean;
  isCountInPlayback: boolean;
  metronomeVolume: number;
  bpm: number | null;
  fullBeatPosition: number;
  timeSignature: string;
  timeSignatureNumerator: number;
  timeSignatureDenominator: number;
  timeSelection: TimeSelection | null;

  // Actions
  updateTransport: (transport: TransportState) => void;
  updateBeatPosition: (beatPos: BeatPosition) => void;
  setPlayState: (state: PlayState) => void;
  setPosition: (seconds: number) => void;
  setRepeat: (repeat: boolean) => void;
  setMetronome: (metronome: boolean) => void;
  setAutoPunch: (autoPunch: boolean) => void;
  setCountInRecord: (enabled: boolean) => void;
  setCountInPlayback: (enabled: boolean) => void;
  setMetronomeVolume: (volume: number) => void;
  setBpm: (bpm: number | null) => void;
  setTimeSelection: (selection: TimeSelection | null) => void;
}

export const createTransportSlice: StateCreator<TransportSlice> = (set, get) => ({
  // Initial state
  playState: 0,
  positionSeconds: 0,
  positionString: '0:00.000',
  positionBeats: '1.1.00',
  isRepeat: false,
  isMetronome: false,
  isAutoPunch: false,
  isCountInRecord: false,
  isCountInPlayback: false,
  metronomeVolume: 0.25, // Default ~-12dB
  bpm: null,
  fullBeatPosition: 0,
  timeSignature: '4/4',
  timeSignatureNumerator: 4,
  timeSignatureDenominator: 4,
  timeSelection: null,

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
    // REAPER's fullBeatPosition counts in denominator beats (eighths for X/8, quarters for X/4)
    // We normalize to quarter-note BPM for consistent display
    let newBpm = get().bpm;
    if (beatPos.positionSeconds > 0.1) {
      const rawBpm = (beatPos.fullBeatPosition / beatPos.positionSeconds) * 60;
      // Normalize to quarter-note BPM: multiply by (4 / denominator)
      // For 4/4: rawBpm * 1 = no change
      // For 6/8: rawBpm * 0.5 = converts eighth-note BPM to quarter-note BPM
      const calculatedBpm = rawBpm * (4 / beatPos.timeSignatureDenominator);
      // Only update if it's a reasonable BPM (20-300)
      if (calculatedBpm >= 20 && calculatedBpm <= 300) {
        newBpm = calculatedBpm;
      }
    }

    set({
      fullBeatPosition: beatPos.fullBeatPosition,
      timeSignature,
      timeSignatureNumerator: beatPos.timeSignatureNumerator,
      timeSignatureDenominator: beatPos.timeSignatureDenominator,
      bpm: newBpm,
    });
  },

  setPlayState: (playState) => set({ playState }),
  setPosition: (positionSeconds) => set({ positionSeconds }),
  setRepeat: (isRepeat) => set({ isRepeat }),
  setMetronome: (isMetronome) => set({ isMetronome }),
  setAutoPunch: (isAutoPunch) => set({ isAutoPunch }),
  setCountInRecord: (isCountInRecord) => set({ isCountInRecord }),
  setCountInPlayback: (isCountInPlayback) => set({ isCountInPlayback }),
  setMetronomeVolume: (metronomeVolume) => set({ metronomeVolume }),
  setBpm: (bpm) => set({ bpm }),
  setTimeSelection: (timeSelection) => set({ timeSelection }),
});
