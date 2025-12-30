/**
 * Drag preview calculation for region editing
 *
 * Calculates the live preview of regions during drag operations,
 * showing ripple effects in real-time.
 *
 * KEY DESIGN: Uses region IDs (not array indices) for stability.
 */

import type { Region } from '../../../core/types';
import type { DragType, DisplayRegion } from '../regionEditSlice.types';
import { snapToBeats } from './rippleOperations';

/** Floating point comparison epsilon */
const EPSILON = 0.001;

/**
 * State needed for drag preview calculation
 */
export interface DragPreviewState {
  dragType: DragType;
  dragRegionId: number | null;  // Region ID (not array index)
  dragStartTime: number | null;
  dragCurrentTime: number | null;
  bpm?: number | null;
  denominator?: number;  // Time signature denominator for proper beat snapping
}

/**
 * Result of drag preview calculation
 */
export interface DragPreviewResult {
  regions: Region[];
  insertionPoint: number | null;
  resizeEdgePosition: number | null;
}

/**
 * Calculate preview regions during drag operation
 *
 * @param displayRegions - Current display regions (with pending changes applied)
 * @param state - Current drag state
 * @returns Preview regions and UI state updates
 */
export function calculateDragPreview(
  displayRegions: DisplayRegion[],
  state: DragPreviewState
): DragPreviewResult {
  const { dragType, dragRegionId, dragStartTime, dragCurrentTime, bpm, denominator = 4 } = state;

  // If not dragging, return regions as-is
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

  // Create a mutable copy for preview calculations
  const previewRegions = displayRegions.map((r) => ({ ...r }));
  const draggedRegion = previewRegions.find((r) => r.id === dragRegionId);

  if (!draggedRegion) {
    return {
      regions: displayRegions,
      insertionPoint: null,
      resizeEdgePosition: null,
    };
  }

  if (dragType === 'resize-start') {
    return calculateResizeStartPreview(previewRegions, draggedRegion, dragCurrentTime, bpm, denominator);
  } else if (dragType === 'resize-end') {
    return calculateResizeEndPreview(previewRegions, draggedRegion, dragCurrentTime, bpm, denominator);
  } else if (dragType === 'move') {
    return calculateMovePreview(previewRegions, draggedRegion, delta);
  }

  return {
    regions: previewRegions.sort((a, b) => a.start - b.start),
    insertionPoint: null,
    resizeEdgePosition: null,
  };
}

/**
 * Calculate preview for resize-start operation
 */
function calculateResizeStartPreview(
  previewRegions: Region[],
  draggedRegion: Region,
  dragCurrentTime: number,
  bpm: number | null | undefined,
  denominator: number
): DragPreviewResult {
  let newStart = Math.max(0, dragCurrentTime);
  if (bpm && bpm > 0) {
    newStart = snapToBeats(newStart, bpm, denominator);
  }

  const minLength = 0.5;
  const originalStart = draggedRegion.start;
  const draggedId = draggedRegion.id;

  if (draggedRegion.end - newStart >= minLength) {
    // Update the dragged region
    const draggedIdx = previewRegions.findIndex((r) => r.id === draggedId);
    if (draggedIdx !== -1) {
      previewRegions[draggedIdx] = {
        ...draggedRegion,
        start: newStart,
      };
    }

    // RIPPLE: When extending start backwards, trim overlapped regions
    if (newStart < originalStart) {
      for (let i = 0; i < previewRegions.length; i++) {
        const region = previewRegions[i];
        if (region.id === draggedId) continue;
        if (region.end > newStart && region.start < newStart) {
          previewRegions[i] = {
            ...region,
            end: newStart,
          };
        }
      }
    }

    return {
      regions: previewRegions.sort((a, b) => a.start - b.start),
      insertionPoint: null,
      resizeEdgePosition: newStart,
    };
  }

  return {
    regions: previewRegions.sort((a, b) => a.start - b.start),
    insertionPoint: null,
    resizeEdgePosition: null,
  };
}

/**
 * Calculate preview for resize-end operation
 */
function calculateResizeEndPreview(
  previewRegions: Region[],
  draggedRegion: Region,
  dragCurrentTime: number,
  bpm: number | null | undefined,
  denominator: number
): DragPreviewResult {
  let newEnd = dragCurrentTime;
  if (bpm && bpm > 0) {
    newEnd = snapToBeats(newEnd, bpm, denominator);
  }

  const minLength = 0.5;
  const originalEnd = draggedRegion.end;
  const draggedId = draggedRegion.id;

  if (newEnd - draggedRegion.start >= minLength) {
    // Update the dragged region
    const draggedIdx = previewRegions.findIndex((r) => r.id === draggedId);
    if (draggedIdx !== -1) {
      previewRegions[draggedIdx] = {
        ...draggedRegion,
        end: newEnd,
      };
    }

    // RIPPLE: Shift subsequent regions when extending/shrinking end
    const resizeDelta = newEnd - originalEnd;

    for (let i = 0; i < previewRegions.length; i++) {
      const region = previewRegions[i];
      if (region.id === draggedId) continue;
      if (region.start >= originalEnd - EPSILON) {
        previewRegions[i] = {
          ...region,
          start: region.start + resizeDelta,
          end: region.end + resizeDelta,
        };
      }
    }

    return {
      regions: previewRegions.sort((a, b) => a.start - b.start),
      insertionPoint: null,
      resizeEdgePosition: newEnd,
    };
  }

  return {
    regions: previewRegions.sort((a, b) => a.start - b.start),
    insertionPoint: null,
    resizeEdgePosition: null,
  };
}

/**
 * Calculate preview for move operation
 */
function calculateMovePreview(
  previewRegions: Region[],
  draggedRegion: Region,
  delta: number
): DragPreviewResult {
  const duration = draggedRegion.end - draggedRegion.start;
  const dragFrom = draggedRegion.start;
  const dragTo = Math.max(0, draggedRegion.start + delta);
  const newEnd = dragTo + duration;
  const draggedId = draggedRegion.id;

  // Build the preview with proper ripple shifts
  const finalRegions: Region[] = [];

  for (const region of previewRegions) {
    if (region.id === draggedId) {
      // Add the dragged region at its new position
      finalRegions.push({
        ...draggedRegion,
        start: dragTo,
        end: newEnd,
      });
    } else {
      const P = region.start;

      // Calculate net shift using "remove then insert" logic
      let netShift = 0;

      if (P > dragFrom + EPSILON) {
        const afterGapClosure = P - duration;
        netShift = -duration;

        if (afterGapClosure >= dragTo - EPSILON) {
          netShift += duration;
        }
      } else {
        if (P >= dragTo - EPSILON) {
          netShift = duration;
        }
      }

      finalRegions.push({
        ...region,
        start: region.start + netShift,
        end: region.end + netShift,
      });
    }
  }

  return {
    regions: finalRegions.sort((a, b) => a.start - b.start),
    insertionPoint: dragTo,
    resizeEdgePosition: null,
  };
}
