/**
 * useTimelineViewport Hook Tests
 *
 * Tests timeline bounds calculation, coordinate conversions, and viewport merging.
 * Pan/pinch gestures and follow-playhead animation have their own dedicated tests.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { renderHook } from '@testing-library/react';
import { useTimelineViewport } from './useTimelineViewport';
import type { Region, Marker } from '../../../core/types';
import type { WSItem } from '../../../core/WebSocketTypes';

// ============================================================================
// Mocks
// ============================================================================

// Mock the transport animation engine (used by useTransportAnimation)
vi.mock('../../../core/TransportAnimationEngine', () => ({
  transportEngine: {
    subscribe: () => () => {},
    getState: () => ({ position: 0, positionBeats: '1.1.00', isPlaying: false }),
  },
}));

// Mock usePanGesture and usePinchGesture — they have their own tests
const mockPanGesture = {
  isPanning: false,
  isMomentumActive: false,
  isCancelled: false,
  handlePointerDown: vi.fn(),
  handlePointerMove: vi.fn(),
  handlePointerUp: vi.fn(),
  stopMomentum: vi.fn(),
};

const mockPinchGesture = {
  isPinchingRef: { current: false },
  isPinching: false,
  handlePointerDown: vi.fn(() => false),
  handlePointerMove: vi.fn(),
  handlePointerUp: vi.fn(),
};

vi.mock('./usePanGesture', () => ({
  usePanGesture: () => mockPanGesture,
}));

vi.mock('./usePinchGesture', () => ({
  usePinchGesture: () => mockPinchGesture,
}));

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
    offsetWidth: 1000,
  } as unknown as HTMLDivElement,
};

function makeRegion(start: number, end: number): Region {
  return { name: `R ${start}-${end}`, id: start, start, end };
}

function makeMarker(position: number): Marker {
  return { name: `M ${position}`, id: position, position };
}

function makeItem(position: number, length: number, trackIdx = 0): WSItem {
  return {
    guid: `item-${position}`,
    trackIdx,
    itemIdx: 0,
    position,
    length,
    color: 0,
    locked: false,
    selected: false,
    activeTakeIdx: 0,
    hasNotes: false,
    takeCount: 1,
    activeTakeName: 'Take 1',
    activeTakeGuid: 'take-guid',
    activeTakeIsMidi: false,
    activeTakeColor: null,
  };
}

const defaultParams = {
  containerRef: mockContainerRef,
  positionSeconds: 0,
  displayRegions: [] as readonly Region[],
  markers: [] as readonly Marker[],
  items: [] as readonly WSItem[],
  followPlayhead: false,
  pauseFollowPlayhead: vi.fn(),
  prefersReducedMotion: false,
  selectionModeActive: false,
  timelineMode: 'navigate' as const,
};

// ============================================================================
// Tests
// ============================================================================

describe('useTimelineViewport', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    // Mock ResizeObserver
    vi.stubGlobal('ResizeObserver', class {
      observe() {}
      unobserve() {}
      disconnect() {}
    });
  });

  // --------------------------------------------------------------------------
  // Timeline bounds calculation
  // --------------------------------------------------------------------------

  describe('timeline bounds', () => {
    it('has minimum 10s duration with empty content', () => {
      const { result } = renderHook(() => useTimelineViewport(defaultParams));

      expect(result.current.baseTimelineStart).toBe(0);
      expect(result.current.baseDuration).toBe(10);
    });

    it('extends to region end with 1.5% padding', () => {
      const regions = [makeRegion(0, 100)];
      const { result } = renderHook(() =>
        useTimelineViewport({ ...defaultParams, displayRegions: regions })
      );

      // 100 * 1.015 = 101.5
      expect(result.current.baseDuration).toBeCloseTo(101.5);
    });

    it('extends to marker position when beyond regions', () => {
      const regions = [makeRegion(0, 50)];
      const markers = [makeMarker(200)];
      const { result } = renderHook(() =>
        useTimelineViewport({ ...defaultParams, displayRegions: regions, markers })
      );

      // 200 * 1.015 = 203
      expect(result.current.baseDuration).toBeCloseTo(203);
    });

    it('extends to item end when beyond regions and markers', () => {
      const items = [makeItem(80, 70)]; // ends at 150
      const { result } = renderHook(() =>
        useTimelineViewport({ ...defaultParams, items })
      );

      // 150 * 1.015 = 152.25
      expect(result.current.baseDuration).toBeCloseTo(152.25);
    });

    it('extends to playhead position when beyond all content', () => {
      const { result } = renderHook(() =>
        useTimelineViewport({ ...defaultParams, positionSeconds: 300 })
      );

      // 300 * 1.015 = 304.5
      expect(result.current.baseDuration).toBeCloseTo(304.5);
    });

    it('timelineStart is always 0', () => {
      const regions = [makeRegion(50, 100)];
      const { result } = renderHook(() =>
        useTimelineViewport({ ...defaultParams, displayRegions: regions })
      );

      expect(result.current.timelineStart).toBe(0);
    });
  });

  // --------------------------------------------------------------------------
  // Coordinate conversions
  // --------------------------------------------------------------------------

  describe('timeToPercent', () => {
    it('converts time to full-timeline percentage', () => {
      const regions = [makeRegion(0, 100)];
      const { result } = renderHook(() =>
        useTimelineViewport({ ...defaultParams, displayRegions: regions })
      );

      // Duration is 101.5 (100 * 1.015)
      // 50 / 101.5 * 100 ≈ 49.26%
      const pct = result.current.timeToPercent(50);
      expect(pct).toBeCloseTo(49.26, 1);
    });

    it('returns 0 for time 0', () => {
      const regions = [makeRegion(0, 100)];
      const { result } = renderHook(() =>
        useTimelineViewport({ ...defaultParams, displayRegions: regions })
      );

      expect(result.current.timeToPercent(0)).toBe(0);
    });
  });

  describe('viewportTimeToPercent', () => {
    it('converts time to viewport-relative percentage', () => {
      const { result } = renderHook(() => useTimelineViewport(defaultParams));

      // Default viewport is 0-10 (min duration), so 5s = 50%
      const pct = result.current.viewportTimeToPercent(5);
      expect(pct).toBe(50);
    });

    it('handles time outside viewport range', () => {
      const { result } = renderHook(() => useTimelineViewport(defaultParams));

      // 15s is beyond the 10s viewport → 150%
      const pct = result.current.viewportTimeToPercent(15);
      expect(pct).toBe(150);
    });
  });

  describe('playheadPercent', () => {
    it('returns viewport-relative playhead position', () => {
      const { result } = renderHook(() =>
        useTimelineViewport({ ...defaultParams, positionSeconds: 5 })
      );

      // Default viewport: 0-10s, playhead at 5s = 50%
      expect(result.current.playheadPercent).toBe(50);
    });

    it('returns 0 when playhead is at start', () => {
      const { result } = renderHook(() =>
        useTimelineViewport({ ...defaultParams, positionSeconds: 0 })
      );

      expect(result.current.playheadPercent).toBe(0);
    });
  });

  describe('positionToTime', () => {
    it('converts screen X to time using viewport range', () => {
      const { result } = renderHook(() => useTimelineViewport(defaultParams));

      // Container is 1000px wide, viewport 0-10s
      // X=500 = 50% → 5s
      const time = result.current.positionToTime(500);
      expect(time).toBe(5);
    });

    it('returns 0 when containerRef is null', () => {
      const { result } = renderHook(() =>
        useTimelineViewport({ ...defaultParams, containerRef: { current: null } })
      );

      expect(result.current.positionToTime(500)).toBe(0);
    });
  });

  // --------------------------------------------------------------------------
  // External viewport
  // --------------------------------------------------------------------------

  describe('external viewport', () => {
    it('uses external viewport when provided', () => {
      const externalViewport = {
        visibleRange: { start: 20, end: 40 },
        zoomLevel: 3,
        visibleDuration: 20,
        pan: vi.fn(),
        zoomIn: vi.fn(),
        zoomOut: vi.fn(),
        setVisibleRange: vi.fn(),
        reset: vi.fn(),
        fitToContent: vi.fn(),
        timeToPercent: vi.fn(),
        percentToTime: vi.fn(),
        isInView: vi.fn(),
        zoomSteps: [10, 20, 30] as readonly number[],
      };

      const { result } = renderHook(() =>
        useTimelineViewport({ ...defaultParams, externalViewport })
      );

      expect(result.current.viewport.visibleRange).toEqual({ start: 20, end: 40 });
      expect(result.current.viewport.visibleDuration).toBe(20);
    });
  });

  // --------------------------------------------------------------------------
  // Return shape
  // --------------------------------------------------------------------------

  describe('return shape', () => {
    it('returns all expected properties', () => {
      const { result } = renderHook(() => useTimelineViewport(defaultParams));

      expect(result.current).toHaveProperty('viewport');
      expect(result.current).toHaveProperty('containerWidth');
      expect(result.current).toHaveProperty('timelineStart');
      expect(result.current).toHaveProperty('duration');
      expect(result.current).toHaveProperty('baseTimelineStart');
      expect(result.current).toHaveProperty('baseDuration');
      expect(result.current).toHaveProperty('timeToPercent');
      expect(result.current).toHaveProperty('viewportTimeToPercent');
      expect(result.current).toHaveProperty('playheadPercent');
      expect(result.current).toHaveProperty('positionToTime');
      expect(result.current).toHaveProperty('pauseFollow');
      expect(result.current).toHaveProperty('panGesture');
      expect(result.current).toHaveProperty('pinchGesture');
    });

    it('pauseFollow delegates to pauseFollowPlayhead', () => {
      const pauseFollowPlayhead = vi.fn();
      const { result } = renderHook(() =>
        useTimelineViewport({ ...defaultParams, pauseFollowPlayhead })
      );

      result.current.pauseFollow();
      expect(pauseFollowPlayhead).toHaveBeenCalledOnce();
    });
  });
});
