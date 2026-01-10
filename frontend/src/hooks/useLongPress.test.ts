/**
 * useLongPress Hook Tests
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { useLongPress } from './useLongPress';

describe('useLongPress', () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  describe('tap detection', () => {
    it('calls onTap for quick mouse click', () => {
      const onTap = vi.fn();
      const { result } = renderHook(() => useLongPress({ onTap }));

      act(() => {
        result.current.handlers.onMouseDown({ preventDefault: vi.fn() } as unknown as React.MouseEvent);
      });

      // Release quickly (before long press threshold)
      act(() => {
        vi.advanceTimersByTime(100);
        result.current.handlers.onMouseUp();
      });

      expect(onTap).toHaveBeenCalledTimes(1);
    });

    it('calls onTap for quick touch', () => {
      const onTap = vi.fn();
      const { result } = renderHook(() => useLongPress({ onTap }));

      act(() => {
        result.current.handlers.onTouchStart({ preventDefault: vi.fn() } as unknown as React.TouchEvent);
      });

      act(() => {
        vi.advanceTimersByTime(100);
        result.current.handlers.onTouchEnd();
      });

      expect(onTap).toHaveBeenCalledTimes(1);
    });

    it('does not call onTap if onLongPress already triggered', () => {
      const onTap = vi.fn();
      const onLongPress = vi.fn();
      const { result } = renderHook(() => useLongPress({ onTap, onLongPress, duration: 400 }));

      act(() => {
        result.current.handlers.onMouseDown({ preventDefault: vi.fn() } as unknown as React.MouseEvent);
      });

      // Wait for long press to trigger
      act(() => {
        vi.advanceTimersByTime(500);
      });

      act(() => {
        result.current.handlers.onMouseUp();
      });

      expect(onLongPress).toHaveBeenCalledTimes(1);
      expect(onTap).not.toHaveBeenCalled();
    });
  });

  describe('long press detection', () => {
    it('calls onLongPress after default duration (400ms)', () => {
      const onLongPress = vi.fn();
      const { result } = renderHook(() => useLongPress({ onLongPress }));

      act(() => {
        result.current.handlers.onMouseDown({ preventDefault: vi.fn() } as unknown as React.MouseEvent);
      });

      expect(onLongPress).not.toHaveBeenCalled();

      act(() => {
        vi.advanceTimersByTime(400);
      });

      expect(onLongPress).toHaveBeenCalledTimes(1);
    });

    it('respects custom duration', () => {
      const onLongPress = vi.fn();
      const { result } = renderHook(() => useLongPress({ onLongPress, duration: 1000 }));

      act(() => {
        result.current.handlers.onMouseDown({ preventDefault: vi.fn() } as unknown as React.MouseEvent);
      });

      act(() => {
        vi.advanceTimersByTime(500);
      });

      expect(onLongPress).not.toHaveBeenCalled();

      act(() => {
        vi.advanceTimersByTime(500);
      });

      expect(onLongPress).toHaveBeenCalledTimes(1);
    });

    it('does not call onLongPress if released before duration', () => {
      const onLongPress = vi.fn();
      const { result } = renderHook(() => useLongPress({ onLongPress, duration: 400 }));

      act(() => {
        result.current.handlers.onMouseDown({ preventDefault: vi.fn() } as unknown as React.MouseEvent);
      });

      act(() => {
        vi.advanceTimersByTime(200);
        result.current.handlers.onMouseUp();
      });

      // Ensure long press doesn't trigger after release
      act(() => {
        vi.advanceTimersByTime(500);
      });

      expect(onLongPress).not.toHaveBeenCalled();
    });
  });

  describe('mouse leave cancellation', () => {
    it('cancels interaction on mouse leave', () => {
      const onTap = vi.fn();
      const onLongPress = vi.fn();
      const { result } = renderHook(() => useLongPress({ onTap, onLongPress }));

      act(() => {
        result.current.handlers.onMouseDown({ preventDefault: vi.fn() } as unknown as React.MouseEvent);
      });

      act(() => {
        vi.advanceTimersByTime(200);
        result.current.handlers.onMouseLeave();
      });

      // Wait past long press threshold
      act(() => {
        vi.advanceTimersByTime(500);
      });

      expect(onTap).not.toHaveBeenCalled();
      expect(onLongPress).not.toHaveBeenCalled();
    });

    it('can start new interaction after cancel', () => {
      const onTap = vi.fn();
      const { result } = renderHook(() => useLongPress({ onTap }));

      // First interaction - cancelled
      act(() => {
        result.current.handlers.onMouseDown({ preventDefault: vi.fn() } as unknown as React.MouseEvent);
        result.current.handlers.onMouseLeave();
      });

      // Second interaction - completed
      act(() => {
        result.current.handlers.onMouseDown({ preventDefault: vi.fn() } as unknown as React.MouseEvent);
        result.current.handlers.onMouseUp();
      });

      expect(onTap).toHaveBeenCalledTimes(1);
    });
  });

  describe('touch and mouse event handling', () => {
    it('ignores mouse down after touch start (synthesized event)', () => {
      const onTap = vi.fn();
      const { result } = renderHook(() => useLongPress({ onTap }));

      // Touch start
      act(() => {
        result.current.handlers.onTouchStart({ preventDefault: vi.fn() } as unknown as React.TouchEvent);
      });

      // Synthesized mouse down (should be ignored)
      act(() => {
        result.current.handlers.onMouseDown({ preventDefault: vi.fn() } as unknown as React.MouseEvent);
      });

      // Touch end
      act(() => {
        result.current.handlers.onTouchEnd();
      });

      // Only one tap should be triggered (from touch)
      expect(onTap).toHaveBeenCalledTimes(1);
    });

    it('ignores mouse up after touch end', () => {
      const onTap = vi.fn();
      const { result } = renderHook(() => useLongPress({ onTap }));

      // Touch interaction
      act(() => {
        result.current.handlers.onTouchStart({ preventDefault: vi.fn() } as unknown as React.TouchEvent);
        result.current.handlers.onTouchEnd();
      });

      // Synthesized mouse up (should be ignored)
      act(() => {
        result.current.handlers.onMouseUp();
      });

      expect(onTap).toHaveBeenCalledTimes(1);
    });

    it('allows mouse events after touch flag resets', () => {
      const onTap = vi.fn();
      const { result } = renderHook(() => useLongPress({ onTap }));

      // Touch interaction
      act(() => {
        result.current.handlers.onTouchStart({ preventDefault: vi.fn() } as unknown as React.TouchEvent);
        result.current.handlers.onTouchEnd();
      });

      // Wait for touch flag to reset (300ms delay)
      act(() => {
        vi.advanceTimersByTime(350);
      });

      // Now mouse events should work
      act(() => {
        result.current.handlers.onMouseDown({ preventDefault: vi.fn() } as unknown as React.MouseEvent);
        result.current.handlers.onMouseUp();
      });

      expect(onTap).toHaveBeenCalledTimes(2);
    });
  });

  describe('handler stability', () => {
    it('returns stable handler references', () => {
      const onTap = vi.fn();
      const { result, rerender } = renderHook(() => useLongPress({ onTap }));

      const initialHandlers = result.current.handlers;
      rerender();

      expect(result.current.handlers.onMouseDown).toBe(initialHandlers.onMouseDown);
      expect(result.current.handlers.onMouseUp).toBe(initialHandlers.onMouseUp);
      expect(result.current.handlers.onMouseLeave).toBe(initialHandlers.onMouseLeave);
      expect(result.current.handlers.onTouchStart).toBe(initialHandlers.onTouchStart);
      expect(result.current.handlers.onTouchEnd).toBe(initialHandlers.onTouchEnd);
    });
  });

  describe('no callbacks provided', () => {
    it('works without onTap', () => {
      const onLongPress = vi.fn();
      const { result } = renderHook(() => useLongPress({ onLongPress }));

      // Quick click - no error
      act(() => {
        result.current.handlers.onMouseDown({ preventDefault: vi.fn() } as unknown as React.MouseEvent);
        result.current.handlers.onMouseUp();
      });

      expect(onLongPress).not.toHaveBeenCalled();
    });

    it('works without onLongPress', () => {
      const onTap = vi.fn();
      const { result } = renderHook(() => useLongPress({ onTap }));

      // Long hold - no timeout set, tap on release
      act(() => {
        result.current.handlers.onMouseDown({ preventDefault: vi.fn() } as unknown as React.MouseEvent);
      });

      act(() => {
        vi.advanceTimersByTime(500);
        result.current.handlers.onMouseUp();
      });

      // Without onLongPress, it should still call onTap (timeout never triggers)
      expect(onTap).toHaveBeenCalledTimes(1);
    });

    it('works with no callbacks at all', () => {
      const { result } = renderHook(() => useLongPress({}));

      // Should not throw
      expect(() => {
        act(() => {
          result.current.handlers.onMouseDown({ preventDefault: vi.fn() } as unknown as React.MouseEvent);
          result.current.handlers.onMouseUp();
        });
      }).not.toThrow();
    });
  });

  describe('cleanup', () => {
    it('clears timeout on unmount', () => {
      const onLongPress = vi.fn();
      const { result, unmount } = renderHook(() => useLongPress({ onLongPress }));

      act(() => {
        result.current.handlers.onMouseDown({ preventDefault: vi.fn() } as unknown as React.MouseEvent);
      });

      unmount();

      // Long press should not fire after unmount
      act(() => {
        vi.advanceTimersByTime(500);
      });

      expect(onLongPress).not.toHaveBeenCalled();
    });
  });
});
