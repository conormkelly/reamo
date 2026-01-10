/**
 * useEdgeScroll Hook Tests
 *
 * Tests edge zone detection, RAF lifecycle, acceleration, and stale closure handling.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { useEdgeScroll } from './useEdgeScroll';
import type { RefObject } from 'react';

describe('useEdgeScroll', () => {
  // Mock RAF
  let rafCallbacks: Array<(timestamp: number) => void> = [];
  let rafId = 0;

  const mockRequestAnimationFrame = vi.fn((callback: (timestamp: number) => void) => {
    rafCallbacks.push(callback);
    return ++rafId;
  });

  const mockCancelAnimationFrame = vi.fn((_id: number) => {
    // Clear the callback (simplified mock)
    rafCallbacks = [];
  });

  // Store originals
  const originalRAF = window.requestAnimationFrame;
  const originalCAF = window.cancelAnimationFrame;
  const originalPerformanceNow = performance.now;

  // Mock container
  function createMockContainerRef(rect: DOMRect): RefObject<HTMLDivElement> {
    return {
      current: {
        getBoundingClientRect: () => rect,
      } as HTMLDivElement,
    };
  }

  // Helper to flush RAF callbacks
  function flushRAF(timestamp: number) {
    const callbacks = [...rafCallbacks];
    rafCallbacks = [];
    callbacks.forEach((cb) => cb(timestamp));
  }

  beforeEach(() => {
    rafCallbacks = [];
    rafId = 0;
    window.requestAnimationFrame = mockRequestAnimationFrame;
    window.cancelAnimationFrame = mockCancelAnimationFrame;
    vi.spyOn(performance, 'now').mockReturnValue(0);
    mockRequestAnimationFrame.mockClear();
    mockCancelAnimationFrame.mockClear();
  });

  afterEach(() => {
    window.requestAnimationFrame = originalRAF;
    window.cancelAnimationFrame = originalCAF;
    performance.now = originalPerformanceNow;
  });

  describe('initialization', () => {
    it('returns updateEdgeScroll and stopEdgeScroll functions', () => {
      const containerRef = createMockContainerRef(new DOMRect(0, 0, 1000, 100));
      const onPan = vi.fn();

      const { result } = renderHook(() =>
        useEdgeScroll({
          containerRef,
          visibleDuration: 60,
          onPan,
          enabled: true,
        })
      );

      expect(typeof result.current.updateEdgeScroll).toBe('function');
      expect(typeof result.current.stopEdgeScroll).toBe('function');
    });

    it('does not start RAF on mount', () => {
      const containerRef = createMockContainerRef(new DOMRect(0, 0, 1000, 100));
      const onPan = vi.fn();

      renderHook(() =>
        useEdgeScroll({
          containerRef,
          visibleDuration: 60,
          onPan,
          enabled: true,
        })
      );

      expect(mockRequestAnimationFrame).not.toHaveBeenCalled();
    });
  });

  describe('edge zone detection', () => {
    it('detects left edge zone and starts scrolling left (negative)', () => {
      // Container from 100-1100px, edge zone is 100-150px (left 50px)
      const containerRef = createMockContainerRef(new DOMRect(100, 0, 1000, 100));
      const onPan = vi.fn();

      const { result } = renderHook(() =>
        useEdgeScroll({
          containerRef,
          visibleDuration: 60,
          onPan,
          enabled: true,
        })
      );

      // Move to left edge zone (clientX = 120, which is 30px from left)
      act(() => {
        result.current.updateEdgeScroll(120);
      });

      expect(mockRequestAnimationFrame).toHaveBeenCalled();

      // Flush RAF with some time delta
      act(() => {
        vi.spyOn(performance, 'now').mockReturnValue(100);
        flushRAF(100);
      });

      // Should have called onPan with negative value (scroll left)
      expect(onPan).toHaveBeenCalled();
      const panValue = onPan.mock.calls[0][0];
      expect(panValue).toBeLessThan(0);
    });

    it('detects right edge zone and starts scrolling right (positive)', () => {
      // Container from 100-1100px, right edge zone is 1050-1100px (right 50px)
      const containerRef = createMockContainerRef(new DOMRect(100, 0, 1000, 100));
      const onPan = vi.fn();

      const { result } = renderHook(() =>
        useEdgeScroll({
          containerRef,
          visibleDuration: 60,
          onPan,
          enabled: true,
        })
      );

      // Move to right edge zone (clientX = 1080)
      act(() => {
        result.current.updateEdgeScroll(1080);
      });

      expect(mockRequestAnimationFrame).toHaveBeenCalled();

      // Flush RAF
      act(() => {
        vi.spyOn(performance, 'now').mockReturnValue(100);
        flushRAF(100);
      });

      // Should have called onPan with positive value (scroll right)
      expect(onPan).toHaveBeenCalled();
      const panValue = onPan.mock.calls[0][0];
      expect(panValue).toBeGreaterThan(0);
    });

    it('does not scroll when cursor is in center', () => {
      const containerRef = createMockContainerRef(new DOMRect(100, 0, 1000, 100));
      const onPan = vi.fn();

      const { result } = renderHook(() =>
        useEdgeScroll({
          containerRef,
          visibleDuration: 60,
          onPan,
          enabled: true,
        })
      );

      // Move to center (clientX = 600)
      act(() => {
        result.current.updateEdgeScroll(600);
      });

      expect(mockRequestAnimationFrame).not.toHaveBeenCalled();
      expect(onPan).not.toHaveBeenCalled();
    });

    it('stops scrolling when moving out of edge zone', () => {
      const containerRef = createMockContainerRef(new DOMRect(100, 0, 1000, 100));
      const onPan = vi.fn();

      const { result } = renderHook(() =>
        useEdgeScroll({
          containerRef,
          visibleDuration: 60,
          onPan,
          enabled: true,
        })
      );

      // Start at left edge
      act(() => {
        result.current.updateEdgeScroll(120);
      });

      expect(mockRequestAnimationFrame).toHaveBeenCalled();
      mockCancelAnimationFrame.mockClear();

      // Move to center
      act(() => {
        result.current.updateEdgeScroll(600);
      });

      expect(mockCancelAnimationFrame).toHaveBeenCalled();
    });
  });

  describe('depth-based speed multiplier', () => {
    it('scrolls faster when deeper in edge zone', () => {
      const containerRef = createMockContainerRef(new DOMRect(0, 0, 1000, 100));
      const onPan = vi.fn();

      const { result } = renderHook(() =>
        useEdgeScroll({
          containerRef,
          visibleDuration: 30, // Fixed duration for consistent speed
          onPan,
          enabled: true,
        })
      );

      // Shallow in left edge zone (40px from left)
      act(() => {
        result.current.updateEdgeScroll(40);
      });

      act(() => {
        vi.spyOn(performance, 'now').mockReturnValue(100);
        flushRAF(100);
      });

      const shallowSpeed = Math.abs(onPan.mock.calls[0][0]);

      // Reset
      act(() => {
        result.current.stopEdgeScroll();
      });
      onPan.mockClear();
      mockRequestAnimationFrame.mockClear();

      // Deep in left edge zone (5px from left)
      act(() => {
        result.current.updateEdgeScroll(5);
      });

      act(() => {
        vi.spyOn(performance, 'now').mockReturnValue(200);
        flushRAF(200);
      });

      const deepSpeed = Math.abs(onPan.mock.calls[0][0]);

      // Deeper should be faster (up to 2x multiplier)
      expect(deepSpeed).toBeGreaterThan(shallowSpeed);
    });
  });

  describe('time-based acceleration', () => {
    it('accelerates scroll speed over time', () => {
      const containerRef = createMockContainerRef(new DOMRect(0, 0, 1000, 100));
      const onPan = vi.fn();

      const { result } = renderHook(() =>
        useEdgeScroll({
          containerRef,
          visibleDuration: 30,
          onPan,
          enabled: true,
        })
      );

      // Start at edge
      vi.spyOn(performance, 'now').mockReturnValue(0);
      act(() => {
        result.current.updateEdgeScroll(25); // In left edge zone
      });

      // First tick - at start, minimal acceleration
      act(() => {
        vi.spyOn(performance, 'now').mockReturnValue(50);
        flushRAF(50);
      });
      const initialSpeed = Math.abs(onPan.mock.calls[0][0]);

      // Later tick - after 1 second, more acceleration
      act(() => {
        vi.spyOn(performance, 'now').mockReturnValue(1050);
        flushRAF(1050);
      });
      const laterSpeed = Math.abs(onPan.mock.calls[1][0]);

      // Much later - after 2 seconds, max acceleration
      act(() => {
        vi.spyOn(performance, 'now').mockReturnValue(2050);
        flushRAF(2050);
      });
      const maxSpeed = Math.abs(onPan.mock.calls[2][0]);

      // Speed should increase over time (up to 4x multiplier)
      expect(laterSpeed).toBeGreaterThan(initialSpeed);
      expect(maxSpeed).toBeGreaterThan(laterSpeed);
    });
  });

  describe('enabled state handling', () => {
    it('does not scroll when disabled', () => {
      const containerRef = createMockContainerRef(new DOMRect(0, 0, 1000, 100));
      const onPan = vi.fn();

      const { result } = renderHook(() =>
        useEdgeScroll({
          containerRef,
          visibleDuration: 60,
          onPan,
          enabled: false, // Disabled
        })
      );

      // Try to trigger edge scroll
      act(() => {
        result.current.updateEdgeScroll(25);
      });

      expect(mockRequestAnimationFrame).not.toHaveBeenCalled();
      expect(onPan).not.toHaveBeenCalled();
    });

    it('stops scrolling when disabled via prop change (stale closure prevention)', () => {
      const containerRef = createMockContainerRef(new DOMRect(0, 0, 1000, 100));
      const onPan = vi.fn();

      const { result, rerender } = renderHook(
        ({ enabled }) =>
          useEdgeScroll({
            containerRef,
            visibleDuration: 60,
            onPan,
            enabled,
          }),
        { initialProps: { enabled: true } }
      );

      // Start scrolling
      act(() => {
        result.current.updateEdgeScroll(25);
      });

      expect(mockRequestAnimationFrame).toHaveBeenCalled();

      // Disable via prop change
      rerender({ enabled: false });

      // Flush RAF - should check enabledRef and stop
      act(() => {
        vi.spyOn(performance, 'now').mockReturnValue(100);
        flushRAF(100);
      });

      // onPan should not be called after disable
      // The RAF tick checks enabledRef.current and exits early
      expect(onPan).not.toHaveBeenCalled();
    });

    it('uses current onPan callback via ref (stale closure prevention)', () => {
      const containerRef = createMockContainerRef(new DOMRect(0, 0, 1000, 100));
      const onPan1 = vi.fn();
      const onPan2 = vi.fn();

      const { result, rerender } = renderHook(
        ({ onPan }) =>
          useEdgeScroll({
            containerRef,
            visibleDuration: 60,
            onPan,
            enabled: true,
          }),
        { initialProps: { onPan: onPan1 } }
      );

      // Start scrolling
      act(() => {
        result.current.updateEdgeScroll(25);
      });

      // Change callback
      rerender({ onPan: onPan2 });

      // Flush RAF
      act(() => {
        vi.spyOn(performance, 'now').mockReturnValue(100);
        flushRAF(100);
      });

      // Should use the new callback (onPan2), not the old one
      expect(onPan1).not.toHaveBeenCalled();
      expect(onPan2).toHaveBeenCalled();
    });
  });

  describe('RAF lifecycle and cleanup', () => {
    it('cancels RAF on unmount', () => {
      const containerRef = createMockContainerRef(new DOMRect(0, 0, 1000, 100));
      const onPan = vi.fn();

      const { result, unmount } = renderHook(() =>
        useEdgeScroll({
          containerRef,
          visibleDuration: 60,
          onPan,
          enabled: true,
        })
      );

      // Start scrolling
      act(() => {
        result.current.updateEdgeScroll(25);
      });

      expect(mockRequestAnimationFrame).toHaveBeenCalled();

      // Unmount
      unmount();

      expect(mockCancelAnimationFrame).toHaveBeenCalled();
    });

    it('cancels RAF when stopEdgeScroll is called', () => {
      const containerRef = createMockContainerRef(new DOMRect(0, 0, 1000, 100));
      const onPan = vi.fn();

      const { result } = renderHook(() =>
        useEdgeScroll({
          containerRef,
          visibleDuration: 60,
          onPan,
          enabled: true,
        })
      );

      // Start scrolling
      act(() => {
        result.current.updateEdgeScroll(25);
      });

      mockCancelAnimationFrame.mockClear();

      // Stop scrolling
      act(() => {
        result.current.stopEdgeScroll();
      });

      expect(mockCancelAnimationFrame).toHaveBeenCalled();
    });

    it('does not start duplicate RAF loops', () => {
      const containerRef = createMockContainerRef(new DOMRect(0, 0, 1000, 100));
      const onPan = vi.fn();

      const { result } = renderHook(() =>
        useEdgeScroll({
          containerRef,
          visibleDuration: 60,
          onPan,
          enabled: true,
        })
      );

      // Start scrolling multiple times in same direction
      act(() => {
        result.current.updateEdgeScroll(25);
        result.current.updateEdgeScroll(20);
        result.current.updateEdgeScroll(15);
      });

      // Should only have started one RAF loop
      expect(mockRequestAnimationFrame).toHaveBeenCalledTimes(1);
    });

    it('restarts RAF when direction changes', () => {
      const containerRef = createMockContainerRef(new DOMRect(0, 0, 1000, 100));
      const onPan = vi.fn();

      const { result } = renderHook(() =>
        useEdgeScroll({
          containerRef,
          visibleDuration: 60,
          onPan,
          enabled: true,
        })
      );

      // Start at left edge
      act(() => {
        result.current.updateEdgeScroll(25);
      });

      expect(mockRequestAnimationFrame).toHaveBeenCalledTimes(1);

      // Move through center to right edge
      act(() => {
        result.current.updateEdgeScroll(500); // center - stops
      });

      // Move to right edge
      act(() => {
        result.current.updateEdgeScroll(980);
      });

      // Should have started new RAF for opposite direction
      expect(mockRequestAnimationFrame).toHaveBeenCalledTimes(2);
    });
  });

  describe('visible duration scaling', () => {
    it('scrolls faster when zoomed out (larger visible duration)', () => {
      const containerRef = createMockContainerRef(new DOMRect(0, 0, 1000, 100));
      const onPanZoomedIn = vi.fn();
      const onPanZoomedOut = vi.fn();

      // Zoomed in (small visible duration)
      const { result: resultIn, unmount: unmountIn } = renderHook(() =>
        useEdgeScroll({
          containerRef,
          visibleDuration: 10, // Zoomed in
          onPan: onPanZoomedIn,
          enabled: true,
        })
      );

      act(() => {
        resultIn.current.updateEdgeScroll(25);
      });

      act(() => {
        vi.spyOn(performance, 'now').mockReturnValue(100);
        flushRAF(100);
      });

      const zoomedInSpeed = Math.abs(onPanZoomedIn.mock.calls[0][0]);
      unmountIn();

      // Zoomed out (large visible duration)
      const { result: resultOut } = renderHook(() =>
        useEdgeScroll({
          containerRef,
          visibleDuration: 120, // Zoomed out
          onPan: onPanZoomedOut,
          enabled: true,
        })
      );

      mockRequestAnimationFrame.mockClear();

      act(() => {
        resultOut.current.updateEdgeScroll(25);
      });

      act(() => {
        vi.spyOn(performance, 'now').mockReturnValue(200);
        flushRAF(200);
      });

      const zoomedOutSpeed = Math.abs(onPanZoomedOut.mock.calls[0][0]);

      // Zoomed out should scroll faster (proportional to visible duration)
      expect(zoomedOutSpeed).toBeGreaterThan(zoomedInSpeed);
    });
  });

  describe('null container handling', () => {
    it('handles null container ref gracefully', () => {
      const containerRef: RefObject<HTMLDivElement | null> = { current: null };
      const onPan = vi.fn();

      const { result } = renderHook(() =>
        useEdgeScroll({
          containerRef,
          visibleDuration: 60,
          onPan,
          enabled: true,
        })
      );

      // Should not throw, just do nothing
      expect(() => {
        act(() => {
          result.current.updateEdgeScroll(25);
        });
      }).not.toThrow();

      expect(mockRequestAnimationFrame).not.toHaveBeenCalled();
    });
  });
});
