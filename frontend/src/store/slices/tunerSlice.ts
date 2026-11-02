/**
 * Tuner state slice
 * Manages tuner subscription and real-time pitch detection data from backend (30Hz)
 *
 * Used by TunerView for chromatic tuning with visual feedback.
 * Only one track can be subscribed at a time per client.
 */

import type { StateCreator } from 'zustand';
import type { TunerEventPayload, TunerState } from '../../core/WebSocketTypes';

/** Why the tuner can't tune the chosen track, as REAPER says it. */
export interface TunerProblem {
  code: string;
  message: string;
}

/** Nothing heard yet, and nothing known about what the tuner can hear. */
const NO_READING = {
  tunerFreq: 0,
  tunerNote: 0,
  tunerNoteName: '',
  tunerOctave: 0,
  tunerCents: 0,
  tunerConf: 0,
  tunerInTune: false,
  tunerState: null,
  tunerProblem: null,
} as const;

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
  /** What the tuner can hear, from the latest event (null before one, or from an older extension) */
  tunerState: TunerState | null;
  /** Why the chosen track can't be tuned: a refused subscribe, or a cantTune event */
  tunerProblem: TunerProblem | null;

  // Settings (persisted to localStorage separately)
  tunerReferenceHz: number;
  /**
   * Silence threshold in dB (-90 to -30). Signals below this are ignored.
   * The tuner reports its own in every event; this is what shows until the
   * first arrives.
   */
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
  /** Record why REAPER refused to tune the chosen track (null to clear) */
  setTunerProblem: (problem: TunerProblem | null) => void;
}

export const createTunerSlice: StateCreator<TunerSlice, [], [], TunerSlice> = (set, get) => ({
  // Initial state
  tunerSubscribedGuid: null,
  ...NO_READING,
  tunerReferenceHz: 440,
  tunerThresholdDb: -90,

  setTunerSubscription: (trackGuid) =>
    set({
      tunerSubscribedGuid: trackGuid,
      // Clear old data when subscription changes
      ...NO_READING,
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
      tunerState: payload.state ?? null,
      tunerProblem:
        payload.state === 'cantTune' ? { code: payload.code ?? '', message: payload.message ?? '' } : null,
      // Multi-client sync: update settings if changed by another client
      tunerReferenceHz: payload.referenceHz,
      tunerThresholdDb: payload.thresholdDb,
    });
  },

  handleTunerError: (_error) => {
    // Auto-unsubscribed by backend, clear local state
    set({ tunerSubscribedGuid: null, ...NO_READING });
  },

  clearTunerSubscription: () => set({ tunerSubscribedGuid: null, ...NO_READING }),

  setTunerProblem: (problem) => set({ tunerProblem: problem }),

  setTunerReferenceHz: (hz) => set({ tunerReferenceHz: hz }),

  setTunerThresholdDb: (db) => set({ tunerThresholdDb: db }),
});
