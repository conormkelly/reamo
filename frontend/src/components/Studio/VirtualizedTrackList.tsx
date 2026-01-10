/**
 * VirtualizedTrackList - Horizontally virtualized track list
 * Uses TanStack Virtual for efficient rendering of large track counts.
 * Only renders tracks in the viewport plus overscan buffer.
 */

import { useMemo, useEffect, useState, useCallback, type ReactElement } from 'react';
import { useVirtualizer } from '@tanstack/react-virtual';
import { useReaperStore } from '../../store';
import { EMPTY_TRACKS } from '../../store/stableRefs';
import { useReaper } from '../ReaperProvider';
import { useTrackSkeleton, type SkeletonTrackWithIndex } from '../../hooks/useTrackSkeleton';
import { useVirtualizedSubscription } from '../../hooks/useVirtualizedSubscription';
import { TrackStripWithMeter } from '../Track';

/** Track width in pixels (100px strip + 12px meter + 4px gap) */
const TRACK_WIDTH = 116;

/** DOM overscan - extra tracks to render for smooth scroll */
const OVERSCAN = 5;

export interface VirtualizedTrackListProps {
  /** Filter query string (empty = show all) */
  filter: string;
  /** Include master track in the virtualized list (default: false) */
  includeMaster?: boolean;
  /** Optional additional class name */
  className?: string;
}

export function VirtualizedTrackList({
  filter,
  includeMaster = false,
  className = '',
}: VirtualizedTrackListProps): ReactElement {
  const [scrollElement, setScrollElement] = useState<HTMLDivElement | null>(null);
  const { sendCommand } = useReaper();
  // Defensive selector with stable fallback - state can be undefined briefly on mobile during hydration
  const tracks = useReaperStore((state) => state?.tracks ?? EMPTY_TRACKS);
  const { totalTracks, filterByName } = useTrackSkeleton();

  // Ref callback to capture scroll element and trigger re-render for virtualizer
  const parentRef = useCallback((node: HTMLDivElement | null) => {
    setScrollElement(node);
  }, []);

  // Filter using skeleton (has ALL tracks)
  const filteredSkeleton = useMemo(() => {
    return filterByName(filter);
  }, [filterByName, filter]);

  // Determine what to virtualize
  const filterActive = !!filter.trim();

  // Get indices to virtualize
  const virtualItems = useMemo((): SkeletonTrackWithIndex[] => {
    if (!filterActive) {
      // No filter: create skeleton entries for tracks
      const startIndex = includeMaster ? 0 : 1;
      const count = includeMaster ? totalTracks + 1 : totalTracks;
      return Array.from({ length: count }, (_, i) => ({
        n: '',
        g: '',
        index: startIndex + i,
      }));
    } else {
      // Filter active: use filtered skeleton
      // When includeMaster, keep master; otherwise exclude it
      return includeMaster
        ? filteredSkeleton
        : filteredSkeleton.filter((t) => t.g !== 'master');
    }
  }, [filterActive, totalTracks, filteredSkeleton, includeMaster]);

  const trackCount = virtualItems.length;

  // Create virtualizer - use scrollElement state to ensure re-render when ref attached
  const virtualizer = useVirtualizer({
    count: trackCount,
    getScrollElement: () => scrollElement,
    estimateSize: () => TRACK_WIDTH,
    horizontal: true,
    overscan: OVERSCAN,
  });

  // Get visible item indices for subscription
  const visibleItems = virtualizer.getVirtualItems();
  const visibleStart = visibleItems[0]?.index ?? 0;
  const visibleEnd = visibleItems[visibleItems.length - 1]?.index ?? 0;

  // Subscribe to visible tracks (with buffer)
  // Pass actual filteredSkeleton (with GUIDs) for GUID mode subscriptions
  useVirtualizedSubscription({
    visibleStart,
    visibleEnd,
    totalTracks,
    filteredSkeleton,
    filterActive,
    includeMaster,
    sendCommand,
  });

  // Reset scroll position when filter changes
  useEffect(() => {
    virtualizer.scrollToIndex(0);
  }, [filter, virtualizer]);

  // Get track index from virtual item index
  const getTrackIndex = (virtualIndex: number): number => {
    const item = virtualItems[virtualIndex];
    return item?.index ?? virtualIndex + 1;
  };

  // Check if we have track data for an index
  const hasTrackData = (trackIndex: number): boolean => {
    return !!tracks[trackIndex];
  };

  // Empty states
  const hasUserTracks = totalTracks > 0;

  if (!hasUserTracks) {
    return (
      <div className={`text-text-muted p-4 ${className}`}>No tracks in project</div>
    );
  }

  if (filterActive && trackCount === 0) {
    return (
      <div className={`text-text-muted p-4 ${className}`}>No matching tracks</div>
    );
  }

  // Horizontal virtualization using flex + spacers
  // This keeps items in normal document flow so height works naturally
  const firstItem = visibleItems[0];
  const lastItem = visibleItems[visibleItems.length - 1];
  const leftPad = firstItem?.start ?? 0;
  const rightPad = Math.max(0, virtualizer.getTotalSize() - (lastItem?.end ?? 0));

  return (
    <div
      ref={parentRef}
      className={`overflow-x-auto flex-1 ${className}`}
    >
      <div className="flex gap-2">
        {/* Left spacer for scroll positioning */}
        {leftPad > 0 && <div style={{ width: leftPad, flexShrink: 0 }} />}

        {/* Visible tracks - in normal flow so height is natural */}
        {visibleItems.map((virtualItem) => {
          const trackIndex = getTrackIndex(virtualItem.index);
          const hasData = hasTrackData(trackIndex);

          return (
            <div
              key={virtualItem.key}
              className="flex-shrink-0"
              style={{ width: TRACK_WIDTH }}
            >
              {hasData ? (
                <TrackStripWithMeter trackIndex={trackIndex} />
              ) : (
                // Placeholder while loading - matches TrackStripWithMeter structure
                <div className="flex gap-1 flex-shrink-0">
                  <div className="w-[12px] h-[200px] bg-bg-surface/50 rounded" />
                  <div className="w-[100px] bg-bg-surface/50 rounded-lg animate-pulse" />
                </div>
              )}
            </div>
          );
        })}

        {/* Right spacer for total scroll width */}
        {rightPad > 0 && <div style={{ width: rightPad, flexShrink: 0 }} />}
      </div>
    </div>
  );
}
