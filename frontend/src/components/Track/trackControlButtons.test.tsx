/**
 * Mute, Solo and Record arm are plain buttons: none of them submits a form
 * it ends up inside.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/react';
import type { ReactNode } from 'react';
import { ReaperContext } from '../../hooks/useReaper';
import type { UseReaperConnectionReturn } from '../../hooks/useReaperConnection';
import { useReaperStore } from '../../store';
import type { Track } from '../../core/types';
import { MuteButton } from './MuteButton';
import { SoloButton } from './SoloButton';
import { RecordArmButton } from './RecordArmButton';

const connection = { sendCommand: vi.fn() } as unknown as UseReaperConnectionReturn;
function withConnection({ children }: { children: ReactNode }) {
  return <ReaperContext.Provider value={connection}>{children}</ReaperContext.Provider>;
}

const TRACK: Track = {
  index: 1, guid: '{GTR}', name: 'Gtr', flags: 0, volume: 1, pan: 0, lastMeterPeak: 0, lastMeterPos: 0,
  clipped: false, width: 1, panMode: 0, sendCount: 0, receiveCount: 0, hwOutCount: 0, fxCount: 0, color: 0,
};

describe('track control buttons', () => {
  beforeEach(() => {
    useReaperStore.setState({ tracks: { 1: TRACK } });
  });

  afterEach(() => {
    cleanup();
  });

  it.each([
    ['Mute', MuteButton, 'Mute Track'],
    ['Solo', SoloButton, 'Solo Track (hold for exclusive)'],
    ['Record arm', RecordArmButton, 'Arm Track for Recording (long-press for input)'],
  ])('%s is type="button"', (_name, Button, title) => {
    render(<Button trackIndex={1} />, { wrapper: withConnection });

    expect(screen.getByTitle(title)).toHaveAttribute('type', 'button');
  });
});
