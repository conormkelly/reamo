/**
 * Audio monitor state slice
 * Manages audio monitoring (binary PCM streaming from REAPER) state
 */

import type { StateCreator } from 'zustand';
import type { AudioMonitorState } from '../../audio/AudioStreamManager';

export interface AudioMonitorSlice {
  /** Current audio monitoring pipeline state */
  audioMonitorState: AudioMonitorState;
  /** Whether the user has requested monitoring (persists across reconnects) */
  audioMonitorRequested: boolean;
  /** Current project sample rate from server (Hz) */
  sampleRate: number;

  setAudioMonitorState: (state: AudioMonitorState) => void;
  setAudioMonitorRequested: (requested: boolean) => void;
  setSampleRate: (rate: number) => void;
}

export const createAudioMonitorSlice: StateCreator<AudioMonitorSlice> = (set) => ({
  audioMonitorState: 'stopped',
  audioMonitorRequested: false,
  sampleRate: 48000,

  setAudioMonitorState: (state) => set({ audioMonitorState: state }),
  setAudioMonitorRequested: (requested) => set({ audioMonitorRequested: requested }),
  setSampleRate: (rate) => set({ sampleRate: rate }),
});
