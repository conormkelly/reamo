/**
 * useVisibleItems Hook Tests
 */

import { describe, it, expect } from 'vitest';
import { renderHook } from '@testing-library/react';
import {
  useVisibleItems,
  useVisibleMarkers,
  useVisibleRegions,
  useVisibleMediaItems,
} from './useVisibleItems';
import type { TimeRange } from './useViewport';

describe('useVisibleItems', () => {
  // Test data
  const regions = [
    { id: 1, start: 0, end: 10 },
    { id: 2, start: 20, end: 30 },
    { id: 3, start: 40, end: 50 },
    { id: 4, start: 60, end: 70 },
    { id: 5, start: 80, end: 90 },
  ];

  const markers = [
    { id: 1, position: 5 },
    { id: 2, position: 25 },
    { id: 3, position: 45 },
    { id: 4, position: 65 },
    { id: 5, position: 85 },
  ];

  describe('basic filtering', () => {
    it('filters items to visible range', () => {
      const visibleRange: TimeRange = { start: 15, end: 55 };

      const { result } = renderHook(() =>
        useVisibleItems({
          items: regions,
          getStart: (r) => r.start,
          getEnd: (r) => r.end,
          visibleRange,
          buffer: 0,
        })
      );

      // Regions 2 (20-30), 3 (40-50) are fully visible
      // Region 4 (60-70) is outside (starts at 60, range ends at 55)
      expect(result.current.visibleItems).toHaveLength(2);
      expect(result.current.visibleItems.map((r) => r.id)).toEqual([2, 3]);
      expect(result.current.count).toBe(2);
      expect(result.current.total).toBe(5);
    });

    it('includes items overlapping start of viewport', () => {
      const visibleRange: TimeRange = { start: 25, end: 55 };

      const { result } = renderHook(() =>
        useVisibleItems({
          items: regions,
          getStart: (r) => r.start,
          getEnd: (r) => r.end,
          visibleRange,
          buffer: 0,
        })
      );

      // Region 2 (20-30) overlaps start
      expect(result.current.visibleItems.map((r) => r.id)).toContain(2);
    });

    it('includes items overlapping end of viewport', () => {
      const visibleRange: TimeRange = { start: 15, end: 45 };

      const { result } = renderHook(() =>
        useVisibleItems({
          items: regions,
          getStart: (r) => r.start,
          getEnd: (r) => r.end,
          visibleRange,
          buffer: 0,
        })
      );

      // Region 3 (40-50) overlaps end
      expect(result.current.visibleItems.map((r) => r.id)).toContain(3);
    });

    it('includes items spanning entire viewport', () => {
      const visibleRange: TimeRange = { start: 22, end: 28 };

      const { result } = renderHook(() =>
        useVisibleItems({
          items: regions,
          getStart: (r) => r.start,
          getEnd: (r) => r.end,
          visibleRange,
          buffer: 0,
        })
      );

      // Region 2 (20-30) spans entire viewport
      expect(result.current.visibleItems).toHaveLength(1);
      expect(result.current.visibleItems[0].id).toBe(2);
    });

    it('excludes items fully before viewport', () => {
      const visibleRange: TimeRange = { start: 50, end: 80 };

      const { result } = renderHook(() =>
        useVisibleItems({
          items: regions,
          getStart: (r) => r.start,
          getEnd: (r) => r.end,
          visibleRange,
          buffer: 0,
        })
      );

      // Regions 1-3 are before viewport
      expect(result.current.visibleItems.map((r) => r.id)).not.toContain(1);
      expect(result.current.visibleItems.map((r) => r.id)).not.toContain(2);
    });

    it('excludes items fully after viewport', () => {
      const visibleRange: TimeRange = { start: 0, end: 35 };

      const { result } = renderHook(() =>
        useVisibleItems({
          items: regions,
          getStart: (r) => r.start,
          getEnd: (r) => r.end,
          visibleRange,
          buffer: 0,
        })
      );

      // Regions 3-5 are after viewport
      expect(result.current.visibleItems.map((r) => r.id)).not.toContain(4);
      expect(result.current.visibleItems.map((r) => r.id)).not.toContain(5);
    });
  });

  describe('buffer', () => {
    it('includes items within buffer zone', () => {
      const visibleRange: TimeRange = { start: 30, end: 60 };

      const { result } = renderHook(() =>
        useVisibleItems({
          items: regions,
          getStart: (r) => r.start,
          getEnd: (r) => r.end,
          visibleRange,
          buffer: 15, // Buffer extends to 15-75
        })
      );

      // Region 2 (20-30) is within buffer
      expect(result.current.visibleItems.map((r) => r.id)).toContain(2);
      // Region 4 (60-70) is within buffer
      expect(result.current.visibleItems.map((r) => r.id)).toContain(4);
    });

    it('uses default buffer of 10 seconds', () => {
      const visibleRange: TimeRange = { start: 35, end: 55 };

      const { result } = renderHook(() =>
        useVisibleItems({
          items: regions,
          getStart: (r) => r.start,
          getEnd: (r) => r.end,
          visibleRange,
          // No buffer specified - should use default of 10
        })
      );

      // Buffer extends to 25-65
      // Region 2 (20-30) should be included (ends at 30, buffer starts at 25)
      expect(result.current.visibleItems.map((r) => r.id)).toContain(2);
      // Region 4 (60-70) should be included (starts at 60, buffer ends at 65)
      expect(result.current.visibleItems.map((r) => r.id)).toContain(4);
    });
  });

  describe('point items (no getEnd)', () => {
    it('filters point items correctly', () => {
      const visibleRange: TimeRange = { start: 20, end: 50 };

      const { result } = renderHook(() =>
        useVisibleItems({
          items: markers,
          getStart: (m) => m.position,
          // No getEnd - markers are points
          visibleRange,
          buffer: 0,
        })
      );

      // Markers at 25 and 45 are visible
      expect(result.current.visibleItems).toHaveLength(2);
      expect(result.current.visibleItems.map((m) => m.id)).toEqual([2, 3]);
    });
  });

  describe('empty and edge cases', () => {
    it('handles empty items array', () => {
      const visibleRange: TimeRange = { start: 0, end: 100 };

      const { result } = renderHook(() =>
        useVisibleItems({
          items: [],
          getStart: (r: { start: number }) => r.start,
          visibleRange,
        })
      );

      expect(result.current.visibleItems).toHaveLength(0);
      expect(result.current.count).toBe(0);
      expect(result.current.total).toBe(0);
    });

    it('handles zero-width viewport', () => {
      const visibleRange: TimeRange = { start: 25, end: 25 };

      const { result } = renderHook(() =>
        useVisibleItems({
          items: regions,
          getStart: (r) => r.start,
          getEnd: (r) => r.end,
          visibleRange,
          buffer: 0,
        })
      );

      // Only region 2 (20-30) contains point 25
      expect(result.current.visibleItems).toHaveLength(1);
      expect(result.current.visibleItems[0].id).toBe(2);
    });

    it('handles items at exact viewport boundaries', () => {
      const visibleRange: TimeRange = { start: 20, end: 50 };

      const { result } = renderHook(() =>
        useVisibleItems({
          items: regions,
          getStart: (r) => r.start,
          getEnd: (r) => r.end,
          visibleRange,
          buffer: 0,
        })
      );

      // Region 2 starts exactly at viewport start (20)
      // Region 3 ends exactly at viewport end (50)
      expect(result.current.visibleItems.map((r) => r.id)).toContain(2);
      expect(result.current.visibleItems.map((r) => r.id)).toContain(3);
    });
  });
});

describe('useVisibleMarkers', () => {
  const markers = [
    { id: 1, position: 10, name: 'A' },
    { id: 2, position: 30, name: 'B' },
    { id: 3, position: 50, name: 'C' },
  ];

  it('filters markers by position', () => {
    const { result } = renderHook(() =>
      useVisibleMarkers(markers, { start: 20, end: 40 }, 0)
    );

    expect(result.current.visibleItems).toHaveLength(1);
    expect(result.current.visibleItems[0].name).toBe('B');
  });
});

describe('useVisibleRegions', () => {
  const regions = [
    { id: 1, start: 0, end: 20, name: 'Intro' },
    { id: 2, start: 30, end: 60, name: 'Verse' },
    { id: 3, start: 70, end: 100, name: 'Chorus' },
  ];

  it('filters regions by start/end', () => {
    const { result } = renderHook(() =>
      useVisibleRegions(regions, { start: 25, end: 75 }, 0)
    );

    expect(result.current.visibleItems).toHaveLength(2);
    expect(result.current.visibleItems.map((r) => r.name)).toEqual(['Verse', 'Chorus']);
  });
});

describe('useVisibleMediaItems', () => {
  const items = [
    { guid: 'a', position: 0, length: 10 },
    { guid: 'b', position: 20, length: 15 }, // ends at 35
    { guid: 'c', position: 50, length: 20 }, // ends at 70
  ];

  it('filters items by position + length', () => {
    const { result } = renderHook(() =>
      useVisibleMediaItems(items, { start: 30, end: 55 }, 0)
    );

    // Item b (20-35) overlaps start
    // Item c (50-70) overlaps viewport
    expect(result.current.visibleItems).toHaveLength(2);
    expect(result.current.visibleItems.map((i) => i.guid)).toEqual(['b', 'c']);
  });
});
