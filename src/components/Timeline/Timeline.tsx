/**
 * Timeline Component
 * Visual timeline showing regions and markers for navigation and selection
 */

import { useState, useRef, useCallback, useMemo, type ReactElement } from 'react';
import { useReaperStore } from '../../store';
import { useReaper } from '../ReaperProvider';
import { useTransport } from '../../hooks/useTransport';
import * as commands from '../../core/CommandBuilder';
import type { Region, Marker } from '../../core/types';
import { MarkerEditModal, isMarkerMoveable, getMarkerMoveAction } from './MarkerEditModal';

export interface TimelineProps {
  className?: string;
  /** Minimum height in pixels */
  height?: number;
}

// Hold duration threshold in ms
const HOLD_THRESHOLD = 300;
// Long-press threshold for marker edit modal
const MARKER_HOLD_THRESHOLD = 500;
// Vertical distance to cancel playhead drag (pixels)
const VERTICAL_CANCEL_THRESHOLD = 50;

/**
 * Convert REAPER color (0xaarrggbb) to CSS color
 */
function reaperColorToCSS(color: number | undefined, fallback: string): string {
  if (!color || color === 0) return fallback;
  const r = (color >> 16) & 0xff;
  const g = (color >> 8) & 0xff;
  const b = color & 0xff;
  return `rgb(${r}, ${g}, ${b})`;
}

/**
 * Timeline component showing regions and markers
 */
/**
 * Convert seconds to beats
 */
function secondsToBeats(seconds: number, bpm: number): number {
  return seconds * (bpm / 60);
}

/**
 * Convert beats to seconds
 */
function beatsToSeconds(beats: number, bpm: number): number {
  return beats * (60 / bpm);
}

/**
 * Snap seconds to nearest subbeat grid
 * @param seconds Time in seconds
 * @param bpm Beats per minute
 * @param subdivisions Subdivisions per beat (4 = 16th notes, 2 = 8th notes)
 */
function snapToGrid(seconds: number, bpm: number, subdivisions: number = 4): number {
  const beatsPerSecond = bpm / 60;
  const subbeatsPerSecond = beatsPerSecond * subdivisions;
  const subbeat = Math.round(seconds * subbeatsPerSecond);
  return subbeat / subbeatsPerSecond;
}

/**
 * Parse REAPER's bar.beat string to get the bar number
 * Format: "bar.beat.ticks" like "-4.1.00" or "56.2.45"
 */
function parseReaperBar(positionBeats: string): number {
  const parts = positionBeats.split('.');
  return parseInt(parts[0], 10);
}

/**
 * Format beats as Bar.Beat.Subdivision with correct REAPER bar offset
 */
function formatBeatsWithOffset(
  seconds: number,
  bpm: number,
  barOffset: number,
  beatsPerBar: number = 4
): string {
  const totalBeats = secondsToBeats(seconds, bpm);
  const calculatedBar = Math.floor(totalBeats / beatsPerBar) + 1;
  const actualBar = calculatedBar + barOffset;
  const beat = Math.floor(totalBeats % beatsPerBar) + 1;
  const sub = Math.round((totalBeats % 1) * 4) + 1; // 16th note subdivision
  return `${actualBar}.${beat}.${sub}`;
}

export function Timeline({ className = '', height = 120 }: TimelineProps): ReactElement {
  const { send } = useReaper();
  const { positionSeconds, seekTo } = useTransport();
  const regions = useReaperStore((state) => state.regions);
  const markers = useReaperStore((state) => state.markers);
  const bpm = useReaperStore((state) => state.bpm);
  const positionBeats = useReaperStore((state) => state.positionBeats);
  const storedTimeSelection = useReaperStore((state) => state.timeSelection);
  const setStoredTimeSelection = useReaperStore((state) => state.setTimeSelection);

  // Calculate bar offset from REAPER's actual bar numbering
  // This handles projects that don't start at bar 1 (e.g., -4.1.00)
  const barOffset = useMemo(() => {
    if (!bpm || !positionBeats || positionSeconds <= 0) return 0;
    const actualBar = parseReaperBar(positionBeats);
    const totalBeats = secondsToBeats(positionSeconds, bpm);
    const calculatedBar = Math.floor(totalBeats / 4) + 1; // Assuming 4/4
    return actualBar - calculatedBar;
  }, [bpm, positionBeats, positionSeconds]);

  // Convert stored beat-based selection to seconds for display
  // Filter out invalid 0-width selections
  const timeSelectionSeconds = useMemo(() => {
    if (!storedTimeSelection || !bpm) return null;
    const start = beatsToSeconds(storedTimeSelection.startBeats, bpm);
    const end = beatsToSeconds(storedTimeSelection.endBeats, bpm);
    // Don't show selections with negligible width (less than 0.01 seconds)
    if (Math.abs(end - start) < 0.01) return null;
    return { start, end };
  }, [storedTimeSelection, bpm]);

  // Gesture state
  const [isHolding, setIsHolding] = useState(false);
  const [dragStart, setDragStart] = useState<number | null>(null);
  const [dragEnd, setDragEnd] = useState<number | null>(null);
  const holdTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const containerRef = useRef<HTMLDivElement>(null);

  // Playhead drag state
  const [isDraggingPlayhead, setIsDraggingPlayhead] = useState(false);
  const [playheadDragStartY, setPlayheadDragStartY] = useState<number | null>(null);
  const [playheadPreviewPercent, setPlayheadPreviewPercent] = useState<number | null>(null);

  // Marker drag state
  const [isDraggingMarker, setIsDraggingMarker] = useState(false);
  const [draggedMarker, setDraggedMarker] = useState<Marker | null>(null);
  const [markerDragStartY, setMarkerDragStartY] = useState<number | null>(null);
  const [markerDragPreviewPercent, setMarkerDragPreviewPercent] = useState<number | null>(null);
  const markerHoldTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Marker edit modal state
  const [editingMarker, setEditingMarker] = useState<Marker | null>(null);

  // Calculate timeline bounds
  const { timelineStart, duration } = useMemo(() => {
    const start = 0;
    let end = 0;

    for (const region of regions) {
      if (region.end > end) end = region.end;
    }
    for (const marker of markers) {
      if (marker.position > end) end = marker.position;
    }

    // Add some padding at the end
    end = Math.max(end * 1.05, 10);

    return { timelineStart: start, duration: end - start };
  }, [regions, markers]);

  // Convert time to percentage position
  const timeToPercent = useCallback(
    (time: number) => {
      if (duration === 0) return 0;
      return ((time - timelineStart) / duration) * 100;
    },
    [timelineStart, duration]
  );

  // Convert x position to time
  const positionToTime = useCallback(
    (clientX: number) => {
      if (!containerRef.current) return 0;
      const rect = containerRef.current.getBoundingClientRect();
      const percent = (clientX - rect.left) / rect.width;
      return timelineStart + percent * duration;
    },
    [timelineStart, duration]
  );

  // Set time selection in REAPER (5 commands: move to start, set start, move to end, set end, return to start)
  const setTimeSelection = useCallback(
    (startSeconds: number, endSeconds: number) => {
      const cmds = commands.join(
        commands.setPosition(startSeconds),
        commands.action(40625), // Set time selection start
        commands.setPosition(endSeconds),
        commands.action(40626), // Set time selection end
        commands.setPosition(startSeconds) // Return cursor to start
      );
      send(cmds);
      // Store locally in beats (so it stays aligned when tempo changes)
      if (bpm) {
        setStoredTimeSelection({
          startBeats: secondsToBeats(startSeconds, bpm),
          endBeats: secondsToBeats(endSeconds, bpm),
        });
      }
    },
    [send, setStoredTimeSelection, bpm]
  );

  // Navigate to position
  const navigateTo = useCallback(
    (time: number) => {
      send(seekTo(time));
    },
    [send, seekTo]
  );

  // Find region at time
  const findRegionAt = useCallback(
    (time: number): Region | null => {
      for (const region of regions) {
        if (time >= region.start && time < region.end) {
          return region;
        }
      }
      return null;
    },
    [regions]
  );

  // Find nearest boundary (region edge or marker) to a time
  const findNearestBoundary = useCallback(
    (time: number): number => {
      let nearest = time;
      let minDist = Infinity;

      // Check region boundaries
      for (const region of regions) {
        const startDist = Math.abs(region.start - time);
        const endDist = Math.abs(region.end - time);
        if (startDist < minDist) {
          minDist = startDist;
          nearest = region.start;
        }
        if (endDist < minDist) {
          minDist = endDist;
          nearest = region.end;
        }
      }

      // Check markers
      for (const marker of markers) {
        const dist = Math.abs(marker.position - time);
        if (dist < minDist) {
          minDist = dist;
          nearest = marker.position;
        }
      }

      return nearest;
    },
    [regions, markers]
  );

  // Handle touch/mouse start
  const handlePointerDown = useCallback(
    (e: React.PointerEvent) => {
      // Don't start timeline selection if dragging playhead
      if (isDraggingPlayhead) return;

      const time = positionToTime(e.clientX);
      setDragStart(time);
      setDragEnd(time);
      setIsHolding(false);

      // Start hold timer
      holdTimerRef.current = setTimeout(() => {
        setIsHolding(true);
      }, HOLD_THRESHOLD);

      // Capture pointer for drag events
      (e.target as HTMLElement).setPointerCapture(e.pointerId);
    },
    [positionToTime, isDraggingPlayhead]
  );

  // Handle touch/mouse move
  const handlePointerMove = useCallback(
    (e: React.PointerEvent) => {
      if (dragStart === null) return;

      const time = positionToTime(e.clientX);
      setDragEnd(time);

      // If moved significantly, we're definitely dragging
      if (Math.abs(time - dragStart) > 0.1) {
        // Clear hold timer - we're dragging
        if (holdTimerRef.current) {
          clearTimeout(holdTimerRef.current);
          holdTimerRef.current = null;
        }
        setIsHolding(true); // Treat drag as selection mode
      }
    },
    [dragStart, positionToTime]
  );

  // Handle touch/mouse end
  const handlePointerUp = useCallback(
    (e: React.PointerEvent) => {
      // Clear hold timer
      if (holdTimerRef.current) {
        clearTimeout(holdTimerRef.current);
        holdTimerRef.current = null;
      }

      if (dragStart === null) return;

      const endTime = positionToTime(e.clientX);
      const wasDragging = Math.abs(endTime - dragStart) > 0.1;

      if (isHolding || wasDragging) {
        // Selection mode: set time selection
        let selStart = Math.min(dragStart, endTime);
        let selEnd = Math.max(dragStart, endTime);

        // Snap to boundaries
        selStart = findNearestBoundary(selStart);
        selEnd = findNearestBoundary(selEnd);

        // If just a hold (no drag), select the region under the pointer
        if (!wasDragging) {
          const region = findRegionAt(dragStart);
          if (region) {
            selStart = region.start;
            selEnd = region.end;
          }
        }

        setTimeSelection(selStart, selEnd);
      } else {
        // Tap: navigate to position
        const region = findRegionAt(dragStart);
        if (region) {
          navigateTo(region.start);
        } else {
          navigateTo(findNearestBoundary(dragStart));
        }
      }

      // Reset state
      setDragStart(null);
      setDragEnd(null);
      setIsHolding(false);

      // Release pointer capture
      (e.target as HTMLElement).releasePointerCapture(e.pointerId);
    },
    [
      dragStart,
      isHolding,
      positionToTime,
      findNearestBoundary,
      findRegionAt,
      setTimeSelection,
      navigateTo,
    ]
  );

  // Playhead position
  const playheadPercent = timeToPercent(positionSeconds);

  // Playhead drag handlers
  const handlePlayheadPointerDown = useCallback(
    (e: React.PointerEvent) => {
      e.stopPropagation();
      (e.target as HTMLElement).setPointerCapture(e.pointerId);

      setIsDraggingPlayhead(true);
      setPlayheadDragStartY(e.clientY);
      setPlayheadPreviewPercent(playheadPercent);
    },
    [playheadPercent]
  );

  const handlePlayheadPointerMove = useCallback(
    (e: React.PointerEvent) => {
      if (!isDraggingPlayhead || !containerRef.current) return;

      const rect = containerRef.current.getBoundingClientRect();
      const deltaY =
        playheadDragStartY !== null ? Math.abs(e.clientY - playheadDragStartY) : 0;
      const isOutsideVertically =
        e.clientY < rect.top - VERTICAL_CANCEL_THRESHOLD ||
        e.clientY > rect.bottom + VERTICAL_CANCEL_THRESHOLD;

      if (isOutsideVertically || deltaY > VERTICAL_CANCEL_THRESHOLD) {
        // Show cancel state - preview snaps back to current playhead
        setPlayheadPreviewPercent(playheadPercent);
        return;
      }

      // Update preview position
      const percent = ((e.clientX - rect.left) / rect.width) * 100;
      setPlayheadPreviewPercent(Math.max(0, Math.min(100, percent)));
    },
    [isDraggingPlayhead, playheadDragStartY, playheadPercent]
  );

  const handlePlayheadPointerUp = useCallback(
    (e: React.PointerEvent) => {
      if (!isDraggingPlayhead || !containerRef.current) return;

      (e.target as HTMLElement).releasePointerCapture(e.pointerId);

      const rect = containerRef.current.getBoundingClientRect();
      const deltaY =
        playheadDragStartY !== null ? Math.abs(e.clientY - playheadDragStartY) : 0;
      const isOutsideVertically =
        e.clientY < rect.top - VERTICAL_CANCEL_THRESHOLD ||
        e.clientY > rect.bottom + VERTICAL_CANCEL_THRESHOLD;

      // Only commit if not cancelled
      if (
        !isOutsideVertically &&
        deltaY <= VERTICAL_CANCEL_THRESHOLD &&
        playheadPreviewPercent !== null
      ) {
        const newTime = timelineStart + (playheadPreviewPercent / 100) * duration;
        send(seekTo(newTime));
      }

      // Reset state
      setIsDraggingPlayhead(false);
      setPlayheadDragStartY(null);
      setPlayheadPreviewPercent(null);
    },
    [
      isDraggingPlayhead,
      playheadDragStartY,
      playheadPreviewPercent,
      timelineStart,
      duration,
      send,
      seekTo,
    ]
  );

  // Marker drag handlers
  const handleMarkerPointerDown = useCallback(
    (e: React.PointerEvent, marker: Marker) => {
      e.stopPropagation();
      (e.target as HTMLElement).setPointerCapture(e.pointerId);

      const canMove = isMarkerMoveable(marker.id);

      setDraggedMarker(marker);
      setMarkerDragStartY(e.clientY);

      if (canMove) {
        setMarkerDragPreviewPercent(timeToPercent(marker.position));
      }

      // Start long-press timer for edit modal
      markerHoldTimerRef.current = setTimeout(() => {
        // Long press detected - open edit modal
        setEditingMarker(marker);
        // Cancel any drag
        setIsDraggingMarker(false);
        setDraggedMarker(null);
        setMarkerDragStartY(null);
        setMarkerDragPreviewPercent(null);
      }, MARKER_HOLD_THRESHOLD);
    },
    [timeToPercent]
  );

  const handleMarkerPointerMove = useCallback(
    (e: React.PointerEvent) => {
      if (!draggedMarker || !containerRef.current) return;

      const canMove = isMarkerMoveable(draggedMarker.id);

      // If moved significantly, we're dragging (cancel long-press timer)
      const movedSignificantly = Math.abs(e.clientX - (containerRef.current.getBoundingClientRect().left + (timeToPercent(draggedMarker.position) / 100) * containerRef.current.getBoundingClientRect().width)) > 5;

      if (movedSignificantly && markerHoldTimerRef.current) {
        clearTimeout(markerHoldTimerRef.current);
        markerHoldTimerRef.current = null;
        if (canMove) {
          setIsDraggingMarker(true);
        }
      }

      if (!isDraggingMarker || !canMove) return;

      const rect = containerRef.current.getBoundingClientRect();
      const deltaY = markerDragStartY !== null ? Math.abs(e.clientY - markerDragStartY) : 0;
      const isOutsideVertically =
        e.clientY < rect.top - VERTICAL_CANCEL_THRESHOLD ||
        e.clientY > rect.bottom + VERTICAL_CANCEL_THRESHOLD;

      if (isOutsideVertically || deltaY > VERTICAL_CANCEL_THRESHOLD) {
        // Cancel - snap back to original position
        setMarkerDragPreviewPercent(timeToPercent(draggedMarker.position));
        return;
      }

      // Calculate time from drag position
      const rawPercent = ((e.clientX - rect.left) / rect.width) * 100;
      const rawTime = timelineStart + (rawPercent / 100) * duration;

      // Snap to grid (16th notes) if we have BPM
      const snappedTime = bpm ? snapToGrid(rawTime, bpm, 4) : rawTime;
      const snappedPercent = timeToPercent(snappedTime);

      setMarkerDragPreviewPercent(Math.max(0, Math.min(100, snappedPercent)));
    },
    [draggedMarker, isDraggingMarker, markerDragStartY, timeToPercent, timelineStart, duration, bpm]
  );

  const handleMarkerPointerUp = useCallback(
    (e: React.PointerEvent) => {
      // Clear long-press timer
      if (markerHoldTimerRef.current) {
        clearTimeout(markerHoldTimerRef.current);
        markerHoldTimerRef.current = null;
      }

      if (!draggedMarker || !containerRef.current) {
        setDraggedMarker(null);
        setMarkerDragStartY(null);
        setMarkerDragPreviewPercent(null);
        setIsDraggingMarker(false);
        return;
      }

      (e.target as HTMLElement).releasePointerCapture(e.pointerId);

      const canMove = isMarkerMoveable(draggedMarker.id);

      // If we were dragging and marker is moveable, commit the move
      if (isDraggingMarker && canMove && markerDragPreviewPercent !== null) {
        const rect = containerRef.current.getBoundingClientRect();
        const deltaY = markerDragStartY !== null ? Math.abs(e.clientY - markerDragStartY) : 0;
        const isOutsideVertically =
          e.clientY < rect.top - VERTICAL_CANCEL_THRESHOLD ||
          e.clientY > rect.bottom + VERTICAL_CANCEL_THRESHOLD;

        // Only commit if not cancelled
        if (!isOutsideVertically && deltaY <= VERTICAL_CANCEL_THRESHOLD) {
          const newTime = timelineStart + (markerDragPreviewPercent / 100) * duration;
          const actionId = getMarkerMoveAction(draggedMarker.id);
          if (actionId) {
            // Seek to new position, then move marker
            send(commands.join(
              commands.setPosition(newTime),
              commands.action(actionId)
            ));
          }
        }
      }

      // Reset state
      setIsDraggingMarker(false);
      setDraggedMarker(null);
      setMarkerDragStartY(null);
      setMarkerDragPreviewPercent(null);
    },
    [draggedMarker, isDraggingMarker, markerDragStartY, markerDragPreviewPercent, timelineStart, duration, send]
  );

  // Marker edit modal callbacks
  const handleMarkerMove = useCallback(
    (markerId: number, newPositionSeconds: number) => {
      const actionId = getMarkerMoveAction(markerId);
      if (actionId) {
        send(commands.join(
          commands.setPosition(newPositionSeconds),
          commands.action(actionId)
        ));
      }
    },
    [send]
  );

  const handleMarkerDelete = useCallback(
    (markerPositionSeconds: number) => {
      // Seek to marker position, then delete marker near cursor
      send(commands.join(
        commands.setPosition(markerPositionSeconds),
        commands.action(40613) // Delete marker near cursor
      ));
    },
    [send]
  );

  const handleReorderAllMarkers = useCallback(() => {
    send(commands.action(40898)); // Renumber all markers in timeline order
  }, [send]);

  // Calculate selection preview bounds
  const selectionPreview = useMemo(() => {
    if (dragStart === null || dragEnd === null) return null;
    if (!isHolding && Math.abs(dragEnd - dragStart) <= 0.1) return null;

    let start = Math.min(dragStart, dragEnd);
    let end = Math.max(dragStart, dragEnd);

    // Snap to boundaries for preview
    start = findNearestBoundary(start);
    end = findNearestBoundary(end);

    return { start, end };
  }, [dragStart, dragEnd, isHolding, findNearestBoundary]);

  return (
    <div className={`${className}`}>
      <h3 className="text-sm font-medium text-gray-400 mb-2">Timeline</h3>

      {/* Top bar - region labels (color bar + text) */}
      <div className="relative h-[25px] bg-gray-900 rounded-t-lg">
        {regions.map((region) => (
          <div
            key={`region-label-${region.id}`}
            className="absolute top-0 bottom-0 border-l border-r border-gray-600 flex flex-col"
            style={{
              left: `${timeToPercent(region.start)}%`,
              width: `${timeToPercent(region.end) - timeToPercent(region.start)}%`,
            }}
          >
            {/* Color bar - 5px */}
            <div
              className="h-[5px] w-full"
              style={{ backgroundColor: reaperColorToCSS(region.color, 'rgb(75, 85, 99)') }}
            />
            {/* Region name */}
            <span className="h-5 flex items-center px-1 text-[11px] text-white font-semibold truncate">
              {region.name}
            </span>
          </div>
        ))}
      </div>

      <div
        ref={containerRef}
        className="relative bg-gray-800 overflow-hidden touch-none select-none"
        style={{ height }}
        onPointerDown={handlePointerDown}
        onPointerMove={handlePointerMove}
        onPointerUp={handlePointerUp}
        onPointerCancel={handlePointerUp}
      >
        {/* Regions - blocks only (no color), labels in top bar */}
        {regions.map((region) => (
          <div
            key={`region-${region.id}`}
            className="absolute top-0 bottom-0 border-l border-r border-gray-600 bg-gray-700/50"
            style={{
              left: `${timeToPercent(region.start)}%`,
              width: `${timeToPercent(region.end) - timeToPercent(region.start)}%`,
            }}
          />
        ))}

        {/* Stored Time Selection */}
        {timeSelectionSeconds && (
          <div
            className="absolute top-0 bottom-0 bg-yellow-500/20 border-l-2 border-r-2 border-yellow-400 pointer-events-none"
            style={{
              left: `${timeToPercent(timeSelectionSeconds.start)}%`,
              width: `${timeToPercent(timeSelectionSeconds.end) - timeToPercent(timeSelectionSeconds.start)}%`,
            }}
          />
        )}

        {/* Markers - lines only, labels in bottom bar */}
        {markers.map((marker) => (
          <div
            key={`marker-${marker.id}`}
            className="absolute top-0 bottom-0 w-0.5 bg-red-500"
            style={{ left: `${timeToPercent(marker.position)}%` }}
          />
        ))}

        {/* Selection Preview */}
        {selectionPreview && (
          <div
            className="absolute top-0 bottom-0 bg-blue-500/30 border-l-2 border-r-2 border-blue-400 pointer-events-none"
            style={{
              left: `${timeToPercent(selectionPreview.start)}%`,
              width: `${timeToPercent(selectionPreview.end) - timeToPercent(selectionPreview.start)}%`,
            }}
          />
        )}

        {/* Playhead with grab handle */}
        <div
          className={`absolute top-0 bottom-0 ${isDraggingPlayhead ? 'opacity-50' : ''}`}
          style={{ left: `${playheadPercent}%` }}
        >
          {/* Playhead line - above markers (z-10), below region labels (z-20) */}
          <div className="absolute top-0 bottom-0 left-0 w-0.5 bg-white pointer-events-none z-10" />

          {/* Grab handle - T-shape at top, above everything */}
          <div
            className="absolute -top-0.5 -left-[11px] w-6 h-6 cursor-grab active:cursor-grabbing z-30"
            style={{ touchAction: 'none' }}
            onPointerDown={handlePlayheadPointerDown}
            onPointerMove={handlePlayheadPointerMove}
            onPointerUp={handlePlayheadPointerUp}
            onPointerCancel={handlePlayheadPointerUp}
          >
            {/* Visible T-bar */}
            <div className="absolute top-0.5 left-1/2 -translate-x-1/2 w-4 h-1.5 bg-white rounded-sm shadow-md" />
          </div>
        </div>

        {/* Preview playhead during drag */}
        {isDraggingPlayhead && playheadPreviewPercent !== null && (
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
                {(() => {
                  const seconds = timelineStart + (playheadPreviewPercent / 100) * duration;
                  const mins = Math.floor(seconds / 60);
                  const secs = (seconds % 60).toFixed(1);
                  const timeStr = `${mins}:${secs.padStart(4, '0')}`;
                  const beatsStr = bpm ? formatBeatsWithOffset(seconds, bpm, barOffset) : '';
                  return beatsStr ? `${timeStr} | ${beatsStr}` : timeStr;
                })()}
              </div>
            </div>
          </div>
        )}

        {/* Preview marker during drag */}
        {isDraggingMarker && draggedMarker && markerDragPreviewPercent !== null && (
          <div
            className="absolute top-0 bottom-0 pointer-events-none"
            style={{ left: `${markerDragPreviewPercent}%` }}
          >
            {/* Preview line */}
            <div className="absolute top-0 bottom-0 left-0 w-0.5 bg-red-400 z-10" />
            {/* Position pill showing time and beats */}
            <div className="absolute top-1/2 -translate-y-1/2 -translate-x-1/2 z-40">
              <div className="bg-gray-900 border border-red-400 rounded px-2 py-1 text-xs text-white font-mono whitespace-nowrap shadow-lg">
                {(() => {
                  const seconds = timelineStart + (markerDragPreviewPercent / 100) * duration;
                  const mins = Math.floor(seconds / 60);
                  const secs = (seconds % 60).toFixed(1);
                  const timeStr = `${mins}:${secs.padStart(4, '0')}`;
                  const beatsStr = bpm ? formatBeatsWithOffset(seconds, bpm, barOffset) : '';
                  return beatsStr ? `${timeStr} | ${beatsStr}` : timeStr;
                })()}
              </div>
            </div>
          </div>
        )}

        {/* Empty state */}
        {regions.length === 0 && markers.length === 0 && (
          <div className="absolute inset-0 flex items-center justify-center text-gray-500 text-sm">
            No regions or markers
          </div>
        )}
      </div>

      {/* Bottom bar - selection indicator and marker pills */}
      <div className="relative h-5 bg-gray-900 rounded-b-lg">
        {/* Time selection indicator - top half */}
        {timeSelectionSeconds && (
          <div
            className="absolute top-0 h-1/2 bg-yellow-400"
            style={{
              left: `${timeToPercent(timeSelectionSeconds.start)}%`,
              width: `${timeToPercent(timeSelectionSeconds.end) - timeToPercent(timeSelectionSeconds.start)}%`,
            }}
          />
        )}
        {/* Marker pills - offset by 1px to center on 2px-wide marker line */}
        {markers.map((marker) => {
          const canMove = isMarkerMoveable(marker.id);
          const isBeingDragged = draggedMarker?.id === marker.id;
          return (
            <div
              key={`marker-pill-${marker.id}`}
              className={`absolute top-1/2 -translate-y-1/2 -translate-x-1/2 min-w-4 h-4 px-1 rounded-full flex items-center justify-center touch-none select-none transition-opacity ${
                canMove
                  ? 'bg-red-600 cursor-grab active:cursor-grabbing'
                  : 'bg-gray-500 cursor-not-allowed'
              } ${isBeingDragged && isDraggingMarker ? 'opacity-50' : ''}`}
              style={{ left: `calc(${timeToPercent(marker.position)}% + 1px)` }}
              onPointerDown={(e) => handleMarkerPointerDown(e, marker)}
              onPointerMove={handleMarkerPointerMove}
              onPointerUp={handleMarkerPointerUp}
              onPointerCancel={handleMarkerPointerUp}
            >
              <span className="text-[10px] text-white font-bold leading-none">{marker.id}</span>
            </div>
          );
        })}
      </div>

      {/* Marker Edit Modal */}
      {editingMarker && (
        <MarkerEditModal
          marker={editingMarker}
          bpm={bpm || 120}
          barOffset={barOffset}
          onClose={() => setEditingMarker(null)}
          onMove={handleMarkerMove}
          onDelete={handleMarkerDelete}
          onReorderAll={handleReorderAllMarkers}
        />
      )}
    </div>
  );
}
