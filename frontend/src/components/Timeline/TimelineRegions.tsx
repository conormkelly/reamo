/**
 * TimelineRegions Component
 * Renders region blocks in the timeline (both top bar labels and main blocks)
 *
 * KEY DESIGN: All region references use region.id (REAPER's markrgnidx),
 * NOT array indices. This ensures stability when server pushes updates.
 */

import type { ReactElement } from 'react';
import type { Region } from '../../core/types';
import type { DragType, PendingRegionChange, TimelineMode } from '../../store';
import { reaperColorToRgba } from '../../utils';
import { DEFAULT_REGION_COLOR_RGB } from '../../constants/colors';

/** Minimum pixel width for region label to show name text */
const REGION_LABEL_MIN_WIDTH_PX = 40;

export interface TimelineRegionsProps {
  /** Regions to display (with pending changes applied) */
  displayRegions: Region[];
  /** Current timeline mode */
  timelineMode: TimelineMode;
  /** Set of selected region IDs */
  selectedRegionIds: Set<number>;
  /** Pending changes by region ID */
  pendingChanges: Record<number, PendingRegionChange>;
  /** ID of region being dragged */
  draggedRegionId: number | null;
  /** Current drag type */
  regionDragType: DragType;
  /** Whether there are any pending changes */
  hasPendingChanges: () => boolean;
  /** Convert time to percentage position */
  renderTimeToPercent: (time: number) => number;
  /** Container width in pixels (for LOD calculations) */
  containerWidth?: number;
}

/**
 * Region labels in the top bar (color bar + name)
 */
export function TimelineRegionLabels({
  displayRegions,
  timelineMode,
  selectedRegionIds,
  pendingChanges,
  draggedRegionId,
  regionDragType,
  renderTimeToPercent,
  containerWidth,
}: Omit<TimelineRegionsProps, 'hasPendingChanges'>): ReactElement {
  return (
    <>
      {displayRegions.map((region) => {
        // Use region.id for all lookups - stable across server updates
        const regionId = region.id;
        const isSelected = timelineMode === 'regions' && selectedRegionIds.has(regionId);
        const isNewRegion = (region as { _isNew?: boolean })._isNew === true;
        const hasPending = pendingChanges[regionId] !== undefined;
        const isBeingDragged = draggedRegionId === regionId && regionDragType !== 'none';
        // New regions get white outline, modified existing get orange
        const pendingRingClass = isNewRegion ? 'ring-1 ring-inset ring-white' : hasPending ? 'ring-1 ring-inset ring-pending-ring' : '';

        // Get region color for stem borders
        const regionColor = region.color ? reaperColorToRgba(region.color, 1) ?? DEFAULT_REGION_COLOR_RGB : DEFAULT_REGION_COLOR_RGB;
        // Don't draw right border if another region starts at this region's end (REAPER only shows the new region's left edge)
        const hasAdjacentRegion = displayRegions.some(r => r.id !== region.id && Math.abs(r.start - region.end) < 0.001);
        // Don't draw right border in label area if another region overlaps (its start is before our end)
        // This prevents stems cutting through other region labels
        const hasOverlappingRegion = displayRegions.some(r => r.id !== region.id && r.start < region.end && r.end > region.end);
        const hideRightBorder = hasAdjacentRegion || hasOverlappingRegion;

        // Find earliest overlapping region that starts within this region's bounds
        // Text should clip at that boundary to avoid overwriting shorter regions
        const overlappingStarts = displayRegions
          .filter(r => r.id !== region.id && r.start > region.start && r.start < region.end)
          .map(r => r.start);
        const earliestOverlap = overlappingStarts.length > 0 ? Math.min(...overlappingStarts) : null;

        // Calculate effective text width (clipped at overlap boundary)
        const percentWidth = renderTimeToPercent(region.end) - renderTimeToPercent(region.start);
        const effectiveEnd = earliestOverlap ?? region.end;
        const effectivePercentWidth = renderTimeToPercent(effectiveEnd) - renderTimeToPercent(region.start);
        const effectivePixelWidth = containerWidth ? (effectivePercentWidth / 100) * containerWidth : Infinity;

        // LOD: hide name if effective (clipped) width is too narrow
        const showName = effectivePixelWidth >= REGION_LABEL_MIN_WIDTH_PX;

        // Calculate text max-width as percentage of parent (the region label div)
        const textMaxWidthPercent = earliestOverlap !== null
          ? ((earliestOverlap - region.start) / (region.end - region.start)) * 100
          : 100;

        return (
          <div
            key={`region-label-${region.id}`}
            data-testid="region-label"
            data-region-id={regionId}
            data-region-name={region.name}
            data-selected={isSelected || undefined}
            data-dragging={isBeingDragged || undefined}
            data-pending={hasPending || undefined}
            data-new={isNewRegion || undefined}
            className={`absolute top-0 bottom-0 border-l flex flex-col ${
              hideRightBorder ? '' : 'border-r'
            } ${
              isBeingDragged
                ? 'border-accent-region z-20 bg-bg-deep'
                : isSelected
                  ? 'border-accent-region z-10'
                  : ''
            } ${pendingRingClass}`}
            style={{
              left: `${renderTimeToPercent(region.start)}%`,
              width: `${percentWidth}%`,
              // Color stems with region color (overridden by selection/drag classes)
              borderLeftColor: isBeingDragged || isSelected ? undefined : regionColor,
              borderRightColor: isBeingDragged || isSelected ? undefined : hideRightBorder ? 'transparent' : regionColor,
            }}
          >
            {/* Color bar - 5px */}
            <div
              className="h-[5px] w-full"
              style={{ backgroundColor: region.color ? reaperColorToRgba(region.color, 1) ?? DEFAULT_REGION_COLOR_RGB : DEFAULT_REGION_COLOR_RGB }}
            />
            {/* Region name - clipped at next overlapping region boundary */}
            {showName && (
              <span
                className="block h-5 leading-5 px-1 text-[11px] text-white font-semibold truncate"
                style={textMaxWidthPercent < 100 ? { maxWidth: `${textMaxWidthPercent}%` } : undefined}
              >
                {region.name}
              </span>
            )}
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
  selectedRegionIds,
  pendingChanges,
  draggedRegionId,
  regionDragType,
  hasPendingChanges,
  renderTimeToPercent,
}: TimelineRegionsProps): ReactElement {
  return (
    <>
      {displayRegions.map((region) => {
        // Use region.id for all lookups - stable across server updates
        const regionId = region.id;
        const isSelected = timelineMode === 'regions' && selectedRegionIds.has(regionId);
        const isNewRegion = (region as { _isNew?: boolean })._isNew === true;
        const hasPending = pendingChanges[regionId] !== undefined;
        const isSingleSelection = isSelected && selectedRegionIds.size === 1;
        const isBeingDragged = draggedRegionId === regionId && regionDragType !== 'none';
        // New regions get white outline, modified existing get orange
        const pendingRingClass = isNewRegion ? 'ring-1 ring-inset ring-white' : hasPending ? 'ring-1 ring-inset ring-pending-ring' : '';

        // Get region color for stem borders
        const regionColor = region.color ? reaperColorToRgba(region.color, 1) ?? DEFAULT_REGION_COLOR_RGB : DEFAULT_REGION_COLOR_RGB;
        // Don't draw right border if another region starts at this region's end (REAPER only shows the new region's left edge)
        const hasAdjacentRegion = displayRegions.some(r => r.id !== region.id && Math.abs(r.start - region.end) < 0.001);

        return (
          <div
            key={`region-${region.id}`}
            data-testid="region-block"
            data-region-id={regionId}
            data-region-name={region.name}
            data-selected={isSelected || undefined}
            data-dragging={isBeingDragged || undefined}
            data-pending={hasPending || undefined}
            data-new={isNewRegion || undefined}
            className={`absolute top-0 bottom-0 border-l ${
              hasAdjacentRegion ? '' : 'border-r'
            } ${
              isBeingDragged
                ? 'border-accent-region bg-accent-region/50 z-20'
                : isSelected
                  ? 'border-accent-region bg-accent-region/30 z-10'
                  : ''
            } ${pendingRingClass}`}
            style={{
              left: `${renderTimeToPercent(region.start)}%`,
              width: `${renderTimeToPercent(region.end) - renderTimeToPercent(region.start)}%`,
              // Color stems with region color (overridden by selection/drag classes)
              borderLeftColor: isBeingDragged || isSelected ? undefined : regionColor,
              borderRightColor: isBeingDragged || isSelected ? undefined : hasAdjacentRegion ? 'transparent' : regionColor,
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
                  <div className="w-1.5 h-8 bg-accent-region rounded-r-sm" />
                </div>
                {/* Right edge handle */}
                <div
                  className="absolute right-0 top-0 bottom-0 w-5 cursor-ew-resize flex items-center justify-end"
                  style={{ touchAction: 'none' }}
                >
                  <div className="w-1.5 h-8 bg-accent-region rounded-l-sm" />
                </div>
              </>
            )}
          </div>
        );
      })}
    </>
  );
}
