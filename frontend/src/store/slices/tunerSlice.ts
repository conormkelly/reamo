/**
 * Tuner state slice
 * Manages tuner subscription and real-time pitch detection data from backend (30Hz)
 *
 * Used by TunerView for chromatic tuning with visual feedback.
 * Only one track can be subscribed at a time per client.
 */

import type { StateCreator } from 'zustand';
import type { TunerEventPayload } from '../../core/WebSocketTypes';

export interface TunerSlice {
  // Subscription state
  /** GUID of the currently subscribed track (null = not subscribed) */
  tunerSubscribedGuid: string | null;

  // Current tuner data (from 30Hz events)
  tunerFreq: number;
  tunerNote: number;
  tunerNoteName: string;
  tunerOctave: number;
  tunerCents: number;
  tunerConf: number;
  tunerInTune: boolean;

  // Settings (persisted to localStorage separately)
  tunerReferenceHz: number;
  /** Silence threshold in dB (-90 to -30). Signals below this are ignored. */
  tunerThresholdDb: number;

  // Actions
  /** Set subscription state (call before sending tuner/subscribe command) */
  setTunerSubscription: (trackGuid: string | null) => void;
  /** Handle incoming tuner event from backend (30Hz) */
  handleTunerEvent: (payload: TunerEventPayload) => void;
  /** Handle tuner error (auto-unsubscribes) */
  handleTunerError: (error: string) => void;
  /** Clear subscription and data (call after sending tuner/unsubscribe command) */
  clearTunerSubscription: () => void;
  /** Update reference Hz (local state only - use sendCommand for backend) */
  setTunerReferenceHz: (hz: number) => void;
  /** Update threshold dB (local state only - use sendCommand for backend) */
  setTunerThresholdDb: (db: number) => void;
}

export const createTunerSlice: StateCreator<TunerSlice, [], [], TunerSlice> = (set, get) => ({
  // Initial state
  tunerSubscribedGuid: null,
  tunerFreq: 0,
  tunerNote: 0,
  tunerNoteName: '',
  tunerOctave: 0,
  tunerCents: 0,
  tunerConf: 0,
  tunerInTune: false,
  tunerReferenceHz: 440,
  tunerThresholdDb: -60,

  setTunerSubscription: (trackGuid) =>
    set({
      tunerSubscribedGuid: trackGuid,
      // Clear old data when subscription changes
      tunerFreq: 0,
      tunerNote: 0,
      tunerNoteName: '',
      tunerOctave: 0,
      tunerCents: 0,
      tunerConf: 0,
      tunerInTune: false,
    }),

  handleTunerEvent: (payload) => {
    const currentGuid = get().tunerSubscribedGuid;
    if (!currentGuid || payload.trackGuid !== currentGuid) return;

    set({
      tunerFreq: payload.freq,
      tunerNote: payload.note,
      tunerNoteName: payload.noteName,
      tunerOctave: payload.octave,
      tunerCents: payload.cents,
      tunerConf: payload.conf,
      tunerInTune: payload.inTune,
      // Multi-client sync: update settings if changed by another client
      tunerReferenceHz: payload.referenceHz,
      tunerThresholdDb: payload.thresholdDb,
    });
  },

  handleTunerError: (_error) => {
    // Auto-unsubscribed by backend, clear local state
    set({
      tunerSubscribedGuid: null,
      tunerFreq: 0,
      tunerNote: 0,
      tunerNoteName: '',
      tunerOctave: 0,
      tunerCents: 0,
      tunerConf: 0,
      tunerInTune: false,
    });
  },

  clearTunerSubscription: () =>
    set({
      tunerSubscribedGuid: null,
      tunerFreq: 0,
      tunerNote: 0,
      tunerNoteName: '',
      tunerOctave: 0,
      tunerCents: 0,
      tunerConf: 0,
      tunerInTune: false,
    }),

  setTunerReferenceHz: (hz) => set({ tunerReferenceHz: hz }),

  setTunerThresholdDb: (db) => set({ tunerThresholdDb: db }),
});
