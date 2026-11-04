/**
 * SendFader tests: a send level drag ends however the browser ends it, so
 * its gesture is always closed and later moves send nothing.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup, act } from '@testing-library/react';
import type { ReactNode } from 'react';
import { ReaperContext } from '../../hooks/useReaper';
import type { UseReaperConnectionReturn } from '../../hooks/useReaperConnection';
import { useReaperStore } from '../../store';
import { SendFader } from './SendFader';

const sendCommand = vi.fn();
const connection = { sendCommand } as unknown as UseReaperConnectionReturn;
function withConnection({ children }: { children: ReactNode }) {
  return <ReaperContext.Provider value={connection}>{children}</ReaperContext.Provider>;
}

function sentOf(command: string) {
  return sendCommand.mock.calls.map(([c]) => c as { command: string }).filter((c) => c.command === command);
}

const ENDS: [string, () => void][] = [
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
];

describe('SendFader drag end', () => {
  beforeEach(() => {
    sendCommand.mockClear();
    useReaperStore.setState({
      mixerLocked: false,
      tracks: {
        1: {
          index: 1, guid: '{SRC}', name: 'Src', flags: 0, volume: 1, pan: 0,
          lastMeterPeak: 0, lastMeterPos: 0, clipped: false, width: 0, panMode: 0,
          sendCount: 1, receiveCount: 0, hwOutCount: 0, fxCount: 0, color: 0,
        },
      },
      sends: [{ srcTrackIdx: 1, destTrackIdx: 2, sendIndex: 0, volume: 1, pan: 0, muted: false, mode: 0 }],
    });
  });

  afterEach(() => {
    cleanup();
  });

  it.each(ENDS)('ends the drag when %s', (_what, end) => {
    render(<SendFader trackIndex={1} destTrackIdx={2} />, { wrapper: withConnection });
    fireEvent.touchStart(screen.getByTitle('Send level - double-tap to reset to 0dB'), {
      touches: [{ clientX: 10, clientY: 10 }],
    });
    const writes = sentOf('send/setVolume').length;

    act(() => end());

    expect(sentOf('gesture/end')).toHaveLength(1);
    fireEvent.touchMove(document, { touches: [{ clientX: 10, clientY: 50 }] });
    expect(sentOf('send/setVolume')).toHaveLength(writes);
  });
});
