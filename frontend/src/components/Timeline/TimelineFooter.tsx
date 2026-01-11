/**
 * Timeline Footer Controls
 * Provides zoom, follow playhead, and selection mode controls
 * Positioned as a footer bar beneath the marker pills
 */

import { type ReactElement } from 'react';
import { Crosshair, Locate } from 'lucide-react';
import { ZoomControls } from './ZoomControls';

export interface TimelineFooterProps {
  /** Whether follow playhead is active */
  followPlayhead: boolean;
  /** Toggle follow playhead */
  onFollowPlayheadToggle: () => void;
  /** Whether selection mode is active */
  selectionModeActive: boolean;
  /** Toggle selection mode */
  onSelectionModeToggle: () => void;
  /** Current zoom level index */
  zoomLevel: number;
  /** Visible duration in seconds */
  visibleDuration: number;
  /** Zoom in callback */
  onZoomIn: () => void;
  /** Zoom out callback */
  onZoomOut: () => void;
  /** Fit to content callback */
  onFitToContent: () => void;
}

export function TimelineFooter({
  followPlayhead,
  onFollowPlayheadToggle,
  selectionModeActive,
  onSelectionModeToggle,
  zoomLevel,
  visibleDuration,
  onZoomIn,
  onZoomOut,
  onFitToContent,
}: TimelineFooterProps): ReactElement {
  return (
    <div className="flex items-center justify-end gap-1 px-2 py-1 bg-bg-deep rounded-b-lg border-t border-border-subtle">
      {/* Follow playhead toggle */}
      <button
        data-testid="follow-playhead-toggle"
        onClick={onFollowPlayheadToggle}
        className={`p-1.5 rounded transition-colors ${
          followPlayhead
            ? 'bg-primary text-text-on-primary'
            : 'text-text-tertiary hover:bg-bg-hover hover:text-text-secondary'
        }`}
        title={followPlayhead ? 'Stop following playhead' : 'Follow playhead'}
        aria-pressed={followPlayhead}
      >
        <Locate size={14} />
      </button>

      {/* Selection mode toggle */}
      <button
        data-testid="selection-toggle"
        onClick={onSelectionModeToggle}
        className={`p-1.5 rounded transition-colors ${
          selectionModeActive
            ? 'bg-primary text-text-on-primary'
            : 'text-text-tertiary hover:bg-bg-hover hover:text-text-secondary'
        }`}
        title={selectionModeActive ? 'Exit selection mode (pan mode)' : 'Enter selection mode'}
        aria-pressed={selectionModeActive}
      >
        <Crosshair size={14} />
      </button>

      {/* Divider */}
      <div className="w-px h-4 bg-border-subtle mx-1" />

      {/* Zoom controls */}
      <ZoomControls
        zoomLevel={zoomLevel}
        visibleDuration={visibleDuration}
        onZoomIn={onZoomIn}
        onZoomOut={onZoomOut}
        onFitToContent={onFitToContent}
      />
    </div>
  );
}
