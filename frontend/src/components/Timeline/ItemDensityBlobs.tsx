/**
 * ItemsDensityOverlay Component
 * Shows where items exist in the timeline as blocks
 *
 * View filter logic:
 * - No filter (viewFilterTrackIdx is null): All items shown as grey merged blocks
 * - Filter active: Only that track's items shown individually with their colors
 *   (other tracks' items are hidden entirely)
 */

import { useMemo } from 'react';
import type { WSItem } from '../../core/WebSocketTypes';
import type { Track } from '../../core/types';
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
  /** Track data for color lookup */
  tracks: Record<number, Track>;
  /** Track index to filter to (null = show all as grey aggregate) */
  viewFilterTrackIdx?: number | null;
}

/** A merged time range representing contiguous item coverage */
interface MergedBlock {
  start: number; // seconds
  end: number; // seconds
}

/** An individual item with position data for rendering */
interface VisibleItem {
  item: WSItem;
  leftPercent: number;
  widthPercent: number;
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

/**
 * Get item color with fallback to default
 */
function getItemColor(item: WSItem, opacity: number = 0.6): string {
  if (!item.color) return DEFAULT_BLOCK_COLOR;
  return reaperColorToRgba(item.color, opacity) ?? DEFAULT_BLOCK_COLOR;
}

export function ItemsDensityOverlay({
  items,
  timelineStart,
  timelineEnd,
  height,
  tracks: _tracks, // Reserved for future waveform integration
  viewFilterTrackIdx,
}: ItemsDensityOverlayProps) {
  // Check if filter is active
  const hasFilter = viewFilterTrackIdx !== null && viewFilterTrackIdx !== undefined;

  // Split items: filtered track items vs all items (for grey blocks when no filter)
  const { coloredTrackItems, greyBlockItems } = useMemo(() => {
    if (!hasFilter) {
      // No filter: show all items as grey merged blocks
      return { coloredTrackItems: [], greyBlockItems: items };
    }
    // Filter active: show only that track's items with colors, hide others
    const onTrack = items.filter((i) => i.trackIdx === viewFilterTrackIdx);
    return { coloredTrackItems: onTrack, greyBlockItems: [] };
  }, [items, hasFilter, viewFilterTrackIdx]);

  // Merge grey block items (only when no filter)
  const greyBlocks = useMemo(
    () => mergeItemRanges(greyBlockItems),
    [greyBlockItems]
  );

  // Calculate visible merged blocks (grey, when no filter)
  const visibleMergedBlocks = useMemo(() => {
    const duration = timelineEnd - timelineStart;
    if (duration <= 0) return [];

    return greyBlocks
      .filter((block: MergedBlock) => block.end > timelineStart && block.start < timelineEnd)
      .map((block: MergedBlock) => {
        const clampedStart = Math.max(block.start, timelineStart);
        const clampedEnd = Math.min(block.end, timelineEnd);
        return {
          leftPercent: ((clampedStart - timelineStart) / duration) * 100,
          widthPercent: ((clampedEnd - clampedStart) / duration) * 100,
        };
      });
  }, [greyBlocks, timelineStart, timelineEnd]);

  // Calculate visible individual items (for colored track)
  const visibleColoredItems = useMemo((): VisibleItem[] => {
    const duration = timelineEnd - timelineStart;
    if (duration <= 0) return [];

    return coloredTrackItems
      .filter((item) => {
        const itemEnd = item.position + item.length;
        return itemEnd > timelineStart && item.position < timelineEnd;
      })
      .map((item) => {
        const clampedStart = Math.max(item.position, timelineStart);
        const clampedEnd = Math.min(item.position + item.length, timelineEnd);
        return {
          item,
          leftPercent: ((clampedStart - timelineStart) / duration) * 100,
          widthPercent: ((clampedEnd - clampedStart) / duration) * 100,
        };
      });
  }, [coloredTrackItems, timelineStart, timelineEnd]);

  // Early return if nothing to render
  if (visibleMergedBlocks.length === 0 && visibleColoredItems.length === 0) {
    return null;
  }

  // 25% of container height, centered vertically
  const blobHeight = height * 0.25;
  const topOffset = (height - blobHeight) / 2;

  return (
    <div
      data-testid="item-density-overlay"
      className="absolute inset-0 z-0 pointer-events-none"
    >
      {/* Grey merged blocks (shown when no filter active) */}
      {visibleMergedBlocks.map((block, i) => (
        <div
          key={`merged-${i}`}
          data-testid={`aggregate-blob-${i}`}
          className="absolute pointer-events-none"
          style={{
            left: `${block.leftPercent}%`,
            width: `${block.widthPercent}%`,
            top: `${topOffset}px`,
            height: `${blobHeight}px`,
            backgroundColor: DEFAULT_BLOCK_COLOR,
          }}
        />
      ))}

      {/* Individual colored items on filtered track */}
      {visibleColoredItems.map((v) => (
        <div
          key={`item-${v.item.trackIdx}-${v.item.itemIdx}`}
          data-testid={`item-blob-${v.item.trackIdx}-${v.item.itemIdx}`}
          data-selected={v.item.selected}
          className="absolute pointer-events-none"
          style={{
            left: `${v.leftPercent}%`,
            width: `${v.widthPercent}%`,
            top: `${topOffset}px`,
            height: `${blobHeight}px`,
            backgroundColor: getItemColor(v.item),
            // Selected: blue inset squared border (no border-radius) - matches mixer track selection
            boxShadow: v.item.selected ? 'inset 0 0 0 2px var(--color-primary)' : 'none',
            zIndex: v.item.selected ? 10 : 0,
          }}
        />
      ))}
    </div>
  );
}
