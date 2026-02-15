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

  setAudioMonitorState: (state: AudioMonitorState) => void;
  setAudioMonitorRequested: (requested: boolean) => void;
}

export const createAudioMonitorSlice: StateCreator<AudioMonitorSlice> = (set) => ({
  audioMonitorState: 'stopped',
  audioMonitorRequested: false,

  setAudioMonitorState: (state) => set({ audioMonitorState: state }),
  setAudioMonitorRequested: (requested) => set({ audioMonitorRequested: requested }),
});
