/**
 * Timeline Footer Controls
 * Provides marker navigation, mode toggles, and zoom controls
 * Layout: [⏮⏭] | [📍⬚] | [−][30s][+][⬛]
 */

import { useRef, useCallback, useEffect, type ReactElement } from 'react';
import { SquareDashedMousePointer, Locate, SkipBack, SkipForward } from 'lucide-react';
import { ZoomControls } from './ZoomControls';

export interface TimelineFooterProps {
  // Marker navigation
  onPrevMarker: () => void;
  onNextMarker: () => void;

  // Mode toggles
  followPlayhead: boolean;
  onFollowPlayheadToggle: () => void;
  selectionModeActive: boolean;
  onSelectionModeToggle: () => void;
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
  // Long-press handling for selection button
  const longPressTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const wasLongPressRef = useRef(false);

  const handleSelectionPointerDown = useCallback(() => {
    wasLongPressRef.current = false;
    longPressTimerRef.current = setTimeout(() => {
      wasLongPressRef.current = true;
      onSelectionLongPress?.();
    }, LONG_PRESS_DURATION);
  }, [onSelectionLongPress]);

  const handleSelectionPointerUp = useCallback(() => {
    if (longPressTimerRef.current) {
      clearTimeout(longPressTimerRef.current);
      longPressTimerRef.current = null;
    }
    // Only toggle if it wasn't a long press
    if (!wasLongPressRef.current) {
      onSelectionModeToggle();
    }
  }, [onSelectionModeToggle]);

  const handleSelectionPointerCancel = useCallback(() => {
    if (longPressTimerRef.current) {
      clearTimeout(longPressTimerRef.current);
      longPressTimerRef.current = null;
    }
  }, []);

  // Cleanup timer on unmount
  useEffect(() => {
    return () => {
      if (longPressTimerRef.current) {
        clearTimeout(longPressTimerRef.current);
      }
    };
  }, []);

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
          onPointerDown={handleSelectionPointerDown}
          onPointerUp={handleSelectionPointerUp}
          onPointerCancel={handleSelectionPointerCancel}
          onPointerLeave={handleSelectionPointerCancel}
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
