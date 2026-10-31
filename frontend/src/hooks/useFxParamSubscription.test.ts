/**
 * Tests for useFxParamSubscription and its window computation.
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import {
  nextSubscriptionWindow,
  useFxParamSubscription,
  MAX_SUBSCRIBED_PARAMS,
  RECENTER_MARGIN,
  bufferFor,
  SUBSCRIBE_THROTTLE_MS,
  type UseFxParamSubscriptionOptions,
} from './useFxParamSubscription';
import { useReaperStore } from '../store';
import type { WSCommand } from '../core/WebSocketCommands';

describe('nextSubscriptionWindow', () => {
  /** Rows subscribed each side of `visibleCount` visible rows. */
  const buffer = (visibleCount: number) => bufferFor(visibleCount);

  it('returns null for an empty list', () => {
    expect(nextSubscriptionWindow(null, { start: 0, end: 0 }, 0)).toBeNull();
  });

  it('spends the whole subscription budget at the visible counts a phone shows', () => {
    // max-h-80 shows 4-5 rows of ~90px; allow for taller lists too
    for (let visibleCount = 1; visibleCount <= 20; visibleCount++) {
      const w = nextSubscriptionWindow(null, { start: 200, end: 200 + visibleCount - 1 }, 1000)!;
      const size = w.end - w.start + 1;
      expect(size).toBeGreaterThanOrEqual(MAX_SUBSCRIBED_PARAMS - 1);
      expect(size).toBeLessThanOrEqual(MAX_SUBSCRIBED_PARAMS);
    }
  });

  it('centres the window on the visible rows', () => {
    // An odd number of spare rows puts the extra one after the visible rows
    expect(nextSubscriptionWindow(null, { start: 100, end: 104 }, 500)).toEqual({
      start: 100 - buffer(5),
      end: 100 - buffer(5) + MAX_SUBSCRIBED_PARAMS - 1,
    });
  });

  it('keeps the full budget at the ends of the list, shifting the window inward', () => {
    expect(nextSubscriptionWindow(null, { start: 0, end: 4 }, 500)).toEqual({
      start: 0,
      end: MAX_SUBSCRIBED_PARAMS - 1,
    });
    expect(nextSubscriptionWindow(null, { start: 10, end: 14 }, 500)).toEqual({
      start: 0,
      end: MAX_SUBSCRIBED_PARAMS - 1,
    });
    expect(nextSubscriptionWindow(null, { start: 495, end: 499 }, 500)).toEqual({
      start: 500 - MAX_SUBSCRIBED_PARAMS,
      end: 499,
    });
    expect(nextSubscriptionWindow(null, { start: 480, end: 484 }, 500)).toEqual({
      start: 500 - MAX_SUBSCRIBED_PARAMS,
      end: 499,
    });
  });

  it('covers the whole of a list no longer than the budget', () => {
    expect(nextSubscriptionWindow(null, { start: 0, end: 2 }, 3)).toEqual({ start: 0, end: 2 });
    expect(nextSubscriptionWindow(null, { start: 50, end: 54 }, 60)).toEqual({ start: 0, end: 59 });
    expect(nextSubscriptionWindow(null, { start: 40, end: 44 }, 100)).toEqual({ start: 0, end: 99 });
  });

  it('never exceeds the extension limit, however many rows are visible', () => {
    for (const visibleCount of [1, 5, 39, 40, 41, 60, 99, 100, 101, 250]) {
      const w = nextSubscriptionWindow(null, { start: 200, end: 200 + visibleCount - 1 }, 1000)!;
      expect(w.end - w.start + 1).toBeLessThanOrEqual(MAX_SUBSCRIBED_PARAMS);
      // The visible rows stay covered while they fit in the limit
      if (visibleCount <= MAX_SUBSCRIBED_PARAMS) {
        expect(w.start).toBeLessThanOrEqual(200);
        expect(w.end).toBeGreaterThanOrEqual(200 + visibleCount - 1);
      }
    }
  });

  it('keeps the window while the visible rows stay clear of its edges', () => {
    const current = nextSubscriptionWindow(null, { start: 200, end: 204 }, 500)!;
    for (const start of [current.start + RECENTER_MARGIN, current.end - RECENTER_MARGIN - 4]) {
      expect(nextSubscriptionWindow(current, { start, end: start + 4 }, 500)).toBe(current);
    }
  });

  it('recentres once the visible rows come within the margin of an edge', () => {
    const current = nextSubscriptionWindow(null, { start: 200, end: 204 }, 500)!;
    const start = current.end - RECENTER_MARGIN - 3;
    expect(nextSubscriptionWindow(current, { start, end: start + 4 }, 500)).toEqual({
      start: start - buffer(5),
      end: start - buffer(5) + MAX_SUBSCRIBED_PARAMS - 1,
    });
  });

  it('needs no margin at an end of the list', () => {
    const top = nextSubscriptionWindow(null, { start: 0, end: 4 }, 500)!;
    expect(nextSubscriptionWindow(top, { start: 0, end: 4 }, 500)).toBe(top);
    const bottom = nextSubscriptionWindow(null, { start: 495, end: 499 }, 500)!;
    expect(nextSubscriptionWindow(bottom, { start: 495, end: 499 }, 500)).toBe(bottom);
  });

  it('replaces a window that no longer fits the list', () => {
    expect(nextSubscriptionWindow({ start: 70, end: 134 }, { start: 0, end: 4 }, 20)).toEqual({
      start: 0,
      end: 19,
    });
  });
});

describe('useFxParamSubscription', () => {
  const ALL = Array.from({ length: 500 }, (_, i) => i);

  let sent: WSCommand[];
  let sendCommand: (cmd: WSCommand) => void;

  const subscribedIndices = (cmd: WSCommand) =>
    (cmd.params as { indices: number[] }).indices;

  const baseOptions = (overrides: Partial<UseFxParamSubscriptionOptions> = {}): UseFxParamSubscriptionOptions => ({
    enabled: true,
    trackGuid: '{T1}',
    fxGuid: '{FX1}',
    paramIndices: ALL,
    visibleRange: { startIndex: 0, endIndex: 4 },
    sendCommand,
    ...overrides,
  });

  beforeEach(() => {
    vi.useFakeTimers();
    sent = [];
    sendCommand = (cmd) => sent.push(cmd);
    useReaperStore.setState({ connected: true });
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('subscribes at once, in indices mode, to the window around the visible rows', () => {
    renderHook((opts) => useFxParamSubscription(opts), { initialProps: baseOptions() });

    expect(sent).toHaveLength(1);
    expect(sent[0].command).toBe('trackFxParams/subscribe');
    expect(subscribedIndices(sent[0])).toEqual(ALL.slice(0, MAX_SUBSCRIBED_PARAMS));
  });

  it('sends nothing until the list is laid out, or while disabled', () => {
    const { rerender } = renderHook((opts) => useFxParamSubscription(opts), {
      initialProps: baseOptions({ visibleRange: null }),
    });
    rerender(baseOptions({ enabled: false }));
    expect(sent).toHaveLength(0);
  });

  it('sends nothing for scrolls that stay inside the window', () => {
    const { rerender } = renderHook((opts) => useFxParamSubscription(opts), {
      initialProps: baseOptions(),
    });
    for (let start = 1; start <= 20; start++) {
      rerender(baseOptions({ visibleRange: { startIndex: start, endIndex: start + 4 } }));
    }
    act(() => vi.advanceTimersByTime(1000));
    expect(sent).toHaveLength(1);
  });

  it('throttles window moves and ends on the latest window', () => {
    const { rerender } = renderHook((opts) => useFxParamSubscription(opts), {
      initialProps: baseOptions(),
    });
    // Jump through the list faster than the throttle allows
    for (const start of [100, 200, 300, 400]) {
      rerender(baseOptions({ visibleRange: { startIndex: start, endIndex: start + 4 } }));
    }
    expect(sent).toHaveLength(1);

    act(() => vi.advanceTimersByTime(SUBSCRIBE_THROTTLE_MS));
    expect(sent).toHaveLength(2);
    expect(subscribedIndices(sent[1])).toContain(402);
    expect(subscribedIndices(sent[1])).not.toContain(300);
  });

  it('drops a pending move when the list scrolls back into the subscribed window', () => {
    const { rerender } = renderHook((opts) => useFxParamSubscription(opts), {
      initialProps: baseOptions(),
    });
    rerender(baseOptions({ visibleRange: { startIndex: 300, endIndex: 304 } }));
    rerender(baseOptions({ visibleRange: { startIndex: 0, endIndex: 4 } }));
    act(() => vi.advanceTimersByTime(1000));
    expect(sent).toHaveLength(1);
  });

  it('subscribes a filtered list by the parameter indices of its rows', () => {
    const { rerender } = renderHook((opts) => useFxParamSubscription(opts), {
      initialProps: baseOptions(),
    });
    const matches = [3, 50, 120, 121, 400];
    act(() => vi.advanceTimersByTime(SUBSCRIBE_THROTTLE_MS));
    rerender(baseOptions({ paramIndices: matches, visibleRange: { startIndex: 0, endIndex: 4 } }));
    expect(subscribedIndices(sent[sent.length - 1])).toEqual(matches);
  });

  it('cancels a pending move when disabled, and subscribes again when re-enabled', () => {
    const { rerender } = renderHook((opts) => useFxParamSubscription(opts), {
      initialProps: baseOptions(),
    });
    rerender(baseOptions({ visibleRange: { startIndex: 300, endIndex: 304 } }));
    rerender(baseOptions({ enabled: false, visibleRange: { startIndex: 300, endIndex: 304 } }));
    act(() => vi.advanceTimersByTime(1000));
    expect(sent).toHaveLength(1);

    rerender(baseOptions());
    expect(sent).toHaveLength(2);
    expect(subscribedIndices(sent[1])).toEqual(subscribedIndices(sent[0]));
  });

  it('subscribes the current window again when the connection comes back', () => {
    const { rerender } = renderHook((opts) => useFxParamSubscription(opts), {
      initialProps: baseOptions(),
    });
    act(() => useReaperStore.setState({ connected: false }));
    act(() => useReaperStore.setState({ connected: true }));
    rerender(baseOptions());

    expect(sent).toHaveLength(2);
    expect(subscribedIndices(sent[1])).toEqual(subscribedIndices(sent[0]));
  });

  it('keeps the window when the list is replaced by one with the same parameters', () => {
    // A refetched skeleton with unchanged names gives a new, equal array
    const { rerender } = renderHook((opts) => useFxParamSubscription(opts), {
      initialProps: baseOptions(),
    });
    act(() => vi.advanceTimersByTime(1000));
    // Scrolled well past the top window, where a fresh window would differ
    rerender(baseOptions({ visibleRange: { startIndex: 300, endIndex: 304 } }));
    expect(sent).toHaveLength(2);
    rerender(baseOptions({ paramIndices: [...ALL], visibleRange: { startIndex: 300, endIndex: 304 } }));
    act(() => vi.advanceTimersByTime(1000));
    expect(sent).toHaveLength(2);
  });

  it('subscribes a new list from its top at once, though the list was scrolled down', () => {
    const { rerender } = renderHook((opts) => useFxParamSubscription(opts), {
      initialProps: baseOptions(),
    });
    act(() => vi.advanceTimersByTime(1000));
    rerender(baseOptions({ visibleRange: { startIndex: 300, endIndex: 304 } }));
    expect(sent).toHaveLength(2);

    // A filter is typed: the first render of the new list still reports the
    // old scroll position, before the list scrolls back to its top
    const matches = ALL.filter((i) => i % 2 === 0);
    rerender(baseOptions({ paramIndices: matches, visibleRange: { startIndex: 300, endIndex: 304 } }));
    expect(sent).toHaveLength(3);
    expect(subscribedIndices(sent[2])).toEqual(matches.slice(0, MAX_SUBSCRIBED_PARAMS));

    // The list then reports its top: nothing more to send
    rerender(baseOptions({ paramIndices: matches, visibleRange: { startIndex: 0, endIndex: 4 } }));
    act(() => vi.advanceTimersByTime(1000));
    expect(sent).toHaveLength(3);
  });
});
