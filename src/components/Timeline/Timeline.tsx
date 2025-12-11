/**
 * Timeline Component
 * Visual timeline showing regions and markers for navigation and selection
 */

import { useState, useRef, useCallback, useMemo, type ReactElement } from 'react';
import { useReaperStore } from '../../store';
import { useReaper } from '../ReaperProvider';
import { useTransport } from '../../hooks/useTransport';
import * as commands from '../../core/CommandBuilder';
import type { Region } from '../../core/types';

export interface TimelineProps {
  className?: string;
  /** Minimum height in pixels */
  height?: number;
}

// Hold duration threshold in ms
const HOLD_THRESHOLD = 300;

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

export function Timeline({ className = '', height = 80 }: TimelineProps): ReactElement {
  const { send } = useReaper();
  const { positionSeconds, seekTo } = useTransport();
  const regions = useReaperStore((state) => state.regions);
  const markers = useReaperStore((state) => state.markers);
  const bpm = useReaperStore((state) => state.bpm);
  const storedTimeSelection = useReaperStore((state) => state.timeSelection);
  const setStoredTimeSelection = useReaperStore((state) => state.setTimeSelection);

  // Convert stored beat-based selection to seconds for display
  const timeSelectionSeconds = useMemo(() => {
    if (!storedTimeSelection || !bpm) return null;
    return {
      start: beatsToSeconds(storedTimeSelection.startBeats, bpm),
      end: beatsToSeconds(storedTimeSelection.endBeats, bpm),
    };
  }, [storedTimeSelection, bpm]);

  // Gesture state
  const [isHolding, setIsHolding] = useState(false);
  const [dragStart, setDragStart] = useState<number | null>(null);
  const [dragEnd, setDragEnd] = useState<number | null>(null);
  const holdTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const containerRef = useRef<HTMLDivElement>(null);

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
    [positionToTime]
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

  // Playhead position
  const playheadPercent = timeToPercent(positionSeconds);

  return (
    <div className={`${className}`}>
      <h3 className="text-sm font-medium text-gray-400 mb-2">Timeline</h3>
      <div
        ref={containerRef}
        className="relative bg-gray-800 rounded-t-lg overflow-hidden touch-none select-none"
        style={{ height }}
        onPointerDown={handlePointerDown}
        onPointerMove={handlePointerMove}
        onPointerUp={handlePointerUp}
        onPointerCancel={handlePointerUp}
      >
        {/* Regions */}
        {regions.map((region) => (
          <div
            key={`region-${region.id}`}
            className="absolute top-0 bottom-0 border-l border-r border-gray-600"
            style={{
              left: `${timeToPercent(region.start)}%`,
              width: `${timeToPercent(region.end) - timeToPercent(region.start)}%`,
              backgroundColor: reaperColorToCSS(region.color, 'rgba(75, 85, 99, 0.5)'),
            }}
          >
            <span className="absolute top-1 left-1 text-xs text-white truncate max-w-full px-1 bg-black/30 rounded">
              {region.name}
            </span>
          </div>
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

        {/* Markers */}
        {markers.map((marker) => (
          <div
            key={`marker-${marker.id}`}
            className="absolute top-0 bottom-0 w-0.5 bg-red-500"
            style={{ left: `${timeToPercent(marker.position)}%` }}
          >
            <span className="absolute bottom-1 left-1.5 text-xs text-red-400 font-bold">
              {marker.id}
            </span>
          </div>
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

        {/* Playhead */}
        <div
          className="absolute top-0 bottom-0 w-0.5 bg-white pointer-events-none z-10"
          style={{ left: `${playheadPercent}%` }}
        />

        {/* Empty state */}
        {regions.length === 0 && markers.length === 0 && (
          <div className="absolute inset-0 flex items-center justify-center text-gray-500 text-sm">
            No regions or markers
          </div>
        )}
      </div>

      {/* Selection indicator bar below timeline */}
      <div className="relative h-2 bg-gray-900 rounded-b-lg">
        {timeSelectionSeconds && (
          <div
            className="absolute top-0 bottom-0 bg-yellow-400"
            style={{
              left: `${timeToPercent(timeSelectionSeconds.start)}%`,
              width: `${timeToPercent(timeSelectionSeconds.end) - timeToPercent(timeSelectionSeconds.start)}%`,
            }}
          />
        )}
      </div>
    </div>
  );
}
