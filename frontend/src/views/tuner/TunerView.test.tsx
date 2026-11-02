/**
 * TunerView - any track can be chosen, armed or not, and the screen says
 * why REAPER can't tune one rather than showing a silence that looks broken.
 */

import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen, fireEvent, act } from '@testing-library/react';
import { useReaperStore } from '../../store';
import type { SkeletonTrack } from '../../core/WebSocketTypes';

vi.hoisted(() => vi.resetModules());

const sendCommand = vi.fn();
const sendCommandAsync = vi.fn();
vi.mock('../../hooks/useReaper', () => ({
  useReaper: () => ({ connected: true, sendCommand, sendCommandAsync }),
}));
vi.mock('../../components/Layout/ViewLayout', () => ({
  ViewLayout: ({ children, header }: { children: React.ReactNode; header?: React.ReactNode }) => (
    <div>
      {header}
      {children}
    </div>
  ),
}));
vi.mock('../../components/Layout/ViewHeader', () => ({
  ViewHeader: ({ children }: { children?: React.ReactNode }) => <div>{children}</div>,
}));

const { TunerView } = await import('./TunerView');

function track(g: string, n: string, armed: boolean): SkeletonTrack {
  return { n, g, m: false, sl: null, sel: false, r: armed, fd: 0, sc: 0, hc: 0, cl: false, ic: 0, fm: 0, c: 0 };
}

const KEYS = '{KEYS}';
const GUITAR = '{GUITAR}';

function subscribes(): string[] {
  return sendCommandAsync.mock.calls
    .map(([cmd]) => cmd as { command: string; params: { trackGuid: string } })
    .filter((cmd) => cmd.command === 'tuner/subscribe')
    .map((cmd) => cmd.params.trackGuid);
}

describe('TunerView', () => {
  beforeEach(() => {
    localStorage.clear();
    sendCommand.mockReset();
    sendCommandAsync.mockReset();
    useReaperStore.getState().clearTunerSubscription();
    useReaperStore.setState({
      trackSkeleton: [track('master', 'MASTER', false), track(KEYS, 'Keys', false), track(GUITAR, 'Guitar', true)],
    });
  });

  it('opens on the first track, armed or not, and marks no track as armed', async () => {
    sendCommandAsync.mockResolvedValue({ success: true, payload: { reference: 440, threshold: -90 } });
    render(<TunerView />);
    await act(async () => {});
    expect(subscribes()).toEqual([KEYS]);
    fireEvent.click(screen.getByRole('button', { name: /Keys/ }));
    expect(screen.getByText('Guitar')).toBeTruthy();
    expect(screen.queryByText('Armed')).toBeNull();
  });

  it("shows REAPER's reason for refusing a track, and asks again when the track is chosen again", async () => {
    const reason = 'This track records MIDI. Choose an audio input for it in REAPER to tune it.';
    sendCommandAsync.mockResolvedValueOnce({ success: false, error: { code: 'INPUT_MIDI', message: reason } });
    render(<TunerView />);
    expect(await screen.findByText(reason)).toBeTruthy();

    // The user sets an audio input in REAPER, then picks Keys again.
    sendCommandAsync.mockResolvedValueOnce({ success: true, payload: { reference: 440, threshold: -90 } });
    fireEvent.click(screen.getByRole('button', { name: /Keys/ }));
    const options = screen.getAllByText('Keys');
    await act(async () => {
      fireEvent.click(options[options.length - 1]);
    });
    expect(subscribes()).toEqual([KEYS, KEYS]);
    expect(screen.queryByText(reason)).toBeNull();
    expect(screen.getByText('No input detected')).toBeTruthy();
  });

  it("says when REAPER's audio device isn't running, and why a track it was tuning stopped", async () => {
    sendCommandAsync.mockResolvedValue({ success: true, payload: { reference: 440, threshold: -90 } });
    render(<TunerView />);
    await act(async () => {});
    const base = {
      trackGuid: KEYS, freq: 0, note: 0, noteName: 'C', octave: -1, cents: 0, clarity: 0, conf: 0,
      inTune: false, referenceHz: 440, thresholdDb: -90,
    };
    act(() => useReaperStore.getState().handleTunerEvent({ ...base, state: 'deviceClosed' }));
    expect(screen.getByRole('status').textContent).toBe(
      "REAPER's audio device isn't running. If it closes when stopped, press play."
    );
    act(() =>
      useReaperStore.getState().handleTunerEvent({
        ...base,
        state: 'cantTune',
        code: 'INPUT_NONE',
        message: 'This track has no record input.',
      })
    );
    expect(screen.getByRole('status').textContent).toBe('This track has no record input.');
    act(() => useReaperStore.getState().handleTunerEvent({ ...base, freq: 220, note: 57, noteName: 'A', octave: 3, state: 'listening' }));
    expect(screen.getByRole('status').textContent).toBe('220.0 Hz');
  });
});
