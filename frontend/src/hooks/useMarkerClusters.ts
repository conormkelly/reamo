/**
 * Marker Clustering Hook
 * Clusters markers that are too close together at current zoom level.
 *
 * Uses 40px merge threshold (Mapbox Supercluster default).
 * Clustering is zoom-dependent: zooming in reveals individual markers.
 *
 * @example
 * ```tsx
 * const { clusters } = useMarkerClusters({
 *   markers,
 *   visibleRange: { start: 0, end: 60 },
 *   containerWidth: 800,
 * });
 *
 * {clusters.map(cluster =>
 *   cluster.count === 1
 *     ? <Marker key={cluster.id} marker={cluster.markers[0]} />
 *     : <MarkerCluster key={cluster.id} cluster={cluster} />
 * )}
 * ```
 */

import { useMemo } from 'react';
import type { Marker } from '../core/types';
import type { TimeRange } from './useViewport';

/** Minimum pixel distance between markers before clustering */
const MERGE_THRESHOLD_PX = 40;

/** A cluster of one or more markers */
export interface MarkerClusterData {
  /** Unique ID for React key */
  id: string;
  /** Center position of cluster in seconds */
  position: number;
  /** Markers in this cluster */
  markers: Marker[];
  /** Number of markers (convenience) */
  count: number;
}

export interface UseMarkerClustersOptions {
  /** All markers to cluster */
  markers: Marker[];
  /** Current visible time range */
  visibleRange: TimeRange;
  /** Container width in pixels */
  containerWidth: number;
}

export interface UseMarkerClustersReturn {
  /** Clustered markers (single-marker clusters have count=1) */
  clusters: MarkerClusterData[];
  /** True if any clustering occurred (count > 1) */
  hasClusters: boolean;
}

/**
 * Creates a cluster from an array of markers
 */
function createCluster(markers: Marker[]): MarkerClusterData {
  const startPosition = markers[0].position;
  const endPosition = markers[markers.length - 1].position;
  const centerPosition = (startPosition + endPosition) / 2;

  return {
    id: `cluster-${markers[0].id}-${markers.length}`,
    position: centerPosition,
    markers,
    count: markers.length,
  };
}

/**
 * Hook for clustering markers based on zoom level
 */
export function useMarkerClusters({
  markers,
  visibleRange,
  containerWidth,
}: UseMarkerClustersOptions): UseMarkerClustersReturn {
  return useMemo(() => {
    // Edge cases: no markers or no container
    if (markers.length === 0 || containerWidth === 0) {
      return { clusters: [], hasClusters: false };
    }

    const visibleDuration = visibleRange.end - visibleRange.start;
    if (visibleDuration <= 0) {
      return { clusters: [], hasClusters: false };
    }

    // Calculate the time threshold for merging based on pixel distance
    const pxPerSecond = containerWidth / visibleDuration;
    const mergeThresholdSeconds = MERGE_THRESHOLD_PX / pxPerSecond;

    // Sort markers by position for linear clustering
    const sorted = [...markers].sort((a, b) => a.position - b.position);

    const clusters: MarkerClusterData[] = [];
    let currentGroup: Marker[] = [];

    for (const marker of sorted) {
      if (currentGroup.length === 0) {
        // Start a new group
        currentGroup = [marker];
      } else {
        const lastMarker = currentGroup[currentGroup.length - 1];
        const gap = marker.position - lastMarker.position;

        if (gap <= mergeThresholdSeconds) {
          // Close enough: add to current group
          currentGroup.push(marker);
        } else {
          // Too far: finalize current group and start new one
          clusters.push(createCluster(currentGroup));
          currentGroup = [marker];
        }
      }
    }

    // Don't forget the last group
    if (currentGroup.length > 0) {
      clusters.push(createCluster(currentGroup));
    }

    const hasClusters = clusters.some((c) => c.count > 1);

    return { clusters, hasClusters };
  }, [markers, visibleRange.start, visibleRange.end, containerWidth]);
}
