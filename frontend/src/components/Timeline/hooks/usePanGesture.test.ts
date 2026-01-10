/**
 * usePanGesture Hook Tests
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { usePanGesture } from './usePanGesture';

describe('usePanGesture', () => {
  // Mock container ref
  const mockRect = {
    left: 100,
    right: 600,
    top: 50,
    bottom: 150,
    width: 500,
    height: 100,
  };

  const mockContainerRef = {
    current: {
      getBoundingClientRect: () => mockRect,
    } as HTMLDivElement,
  };

  // Mock pointer capture methods
  const mockSetPointerCapture = vi.fn();
  const mockReleasePointerCapture = vi.fn();

  // Create mock pointer event
  const createPointerEvent = (clientX: number, clientY: number, pointerId = 1) =>
    ({
      clientX,
      clientY,
      pointerId,
      target: {
        setPointerCapture: mockSetPointerCapture,
        releasePointerCapture: mockReleasePointerCapture,
      },
    }) as unknown as React.PointerEvent;

  beforeEach(() => {
    vi.clearAllMocks();
  });

  describe('initialization', () => {
    it('starts not panning', () => {
      const onPan = vi.fn();
      const { result } = renderHook(() =>
        usePanGesture({
          containerRef: mockContainerRef,
          visibleDuration: 30,
          onPan,
        })
      );

      expect(result.current.isPanning).toBe(false);
      expect(result.current.isCancelled).toBe(false);
    });
  });

  describe('pointer down', () => {
    it('starts pan gesture and captures pointer', () => {
      const onPan = vi.fn();
      const { result } = renderHook(() =>
        usePanGesture({
          containerRef: mockContainerRef,
          visibleDuration: 30,
          onPan,
        })
      );

      act(() => {
        result.current.handlePointerDown(createPointerEvent(200, 100));
      });

      expect(result.current.isPanning).toBe(true);
      expect(result.current.isCancelled).toBe(false);
      expect(mockSetPointerCapture).toHaveBeenCalledWith(1);
    });

    it('does not start when disabled', () => {
      const onPan = vi.fn();
      const { result } = renderHook(() =>
        usePanGesture({
          containerRef: mockContainerRef,
          visibleDuration: 30,
          onPan,
          disabled: true,
        })
      );

      act(() => {
        result.current.handlePointerDown(createPointerEvent(200, 100));
      });

      expect(result.current.isPanning).toBe(false);
      expect(mockSetPointerCapture).not.toHaveBeenCalled();
    });

    it('does not start without container ref', () => {
      const onPan = vi.fn();
      const { result } = renderHook(() =>
        usePanGesture({
          containerRef: { current: null },
          visibleDuration: 30,
          onPan,
        })
      );

      act(() => {
        result.current.handlePointerDown(createPointerEvent(200, 100));
      });

      expect(result.current.isPanning).toBe(false);
    });
  });

  describe('pointer move', () => {
    it('calls onPan with correct time delta for rightward drag', () => {
      const onPan = vi.fn();
      const { result } = renderHook(() =>
        usePanGesture({
          containerRef: mockContainerRef,
          visibleDuration: 30, // 30 seconds visible
          onPan,
        })
      );

      // Start at x=200
      act(() => {
        result.current.handlePointerDown(createPointerEvent(200, 100));
      });

      // Move right 100px (20% of 500px width)
      // Expected: -6 seconds (20% of 30s, negative because drag right = pan backward)
      act(() => {
        result.current.handlePointerMove(createPointerEvent(300, 100));
      });

      expect(onPan).toHaveBeenCalledTimes(1);
      expect(onPan).toHaveBeenCalledWith(-6); // -100/500 * 30 = -6
    });

    it('calls onPan with correct time delta for leftward drag', () => {
      const onPan = vi.fn();
      const { result } = renderHook(() =>
        usePanGesture({
          containerRef: mockContainerRef,
          visibleDuration: 30,
          onPan,
        })
      );

      // Start at x=300
      act(() => {
        result.current.handlePointerDown(createPointerEvent(300, 100));
      });

      // Move left 50px (10% of 500px width)
      // Expected: +3 seconds (10% of 30s, positive because drag left = pan forward)
      act(() => {
        result.current.handlePointerMove(createPointerEvent(250, 100));
      });

      expect(onPan).toHaveBeenCalledWith(3); // 50/500 * 30 = 3
    });

    it('accumulates multiple moves', () => {
      const onPan = vi.fn();
      const { result } = renderHook(() =>
        usePanGesture({
          containerRef: mockContainerRef,
          visibleDuration: 30,
          onPan,
        })
      );

      act(() => {
        result.current.handlePointerDown(createPointerEvent(200, 100));
      });

      // First move: +50px
      act(() => {
        result.current.handlePointerMove(createPointerEvent(250, 100));
      });

      // Second move: +50px more
      act(() => {
        result.current.handlePointerMove(createPointerEvent(300, 100));
      });

      expect(onPan).toHaveBeenCalledTimes(2);
      expect(onPan).toHaveBeenNthCalledWith(1, -3); // -50/500 * 30
      expect(onPan).toHaveBeenNthCalledWith(2, -3); // -50/500 * 30
    });

    it('does not call onPan when not panning', () => {
      const onPan = vi.fn();
      const { result } = renderHook(() =>
        usePanGesture({
          containerRef: mockContainerRef,
          visibleDuration: 30,
          onPan,
        })
      );

      // Move without starting pan
      act(() => {
        result.current.handlePointerMove(createPointerEvent(300, 100));
      });

      expect(onPan).not.toHaveBeenCalled();
    });

    it('does not call onPan when delta is zero', () => {
      const onPan = vi.fn();
      const { result } = renderHook(() =>
        usePanGesture({
          containerRef: mockContainerRef,
          visibleDuration: 30,
          onPan,
        })
      );

      act(() => {
        result.current.handlePointerDown(createPointerEvent(200, 100));
      });

      // Move to same position
      act(() => {
        result.current.handlePointerMove(createPointerEvent(200, 100));
      });

      expect(onPan).not.toHaveBeenCalled();
    });
  });

  describe('vertical cancel', () => {
    it('cancels when vertical movement exceeds threshold', () => {
      const onPan = vi.fn();
      const { result } = renderHook(() =>
        usePanGesture({
          containerRef: mockContainerRef,
          visibleDuration: 30,
          onPan,
        })
      );

      act(() => {
        result.current.handlePointerDown(createPointerEvent(200, 100));
      });

      // Move vertically beyond 50px threshold
      act(() => {
        result.current.handlePointerMove(createPointerEvent(300, 160)); // 60px vertical
      });

      expect(result.current.isCancelled).toBe(true);
      expect(onPan).not.toHaveBeenCalled();
    });

    it('cancels when pointer moves outside container vertically', () => {
      const onPan = vi.fn();
      const { result } = renderHook(() =>
        usePanGesture({
          containerRef: mockContainerRef,
          visibleDuration: 30,
          onPan,
        })
      );

      act(() => {
        result.current.handlePointerDown(createPointerEvent(200, 100));
      });

      // Move above container (top is 50, threshold is 50, so above 0)
      act(() => {
        result.current.handlePointerMove(createPointerEvent(300, -10));
      });

      expect(result.current.isCancelled).toBe(true);
      expect(onPan).not.toHaveBeenCalled();
    });

    it('recovers from cancelled state when returning to valid area', () => {
      const onPan = vi.fn();
      const { result } = renderHook(() =>
        usePanGesture({
          containerRef: mockContainerRef,
          visibleDuration: 30,
          onPan,
        })
      );

      act(() => {
        result.current.handlePointerDown(createPointerEvent(200, 100));
      });

      // Cancel by moving too far vertically
      act(() => {
        result.current.handlePointerMove(createPointerEvent(300, 200));
      });
      expect(result.current.isCancelled).toBe(true);

      // Return to valid area and move horizontally
      act(() => {
        result.current.handlePointerMove(createPointerEvent(350, 105));
      });
      expect(result.current.isCancelled).toBe(false);
      expect(onPan).toHaveBeenCalled();
    });
  });

  describe('pointer up', () => {
    it('ends pan gesture and releases pointer capture', () => {
      const onPan = vi.fn();
      const { result } = renderHook(() =>
        usePanGesture({
          containerRef: mockContainerRef,
          visibleDuration: 30,
          onPan,
        })
      );

      act(() => {
        result.current.handlePointerDown(createPointerEvent(200, 100));
      });

      expect(result.current.isPanning).toBe(true);

      act(() => {
        result.current.handlePointerUp(createPointerEvent(300, 100));
      });

      expect(result.current.isPanning).toBe(false);
      expect(result.current.isCancelled).toBe(false);
      expect(mockReleasePointerCapture).toHaveBeenCalledWith(1);
    });

    it('handles already released pointer capture', () => {
      const onPan = vi.fn();
      const throwingReleaseCapture = vi.fn().mockImplementation(() => {
        throw new Error('Pointer capture already released');
      });

      const { result } = renderHook(() =>
        usePanGesture({
          containerRef: mockContainerRef,
          visibleDuration: 30,
          onPan,
        })
      );

      act(() => {
        result.current.handlePointerDown(createPointerEvent(200, 100));
      });

      // Should not throw when releasePointerCapture fails
      expect(() => {
        act(() => {
          result.current.handlePointerUp({
            ...createPointerEvent(300, 100),
            target: {
              setPointerCapture: mockSetPointerCapture,
              releasePointerCapture: throwingReleaseCapture,
            },
          } as unknown as React.PointerEvent);
        });
      }).not.toThrow();

      expect(result.current.isPanning).toBe(false);
    });

    it('does nothing when not panning', () => {
      const onPan = vi.fn();
      const { result } = renderHook(() =>
        usePanGesture({
          containerRef: mockContainerRef,
          visibleDuration: 30,
          onPan,
        })
      );

      act(() => {
        result.current.handlePointerUp(createPointerEvent(300, 100));
      });

      expect(mockReleasePointerCapture).not.toHaveBeenCalled();
    });
  });

  describe('different visible durations', () => {
    it('scales correctly with 60 second visible duration', () => {
      const onPan = vi.fn();
      const { result } = renderHook(() =>
        usePanGesture({
          containerRef: mockContainerRef,
          visibleDuration: 60, // 60 seconds visible
          onPan,
        })
      );

      act(() => {
        result.current.handlePointerDown(createPointerEvent(200, 100));
      });

      // Move right 100px (20% of 500px width)
      // Expected: -12 seconds (20% of 60s)
      act(() => {
        result.current.handlePointerMove(createPointerEvent(300, 100));
      });

      expect(onPan).toHaveBeenCalledWith(-12);
    });

    it('scales correctly with 10 second visible duration', () => {
      const onPan = vi.fn();
      const { result } = renderHook(() =>
        usePanGesture({
          containerRef: mockContainerRef,
          visibleDuration: 10, // 10 seconds visible
          onPan,
        })
      );

      act(() => {
        result.current.handlePointerDown(createPointerEvent(200, 100));
      });

      // Move right 100px (20% of 500px width)
      // Expected: -2 seconds (20% of 10s)
      act(() => {
        result.current.handlePointerMove(createPointerEvent(300, 100));
      });

      expect(onPan).toHaveBeenCalledWith(-2);
    });
  });
});
