/**
 * ItemsDensityOverlay Component
 * Shows where items exist in the timeline as simple merged blocks
 * Overlapping items are merged into contiguous regions
 * When a track is selected, shows only that track's items in track color
 */

import { useMemo } from 'react';
import type { WSItem } from '../../core/WebSocketTypes';
import { type Track, isSelected } from '../../core/types';
import { reaperColorToRgba } from '../../utils';

// Default density block color - matches --color-density-block token
const DEFAULT_BLOCK_COLOR = 'rgba(129, 137, 137, 0.5)'; // --color-density-block

export interface ItemsDensityOverlayProps {
  /** All items in the project */
  items: WSItem[];
  /** Timeline start time in seconds */
  timelineStart: number;
  /** Timeline end time in seconds */
  timelineEnd: number;
  /** Height of the container in pixels */
  height: number;
  /** Track data for selection and color lookup */
  tracks: Record<number, Track>;
  /** Currently selected item key (trackIdx:itemIdx) */
  selectedItemKey?: string | null;
}

/** A merged time range representing contiguous item coverage */
interface MergedBlock {
  start: number; // seconds
  end: number; // seconds
}

/**
 * Merge overlapping item ranges into contiguous blocks
 * Items that overlap or touch are combined into single blocks
 */
function mergeItemRanges(items: WSItem[]): MergedBlock[] {
  if (items.length === 0) return [];

  // Get all item ranges and sort by start time
  const ranges = items
    .map((item) => ({
      start: item.position,
      end: item.position + item.length,
    }))
    .sort((a, b) => a.start - b.start);

  // Merge overlapping ranges
  const merged: MergedBlock[] = [];
  let current = { ...ranges[0] };

  for (let i = 1; i < ranges.length; i++) {
    const range = ranges[i];

    if (range.start <= current.end) {
      // Overlapping or touching - extend current block
      current.end = Math.max(current.end, range.end);
    } else {
      // Gap - push current and start new block
      merged.push(current);
      current = { ...range };
    }
  }

  // Push the last block
  merged.push(current);

  return merged;
}

export function ItemsDensityOverlay({
  items,
  timelineStart,
  timelineEnd,
  height,
  tracks,
  selectedItemKey,
}: ItemsDensityOverlayProps) {
  // Get selected track indices from REAPER's track selection
  const selectedTrackIndices = useMemo(() => {
    return Object.values(tracks)
      .filter(isSelected)
      .map((t) => t.index);
  }, [tracks]);

  // Filter items based on track selection:
  // - 0 selected = show all items
  // - 1+ selected = show only items from selected tracks
  const filteredItems = useMemo(() => {
    if (selectedTrackIndices.length === 0) return items;
    const selectedSet = new Set(selectedTrackIndices);
    return items.filter((item) => selectedSet.has(item.trackIdx));
  }, [items, selectedTrackIndices]);

  // Merge filtered items into contiguous blocks
  const blocks = useMemo(() => mergeItemRanges(filteredItems), [filteredItems]);

  // Get block color:
  // - 0 selected = default color
  // - 1 selected = that track's color
  // - 2+ selected = default color
  const blockColor = useMemo(() => {
    if (selectedTrackIndices.length !== 1) return DEFAULT_BLOCK_COLOR;
    const track = tracks[selectedTrackIndices[0]];
    if (!track || !track.color) return DEFAULT_BLOCK_COLOR;
    // Use track color at 50% opacity
    return reaperColorToRgba(track.color, 0.5) ?? DEFAULT_BLOCK_COLOR;
  }, [selectedTrackIndices, tracks]);

  // Filter to blocks that overlap with the visible timeline
  const visibleBlocks = useMemo(() => {
    const duration = timelineEnd - timelineStart;
    if (duration <= 0) return [];

    return blocks
      .filter((block) => block.end > timelineStart && block.start < timelineEnd)
      .map((block) => {
        // Clamp to timeline bounds and convert to percentages
        const clampedStart = Math.max(block.start, timelineStart);
        const clampedEnd = Math.min(block.end, timelineEnd);

        return {
          leftPercent: ((clampedStart - timelineStart) / duration) * 100,
          widthPercent: ((clampedEnd - clampedStart) / duration) * 100,
        };
      });
  }, [blocks, timelineStart, timelineEnd]);

  // Find selected item and calculate its position
  const selectedItemBlock = useMemo(() => {
    if (!selectedItemKey) return null;

    const selectedItem = filteredItems.find(
      (item) => `${item.trackIdx}:${item.itemIdx}` === selectedItemKey
    );

    if (!selectedItem) return null;

    const duration = timelineEnd - timelineStart;
    if (duration <= 0) return null;

    const itemStart = selectedItem.position;
    const itemEnd = selectedItem.position + selectedItem.length;

    // Check if item is in visible range
    if (itemEnd < timelineStart || itemStart > timelineEnd) return null;

    // Clamp to timeline bounds and convert to percentages
    const clampedStart = Math.max(itemStart, timelineStart);
    const clampedEnd = Math.min(itemEnd, timelineEnd);

    return {
      leftPercent: ((clampedStart - timelineStart) / duration) * 100,
      widthPercent: ((clampedEnd - clampedStart) / duration) * 100,
    };
  }, [selectedItemKey, filteredItems, timelineStart, timelineEnd]);

  if (visibleBlocks.length === 0 && !selectedItemBlock) return null;

  // 25% of container height, centered vertically
  const blobHeight = height * 0.25;
  const topOffset = (height - blobHeight) / 2;

  return (
    <div
      data-testid="item-density-overlay"
      className="absolute inset-0 z-0 pointer-events-none"
    >
      {/* Regular merged blocks */}
      {visibleBlocks.map((block, i) => (
        <div
          key={i}
          className="absolute pointer-events-none"
          style={{
            left: `${block.leftPercent}%`,
            width: `${block.widthPercent}%`,
            top: `${topOffset}px`,
            height: `${blobHeight}px`,
            backgroundColor: blockColor,
          }}
        />
      ))}

      {/* Selected item highlight overlay */}
      {selectedItemBlock && (
        <div
          className="absolute pointer-events-none ring-2 ring-selection-overlay-border rounded-sm z-10"
          style={{
            left: `${selectedItemBlock.leftPercent}%`,
            width: `${selectedItemBlock.widthPercent}%`,
            top: `${topOffset}px`,
            height: `${blobHeight}px`,
            backgroundColor: blockColor,
          }}
        />
      )}
    </div>
  );
}
