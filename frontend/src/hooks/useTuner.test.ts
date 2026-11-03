/**
 * useTuner: saved settings reach the tuner only once it is open, and the
 * master's threshold is kept apart from the tracks'.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';

// Vitest 4.x: setup.ts pre-caches modules before vi.mock can intercept.
vi.hoisted(() => vi.resetModules());

const mockSendCommand = vi.fn();
const mockSendCommandAsync = vi.fn();

vi.mock('./useReaper', () => ({
  useReaper: vi.fn(() => ({
    sendCommand: mockSendCommand,
    sendCommandAsync: mockSendCommandAsync,
  })),
}));

import { useTuner, TUNER_STALE_MS, SEVERAL_HOLD_MS } from './useTuner';
import { TUNER_RESEND_MS } from '../core/WebSocketTypes';
import type { TunerEventPayload } from '../core/WebSocketTypes';
import { useReaperStore } from '../store';

const TRACK = '{TRACK-GUID-0001}';

type Response = {
  success: boolean;
  payload?: { reference: number; threshold: number };
  error?: { code: string; message: string };
};

/** The subscribe's response, released by the test. */
function pendingSubscribe(): (r: Response) => Promise<void> {
  let resolve!: (r: Response) => void;
  mockSendCommandAsync.mockReturnValueOnce(new Promise<Response>((res) => (resolve = res)));
  return async (r) => {
    await act(async () => {
      resolve(r);
    });
  };
}

function setParams(): Array<[string, number]> {
  return mockSendCommand.mock.calls
    .map(([cmd]) => cmd as { command: string; params: { param: string; value: number } })
    .filter((cmd) => cmd.command === 'tuner/setParam')
    .map((cmd) => [cmd.params.param, cmd.params.value]);
}

describe('useTuner', () => {
  beforeEach(() => {
    localStorage.clear();
    mockSendCommand.mockReset();
    mockSendCommandAsync.mockReset();
    useReaperStore.getState().clearTunerSubscription();
  });

  it('sends saved settings only after the subscribe succeeds, against what the tuner reports', async () => {
    localStorage.setItem('tuner-reference', '442');
    localStorage.setItem('tuner-threshold-track', '-90'); // the analyser's own value: nothing to send
    const respond = pendingSubscribe();
    const { result } = renderHook(() => useTuner());

    act(() => {
      void result.current.subscribe(TRACK);
    });
    // The tuner isn't open yet: a setParam now would be refused (NOT_SUBSCRIBED).
    expect(setParams()).toEqual([]);

    await respond({ success: true, payload: { reference: 440, threshold: -90 } });
    expect(setParams()).toEqual([['reference', 442]]);
    expect(useReaperStore.getState().tunerReferenceHz).toBe(442);
  });

  it('sends nothing when the subscribe fails', async () => {
    localStorage.setItem('tuner-reference', '442');
    const respond = pendingSubscribe();
    const { result } = renderHook(() => useTuner());
    act(() => {
      void result.current.subscribe(TRACK);
    });
    await respond({ success: false });
    expect(setParams()).toEqual([]);
  });

  it('sends nothing for a tuner the phone has moved off while the subscribe was answered', async () => {
    localStorage.setItem('tuner-reference', '442');
    const respond = pendingSubscribe();
    const { result } = renderHook(() => useTuner());
    act(() => {
      void result.current.subscribe(TRACK);
    });
    act(() => {
      result.current.unsubscribe();
    });
    await respond({ success: true, payload: { reference: 440, threshold: -60 } });
    expect(setParams()).toEqual([]);
  });

  it("never applies a track tuner's saved threshold to the master", async () => {
    // A track tuner's threshold, saved on this phone.
    localStorage.setItem('tuner-threshold-track', '-60');
    const respond = pendingSubscribe();
    const { result } = renderHook(() => useTuner());
    act(() => {
      void result.current.subscribe('master');
    });
    await respond({ success: true, payload: { reference: 440, threshold: -90 } });
    expect(setParams()).toEqual([]);
  });

  it('saves a threshold set on the master under its own key', () => {
    const { result } = renderHook(() => useTuner());
    act(() => {
      result.current.setThresholdDb(-70, 'master');
    });
    expect(localStorage.getItem('tuner-threshold-master')).toBe('-70');
    expect(localStorage.getItem('tuner-threshold-track')).toBeNull();
    act(() => {
      result.current.setThresholdDb(-50, TRACK);
    });
    expect(localStorage.getItem('tuner-threshold-track')).toBe('-50');
    expect(localStorage.getItem('tuner-threshold-master')).toBe('-70');
    expect(localStorage.getItem('tuner-threshold')).toBeNull();
  });

  it("sends the saved settings after a refusal for the track's input, which the phone still follows", async () => {
    localStorage.setItem('tuner-reference', '442');
    localStorage.setItem('tuner-threshold-track', '-70');
    const respond = pendingSubscribe();
    const { result } = renderHook(() => useTuner());
    act(() => {
      void result.current.subscribe(TRACK);
    });
    await respond({ success: false, error: { code: 'INPUT_NONE', message: 'No record input.' } });
    // Tuning starts at 442 once the user gives the track an input.
    expect(setParams()).toEqual([
      ['reference', 442],
      ['threshold', -70],
    ]);
    expect(useReaperStore.getState().tunerReferenceHz).toBe(442);
  });

  it('sends nothing after a refusal that leaves the phone on no tuner', async () => {
    localStorage.setItem('tuner-reference', '442');
    const respond = pendingSubscribe();
    const { result } = renderHook(() => useTuner());
    act(() => {
      void result.current.subscribe(TRACK);
    });
    await respond({ success: false, error: { code: 'TRACK_NOT_FOUND', message: 'Track GUID not found in cache' } });
    expect(setParams()).toEqual([]);
  });

  it("keeps a refusal's code and message for the screen to show", async () => {
    const respond = pendingSubscribe();
    const { result } = renderHook(() => useTuner());
    act(() => {
      void result.current.subscribe(TRACK);
    });
    await respond({
      success: false,
      error: { code: 'INPUT_MIDI', message: 'This track records MIDI.' },
    });
    expect(result.current.problem).toEqual({ code: 'INPUT_MIDI', message: 'This track records MIDI.' });

    // Subscribing again clears it until REAPER answers.
    const again = pendingSubscribe();
    act(() => {
      void result.current.subscribe(TRACK);
    });
    expect(result.current.problem).toBeNull();
    await again({ success: true, payload: { reference: 440, threshold: -90 } });
    expect(result.current.problem).toBeNull();
  });

  describe('a reading that stops arriving', () => {
    function event(overrides: Partial<TunerEventPayload> = {}): TunerEventPayload {
      return {
        trackGuid: TRACK, freq: 82.41, note: 40, noteName: 'E', octave: 2, cents: 0.5, clarity: 0.98, conf: 0.98,
        inTune: true, referenceHz: 440, thresholdDb: -90, state: 'listening',
        starting: false, settling: false, stable: true, multiple: false,
        ...overrides,
      };
    }
    const send = (overrides: Partial<TunerEventPayload> = {}) =>
      act(() => useReaperStore.getState().handleTunerEvent(event(overrides)));
    const advance = (ms: number) => act(() => vi.advanceTimersByTime(ms));

    beforeEach(() => {
      vi.useFakeTimers();
      return () => vi.useRealTimers();
    });

    it('allows a few resends to go missing before the reading is taken as gone', () => {
      expect(TUNER_STALE_MS).toBe(3 * TUNER_RESEND_MS);
    });

    it('is stale once no event has come for the stale time, and fresh again with the next', () => {
      const { result } = renderHook(() => useTuner());
      act(() => useReaperStore.getState().setTunerSubscription(TRACK));
      send();
      advance(TUNER_STALE_MS - 1);
      expect(result.current.stale).toBe(false);
      advance(1);
      expect(result.current.stale).toBe(true);
      send();
      expect(result.current.stale).toBe(false);
    });

    it('stays fresh while the backend resends a reading that holds', () => {
      const { result } = renderHook(() => useTuner());
      act(() => useReaperStore.getState().setTunerSubscription(TRACK));
      for (let i = 0; i < 20; i++) {
        send({ freq: 0, note: 0, noteName: 'C', octave: -1, cents: 0, inTune: false, stable: false, multiple: true });
        advance(TUNER_RESEND_MS);
        expect(result.current.stale).toBe(false);
        expect(result.current.multiple).toBe(true);
      }
    });

    it('is stale when no event comes at all after subscribing', () => {
      const { result } = renderHook(() => useTuner());
      act(() => useReaperStore.getState().setTunerSubscription(TRACK));
      expect(result.current.heard).toBe(false);
      expect(result.current.stale).toBe(false);
      advance(TUNER_STALE_MS);
      expect(result.current.stale).toBe(true);
    });

    it("doesn't carry a stale mark to the next subscription, even to the same source", () => {
      const { result } = renderHook(() => useTuner());
      act(() => useReaperStore.getState().setTunerSubscription(TRACK));
      advance(TUNER_STALE_MS);
      expect(result.current.stale).toBe(true);
      act(() => useReaperStore.getState().setTunerSubscription('master'));
      expect(result.current.stale).toBe(false);
      act(() => useReaperStore.getState().setTunerSubscription(TRACK));
      expect(result.current.stale).toBe(false);
      advance(TUNER_STALE_MS - 1);
      expect(result.current.stale).toBe(false);
    });

    it('takes an event for another source as no event', () => {
      const { result } = renderHook(() => useTuner());
      act(() => useReaperStore.getState().setTunerSubscription(TRACK));
      send();
      for (let i = 0; i < 4; i++) {
        advance(TUNER_RESEND_MS);
        send({ trackGuid: 'master' });
      }
      expect(result.current.stale).toBe(true);
    });
  });

  describe('several notes', () => {
    function event(overrides: Partial<TunerEventPayload> = {}): TunerEventPayload {
      return {
        trackGuid: TRACK, freq: 82.41, note: 40, noteName: 'E', octave: 2, cents: 0.5, clarity: 0.98, conf: 0.98,
        inTune: true, referenceHz: 440, thresholdDb: -90, state: 'listening',
        starting: false, settling: false, stable: true, multiple: false,
        ...overrides,
      };
    }
    const send = (overrides: Partial<TunerEventPayload> = {}) =>
      act(() => useReaperStore.getState().handleTunerEvent(event(overrides)));
    const advance = (ms: number) => act(() => vi.advanceTimersByTime(ms));

    beforeEach(() => {
      vi.useFakeTimers();
      return () => vi.useRealTimers();
    });

    it('holds for SEVERAL_HOLD_MS after the last event flagging it, so an analyser flipping each tick shows it steadily', () => {
      const { result } = renderHook(() => useTuner());
      act(() => useReaperStore.getState().setTunerSubscription(TRACK));
      for (let i = 0; i < 10; i++) {
        send({ multiple: i % 2 === 0 || i === 9 });
        expect(result.current.multiple).toBe(true);
        advance(33);
      }
      send();
      advance(SEVERAL_HOLD_MS - 1);
      expect(result.current.multiple).toBe(true);
      advance(1);
      expect(result.current.multiple).toBe(false);
    });

    it('is not held over to another source', () => {
      const { result } = renderHook(() => useTuner());
      act(() => useReaperStore.getState().setTunerSubscription(TRACK));
      send({ multiple: true });
      act(() => useReaperStore.getState().setTunerSubscription('master'));
      expect(result.current.multiple).toBe(false);
      send({ trackGuid: 'master' });
      expect(result.current.multiple).toBe(false);
    });
  });
});
