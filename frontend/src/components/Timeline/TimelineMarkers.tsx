/**
 * TimelineMarkers Component
 * Renders marker lines and pills in the timeline
 *
 * Supports two rendering modes:
 * - Individual markers (default)
 * - Clustered markers (when useMarkerClusters hook provides clusters)
 */

import type { ReactElement } from 'react';
import type { Marker } from '../../core/types';
import type { MarkerClusterData } from '../../hooks/useMarkerClusters';
import type { TimelineMode } from '../../store';
import { reaperColorToHex, formatTime } from '../../utils';

export interface TimelineMarkersProps {
  /** Markers to display */
  markers: Marker[];
  /** Current timeline mode */
  timelineMode: TimelineMode;
  /** Convert time to percentage position */
  renderTimeToPercent: (time: number) => number;
}

export interface TimelineMarkerPillsProps extends TimelineMarkersProps {
  /** Marker currently being dragged */
  draggedMarker: Marker | null;
  /** Whether a marker is currently being dragged */
  isDraggingMarker: boolean;
  /** Pointer down handler for marker drag */
  handleMarkerPointerDown: (e: React.PointerEvent, marker: Marker) => void;
  /** Pointer move handler for marker drag */
  handleMarkerPointerMove: (e: React.PointerEvent) => void;
  /** Pointer up handler for marker drag */
  handleMarkerPointerUp: (e: React.PointerEvent) => void;
}

/**
 * Get the outline color for a marker
 * - Uses marker's custom color if available
 * - Falls back to default marker color (red) for markers without custom color
 * - Muted gray in regions mode (markers disabled)
 */
function getMarkerColor(marker: Marker, timelineMode: TimelineMode): string {
  // In regions mode: muted gray (markers are disabled)
  if (timelineMode === 'regions') {
    return 'var(--color-text-muted)';
  }

  // Use marker's custom color or default
  const customColor = marker.color ? reaperColorToHex(marker.color) : null;
  return customColor || 'var(--color-marker-default)';
}

/**
 * Marker lines in the main timeline area
 */
export function TimelineMarkerLines({
  markers,
  timelineMode,
  renderTimeToPercent,
}: TimelineMarkersProps): ReactElement {
  return (
    <>
      {markers.map((marker) => {
        const color = getMarkerColor(marker, timelineMode);
        const opacity = timelineMode === 'regions' ? 0.4 : 1;
        return (
          <div
            key={`marker-${marker.id}`}
            className="absolute top-0 bottom-0 w-0.5"
            style={{
              left: `${renderTimeToPercent(marker.position)}%`,
              backgroundColor: color,
              opacity,
            }}
            aria-hidden="true"
          />
        );
      })}
    </>
  );
}

/**
 * Marker pills in the bottom bar (interactive)
 * Design: Outlined pill with dark interior, white text
 * - 2px colored outline (marker color or red default)
 * - Thin dark stroke outside for contrast with light colors
 * - Dark interior (bg-bg-surface)
 * - White text for number
 */
export function TimelineMarkerPills({
  markers,
  timelineMode,
  renderTimeToPercent,
  draggedMarker,
  isDraggingMarker,
  handleMarkerPointerDown,
  handleMarkerPointerMove,
  handleMarkerPointerUp,
}: TimelineMarkerPillsProps): ReactElement {
  return (
    <>
      {markers.map((marker) => {
        const isBeingDragged = draggedMarker?.id === marker.id;
        const outlineColor = getMarkerColor(marker, timelineMode);
        const isDisabled = timelineMode === 'regions';

        // Build descriptive label for screen readers
        const positionStr = formatTime(marker.position);
        const nameStr = marker.name ? `: ${marker.name}` : '';
        const ariaLabel = `Marker ${marker.id}${nameStr} at ${positionStr}`;

        return (
          <div
            key={`marker-pill-${marker.id}`}
            role="button"
            aria-label={ariaLabel}
            aria-disabled={isDisabled}
            className={`absolute top-1/2 -translate-y-1/2 -translate-x-1/2 min-w-5 h-5 px-1.5 rounded-full flex items-center justify-center touch-none select-none transition-opacity bg-bg-surface ${
              isDisabled
                ? 'pointer-events-none opacity-40'
                : 'cursor-grab active:cursor-grabbing'
            } ${isBeingDragged && isDraggingMarker ? 'opacity-50' : ''}`}
            style={{
              left: `calc(${renderTimeToPercent(marker.position)}% + 1px)`,
              // 2px colored outline + 1px dark stroke outside for contrast
              border: `2px solid ${outlineColor}`,
              boxShadow: '0 0 0 1px var(--color-shadow-contrast)',
            }}
            onPointerDown={isDisabled ? undefined : (e) => handleMarkerPointerDown(e, marker)}
            onPointerMove={isDisabled ? undefined : handleMarkerPointerMove}
            onPointerUp={isDisabled ? undefined : handleMarkerPointerUp}
            onPointerCancel={isDisabled ? undefined : handleMarkerPointerUp}
          >
            <span className="text-[10px] font-bold leading-none text-text-marker">
              {marker.id}
            </span>
          </div>
        );
      })}
    </>
  );
}

// ============================================
// Clustered Marker Components
// ============================================

export interface ClusteredMarkerLinesProps {
  /** Clusters to display */
  clusters: MarkerClusterData[];
  /** Current timeline mode */
  timelineMode: TimelineMode;
  /** Convert time to percentage position */
  renderTimeToPercent: (time: number) => number;
}

/**
 * Marker lines with cluster support
 * Single-marker clusters render as normal lines
 * Multi-marker clusters render as dashed/thicker lines
 */
export function ClusteredMarkerLines({
  clusters,
  timelineMode,
  renderTimeToPercent,
}: ClusteredMarkerLinesProps): ReactElement {
  return (
    <>
      {clusters.map((cluster) => {
        const opacity = timelineMode === 'regions' ? 0.4 : 1;

        if (cluster.count === 1) {
          // Single marker - render normally
          const marker = cluster.markers[0];
          const color = getMarkerColor(marker, timelineMode);
          return (
            <div
              key={`marker-${marker.id}`}
              className="absolute top-0 bottom-0 w-0.5"
              style={{
                left: `${renderTimeToPercent(marker.position)}%`,
                backgroundColor: color,
                opacity,
              }}
              aria-hidden="true"
            />
          );
        }

        // Multiple markers - render cluster line (dashed)
        const color = timelineMode === 'regions' ? 'var(--color-text-muted)' : 'var(--color-marker-default)';
        return (
          <div
            key={cluster.id}
            className="absolute top-0 bottom-0 w-1"
            style={{
              left: `${renderTimeToPercent(cluster.position)}%`,
              opacity,
              background: `repeating-linear-gradient(
                to bottom,
                ${color} 0px,
                ${color} 4px,
                transparent 4px,
                transparent 8px
              )`,
            }}
            aria-hidden="true"
            title={`${cluster.count} markers`}
          />
        );
      })}
    </>
  );
}

export interface ClusteredMarkerPillsProps extends Omit<TimelineMarkerPillsProps, 'markers'> {
  /** Clusters to display */
  clusters: MarkerClusterData[];
  /** Called when a cluster is tapped */
  onClusterTap?: (cluster: MarkerClusterData) => void;
}

/**
 * Marker pills with cluster support
 * Single-marker clusters render as normal pills
 * Multi-marker clusters render as cluster badges
 */
export function ClusteredMarkerPills({
  clusters,
  timelineMode,
  renderTimeToPercent,
  draggedMarker,
  isDraggingMarker,
  handleMarkerPointerDown,
  handleMarkerPointerMove,
  handleMarkerPointerUp,
  onClusterTap,
}: ClusteredMarkerPillsProps): ReactElement {
  const isDisabled = timelineMode === 'regions';

  return (
    <>
      {clusters.map((cluster) => {
        if (cluster.count === 1) {
          // Single marker - render normally
          const marker = cluster.markers[0];
          const isBeingDragged = draggedMarker?.id === marker.id;
          const outlineColor = getMarkerColor(marker, timelineMode);

          const positionStr = formatTime(marker.position);
          const nameStr = marker.name ? `: ${marker.name}` : '';
          const ariaLabel = `Marker ${marker.id}${nameStr} at ${positionStr}`;

          return (
            <div
              key={`marker-pill-${marker.id}`}
              role="button"
              aria-label={ariaLabel}
              aria-disabled={isDisabled}
              className={`absolute top-1/2 -translate-y-1/2 -translate-x-1/2 min-w-5 h-5 px-1.5 rounded-full flex items-center justify-center touch-none select-none transition-opacity bg-bg-surface ${
                isDisabled
                  ? 'pointer-events-none opacity-40'
                  : 'cursor-grab active:cursor-grabbing'
              } ${isBeingDragged && isDraggingMarker ? 'opacity-50' : ''}`}
              style={{
                left: `calc(${renderTimeToPercent(marker.position)}% + 1px)`,
                border: `2px solid ${outlineColor}`,
                boxShadow: '0 0 0 1px var(--color-shadow-contrast)',
              }}
              onPointerDown={isDisabled ? undefined : (e) => handleMarkerPointerDown(e, marker)}
              onPointerMove={isDisabled ? undefined : handleMarkerPointerMove}
              onPointerUp={isDisabled ? undefined : handleMarkerPointerUp}
              onPointerCancel={isDisabled ? undefined : handleMarkerPointerUp}
            >
              <span className="text-[10px] font-bold leading-none text-text-marker">
                {marker.id}
              </span>
            </div>
          );
        }

        // Multiple markers - render cluster badge
        const badgeColor = timelineMode === 'regions' ? 'var(--color-text-muted)' : 'var(--color-marker-default)';
        const markerNames = cluster.markers.map((m) => m.name || `Marker ${m.id}`).join(', ');
        const ariaLabel = `${cluster.count} markers: ${markerNames}`;

        return (
          <button
            key={cluster.id}
            type="button"
            aria-label={ariaLabel}
            aria-disabled={isDisabled}
            className={`absolute top-1/2 -translate-y-1/2 -translate-x-1/2 min-w-6 h-5 px-2 rounded-full flex items-center justify-center touch-none select-none transition-opacity bg-bg-surface ${
              isDisabled ? 'pointer-events-none opacity-40' : 'cursor-pointer hover:opacity-80'
            }`}
            style={{
              left: `${renderTimeToPercent(cluster.position)}%`,
              border: `2px solid ${badgeColor}`,
              boxShadow: '0 0 0 1px var(--color-shadow-contrast)',
            }}
            onClick={isDisabled ? undefined : () => onClusterTap?.(cluster)}
            disabled={isDisabled}
          >
            <span className="text-[10px] font-bold leading-none text-text-marker">
              {cluster.count}
            </span>
          </button>
        );
      })}
    </>
  );
}
