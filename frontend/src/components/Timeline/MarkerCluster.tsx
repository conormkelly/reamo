/**
 * MarkerCluster Component
 * Renders a cluster badge for multiple overlapping markers at low zoom.
 *
 * Behavior (graduated based on cluster size):
 * - 1 marker: Renders as normal marker (caller should handle this)
 * - 2-5 markers: Tap opens popover with tappable list
 * - 6+ markers: Tap zooms to expand
 * - At max zoom with 6+: Scrollable popover
 *
 * @example
 * ```tsx
 * <MarkerCluster
 *   cluster={cluster}
 *   leftPercent={timeToPercent(cluster.position)}
 *   onTap={handleClusterTap}
 * />
 * ```
 */

import type { ReactElement } from 'react';
import type { MarkerClusterData } from '../../hooks/useMarkerClusters';
import type { TimelineMode } from '../../store';

export interface MarkerClusterProps {
  /** The cluster to render */
  cluster: MarkerClusterData;
  /** Horizontal position as percentage (0-100) */
  leftPercent: number;
  /** Current timeline mode */
  timelineMode: TimelineMode;
  /** Called when cluster is tapped */
  onTap?: (cluster: MarkerClusterData) => void;
  /** Whether this cluster is in a disabled state */
  disabled?: boolean;
}

/**
 * Get cluster badge color based on timeline mode
 */
function getClusterColor(timelineMode: TimelineMode): string {
  if (timelineMode === 'regions') {
    return 'var(--color-text-muted)';
  }
  return 'var(--color-marker-default)';
}

/**
 * Marker cluster badge component
 */
export function MarkerCluster({
  cluster,
  leftPercent,
  timelineMode,
  onTap,
  disabled = false,
}: MarkerClusterProps): ReactElement {
  const isDisabled = disabled || timelineMode === 'regions';
  const badgeColor = getClusterColor(timelineMode);

  // Build aria label with marker names
  const markerNames = cluster.markers.map((m) => m.name || `Marker ${m.id}`).join(', ');
  const ariaLabel = `${cluster.count} markers: ${markerNames}`;

  const handleClick = () => {
    if (!isDisabled && onTap) {
      onTap(cluster);
    }
  };

  return (
    <button
      type="button"
      aria-label={ariaLabel}
      aria-disabled={isDisabled}
      className={`absolute top-1/2 -translate-y-1/2 -translate-x-1/2 min-w-6 h-6 px-2 rounded-full flex items-center justify-center touch-none select-none transition-opacity bg-bg-surface ${
        isDisabled ? 'pointer-events-none opacity-40' : 'cursor-pointer hover:opacity-80'
      }`}
      style={{
        left: `${leftPercent}%`,
        border: `2px solid ${badgeColor}`,
        boxShadow: '0 0 0 1px var(--color-shadow-contrast)',
      }}
      onClick={handleClick}
      disabled={isDisabled}
    >
      <span className="text-[11px] font-bold leading-none text-text-marker">{cluster.count}</span>
    </button>
  );
}

/**
 * Marker cluster line in main timeline area
 * Shows a thicker/dotted line to indicate multiple markers
 */
export function MarkerClusterLine({
  cluster,
  leftPercent,
  timelineMode,
}: Pick<MarkerClusterProps, 'cluster' | 'leftPercent' | 'timelineMode'>): ReactElement {
  const color = getClusterColor(timelineMode);
  const opacity = timelineMode === 'regions' ? 0.4 : 1;

  return (
    <div
      className="absolute top-0 bottom-0 w-1"
      style={{
        left: `${leftPercent}%`,
        backgroundColor: color,
        opacity,
        // Dashed appearance for clusters
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
}
