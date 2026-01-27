/**
 * Pure helper functions for computing region display state.
 *
 * These are extracted from regionEditSlice to allow components to call them
 * directly with explicit dependencies, satisfying ESLint's exhaustive-deps rule.
 *
 * The store methods (getDisplayRegions, getDragPreviewRegions) use these internally.
 */

import type { Region } from '../../core/types';
import type { PendingChangesRecord, DisplayRegion, DragType } from './regionEditSlice.types';
import { calculateDragPreview } from './regionEdit';

/**
 * Compute display regions by applying pending changes to the base regions.
 *
 * Pure function - all dependencies are explicit parameters.
 *
 * @param regions - Base regions from REAPER
 * @param pendingChanges - Local pending changes (keyed by region ID)
 * @returns Regions with pending changes applied, sorted by start time
 */
export function computeDisplayRegions(
  regions: Region[],
  pendingChanges: PendingChangesRecord
): DisplayRegion[] {
  const result: DisplayRegion[] = [];

  // Add existing regions, applying pending changes by region ID
  for (const region of regions) {
    const change = pendingChanges[region.id];
    if (change) {
      if (!change.isDeleted) {
        result.push({
          name: change.name,
          id: region.id,
          start: change.newStart,
          end: change.newEnd,
          color: change.color,
        });
      }
      // If deleted, don't add to result
    } else {
      // No pending change - show original
      result.push({ ...region });
    }
  }

  // Add new regions (negative keys)
  for (const key of Object.keys(pendingChanges)) {
    const numKey = parseInt(key, 10);
    if (numKey < 0) {
      const change = pendingChanges[numKey];
      if (change && change.isNew && !change.isDeleted) {
        result.push({
          name: change.name,
          id: numKey,
          start: change.newStart,
          end: change.newEnd,
          color: change.color,
          _isNew: true,
        });
      }
    }
  }

  return result.sort((a, b) => a.start - b.start);
}

/** Drag state required for preview calculation */
export interface DragState {
  dragType: DragType;
  dragRegionId: number | null;
  dragStartTime: number | null;
  dragCurrentTime: number | null;
}

/** Result of drag preview calculation */
export interface DragPreviewResult {
  regions: Region[];
  insertionPoint: number | null;
  resizeEdgePosition: number | null;
}

/**
 * Compute drag preview regions showing where the dragged region will end up.
 *
 * Pure function - all dependencies are explicit parameters.
 *
 * @param regions - Base regions from REAPER
 * @param pendingChanges - Local pending changes
 * @param dragState - Current drag operation state
 * @param bpm - Current tempo (for snapping)
 * @param denominator - Time signature denominator
 * @returns Preview regions and indicator positions
 */
export function computeDragPreview(
  regions: Region[],
  pendingChanges: PendingChangesRecord,
  dragState: DragState,
  bpm: number | null,
  denominator: number
): DragPreviewResult {
  const { dragType, dragRegionId, dragStartTime, dragCurrentTime } = dragState;

  // First get display regions (with pending changes applied)
  const displayRegions = computeDisplayRegions(regions, pendingChanges);

  // If not dragging, return display regions as-is
  if (dragType === 'none' || dragRegionId === null || dragStartTime === null || dragCurrentTime === null) {
    return {
      regions: displayRegions,
      insertionPoint: null,
      resizeEdgePosition: null,
    };
  }

  const delta = dragCurrentTime - dragStartTime;
  if (Math.abs(delta) < 0.01) {
    return {
      regions: displayRegions,
      insertionPoint: null,
      resizeEdgePosition: null,
    };
  }

  // Use the extracted drag preview calculation
  const result = calculateDragPreview(displayRegions, {
    dragType,
    dragRegionId,
    dragStartTime,
    dragCurrentTime,
    bpm,
    denominator,
  });

  return {
    regions: result.regions,
    insertionPoint: result.insertionPoint,
    resizeEdgePosition: result.resizeEdgePosition,
  };
}
