/**
 * MixerStrip tests: the track list holds still while a fader is dragged.
 *
 * A strip shows the track at its index in the store. A drag on its fader
 * writes to the GUID it grabbed, so the strip under the finger must keep
 * showing that track until the drag ends, whatever REAPER does to the
 * track order meanwhile. These drive the strip through the store's real
 * message handler, as the extension's events would.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup, act, within } from '@testing-library/react';
import type { ReactNode } from 'react';
import { ReaperContext } from '../../hooks/useReaper';
import type { UseReaperConnectionReturn } from '../../hooks/useReaperConnection';
import type { WSTrack, SkeletonTrack } from '../../core/WebSocketTypes';
import { useReaperStore } from '../../store';
import { msg } from '../../test';
import { MixerStrip } from './MixerStrip';

const sendCommand = vi.fn();
const connection = { sendCommand } as unknown as UseReaperConnectionReturn;
function withConnection({ children }: { children: ReactNode }) {
  return <ReaperContext.Provider value={connection}>{children}</ReaperContext.Provider>;
}

type Row = { g: string; name: string; volume?: number };

function tracksEvent(rows: Row[]) {
  const list: Partial<WSTrack>[] = rows.map((r, i) => ({
    idx: i,
    g: r.g,
    name: r.name,
    volume: r.volume ?? 1.0,
  }));
  return msg.tracks(list, rows.length - 1);
}

function skeletonEvent(rows: Row[]) {
  const list: Partial<SkeletonTrack>[] = rows.map((r) => ({ g: r.g, n: r.name }));
  return msg.trackSkeleton(list);
}

function handle(message: ReturnType<typeof msg.tracks>) {
  act(() => {
    useReaperStore.getState().handleWebSocketMessage(message);
  });
}

const MASTER: Row = { g: 'master', name: 'MASTER' };
const DRUMS: Row = { g: '{DRUMS}', name: 'Drums' };
const BASS: Row = { g: '{BASS}', name: 'Bass' };
const KEYS: Row = { g: '{KEYS}', name: 'Keys' };
const NEW: Row = { g: '{NEW}', name: 'New track' };

const START = [MASTER, DRUMS, BASS, KEYS];

function sentOf(command: string) {
  return sendCommand.mock.calls
    .map(([c]) => c as { command: string; params: Record<string, unknown> })
    .filter((c) => c.command === command);
}

/** The strip shows the track at index 2: Bass, before any change. */
function renderStripAt2() {
  render(<MixerStrip trackIndex={2} mode="volume" faderHeight={200} />, { wrapper: withConnection });
  const strip = screen.getByTestId('mixer-strip');
  const fader = within(strip).getByTitle('Volume - double-tap to reset to 0dB');
  // jsdom lays nothing out; give the fader a height so a move maps to a value.
  fader.getBoundingClientRect = () =>
    ({ top: 0, left: 0, right: 32, bottom: 200, width: 32, height: 200, x: 0, y: 0, toJSON: () => ({}) }) as DOMRect;
  return { strip, fader };
}

function stripName(strip: HTMLElement): string {
  return within(strip).getByTitle(/ - tap to (de)?select$/).textContent ?? '';
}

describe('MixerStrip while its fader is dragged', () => {
  beforeEach(() => {
    sendCommand.mockClear();
    useReaperStore.setState({
      _testMode: false,
      mixerLocked: false,
      tracks: {},
      trackSkeleton: [],
      guidToIndex: new Map(),
      trackLayoutHolds: 0,
      heldTrackSkeleton: null,
      heldTracksEvent: null,
      removedHeldTrackGuids: new Set(),
    });
    handle(skeletonEvent(START));
    handle(tracksEvent(START));
  });

  afterEach(() => {
    cleanup();
  });

  it('keeps showing the dragged track when a track is inserted above it', () => {
    const { strip, fader } = renderStripAt2();
    expect(stripName(strip)).toBe('Bass');

    fireEvent.mouseDown(fader, { clientX: 10, clientY: 100 });
    handle(tracksEvent([MASTER, NEW, DRUMS, { ...BASS, volume: 0.5 }, KEYS]));
    handle(skeletonEvent([MASTER, NEW, DRUMS, BASS, KEYS]));

    expect(stripName(strip)).toBe('Bass');
    // Values still arrive for the held row: Bass's own new volume.
    expect(strip).toHaveTextContent('-6.02 dB');

    fireEvent.mouseUp(document);
    // The drag is over: the strip at index 2 now shows what REAPER has there.
    expect(stripName(strip)).toBe('Drums');
  });

  it('keeps showing the dragged track when it is moved above another track, or a track is removed', () => {
    const { strip, fader } = renderStripAt2();

    fireEvent.mouseDown(fader, { clientX: 10, clientY: 100 });
    handle(tracksEvent([MASTER, BASS, DRUMS, KEYS]));
    handle(skeletonEvent([MASTER, BASS, DRUMS, KEYS]));
    expect(stripName(strip)).toBe('Bass');

    handle(tracksEvent([MASTER, BASS, KEYS]));
    handle(skeletonEvent([MASTER, BASS, KEYS]));
    expect(stripName(strip)).toBe('Bass');

    fireEvent.mouseUp(document);
    // REAPER's order applies on release: Keys is now at index 2.
    expect(stripName(strip)).toBe('Keys');
    expect(useReaperStore.getState().tracks[1]?.name).toBe('Bass');
  });

  it.each([
    ['fader', 'Volume - double-tap to reset to 0dB', 'track/setVolume', 10, 100, 10, 60],
    ['pan control', 'Pan - double-tap to center', 'track/setPan', 35, 8, 60, 8],
  ])(
    'a second press on the %s mid-drag keeps the strip and the writes on the dragged track',
    (_what, title, command, x, y, toX, toY) => {
      const now = vi.spyOn(Date, 'now').mockReturnValue(1_000);
      try {
        const { strip } = renderStripAt2();
        const control = within(strip).getByTitle(title);
        control.getBoundingClientRect = () =>
          ({ top: 0, left: 0, right: 70, bottom: 200, width: 70, height: 200, x: 0, y: 0, toJSON: () => ({}) }) as DOMRect;

        fireEvent.touchStart(control, { touches: [{ clientX: x, clientY: y }] });
        handle(tracksEvent([MASTER, NEW, DRUMS, BASS, KEYS]));
        handle(skeletonEvent([MASTER, NEW, DRUMS, BASS, KEYS]));

        // A second finger on the same control, too late to count as a double tap.
        now.mockReturnValue(2_000);
        sendCommand.mockClear();
        fireEvent.touchStart(control, { touches: [{ clientX: x, clientY: y }] });
        fireEvent.touchMove(document, { touches: [{ clientX: toX, clientY: toY }] });

        expect(stripName(strip)).toBe('Bass');
        const writes = sentOf(command);
        expect(writes.length).toBeGreaterThan(0);
        expect(new Set(writes.map((w) => w.params.trackGuid))).toEqual(new Set(['{BASS}']));
        expect(sentOf('gesture/start').map((g) => g.params.trackGuid)).toEqual(['{BASS}']);

        fireEvent.touchEnd(document);
        expect(stripName(strip)).toBe('Drums');
        expect(useReaperStore.getState().trackLayoutHolds).toBe(0);
      } finally {
        now.mockRestore();
      }
    }
  );

  it.each([
    ['fader', 'Volume - double-tap to reset to 0dB'],
    ['pan control', 'Pan - double-tap to center'],
  ])('a double-tap on a deleted track\'s greyed %s sends nothing', (_what, title) => {
    const now = vi.spyOn(Date, 'now').mockReturnValue(1_000);
    try {
      const { strip } = renderStripAt2();
      const control = within(strip).getByTitle(title);
      fireEvent.touchStart(control, { touches: [{ clientX: 10, clientY: 8 }] });
      handle(tracksEvent([MASTER, DRUMS, KEYS]));
      handle(skeletonEvent([MASTER, DRUMS, KEYS]));
      expect(control).toHaveAttribute('aria-disabled', 'true');

      // The second tap of a double-tap, inside its 300 ms.
      now.mockReturnValue(1_100);
      sendCommand.mockClear();
      fireEvent.touchStart(control, { touches: [{ clientX: 10, clientY: 8 }] });

      expect(sendCommand).not.toHaveBeenCalled();
      fireEvent.touchEnd(document);
    } finally {
      now.mockRestore();
    }
  });

  it('a new press on a deleted track\'s greyed fader mid-hold sends nothing', () => {
    const now = vi.spyOn(Date, 'now').mockReturnValue(1_000);
    try {
      const { strip, fader } = renderStripAt2();
      fireEvent.touchStart(fader, { touches: [{ clientX: 10, clientY: 100 }] });
      handle(tracksEvent([MASTER, DRUMS, KEYS]));
      handle(skeletonEvent([MASTER, DRUMS, KEYS]));
      expect(fader).toHaveAttribute('aria-disabled', 'true');

      now.mockReturnValue(2_000);
      sendCommand.mockClear();
      fireEvent.touchStart(fader, { touches: [{ clientX: 10, clientY: 100 }] });
      fireEvent.touchMove(document, { touches: [{ clientX: 10, clientY: 50 }] });
      fireEvent.touchEnd(document);

      expect(sendCommand).not.toHaveBeenCalled();
      expect(stripName(strip)).toBe('Keys');
      expect(useReaperStore.getState().trackLayoutHolds).toBe(0);
    } finally {
      now.mockRestore();
    }
  });

  it('greys the fader and sends no more volume writes once the dragged track is deleted', () => {
    const { strip, fader } = renderStripAt2();

    fireEvent.mouseDown(fader, { clientX: 10, clientY: 100 });
    fireEvent.mouseMove(document, { clientX: 10, clientY: 90 });
    expect(sentOf('track/setVolume')).toHaveLength(1);

    handle(tracksEvent([MASTER, DRUMS, KEYS]));
    handle(skeletonEvent([MASTER, DRUMS, KEYS]));

    // The row does not jump to Keys, and its fader is shown disabled.
    expect(stripName(strip)).toBe('Bass');
    expect(fader).toHaveAttribute('aria-disabled', 'true');
    expect(fader).toHaveClass('opacity-50');

    fireEvent.mouseMove(document, { clientX: 10, clientY: 60 });
    fireEvent.mouseMove(document, { clientX: 10, clientY: 40 });
    expect(sentOf('track/setVolume')).toHaveLength(1);
    expect(sentOf('track/setVolume')[0].params.trackGuid).toBe('{BASS}');

    fireEvent.mouseUp(document);
    // Its GUID resolves to nothing, so the drag's end is not sent either.
    expect(sentOf('gesture/end')).toHaveLength(0);
    expect(stripName(strip)).toBe('Keys');
    expect(fader).not.toHaveAttribute('aria-disabled');
  });

  it('holds the strip and greys the pan control too when its dragged track is deleted', () => {
    const { strip } = renderStripAt2();
    const pan = within(strip).getByTitle('Pan - double-tap to center');
    pan.getBoundingClientRect = () =>
      ({ top: 0, left: 0, right: 70, bottom: 16, width: 70, height: 16, x: 0, y: 0, toJSON: () => ({}) }) as DOMRect;

    fireEvent.mouseDown(pan, { clientX: 35, clientY: 8 });
    expect(sentOf('track/setPan')).toHaveLength(1);
    handle(tracksEvent([MASTER, NEW, DRUMS, BASS, KEYS]));
    handle(skeletonEvent([MASTER, NEW, DRUMS, BASS, KEYS]));
    expect(stripName(strip)).toBe('Bass');

    handle(tracksEvent([MASTER, NEW, DRUMS, KEYS]));
    handle(skeletonEvent([MASTER, NEW, DRUMS, KEYS]));
    expect(stripName(strip)).toBe('Bass');
    expect(pan).toHaveAttribute('aria-disabled', 'true');
    fireEvent.mouseMove(document, { clientX: 60, clientY: 8 });
    expect(sentOf('track/setPan')).toHaveLength(1);

    fireEvent.mouseUp(document);
    expect(sentOf('gesture/end')).toHaveLength(0);
    expect(stripName(strip)).toBe('Drums');
  });

  it.each([
    ['a touch is cancelled', () => fireEvent.touchCancel(document)],
    ['the window loses focus', () => fireEvent.blur(window)],
    [
      'the page is hidden',
      () => {
        Object.defineProperty(document, 'visibilityState', { value: 'hidden', configurable: true });
        fireEvent(document, new Event('visibilitychange'));
        Object.defineProperty(document, 'visibilityState', { value: 'visible', configurable: true });
      },
    ],
  ])('ends the drag and applies the held changes when %s', (_what, end) => {
    const { strip, fader } = renderStripAt2();

    fireEvent.touchStart(fader, { touches: [{ clientX: 10, clientY: 100 }] });
    handle(tracksEvent([MASTER, NEW, DRUMS, BASS, KEYS]));
    handle(skeletonEvent([MASTER, NEW, DRUMS, BASS, KEYS]));
    expect(stripName(strip)).toBe('Bass');

    act(() => end());

    expect(stripName(strip)).toBe('Drums');
    expect(sentOf('gesture/end')).toHaveLength(1);
    // A move after the drag ended writes nothing.
    fireEvent.touchMove(document, { touches: [{ clientX: 10, clientY: 50 }] });
    expect(sentOf('track/setVolume')).toHaveLength(0);
  });

  it('releases the layout on unmount after a second press on the same fader mid-drag', () => {
    const now = vi.spyOn(Date, 'now').mockReturnValue(1_000);
    try {
      const { fader } = renderStripAt2();
      fireEvent.touchStart(fader, { touches: [{ clientX: 10, clientY: 100 }] });
      // A second finger on the same fader, too late to count as a double tap.
      now.mockReturnValue(2_000);
      fireEvent.touchStart(fader, { touches: [{ clientX: 10, clientY: 120 }] });
      expect(useReaperStore.getState().trackLayoutHolds).toBe(1);

      cleanup();
      expect(useReaperStore.getState().trackLayoutHolds).toBe(0);
    } finally {
      now.mockRestore();
    }
  });

  it.each([
    ['fader', 'Volume - double-tap to reset to 0dB'],
    ['pan control', 'Pan - double-tap to center'],
  ])('releases the layout when sending the %s drag\'s end throws', (_what, title) => {
    const { strip } = renderStripAt2();
    const control = within(strip).getByTitle(title);
    fireEvent.mouseDown(control, { clientX: 10, clientY: 8 });
    handle(tracksEvent([MASTER, NEW, DRUMS, BASS, KEYS]));

    sendCommand.mockImplementation((c: { command: string }) => {
      if (c.command === 'gesture/end') throw new Error('socket gone');
    });
    // jsdom reports a listener's throw instead of rethrowing it.
    const onError = (e: ErrorEvent) => e.preventDefault();
    window.addEventListener('error', onError);
    try {
      fireEvent.mouseUp(document);
    } finally {
      window.removeEventListener('error', onError);
      sendCommand.mockReset();
    }

    expect(useReaperStore.getState().trackLayoutHolds).toBe(0);
    expect(stripName(strip)).toBe('Drums');
  });

  it('applies the held changes when the strip unmounts mid-drag', () => {
    const { fader } = renderStripAt2();

    fireEvent.mouseDown(fader, { clientX: 10, clientY: 100 });
    handle(tracksEvent([MASTER, NEW, DRUMS, BASS, KEYS]));
    handle(skeletonEvent([MASTER, NEW, DRUMS, BASS, KEYS]));
    cleanup();

    expect(useReaperStore.getState().tracks[2]?.name).toBe('Drums');
    expect(useReaperStore.getState().trackSkeleton.map((t) => t.n)).toEqual([
      'MASTER', 'New track', 'Drums', 'Bass', 'Keys',
    ]);
  });
});
