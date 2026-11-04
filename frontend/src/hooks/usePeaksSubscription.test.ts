/**
 * usePeaksSubscription: the viewport it sends.
 *
 * The extension reads viewport.widthPx as an integer and refuses a
 * fraction: peaks/subscribe then drops the viewport, and
 * peaks/updateViewport answers INVALID_PARAMS. A ResizeObserver reports
 * fractional widths, so the width must reach the wire whole.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { renderHook, cleanup } from '@testing-library/react';

// Vitest 4.x: setup.ts pre-caches modules before vi.mock can intercept.
// resetModules forces re-evaluation so mocks apply to transitive imports.
vi.hoisted(() => vi.resetModules());

const mockSendCommand = vi.fn();

vi.mock('./useReaper', () => ({
  useReaper: vi.fn(() => ({ sendCommand: mockSendCommand, connected: true })),
}));

import { usePeaksSubscription, type UsePeaksSubscriptionOptions } from './usePeaksSubscription';

type Sent = { command: string; params?: { viewport?: { widthPx: number } } };

function sentWidths(command: string): number[] {
  return mockSendCommand.mock.calls
    .map(([cmd]) => cmd as Sent)
    .filter((cmd) => cmd.command === command)
    .map((cmd) => cmd.params?.viewport?.widthPx as number);
}

describe('usePeaksSubscription viewport width', () => {
  beforeEach(() => {
    mockSendCommand.mockClear();
  });

  afterEach(() => {
    cleanup();
  });

  it('sends a fractional measured width as whole pixels, in peaks/subscribe and peaks/updateViewport', () => {
    const options: UsePeaksSubscriptionOptions = {
      range: { start: 0, end: 7 },
      sampleCount: 30,
      viewport: { start: 0, end: 30, widthPx: 389.6 },
    };

    const { rerender } = renderHook((opts: UsePeaksSubscriptionOptions) => usePeaksSubscription(opts), {
      initialProps: options,
    });
    // Zooming far in changes the LOD, which sends an update at once rather
    // than after the gesture debounce.
    rerender({ ...options, viewport: { start: 0, end: 0.5, widthPx: 412.25 } });

    expect(sentWidths('peaks/subscribe')).toEqual([390]);
    expect(sentWidths('peaks/updateViewport')).toEqual([412]);
  });
});
