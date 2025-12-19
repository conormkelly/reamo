/**
 * Drag preview calculation for region editing
 *
 * Calculates the live preview of regions during drag operations,
 * showing ripple effects in real-time.
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
  dragRegionIndex: number | null;
  dragStartTime: number | null;
  dragCurrentTime: number | null;
  bpm?: number | null;
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
  const { dragType, dragRegionIndex, dragStartTime, dragCurrentTime, bpm } = state;

  // If not dragging, return regions as-is
  if (dragType === 'none' || dragRegionIndex === null || dragStartTime === null || dragCurrentTime === null) {
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
  const previewRegions = displayRegions.map((r, idx) => ({ ...r, _originalIdx: idx }));
  const draggedRegion = previewRegions[dragRegionIndex];

  if (!draggedRegion) {
    return {
      regions: displayRegions,
      insertionPoint: null,
      resizeEdgePosition: null,
    };
  }

  if (dragType === 'resize-start') {
    return calculateResizeStartPreview(previewRegions, draggedRegion, dragRegionIndex, dragCurrentTime, bpm);
  } else if (dragType === 'resize-end') {
    return calculateResizeEndPreview(previewRegions, draggedRegion, dragRegionIndex, dragCurrentTime, bpm);
  } else if (dragType === 'move') {
    return calculateMovePreview(previewRegions, draggedRegion, dragRegionIndex, delta);
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
  dragRegionIndex: number,
  dragCurrentTime: number,
  bpm: number | null | undefined
): DragPreviewResult {
  let newStart = Math.max(0, dragCurrentTime);
  if (bpm && bpm > 0) {
    newStart = snapToBeats(newStart, bpm);
  }

  const minLength = 0.5;
  const originalStart = draggedRegion.start;

  if (draggedRegion.end - newStart >= minLength) {
    previewRegions[dragRegionIndex] = {
      ...draggedRegion,
      start: newStart,
    };

    // RIPPLE: When extending start backwards, trim overlapped regions
    if (newStart < originalStart) {
      for (let i = 0; i < previewRegions.length; i++) {
        if (i === dragRegionIndex) continue;
        const region = previewRegions[i];
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
  dragRegionIndex: number,
  dragCurrentTime: number,
  bpm: number | null | undefined
): DragPreviewResult {
  let newEnd = dragCurrentTime;
  if (bpm && bpm > 0) {
    newEnd = snapToBeats(newEnd, bpm);
  }

  const minLength = 0.5;
  const originalEnd = draggedRegion.end;

  if (newEnd - draggedRegion.start >= minLength) {
    previewRegions[dragRegionIndex] = {
      ...draggedRegion,
      end: newEnd,
    };

    // RIPPLE: Shift subsequent regions when extending/shrinking end
    const resizeDelta = newEnd - originalEnd;

    for (let i = 0; i < previewRegions.length; i++) {
      if (i === dragRegionIndex) continue;
      const region = previewRegions[i];
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
  dragRegionIndex: number,
  delta: number
): DragPreviewResult {
  const duration = draggedRegion.end - draggedRegion.start;
  const dragFrom = draggedRegion.start;
  const dragTo = Math.max(0, draggedRegion.start + delta);
  const newEnd = dragTo + duration;

  // Build the preview with proper ripple shifts
  const finalRegions: Region[] = [];

  for (let i = 0; i < previewRegions.length; i++) {
    if (i === dragRegionIndex) {
      // Add the dragged region at its new position
      finalRegions.push({
        ...draggedRegion,
        start: dragTo,
        end: newEnd,
      });
    } else {
      const region = previewRegions[i];
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
