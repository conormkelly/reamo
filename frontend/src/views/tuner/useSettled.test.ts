/**
 * useSettled: what the tuner tells a screen reader changes only once a new
 * value has held, so a reading wavering at an edge isn't spoken 30 times a
 * second.
 */

import { describe, it, expect, vi, afterEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { useSettled } from './useSettled';

afterEach(() => vi.useRealTimers());

describe('useSettled', () => {
  it('takes a new value only once it has held for the delay', () => {
    vi.useFakeTimers();
    const { result, rerender } = renderHook(({ v }) => useSettled(v, 300), { initialProps: { v: '' } });
    rerender({ v: 'In tune' });
    act(() => vi.advanceTimersByTime(299));
    expect(result.current).toBe('');
    act(() => vi.advanceTimersByTime(1));
    expect(result.current).toBe('In tune');
  });

  it('never takes a value that flickers back within the delay', () => {
    vi.useFakeTimers();
    const { result, rerender } = renderHook(({ v }) => useSettled(v, 300), { initialProps: { v: 'In tune' } });
    for (let i = 0; i < 10; i++) {
      rerender({ v: 'Sharp' });
      act(() => vi.advanceTimersByTime(33));
      rerender({ v: 'In tune' });
      act(() => vi.advanceTimersByTime(33));
    }
    expect(result.current).toBe('In tune');
    act(() => vi.advanceTimersByTime(1000));
    expect(result.current).toBe('In tune');
  });
});
