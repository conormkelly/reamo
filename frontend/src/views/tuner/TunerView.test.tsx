/**
 * TunerView - any track can be chosen, armed or not, and the screen says
 * why REAPER can't tune one rather than showing a silence that looks broken.
 */

import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen, fireEvent, act, waitFor } from '@testing-library/react';
import { useReaperStore } from '../../store';
import type { SkeletonTrack, TunerEventPayload } from '../../core/WebSocketTypes';

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

/** What the live region settles on (it takes a value once it has held 300 ms). */
async function says(text: string) {
  await waitFor(() => expect(screen.getByRole('status').textContent).toBe(text), { timeout: 1000 });
}

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
    await says("REAPER's audio device isn't running. If it closes when stopped, press play.");
    act(() =>
      useReaperStore.getState().handleTunerEvent({
        ...base,
        state: 'cantTune',
        code: 'INPUT_NONE',
        message: 'This track has no record input.',
      })
    );
    expect(screen.getByText('This track has no record input.')).toBeTruthy();
    await says('This track has no record input.');
    act(() => useReaperStore.getState().handleTunerEvent({ ...base, freq: 220, note: 57, noteName: 'A', octave: 3, state: 'listening' }));
    expect(screen.getByText('220.00 Hz')).toBeTruthy();
    await says('');
  });

  describe('readings', () => {
    function reading(overrides: Partial<TunerEventPayload> = {}): TunerEventPayload {
      return {
        trackGuid: KEYS, freq: 82.41, note: 40, noteName: 'E', octave: 2, cents: 0.5, clarity: 0.98, conf: 0.98,
        inTune: true, referenceHz: 440, thresholdDb: -90, state: 'listening',
        starting: false, settling: false, stable: true, multiple: false,
        ...overrides,
      };
    }
    function send(overrides: Partial<TunerEventPayload> = {}) {
      act(() => useReaperStore.getState().handleTunerEvent(reading(overrides)));
    }
    async function open() {
      sendCommandAsync.mockResolvedValue({ success: true, payload: { reference: 440, threshold: -90 } });
      const view = render(<TunerView />);
      await act(async () => {});
      return view;
    }
    const green = (root: HTMLElement) => root.querySelector('.text-success, .bg-success') !== null;
    const needle = () => screen.queryByTestId('tuner-needle');
    const note = () => screen.getByTestId('tuner-note');

    it('turns green only for a stable reading in the in-tune window, and says so to screen readers', async () => {
      const { container } = await open();
      send({ stable: false });
      expect(green(container)).toBe(false);
      expect(needle()?.dataset.tone).toBe('moving');
      send({ settling: true });
      expect(green(container)).toBe(false);
      send({ inTune: false, cents: 1 });
      expect(green(container)).toBe(false);
      send({ multiple: true });
      expect(green(container)).toBe(false);
      send({ inTune: false, cents: 4 });
      expect(green(container)).toBe(false);
      await says('Sharp');
      send();
      expect(green(container)).toBe(true);
      expect(note().dataset.look).toBe('inTune');
      expect(needle()?.dataset.tone).toBe('inTune');
      await says('In tune');
    });

    it('dims the note and hides the needle while a note is starting', async () => {
      const { container } = await open();
      send({ freq: 0, note: 0, noteName: 'C', octave: -1, cents: 0, inTune: false, stable: false, starting: true });
      expect(note().dataset.look).toBe('starting');
      expect(note().textContent).not.toContain('C');
      expect(needle()).toBeNull();
      expect(screen.getByText('Hearing a note…')).toBeTruthy();
      expect(green(container)).toBe(false);
      // Comes with every pluck: shown, not spoken
      await new Promise((r) => setTimeout(r, 350));
      expect(screen.getByRole('status').textContent).toBe('');
    });

    it('shows the note solid with a grey needle while it settles', async () => {
      await open();
      send({ settling: true, stable: false, cents: -18, inTune: false });
      expect(note().dataset.look).toBe('shown');
      expect(note().textContent).toContain('E');
      expect(needle()?.dataset.tone).toBe('moving');
    });

    it('asks for one string when several notes sound', async () => {
      await open();
      send({ multiple: true });
      expect(screen.getByText('Several notes — let one string ring')).toBeTruthy();
      await says('Several notes — let one string ring');
    });

    it('shows no needle with no pitch', async () => {
      await open();
      send({ freq: 0, note: 0, noteName: 'C', octave: -1, cents: 0, inTune: false, stable: false });
      expect(needle()).toBeNull();
      expect(note().dataset.look).toBe('none');
    });

    it('keeps green from one source off the next until that one is stable in tune', async () => {
      const { container } = await open();
      send();
      expect(green(container)).toBe(true);
      fireEvent.click(screen.getByRole('button', { name: /Keys/ }));
      await act(async () => {
        fireEvent.click(screen.getByRole('button', { name: /Guitar/ }));
      });
      expect(green(container)).toBe(false);
      send({ trackGuid: GUITAR, stable: false });
      expect(green(container)).toBe(false);
      send({ trackGuid: GUITAR });
      expect(green(container)).toBe(true);
    });

    it("never shows one source's note held on the next", async () => {
      await open();
      send({ cents: 0 });
      act(() => {
        useReaperStore.getState().setTunerSubscription('master');
        // F2 at -49 cents, which a held E2 would show as E2 +51
        useReaperStore.getState().handleTunerEvent(
          reading({ trackGuid: 'master', freq: 84.8, note: 41, noteName: 'F', cents: -49, inTune: false })
        );
      });
      expect(note().textContent).toContain('F');
    });
  });

  describe('source sheet', () => {
    it("keeps the saved track while the track list hasn't arrived", async () => {
      localStorage.setItem('tuner-track', GUITAR);
      useReaperStore.setState({ trackSkeleton: [] });
      sendCommandAsync.mockResolvedValue({ success: true, payload: { reference: 440, threshold: -90 } });
      render(<TunerView />);
      await act(async () => {});
      expect(subscribes()).toEqual([GUITAR]);
      expect(localStorage.getItem('tuner-track')).toBe(GUITAR);
    });

    it('offers the master output first, then every track, and tunes the master when chosen', async () => {
      sendCommandAsync.mockResolvedValue({ success: true, payload: { reference: 440, threshold: -90 } });
      render(<TunerView />);
      await act(async () => {});
      fireEvent.click(screen.getByRole('button', { name: /Keys/ }));
      const sheet = screen.getByRole('dialog');
      const options = Array.from(sheet.querySelectorAll('button')).map((b) => b.textContent);
      expect(options[0]).toContain('Master output');
      expect(options.slice(1).map((t) => t?.replace('✓', ''))).toEqual(['Keys', 'Guitar']);
      await act(async () => {
        fireEvent.click(screen.getByRole('button', { name: /Master output/ }));
      });
      expect(subscribes()).toEqual([KEYS, 'master']);
      const header = screen.getAllByRole('button').find((b) => b.getAttribute('aria-haspopup') === 'dialog');
      expect(header?.textContent).toContain('Master output');
      expect(localStorage.getItem('tuner-track')).toBe('master');
    });

    it('opens on the master output when that was the last choice', async () => {
      localStorage.setItem('tuner-track', 'master');
      sendCommandAsync.mockResolvedValue({ success: true, payload: { reference: 440, threshold: -90 } });
      render(<TunerView />);
      await act(async () => {});
      expect(subscribes()).toEqual(['master']);
    });

    it('tunes the master output when the project has no tracks', async () => {
      useReaperStore.setState({ trackSkeleton: [track('master', 'MASTER', false)] });
      sendCommandAsync.mockResolvedValue({ success: true, payload: { reference: 440, threshold: -90 } });
      render(<TunerView />);
      await act(async () => {});
      expect(subscribes()).toEqual(['master']);
    });
  });
});
