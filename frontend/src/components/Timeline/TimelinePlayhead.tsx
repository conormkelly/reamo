/**
 * TimelinePlayhead Component
 * Renders the playhead line, grab handle, and drag previews
 *
 * Uses client-side interpolation for smooth 60fps playhead movement.
 * The playhead position is updated via refs and direct DOM manipulation
 * to avoid React re-render overhead.
 */

import { useRef, useLayoutEffect, type ReactElement } from 'react';
import type { Marker } from '../../core/types';
import { formatBeats, formatTime, reaperColorToHex } from '../../utils';
import { useTransportAnimation } from '../../hooks';

export interface TimelinePlayheadProps {
  /** Current playhead position in seconds (used for initial render and when stopped) */
  positionSeconds: number;
  /** Current timeline mode */
  timelineMode: 'navigate' | 'regions';
  /** Whether syncing is in progress */
  isSyncing: boolean;
  /** Whether playhead is being dragged */
  isDraggingPlayhead: boolean;
  /** Convert time to percentage position */
  renderTimeToPercent: (time: number) => number;
  /** Pointer down handler */
  handlePlayheadPointerDown: (e: React.PointerEvent) => void;
  /** Pointer move handler */
  handlePlayheadPointerMove: (e: React.PointerEvent) => void;
  /** Pointer up handler */
  handlePlayheadPointerUp: (e: React.PointerEvent) => void;
}

export interface PlayheadPreviewProps {
  /** Preview position as percentage */
  playheadPreviewPercent: number | null;
  /** Whether playhead is being dragged */
  isDraggingPlayhead: boolean;
  /** Timeline start in seconds */
  timelineStart: number;
  /** Timeline duration in seconds */
  duration: number;
  /** BPM for beat display */
  bpm: number | null;
  /** Bar offset for beat formatting */
  barOffset: number;
  /** Beats per bar from time signature */
  beatsPerBar?: number;
  /** Time signature denominator */
  denominator?: number;
}

export interface MarkerDragPreviewProps {
  /** Marker being dragged */
  draggedMarker: Marker | null;
  /** Whether a marker is being dragged */
  isDraggingMarker: boolean;
  /** Preview position as percentage */
  markerDragPreviewPercent: number | null;
  /** Timeline start in seconds */
  timelineStart: number;
  /** Timeline duration in seconds */
  duration: number;
  /** BPM for beat display */
  bpm: number | null;
  /** Bar offset for beat formatting */
  barOffset: number;
  /** Beats per bar from time signature */
  beatsPerBar?: number;
  /** Time signature denominator */
  denominator?: number;
}

/**
 * Main playhead line and grab handle
 * Uses client-side interpolation for smooth 60fps updates
 */
export function TimelinePlayhead({
  positionSeconds: _positionSeconds,
  timelineMode,
  isSyncing,
  isDraggingPlayhead,
  renderTimeToPercent,
  handlePlayheadPointerDown,
  handlePlayheadPointerMove,
  handlePlayheadPointerUp,
}: TimelinePlayheadProps): ReactElement | null {
  const containerRef = useRef<HTMLDivElement>(null);

  // Keep renderTimeToPercent in a ref so animation callback has current value
  const renderTimeToPercentRef = useRef(renderTimeToPercent);
  useLayoutEffect(() => {
    renderTimeToPercentRef.current = renderTimeToPercent;
  }, [renderTimeToPercent]);

  // Subscribe to 60fps animation updates
  // This is the ONLY place we set left position - not in JSX style prop
  // to avoid React and animation callback fighting each other
  useTransportAnimation((state) => {
    if (containerRef.current) {
      const percent = renderTimeToPercentRef.current(state.position);
      containerRef.current.style.left = `${percent}%`;
    }
  }, []);

  if (isSyncing) return null;

  return (
    <div
      ref={containerRef}
      className={`absolute top-0 bottom-0 ${isDraggingPlayhead ? 'opacity-50' : ''}`}
    >
      {/* Playhead line - above markers (z-10), below region labels (z-20) */}
      <div className={`absolute top-0 bottom-0 left-0 w-0.5 pointer-events-none z-10 ${
        timelineMode === 'regions' ? 'bg-gray-500 opacity-40' : 'bg-white'
      }`} />

      {/* Grab handle - T-shape at top, above everything */}
      <div
        className={`absolute -top-0.5 -left-[11px] w-6 h-6 z-30 ${
          timelineMode === 'regions'
            ? 'pointer-events-none opacity-40'
            : 'cursor-grab active:cursor-grabbing'
        }`}
        style={{ touchAction: 'none' }}
        onPointerDown={timelineMode === 'regions' ? undefined : handlePlayheadPointerDown}
        onPointerMove={timelineMode === 'regions' ? undefined : handlePlayheadPointerMove}
        onPointerUp={timelineMode === 'regions' ? undefined : handlePlayheadPointerUp}
        onPointerCancel={timelineMode === 'regions' ? undefined : handlePlayheadPointerUp}
      >
        {/* Visible T-bar */}
        <div className={`absolute top-0.5 left-1/2 -translate-x-1/2 w-4 h-1.5 rounded-sm shadow-md ${
          timelineMode === 'regions' ? 'bg-gray-500' : 'bg-white'
        }`} />
      </div>
    </div>
  );
}

/**
 * Preview playhead shown during drag
 */
export function PlayheadDragPreview({
  playheadPreviewPercent,
  isDraggingPlayhead,
  timelineStart,
  duration,
  bpm,
  barOffset,
  beatsPerBar = 4,
  denominator = 4,
}: PlayheadPreviewProps): ReactElement | null {
  if (!isDraggingPlayhead || playheadPreviewPercent === null) return null;

  const seconds = timelineStart + (playheadPreviewPercent / 100) * duration;
  const timeStr = formatTime(seconds, { precision: 1 });
  const beatsStr = bpm ? formatBeats(seconds, bpm, barOffset, beatsPerBar, denominator) : '';

  return (
    <div
      className="absolute top-0 bottom-0 pointer-events-none"
      style={{ left: `${playheadPreviewPercent}%` }}
    >
      {/* Preview line - same z as main playhead line */}
      <div className="absolute top-0 bottom-0 left-0 w-0.5 bg-white z-10" />
      {/* Preview T-bar with highlight - above everything */}
      <div className="absolute top-0 -left-[11px] w-6 h-6 z-40">
        <div className="absolute top-0.5 left-1/2 -translate-x-1/2 w-4 h-1.5 bg-white rounded-sm shadow-lg ring-2 ring-blue-400" />
      </div>
      {/* Position pill showing time and beats - at bottom so finger doesn't obscure */}
      <div className="absolute bottom-1 -translate-x-1/2 z-40">
        <div className="bg-gray-900 border border-blue-400 rounded px-2 py-1 text-xs text-white font-mono whitespace-nowrap shadow-lg">
          {beatsStr ? `${timeStr} | ${beatsStr}` : timeStr}
        </div>
      </div>
    </div>
  );
}

/**
 * Preview marker shown during marker drag
 */
export function MarkerDragPreview({
  draggedMarker,
  isDraggingMarker,
  markerDragPreviewPercent,
  timelineStart,
  duration,
  bpm,
  barOffset,
  beatsPerBar = 4,
  denominator = 4,
}: MarkerDragPreviewProps): ReactElement | null {
  if (!isDraggingMarker || !draggedMarker || markerDragPreviewPercent === null) return null;

  const seconds = timelineStart + (markerDragPreviewPercent / 100) * duration;
  const timeStr = formatTime(seconds, { precision: 1 });
  const beatsStr = bpm ? formatBeats(seconds, bpm, barOffset, beatsPerBar, denominator) : '';

  // Use marker's custom color or default red
  const markerColor = draggedMarker.color ? reaperColorToHex(draggedMarker.color) ?? '#dc2626' : '#dc2626';

  return (
    <div
      className="absolute top-0 bottom-0 pointer-events-none"
      style={{ left: `${markerDragPreviewPercent}%` }}
    >
      {/* Preview line */}
      <div className="absolute top-0 bottom-0 left-0 w-0.5 z-10" style={{ backgroundColor: markerColor }} />
      {/* Position pill showing time and beats */}
      <div className="absolute top-1/2 -translate-y-1/2 -translate-x-1/2 z-40">
        <div className="bg-gray-900 rounded px-2 py-1 text-xs text-white font-mono whitespace-nowrap shadow-lg" style={{ borderColor: markerColor, borderWidth: 1 }}>
          {beatsStr ? `${timeStr} | ${beatsStr}` : timeStr}
        </div>
      </div>
    </div>
  );
}
