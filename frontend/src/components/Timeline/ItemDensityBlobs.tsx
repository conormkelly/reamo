/**
 * ItemsDensityOverlay Component
 * Shows where items exist in the timeline as blocks
 *
 * Coloring logic (based on item selection, NOT track selection):
 * - No item selected: All items shown as grey merged blocks
 * - Item selected: Items on that track shown individually with their colors,
 *   items on other tracks shown as grey merged blocks
 */

import { useMemo } from 'react';
import type { WSItem } from '../../core/WebSocketTypes';
import type { Track } from '../../core/types';
import { reaperColorToRgba } from '../../utils';
import { parseItemKey } from '../../store/slices/itemsSlice';

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
  /** Currently selected item key (trackIdx:itemIdx) */
  selectedItemKey?: string | null;
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
  selectedItemKey,
}: ItemsDensityOverlayProps) {
  // Derive colored track from selected item (NOT from REAPER track selection)
  const coloredTrackIdx = useMemo(() => {
    if (!selectedItemKey) return null;
    const parsed = parseItemKey(selectedItemKey);
    return parsed?.trackIdx ?? null;
  }, [selectedItemKey]);

  // Split items: colored track items vs other track items
  const { coloredTrackItems, otherTrackItems } = useMemo(() => {
    if (coloredTrackIdx === null) {
      return { coloredTrackItems: [], otherTrackItems: items };
    }
    const onTrack = items.filter((i) => i.trackIdx === coloredTrackIdx);
    const offTrack = items.filter((i) => i.trackIdx !== coloredTrackIdx);
    return { coloredTrackItems: onTrack, otherTrackItems: offTrack };
  }, [items, coloredTrackIdx]);

  // Merge other track items into grey blocks
  const otherTrackBlocks = useMemo(
    () => mergeItemRanges(otherTrackItems),
    [otherTrackItems]
  );

  // Calculate visible merged blocks (for other tracks)
  const visibleMergedBlocks = useMemo(() => {
    const duration = timelineEnd - timelineStart;
    if (duration <= 0) return [];

    return otherTrackBlocks
      .filter((block) => block.end > timelineStart && block.start < timelineEnd)
      .map((block) => {
        const clampedStart = Math.max(block.start, timelineStart);
        const clampedEnd = Math.min(block.end, timelineEnd);
        return {
          leftPercent: ((clampedStart - timelineStart) / duration) * 100,
          widthPercent: ((clampedEnd - clampedStart) / duration) * 100,
        };
      });
  }, [otherTrackBlocks, timelineStart, timelineEnd]);

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
      {/* Grey merged blocks for items on OTHER tracks */}
      {visibleMergedBlocks.map((block, i) => (
        <div
          key={`merged-${i}`}
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

      {/* Individual colored items on selected track */}
      {visibleColoredItems.map((v) => {
        const isSelected =
          selectedItemKey === `${v.item.trackIdx}:${v.item.itemIdx}`;
        return (
          <div
            key={`item-${v.item.trackIdx}-${v.item.itemIdx}`}
            className={`absolute pointer-events-none ${
              isSelected ? 'ring-2 ring-selection-overlay-border rounded-sm z-10' : ''
            }`}
            style={{
              left: `${v.leftPercent}%`,
              width: `${v.widthPercent}%`,
              top: `${topOffset}px`,
              height: `${blobHeight}px`,
              backgroundColor: getItemColor(v.item),
            }}
          />
        );
      })}
    </div>
  );
}
