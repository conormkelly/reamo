/**
 * useTimelinePointerEvents Hook Tests
 *
 * Tests gesture routing logic: mode delegation, selection mode drag lifecycle,
 * tap detection, vertical cancel, pinch priority, and selectionPreview memo.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { useTimelinePointerEvents } from './useTimelinePointerEvents';
import type { UsePanGestureResult } from './usePanGesture';
import type { UsePinchGestureResult } from './usePinchGesture';

// ============================================================================
// Test Fixtures
// ============================================================================

const mockRect = {
  left: 0,
  right: 1000,
  top: 0,
  bottom: 400,
  width: 1000,
  height: 400,
  x: 0,
  y: 0,
  toJSON: () => ({}),
};

const mockContainerRef = {
  current: {
    getBoundingClientRect: () => mockRect,
  } as unknown as HTMLDivElement,
};

function makePanGesture(): UsePanGestureResult {
  return {
    isPanning: false,
    isMomentumActive: false,
    isCancelled: false,
    handlePointerDown: vi.fn(),
    handlePointerMove: vi.fn(),
    handlePointerUp: vi.fn(),
    stopMomentum: vi.fn(),
  };
}

function makePinchGesture(isPinching = false): UsePinchGestureResult {
  return {
    isPinchingRef: { current: isPinching } as React.RefObject<boolean>,
    isPinching,
    handlePointerDown: vi.fn(() => false),
    handlePointerMove: vi.fn(),
    handlePointerUp: vi.fn(),
  };
}

/** Creates a minimal PointerEvent-like object */
function makePointerEvent(overrides: Partial<React.PointerEvent> = {}): React.PointerEvent {
  return {
    clientX: 500,
    clientY: 200,
    pointerId: 1,
    target: {
      setPointerCapture: vi.fn(),
      releasePointerCapture: vi.fn(),
    } as unknown as EventTarget,
    ...overrides,
  } as unknown as React.PointerEvent;
}

// ============================================================================
// Tests
// ============================================================================

describe('useTimelinePointerEvents', () => {
  const handleRegionPointerDown = vi.fn();
  const handleRegionPointerMove = vi.fn();
  const handleRegionPointerUp = vi.fn();
  const handleItemTap = vi.fn(() => false);
  const positionToTime = vi.fn((clientX: number) => clientX / 10); // 1000px = 100s
  const pauseFollow = vi.fn();
  const setTimeSelection = vi.fn();
  const navigateTo = vi.fn();
  const findNearestBoundary = vi.fn((time: number) => time); // identity

  beforeEach(() => {
    vi.clearAllMocks();
  });

  function renderPointerEvents(overrides: Partial<Parameters<typeof useTimelinePointerEvents>[0]> = {}) {
    const panGesture = makePanGesture();
    const pinchGesture = makePinchGesture();

    const params = {
      containerRef: mockContainerRef,
      timelineMode: 'navigate' as const,
      selectionModeActive: false,
      panGesture,
      pinchGesture,
      isDraggingPlayhead: false,
      handleRegionPointerDown,
      handleRegionPointerMove,
      handleRegionPointerUp,
      handleItemTap,
      positionToTime,
      followPlayhead: false,
      pauseFollow,
      setTimeSelection,
      navigateTo,
      findNearestBoundary,
      ...overrides,
    };

    const result = renderHook(() => useTimelinePointerEvents(params));
    return { ...result, panGesture, pinchGesture };
  }

  // --------------------------------------------------------------------------
  // Return shape
  // --------------------------------------------------------------------------

  describe('return shape', () => {
    it('returns all expected properties', () => {
      const { result } = renderPointerEvents();

      expect(result.current).toHaveProperty('handlePointerDown');
      expect(result.current).toHaveProperty('handlePointerMove');
      expect(result.current).toHaveProperty('handlePointerUp');
      expect(result.current).toHaveProperty('selectionPreview');
    });

    it('selectionPreview is null initially', () => {
      const { result } = renderPointerEvents();
      expect(result.current.selectionPreview).toBeNull();
    });
  });

  // --------------------------------------------------------------------------
  // Pinch priority
  // --------------------------------------------------------------------------

  describe('pinch priority', () => {
    it('delegates to pinchGesture on pointer down and pauses follow when not following playhead', () => {
      const pinchGesture = makePinchGesture();
      (pinchGesture.handlePointerDown as ReturnType<typeof vi.fn>).mockReturnValue(true);

      const { result } = renderPointerEvents({ pinchGesture, followPlayhead: false });

      act(() => {
        result.current.handlePointerDown(makePointerEvent());
      });

      expect(pinchGesture.handlePointerDown).toHaveBeenCalled();
      expect(pauseFollow).toHaveBeenCalled();
    });

    it('does not pause follow when following playhead during pinch', () => {
      const pinchGesture = makePinchGesture();
      (pinchGesture.handlePointerDown as ReturnType<typeof vi.fn>).mockReturnValue(true);

      const { result } = renderPointerEvents({ pinchGesture, followPlayhead: true });

      act(() => {
        result.current.handlePointerDown(makePointerEvent());
      });

      expect(pauseFollow).not.toHaveBeenCalled();
    });

    it('skips other gestures during pointer move when pinching', () => {
      const pinchGesture = makePinchGesture(true); // isPinching = true
      const panGesture = makePanGesture();

      const { result } = renderPointerEvents({ pinchGesture, panGesture });

      act(() => {
        result.current.handlePointerMove(makePointerEvent());
      });

      expect(pinchGesture.handlePointerMove).toHaveBeenCalled();
      expect(panGesture.handlePointerMove).not.toHaveBeenCalled();
      expect(handleRegionPointerMove).not.toHaveBeenCalled();
    });

    it('does not process tap on pointer up when was pinching', () => {
      const pinchGesture = makePinchGesture(true); // isPinching = true

      const { result } = renderPointerEvents({ pinchGesture });

      act(() => {
        result.current.handlePointerUp(makePointerEvent());
      });

      expect(pinchGesture.handlePointerUp).toHaveBeenCalled();
      expect(handleItemTap).not.toHaveBeenCalled();
    });
  });

  // --------------------------------------------------------------------------
  // Region mode delegation
  // --------------------------------------------------------------------------

  describe('region mode delegation', () => {
    it('delegates pointer down to region handler in regions mode', () => {
      const { result } = renderPointerEvents({ timelineMode: 'regions' });

      act(() => {
        result.current.handlePointerDown(makePointerEvent());
      });

      expect(handleRegionPointerDown).toHaveBeenCalled();
    });

    it('delegates pointer move to region handler in regions mode', () => {
      const { result } = renderPointerEvents({ timelineMode: 'regions' });

      act(() => {
        result.current.handlePointerMove(makePointerEvent());
      });

      expect(handleRegionPointerMove).toHaveBeenCalled();
    });

    it('delegates pointer up to region handler in regions mode', () => {
      const { result } = renderPointerEvents({ timelineMode: 'regions' });

      act(() => {
        result.current.handlePointerUp(makePointerEvent());
      });

      expect(handleRegionPointerUp).toHaveBeenCalled();
    });
  });

  // --------------------------------------------------------------------------
  // Navigate mode - pan (default, selection mode off)
  // --------------------------------------------------------------------------

  describe('navigate mode - pan', () => {
    it('delegates pointer down to pan gesture', () => {
      const panGesture = makePanGesture();
      const { result } = renderPointerEvents({ panGesture });

      act(() => {
        result.current.handlePointerDown(makePointerEvent());
      });

      expect(panGesture.handlePointerDown).toHaveBeenCalled();
    });

    it('delegates pointer move to pan gesture', () => {
      const panGesture = makePanGesture();
      const { result } = renderPointerEvents({ panGesture });

      act(() => {
        result.current.handlePointerMove(makePointerEvent());
      });

      expect(panGesture.handlePointerMove).toHaveBeenCalled();
    });

    it('calls handleItemTap on tap (minimal movement)', () => {
      const panGesture = makePanGesture();
      const { result } = renderPointerEvents({ panGesture });

      // Pointer down to set panStartPositionRef
      act(() => {
        result.current.handlePointerDown(makePointerEvent({ clientX: 500, clientY: 200 }));
      });

      // Pointer up at same position (tap)
      act(() => {
        result.current.handlePointerUp(makePointerEvent({ clientX: 502, clientY: 201 }));
      });

      expect(handleItemTap).toHaveBeenCalledWith(502, 201);
    });

    it('does not call handleItemTap on drag (large movement)', () => {
      const panGesture = makePanGesture();
      const { result } = renderPointerEvents({ panGesture });

      act(() => {
        result.current.handlePointerDown(makePointerEvent({ clientX: 500, clientY: 200 }));
      });

      // Move far enough to exceed TAP_THRESHOLD (10px)
      act(() => {
        result.current.handlePointerUp(makePointerEvent({ clientX: 520, clientY: 200 }));
      });

      expect(handleItemTap).not.toHaveBeenCalled();
    });

    it('does nothing on pointer down when dragging playhead', () => {
      const panGesture = makePanGesture();
      const { result } = renderPointerEvents({ panGesture, isDraggingPlayhead: true });

      act(() => {
        result.current.handlePointerDown(makePointerEvent());
      });

      expect(panGesture.handlePointerDown).not.toHaveBeenCalled();
    });
  });

  // --------------------------------------------------------------------------
  // Navigate mode - selection mode
  // --------------------------------------------------------------------------

  describe('navigate mode - selection', () => {
    it('creates time selection on horizontal drag', () => {
      const { result } = renderPointerEvents({ selectionModeActive: true });

      // Start drag at X=200 → 20s
      act(() => {
        result.current.handlePointerDown(makePointerEvent({ clientX: 200, clientY: 200 }));
      });

      // End drag at X=800 → 80s (horizontal movement > 0.1)
      act(() => {
        result.current.handlePointerUp(makePointerEvent({ clientX: 800, clientY: 200 }));
      });

      expect(setTimeSelection).toHaveBeenCalledWith(20, 80);
    });

    it('navigates to boundary on tap (no horizontal movement)', () => {
      const { result } = renderPointerEvents({ selectionModeActive: true });

      // Tap at X=500 → 50s
      act(() => {
        result.current.handlePointerDown(makePointerEvent({ clientX: 500, clientY: 200 }));
      });

      // Up at same position (tap - endTime close to dragStart)
      act(() => {
        result.current.handlePointerUp(makePointerEvent({ clientX: 500, clientY: 200 }));
      });

      expect(navigateTo).toHaveBeenCalledWith(50);
      expect(setTimeSelection).not.toHaveBeenCalled();
    });

    it('snaps selection boundaries via findNearestBoundary', () => {
      // findNearestBoundary rounds to nearest 10
      findNearestBoundary.mockImplementation((t: number) => Math.round(t / 10) * 10);

      const { result } = renderPointerEvents({ selectionModeActive: true });

      act(() => {
        result.current.handlePointerDown(makePointerEvent({ clientX: 213, clientY: 200 }));
      });

      act(() => {
        result.current.handlePointerUp(makePointerEvent({ clientX: 787, clientY: 200 }));
      });

      // 213/10 = 21.3 → snapped to 20, 787/10 = 78.7 → snapped to 80
      expect(setTimeSelection).toHaveBeenCalledWith(20, 80);
    });

    it('does not create selection when cancelled vertically', () => {
      const { result } = renderPointerEvents({ selectionModeActive: true });

      // Start drag
      act(() => {
        result.current.handlePointerDown(makePointerEvent({ clientX: 200, clientY: 200 }));
      });

      // Move vertically off timeline (> 50px threshold beyond container bottom of 400)
      act(() => {
        result.current.handlePointerMove(makePointerEvent({ clientX: 500, clientY: 500 }));
      });

      // End drag
      act(() => {
        result.current.handlePointerUp(makePointerEvent({ clientX: 800, clientY: 500 }));
      });

      expect(setTimeSelection).not.toHaveBeenCalled();
      expect(navigateTo).not.toHaveBeenCalled();
    });

    it('captures pointer on drag start and releases on end', () => {
      const setPointerCapture = vi.fn();
      const releasePointerCapture = vi.fn();
      const target = { setPointerCapture, releasePointerCapture } as unknown as EventTarget;

      const { result } = renderPointerEvents({ selectionModeActive: true });

      act(() => {
        result.current.handlePointerDown(makePointerEvent({ target, pointerId: 42 } as Partial<React.PointerEvent>));
      });

      expect(setPointerCapture).toHaveBeenCalledWith(42);

      act(() => {
        result.current.handlePointerUp(makePointerEvent({ target, pointerId: 42 } as Partial<React.PointerEvent>));
      });

      expect(releasePointerCapture).toHaveBeenCalledWith(42);
    });
  });

  // --------------------------------------------------------------------------
  // Selection preview
  // --------------------------------------------------------------------------

  describe('selectionPreview', () => {
    it('returns preview bounds during active selection drag', () => {
      const { result } = renderPointerEvents({ selectionModeActive: true });

      // Start drag at 200px = 20s
      act(() => {
        result.current.handlePointerDown(makePointerEvent({ clientX: 200, clientY: 200 }));
      });

      // Move to 800px = 80s (> 0.1s threshold)
      act(() => {
        result.current.handlePointerMove(makePointerEvent({ clientX: 800, clientY: 200 }));
      });

      expect(result.current.selectionPreview).toEqual({ start: 20, end: 80 });
    });

    it('returns null when drag movement is too small', () => {
      const { result } = renderPointerEvents({ selectionModeActive: true });

      act(() => {
        result.current.handlePointerDown(makePointerEvent({ clientX: 500, clientY: 200 }));
      });

      // Move less than 0.1s (1px = 0.1s with our positionToTime)
      act(() => {
        result.current.handlePointerMove(makePointerEvent({ clientX: 500, clientY: 200 }));
      });

      expect(result.current.selectionPreview).toBeNull();
    });

    it('returns null when cancelled vertically', () => {
      const { result } = renderPointerEvents({ selectionModeActive: true });

      act(() => {
        result.current.handlePointerDown(makePointerEvent({ clientX: 200, clientY: 200 }));
      });

      // Move horizontally first
      act(() => {
        result.current.handlePointerMove(makePointerEvent({ clientX: 800, clientY: 200 }));
      });

      expect(result.current.selectionPreview).not.toBeNull();

      // Then cancel vertically
      act(() => {
        result.current.handlePointerMove(makePointerEvent({ clientX: 800, clientY: 500 }));
      });

      expect(result.current.selectionPreview).toBeNull();
    });

    it('resets after pointer up', () => {
      const { result } = renderPointerEvents({ selectionModeActive: true });

      act(() => {
        result.current.handlePointerDown(makePointerEvent({ clientX: 200, clientY: 200 }));
      });

      act(() => {
        result.current.handlePointerMove(makePointerEvent({ clientX: 800, clientY: 200 }));
      });

      expect(result.current.selectionPreview).not.toBeNull();

      act(() => {
        result.current.handlePointerUp(makePointerEvent({ clientX: 800, clientY: 200 }));
      });

      expect(result.current.selectionPreview).toBeNull();
    });
  });
});
