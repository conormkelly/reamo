/**
 * Timeline Footer Controls
 * Provides marker navigation, mode toggles, and zoom controls
 * Layout: [⏮⏭] | [📍⬚] | [−][30s][+][⬛]
 */

import type { ReactElement } from 'react';
import { SquareDashedMousePointer, Locate, SkipBack, SkipForward } from 'lucide-react';
import { ZoomControls } from './ZoomControls';
import { useLongPress } from '../../hooks/useLongPress';

export interface TimelineFooterProps {
  // Marker navigation
  onPrevMarker: () => void;
  onNextMarker: () => void;

  // Mode toggles
  followPlayhead: boolean;
  onFollowPlayheadToggle: () => void;
  selectionModeActive: boolean;
  onSelectionModeToggle: () => void;
  /** Hold on the selection mode button; without it a hold is a tap */
  onSelectionLongPress?: () => void;

  // Zoom controls
  visibleDuration: number;
  onZoomIn: () => void;
  onZoomOut: () => void;
  onFitToContent: () => void;
}

// Long-press duration in ms
const LONG_PRESS_DURATION = 400;

export function TimelineFooter({
  onPrevMarker,
  onNextMarker,
  followPlayhead,
  onFollowPlayheadToggle,
  selectionModeActive,
  onSelectionModeToggle,
  onSelectionLongPress,
  visibleDuration,
  onZoomIn,
  onZoomOut,
  onFitToContent,
}: TimelineFooterProps): ReactElement {
  // Tap toggles selection mode, hold opens manual selection input
  const { handlers: selectionHandlers } = useLongPress({
    onTap: onSelectionModeToggle,
    onLongPress: onSelectionLongPress,
    duration: LONG_PRESS_DURATION,
  });

  // Common button styles
  const buttonBase = 'p-2.5 rounded-lg transition-colors touch-none';
  const buttonWide = 'py-2.5 px-4 rounded-lg transition-colors touch-none'; // Wider for nav buttons
  const buttonInactive = 'text-text-tertiary hover:bg-bg-hover hover:text-text-secondary active:bg-bg-surface';
  const buttonActive = 'bg-primary text-text-on-primary';

  return (
    <div className="flex items-center px-2 py-2 bg-bg-deep rounded-b-lg border-t border-border-subtle">
      {/* Left: Mode toggles - flex-1 to balance */}
      <div className="flex-1 flex items-center gap-1">
        {/* Follow playhead */}
        <button
          data-testid="follow-playhead-toggle"
          onClick={onFollowPlayheadToggle}
          className={`${buttonBase} ${followPlayhead ? buttonActive : buttonInactive}`}
          title={followPlayhead ? 'Stop following playhead' : 'Find and follow playhead'}
          aria-pressed={followPlayhead}
        >
          <Locate size={18} />
        </button>

        {/* Selection mode - supports long-press for manual input */}
        <button
          data-testid="selection-toggle"
          {...selectionHandlers}
          className={`${buttonBase} ${selectionModeActive ? buttonActive : buttonInactive}`}
          title={selectionModeActive ? 'Exit selection mode' : 'Selection mode (hold for manual input)'}
          aria-pressed={selectionModeActive}
        >
          <SquareDashedMousePointer size={18} />
        </button>
      </div>

      {/* Center: Marker navigation */}
      <div className="flex items-center">
        <button
          onClick={onPrevMarker}
          className={`${buttonWide} ${buttonInactive}`}
          title="Previous marker"
          aria-label="Previous marker"
        >
          <SkipBack size={18} />
        </button>
        <button
          onClick={onNextMarker}
          className={`${buttonWide} ${buttonInactive}`}
          title="Next marker"
          aria-label="Next marker"
        >
          <SkipForward size={18} />
        </button>
      </div>

      {/* Right: Zoom controls - flex-1 to balance */}
      <div className="flex-1 flex items-center justify-end">
        <ZoomControls
          visibleDuration={visibleDuration}
          onZoomIn={onZoomIn}
          onZoomOut={onZoomOut}
          onFitToContent={onFitToContent}
        />
      </div>
    </div>
  );
}
