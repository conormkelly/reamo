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

function flags() {
  const t = useReaperStore.getState();
  return { starting: t.tunerStarting, settling: t.tunerSettling, stable: t.tunerStable, multiple: t.tunerMultiple };
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

  it("carries the analyser's starting, settling, stable and multiple flags of each reading", () => {
    const s = useReaperStore.getState();
    s.handleTunerEvent(event({ starting: true }));
    expect(flags()).toEqual({ starting: true, settling: false, stable: false, multiple: false });
    s.handleTunerEvent(event({ freq: 82.4, note: 40, noteName: 'E', octave: 2, settling: true, multiple: true }));
    expect(flags()).toEqual({ starting: false, settling: true, stable: false, multiple: true });
    s.handleTunerEvent(event({ freq: 82.4, note: 40, noteName: 'E', octave: 2, stable: true }));
    expect(flags()).toEqual({ starting: false, settling: false, stable: true, multiple: false });
  });

  it('takes a reading without flags as never stable, so it is never shown in tune', () => {
    const s = useReaperStore.getState();
    s.handleTunerEvent(event({ freq: 440, note: 69, noteName: 'A', octave: 4, inTune: true, stable: true }));
    const { settling: _a, stable: _b, multiple: _c, starting: _d, ...noFlags } = event({
      freq: 440, note: 69, noteName: 'A', octave: 4, inTune: true,
    });
    s.handleTunerEvent(noFlags);
    expect(flags()).toEqual({ starting: false, settling: false, stable: false, multiple: false });
  });

  it('forgets the flags when the subscription changes or ends, so another source never inherits stable', () => {
    const s = useReaperStore.getState();
    const stableA = event({ freq: 440, note: 69, noteName: 'A', octave: 4, inTune: true, stable: true, multiple: true });
    s.handleTunerEvent(stableA);
    s.setTunerSubscription('master');
    expect(flags()).toEqual({ starting: false, settling: false, stable: false, multiple: false });
    s.handleTunerEvent({ ...stableA, trackGuid: 'master' });
    s.clearTunerSubscription();
    expect(flags()).toEqual({ starting: false, settling: false, stable: false, multiple: false });
    s.setTunerSubscription(TRACK);
    s.handleTunerEvent(stableA);
    s.handleTunerError('TUNER_NOT_FOUND');
    expect(flags()).toEqual({ starting: false, settling: false, stable: false, multiple: false });
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
