/**
 * TimelinePlayhead Component
 * Renders the playhead line, grab handle, and drag previews
 *
 * Uses client-side interpolation for smooth 60fps playhead movement.
 * The playhead position is updated via refs and direct DOM manipulation
 * to avoid React re-render overhead.
 */

import { useRef, useLayoutEffect, useState, useEffect, type ReactElement } from 'react';
import type { Marker } from '../../core/types';
import type { TimelineMode } from '../../store';
import { transportEngine } from '../../core/TransportAnimationEngine';
import { formatBeats, formatTime, reaperColorToHex } from '../../utils';
import { useTransportAnimation } from '../../hooks';
import { useReaper } from '../ReaperProvider';
import { tempo as tempoCmd } from '../../core/WebSocketCommands';

export interface TimelinePlayheadProps {
  /** Current playhead position in seconds (used for initial render and when stopped) */
  positionSeconds: number;
  /** Current timeline mode */
  timelineMode: TimelineMode;
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
  /** Preview time in seconds (use this for display to avoid precision loss) */
  playheadPreviewTime: number | null;
  /** Whether playhead is being dragged */
  isDraggingPlayhead: boolean;
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
  /** Preview position in seconds (for server bar string lookup) */
  markerDragPreviewTime: number | null;
  /** BPM for beat display (fallback when server string unavailable) */
  bpm: number | null;
  /** Bar offset for beat formatting (fallback) */
  barOffset: number;
  /** Beats per bar from time signature (fallback) */
  beatsPerBar?: number;
  /** Time signature denominator (fallback) */
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
    // When bounds change (renderTimeToPercent recreated), recalculate position.
    // This fixes the race condition where animation callback fires before React
    // state updates, causing playhead to be positioned with stale bounds.
    if (containerRef.current) {
      const state = transportEngine.getState();
      const percent = renderTimeToPercent(state.position);
      containerRef.current.style.left = `${percent}%`;
    }
  }, [renderTimeToPercent]);

  // Subscribe to 60fps animation updates
  // Note: Uses style.left which triggers layout. Future optimization: migrate
  // Timeline to canvas for compositor-only 60fps rendering.
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
      data-playhead
      data-testid="playhead"
      className={`absolute top-0 bottom-0 ${isDraggingPlayhead ? 'opacity-50' : ''}`}
    >
      {/* Playhead line - above markers (z-10), below region labels (z-20) */}
      <div
        className={`absolute top-0 bottom-0 left-0 w-0.5 pointer-events-none z-10 ${
          timelineMode === 'regions' ? 'opacity-40' : ''
        }`}
        style={{ backgroundColor: timelineMode === 'regions' ? 'var(--color-text-muted)' : 'var(--color-playhead)' }}
      />

      {/* Grab handle - inverted triangle at top, above everything */}
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
        {/* Inverted triangle (pointing down) */}
        <div
          className="absolute top-0 left-1/2 -translate-x-1/2"
          style={{
            width: 0,
            height: 0,
            borderLeft: '12px solid transparent',
            borderRight: '12px solid transparent',
            borderTop: timelineMode === 'regions' ? '16px solid var(--color-text-muted)' : '16px solid var(--color-playhead)',
          }}
        />
      </div>
    </div>
  );
}

/**
 * Preview playhead shown during drag
 * Fetches tempo-aware bar string from server for accurate display
 */
export function PlayheadDragPreview({
  playheadPreviewPercent,
  isDraggingPlayhead,
}: Pick<PlayheadPreviewProps, 'playheadPreviewPercent' | 'isDraggingPlayhead'>): ReactElement | null {
  if (!isDraggingPlayhead || playheadPreviewPercent === null) return null;

  return (
    <div
      className="absolute top-0 bottom-0 pointer-events-none"
      style={{ left: `${playheadPreviewPercent}%` }}
    >
      {/* Preview line - same z as main playhead line */}
      <div className="absolute top-0 bottom-0 left-0 w-0.5 z-10 bg-playhead" />
      {/* Preview inverted triangle with highlight - above everything */}
      <div className="absolute top-0 -left-[11px] w-6 h-6 z-40">
        <div
          className="absolute top-0 left-1/2 -translate-x-1/2"
          style={{
            width: 0,
            height: 0,
            borderLeft: '12px solid transparent',
            borderRight: '12px solid transparent',
            borderTop: '16px solid var(--color-playhead)',
            filter: 'drop-shadow(0 0 4px oklch(from var(--color-playhead) l c h / 0.9))',
          }}
        />
      </div>
    </div>
  );
}

/**
 * Pill showing playhead preview position - rendered separately in header area
 */
export function PlayheadPreviewPill({
  playheadPreviewPercent,
  playheadPreviewTime,
  isDraggingPlayhead,
  bpm,
  barOffset,
  beatsPerBar = 4,
  denominator = 4,
}: PlayheadPreviewProps): ReactElement | null {
  const { sendCommandAsync } = useReaper();
  const [serverBars, setServerBars] = useState<string | null>(null);
  const lastRequestedTime = useRef<number | null>(null);

  // Fetch tempo-aware bar string from server when preview time changes
  useEffect(() => {
    if (playheadPreviewTime === null || !isDraggingPlayhead) {
      setServerBars(null);
      return;
    }

    // Debounce: don't re-request if time hasn't changed significantly (< 0.01s)
    if (lastRequestedTime.current !== null &&
        Math.abs(playheadPreviewTime - lastRequestedTime.current) < 0.01) {
      return;
    }
    lastRequestedTime.current = playheadPreviewTime;

    // Request tempo-aware bar string from server
    sendCommandAsync(tempoCmd.timeToBeats(playheadPreviewTime))
      .then((response) => {
        const resp = response as { payload?: { bars?: string } } | undefined;
        if (resp?.payload?.bars) {
          setServerBars(resp.payload.bars);
        }
      })
      .catch(() => {
        // Ignore errors, fall back to local calculation
      });
  }, [playheadPreviewTime, isDraggingPlayhead, sendCommandAsync]);

  // Reset server bars when drag ends
  useEffect(() => {
    if (!isDraggingPlayhead) {
      setServerBars(null);
      lastRequestedTime.current = null;
    }
  }, [isDraggingPlayhead]);

  if (!isDraggingPlayhead || playheadPreviewPercent === null || playheadPreviewTime === null) return null;

  const timeStr = formatTime(playheadPreviewTime, { precision: 2 });
  const beatsStr = serverBars ?? (bpm ? formatBeats(playheadPreviewTime, bpm, barOffset, beatsPerBar, denominator) : '');

  return (
    <div
      className="absolute top-1/2 -translate-y-1/2 -translate-x-1/2 z-40 pointer-events-none"
      style={{ left: `${playheadPreviewPercent}%` }}
    >
      <div className="bg-bg-deep border border-playhead rounded px-2 py-1 text-xs text-text-primary font-mono whitespace-nowrap shadow-lg">
        {beatsStr ? `${beatsStr} | ${timeStr}` : timeStr}
      </div>
    </div>
  );
}

/**
 * Preview marker shown during marker drag
 * Fetches tempo-aware bar string from server for accurate display
 */
export function MarkerDragPreview({
  draggedMarker,
  isDraggingMarker,
  markerDragPreviewPercent,
  markerDragPreviewTime,
  bpm,
  barOffset,
  beatsPerBar = 4,
  denominator = 4,
}: MarkerDragPreviewProps): ReactElement | null {
  const { sendCommandAsync } = useReaper();
  const [serverBars, setServerBars] = useState<string | null>(null);
  const lastRequestedTime = useRef<number | null>(null);

  // Fetch tempo-aware bar string from server when preview time changes
  useEffect(() => {
    if (markerDragPreviewTime === null || !isDraggingMarker) {
      setServerBars(null);
      return;
    }

    // Debounce: don't re-request if time hasn't changed significantly (< 0.01s)
    if (lastRequestedTime.current !== null &&
        Math.abs(markerDragPreviewTime - lastRequestedTime.current) < 0.01) {
      return;
    }
    lastRequestedTime.current = markerDragPreviewTime;

    // Request tempo-aware bar string from server
    sendCommandAsync(tempoCmd.timeToBeats(markerDragPreviewTime))
      .then((response) => {
        // sendAsync resolves with full ResponseMessage, payload contains the bars
        const resp = response as { payload?: { bars?: string } } | undefined;
        if (resp?.payload?.bars) {
          setServerBars(resp.payload.bars);
        }
      })
      .catch(() => {
        // Ignore errors, fall back to local calculation
      });
  }, [markerDragPreviewTime, isDraggingMarker, sendCommandAsync]);

  // Reset server bars when drag ends
  useEffect(() => {
    if (!isDraggingMarker) {
      setServerBars(null);
      lastRequestedTime.current = null;
    }
  }, [isDraggingMarker]);

  if (!isDraggingMarker || !draggedMarker || markerDragPreviewPercent === null || markerDragPreviewTime === null) {
    return null;
  }

  const timeStr = formatTime(markerDragPreviewTime, { precision: 3 });
  // Use server bar string if available, or marker's original positionBars if at original position
  // Fall back to local calculation only as last resort
  const isAtOriginalPosition = Math.abs(markerDragPreviewTime - draggedMarker.position) < 0.01;
  const beatsStr = serverBars
    ?? (isAtOriginalPosition ? draggedMarker.positionBars : null)
    ?? (bpm ? formatBeats(markerDragPreviewTime, bpm, barOffset, beatsPerBar, denominator) : '');

  // Use marker's custom color or default (from CSS token)
  const markerColor = draggedMarker.color ? reaperColorToHex(draggedMarker.color) ?? 'var(--color-marker-default)' : 'var(--color-marker-default)';

  return (
    <div
      className="absolute top-0 bottom-0 pointer-events-none"
      style={{ left: `${markerDragPreviewPercent}%` }}
    >
      {/* Preview line */}
      <div className="absolute top-0 bottom-0 left-0 w-0.5 z-10" style={{ backgroundColor: markerColor }} />
      {/* Position pill showing time and beats */}
      <div className="absolute top-1/2 -translate-y-1/2 -translate-x-1/2 z-40">
        <div className="bg-bg-deep rounded px-2 py-1 text-xs text-text-primary font-mono whitespace-nowrap shadow-lg" style={{ borderColor: markerColor, borderWidth: 1 }}>
          {beatsStr ? `${beatsStr} | ${timeStr}` : timeStr}
        </div>
      </div>
    </div>
  );
}
