/**
 * useItemTapHandler — Item hit-testing for timeline taps
 *
 * Handles tap detection on multi-track lanes and single-track item blobs.
 * Given a (clientX, clientY) tap position, determines whether an item or
 * lane was hit and dispatches the appropriate selection commands.
 *
 * Returns true if the tap was handled (hit an item or lane), false otherwise.
 */

import { useCallback, type RefObject } from 'react';
import type { WSItem, SkeletonTrack } from '../../../core/WebSocketTypes';
import type { UseViewportReturn } from '../../../hooks';
import type { WSCommand } from '../../../core/WebSocketCommands';
import { item as itemCmd, track as trackCmd } from '../../../core/WebSocketCommands';

interface UseItemTapHandlerParams {
  containerRef: RefObject<HTMLDivElement | null>;
  viewport: UseViewportReturn;
  items: readonly WSItem[];
  trackSkeleton: readonly SkeletonTrack[];
  multiTrackLanes?: SkeletonTrack[];
  multiTrackIndices?: number[];
  viewFilterTrackGuid: string | null;
  itemSelectionModeActive: boolean;
  enterItemSelectionMode: (guid: string) => void;
  setViewFilterTrack: (guid: string | null) => void;
  setSelectedMarkerId: (id: number | null) => void;
  sendCommand: (cmd: WSCommand) => void;
  optimisticSelectTrack: (trackGuid: string) => void;
}

/** Convert track GUID → trackIdx using skeleton */
function getTrackIdxFromGuid(trackSkeleton: readonly SkeletonTrack[], guid: string): number | null {
  const idx = trackSkeleton.findIndex((t) => t.g === guid);
  return idx >= 0 ? idx : null;
}

export function useItemTapHandler({
  containerRef,
  viewport,
  items,
  trackSkeleton,
  multiTrackLanes,
  multiTrackIndices,
  viewFilterTrackGuid,
  itemSelectionModeActive,
  enterItemSelectionMode,
  setViewFilterTrack,
  setSelectedMarkerId,
  sendCommand,
  optimisticSelectTrack,
}: UseItemTapHandlerParams): (clientX: number, clientY: number) => boolean {
  return useCallback(
    (clientX: number, clientY: number): boolean => {
      if (!containerRef.current) return false;

      const rect = containerRef.current.getBoundingClientRect();
      const clickPercent = (clientX - rect.left) / rect.width;
      const clickTime =
        viewport.visibleRange.start +
        clickPercent * (viewport.visibleRange.end - viewport.visibleRange.start);
      const containerHeight = rect.height;
      const relativeY = clientY - rect.top;

      // Multi-track lanes mode: determine which lane was clicked
      if (multiTrackLanes && multiTrackLanes.length > 0 && multiTrackIndices && multiTrackIndices.length > 0) {
        const laneCount = multiTrackLanes.length;
        const laneHeight = containerHeight / laneCount;
        const laneIdx = Math.floor(relativeY / laneHeight);

        // Validate lane index
        if (laneIdx < 0 || laneIdx >= laneCount) {
          return false;
        }

        // Use passed track indices directly (slot-based for sequential banks)
        const clickedTrackGuid = multiTrackLanes[laneIdx]?.g;
        const clickedTrackIdx = multiTrackIndices[laneIdx];
        if (clickedTrackIdx === undefined) {
          return false;
        }

        // Check if click is within item strip in this lane (60% height, centered)
        const itemHeightPercent = 0.6;
        const itemTopOffset = laneHeight * (1 - itemHeightPercent) / 2;
        const relativeYInLane = relativeY - (laneIdx * laneHeight);
        const isWithinItemStrip = relativeYInLane >= itemTopOffset &&
                                  relativeYInLane <= itemTopOffset + (laneHeight * itemHeightPercent);

        // Find items at this time position ON THIS TRACK ONLY
        const itemsAtTime = items.filter(
          (item) =>
            item.trackIdx === clickedTrackIdx &&
            item.position <= clickTime &&
            item.position + item.length >= clickTime
        );

        // Tap on empty lane space (outside item strip OR no item at position)
        // → Clear all selections, select only this track
        if (!isWithinItemStrip || itemsAtTime.length === 0) {
          // Clear marker selection (mutual exclusion)
          setSelectedMarkerId(null);
          // Clear all track and item selections, then select this track only
          sendCommand(trackCmd.unselectAll());
          sendCommand(itemCmd.unselectAll());
          sendCommand(trackCmd.setSelected(clickedTrackIdx, 1));
          // Optimistic update: highlight track immediately (skeleton polls at 1Hz)
          if (clickedTrackGuid) {
            optimisticSelectTrack(clickedTrackGuid);
            setViewFilterTrack(clickedTrackGuid);
          }
          return true;
        }

        // Tap on item → toggle item selection + select item's track
        if (itemsAtTime.length > 0) {
          // Clear marker selection (mutual exclusion)
          setSelectedMarkerId(null);

          // Enter item selection mode if not already active
          if (!itemSelectionModeActive && clickedTrackGuid) {
            enterItemSelectionMode(clickedTrackGuid);
          }

          // Sort by position, take first (earliest) item and toggle selection
          const firstItem = itemsAtTime.sort((a, b) => a.position - b.position)[0];
          sendCommand(itemCmd.toggleSelect(firstItem.guid));

          // Select the item's track (clears other track selections)
          sendCommand(trackCmd.unselectAll());
          sendCommand(trackCmd.setSelected(clickedTrackIdx, 1));
          // Optimistic update: highlight track immediately (skeleton polls at 1Hz)
          if (clickedTrackGuid) {
            optimisticSelectTrack(clickedTrackGuid);
          }
        }

        return true;
      }

      // Single-track mode: original logic
      // Check if tap is within item blob vertical bounds (25% height, centered)
      const blobHeight = containerHeight * 0.25;
      const topOffset = (containerHeight - blobHeight) / 2;
      const isWithinBlobYBounds = relativeY >= topOffset && relativeY <= topOffset + blobHeight;

      if (!isWithinBlobYBounds) {
        return false;
      }

      // Find items at this time position
      const itemsAtTime = items.filter(
        (item) =>
          item.position <= clickTime && item.position + item.length >= clickTime
      );

      if (itemsAtTime.length > 0) {
        // Group by track, find first track (lowest index) with items
        const byTrack = new Map<number, WSItem[]>();
        itemsAtTime.forEach((item) => {
          if (!byTrack.has(item.trackIdx)) byTrack.set(item.trackIdx, []);
          byTrack.get(item.trackIdx)!.push(item);
        });

        // Get first track (lowest index)
        const firstTrackIdx = Math.min(...byTrack.keys());
        const trackGuid = trackSkeleton[firstTrackIdx]?.g;

        // Clear marker selection (mutual exclusion)
        setSelectedMarkerId(null);

        if (!itemSelectionModeActive) {
          // Not in item selection mode yet - enter it
          if (trackGuid) {
            enterItemSelectionMode(trackGuid);
          }
        } else {
          // Already in item selection mode - only select items on the FILTERED track
          const filterTrackIdx = viewFilterTrackGuid
            ? getTrackIdxFromGuid(trackSkeleton, viewFilterTrackGuid)
            : null;

          if (filterTrackIdx !== null && byTrack.has(filterTrackIdx)) {
            const trackItemsAtTime = byTrack.get(filterTrackIdx)!;
            const firstItem = trackItemsAtTime.sort((a, b) => a.position - b.position)[0];
            sendCommand(itemCmd.toggleSelect(firstItem.guid));
          }
        }

        return true;
      }

      return false;
    },
    [
      containerRef,
      viewport,
      items,
      trackSkeleton,
      multiTrackLanes,
      multiTrackIndices,
      viewFilterTrackGuid,
      itemSelectionModeActive,
      enterItemSelectionMode,
      setViewFilterTrack,
      setSelectedMarkerId,
      sendCommand,
      optimisticSelectTrack,
    ]
  );
}
