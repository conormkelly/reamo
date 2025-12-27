/**
 * TimelineRegions Component
 * Renders region blocks in the timeline (both top bar labels and main blocks)
 */

import type { ReactElement } from 'react';
import type { Region } from '../../core/types';
import type { DragType, PendingRegionChange, TimelineMode } from '../../store';
import { reaperColorToRgba } from '../../utils';

// Default region color in REAPER (shown when color = 0) - #688585 as RGB
const DEFAULT_REGION_COLOR_RGB = 'rgb(104, 133, 133)';

export interface TimelineRegionsProps {
  /** Regions to display (with pending changes applied) */
  displayRegions: Region[];
  /** Current timeline mode */
  timelineMode: TimelineMode;
  /** Set of selected region pending keys */
  selectedPendingKeys: Set<number>;
  /** Pending changes by region index */
  pendingChanges: Record<number, PendingRegionChange>;
  /** Pending key of region being dragged */
  draggedPendingKey: number | null;
  /** Current drag type */
  regionDragType: DragType;
  /** Whether there are any pending changes */
  hasPendingChanges: () => boolean;
  /** Convert time to percentage position */
  renderTimeToPercent: (time: number) => number;
}

/**
 * Region labels in the top bar (color bar + name)
 */
export function TimelineRegionLabels({
  displayRegions,
  timelineMode,
  selectedPendingKeys,
  pendingChanges,
  draggedPendingKey,
  regionDragType,
  renderTimeToPercent,
}: Omit<TimelineRegionsProps, 'hasPendingChanges'>): ReactElement {
  return (
    <>
      {displayRegions.map((region, idx) => {
        // Use _pendingKey from display region metadata for selection/pending lookup
        // This is stable across drag preview reordering
        const pendingKey = (region as { _pendingKey?: number })._pendingKey ?? idx;
        const isSelected = timelineMode === 'regions' && selectedPendingKeys.has(pendingKey);
        const isNewRegion = (region as { _isNew?: boolean })._isNew === true;
        const hasPending = pendingChanges[pendingKey] !== undefined;
        const isBeingDragged = draggedPendingKey === pendingKey && regionDragType !== 'none';
        // New regions get white outline, modified existing get orange
        const pendingRingClass = isNewRegion ? 'ring-1 ring-inset ring-white' : hasPending ? 'ring-1 ring-inset ring-amber-400' : '';

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
              left: `${renderTimeToPercent(region.start)}%`,
              width: `${renderTimeToPercent(region.end) - renderTimeToPercent(region.start)}%`,
            }}
          >
            {/* Color bar - 5px */}
            <div
              className="h-[5px] w-full"
              style={{ backgroundColor: region.color ? reaperColorToRgba(region.color, 1) ?? DEFAULT_REGION_COLOR_RGB : DEFAULT_REGION_COLOR_RGB }}
            />
            {/* Region name */}
            <span className="h-5 flex items-center px-1 text-[11px] text-white font-semibold truncate">
              {region.name}
            </span>
          </div>
        );
      })}
    </>
  );
}

/**
 * Region blocks in the main timeline area
 */
export function TimelineRegionBlocks({
  displayRegions,
  timelineMode,
  selectedPendingKeys,
  pendingChanges,
  draggedPendingKey,
  regionDragType,
  hasPendingChanges,
  renderTimeToPercent,
}: TimelineRegionsProps): ReactElement {
  return (
    <>
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
              left: `${renderTimeToPercent(region.start)}%`,
              width: `${renderTimeToPercent(region.end) - renderTimeToPercent(region.start)}%`,
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
    </>
  );
}
