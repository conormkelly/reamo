/**
 * useMarkerClusters Hook Tests
 */

import { describe, it, expect } from 'vitest';
import { renderHook } from '@testing-library/react';
import { useMarkerClusters } from './useMarkerClusters';
import type { Marker } from '../core/types';

// Helper to create test markers
function createMarker(id: number, position: number, name?: string): Marker {
  return {
    id,
    position,
    name: name ?? `Marker ${id}`,
    color: 0xffffff,
  };
}

describe('useMarkerClusters', () => {
  const defaultVisibleRange = { start: 0, end: 60 };
  const defaultContainerWidth = 800; // 800px / 60s = ~13.3 px/s

  describe('edge cases', () => {
    it('returns empty clusters for empty marker array', () => {
      const { result } = renderHook(() =>
        useMarkerClusters({
          markers: [],
          visibleRange: defaultVisibleRange,
          containerWidth: defaultContainerWidth,
        })
      );

      expect(result.current.clusters).toEqual([]);
      expect(result.current.hasClusters).toBe(false);
    });

    it('returns empty clusters when containerWidth is 0', () => {
      const { result } = renderHook(() =>
        useMarkerClusters({
          markers: [createMarker(0, 10)],
          visibleRange: defaultVisibleRange,
          containerWidth: 0,
        })
      );

      expect(result.current.clusters).toEqual([]);
      expect(result.current.hasClusters).toBe(false);
    });

    it('returns empty clusters when visibleDuration is 0', () => {
      const { result } = renderHook(() =>
        useMarkerClusters({
          markers: [createMarker(0, 10)],
          visibleRange: { start: 30, end: 30 },
          containerWidth: defaultContainerWidth,
        })
      );

      expect(result.current.clusters).toEqual([]);
      expect(result.current.hasClusters).toBe(false);
    });

    it('returns empty clusters when visibleDuration is negative', () => {
      const { result } = renderHook(() =>
        useMarkerClusters({
          markers: [createMarker(0, 10)],
          visibleRange: { start: 60, end: 30 },
          containerWidth: defaultContainerWidth,
        })
      );

      expect(result.current.clusters).toEqual([]);
      expect(result.current.hasClusters).toBe(false);
    });
  });

  describe('single marker handling', () => {
    it('handles a single marker as a cluster of 1', () => {
      const { result } = renderHook(() =>
        useMarkerClusters({
          markers: [createMarker(0, 30)],
          visibleRange: defaultVisibleRange,
          containerWidth: defaultContainerWidth,
        })
      );

      expect(result.current.clusters).toHaveLength(1);
      expect(result.current.clusters[0].count).toBe(1);
      expect(result.current.clusters[0].position).toBe(30);
      expect(result.current.clusters[0].markers).toHaveLength(1);
      expect(result.current.hasClusters).toBe(false);
    });
  });

  describe('clustering logic', () => {
    // With 800px container and 60s visible, pxPerSecond = 13.33
    // Merge threshold = 40px / 13.33 = ~3 seconds

    it('clusters markers within 40px threshold', () => {
      // 1 second apart at 13.33 px/s = 13.33px apart (< 40px threshold)
      const { result } = renderHook(() =>
        useMarkerClusters({
          markers: [
            createMarker(0, 10),
            createMarker(1, 11), // 1s apart = ~13px
            createMarker(2, 12), // 1s apart = ~13px
          ],
          visibleRange: defaultVisibleRange,
          containerWidth: defaultContainerWidth,
        })
      );

      expect(result.current.clusters).toHaveLength(1);
      expect(result.current.clusters[0].count).toBe(3);
      expect(result.current.hasClusters).toBe(true);
    });

    it('keeps markers separate when beyond 40px threshold', () => {
      // 10 seconds apart at 13.33 px/s = 133px apart (> 40px threshold)
      const { result } = renderHook(() =>
        useMarkerClusters({
          markers: [
            createMarker(0, 10),
            createMarker(1, 20), // 10s apart = ~133px
            createMarker(2, 30), // 10s apart = ~133px
          ],
          visibleRange: defaultVisibleRange,
          containerWidth: defaultContainerWidth,
        })
      );

      expect(result.current.clusters).toHaveLength(3);
      expect(result.current.clusters.every((c) => c.count === 1)).toBe(true);
      expect(result.current.hasClusters).toBe(false);
    });

    it('creates mixed clusters based on proximity', () => {
      // Group 1: markers at 10, 11 (1s apart = ~13px, should cluster)
      // Separate: marker at 30 (19s from 11 = ~253px, should be alone)
      // Group 2: markers at 50, 51 (1s apart = ~13px, should cluster)
      const { result } = renderHook(() =>
        useMarkerClusters({
          markers: [
            createMarker(0, 10),
            createMarker(1, 11),
            createMarker(2, 30),
            createMarker(3, 50),
            createMarker(4, 51),
          ],
          visibleRange: defaultVisibleRange,
          containerWidth: defaultContainerWidth,
        })
      );

      expect(result.current.clusters).toHaveLength(3);
      expect(result.current.clusters[0].count).toBe(2); // 10, 11
      expect(result.current.clusters[1].count).toBe(1); // 30
      expect(result.current.clusters[2].count).toBe(2); // 50, 51
      expect(result.current.hasClusters).toBe(true);
    });

    it('handles unsorted markers by sorting them', () => {
      const { result } = renderHook(() =>
        useMarkerClusters({
          markers: [
            createMarker(0, 30),
            createMarker(1, 10),
            createMarker(2, 20),
          ],
          visibleRange: defaultVisibleRange,
          containerWidth: defaultContainerWidth,
        })
      );

      // Should be sorted: 10, 20, 30
      expect(result.current.clusters).toHaveLength(3);
      expect(result.current.clusters[0].position).toBe(10);
      expect(result.current.clusters[1].position).toBe(20);
      expect(result.current.clusters[2].position).toBe(30);
    });
  });

  describe('zoom-dependent clustering', () => {
    it('clusters more when zoomed out (larger visible range)', () => {
      const markers = [
        createMarker(0, 10),
        createMarker(1, 15), // 5s apart
        createMarker(2, 20), // 5s apart
      ];

      // Zoomed in: 30s visible, 800px = 26.67 px/s
      // 5s = 133px apart (> 40px) - should NOT cluster
      const { result: zoomedIn } = renderHook(() =>
        useMarkerClusters({
          markers,
          visibleRange: { start: 0, end: 30 },
          containerWidth: 800,
        })
      );

      expect(zoomedIn.current.clusters).toHaveLength(3);
      expect(zoomedIn.current.hasClusters).toBe(false);

      // Zoomed out: 300s visible, 800px = 2.67 px/s
      // 5s = 13.3px apart (< 40px) - should cluster
      const { result: zoomedOut } = renderHook(() =>
        useMarkerClusters({
          markers,
          visibleRange: { start: 0, end: 300 },
          containerWidth: 800,
        })
      );

      expect(zoomedOut.current.clusters).toHaveLength(1);
      expect(zoomedOut.current.clusters[0].count).toBe(3);
      expect(zoomedOut.current.hasClusters).toBe(true);
    });
  });

  describe('cluster properties', () => {
    it('calculates cluster center position correctly', () => {
      const { result } = renderHook(() =>
        useMarkerClusters({
          markers: [
            createMarker(0, 10),
            createMarker(1, 11),
            createMarker(2, 12),
          ],
          visibleRange: defaultVisibleRange,
          containerWidth: defaultContainerWidth,
        })
      );

      // Center of 10-12 should be 11
      expect(result.current.clusters[0].position).toBe(11);
    });

    it('generates unique cluster IDs', () => {
      const { result } = renderHook(() =>
        useMarkerClusters({
          markers: [
            createMarker(0, 10),
            createMarker(1, 11),
            createMarker(2, 30),
          ],
          visibleRange: defaultVisibleRange,
          containerWidth: defaultContainerWidth,
        })
      );

      const ids = result.current.clusters.map((c) => c.id);
      const uniqueIds = new Set(ids);
      expect(uniqueIds.size).toBe(ids.length);
    });

    it('includes all original markers in clusters', () => {
      const markers = [
        createMarker(0, 10),
        createMarker(1, 11),
        createMarker(2, 30),
        createMarker(3, 31),
      ];

      const { result } = renderHook(() =>
        useMarkerClusters({
          markers,
          visibleRange: defaultVisibleRange,
          containerWidth: defaultContainerWidth,
        })
      );

      const allClusteredMarkers = result.current.clusters.flatMap((c) => c.markers);
      expect(allClusteredMarkers).toHaveLength(4);

      // Verify all original marker IDs are present
      const markerIds = allClusteredMarkers.map((m) => m.id).sort();
      expect(markerIds).toEqual([0, 1, 2, 3]);
    });
  });

  describe('memoization', () => {
    it('returns same reference when inputs unchanged', () => {
      const markers = [createMarker(0, 10), createMarker(1, 20)];
      const visibleRange = { start: 0, end: 60 };

      const { result, rerender } = renderHook(
        ({ markers, visibleRange, containerWidth }) =>
          useMarkerClusters({ markers, visibleRange, containerWidth }),
        {
          initialProps: {
            markers,
            visibleRange,
            containerWidth: 800,
          },
        }
      );

      const firstResult = result.current.clusters;

      // Rerender with same props
      rerender({ markers, visibleRange, containerWidth: 800 });

      expect(result.current.clusters).toBe(firstResult);
    });

    it('recalculates when markers change', () => {
      const { result, rerender } = renderHook(
        ({ markers }) =>
          useMarkerClusters({
            markers,
            visibleRange: defaultVisibleRange,
            containerWidth: defaultContainerWidth,
          }),
        {
          initialProps: {
            markers: [createMarker(0, 10)],
          },
        }
      );

      expect(result.current.clusters).toHaveLength(1);

      // Add a marker
      rerender({ markers: [createMarker(0, 10), createMarker(1, 20)] });

      expect(result.current.clusters).toHaveLength(2);
    });

    it('recalculates when visible range changes', () => {
      const markers = [
        createMarker(0, 10),
        createMarker(1, 15),
      ];

      const { result, rerender } = renderHook(
        ({ visibleRange }) =>
          useMarkerClusters({
            markers,
            visibleRange,
            containerWidth: 800,
          }),
        {
          initialProps: {
            visibleRange: { start: 0, end: 30 }, // Zoomed in
          },
        }
      );

      const initialHasClusters = result.current.hasClusters;

      // Zoom out significantly
      rerender({ visibleRange: { start: 0, end: 300 } });

      // Clustering behavior may change
      expect(result.current.hasClusters).not.toBe(initialHasClusters);
    });
  });
});
