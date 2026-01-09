/**
 * ItemsTimeline Component
 * High LOD view for Items mode - shows detailed waveforms on a single track
 */

import { useMemo, useCallback, type ReactElement } from 'react';
import { useReaperStore } from '../../store';
import { EMPTY_ITEMS, EMPTY_TRACKS } from '../../store/stableRefs';
import type { WSItem } from '../../core/WebSocketTypes';
import { WaveformItem } from './WaveformItem';
import { ItemInfoBar } from './ItemInfoBar';

export interface ItemsTimelineProps {
  /** Start of visible timeline in seconds (hint, actual bounds come from items) */
  timelineStart: number;
  /** End of visible timeline in seconds (hint, actual bounds come from items) */
  timelineEnd: number;
  /** Height of the timeline area in pixels */
  height?: number;
}

/**
 * Get all tracks that have items, sorted by track index
 */
function getTracksWithItems(
  items: WSItem[],
  tracks: Record<number, { index: number; name: string }>
): { trackIdx: number; name: string; itemCount: number }[] {
  const trackMap = new Map<number, number>();

  for (const item of items) {
    trackMap.set(item.trackIdx, (trackMap.get(item.trackIdx) ?? 0) + 1);
  }

  return Array.from(trackMap.entries())
    .map(([trackIdx, itemCount]) => ({
      trackIdx,
      name: tracks[trackIdx]?.name ?? `Track ${trackIdx + 1}`,
      itemCount,
    }))
    .sort((a, b) => a.trackIdx - b.trackIdx);
}

export function ItemsTimeline({
  height = 120,
}: ItemsTimelineProps): ReactElement {
  // Store state - defensive selectors with stable fallbacks for mobile hydration
  const items = useReaperStore((state) => state?.items ?? EMPTY_ITEMS);
  const tracks = useReaperStore((state) => state?.tracks ?? EMPTY_TRACKS);
  const selectedTrackIdx = useReaperStore((state) => state.selectedTrackIdx);
  const setSelectedTrack = useReaperStore((state) => state.setSelectedTrack);
  const selectedItemKey = useReaperStore((state) => state.selectedItemKey);
  const selectItem = useReaperStore((state) => state.selectItem);
  const clearItemSelection = useReaperStore((state) => state.clearItemSelection);

  // Get all tracks that have items
  const tracksWithItems = useMemo(
    () => getTracksWithItems(items, tracks),
    [items, tracks]
  );

  // Auto-select first track with items if none selected or selected is invalid
  const activeTrackIdx = useMemo(() => {
    if (selectedTrackIdx !== null) {
      // Verify the selected track still has items
      if (tracksWithItems.some((t) => t.trackIdx === selectedTrackIdx)) {
        return selectedTrackIdx;
      }
    }
    // Fall back to first track with items
    return tracksWithItems[0]?.trackIdx ?? null;
  }, [selectedTrackIdx, tracksWithItems]);

  // Items for the active track
  const trackItems = useMemo(() => {
    if (activeTrackIdx === null) return [];
    return items.filter((item) => item.trackIdx === activeTrackIdx);
  }, [items, activeTrackIdx]);

  // Compute timeline bounds from track items (with padding)
  const timelineBounds = useMemo(() => {
    if (trackItems.length === 0) {
      return { start: 0, end: 60 };
    }
    const minPos = Math.min(...trackItems.map((i) => i.position));
    const maxEnd = Math.max(...trackItems.map((i) => i.position + i.length));
    const duration = maxEnd - minPos;
    const padding = duration * 0.05; // 5% padding on each side
    return {
      start: Math.max(0, minPos - padding),
      end: maxEnd + padding,
    };
  }, [trackItems]);

  // Selected item
  const selectedItem = useMemo(() => {
    if (!selectedItemKey) return null;
    return trackItems.find(
      (item) => `${item.trackIdx}:${item.itemIdx}` === selectedItemKey
    ) ?? null;
  }, [trackItems, selectedItemKey]);

  // Handle track selection change
  const handleTrackChange = useCallback(
    (e: React.ChangeEvent<HTMLSelectElement>) => {
      const trackIdx = parseInt(e.target.value, 10);
      setSelectedTrack(trackIdx);
      clearItemSelection();
    },
    [setSelectedTrack, clearItemSelection]
  );

  // Handle item click
  const handleItemClick = useCallback(
    (item: WSItem) => {
      selectItem(item.trackIdx, item.itemIdx);
    },
    [selectItem]
  );

  // Convert time to percentage position
  const timeToPercent = useCallback(
    (time: number) => {
      const duration = timelineBounds.end - timelineBounds.start;
      if (duration <= 0) return 0;
      return ((time - timelineBounds.start) / duration) * 100;
    },
    [timelineBounds]
  );

  // No items case
  if (items.length === 0) {
    return (
      <div
        className="flex items-center justify-center bg-bg-deep rounded text-text-secondary text-sm"
        style={{ height: `${height}px` }}
      >
        No items in project
      </div>
    );
  }

  // No tracks with items (shouldn't happen if items.length > 0)
  if (tracksWithItems.length === 0) {
    return (
      <div
        className="flex items-center justify-center bg-bg-deep rounded text-text-secondary text-sm"
        style={{ height: `${height}px` }}
      >
        No tracks with items
      </div>
    );
  }

  return (
    <div className="flex flex-col">
      {/* Track selector */}
      <div className="flex items-center gap-2 px-2 py-1.5 bg-bg-surface rounded-t border border-border-subtle">
        <label className="text-xs text-text-secondary">Track:</label>
        <select
          value={activeTrackIdx ?? ''}
          onChange={handleTrackChange}
          className="flex-1 bg-bg-elevated text-text-primary text-sm rounded px-2 py-1 border border-border-default focus:border-success focus:outline-none"
        >
          {tracksWithItems.map((track) => (
            <option key={track.trackIdx} value={track.trackIdx}>
              {track.name} ({track.itemCount} item{track.itemCount !== 1 ? 's' : ''})
            </option>
          ))}
        </select>
      </div>

      {/* Items area */}
      <div
        className="relative bg-bg-deep border-x border-border-subtle"
        style={{ height: `${height}px` }}
      >
        {trackItems.length === 0 ? (
          <div className="flex items-center justify-center h-full text-text-muted text-sm">
            No items on this track
          </div>
        ) : (
          trackItems.map((item) => (
            <WaveformItem
              key={`${item.trackIdx}:${item.itemIdx}`}
              item={item}
              isSelected={selectedItemKey === `${item.trackIdx}:${item.itemIdx}`}
              timeToPercent={timeToPercent}
              height={height}
              onClick={() => handleItemClick(item)}
            />
          ))
        )}
      </div>

      {/* Item info bar */}
      <div className="bg-bg-surface rounded-b border border-t-0 border-border-subtle px-2 py-1.5">
        {selectedItem ? (
          <ItemInfoBar item={selectedItem} />
        ) : (
          <div className="text-xs text-text-muted">
            Tap an item to select it
          </div>
        )}
      </div>
    </div>
  );
}
