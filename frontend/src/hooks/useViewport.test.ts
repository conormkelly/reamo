/**
 * useViewport Hook Tests
 */

import { describe, it, expect } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { useViewport, ZOOM_STEPS } from './useViewport';

describe('useViewport', () => {
  const defaultOptions = { projectDuration: 180 };

  describe('initialization', () => {
    it('initializes with default 30 second range', () => {
      const { result } = renderHook(() => useViewport(defaultOptions));

      expect(result.current.visibleRange.start).toBe(0);
      expect(result.current.visibleRange.end).toBe(30);
      expect(result.current.visibleDuration).toBe(30);
    });

    it('initializes with custom range', () => {
      const { result } = renderHook(() =>
        useViewport({
          ...defaultOptions,
          initialRange: { start: 10, end: 40 },
        })
      );

      expect(result.current.visibleRange.start).toBe(10);
      expect(result.current.visibleRange.end).toBe(40);
    });

    it('clamps initial range to project bounds', () => {
      const { result } = renderHook(() =>
        useViewport({
          projectDuration: 60,
          initialRange: { start: 50, end: 80 },
        })
      );

      // Should clamp: 30s duration starting at 30 (so end is at 60)
      expect(result.current.visibleRange.start).toBe(30);
      expect(result.current.visibleRange.end).toBe(60);
    });

    it('handles project smaller than default duration', () => {
      const { result } = renderHook(() =>
        useViewport({ projectDuration: 10 })
      );

      expect(result.current.visibleRange.start).toBe(0);
      expect(result.current.visibleRange.end).toBe(10);
    });
  });

  describe('pan', () => {
    it('pans forward by delta seconds', () => {
      const { result } = renderHook(() => useViewport(defaultOptions));

      act(() => {
        result.current.pan(10);
      });

      expect(result.current.visibleRange.start).toBe(10);
      expect(result.current.visibleRange.end).toBe(40);
    });

    it('pans backward by negative delta', () => {
      const { result } = renderHook(() =>
        useViewport({
          ...defaultOptions,
          initialRange: { start: 30, end: 60 },
        })
      );

      act(() => {
        result.current.pan(-10);
      });

      expect(result.current.visibleRange.start).toBe(20);
      expect(result.current.visibleRange.end).toBe(50);
    });

    it('clamps pan to start of project', () => {
      const { result } = renderHook(() => useViewport(defaultOptions));

      act(() => {
        result.current.pan(-100); // Try to pan before start
      });

      expect(result.current.visibleRange.start).toBe(0);
      expect(result.current.visibleRange.end).toBe(30);
    });

    it('clamps pan to end of project', () => {
      const { result } = renderHook(() => useViewport(defaultOptions));

      act(() => {
        result.current.pan(200); // Try to pan past end
      });

      // Should stop at 180 - 30 = 150 start
      expect(result.current.visibleRange.start).toBe(150);
      expect(result.current.visibleRange.end).toBe(180);
    });
  });

  describe('zoom', () => {
    it('zoomIn decreases visible duration', () => {
      const { result } = renderHook(() => useViewport(defaultOptions));
      const initialDuration = result.current.visibleDuration;

      act(() => {
        result.current.zoomIn();
      });

      expect(result.current.visibleDuration).toBeLessThan(initialDuration);
    });

    it('zoomOut increases visible duration', () => {
      const { result } = renderHook(() => useViewport(defaultOptions));
      const initialDuration = result.current.visibleDuration;

      act(() => {
        result.current.zoomOut();
      });

      expect(result.current.visibleDuration).toBeGreaterThan(initialDuration);
    });

    it('zoomIn keeps center point fixed', () => {
      const { result } = renderHook(() =>
        useViewport({
          ...defaultOptions,
          initialRange: { start: 60, end: 120 }, // Center at 90
        })
      );

      const centerBefore =
        (result.current.visibleRange.start + result.current.visibleRange.end) / 2;

      act(() => {
        result.current.zoomIn();
      });

      const centerAfter =
        (result.current.visibleRange.start + result.current.visibleRange.end) / 2;

      expect(centerAfter).toBeCloseTo(centerBefore, 1);
    });

    it('zoomIn stops at minimum zoom level', () => {
      const { result } = renderHook(() =>
        useViewport({
          ...defaultOptions,
          initialRange: { start: 0, end: ZOOM_STEPS[0] },
        })
      );

      // Should be at minimum zoom already
      act(() => {
        result.current.zoomIn();
        result.current.zoomIn();
        result.current.zoomIn();
      });

      expect(result.current.visibleDuration).toBeGreaterThanOrEqual(ZOOM_STEPS[0]);
    });

    it('zoomOut stops at maximum zoom level', () => {
      const { result } = renderHook(() =>
        useViewport({
          projectDuration: 10000, // Large project
          initialRange: { start: 0, end: ZOOM_STEPS[ZOOM_STEPS.length - 1] },
        })
      );

      act(() => {
        result.current.zoomOut();
        result.current.zoomOut();
        result.current.zoomOut();
      });

      expect(result.current.visibleDuration).toBeLessThanOrEqual(
        ZOOM_STEPS[ZOOM_STEPS.length - 1]
      );
    });

    it('zoom level is correct index into ZOOM_STEPS', () => {
      const { result } = renderHook(() =>
        useViewport({
          ...defaultOptions,
          initialRange: { start: 0, end: 30 }, // 30s = index 6 (after adding 1,2,3s steps)
        })
      );

      expect(result.current.zoomLevel).toBe(6); // ZOOM_STEPS[6] = 30
    });
  });

  describe('setVisibleRange', () => {
    it('sets range directly', () => {
      const { result } = renderHook(() => useViewport(defaultOptions));

      act(() => {
        result.current.setVisibleRange({ start: 50, end: 100 });
      });

      expect(result.current.visibleRange.start).toBe(50);
      expect(result.current.visibleRange.end).toBe(100);
    });

    it('clamps range to project bounds', () => {
      const { result } = renderHook(() => useViewport(defaultOptions));

      act(() => {
        result.current.setVisibleRange({ start: -10, end: 200 });
      });

      // Range is 210s which exceeds project (180s), so shows entire project
      expect(result.current.visibleRange.start).toBe(0);
      expect(result.current.visibleRange.end).toBe(180);
    });
  });

  describe('reset', () => {
    it('resets to initial range', () => {
      const { result } = renderHook(() =>
        useViewport({
          ...defaultOptions,
          initialRange: { start: 10, end: 40 },
        })
      );

      act(() => {
        result.current.pan(50);
        result.current.zoomOut();
      });

      act(() => {
        result.current.reset();
      });

      expect(result.current.visibleRange.start).toBe(10);
      expect(result.current.visibleRange.end).toBe(40);
    });
  });

  describe('fitToContent', () => {
    it('fits viewport to content with padding', () => {
      const { result } = renderHook(() => useViewport(defaultOptions));

      act(() => {
        result.current.fitToContent({ start: 20, end: 80 });
      });

      // Content is 60s, with 5% padding = 63s
      // Start should be padded back by 5% of 60 = 3s
      expect(result.current.visibleRange.start).toBeCloseTo(17, 0);
      expect(result.current.visibleDuration).toBeCloseTo(66, 0);
    });
  });

  describe('timeToPercent / percentToTime', () => {
    it('converts time at start to 0%', () => {
      const { result } = renderHook(() =>
        useViewport({
          ...defaultOptions,
          initialRange: { start: 30, end: 60 },
        })
      );

      expect(result.current.timeToPercent(30)).toBe(0);
    });

    it('converts time at end to 100%', () => {
      const { result } = renderHook(() =>
        useViewport({
          ...defaultOptions,
          initialRange: { start: 30, end: 60 },
        })
      );

      expect(result.current.timeToPercent(60)).toBe(100);
    });

    it('converts time at midpoint to 50%', () => {
      const { result } = renderHook(() =>
        useViewport({
          ...defaultOptions,
          initialRange: { start: 30, end: 60 },
        })
      );

      expect(result.current.timeToPercent(45)).toBe(50);
    });

    it('converts percent to time correctly', () => {
      const { result } = renderHook(() =>
        useViewport({
          ...defaultOptions,
          initialRange: { start: 30, end: 60 },
        })
      );

      expect(result.current.percentToTime(0)).toBe(30);
      expect(result.current.percentToTime(50)).toBe(45);
      expect(result.current.percentToTime(100)).toBe(60);
    });

    it('handles time outside visible range', () => {
      const { result } = renderHook(() =>
        useViewport({
          ...defaultOptions,
          initialRange: { start: 30, end: 60 },
        })
      );

      // Before visible range
      expect(result.current.timeToPercent(0)).toBe(-100);
      // After visible range
      expect(result.current.timeToPercent(90)).toBe(200);
    });
  });

  describe('isInView', () => {
    it('returns true for range fully inside viewport', () => {
      const { result } = renderHook(() =>
        useViewport({
          ...defaultOptions,
          initialRange: { start: 30, end: 60 },
        })
      );

      expect(result.current.isInView(35, 55)).toBe(true);
    });

    it('returns true for range overlapping start', () => {
      const { result } = renderHook(() =>
        useViewport({
          ...defaultOptions,
          initialRange: { start: 30, end: 60 },
        })
      );

      expect(result.current.isInView(20, 40)).toBe(true);
    });

    it('returns true for range overlapping end', () => {
      const { result } = renderHook(() =>
        useViewport({
          ...defaultOptions,
          initialRange: { start: 30, end: 60 },
        })
      );

      expect(result.current.isInView(50, 70)).toBe(true);
    });

    it('returns true for range spanning viewport', () => {
      const { result } = renderHook(() =>
        useViewport({
          ...defaultOptions,
          initialRange: { start: 30, end: 60 },
        })
      );

      expect(result.current.isInView(0, 100)).toBe(true);
    });

    it('returns false for range before viewport', () => {
      const { result } = renderHook(() =>
        useViewport({
          ...defaultOptions,
          initialRange: { start: 30, end: 60 },
        })
      );

      expect(result.current.isInView(0, 29)).toBe(false);
    });

    it('returns false for range after viewport', () => {
      const { result } = renderHook(() =>
        useViewport({
          ...defaultOptions,
          initialRange: { start: 30, end: 60 },
        })
      );

      expect(result.current.isInView(61, 90)).toBe(false);
    });

    it('includes buffer in visibility check', () => {
      const { result } = renderHook(() =>
        useViewport({
          ...defaultOptions,
          initialRange: { start: 30, end: 60 },
        })
      );

      // Without buffer: range 25-28 is not visible
      expect(result.current.isInView(25, 28, 0)).toBe(false);

      // With 5s buffer: range 25-28 is visible (buffer extends to 25)
      expect(result.current.isInView(25, 28, 5)).toBe(true);
    });
  });

  describe('zoomSteps', () => {
    it('exposes ZOOM_STEPS constant', () => {
      const { result } = renderHook(() => useViewport(defaultOptions));

      expect(result.current.zoomSteps).toBe(ZOOM_STEPS);
      expect(result.current.zoomSteps).toContain(30);
      expect(result.current.zoomSteps).toContain(60);
    });
  });
});
