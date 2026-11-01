/**
 * Tuner Subscription Hook
 * Manages the tuner subscription lifecycle (subscribe/unsubscribe on mount/unmount)
 *
 * Follows the RoutingModal pattern: set store state BEFORE sending command.
 * The backend auto-unsubscribes from any previous track when a new subscribe is sent.
 *
 * @example
 * ```tsx
 * const { subscribe, unsubscribe, isSubscribed } = useTuner();
 *
 * // Subscribe to a track's tuner
 * useEffect(() => {
 *   if (selectedTrackGuid) {
 *     subscribe(selectedTrackGuid);
 *     return () => unsubscribe();
 *   }
 * }, [selectedTrackGuid, subscribe, unsubscribe]);
 * ```
 */

import { useCallback } from 'react';
import { useReaperStore } from '../store';
import { useReaper } from './useReaper';
import { tuner } from '../core/WebSocketCommands';
import {
  savedSettingsToSend,
  saveReferenceHz,
  saveThresholdDb,
  tunerKind,
} from '../views/tuner/tunerStorage';

export interface UseTunerReturn {
  /**
   * Subscribe to tuner on a track (inserts JSFX if first subscriber) or the
   * master. Once REAPER confirms, sends the settings saved on this phone
   * that differ from the tuner's.
   */
  subscribe: (trackGuid: string) => Promise<void>;
  /** Unsubscribe from tuner. Removes JSFX if last subscriber. */
  unsubscribe: () => void;
  /** Whether currently subscribed to a track's tuner */
  isSubscribed: boolean;
  /** GUID of the currently subscribed track (null if not subscribed) */
  subscribedGuid: string | null;
  /** Current tuner data */
  freq: number;
  note: number;
  noteName: string;
  octave: number;
  cents: number;
  conf: number;
  inTune: boolean;
  /** Reference frequency in Hz */
  referenceHz: number;
  /** Set reference frequency (sends command to backend) */
  setReferenceHz: (hz: number, trackGuid: string) => void;
  /** Silence threshold in dB (-90 to -30) */
  thresholdDb: number;
  /** Set silence threshold (sends command to backend) */
  setThresholdDb: (db: number, trackGuid: string) => void;
}

/**
 * Hook to manage tuner subscription lifecycle.
 * Provides subscribe/unsubscribe functions and current tuner state.
 */
export function useTuner(): UseTunerReturn {
  const { sendCommand, sendCommandAsync } = useReaper();

  // Store state
  const subscribedGuid = useReaperStore((s) => s.tunerSubscribedGuid);
  const freq = useReaperStore((s) => s.tunerFreq);
  const note = useReaperStore((s) => s.tunerNote);
  const noteName = useReaperStore((s) => s.tunerNoteName);
  const octave = useReaperStore((s) => s.tunerOctave);
  const cents = useReaperStore((s) => s.tunerCents);
  const conf = useReaperStore((s) => s.tunerConf);
  const inTune = useReaperStore((s) => s.tunerInTune);
  const referenceHz = useReaperStore((s) => s.tunerReferenceHz);
  const thresholdDb = useReaperStore((s) => s.tunerThresholdDb);

  // Store actions
  const setTunerSubscription = useReaperStore((s) => s.setTunerSubscription);
  const clearTunerSubscription = useReaperStore((s) => s.clearTunerSubscription);
  const setTunerReferenceHz = useReaperStore((s) => s.setTunerReferenceHz);
  const setTunerThresholdDb = useReaperStore((s) => s.setTunerThresholdDb);

  // Subscribe to tuner on a track, then apply the settings saved on this
  // phone: before REAPER confirms, a setParam would be refused (the tuner
  // isn't open), and the first event would put the tuner's own back.
  const subscribe = useCallback(
    async (trackGuid: string) => {
      // 1. Set store state first (prepares to receive events)
      setTunerSubscription(trackGuid);

      // 2. Send subscribe command
      let response: { success?: boolean; payload?: { reference?: number; threshold?: number } };
      try {
        response = (await sendCommandAsync(tuner.subscribe(trackGuid))) as typeof response;
      } catch {
        return; // not connected, or no answer: the page re-subscribes on reconnect
      }
      if (!response?.success || useReaperStore.getState().tunerSubscribedGuid !== trackGuid) return;
      const reported = response.payload;
      if (typeof reported?.reference !== 'number' || typeof reported?.threshold !== 'number') return;

      // 3. The saved settings that differ from the tuner's
      for (const [param, value] of savedSettingsToSend(tunerKind(trackGuid), {
        referenceHz: reported.reference,
        thresholdDb: reported.threshold,
      })) {
        if (param === 'reference') setTunerReferenceHz(value);
        else setTunerThresholdDb(value);
        sendCommand(tuner.setParam(trackGuid, param, value));
      }
    },
    [sendCommand, sendCommandAsync, setTunerSubscription, setTunerReferenceHz, setTunerThresholdDb]
  );

  // Unsubscribe from tuner
  const unsubscribe = useCallback(() => {
    // Send unsubscribe command
    sendCommand(tuner.unsubscribe());

    // Clear subscription state
    clearTunerSubscription();
  }, [sendCommand, clearTunerSubscription]);

  // Set reference frequency
  const setReferenceHz = useCallback(
    (hz: number, trackGuid: string) => {
      // Update local state
      setTunerReferenceHz(hz);

      // Send command to backend
      sendCommand(tuner.setParam(trackGuid, 'reference', hz));

      // Persist to localStorage
      saveReferenceHz(hz);
    },
    [sendCommand, setTunerReferenceHz]
  );

  // Set silence threshold
  const setThresholdDb = useCallback(
    (db: number, trackGuid: string) => {
      // Update local state
      setTunerThresholdDb(db);

      // Send command to backend
      sendCommand(tuner.setParam(trackGuid, 'threshold', db));

      // Persist to localStorage, per kind of tuner (tunerStorage.ts)
      saveThresholdDb(tunerKind(trackGuid), db);
    },
    [sendCommand, setTunerThresholdDb]
  );

  return {
    subscribe,
    unsubscribe,
    isSubscribed: subscribedGuid !== null,
    subscribedGuid,
    freq,
    note,
    noteName,
    octave,
    cents,
    conf,
    inTune,
    referenceHz,
    setReferenceHz,
    thresholdDb,
    setThresholdDb,
  };
}
