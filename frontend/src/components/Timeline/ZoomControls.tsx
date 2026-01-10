/**
 * Zoom Controls Component
 * Provides zoom in/out buttons and level indicator for timeline viewport
 */

import { type ReactElement, useCallback } from 'react';
import { ZoomIn, ZoomOut, Maximize2 } from 'lucide-react';
import { ZOOM_STEPS } from '../../hooks/useViewport';

export interface ZoomControlsProps {
  /** Current zoom level index (into ZOOM_STEPS) */
  zoomLevel: number;
  /** Current visible duration in seconds */
  visibleDuration: number;
  /** Zoom in callback (show less time, more detail) */
  onZoomIn: () => void;
  /** Zoom out callback (show more time, less detail) */
  onZoomOut: () => void;
  /** Fit to content callback */
  onFitToContent?: () => void;
  /** Optional className for container */
  className?: string;
}

/**
 * Format duration for display
 * @param seconds Duration in seconds
 * @returns Formatted string (e.g., "30s", "2m", "1h")
 */
function formatDuration(seconds: number): string {
  if (seconds < 60) {
    return `${Math.round(seconds)}s`;
  }
  if (seconds < 3600) {
    const minutes = Math.round(seconds / 60);
    return `${minutes}m`;
  }
  const hours = Math.round(seconds / 3600);
  return `${hours}h`;
}

export function ZoomControls({
  zoomLevel,
  visibleDuration,
  onZoomIn,
  onZoomOut,
  onFitToContent,
  className = '',
}: ZoomControlsProps): ReactElement {
  const canZoomIn = zoomLevel > 0;
  const canZoomOut = zoomLevel < ZOOM_STEPS.length - 1;

  const handleZoomIn = useCallback(
    (e: React.MouseEvent) => {
      e.stopPropagation();
      if (canZoomIn) onZoomIn();
    },
    [canZoomIn, onZoomIn]
  );

  const handleZoomOut = useCallback(
    (e: React.MouseEvent) => {
      e.stopPropagation();
      if (canZoomOut) onZoomOut();
    },
    [canZoomOut, onZoomOut]
  );

  const handleFitToContent = useCallback(
    (e: React.MouseEvent) => {
      e.stopPropagation();
      onFitToContent?.();
    },
    [onFitToContent]
  );

  return (
    <div className={`flex items-center gap-1 ${className}`}>
      {/* Zoom out (show more time) */}
      <button
        onClick={handleZoomOut}
        disabled={!canZoomOut}
        className={`p-1.5 rounded transition-colors ${
          canZoomOut
            ? 'text-text-secondary hover:bg-bg-hover hover:text-text-primary'
            : 'text-text-disabled cursor-not-allowed'
        }`}
        title="Zoom out (show more time)"
        aria-label="Zoom out"
      >
        <ZoomOut size={16} />
      </button>

      {/* Duration indicator */}
      <span
        className="min-w-[3rem] text-center text-xs font-medium text-text-tertiary tabular-nums"
        title={`Showing ${formatDuration(visibleDuration)} of timeline`}
      >
        {formatDuration(visibleDuration)}
      </span>

      {/* Zoom in (show less time, more detail) */}
      <button
        onClick={handleZoomIn}
        disabled={!canZoomIn}
        className={`p-1.5 rounded transition-colors ${
          canZoomIn
            ? 'text-text-secondary hover:bg-bg-hover hover:text-text-primary'
            : 'text-text-disabled cursor-not-allowed'
        }`}
        title="Zoom in (show more detail)"
        aria-label="Zoom in"
      >
        <ZoomIn size={16} />
      </button>

      {/* Fit to content */}
      {onFitToContent && (
        <button
          onClick={handleFitToContent}
          className="p-1.5 rounded text-text-secondary hover:bg-bg-hover hover:text-text-primary transition-colors ml-1"
          title="Fit to content"
          aria-label="Fit to content"
        >
          <Maximize2 size={16} />
        </button>
      )}
    </div>
  );
}
