/**
 * useItemTapHandler Hook Tests
 *
 * Tests item hit-testing logic for both multi-track lane mode and single-track mode.
 * The hook converts (clientX, clientY) screen coordinates into item/track selection commands.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { renderHook } from '@testing-library/react';
import { useItemTapHandler } from './useItemTapHandler';
import type { WSItem, SkeletonTrack } from '../../../core/WebSocketTypes';
import type { UseViewportReturn } from '../../../hooks';

// ============================================================================
// Test Fixtures
// ============================================================================

/** Container: 1000px wide × 400px tall, starting at (0, 0) */
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

/** Viewport: 0–100s visible */
const mockViewport: UseViewportReturn = {
  visibleRange: { start: 0, end: 100 },
  zoomLevel: 0,
  visibleDuration: 100,
  pan: vi.fn(),
  zoomIn: vi.fn(),
  zoomOut: vi.fn(),
  setVisibleRange: vi.fn(),
  reset: vi.fn(),
  fitToContent: vi.fn(),
  timeToPercent: (t: number) => (t / 100) * 100,
  percentToTime: (p: number) => (p / 100) * 100,
  isInView: () => true,
  zoomSteps: [10, 30, 60, 100] as readonly number[],
};

function makeSkeleton(count: number): SkeletonTrack[] {
  return Array.from({ length: count }, (_, i) => ({
    n: `Track ${i + 1}`,
    g: `guid-${i}`,
    m: false,
    sl: null,
    sel: false,
    r: false,
    fd: 0,
    sc: 0,
    hc: 0,
    cl: false,
    ic: 0,
    fm: 0,
  }));
}

function makeItem(overrides: Partial<WSItem> & { trackIdx: number; position: number; length: number }): WSItem {
  return {
    guid: `item-${overrides.trackIdx}-${overrides.position}`,
    itemIdx: 0,
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
    ...overrides,
  };
}

// ============================================================================
// Tests
// ============================================================================

describe('useItemTapHandler', () => {
  const sendCommand = vi.fn();
  const enterItemSelectionMode = vi.fn();
  const setViewFilterTrack = vi.fn();
  const setSelectedMarkerId = vi.fn();
  const optimisticSelectTrack = vi.fn();

  beforeEach(() => {
    vi.clearAllMocks();
  });

  function renderTapHandler(overrides: Partial<Parameters<typeof useItemTapHandler>[0]> = {}) {
    return renderHook(() =>
      useItemTapHandler({
        containerRef: mockContainerRef,
        viewport: mockViewport,
        items: [],
        trackSkeleton: makeSkeleton(4),
        viewFilterTrackGuid: null,
        itemSelectionModeActive: false,
        enterItemSelectionMode,
        setViewFilterTrack,
        setSelectedMarkerId,
        sendCommand,
        optimisticSelectTrack,
        ...overrides,
      })
    );
  }

  // --------------------------------------------------------------------------
  // Basic: null container, no items
  // --------------------------------------------------------------------------

  describe('no-op cases', () => {
    it('returns false when containerRef is null', () => {
      const { result } = renderTapHandler({
        containerRef: { current: null },
      });
      expect(result.current(500, 200)).toBe(false);
      expect(sendCommand).not.toHaveBeenCalled();
    });

    it('returns false in single-track mode when tap is outside blob Y bounds', () => {
      // Blob is 25% of 400px = 100px, centered at 200px → Y range [150, 250]
      // Tap at Y=10 is outside
      const { result } = renderTapHandler();
      expect(result.current(500, 10)).toBe(false);
    });

    it('returns false in single-track mode when no items at tap position', () => {
      // Tap within blob Y bounds (Y=200) but no items exist
      const { result } = renderTapHandler();
      expect(result.current(500, 200)).toBe(false);
    });
  });

  // --------------------------------------------------------------------------
  // Single-track mode
  // --------------------------------------------------------------------------

  describe('single-track mode (no multiTrackLanes)', () => {
    const item = makeItem({ trackIdx: 0, position: 40, length: 20 });

    it('enters item selection mode on first tap on an item', () => {
      const skeleton = makeSkeleton(2);
      const { result } = renderTapHandler({
        items: [item],
        trackSkeleton: skeleton,
      });

      // Tap at X=500 → 50s, within item [40,60]. Y=200 → center of blob
      const handled = result.current(500, 200);

      expect(handled).toBe(true);
      expect(setSelectedMarkerId).toHaveBeenCalledWith(null);
      expect(enterItemSelectionMode).toHaveBeenCalledWith('guid-0');
    });

    it('toggles item selection when already in item selection mode', () => {
      const skeleton = makeSkeleton(2);
      const { result } = renderTapHandler({
        items: [item],
        trackSkeleton: skeleton,
        itemSelectionModeActive: true,
        viewFilterTrackGuid: 'guid-0',
      });

      const handled = result.current(500, 200);

      expect(handled).toBe(true);
      expect(enterItemSelectionMode).not.toHaveBeenCalled();
      // Should toggle select the item
      expect(sendCommand).toHaveBeenCalledWith(
        expect.objectContaining({ command: expect.stringContaining('item') })
      );
    });

    it('returns false when tap time does not overlap any item', () => {
      const { result } = renderTapHandler({
        items: [item], // item at 40-60s
      });

      // Tap at X=100 → 10s, outside item range. Y=200 within blob bounds.
      expect(result.current(100, 200)).toBe(false);
    });
  });

  // --------------------------------------------------------------------------
  // Multi-track lane mode
  // --------------------------------------------------------------------------

  describe('multi-track lane mode', () => {
    const lanes = makeSkeleton(4);
    const laneIndices = [0, 1, 2, 3];

    it('selects track when tapping empty lane space', () => {
      const { result } = renderTapHandler({
        multiTrackLanes: lanes,
        multiTrackIndices: laneIndices,
        items: [], // no items
      });

      // 4 lanes in 400px = 100px each. Tap Y=50 → lane 0, centered in lane
      const handled = result.current(500, 50);

      expect(handled).toBe(true);
      expect(setSelectedMarkerId).toHaveBeenCalledWith(null);
      // Should unselect all tracks and items, then select track 0
      expect(sendCommand).toHaveBeenCalledTimes(3);
      expect(setViewFilterTrack).toHaveBeenCalledWith('guid-0');
    });

    it('selects correct lane based on Y position', () => {
      const { result } = renderTapHandler({
        multiTrackLanes: lanes,
        multiTrackIndices: laneIndices,
        items: [],
      });

      // Lane height = 100px. Tap Y=350 → lane 3
      result.current(500, 350);

      expect(setViewFilterTrack).toHaveBeenCalledWith('guid-3');
    });

    it('toggles item selection when tapping on an item in a lane', () => {
      const item = makeItem({ trackIdx: 1, position: 40, length: 20 });
      const { result } = renderTapHandler({
        multiTrackLanes: lanes,
        multiTrackIndices: laneIndices,
        items: [item],
      });

      // Lane 1: Y range [100, 200]. Item strip is 60% centered → [120, 180].
      // Tap Y=150 (center of lane 1), X=500 → 50s (within item [40,60])
      const handled = result.current(500, 150);

      expect(handled).toBe(true);
      expect(setSelectedMarkerId).toHaveBeenCalledWith(null);
      expect(enterItemSelectionMode).toHaveBeenCalledWith('guid-1');
      // Should send toggleSelect for the item + track selection commands
      expect(sendCommand).toHaveBeenCalled();
    });

    it('returns false for out-of-bounds lane index', () => {
      const { result } = renderTapHandler({
        multiTrackLanes: lanes,
        multiTrackIndices: laneIndices,
        items: [],
      });

      // Y=-10 → lane index -1 (out of bounds)
      expect(result.current(500, -10)).toBe(false);
    });

    it('selects empty lane even when item exists on a different track at same time', () => {
      // Item on track 0, but we tap lane 2 (track 2) — should select track, not item
      const item = makeItem({ trackIdx: 0, position: 40, length: 20 });
      const { result } = renderTapHandler({
        multiTrackLanes: lanes,
        multiTrackIndices: laneIndices,
        items: [item],
      });

      // Lane 2: Y range [200, 300]. Tap Y=250, X=500 → 50s
      // Item is on trackIdx 0, not trackIdx 2, so no item hit
      const handled = result.current(500, 250);

      expect(handled).toBe(true);
      expect(setViewFilterTrack).toHaveBeenCalledWith('guid-2');
      // Should NOT enter item selection mode
      expect(enterItemSelectionMode).not.toHaveBeenCalled();
    });
  });

  // --------------------------------------------------------------------------
  // getTrackIdxFromGuid (tested indirectly via single-track item selection mode)
  // --------------------------------------------------------------------------

  describe('getTrackIdxFromGuid (indirect)', () => {
    it('resolves filter track GUID to correct index for item toggling', () => {
      const skeleton = makeSkeleton(3);
      // Items on tracks 0 and 1 at same position
      const items = [
        makeItem({ trackIdx: 0, position: 40, length: 20, guid: 'item-a' }),
        makeItem({ trackIdx: 1, position: 40, length: 20, guid: 'item-b' }),
      ];

      const { result } = renderTapHandler({
        items,
        trackSkeleton: skeleton,
        itemSelectionModeActive: true,
        viewFilterTrackGuid: 'guid-1', // filter to track 1
      });

      // Tap at 50s within blob Y bounds → should toggle item-b (track 1), not item-a
      result.current(500, 200);

      expect(sendCommand).toHaveBeenCalledWith(
        expect.objectContaining({ command: 'item/toggleSelect', params: { guid: 'item-b' } })
      );
    });

    it('does not send command when filter track has no item at tap position', () => {
      const skeleton = makeSkeleton(3);
      const items = [
        makeItem({ trackIdx: 0, position: 40, length: 20, guid: 'item-a' }),
      ];

      const { result } = renderTapHandler({
        items,
        trackSkeleton: skeleton,
        itemSelectionModeActive: true,
        viewFilterTrackGuid: 'guid-1', // filter to track 1, but item is on track 0
      });

      result.current(500, 200);

      // Item exists at this time but not on filtered track — no toggle command
      expect(sendCommand).not.toHaveBeenCalled();
      // But still returns true (item was found, just not on filtered track)
    });
  });
});
