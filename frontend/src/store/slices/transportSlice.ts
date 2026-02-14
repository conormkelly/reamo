/**
 * Transport state slice
 * Manages playback state, position, and transport controls
 */

import type { StateCreator } from 'zustand';
import type { PlayState, TransportState, BeatPosition } from '../../core/types';

export interface TimeSelection {
  /** Start position in seconds */
  startSeconds: number;
  /** End position in seconds */
  endSeconds: number;
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
  isPreRollPlay: boolean;
  isPreRollRecord: boolean;
  metronomeVolume: number;
  masterStereo: boolean; // Master track stereo mode (false = mono)
  bpm: number | null;
  fullBeatPosition: number;
  timeSignatureNumerator: number;
  timeSignatureDenominator: number;
  timeSelection: TimeSelection | null;
  barOffset: number;

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
  setPreRollPlay: (enabled: boolean) => void;
  setPreRollRecord: (enabled: boolean) => void;
  setMetronomeVolume: (volume: number) => void;
  setMasterStereo: (stereo: boolean) => void;
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
  isPreRollPlay: false,
  isPreRollRecord: false,
  metronomeVolume: 0.25, // Default ~-12dB
  masterStereo: true, // Default is stereo
  bpm: null,
  fullBeatPosition: 0,
  timeSignatureNumerator: 4,
  timeSignatureDenominator: 4,
  timeSelection: null,
  barOffset: 0,

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
  setPreRollPlay: (isPreRollPlay) => set({ isPreRollPlay }),
  setPreRollRecord: (isPreRollRecord) => set({ isPreRollRecord }),
  setMetronomeVolume: (metronomeVolume) => set({ metronomeVolume }),
  setMasterStereo: (masterStereo) => set({ masterStereo }),
  setBpm: (bpm) => set({ bpm }),
  setTimeSelection: (timeSelection) => set({ timeSelection }),
});
