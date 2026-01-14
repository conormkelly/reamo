/**
 * MultiSelectInfoBar Component
 * Shows compact summary when 2+ items are selected, with details button for bottom sheet
 */

import { useState, useMemo, useCallback, type ReactElement } from 'react';
import { X, ChevronRight } from 'lucide-react';
import { BottomSheet } from '../Modal/BottomSheet';
import { useReaperStore } from '../../store';
import { useReaper } from '../ReaperProvider';
import { useTimeFormatters } from '../../hooks';
import { item as itemCmd } from '../../core/WebSocketCommands';
import { EMPTY_SKELETON } from '../../store/stableRefs';
import type { SkeletonTrack, WSItem } from '../../core/WebSocketTypes';

export interface MultiSelectInfoBarProps {
  /** Selected items (must be 2+ items) */
  selectedItems: WSItem[];
  className?: string;
}

/** Group items by track */
interface TrackGroup {
  trackIdx: number;
  trackName: string;
  items: WSItem[];
}

export function MultiSelectInfoBar({
  selectedItems,
  className = '',
}: MultiSelectInfoBarProps): ReactElement {
  const { sendCommand } = useReaper();
  const { formatBeats, formatDuration } = useTimeFormatters();
  const trackSkeleton = useReaperStore((s) => s?.trackSkeleton ?? EMPTY_SKELETON) as readonly SkeletonTrack[];

  const [showSheet, setShowSheet] = useState(false);

  // Group items by track
  const groupedByTrack = useMemo((): TrackGroup[] => {
    const groups = new Map<number, WSItem[]>();

    for (const item of selectedItems) {
      const existing = groups.get(item.trackIdx) ?? [];
      existing.push(item);
      groups.set(item.trackIdx, existing);
    }

    // Sort by track index, items by position within each track
    return Array.from(groups.entries())
      .sort(([a], [b]) => a - b)
      .map(([trackIdx, items]) => ({
        trackIdx,
        trackName: trackSkeleton[trackIdx]?.n ?? `Track ${trackIdx + 1}`,
        items: items.sort((a, b) => a.position - b.position),
      }));
  }, [selectedItems, trackSkeleton]);

  // Calculate summary stats
  const totalDuration = useMemo(() => {
    return selectedItems.reduce((sum, item) => sum + item.length, 0);
  }, [selectedItems]);

  const trackCount = groupedByTrack.length;

  // Clear all selection
  const handleClearAll = useCallback(() => {
    sendCommand(itemCmd.unselectAll());
    setShowSheet(false);
  }, [sendCommand]);

  // Deselect single item
  const handleDeselectItem = useCallback(
    (item: WSItem) => {
      sendCommand(itemCmd.toggleSelect(item.guid));
    },
    [sendCommand]
  );

  return (
    <>
      {/* Compact bar */}
      <div
        data-testid="multi-select-info-bar"
        className={`flex items-center justify-between px-3 py-2 bg-bg-surface/50 rounded-lg ${className}`}
      >
        <div className="flex items-center gap-3">
          {/* Clear button */}
          <button
            onClick={handleClearAll}
            className="p-1 rounded hover:bg-bg-hover text-text-muted hover:text-text-primary transition-colors"
            title="Clear selection"
          >
            <X className="w-4 h-4" />
          </button>

          {/* Count */}
          <span className="text-sm text-text-primary font-medium">
            {selectedItems.length} items selected
          </span>

          {/* Track count hint */}
          {trackCount > 1 && (
            <span className="text-xs text-text-muted">
              across {trackCount} tracks
            </span>
          )}
        </div>

        {/* Details button */}
        <button
          onClick={() => setShowSheet(true)}
          className="flex items-center gap-1 px-2 py-1 rounded bg-bg-elevated hover:bg-bg-hover text-text-secondary hover:text-text-primary text-xs transition-colors"
        >
          Details
          <ChevronRight className="w-3 h-3" />
        </button>
      </div>

      {/* Details bottom sheet */}
      <BottomSheet
        isOpen={showSheet}
        onClose={() => setShowSheet(false)}
        ariaLabel="Selected items"
      >
        <div className="px-4 pb-6">
          {/* Header */}
          <div className="text-center mb-4 pt-1">
            <h2 className="text-lg font-semibold text-text-primary">
              {selectedItems.length} Items Selected
            </h2>
            <p className="text-sm text-text-secondary">
              {formatDuration(totalDuration)} total
              {trackCount > 1 && ` across ${trackCount} tracks`}
            </p>
          </div>

          {/* Items grouped by track */}
          <div className="space-y-4 max-h-[60vh] overflow-y-auto">
            {groupedByTrack.map((group) => (
              <div key={group.trackIdx}>
                {/* Track header */}
                <div className="flex items-center gap-2 mb-2">
                  <span className="text-xs font-medium text-text-muted uppercase tracking-wide">
                    {group.trackName}
                  </span>
                  <span className="text-xs text-text-tertiary">
                    ({group.items.length})
                  </span>
                </div>

                {/* Items on this track */}
                <div className="space-y-1">
                  {group.items.map((item) => (
                    <button
                      key={item.guid}
                      onClick={() => handleDeselectItem(item)}
                      className="w-full flex items-center justify-between px-3 py-2 rounded-lg bg-bg-surface hover:bg-bg-hover text-left transition-colors group"
                    >
                      <div className="flex-1 min-w-0">
                        {/* Item index */}
                        <div className="text-sm text-text-primary truncate">
                          Item {item.itemIdx + 1}
                        </div>
                        {/* Position and duration */}
                        <div className="text-xs text-text-muted font-mono">
                          {formatBeats(item.position)} · {formatDuration(item.length)}
                        </div>
                      </div>
                      {/* Deselect hint */}
                      <div className="ml-2 text-xs text-text-tertiary group-hover:text-text-secondary">
                        <X className="w-4 h-4" />
                      </div>
                    </button>
                  ))}
                </div>
              </div>
            ))}
          </div>

          {/* Clear all button */}
          <button
            onClick={handleClearAll}
            className="w-full mt-4 px-4 py-3 rounded-lg bg-error-bg hover:bg-error/30 text-error-text text-sm font-medium transition-colors"
          >
            Clear Selection
          </button>
        </div>
      </BottomSheet>
    </>
  );
}
