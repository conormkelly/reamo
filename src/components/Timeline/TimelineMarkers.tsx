/**
 * TimelineMarkers Component
 * Renders marker lines and pills in the timeline
 */

import type { ReactElement } from 'react';
import type { Marker } from '../../core/types';
import { isMarkerMoveable } from './MarkerEditModal';

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
 * Marker lines in the main timeline area
 */
export function TimelineMarkerLines({
  markers,
  timelineMode,
  renderTimeToPercent,
}: TimelineMarkersProps): ReactElement {
  return (
    <>
      {markers.map((marker) => (
        <div
          key={`marker-${marker.id}`}
          className={`absolute top-0 bottom-0 w-0.5 ${
            timelineMode === 'regions' ? 'bg-gray-600 opacity-40' : 'bg-red-500'
          }`}
          style={{ left: `${renderTimeToPercent(marker.position)}%` }}
        />
      ))}
    </>
  );
}

/**
 * Marker pills in the bottom bar (interactive)
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
        return (
          <div
            key={`marker-pill-${marker.id}`}
            className={`absolute top-1/2 -translate-y-1/2 -translate-x-1/2 min-w-4 h-4 px-1 rounded-full flex items-center justify-center touch-none select-none transition-opacity ${
              timelineMode === 'regions'
                ? 'bg-gray-600 pointer-events-none opacity-40'
                : canMove
                  ? 'bg-red-600 cursor-grab active:cursor-grabbing'
                  : 'bg-gray-500 cursor-not-allowed'
            } ${isBeingDragged && isDraggingMarker ? 'opacity-50' : ''}`}
            style={{ left: `calc(${renderTimeToPercent(marker.position)}% + 1px)` }}
            onPointerDown={timelineMode === 'regions' ? undefined : (e) => handleMarkerPointerDown(e, marker)}
            onPointerMove={timelineMode === 'regions' ? undefined : handleMarkerPointerMove}
            onPointerUp={timelineMode === 'regions' ? undefined : handleMarkerPointerUp}
            onPointerCancel={timelineMode === 'regions' ? undefined : handleMarkerPointerUp}
          >
            <span className={`text-[10px] font-bold leading-none ${
              timelineMode === 'regions' ? 'text-gray-400' : 'text-white'
            }`}>{marker.id}</span>
          </div>
        );
      })}
    </>
  );
}
