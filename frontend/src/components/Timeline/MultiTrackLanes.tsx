/**
 * MultiTrackLanes Component
 * Renders multiple track lanes showing items across several tracks simultaneously.
 *
 * Part of Timeline View Phase 2: Multi-Track Lanes
 * Shows 4-8 tracks as horizontal lanes with items positioned by time.
 *
 * This is a thin wrapper that renders ItemsDensityOverlay for each track lane,
 * reusing the battle-tested item positioning logic from ItemsDensityOverlay.
 *
 * Features:
 * - Full-width lanes (no labels - horizontal space is precious on mobile)
 * - Items colored by their item/track color
 * - Selected items highlighted with blue border
 * - Focused track highlighted with subtle background
 *
 * Note: Items are pointer-events-none. Click handling is done at the Timeline
 * level via hit-testing (same pattern as single-track mode).
 */

import { useMemo, type ReactElement } from 'react';
import type { WSItem, SkeletonTrack } from '../../core/WebSocketTypes';
import { reaperColorToRgba } from '../../utils';

// Default item color when no color set - matches ItemsDensityOverlay
const DEFAULT_ITEM_COLOR = 'rgba(129, 137, 137, 0.6)';

export interface MultiTrackLanesProps {
  /** Track skeleton entries to display as lanes (ordered) */
  tracks: SkeletonTrack[];
  /** Track indices corresponding to tracks (1-based, from bank navigation) */
  trackIndices: number[];
  /** All items in the project */
  items: WSItem[];
  /** Timeline start time in seconds */
  timelineStart: number;
  /** Timeline end time in seconds */
  timelineEnd: number;
  /** Total height available for lanes */
  height: number;
  /** Currently focused track GUID (shows highlight) */
  focusedTrackGuid?: string | null;
}

/** Get item color with fallback - same logic as ItemsDensityOverlay */
function getItemColor(item: WSItem, opacity: number = 0.6): string {
  if (!item.color) return DEFAULT_ITEM_COLOR;
  return reaperColorToRgba(item.color, opacity) ?? DEFAULT_ITEM_COLOR;
}

/** An individual item with position data for rendering */
interface VisibleItem {
  item: WSItem;
  leftPercent: number;
  widthPercent: number;
}

export function MultiTrackLanes({
  tracks,
  trackIndices,
  items,
  timelineStart,
  timelineEnd,
  height,
  focusedTrackGuid,
}: MultiTrackLanesProps): ReactElement | null {
  // Group items by trackIdx for efficient lookup
  const itemsByTrack = useMemo(() => {
    const map = new Map<number, WSItem[]>();
    for (const item of items) {
      const existing = map.get(item.trackIdx);
      if (existing) {
        existing.push(item);
      } else {
        map.set(item.trackIdx, [item]);
      }
    }
    return map;
  }, [items]);

  // Calculate lane dimensions
  const laneCount = tracks.length;
  if (laneCount === 0) return null;

  const laneHeight = height / laneCount;
  const duration = timelineEnd - timelineStart;

  // Item sizing within each lane - 60% of lane height, centered
  // (Proportionally similar to single-track's 25% of full height)
  const itemHeightPercent = 60;

  return (
    <div
      data-testid="multi-track-lanes"
      className="absolute inset-0 pointer-events-none"
      style={{ height }}
    >
      {tracks.map((track, laneIdx) => {
        // Use passed track indices directly (slot-based for sequential banks)
        const trackIdx = trackIndices[laneIdx];
        if (trackIdx === undefined) return null; // Skip if index not available
        const trackItems = itemsByTrack.get(trackIdx) ?? [];
        const isFocused = focusedTrackGuid === track.g;

        // Calculate visible items for this track
        // Uses same clamping logic as ItemsDensityOverlay
        const visibleItems: VisibleItem[] = duration <= 0 ? [] : trackItems
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

        // Calculate item vertical position within lane (centered)
        const itemTopPercent = (100 - itemHeightPercent) / 2;

        return (
          <div
            key={track.g}
            data-testid={`track-lane-${trackIdx}`}
            className={`
              absolute left-0 right-0 border-b border-border-subtle/30
              ${isFocused ? 'bg-primary/10' : ''}
            `}
            style={{
              top: laneIdx * laneHeight,
              height: laneHeight,
            }}
          >
            {/* Items - same rendering as ItemsDensityOverlay */}
            {visibleItems.map((v) => (
              <div
                key={`item-${v.item.trackIdx}-${v.item.itemIdx}`}
                data-testid={`lane-item-${v.item.trackIdx}-${v.item.itemIdx}`}
                data-selected={v.item.selected}
                className="absolute pointer-events-none"
                style={{
                  left: `${v.leftPercent}%`,
                  width: `${v.widthPercent}%`,
                  top: `${itemTopPercent}%`,
                  height: `${itemHeightPercent}%`,
                  backgroundColor: getItemColor(v.item),
                  // Selected: blue inset squared border - matches ItemsDensityOverlay
                  boxShadow: v.item.selected ? 'inset 0 0 0 2px var(--color-primary)' : 'none',
                  zIndex: v.item.selected ? 10 : 0,
                }}
              />
            ))}
          </div>
        );
      })}
    </div>
  );
}
