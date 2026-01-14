/**
 * ItemsTimeline Component
 * High LOD view for Items mode - shows detailed waveforms on a single track
 *
 * Viewport-aware: uses shared viewport from TimelineSection so zoom/pan in
 * navigate mode carries over to items mode.
 */

import { useState, useMemo, useCallback, type ReactElement } from 'react';
import { useReaperStore } from '../../store';
import { EMPTY_ITEMS, EMPTY_TRACKS, EMPTY_REGIONS } from '../../store/stableRefs';
import { useVisibleMediaItems, useTimeSignature, type TimeRange } from '../../hooks';
import type { WSItem } from '../../core/WebSocketTypes';
import type { TimeSelection } from '../../store/slices/transportSlice';
import { reaperColorToRgba } from '../../utils';
import { WaveformItem } from './WaveformItem';
import { ItemInfoBar } from './ItemInfoBar';

/** Filter modes for items display */
type ItemFilterMode = 'viewport' | 'timeSelection' | 'all';

/** Buffer in seconds beyond visible range (prevents popping during pan) */
const VISIBILITY_BUFFER = 10;

/** Height of the region color bar at top */
const REGION_BAR_HEIGHT = 12;

/** Default region color when none set */
const DEFAULT_REGION_COLOR = 'rgba(128, 90, 213, 0.6)';

export interface ItemsTimelineProps {
  /** Visible time range from shared viewport */
  visibleRange: TimeRange;
  /** Time-to-percent conversion function from viewport (used in viewport mode) */
  timeToPercent: (time: number) => number;
  /** Current REAPER time selection (for timeSelection filter mode) */
  timeSelection?: TimeSelection | null;
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
  visibleRange,
  timeToPercent: viewportTimeToPercent,
  timeSelection,
  height = 80,
}: ItemsTimelineProps): ReactElement {
  // Store state - defensive selectors with stable fallbacks for mobile hydration
  const items = useReaperStore((state) => state?.items ?? EMPTY_ITEMS);
  const tracks = useReaperStore((state) => state?.tracks ?? EMPTY_TRACKS);
  const regions = useReaperStore((state) => state?.regions ?? EMPTY_REGIONS);
  const bpm = useReaperStore((state) => state.bpm ?? 120);
  const selectedTrackIdx = useReaperStore((state) => state.selectedTrackIdx);
  const setSelectedTrack = useReaperStore((state) => state.setSelectedTrack);
  const selectedItemGuid = useReaperStore((state) => state.selectedItemGuid);
  const selectItem = useReaperStore((state) => state.selectItem);
  const clearItemSelection = useReaperStore((state) => state.clearItemSelection);

  // Time signature for beat grid
  const { beatsPerBar } = useTimeSignature();

  // Filter mode state
  const [filterMode, setFilterMode] = useState<ItemFilterMode>('viewport');

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

  // Compute display range based on filter mode
  // This is the range used for positioning items AND what we show
  const displayRange = useMemo((): TimeRange => {
    switch (filterMode) {
      case 'viewport':
        return visibleRange;
      case 'timeSelection':
        if (timeSelection && timeSelection.endSeconds > timeSelection.startSeconds) {
          return { start: timeSelection.startSeconds, end: timeSelection.endSeconds };
        }
        // Fall back to viewport if no time selection
        return visibleRange;
      case 'all': {
        // Compute bounds from all items on track
        if (trackItems.length === 0) {
          return { start: 0, end: 60 };
        }
        const minPos = Math.min(...trackItems.map((i) => i.position));
        const maxEnd = Math.max(...trackItems.map((i) => i.position + i.length));
        const duration = maxEnd - minPos;
        const padding = duration * 0.05;
        return {
          start: Math.max(0, minPos - padding),
          end: maxEnd + padding,
        };
      }
    }
  }, [filterMode, visibleRange, timeSelection, trackItems]);

  // Time-to-percent conversion based on display range
  const timeToPercent = useCallback(
    (time: number): number => {
      if (filterMode === 'viewport') {
        return viewportTimeToPercent(time);
      }
      const duration = displayRange.end - displayRange.start;
      if (duration <= 0) return 0;
      return ((time - displayRange.start) / duration) * 100;
    },
    [filterMode, viewportTimeToPercent, displayRange]
  );

  // Filter items to display range
  const { visibleItems: filteredItems } = useVisibleMediaItems(
    trackItems,
    displayRange,
    filterMode === 'all' ? 0 : VISIBILITY_BUFFER
  );

  // Regions overlapping the display range (for context bar)
  const visibleRegions = useMemo(() => {
    return regions.filter(
      (r) => r.end > displayRange.start && r.start < displayRange.end
    );
  }, [regions, displayRange]);

  // Beat grid lines
  const beatLines = useMemo(() => {
    const lines: { position: number; isBar: boolean }[] = [];
    const secondsPerBeat = 60 / bpm;
    const displayDuration = displayRange.end - displayRange.start;

    // Calculate appropriate density based on zoom level
    // At high zoom, show individual beats; at low zoom, only bars
    const beatsVisible = displayDuration / secondsPerBeat;
    const showBeats = beatsVisible < 64; // Only show beats if < 64 visible

    // Start from the nearest bar before displayRange.start
    const firstBeat = Math.floor(displayRange.start / secondsPerBeat);
    const lastBeat = Math.ceil(displayRange.end / secondsPerBeat);

    for (let beat = firstBeat; beat <= lastBeat; beat++) {
      const time = beat * secondsPerBeat;
      if (time < displayRange.start || time > displayRange.end) continue;

      const isBar = beat % beatsPerBar === 0;
      if (showBeats || isBar) {
        lines.push({ position: time, isBar });
      }
    }

    return lines;
  }, [bpm, beatsPerBar, displayRange]);

  // Selected item
  const selectedItem = useMemo(() => {
    if (!selectedItemGuid) return null;
    return trackItems.find((item) => item.guid === selectedItemGuid) ?? null;
  }, [trackItems, selectedItemGuid]);

  // Handle track selection change
  const handleTrackChange = useCallback(
    (e: React.ChangeEvent<HTMLSelectElement>) => {
      const trackIdx = parseInt(e.target.value, 10);
      setSelectedTrack(trackIdx);
      clearItemSelection();
    },
    [setSelectedTrack, clearItemSelection]
  );

  // Handle filter mode change
  const handleFilterModeChange = useCallback(
    (e: React.ChangeEvent<HTMLSelectElement>) => {
      setFilterMode(e.target.value as ItemFilterMode);
    },
    []
  );

  // Handle item click
  const handleItemClick = useCallback(
    (item: WSItem) => {
      selectItem(item.guid);
    },
    [selectItem]
  );

  // Check if time selection filter is disabled (no selection exists)
  const timeSelectionDisabled = !timeSelection || timeSelection.endSeconds <= timeSelection.startSeconds;

  // Items area height (total minus region bar)
  const itemsAreaHeight = height - REGION_BAR_HEIGHT;

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
      {/* Track selector and filter mode */}
      <div className="flex items-center gap-2 px-2 py-1.5 bg-bg-surface rounded-t border border-border-subtle">
        <label className="text-xs text-text-secondary">Track:</label>
        <select
          value={activeTrackIdx ?? ''}
          onChange={handleTrackChange}
          className="flex-1 bg-bg-elevated text-text-primary text-sm rounded px-2 py-1 border border-border-default focus:border-success focus:outline-none min-w-0"
        >
          {tracksWithItems.map((track) => (
            <option key={track.trackIdx} value={track.trackIdx}>
              {track.name} ({track.itemCount} item{track.itemCount !== 1 ? 's' : ''})
            </option>
          ))}
        </select>

        <label className="text-xs text-text-secondary ml-2">Show:</label>
        <select
          value={filterMode}
          onChange={handleFilterModeChange}
          className="bg-bg-elevated text-text-primary text-sm rounded px-2 py-1 border border-border-default focus:border-success focus:outline-none"
        >
          <option value="viewport">Visible Range</option>
          <option value="timeSelection" disabled={timeSelectionDisabled}>
            Time Selection{timeSelectionDisabled ? ' (none)' : ''}
          </option>
          <option value="all">All Items</option>
        </select>
      </div>

      {/* Region color bar (thin context strip) */}
      <div
        className="relative bg-bg-elevated border-x border-border-subtle overflow-hidden"
        style={{ height: `${REGION_BAR_HEIGHT}px` }}
      >
        {visibleRegions.map((region) => {
          const leftPercent = timeToPercent(region.start);
          const rightPercent = timeToPercent(region.end);
          const widthPercent = rightPercent - leftPercent;
          const color = region.color
            ? reaperColorToRgba(region.color, 0.8) ?? DEFAULT_REGION_COLOR
            : DEFAULT_REGION_COLOR;

          return (
            <div
              key={region.id}
              className="absolute top-0 bottom-0"
              style={{
                left: `${leftPercent}%`,
                width: `${widthPercent}%`,
                backgroundColor: color,
              }}
            />
          );
        })}
      </div>

      {/* Items area with beat grid */}
      <div
        className="relative bg-bg-deep border-x border-border-subtle overflow-hidden"
        style={{ height: `${itemsAreaHeight}px` }}
      >
        {/* Beat grid lines */}
        {beatLines.map(({ position, isBar }, idx) => (
          <div
            key={idx}
            className="absolute top-0 bottom-0 pointer-events-none"
            style={{
              left: `${timeToPercent(position)}%`,
              width: '1px',
              backgroundColor: isBar
                ? 'rgba(255, 255, 255, 0.15)'
                : 'rgba(255, 255, 255, 0.06)',
            }}
          />
        ))}

        {/* Items */}
        {filteredItems.length === 0 ? (
          <div className="flex items-center justify-center h-full text-text-muted text-sm">
            {trackItems.length === 0
              ? 'No items on this track'
              : filterMode === 'viewport'
                ? 'No items in visible range'
                : filterMode === 'timeSelection'
                  ? 'No items in time selection'
                  : 'No items'}
          </div>
        ) : (
          filteredItems.map((item) => (
            <WaveformItem
              key={item.guid}
              item={item}
              isSelected={selectedItemGuid === item.guid}
              timeToPercent={timeToPercent}
              height={itemsAreaHeight}
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
          <div className="text-xs text-text-muted flex justify-between">
            <span>Tap an item to select it</span>
            <span className="text-text-tertiary">
              {filteredItems.length}/{trackItems.length} items
            </span>
          </div>
        )}
      </div>
    </div>
  );
}
