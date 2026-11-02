/**
 * tunerSlice: what the tuner can hear, and why it can't tune, from its
 * events.
 */

import { describe, it, expect, beforeEach } from 'vitest';
import { useReaperStore } from '..';
import type { TunerEventPayload } from '../../core/WebSocketTypes';

const TRACK = '{TRACK-GUID-0001}';

function event(overrides: Partial<TunerEventPayload> = {}): TunerEventPayload {
  return {
    trackGuid: TRACK,
    freq: 0,
    note: 0,
    noteName: 'C',
    octave: -1,
    cents: 0,
    clarity: 0,
    conf: 0,
    inTune: false,
    referenceHz: 440,
    thresholdDb: -90,
    state: 'listening',
    ...overrides,
  };
}

describe('tunerSlice', () => {
  beforeEach(() => {
    useReaperStore.getState().clearTunerSubscription();
    useReaperStore.getState().setTunerSubscription(TRACK);
  });

  it('keeps why the track can\'t be tuned while events say so, and drops it when tuning resumes', () => {
    const s = useReaperStore.getState();
    s.handleTunerEvent(event({ state: 'cantTune', code: 'INPUT_NONE', message: 'No record input.' }));
    expect(useReaperStore.getState().tunerState).toBe('cantTune');
    expect(useReaperStore.getState().tunerProblem).toEqual({ code: 'INPUT_NONE', message: 'No record input.' });

    s.handleTunerEvent(event({ freq: 220, note: 57, noteName: 'A', octave: 3 }));
    expect(useReaperStore.getState().tunerState).toBe('listening');
    expect(useReaperStore.getState().tunerProblem).toBeNull();
    expect(useReaperStore.getState().tunerFreq).toBe(220);
  });

  it('says when REAPER has the audio device closed', () => {
    useReaperStore.getState().handleTunerEvent(event({ state: 'deviceClosed' }));
    expect(useReaperStore.getState().tunerState).toBe('deviceClosed');
    expect(useReaperStore.getState().tunerProblem).toBeNull();
  });

  it('takes an event without a state, from an older extension, as listening to nothing in particular', () => {
    const { state: _state, ...old } = event();
    useReaperStore.getState().handleTunerEvent(old);
    expect(useReaperStore.getState().tunerState).toBeNull();
  });

  it('ignores events for a tuner the phone has left', () => {
    useReaperStore.getState().handleTunerEvent(event({ trackGuid: '{OTHER}', state: 'deviceClosed' }));
    expect(useReaperStore.getState().tunerState).toBeNull();
  });

  it('forgets the state and any problem when the subscription changes or ends', () => {
    const s = useReaperStore.getState();
    s.setTunerProblem({ code: 'INPUT_MIDI', message: 'MIDI.' });
    s.setTunerSubscription('{ANOTHER}');
    expect(useReaperStore.getState().tunerProblem).toBeNull();
    s.handleTunerEvent(event({ trackGuid: '{ANOTHER}', state: 'deviceClosed' }));
    s.handleTunerError('TUNER_NOT_FOUND');
    expect(useReaperStore.getState().tunerState).toBeNull();
    expect(useReaperStore.getState().tunerSubscribedGuid).toBeNull();
  });
});
