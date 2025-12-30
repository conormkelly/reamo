/**
 * Pure functions for ripple edit operations
 *
 * These functions calculate how regions should shift when edits are made.
 * All functions are pure - they take current state and return new pending changes.
 *
 * KEY DESIGN: All pending changes are keyed by REGION ID (not array index).
 * This ensures stability when server pushes updates that change array ordering.
 */

import type { Region } from '../../../core/types';
import type { PendingChangesRecord, DeleteMode } from '../regionEditSlice.types';
import { snapToGrid } from '../../../utils';

/** Floating point comparison epsilon */
const EPSILON = 0.001;

/**
 * Snap to beat grid based on time signature denominator
 * @param denominator - Time signature denominator (4 = quarter, 8 = eighth, 2 = half). Default: 4
 */
export const snapToBeats = (seconds: number, bpm: number, denominator: number = 4) =>
  snapToGrid(seconds, bpm, denominator / 4);

/**
 * Calculate minimum region length (1 bar) from BPM and time signature
 *
 * @param bpm - Quarter-note BPM (normalized)
 * @param beatsPerBar - Numerator of time signature (e.g., 6 for 6/8)
 * @param denominator - Denominator of time signature (e.g., 8 for 6/8)
 * @returns Duration of one bar in seconds
 */
export function getMinRegionLength(bpm: number | null, beatsPerBar = 4, denominator = 4): number {
  if (!bpm || bpm <= 0) {
    return 2; // Default to 2 seconds if no BPM
  }
  // Convert beatsPerBar (in denominator units) to quarter-note beats
  // For 6/8: 6 eighth notes = 3 quarter notes
  // For 2/2: 2 half notes = 4 quarter notes
  const quarterNoteBeats = beatsPerBar * (4 / denominator);
  return (60 / bpm) * quarterNoteBeats;
}

/** Helper to find a region by ID */
function findRegionById(regions: Region[], id: number): Region | undefined {
  if (id < 0) return undefined; // Negative IDs are new regions
  return regions.find((r) => r.id === id);
}

/**
 * Parameters for resize ripple calculation
 */
export interface ResizeRippleParams {
  id: number;  // Region ID (not array index)
  edge: 'start' | 'end';
  newTime: number;
  regions: Region[];
  bpm: number | null;
  beatsPerBar?: number;
  denominator?: number;
  pendingChanges: PendingChangesRecord;
}

/**
 * Calculate ripple effects for resizing a region
 * Returns the updated pending changes
 */
export function calculateResizeRipple(params: ResizeRippleParams): PendingChangesRecord {
  const { id, edge, newTime, regions, bpm, beatsPerBar = 4, denominator = 4, pendingChanges } = params;
  const minLength = getMinRegionLength(bpm, beatsPerBar, denominator);
  const changes = { ...pendingChanges };
  const existing = changes[id];

  // Handle new regions (negative keys) - they only exist in pendingChanges
  let regionStart: number;
  let regionEnd: number;
  let regionName: string;
  let regionColor: number | undefined;
  let regionId: number;

  if (id < 0) {
    if (!existing) return changes; // New region must exist in pending changes
    regionStart = existing.newStart;
    regionEnd = existing.newEnd;
    regionName = existing.name;
    regionColor = existing.color;
    regionId = existing.originalIdx;
  } else {
    const region = findRegionById(regions, id);
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

  // Snap to beat grid (using time signature denominator for proper snap points)
  let snappedTime = newTime;
  if (bpm && bpm > 0) {
    snappedTime = snapToBeats(newTime, bpm, denominator);
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
      // Trim existing regions
      for (const otherRegion of regions) {
        if (otherRegion.id === id) continue;

        const otherExisting = changes[otherRegion.id];

        // Skip deleted regions - don't resurrect them
        if (otherExisting?.isDeleted) continue;

        const otherStart = otherExisting?.newStart ?? otherRegion.start;
        const otherEnd = otherExisting?.newEnd ?? otherRegion.end;

        // If this region ends after the new start and starts before the new start,
        // it's being overlapped - trim its end to the new start
        if (otherEnd > newStart && otherStart < newStart) {
          changes[otherRegion.id] = {
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

      // Trim new pending regions (negative keys)
      for (const keyStr of Object.keys(changes)) {
        const key = parseInt(keyStr, 10);
        if (key >= 0 || key === id) continue;
        const pending = changes[key];
        if (!pending || pending.isDeleted || !pending.isNew) continue;

        // If this region ends after the new start and starts before the new start,
        // it's being overlapped - trim its end to the new start
        if (pending.newEnd > newStart && pending.newStart < newStart) {
          changes[key] = {
            ...pending,
            newEnd: newStart,
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
  const isNew = id < 0;
  changes[id] = {
    originalIdx: regionId,
    originalStart: isNew ? existing!.originalStart : findRegionById(regions, id)!.start,
    originalEnd: isNew ? existing!.originalEnd : findRegionById(regions, id)!.end,
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
      // Shift existing regions
      for (const otherRegion of regions) {
        if (otherRegion.id === id) continue;

        const otherExisting = changes[otherRegion.id];

        // Skip deleted regions - don't resurrect them
        if (otherExisting?.isDeleted) continue;

        const otherStart = otherExisting?.newStart ?? otherRegion.start;
        const otherEnd = otherExisting?.newEnd ?? otherRegion.end;

        // Only affect regions that start at or after the original end
        if (otherStart >= originalEnd) {
          changes[otherRegion.id] = {
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

      // Shift new pending regions (negative keys)
      for (const keyStr of Object.keys(changes)) {
        const key = parseInt(keyStr, 10);
        if (key >= 0 || key === id) continue;
        const pending = changes[key];
        if (!pending || pending.isDeleted || !pending.isNew) continue;

        // Only affect regions that start at or after the original end
        if (pending.newStart >= originalEnd) {
          changes[key] = {
            ...pending,
            newStart: pending.newStart + delta,
            newEnd: pending.newEnd + delta,
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
  ids: number[];  // Region IDs (not array indices)
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
  const { ids, deltaTime, regions, pendingChanges } = params;
  const changes = { ...pendingChanges };

  // First, calculate new positions for moved regions
  const movedRegions: Array<{
    id: number;
    newStart: number;
    newEnd: number;
    duration: number;
    oldStart: number;
  }> = [];

  for (const id of ids) {
    const existing = changes[id];

    // Handle new regions (negative keys) - they only exist in pendingChanges
    if (id < 0) {
      if (!existing || !existing.isNew) continue;

      const currentStart = existing.newStart;
      const currentEnd = existing.newEnd;
      const duration = currentEnd - currentStart;

      const newStart = Math.max(0, currentStart + deltaTime);
      const newEnd = newStart + duration;

      movedRegions.push({ id, newStart, newEnd, duration, oldStart: currentStart });

      changes[id] = {
        ...existing,
        newStart,
        newEnd,
      };
    } else {
      // Handle existing regions from REAPER
      const region = findRegionById(regions, id);
      if (!region) continue;

      const currentStart = existing?.newStart ?? region.start;
      const currentEnd = existing?.newEnd ?? region.end;
      const duration = currentEnd - currentStart;

      const newStart = Math.max(0, currentStart + deltaTime);
      const newEnd = newStart + duration;

      movedRegions.push({ id, newStart, newEnd, duration, oldStart: currentStart });

      changes[id] = {
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
    const movedIdSet = new Set(ids);

    // Process existing regions
    for (const region of regions) {
      if (movedIdSet.has(region.id)) continue;

      const existing = changes[region.id];
      if (existing?.isDeleted) continue;

      const P = existing?.newStart ?? region.start;
      const currentEnd = existing?.newEnd ?? region.end;

      const netShift = calculateNetShift(P, dragFrom, dragTo, duration);

      if (Math.abs(netShift) > EPSILON) {
        changes[region.id] = {
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
      if (key >= 0 || movedIdSet.has(key)) continue;
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
  beatsPerBar?: number;
  denominator?: number;
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
  const { start, bpm, beatsPerBar = 4, denominator = 4, color, regions, pendingChanges, nextNewRegionKey, name } = params;
  let { end } = params;

  const minLength = getMinRegionLength(bpm, beatsPerBar, denominator);
  if (end - start < minLength) {
    end = start + minLength;
  }

  const changes = { ...pendingChanges };
  const newRegionDuration = end - start;

  // RIPPLE LOGIC: Apply trim and shift like resizing end edge
  for (const region of regions) {
    const existing = changes[region.id];

    // Skip deleted regions
    if (existing?.isDeleted) continue;

    const regionStart = existing?.newStart ?? region.start;
    const regionEnd = existing?.newEnd ?? region.end;

    // If this region contains the insertion point, trim its end
    if (regionStart < start - EPSILON && regionEnd > start + EPSILON) {
      changes[region.id] = {
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
      changes[region.id] = {
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
  id: number;  // Region ID (not array index)
  mode: DeleteMode;
  regions: Region[];
  pendingChanges: PendingChangesRecord;
}

/**
 * Calculate ripple effects for deleting a region
 * Returns the updated pending changes
 */
export function calculateDeleteRipple(params: DeleteRippleParams): PendingChangesRecord {
  const { id, mode, regions, pendingChanges } = params;
  const changes = { ...pendingChanges };

  // Handle new regions (negative keys) - they only exist in pendingChanges
  const isNewRegion = id < 0;
  let regionStart: number;
  let regionEnd: number;
  let regionName: string;
  let regionColor: number | undefined;
  let regionId: number;

  if (isNewRegion) {
    const pendingRegion = changes[id];
    if (!pendingRegion || !pendingRegion.isNew) return changes;
    regionStart = pendingRegion.newStart;
    regionEnd = pendingRegion.newEnd;
    regionName = pendingRegion.name;
    regionColor = pendingRegion.color;
    regionId = id;
  } else {
    const region = findRegionById(regions, id);
    if (!region) return changes;
    const existing = changes[id];
    regionStart = existing?.newStart ?? region.start;
    regionEnd = existing?.newEnd ?? region.end;
    regionName = existing?.name ?? region.name;
    regionColor = existing?.color ?? region.color;
    regionId = region.id;
  }

  const deletedDuration = regionEnd - regionStart;

  // For new regions, remove from pendingChanges; for existing, mark as deleted
  if (isNewRegion) {
    delete changes[id];
  } else {
    const region = findRegionById(regions, id)!;
    changes[id] = {
      originalIdx: regionId,
      originalStart: region.start,
      originalEnd: region.end,
      newStart: regionStart,
      newEnd: regionEnd,
      name: regionName,
      color: regionColor,
      isDeleted: true,
    };
  }

  if (mode === 'extend-previous') {
    applyExtendPreviousRipple(changes, regions, id, regionStart, regionEnd);
  } else if (mode === 'ripple-back') {
    applyRippleBackDelete(changes, regions, id, regionEnd, deletedDuration);
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
  deletedId: number,
  regionStart: number,
  regionEnd: number
): void {
  let bestPrevKey: number | null = null;
  let bestPrevEnd = -Infinity;

  // Check existing regions
  for (const region of regions) {
    if (region.id === deletedId) continue;
    const existing = changes[region.id];
    if (existing?.isDeleted) continue;
    const rEnd = existing?.newEnd ?? region.end;
    if (rEnd <= regionStart && rEnd > bestPrevEnd) {
      bestPrevEnd = rEnd;
      bestPrevKey = region.id;
    }
  }

  // Check new pending regions (negative keys)
  for (const keyStr of Object.keys(changes)) {
    const key = parseInt(keyStr, 10);
    if (key >= 0 || key === deletedId) continue;
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
      const prevRegion = findRegionById(regions, bestPrevKey)!;
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
  deletedId: number,
  regionEnd: number,
  deletedDuration: number
): void {
  // Check existing regions
  for (const otherRegion of regions) {
    if (otherRegion.id === deletedId) continue;
    const existing = changes[otherRegion.id];
    if (existing?.isDeleted) continue;
    const otherStart = existing?.newStart ?? otherRegion.start;
    const otherEnd = existing?.newEnd ?? otherRegion.end;

    if (otherStart >= regionEnd) {
      changes[otherRegion.id] = {
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
    if (key >= 0 || key === deletedId) continue;
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
