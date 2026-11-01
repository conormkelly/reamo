/**
 * useTuner: saved settings reach the tuner only once it is open.
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

import { useTuner } from './useTuner';
import { useReaperStore } from '../store';

const TRACK = '{TRACK-GUID-0001}';

type Response = { success: boolean; payload?: { reference: number; threshold: number } };

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
    localStorage.setItem('tuner-threshold', '-60'); // the JSFX's own value: nothing to send
    const respond = pendingSubscribe();
    const { result } = renderHook(() => useTuner());

    act(() => {
      void result.current.subscribe(TRACK);
    });
    // The tuner isn't open yet: a setParam now would be refused (NOT_SUBSCRIBED).
    expect(setParams()).toEqual([]);

    await respond({ success: true, payload: { reference: 440, threshold: -60 } });
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
});
