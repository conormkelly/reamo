/**
 * Pure functions for ripple edit operations
 *
 * These functions calculate how regions should shift when edits are made.
 * All functions are pure - they take current state and return new pending changes.
 */

import type { Region } from '../../../core/types';
import type { PendingChangesRecord, DeleteMode } from '../regionEditSlice.types';
import { snapToGrid } from '../../../utils';

/** Floating point comparison epsilon */
const EPSILON = 0.001;

/** Snap to quarter note grid */
export const snapToBeats = (seconds: number, bpm: number) => snapToGrid(seconds, bpm, 1);

/**
 * Calculate minimum region length (1 bar) from BPM
 */
export function getMinRegionLength(bpm: number | null): number {
  if (!bpm || bpm <= 0) {
    return 2; // Default to 2 seconds if no BPM
  }
  const beatsPerBar = 4; // Assuming 4/4
  return (60 / bpm) * beatsPerBar;
}

/**
 * Parameters for resize ripple calculation
 */
export interface ResizeRippleParams {
  index: number;
  edge: 'start' | 'end';
  newTime: number;
  regions: Region[];
  bpm: number | null;
  pendingChanges: PendingChangesRecord;
}

/**
 * Calculate ripple effects for resizing a region
 * Returns the updated pending changes
 */
export function calculateResizeRipple(params: ResizeRippleParams): PendingChangesRecord {
  const { index, edge, newTime, regions, bpm, pendingChanges } = params;
  const minLength = getMinRegionLength(bpm);
  const changes = { ...pendingChanges };
  const existing = changes[index];

  // Handle new regions (negative keys) - they only exist in pendingChanges
  let regionStart: number;
  let regionEnd: number;
  let regionName: string;
  let regionColor: number | undefined;
  let regionId: number;

  if (index < 0) {
    if (!existing) return changes; // New region must exist in pending changes
    regionStart = existing.newStart;
    regionEnd = existing.newEnd;
    regionName = existing.name;
    regionColor = existing.color;
    regionId = existing.originalIdx;
  } else {
    const region = regions[index];
    if (!region) return changes;
    regionStart = existing?.newStart ?? region.start;
    regionEnd = existing?.newEnd ?? region.end;
    regionName = region.name;
    regionColor = region.color;
    regionId = region.id;
  }

  let newStart = regionStart;
  let newEnd = regionEnd;
  const originalEnd = regionEnd;

  // Snap to beat grid
  let snappedTime = newTime;
  if (bpm && bpm > 0) {
    snappedTime = snapToBeats(newTime, bpm);
  }

  if (edge === 'start') {
    const originalStart = regionStart;
    newStart = Math.max(0, snappedTime);
    // Enforce minimum length
    if (newEnd - newStart < minLength) {
      newStart = newEnd - minLength;
    }

    // RIPPLE: When extending start backwards, trim overlapped regions
    if (newStart < originalStart) {
      for (let i = 0; i < regions.length; i++) {
        if (i === index) continue;

        const otherRegion = regions[i];
        const otherExisting = changes[i];
        const otherStart = otherExisting?.newStart ?? otherRegion.start;
        const otherEnd = otherExisting?.newEnd ?? otherRegion.end;

        // If this region ends after the new start and starts before the new start,
        // it's being overlapped - trim its end to the new start
        if (otherEnd > newStart && otherStart < newStart) {
          changes[i] = {
            originalIdx: otherRegion.id,
            originalStart: otherRegion.start,
            originalEnd: otherRegion.end,
            newStart: otherStart,
            newEnd: newStart,
            name: otherRegion.name,
            color: otherRegion.color,
          };
        }
      }
    }
  } else {
    newEnd = snappedTime;
    // Enforce minimum length
    if (newEnd - newStart < minLength) {
      newEnd = newStart + minLength;
    }
  }

  // For new regions, preserve isNew flag
  const isNew = index < 0;
  changes[index] = {
    originalIdx: regionId,
    originalStart: isNew ? existing!.originalStart : regions[index].start,
    originalEnd: isNew ? existing!.originalEnd : regions[index].end,
    newStart,
    newEnd,
    name: regionName,
    color: regionColor,
    ...(isNew && { isNew: true }),
  };

  // RIPPLE: When resizing end edge, shift subsequent regions
  if (edge === 'end') {
    const delta = newEnd - originalEnd;

    if (Math.abs(delta) > EPSILON) {
      for (let i = 0; i < regions.length; i++) {
        if (i === index) continue;

        const otherRegion = regions[i];
        const otherExisting = changes[i];
        const otherStart = otherExisting?.newStart ?? otherRegion.start;
        const otherEnd = otherExisting?.newEnd ?? otherRegion.end;

        // Only affect regions that start at or after the original end
        if (otherStart >= originalEnd) {
          changes[i] = {
            originalIdx: otherRegion.id,
            originalStart: otherRegion.start,
            originalEnd: otherRegion.end,
            newStart: otherStart + delta,
            newEnd: otherEnd + delta,
            name: otherRegion.name,
            color: otherRegion.color,
          };
        }
      }
    }
  }

  return changes;
}

/**
 * Parameters for move ripple calculation
 */
export interface MoveRippleParams {
  indices: number[];
  deltaTime: number;
  regions: Region[];
  pendingChanges: PendingChangesRecord;
}

/**
 * Calculate ripple effects for moving regions
 * Uses "remove then insert" logic:
 * 1. Remove from original position → gap closes (everything after shifts LEFT)
 * 2. Insert at new position → gap opens (everything at/after shifts RIGHT)
 *
 * Returns the updated pending changes
 */
export function calculateMoveRipple(params: MoveRippleParams): PendingChangesRecord {
  const { indices, deltaTime, regions, pendingChanges } = params;
  const changes = { ...pendingChanges };

  // First, calculate new positions for moved regions
  const movedRegions: Array<{
    index: number;
    newStart: number;
    newEnd: number;
    duration: number;
    oldStart: number;
  }> = [];

  for (const index of indices) {
    const existing = changes[index];

    // Handle new regions (negative keys) - they only exist in pendingChanges
    if (index < 0) {
      if (!existing || !existing.isNew) continue;

      const currentStart = existing.newStart;
      const currentEnd = existing.newEnd;
      const duration = currentEnd - currentStart;

      const newStart = Math.max(0, currentStart + deltaTime);
      const newEnd = newStart + duration;

      movedRegions.push({ index, newStart, newEnd, duration, oldStart: currentStart });

      changes[index] = {
        ...existing,
        newStart,
        newEnd,
      };
    } else {
      // Handle existing regions from REAPER
      const region = regions[index];
      if (!region) continue;

      const currentStart = existing?.newStart ?? region.start;
      const currentEnd = existing?.newEnd ?? region.end;
      const duration = currentEnd - currentStart;

      const newStart = Math.max(0, currentStart + deltaTime);
      const newEnd = newStart + duration;

      movedRegions.push({ index, newStart, newEnd, duration, oldStart: currentStart });

      changes[index] = {
        originalIdx: region.id,
        originalStart: region.start,
        originalEnd: region.end,
        newStart,
        newEnd,
        name: existing?.name ?? region.name,
        color: existing?.color ?? region.color,
      };
    }
  }

  // RIPPLE: Use "remove then insert" logic
  if (movedRegions.length > 0) {
    const dragFrom = movedRegions[0].oldStart;
    const dragTo = movedRegions[0].newStart;
    const duration = movedRegions[0].duration;
    const movedIndices = new Set(indices);

    // Process existing regions
    for (let i = 0; i < regions.length; i++) {
      if (movedIndices.has(i)) continue;

      const region = regions[i];
      const existing = changes[i];
      if (existing?.isDeleted) continue;

      const P = existing?.newStart ?? region.start;
      const currentEnd = existing?.newEnd ?? region.end;

      const netShift = calculateNetShift(P, dragFrom, dragTo, duration);

      if (Math.abs(netShift) > EPSILON) {
        changes[i] = {
          originalIdx: region.id,
          originalStart: region.start,
          originalEnd: region.end,
          newStart: P + netShift,
          newEnd: currentEnd + netShift,
          name: existing?.name ?? region.name,
          color: existing?.color ?? region.color,
        };
      }
    }

    // Process new pending regions (negative keys)
    for (const keyStr of Object.keys(changes)) {
      const key = parseInt(keyStr, 10);
      if (key >= 0 || movedIndices.has(key)) continue;
      const pending = changes[key];
      if (!pending || pending.isDeleted || !pending.isNew) continue;

      const P = pending.newStart;
      const currentEnd = pending.newEnd;

      const netShift = calculateNetShift(P, dragFrom, dragTo, duration);

      if (Math.abs(netShift) > EPSILON) {
        changes[key] = {
          ...pending,
          newStart: P + netShift,
          newEnd: currentEnd + netShift,
        };
      }
    }
  }

  return changes;
}

/**
 * Calculate net shift for a region at position P when moving from dragFrom to dragTo
 */
function calculateNetShift(P: number, dragFrom: number, dragTo: number, duration: number): number {
  let netShift = 0;

  if (P > dragFrom + EPSILON) {
    // This region was after the dragged region - gap closure shifts it left
    const afterGapClosure = P - duration;
    netShift = -duration;

    // After gap closure, if it's at/after target, shift right to make room
    if (afterGapClosure >= dragTo - EPSILON) {
      netShift += duration; // Net: 0
    }
  } else {
    // This region was before/at the dragged region
    // If it's at/after target, shift right to make room
    if (P >= dragTo - EPSILON) {
      netShift = duration;
    }
  }

  return netShift;
}

/**
 * Parameters for create region ripple calculation
 */
export interface CreateRippleParams {
  start: number;
  end: number;
  name: string;
  bpm: number | null;
  color: number | undefined;
  regions: Region[];
  pendingChanges: PendingChangesRecord;
  nextNewRegionKey: number;
}

/**
 * Result of create region calculation
 */
export interface CreateRippleResult {
  changes: PendingChangesRecord;
  newRegionKey: number;
}

/**
 * Calculate ripple effects for creating a new region
 * Returns the updated pending changes and the key for the new region
 */
export function calculateCreateRipple(params: CreateRippleParams): CreateRippleResult {
  const { start, bpm, color, regions, pendingChanges, nextNewRegionKey, name } = params;
  let { end } = params;

  const minLength = getMinRegionLength(bpm);
  if (end - start < minLength) {
    end = start + minLength;
  }

  const changes = { ...pendingChanges };
  const newRegionDuration = end - start;

  // RIPPLE LOGIC: Apply trim and shift like resizing end edge
  for (let i = 0; i < regions.length; i++) {
    const region = regions[i];
    const existing = changes[i];

    // Skip deleted regions
    if (existing?.isDeleted) continue;

    const regionStart = existing?.newStart ?? region.start;
    const regionEnd = existing?.newEnd ?? region.end;

    // If this region contains the insertion point, trim its end
    if (regionStart < start - EPSILON && regionEnd > start + EPSILON) {
      changes[i] = {
        originalIdx: region.id,
        originalStart: region.start,
        originalEnd: region.end,
        newStart: regionStart,
        newEnd: start,
        name: existing?.name ?? region.name,
        color: existing?.color ?? region.color,
      };
    }
    // If this region starts at or after the insertion point, shift it right
    else if (regionStart >= start - EPSILON) {
      changes[i] = {
        originalIdx: region.id,
        originalStart: region.start,
        originalEnd: region.end,
        newStart: regionStart + newRegionDuration,
        newEnd: regionEnd + newRegionDuration,
        name: existing?.name ?? region.name,
        color: existing?.color ?? region.color,
      };
    }
  }

  changes[nextNewRegionKey] = {
    originalIdx: nextNewRegionKey,
    originalStart: start,
    originalEnd: end,
    newStart: start,
    newEnd: end,
    name,
    color,
    isNew: true,
  };

  return {
    changes,
    newRegionKey: nextNewRegionKey - 1,
  };
}

/**
 * Parameters for delete region ripple calculation
 */
export interface DeleteRippleParams {
  index: number;
  mode: DeleteMode;
  regions: Region[];
  pendingChanges: PendingChangesRecord;
}

/**
 * Calculate ripple effects for deleting a region
 * Returns the updated pending changes
 */
export function calculateDeleteRipple(params: DeleteRippleParams): PendingChangesRecord {
  const { index, mode, regions, pendingChanges } = params;
  const changes = { ...pendingChanges };

  // Handle new regions (negative keys) - they only exist in pendingChanges
  const isNewRegion = index < 0;
  let regionStart: number;
  let regionEnd: number;
  let regionName: string;
  let regionColor: number | undefined;
  let regionId: number;

  if (isNewRegion) {
    const pendingRegion = changes[index];
    if (!pendingRegion || !pendingRegion.isNew) return changes;
    regionStart = pendingRegion.newStart;
    regionEnd = pendingRegion.newEnd;
    regionName = pendingRegion.name;
    regionColor = pendingRegion.color;
    regionId = index;
  } else {
    const region = regions[index];
    if (!region) return changes;
    const existing = changes[index];
    regionStart = existing?.newStart ?? region.start;
    regionEnd = existing?.newEnd ?? region.end;
    regionName = existing?.name ?? region.name;
    regionColor = existing?.color ?? region.color;
    regionId = region.id;
  }

  const deletedDuration = regionEnd - regionStart;

  // For new regions, remove from pendingChanges; for existing, mark as deleted
  if (isNewRegion) {
    delete changes[index];
  } else {
    changes[index] = {
      originalIdx: regionId,
      originalStart: regions[index].start,
      originalEnd: regions[index].end,
      newStart: regionStart,
      newEnd: regionEnd,
      name: regionName,
      color: regionColor,
      isDeleted: true,
    };
  }

  if (mode === 'extend-previous') {
    applyExtendPreviousRipple(changes, regions, index, regionStart, regionEnd);
  } else if (mode === 'ripple-back') {
    applyRippleBackDelete(changes, regions, index, regionEnd, deletedDuration);
  }
  // mode === 'leave-gap' - no additional changes needed

  return changes;
}

/**
 * Find and extend the previous region to fill the gap left by deleted region
 */
function applyExtendPreviousRipple(
  changes: PendingChangesRecord,
  regions: Region[],
  deletedIndex: number,
  regionStart: number,
  regionEnd: number
): void {
  let bestPrevKey: number | null = null;
  let bestPrevEnd = -Infinity;

  // Check existing regions
  for (let i = 0; i < regions.length; i++) {
    if (i === deletedIndex) continue;
    const existing = changes[i];
    if (existing?.isDeleted) continue;
    const rEnd = existing?.newEnd ?? regions[i].end;
    if (rEnd <= regionStart && rEnd > bestPrevEnd) {
      bestPrevEnd = rEnd;
      bestPrevKey = i;
    }
  }

  // Check new pending regions (negative keys)
  for (const keyStr of Object.keys(changes)) {
    const key = parseInt(keyStr, 10);
    if (key >= 0 || key === deletedIndex) continue;
    const pending = changes[key];
    if (!pending || pending.isDeleted || !pending.isNew) continue;
    if (pending.newEnd <= regionStart && pending.newEnd > bestPrevEnd) {
      bestPrevEnd = pending.newEnd;
      bestPrevKey = key;
    }
  }

  // Extend the previous region to fill the gap
  if (bestPrevKey !== null) {
    const isNewPrev = bestPrevKey < 0;
    if (isNewPrev) {
      const prevPending = changes[bestPrevKey]!;
      changes[bestPrevKey] = {
        ...prevPending,
        newEnd: regionEnd,
      };
    } else {
      const prevRegion = regions[bestPrevKey];
      const prevExisting = changes[bestPrevKey];
      changes[bestPrevKey] = {
        originalIdx: prevRegion.id,
        originalStart: prevRegion.start,
        originalEnd: prevRegion.end,
        newStart: prevExisting?.newStart ?? prevRegion.start,
        newEnd: regionEnd,
        name: prevExisting?.name ?? prevRegion.name,
        color: prevExisting?.color ?? prevRegion.color,
      };
    }
  }
}

/**
 * Shift all regions after the deleted region backwards
 */
function applyRippleBackDelete(
  changes: PendingChangesRecord,
  regions: Region[],
  deletedIndex: number,
  regionEnd: number,
  deletedDuration: number
): void {
  // Check existing regions
  for (let i = 0; i < regions.length; i++) {
    if (i === deletedIndex) continue;
    const otherRegion = regions[i];
    const existing = changes[i];
    if (existing?.isDeleted) continue;
    const otherStart = existing?.newStart ?? otherRegion.start;
    const otherEnd = existing?.newEnd ?? otherRegion.end;

    if (otherStart >= regionEnd) {
      changes[i] = {
        originalIdx: otherRegion.id,
        originalStart: otherRegion.start,
        originalEnd: otherRegion.end,
        newStart: otherStart - deletedDuration,
        newEnd: otherEnd - deletedDuration,
        name: existing?.name ?? otherRegion.name,
        color: existing?.color ?? otherRegion.color,
      };
    }
  }

  // Check new pending regions (negative keys)
  for (const keyStr of Object.keys(changes)) {
    const key = parseInt(keyStr, 10);
    if (key >= 0 || key === deletedIndex) continue;
    const pending = changes[key];
    if (!pending || pending.isDeleted || !pending.isNew) continue;

    if (pending.newStart >= regionEnd) {
      changes[key] = {
        ...pending,
        newStart: pending.newStart - deletedDuration,
        newEnd: pending.newEnd - deletedDuration,
      };
    }
  }
}
