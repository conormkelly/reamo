/**
 * TimelinePlayhead Component
 * Renders the playhead line, grab handle, and drag previews
 */

import type { ReactElement } from 'react';
import type { Marker } from '../../core/types';
import { formatBeats } from '../../utils';

export interface TimelinePlayheadProps {
  /** Current playhead position in seconds */
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
 */
export function TimelinePlayhead({
  positionSeconds,
  timelineMode,
  isSyncing,
  isDraggingPlayhead,
  renderTimeToPercent,
  handlePlayheadPointerDown,
  handlePlayheadPointerMove,
  handlePlayheadPointerUp,
}: TimelinePlayheadProps): ReactElement | null {
  if (isSyncing) return null;

  return (
    <div
      className={`absolute top-0 bottom-0 ${isDraggingPlayhead ? 'opacity-50' : ''}`}
      style={{ left: `${renderTimeToPercent(positionSeconds)}%` }}
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
  const mins = Math.floor(seconds / 60);
  const secs = (seconds % 60).toFixed(1);
  const timeStr = `${mins}:${secs.padStart(4, '0')}`;
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
  const mins = Math.floor(seconds / 60);
  const secs = (seconds % 60).toFixed(1);
  const timeStr = `${mins}:${secs.padStart(4, '0')}`;
  const beatsStr = bpm ? formatBeats(seconds, bpm, barOffset, beatsPerBar, denominator) : '';

  return (
    <div
      className="absolute top-0 bottom-0 pointer-events-none"
      style={{ left: `${markerDragPreviewPercent}%` }}
    >
      {/* Preview line */}
      <div className="absolute top-0 bottom-0 left-0 w-0.5 bg-red-400 z-10" />
      {/* Position pill showing time and beats */}
      <div className="absolute top-1/2 -translate-y-1/2 -translate-x-1/2 z-40">
        <div className="bg-gray-900 border border-red-400 rounded px-2 py-1 text-xs text-white font-mono whitespace-nowrap shadow-lg">
          {beatsStr ? `${timeStr} | ${beatsStr}` : timeStr}
        </div>
      </div>
    </div>
  );
}
