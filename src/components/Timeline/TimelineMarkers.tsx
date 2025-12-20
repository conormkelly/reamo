/**
 * TimelineMarkers Component
 * Renders marker lines and pills in the timeline
 */

import type { ReactElement } from 'react';
import type { Marker } from '../../core/types';
import { isMarkerMoveable } from './MarkerEditModal';
import { reaperColorToHex } from '../../utils';

export interface TimelineMarkersProps {
  /** Markers to display */
  markers: Marker[];
  /** Current timeline mode */
  timelineMode: 'navigate' | 'regions';
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
 * - Falls back to red (#dc2626) for markers without custom color
 * - Gray (#6b7280) for non-moveable markers (11+) or in regions mode
 */
function getMarkerColor(marker: Marker, timelineMode: 'navigate' | 'regions'): string {
  const isMoveable = isMarkerMoveable(marker.id);

  // In regions mode or non-moveable markers: gray
  if (timelineMode === 'regions' || !isMoveable) {
    return '#6b7280'; // gray-500
  }

  // Use marker's custom color or default red
  const customColor = marker.color ? reaperColorToHex(marker.color) : null;
  return customColor || '#dc2626'; // red-600
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
 * - Dark gray interior (bg-gray-800)
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
        const canMove = isMarkerMoveable(marker.id) && timelineMode !== 'regions';
        const isBeingDragged = draggedMarker?.id === marker.id;
        const outlineColor = getMarkerColor(marker, timelineMode);
        const isDisabled = timelineMode === 'regions';

        return (
          <div
            key={`marker-pill-${marker.id}`}
            className={`absolute top-1/2 -translate-y-1/2 -translate-x-1/2 min-w-5 h-5 px-1.5 rounded-full flex items-center justify-center touch-none select-none transition-opacity bg-gray-800 ${
              isDisabled
                ? 'pointer-events-none opacity-40'
                : canMove
                  ? 'cursor-grab active:cursor-grabbing'
                  : 'cursor-not-allowed'
            } ${isBeingDragged && isDraggingMarker ? 'opacity-50' : ''}`}
            style={{
              left: `calc(${renderTimeToPercent(marker.position)}% + 1px)`,
              // 2px colored outline + 1px dark stroke outside for contrast
              border: `2px solid ${outlineColor}`,
              boxShadow: '0 0 0 1px rgba(0,0,0,0.5)',
            }}
            onPointerDown={isDisabled ? undefined : (e) => handleMarkerPointerDown(e, marker)}
            onPointerMove={isDisabled ? undefined : handleMarkerPointerMove}
            onPointerUp={isDisabled ? undefined : handleMarkerPointerUp}
            onPointerCancel={isDisabled ? undefined : handleMarkerPointerUp}
          >
            <span className="text-[10px] font-bold leading-none text-white">
              {marker.id}
            </span>
          </div>
        );
      })}
    </>
  );
}
