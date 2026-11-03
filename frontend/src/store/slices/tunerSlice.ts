/**
 * Tuner state slice
 * Manages tuner subscription and real-time pitch detection data from backend
 * (each change at its 30 Hz poll, and a reading that holds every 250 ms)
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
  tunerStarting: false,
  tunerSettling: false,
  tunerStable: false,
  tunerMultiple: false,
  tunerState: null,
  tunerProblem: null,
  tunerHeard: false,
} as const;

export interface TunerSlice {
  // Subscription state
  /** GUID of the currently subscribed track (null = not subscribed) */
  tunerSubscribedGuid: string | null;

  // Current tuner data (from the latest event)
  tunerFreq: number;
  tunerNote: number;
  tunerNoteName: string;
  tunerOctave: number;
  tunerCents: number;
  tunerConf: number;
  /** The backend's in-tune window (a pitch, and |cents| < 2): not a reading to tune by unless `tunerStable` */
  tunerInTune: boolean;
  /**
   * The analyser's flags for the reading (false when an event has none: an
   * extension whose track tuner was a JSFX, which can't tell them).
   * - starting: a note has begun but its name is held back (~0.1 s); no pitch yet
   * - settling: the note's attack; the name is known, the cents not yet
   * - stable: the pitch has held still; the only reading to tune by
   * - multiple: several notes sound; a reading is one of them
   */
  tunerStarting: boolean;
  tunerSettling: boolean;
  tunerStable: boolean;
  tunerMultiple: boolean;
  /** What the tuner can hear, from the latest event (null before one, or from an older extension) */
  tunerState: TunerState | null;
  /** Why the chosen track can't be tuned: a refused subscribe, or a cantTune event */
  tunerProblem: TunerProblem | null;
  /** Whether an event has come for this subscription: until one has, nothing above is REAPER's */
  tunerHeard: boolean;
  /**
   * Changes with every event taken and every change of subscription, for a
   * reading's freshness to be timed from (useTuner's `stale`).
   */
  tunerEventSeq: number;

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
  /** Handle incoming tuner event from backend */
  handleTunerEvent: (payload: TunerEventPayload) => void;
  /**
   * Handle a tuner error: the backend has unsubscribed the phone from the
   * source it names. One about a source the phone has since left is
   * ignored; one naming none (an older extension) ends the subscription.
   */
  handleTunerError: (error: string, trackGuid?: string) => void;
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
  tunerEventSeq: 0,
  tunerReferenceHz: 440,
  tunerThresholdDb: -90,

  setTunerSubscription: (trackGuid) =>
    set((s) => ({
      tunerSubscribedGuid: trackGuid,
      // Clear old data when subscription changes
      ...NO_READING,
      tunerEventSeq: s.tunerEventSeq + 1,
    })),

  handleTunerEvent: (payload) => {
    const currentGuid = get().tunerSubscribedGuid;
    if (!currentGuid || payload.trackGuid !== currentGuid) return;

    set((s) => ({
      tunerHeard: true,
      tunerEventSeq: s.tunerEventSeq + 1,
      tunerFreq: payload.freq,
      tunerNote: payload.note,
      tunerNoteName: payload.noteName,
      tunerOctave: payload.octave,
      tunerCents: payload.cents,
      tunerConf: payload.conf,
      tunerInTune: payload.inTune,
      tunerStarting: payload.starting === true,
      tunerSettling: payload.settling === true,
      tunerStable: payload.stable === true,
      tunerMultiple: payload.multiple === true,
      tunerState: payload.state ?? null,
      tunerProblem:
        payload.state === 'cantTune' ? { code: payload.code ?? '', message: payload.message ?? '' } : null,
      // Multi-client sync: update settings if changed by another client
      tunerReferenceHz: payload.referenceHz,
      tunerThresholdDb: payload.thresholdDb,
    }));
  },

  handleTunerError: (_error, trackGuid) => {
    if (trackGuid !== undefined && trackGuid !== get().tunerSubscribedGuid) return;
    // Auto-unsubscribed by backend, clear local state
    set((s) => ({ tunerSubscribedGuid: null, ...NO_READING, tunerEventSeq: s.tunerEventSeq + 1 }));
  },

  clearTunerSubscription: () =>
    set((s) => ({ tunerSubscribedGuid: null, ...NO_READING, tunerEventSeq: s.tunerEventSeq + 1 })),

  setTunerProblem: (problem) => set({ tunerProblem: problem }),

  setTunerReferenceHz: (hz) => set({ tunerReferenceHz: hz }),

  setTunerThresholdDb: (db) => set({ tunerThresholdDb: db }),
});
