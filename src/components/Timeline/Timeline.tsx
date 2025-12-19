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
import { usePlayheadDrag, useMarkerDrag } from './hooks';
import type { DragType } from '../../store';
import {
  secondsToBeats,
  beatsToSeconds,
  formatBeats,
  formatDelta,
  parseReaperBar,
  snapToGrid,
  reaperColorToRgba,
} from '../../utils';

export interface TimelineProps {
  className?: string;
  /** Minimum height in pixels */
  height?: number;
  /** Whether time selection sync is in progress */
  isSyncing?: boolean;
}

// Hold duration threshold in ms
const HOLD_THRESHOLD = 300;

export function Timeline({ className = '', height = 120, isSyncing = false }: TimelineProps): ReactElement {
  const { send } = useReaper();
  const { positionSeconds, seekTo } = useTransport();
  const regions = useReaperStore((state) => state.regions);
  const markers = useReaperStore((state) => state.markers);
  const bpm = useReaperStore((state) => state.bpm);
  const positionBeats = useReaperStore((state) => state.positionBeats);
  const storedTimeSelection = useReaperStore((state) => state.timeSelection);
  const setStoredTimeSelection = useReaperStore((state) => state.setTimeSelection);

  // Region editing state
  const timelineMode = useReaperStore((state) => state.timelineMode);
  const selectedRegionIndices = useReaperStore((state) => state.selectedRegionIndices);
  const pendingChanges = useReaperStore((state) => state.pendingChanges);
  const hasPendingChanges = useReaperStore((state) => state.hasPendingChanges);
  const selectRegion = useReaperStore((state) => state.selectRegion);
  const deselectRegion = useReaperStore((state) => state.deselectRegion);
  const clearSelection = useReaperStore((state) => state.clearSelection);
  const isRegionSelected = useReaperStore((state) => state.isRegionSelected);
  const resizeRegion = useReaperStore((state) => state.resizeRegion);
  const moveRegion = useReaperStore((state) => state.moveRegion);
  const getDisplayRegions = useReaperStore((state) => state.getDisplayRegions);
  const getDragPreviewRegions = useReaperStore((state) => state.getDragPreviewRegions);
  const startDrag = useReaperStore((state) => state.startDrag);
  const updateDrag = useReaperStore((state) => state.updateDrag);
  const endDrag = useReaperStore((state) => state.endDrag);
  const cancelDrag = useReaperStore((state) => state.cancelDrag);
  const regionDragType = useReaperStore((state) => state.dragType);
  const regionDragIndex = useReaperStore((state) => state.dragRegionIndex);
  const dragCurrentTime = useReaperStore((state) => state.dragCurrentTime);
  const dragStartTime = useReaperStore((state) => state.dragStartTime);
  const insertionPoint = useReaperStore((state) => state.insertionPoint);
  const resizeEdgePosition = useReaperStore((state) => state.resizeEdgePosition);

  // Calculate bar offset from REAPER's actual bar numbering
  // This handles projects that don't start at bar 1 (e.g., -4.1.00)
  const barOffset = useMemo(() => {
    if (!bpm || !positionBeats || positionSeconds <= 0) return 0;
    const actualBar = parseReaperBar(positionBeats);
    const rawBeats = secondsToBeats(positionSeconds, bpm);
    // Round to nearest 16th note to handle floating point precision
    const totalBeats = Math.round(rawBeats * 4) / 4;
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

  // Base display regions (with pending changes but WITHOUT drag preview) - used for snap calculations
  const baseDisplayRegions = useMemo(() => {
    if (timelineMode === 'regions') {
      return getDisplayRegions(regions);
    }
    return regions;
  }, [timelineMode, regions, getDisplayRegions, pendingChanges]);

  // Get regions to display (with pending changes and drag preview applied in region mode)
  const displayRegions = useMemo(() => {
    if (timelineMode === 'regions') {
      // Use drag preview when actively dragging, otherwise show pending changes
      if (regionDragType !== 'none') {
        return getDragPreviewRegions(regions);
      }
      return baseDisplayRegions;
    }
    return regions;
  }, [timelineMode, regions, baseDisplayRegions, getDragPreviewRegions, regionDragType, dragCurrentTime]);

  // Compute selected _pendingKey values from baseDisplayRegions
  // This is needed because during a drag, displayRegions is reordered but selectedRegionIndices
  // still contains the original display indices. We need to track selection by _pendingKey.
  const selectedPendingKeys = useMemo(() => {
    return new Set(
      selectedRegionIndices.map(idx => {
        const region = baseDisplayRegions[idx];
        return region ? ((region as { _pendingKey?: number })._pendingKey ?? idx) : idx;
      })
    );
  }, [selectedRegionIndices, baseDisplayRegions]);

  // Get the _pendingKey of the region being dragged (from baseDisplayRegions, not preview)
  const draggedPendingKey = useMemo(() => {
    if (regionDragIndex === null || regionDragType === 'none') return null;
    const region = baseDisplayRegions[regionDragIndex];
    return region ? ((region as { _pendingKey?: number })._pendingKey ?? regionDragIndex) : null;
  }, [regionDragIndex, regionDragType, baseDisplayRegions]);

  // Region edit modal state (TODO: implement RegionEditModal)
  const [_editingRegion, setEditingRegion] = useState<{ region: Region; index: number } | null>(null);

  // Edge handle hit zone size in pixels
  const EDGE_HANDLE_SIZE = 20;

  // Long-press threshold for region edit modal
  const REGION_HOLD_THRESHOLD = 500;

  // Region hold timer ref
  const regionHoldTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Track if region was already selected when tap started (for toggle behavior)
  const wasSelectedOnTapStartRef = useRef<boolean>(false);

  // Gesture state
  const [isHolding, setIsHolding] = useState(false);
  const [dragStart, setDragStart] = useState<number | null>(null);
  const [dragEnd, setDragEnd] = useState<number | null>(null);
  const holdTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const containerRef = useRef<HTMLDivElement>(null);

  // Marker edit modal state
  const [editingMarker, setEditingMarker] = useState<Marker | null>(null);

  // Calculate timeline bounds (expands dynamically when dragging beyond current extent)
  const { timelineStart, duration } = useMemo(() => {
    const start = 0;
    let end = 0;

    // Use display regions (includes drag preview) to get current extent
    for (const region of displayRegions) {
      if (region.end > end) end = region.end;
    }
    for (const marker of markers) {
      if (marker.position > end) end = marker.position;
    }

    // Also consider current drag target (for smooth expansion while dragging)
    if (resizeEdgePosition !== null && resizeEdgePosition > end) {
      end = resizeEdgePosition;
    }
    if (insertionPoint !== null && insertionPoint > end) {
      end = insertionPoint;
    }
    if (dragCurrentTime !== null && dragCurrentTime > end) {
      end = dragCurrentTime;
    }

    // Add some padding at the end
    end = Math.max(end * 1.05, 10);

    return { timelineStart: start, duration: end - start };
  }, [displayRegions, markers, resizeEdgePosition, insertionPoint, dragCurrentTime]);

  // Convert time to percentage position
  const timeToPercent = useCallback(
    (time: number) => {
      if (duration === 0) return 0;
      return ((time - timelineStart) / duration) * 100;
    },
    [timelineStart, duration]
  );

  // Playhead position and drag hook (must be before handlePointerDown which uses isDraggingPlayhead)
  const playheadPercent = timeToPercent(positionSeconds);
  const handlePlayheadSeek = useCallback(
    (newTime: number) => send(seekTo(newTime)),
    [send, seekTo]
  );
  const {
    isDragging: isDraggingPlayhead,
    previewPercent: playheadPreviewPercent,
    handlePointerDown: handlePlayheadPointerDown,
    handlePointerMove: handlePlayheadPointerMove,
    handlePointerUp: handlePlayheadPointerUp,
  } = usePlayheadDrag({
    containerRef,
    playheadPercent,
    timelineStart,
    duration,
    onSeek: handlePlayheadSeek,
  });

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

  // Find region index at position (using displayRegions for pending changes)
  const findRegionIndexAtPosition = useCallback(
    (clientX: number): number | null => {
      if (!containerRef.current) return null;
      const time = positionToTime(clientX);

      for (let i = 0; i < displayRegions.length; i++) {
        const region = displayRegions[i];
        if (time >= region.start && time < region.end) {
          return i;
        }
      }
      return null;
    },
    [displayRegions, positionToTime]
  );

  // Determine drag type (resize-start, resize-end, or move) based on click position
  const detectDragType = useCallback(
    (clientX: number, regionIndex: number): DragType => {
      if (!containerRef.current) return 'move';

      const rect = containerRef.current.getBoundingClientRect();
      const region = displayRegions[regionIndex];
      if (!region) return 'move';

      const startPercent = timeToPercent(region.start);
      const endPercent = timeToPercent(region.end);

      const startX = rect.left + (startPercent / 100) * rect.width;
      const endX = rect.left + (endPercent / 100) * rect.width;

      if (Math.abs(clientX - startX) < EDGE_HANDLE_SIZE) {
        return 'resize-start';
      }
      if (Math.abs(clientX - endX) < EDGE_HANDLE_SIZE) {
        return 'resize-end';
      }
      return 'move';
    },
    [displayRegions, timeToPercent]
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

      // Region editing mode
      if (timelineMode === 'regions') {
        const regionIndex = findRegionIndexAtPosition(e.clientX);

        if (regionIndex !== null) {
          const wasSelected = isRegionSelected(regionIndex);
          const dragType = detectDragType(e.clientX, regionIndex);

          // Track selection state at tap start for toggle behavior in pointerUp
          wasSelectedOnTapStartRef.current = wasSelected;

          // If already selected and tapped again, add to multi-select
          if (wasSelected && selectedRegionIndices.length === 1) {
            // Start long-press timer for edit modal
            regionHoldTimerRef.current = setTimeout(() => {
              const region = displayRegions[regionIndex];
              if (region) {
                setEditingRegion({ region, index: regionIndex });
              }
              // Cancel any drag
              cancelDrag();
            }, REGION_HOLD_THRESHOLD);
          }

          // Start drag operation - allow dragging even with pending changes
          // so users can continue editing before committing
          startDrag(dragType, regionIndex, e.clientX, time);

          // Select the region if not already selected
          if (!wasSelected) {
            selectRegion(regionIndex);
          }
        } else {
          // Tapped on empty area - clear selection
          clearSelection();
        }

        // Capture pointer
        (e.target as HTMLElement).setPointerCapture(e.pointerId);
        return;
      }

      // Navigate mode (existing behavior)
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
    [
      positionToTime,
      isDraggingPlayhead,
      timelineMode,
      findRegionIndexAtPosition,
      isRegionSelected,
      detectDragType,
      selectedRegionIndices,
      displayRegions,
      startDrag,
      selectRegion,
      clearSelection,
      cancelDrag,
    ]
  );

  // Handle touch/mouse move
  const handlePointerMove = useCallback(
    (e: React.PointerEvent) => {
      const time = positionToTime(e.clientX);

      // Region editing mode
      if (timelineMode === 'regions' && regionDragType !== 'none' && regionDragIndex !== null) {
        // Clear long-press timer if we moved
        if (regionHoldTimerRef.current) {
          clearTimeout(regionHoldTimerRef.current);
          regionHoldTimerRef.current = null;
        }

        // For move operations, snap to valid insertion points only
        // Valid points depend on direction of move and account for gap closure
        if (regionDragType === 'move' && dragStartTime !== null) {
          const indicesToMove = selectedRegionIndices.length > 0
            ? selectedRegionIndices
            : [regionDragIndex];

          // IMPORTANT: Use baseDisplayRegions (positions BEFORE the drag), not displayRegions (preview)
          // This ensures we snap to the original positions, not the shifting preview
          const primaryRegion = baseDisplayRegions[regionDragIndex];
          if (primaryRegion) {
            // Calculate where the region's start would be after the move
            const delta = time - dragStartTime;
            const newStart = primaryRegion.start + delta;
            const regionDuration = primaryRegion.end - primaryRegion.start;

            // Build valid insertion points accounting for gap closure:
            // When we remove the region from its position, regions AFTER it shift LEFT by regionDuration
            // So we need to adjust snap points accordingly:
            // - Position 0 (to make it first)
            // - The dragged region's own start (no movement = always valid)
            // - Start of regions BEFORE: valid as-is (they don't shift)
            // - Start of regions AFTER: adjusted (subtract regionDuration for gap closure)
            // - The adjusted end position (lastEnd - regionDuration)
            const snapPoints: number[] = [0];
            let lastEnd = 0;

            // Always include the region's own position (allows "canceling" by returning to original)
            snapPoints.push(primaryRegion.start);

            baseDisplayRegions.forEach((region, index) => {
              if (!indicesToMove.includes(index)) {
                if (region.start < primaryRegion.start) {
                  // Regions BEFORE: their starts are valid as-is (they don't shift)
                  snapPoints.push(region.start);
                } else {
                  // Regions AFTER: adjust their starts for gap closure
                  // When we remove the dragged region, these shift left by regionDuration
                  // So the valid insertion point is their original start minus regionDuration
                  snapPoints.push(region.start - regionDuration);
                }
                if (region.end > lastEnd) {
                  lastEnd = region.end;
                }
              }
            });

            // Add the adjusted end position (accounting for gap closure when we remove the region)
            // When we remove the region, everything after shifts left by regionDuration
            if (lastEnd > 0) {
              const adjustedLastEnd = lastEnd - regionDuration;
              snapPoints.push(adjustedLastEnd);
            }

            // ALWAYS snap to the nearest valid point (no free positioning)
            let snappedStart = snapPoints[0];
            let minDist = Infinity;

            for (const point of snapPoints) {
              const dist = Math.abs(newStart - point);
              if (dist < minDist) {
                minDist = dist;
                snappedStart = point;
              }
            }

            // Adjust the time to produce the snapped position
            const snappedDelta = snappedStart - primaryRegion.start;
            const snappedTime = dragStartTime + snappedDelta;
            updateDrag(e.clientX, snappedTime);
            return;
          }
        }

        // For resize operations, snap to bar boundaries (4 beats) for less sensitivity
        const snappedTime = bpm ? snapToGrid(time, bpm, 4) : time;

        updateDrag(e.clientX, snappedTime);
        return;
      }

      // Navigate mode
      if (dragStart === null) return;

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
    [dragStart, positionToTime, timelineMode, regionDragType, regionDragIndex, updateDrag, bpm, duration, displayRegions, baseDisplayRegions, selectedRegionIndices, dragStartTime]
  );

  // Handle touch/mouse end
  const handlePointerUp = useCallback(
    (e: React.PointerEvent) => {
      // Clear hold timers
      if (holdTimerRef.current) {
        clearTimeout(holdTimerRef.current);
        holdTimerRef.current = null;
      }
      if (regionHoldTimerRef.current) {
        clearTimeout(regionHoldTimerRef.current);
        regionHoldTimerRef.current = null;
      }

      // Region editing mode
      if (timelineMode === 'regions') {
        if (regionDragType !== 'none' && regionDragIndex !== null && dragStartTime !== null && dragCurrentTime !== null) {
          const delta = dragCurrentTime - dragStartTime;
          const wasDragging = Math.abs(delta) > 0.05; // More than 50ms movement

          if (wasDragging) {
            // Get the region from baseDisplayRegions (original positions, not drag preview)
            const region = baseDisplayRegions[regionDragIndex];
            if (region) {
              // CRITICAL: regionDragIndex and selectedRegionIndices are DISPLAY indices (sorted by time)
              // But moveRegion/resizeRegion expect REGION indices (position in original regions array)
              // The _pendingKey on each display region stores the original region index
              const regionIndex = (region as { _pendingKey?: number })._pendingKey ?? regionDragIndex;

              if (regionDragType === 'resize-start') {
                // Resize start edge - use region index, not display index
                resizeRegion(regionIndex, 'start', dragCurrentTime, regions, bpm);
              } else if (regionDragType === 'resize-end') {
                // Resize end edge - use region index, not display index
                resizeRegion(regionIndex, 'end', dragCurrentTime, regions, bpm);
              } else if (regionDragType === 'move') {
                // Convert display indices to region indices (via _pendingKey)
                const displayIndicesToMove = selectedRegionIndices.length > 0
                  ? selectedRegionIndices
                  : [regionDragIndex];

                const regionIndicesToMove = displayIndicesToMove.map(displayIdx => {
                  const r = baseDisplayRegions[displayIdx] as { _pendingKey?: number };
                  return r._pendingKey ?? displayIdx;
                });

                // Move region(s) - pass region indices, not display indices
                moveRegion(regionIndicesToMove, delta, regions);

                // After move, find new display indices and update selection
                // Use setTimeout to let state update first
                setTimeout(() => {
                  const updatedDisplayRegions = getDisplayRegions(regions);
                  const newDisplayIndices = regionIndicesToMove
                    .map(regIdx => {
                      return updatedDisplayRegions.findIndex(
                        r => (r as { _pendingKey?: number })._pendingKey === regIdx
                      );
                    })
                    .filter(idx => idx !== -1);

                  // Update selection to the new display indices
                  if (newDisplayIndices.length > 0) {
                    clearSelection();
                    newDisplayIndices.forEach(idx => selectRegion(idx));
                  }
                }, 0);
              }
            }
          } else {
            // Was just a tap - toggle selection only if it was already selected before tap started
            if (wasSelectedOnTapStartRef.current) {
              // Deselect if it was already selected when tap started
              deselectRegion(regionDragIndex);
            }
          }
        }

        endDrag();
        (e.target as HTMLElement).releasePointerCapture(e.pointerId);
        return;
      }

      // Navigate mode
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
      timelineMode,
      regionDragType,
      regionDragIndex,
      dragStartTime,
      dragCurrentTime,
      displayRegions,
      baseDisplayRegions,
      resizeRegion,
      moveRegion,
      selectedRegionIndices,
      regions,
      bpm,
      isRegionSelected,
      deselectRegion,
      endDrag,
      getDisplayRegions,
      clearSelection,
      selectRegion,
    ]
  );

  // Marker drag hook
  const handleMarkerMoveFromDrag = useCallback(
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
  const {
    isDragging: isDraggingMarker,
    draggedMarker,
    previewPercent: markerDragPreviewPercent,
    handlePointerDown: handleMarkerPointerDown,
    handlePointerMove: handleMarkerPointerMove,
    handlePointerUp: handleMarkerPointerUp,
  } = useMarkerDrag({
    containerRef,
    timelineStart,
    duration,
    bpm,
    timeToPercent,
    onEdit: setEditingMarker,
    onMove: handleMarkerMoveFromDrag,
  });

  // Marker edit modal callbacks (also used by MarkerEditModal)
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
      {/* Top bar - region labels (color bar + text) */}
      <div className="relative h-[25px] bg-gray-900 rounded-t-lg">
        {displayRegions.map((region, idx) => {
          // Use _pendingKey from display region metadata for selection/pending lookup
          // This is stable across drag preview reordering
          const pendingKey = (region as { _pendingKey?: number })._pendingKey ?? idx;
          const isSelected = timelineMode === 'regions' && selectedPendingKeys.has(pendingKey);
          const isNewRegion = (region as { _isNew?: boolean })._isNew === true;
          const hasPending = pendingChanges[pendingKey] !== undefined;
          const isBeingDragged = draggedPendingKey === pendingKey && regionDragType !== 'none';
          // New regions get white outline, modified existing get orange
          const pendingRingClass = isNewRegion ? 'ring-1 ring-white' : hasPending ? 'ring-1 ring-amber-400' : '';
          return (
            <div
              key={`region-label-${region.id}`}
              className={`absolute top-0 bottom-0 border-l border-r flex flex-col ${
                isBeingDragged
                  ? 'border-purple-400 z-20 bg-gray-900'
                  : isSelected
                    ? 'border-purple-400 z-10'
                    : 'border-gray-600'
              } ${pendingRingClass}`}
              style={{
                left: `${timeToPercent(region.start)}%`,
                width: `${timeToPercent(region.end) - timeToPercent(region.start)}%`,
              }}
            >
              {/* Color bar - 5px */}
              <div
                className="h-[5px] w-full"
                style={{ backgroundColor: region.color ? reaperColorToRgba(region.color, 1) ?? 'rgb(75, 85, 99)' : 'rgb(75, 85, 99)' }}
              />
              {/* Region name */}
              <span className="h-5 flex items-center px-1 text-[11px] text-white font-semibold truncate">
                {region.name}
              </span>
            </div>
          );
        })}
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
        {displayRegions.map((region, idx) => {
          // Use _pendingKey from display region metadata for selection/pending lookup
          // This is stable across drag preview reordering
          const pendingKey = (region as { _pendingKey?: number })._pendingKey ?? idx;
          const isSelected = timelineMode === 'regions' && selectedPendingKeys.has(pendingKey);
          const isNewRegion = (region as { _isNew?: boolean })._isNew === true;
          const hasPending = pendingChanges[pendingKey] !== undefined;
          const isSingleSelection = isSelected && selectedPendingKeys.size === 1;
          const isBeingDragged = draggedPendingKey === pendingKey && regionDragType !== 'none';
          // New regions get white outline, modified existing get orange
          const pendingRingClass = isNewRegion ? 'ring-1 ring-inset ring-white' : hasPending ? 'ring-1 ring-inset ring-amber-400' : '';

          return (
            <div
              key={`region-${region.id}`}
              className={`absolute top-0 bottom-0 border-l border-r ${
                isBeingDragged
                  ? 'border-purple-400 bg-purple-500/50 z-20'
                  : isSelected
                    ? 'border-purple-400 bg-purple-500/30 z-10'
                    : 'border-gray-600 bg-gray-700/50'
              } ${pendingRingClass}`}
              style={{
                left: `${timeToPercent(region.start)}%`,
                width: `${timeToPercent(region.end) - timeToPercent(region.start)}%`,
              }}
            >
              {/* Edge handles - only show for single selection when no pending changes */}
              {isSingleSelection && !hasPendingChanges() && (
                <>
                  {/* Left edge handle */}
                  <div
                    className="absolute left-0 top-0 bottom-0 w-5 cursor-ew-resize flex items-center justify-start"
                    style={{ touchAction: 'none' }}
                  >
                    <div className="w-1.5 h-8 bg-purple-400 rounded-r-sm" />
                  </div>
                  {/* Right edge handle */}
                  <div
                    className="absolute right-0 top-0 bottom-0 w-5 cursor-ew-resize flex items-center justify-end"
                    style={{ touchAction: 'none' }}
                  >
                    <div className="w-1.5 h-8 bg-purple-400 rounded-l-sm" />
                  </div>
                </>
              )}
            </div>
          );
        })}

        {/* Stored Time Selection */}
        {timeSelectionSeconds && (
          <div
            className={`absolute top-0 bottom-0 border-l-2 border-r-2 pointer-events-none ${
              timelineMode === 'regions'
                ? 'bg-gray-500/5 border-gray-700 opacity-50'
                : 'bg-yellow-500/20 border-yellow-400'
            }`}
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
            className={`absolute top-0 bottom-0 w-0.5 ${
              timelineMode === 'regions' ? 'bg-gray-600 opacity-40' : 'bg-red-500'
            }`}
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

        {/* Insertion Point Indicator (for move operations) */}
        {insertionPoint !== null && regionDragType === 'move' && (
          <div
            className="absolute top-0 bottom-0 pointer-events-none z-20"
            style={{ left: `${timeToPercent(insertionPoint)}%` }}
          >
            {/* Main insertion line */}
            <div className="absolute top-0 bottom-0 left-0 w-1 bg-green-400 shadow-lg shadow-green-400/50" />
            {/* Top arrow indicator */}
            <div className="absolute -top-1 left-1/2 -translate-x-1/2 w-0 h-0 border-l-[6px] border-r-[6px] border-t-[8px] border-l-transparent border-r-transparent border-t-green-400" />
            {/* Bottom arrow indicator */}
            <div className="absolute -bottom-1 left-1/2 -translate-x-1/2 w-0 h-0 border-l-[6px] border-r-[6px] border-b-[8px] border-l-transparent border-r-transparent border-b-green-400" />
            {/* Position pill showing bar position at bottom */}
            <div className="absolute bottom-1 -translate-x-1/2 z-40">
              <div className="bg-gray-900 border border-green-400 rounded px-2 py-1 text-xs text-white font-mono whitespace-nowrap shadow-lg">
                {bpm ? formatBeats(insertionPoint, bpm, barOffset) : `${insertionPoint.toFixed(1)}s`}
              </div>
            </div>
          </div>
        )}

        {/* Resize Edge Position Indicator */}
        {resizeEdgePosition !== null && (regionDragType === 'resize-start' || regionDragType === 'resize-end') && regionDragIndex !== null && (
          (() => {
            const originalRegion = regions[regionDragIndex];
            const originalEdge = regionDragType === 'resize-start' ? originalRegion?.start : originalRegion?.end;
            const delta = originalEdge !== undefined ? resizeEdgePosition - originalEdge : 0;
            const showDelta = Math.abs(delta) > 0.01 && bpm;

            return (
              <div
                className="absolute top-0 bottom-0 pointer-events-none z-20"
                style={{ left: `${timeToPercent(resizeEdgePosition)}%` }}
              >
                {/* Main edge line */}
                <div className="absolute top-0 bottom-0 left-0 w-1 bg-green-400 shadow-lg shadow-green-400/50" />
                {/* Top arrow indicator */}
                <div className="absolute -top-1 left-1/2 -translate-x-1/2 w-0 h-0 border-l-[6px] border-r-[6px] border-t-[8px] border-l-transparent border-r-transparent border-t-green-400" />
                {/* Bottom arrow indicator */}
                <div className="absolute -bottom-1 left-1/2 -translate-x-1/2 w-0 h-0 border-l-[6px] border-r-[6px] border-b-[8px] border-l-transparent border-r-transparent border-b-green-400" />
                {/* Delta pill showing change amount */}
                {showDelta && (
                  <div className="absolute top-8 -translate-x-1/2 z-40">
                    <div className={`rounded px-2 py-0.5 text-xs font-mono whitespace-nowrap shadow-lg ${
                      delta < 0 ? 'bg-red-900/90 text-red-200 border border-red-500' : 'bg-green-900/90 text-green-200 border border-green-500'
                    }`}>
                      {formatDelta(delta, bpm!)}
                    </div>
                  </div>
                )}
                {/* Position pill showing bar position at bottom */}
                <div className="absolute bottom-1 -translate-x-1/2 z-40">
                  <div className="bg-gray-900 border border-green-400 rounded px-2 py-1 text-xs text-white font-mono whitespace-nowrap shadow-lg">
                    {bpm ? formatBeats(resizeEdgePosition, bpm, barOffset) : `${resizeEdgePosition.toFixed(1)}s`}
                  </div>
                </div>
              </div>
            );
          })()
        )}

        {/* Playhead with grab handle - hidden while syncing */}
        {!isSyncing && (
          <div
            className={`absolute top-0 bottom-0 ${isDraggingPlayhead ? 'opacity-50' : ''}`}
            style={{ left: `${playheadPercent}%` }}
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
        )}

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
                  const beatsStr = bpm ? formatBeats(seconds, bpm, barOffset) : '';
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
                  const beatsStr = bpm ? formatBeats(seconds, bpm, barOffset) : '';
                  return beatsStr ? `${timeStr} | ${beatsStr}` : timeStr;
                })()}
              </div>
            </div>
          </div>
        )}

        {/* Empty state */}
        {displayRegions.length === 0 && markers.length === 0 && (
          <div className="absolute inset-0 flex items-center justify-center text-gray-500 text-sm">
            No regions or markers
          </div>
        )}

        {/* Syncing indicator */}
        {isSyncing && (
          <div className="absolute inset-0 flex items-center justify-center z-50 pointer-events-none">
            <div className="px-3 py-1.5 bg-gray-900/90 border border-yellow-500/50 rounded-full text-yellow-400 text-xs font-medium animate-pulse">
              Syncing...
            </div>
          </div>
        )}
      </div>

      {/* Bottom bar - selection indicator and marker pills */}
      <div className="relative h-5 bg-gray-900 rounded-b-lg">
        {/* Time selection indicator - top half */}
        {timeSelectionSeconds && (
          <div
            className={`absolute top-0 h-1/2 ${
              timelineMode === 'regions' ? 'bg-gray-600 opacity-40' : 'bg-yellow-400'
            }`}
            style={{
              left: `${timeToPercent(timeSelectionSeconds.start)}%`,
              width: `${timeToPercent(timeSelectionSeconds.end) - timeToPercent(timeSelectionSeconds.start)}%`,
            }}
          />
        )}
        {/* Marker pills - offset by 1px to center on 2px-wide marker line */}
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
              style={{ left: `calc(${timeToPercent(marker.position)}% + 1px)` }}
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
