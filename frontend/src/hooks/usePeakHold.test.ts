/**
 * Tests for usePeakHold hook - Peak hold meter behavior
 *
 * Peak hold displays the highest recent peak for a duration before dropping.
 * This mimics REAPER's native meter behavior where you can see "sound came through".
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { usePeakHold } from './usePeakHold';

describe('usePeakHold', () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('returns current peak when no history', () => {
    const { result } = renderHook(() => usePeakHold(-20));
    expect(result.current).toBe(-20);
  });

  it('holds peak when current drops below', () => {
    const { result, rerender } = renderHook(
      ({ peak }) => usePeakHold(peak),
      { initialProps: { peak: -10 } }
    );

    expect(result.current).toBe(-10);

    // Peak drops
    rerender({ peak: -30 });

    // Should still show the higher peak
    expect(result.current).toBe(-10);
  });

  it('updates immediately when new peak is higher', () => {
    const { result, rerender } = renderHook(
      ({ peak }) => usePeakHold(peak),
      { initialProps: { peak: -20 } }
    );

    // Higher peak arrives
    rerender({ peak: -5 });

    expect(result.current).toBe(-5);
  });

  it('drops to current after hold duration expires', () => {
    const { result, rerender } = renderHook(
      ({ peak }) => usePeakHold(peak, 1000),
      { initialProps: { peak: -10 } }
    );

    // Peak drops
    rerender({ peak: -30 });
    expect(result.current).toBe(-10);

    // Advance time past hold duration
    act(() => {
      vi.advanceTimersByTime(1000);
    });

    // Should now show current peak
    expect(result.current).toBe(-30);
  });

  it('resets hold timer when new higher peak arrives', () => {
    const { result, rerender } = renderHook(
      ({ peak }) => usePeakHold(peak, 1000),
      { initialProps: { peak: -20 } }
    );

    // Advance 500ms
    act(() => {
      vi.advanceTimersByTime(500);
    });

    // New higher peak arrives
    rerender({ peak: -10 });
    expect(result.current).toBe(-10);

    // Advance another 500ms (total 1000ms since start, but only 500ms since new peak)
    act(() => {
      vi.advanceTimersByTime(500);
    });

    // Should still hold the new peak
    expect(result.current).toBe(-10);

    // Peak drops
    rerender({ peak: -40 });

    // Advance full hold duration from new peak
    act(() => {
      vi.advanceTimersByTime(1000);
    });

    // Now should drop
    expect(result.current).toBe(-40);
  });

  it('handles -Infinity as silence', () => {
    const { result, rerender } = renderHook(
      ({ peak }) => usePeakHold(peak),
      { initialProps: { peak: -10 } }
    );

    // Signal goes silent
    rerender({ peak: -Infinity });

    // Should hold the last peak
    expect(result.current).toBe(-10);

    // After hold expires
    act(() => {
      vi.advanceTimersByTime(1000);
    });

    expect(result.current).toBe(-Infinity);
  });

  it('uses default 1 second hold duration', () => {
    const { result, rerender } = renderHook(
      ({ peak }) => usePeakHold(peak),
      { initialProps: { peak: -10 } }
    );

    rerender({ peak: -30 });

    // At 999ms, should still hold
    act(() => {
      vi.advanceTimersByTime(999);
    });
    expect(result.current).toBe(-10);

    // At 1000ms, should drop
    act(() => {
      vi.advanceTimersByTime(1);
    });
    expect(result.current).toBe(-30);
  });
});
