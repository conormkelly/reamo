/**
 * Region Edit state slice
 * Manages region editing mode, selection, and pending changes
 * Always uses ripple edit behavior (regions shift to accommodate changes)
 */

import type { StateCreator } from 'zustand';
import type { Region } from '../../core/types';

// Timeline mode: navigate (existing behavior) or regions (editing)
export type TimelineMode = 'navigate' | 'regions';

// Drag operation type
export type DragType = 'none' | 'resize-start' | 'resize-end' | 'move';

// A pending change to a region (local only until committed)
export interface PendingRegionChange {
  originalIdx: number; // REAPER's markrgnidx (region ID), not array index. Negative for new regions.
  originalStart: number; // Original start in seconds
  originalEnd: number; // Original end in seconds
  newStart: number; // Pending new start
  newEnd: number; // Pending new end
  name: string;
  color?: number;
  isNew?: boolean; // True if newly created
  isDeleted?: boolean; // True if marked for deletion
}

export interface RegionEditSlice {
  // Mode state
  timelineMode: TimelineMode;

  // Selection state (indices into the regions array)
  selectedRegionIndices: number[];

  // Pending changes (keyed by original index, or negative for new regions)
  pendingChanges: Record<number, PendingRegionChange>;
  nextNewRegionKey: number; // Counter for new region keys (negative)

  // Drag state
  dragType: DragType;
  dragRegionIndex: number | null;
  dragStartX: number | null;
  dragStartTime: number | null;
  dragCurrentTime: number | null;

  // Insertion point (where the dragged region will slot in)
  insertionPoint: number | null;

  // Resize edge preview position (for position pill during resize)
  resizeEdgePosition: number | null;

  // Lua script detection
  luaScriptInstalled: boolean;
  luaScriptChecked: boolean;

  // Commit state
  isCommitting: boolean;
  commitError: string | null;

  // Mode actions
  setTimelineMode: (mode: TimelineMode) => void;

  // Selection actions
  selectRegion: (index: number) => void;
  addToSelection: (index: number) => void;
  deselectRegion: (index: number) => void;
  clearSelection: () => void;
  isRegionSelected: (index: number) => boolean;

  // Edit actions (modify pending state only)
  resizeRegion: (index: number, edge: 'start' | 'end', newTime: number, regions: Region[], bpm: number | null) => void;
  moveRegion: (indices: number[], deltaTime: number, regions: Region[]) => void;
  createRegion: (start: number, end: number, name: string, bpm: number | null, color: number | undefined, regions: Region[]) => void;
  deleteRegion: (index: number, regions: Region[]) => void;
  deleteRegionWithMode: (index: number, mode: 'leave-gap' | 'extend-previous' | 'ripple-back', regions: Region[]) => void;
  updateRegionMeta: (index: number, updates: { name?: string; color?: number }, regions: Region[]) => void;

  // Drag actions
  startDrag: (type: DragType, index: number, x: number, time: number) => void;
  updateDrag: (x: number, time: number) => void;
  endDrag: () => void;
  cancelDrag: () => void;

  // Commit/cancel actions
  commitChanges: () => void;
  cancelChanges: () => void;
  setCommitting: (committing: boolean) => void;
  setCommitError: (error: string | null) => void;

  // Lua detection
  setLuaScriptInstalled: (installed: boolean) => void;
  setLuaScriptChecked: (checked: boolean) => void;

  // Helpers
  hasPendingChanges: () => boolean;
  getDisplayRegions: (regions: Region[]) => Region[];
  getPendingChange: (index: number) => PendingRegionChange | undefined;
  getDragPreviewRegions: (regions: Region[]) => Region[];
}

// Calculate minimum region length (1 bar) from BPM
function getMinRegionLength(bpm: number | null): number {
  if (!bpm || bpm <= 0) {
    return 2; // Default to 2 seconds if no BPM
  }
  const beatsPerBar = 4; // Assuming 4/4
  return (60 / bpm) * beatsPerBar;
}

// Snap time to beat grid (for region editing)
function snapToBeats(seconds: number, bpm: number): number {
  const beatsPerSecond = bpm / 60;
  const beat = Math.round(seconds * beatsPerSecond);
  return beat / beatsPerSecond;
}

export const createRegionEditSlice: StateCreator<RegionEditSlice> = (set, get) => ({
  // Initial state
  timelineMode: 'navigate',
  selectedRegionIndices: [],
  pendingChanges: {},
  nextNewRegionKey: -1,
  dragType: 'none',
  dragRegionIndex: null,
  dragStartX: null,
  dragStartTime: null,
  dragCurrentTime: null,
  insertionPoint: null,
  resizeEdgePosition: null,
  luaScriptInstalled: false,
  luaScriptChecked: false,
  isCommitting: false,
  commitError: null,

  // Mode actions
  setTimelineMode: (mode) => {
    // When leaving region mode, cancel any pending changes
    if (mode === 'navigate' && get().hasPendingChanges()) {
      get().cancelChanges();
    }
    set({ timelineMode: mode, selectedRegionIndices: [] });
  },

  // Selection actions
  selectRegion: (index) => set({ selectedRegionIndices: [index] }),

  addToSelection: (index) => {
    const current = get().selectedRegionIndices;
    if (!current.includes(index)) {
      set({ selectedRegionIndices: [...current, index].sort((a, b) => a - b) });
    }
  },

  deselectRegion: (index) => {
    const current = get().selectedRegionIndices;
    set({ selectedRegionIndices: current.filter((i) => i !== index) });
  },

  clearSelection: () => set({ selectedRegionIndices: [] }),

  isRegionSelected: (index) => get().selectedRegionIndices.includes(index),

  // Edit actions (always ripple mode)
  resizeRegion: (index, edge, newTime, regions, bpm) => {
    const minLength = getMinRegionLength(bpm);
    const changes = { ...get().pendingChanges };
    const existing = changes[index];

    // Handle new regions (negative keys) - they only exist in pendingChanges
    let regionStart: number;
    let regionEnd: number;
    let regionName: string;
    let regionColor: number | undefined;
    let regionId: number;

    if (index < 0) {
      if (!existing) return; // New region must exist in pending changes
      regionStart = existing.newStart;
      regionEnd = existing.newEnd;
      regionName = existing.name;
      regionColor = existing.color;
      regionId = existing.originalIdx;
    } else {
      const region = regions[index];
      if (!region) return;
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
              originalIdx: otherRegion.id, // Use REAPER's markrgnidx, not array index
              originalStart: otherRegion.start,
              originalEnd: otherRegion.end,
              newStart: otherStart,
              newEnd: newStart, // Trim end to the dragged region's new start
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
      const delta = newEnd - originalEnd; // Positive = extending, negative = shrinking

      if (Math.abs(delta) > 0.001) {
        for (let i = 0; i < regions.length; i++) {
          if (i === index) continue;

          const otherRegion = regions[i];
          const otherExisting = changes[i];
          const otherStart = otherExisting?.newStart ?? otherRegion.start;
          const otherEnd = otherExisting?.newEnd ?? otherRegion.end;

          // Only affect regions that start at or after the original end
          if (otherStart >= originalEnd) {
            changes[i] = {
              originalIdx: otherRegion.id, // Use REAPER's markrgnidx, not array index
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

    set({ pendingChanges: changes });
  },

  moveRegion: (indices, deltaTime, regions) => {
    const changes = { ...get().pendingChanges };

    // Epsilon for floating point comparisons
    const epsilon = 0.001;

    // First, calculate new positions for moved regions
    // Note: Snapping to region boundaries is handled by Timeline.tsx before calling this
    const movedRegions: Array<{ index: number; newStart: number; newEnd: number; duration: number; oldStart: number }> = [];

    for (const index of indices) {
      const region = regions[index];
      if (!region) continue;

      const existing = changes[index];
      const currentStart = existing?.newStart ?? region.start;
      const currentEnd = existing?.newEnd ?? region.end;
      const duration = currentEnd - currentStart;

      const newStart = Math.max(0, currentStart + deltaTime);
      const newEnd = newStart + duration;

      movedRegions.push({ index, newStart, newEnd, duration, oldStart: currentStart });

      changes[index] = {
        originalIdx: region.id, // Use REAPER's markrgnidx, not array index
        originalStart: region.start,
        originalEnd: region.end,
        newStart,
        newEnd,
        name: existing?.name ?? region.name,
        color: existing?.color ?? region.color,
      };
    }

    // RIPPLE: Use "remove then insert" logic
    // 1. Remove from original position → gap closes (everything after shifts LEFT)
    // 2. Insert at new position → gap opens (everything at/after shifts RIGHT)
    if (movedRegions.length > 0) {
      // Use current position (from pending changes), not original REAPER position
      const dragFrom = movedRegions[0].oldStart; // Position BEFORE this drag
      const dragTo = movedRegions[0].newStart; // Target position
      const duration = movedRegions[0].duration;
      const movedIndices = new Set(indices);

      for (let i = 0; i < regions.length; i++) {
        // Skip regions that are being moved
        if (movedIndices.has(i)) continue;

        const region = regions[i];
        const existing = changes[i];
        if (existing?.isDeleted) continue;

        const P = existing?.newStart ?? region.start;
        const currentEnd = existing?.newEnd ?? region.end;

        // Calculate net shift using "remove then insert" logic
        // Use epsilon for floating point comparisons
        let netShift = 0;

        if (P > dragFrom + epsilon) {
          // This region was after the dragged region - gap closure shifts it left
          const afterGapClosure = P - duration;
          netShift = -duration;

          // After gap closure, if it's at/after target, shift right to make room
          if (afterGapClosure >= dragTo - epsilon) {
            netShift += duration; // Net: 0
          }
        } else {
          // This region was before/at the dragged region
          // If it's at/after target, shift right to make room
          if (P >= dragTo - epsilon) {
            netShift = duration;
          }
        }

        if (Math.abs(netShift) > epsilon) {
          changes[i] = {
            originalIdx: region.id, // Use REAPER's markrgnidx, not array index
            originalStart: region.start,
            originalEnd: region.end,
            newStart: P + netShift,
            newEnd: currentEnd + netShift,
            name: existing?.name ?? region.name,
            color: existing?.color ?? region.color,
          };
        }
      }

      // Also handle new pending regions (negative keys)
      for (const keyStr of Object.keys(changes)) {
        const key = parseInt(keyStr, 10);
        if (key >= 0 || movedIndices.has(key)) continue;
        const pending = changes[key];
        if (!pending || pending.isDeleted || !pending.isNew) continue;

        const P = pending.newStart;
        const currentEnd = pending.newEnd;

        let netShift = 0;

        if (P > dragFrom + epsilon) {
          const afterGapClosure = P - duration;
          netShift = -duration;
          if (afterGapClosure >= dragTo - epsilon) {
            netShift += duration;
          }
        } else {
          if (P >= dragTo - epsilon) {
            netShift = duration;
          }
        }

        if (Math.abs(netShift) > epsilon) {
          changes[key] = {
            ...pending,
            newStart: P + netShift,
            newEnd: currentEnd + netShift,
          };
        }
      }
    }

    set({ pendingChanges: changes });
  },

  createRegion: (start, end, name, bpm, color, regions) => {
    const minLength = getMinRegionLength(bpm);
    let finalEnd = end;
    if (finalEnd - start < minLength) {
      finalEnd = start + minLength;
    }

    const changes = { ...get().pendingChanges };
    const newRegionDuration = finalEnd - start;

    // RIPPLE LOGIC: Apply trim and shift like resizing end edge
    // 1. Find any region that contains the new region's start point and trim it
    // 2. Shift all regions that start at or after the new region's start
    // Use small epsilon for floating point comparison tolerance
    const epsilon = 0.001;

    for (let i = 0; i < regions.length; i++) {
      const region = regions[i];
      const existing = changes[i];

      // Skip deleted regions - they shouldn't participate in ripple logic
      if (existing?.isDeleted) continue;

      const regionStart = existing?.newStart ?? region.start;
      const regionEnd = existing?.newEnd ?? region.end;

      // If this region contains the insertion point, trim its end
      // (region starts before insertion and ends after insertion)
      if (regionStart < start - epsilon && regionEnd > start + epsilon) {
        changes[i] = {
          originalIdx: region.id,
          originalStart: region.start,
          originalEnd: region.end,
          newStart: regionStart,
          newEnd: start, // Trim end to where new region starts
          name: existing?.name ?? region.name,
          color: existing?.color ?? region.color,
        };
      }
      // If this region starts at or after the insertion point, shift it right
      // (includes regions that start at the same position - they get pushed)
      else if (regionStart >= start - epsilon) {
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

    const key = get().nextNewRegionKey;
    changes[key] = {
      originalIdx: key,
      originalStart: start,
      originalEnd: finalEnd,
      newStart: start,
      newEnd: finalEnd,
      name,
      color,
      isNew: true,
    };

    set({
      pendingChanges: changes,
      nextNewRegionKey: key - 1,
    });
  },

  updateRegionMeta: (index, updates, regions) => {
    const changes = { ...get().pendingChanges };
    const existing = changes[index];

    // Handle new regions (negative keys) - they only exist in pendingChanges
    if (index < 0) {
      if (!existing) return; // New region must exist in pending changes
      changes[index] = {
        ...existing,
        name: updates.name ?? existing.name,
        color: updates.color ?? existing.color,
      };
    } else {
      // Handle existing regions
      const region = regions[index];
      if (!region) return;

      changes[index] = {
        originalIdx: region.id,
        originalStart: region.start,
        originalEnd: region.end,
        newStart: existing?.newStart ?? region.start,
        newEnd: existing?.newEnd ?? region.end,
        name: updates.name ?? existing?.name ?? region.name,
        color: updates.color ?? existing?.color ?? region.color,
      };
    }

    set({ pendingChanges: changes });
  },

  deleteRegion: (index, regions) => {
    const region = regions[index];
    if (!region) return;

    set({
      pendingChanges: {
        ...get().pendingChanges,
        [index]: {
          originalIdx: region.id, // Use REAPER's markrgnidx, not array index
          originalStart: region.start,
          originalEnd: region.end,
          newStart: region.start,
          newEnd: region.end,
          name: region.name,
          color: region.color,
          isDeleted: true,
        },
      },
      // Remove from selection if selected
      selectedRegionIndices: get().selectedRegionIndices.filter((i) => i !== index),
    });
  },

  deleteRegionWithMode: (index, mode, regions) => {
    const changes = { ...get().pendingChanges };

    // Handle new regions (negative keys) - they only exist in pendingChanges
    const isNewRegion = index < 0;
    let regionStart: number;
    let regionEnd: number;
    let regionName: string;
    let regionColor: number | undefined;
    let regionId: number;

    if (isNewRegion) {
      const pendingRegion = changes[index];
      if (!pendingRegion || !pendingRegion.isNew) return;
      regionStart = pendingRegion.newStart;
      regionEnd = pendingRegion.newEnd;
      regionName = pendingRegion.name;
      regionColor = pendingRegion.color;
      regionId = index;
    } else {
      const region = regions[index];
      if (!region) return;
      const existing = changes[index];
      regionStart = existing?.newStart ?? region.start;
      regionEnd = existing?.newEnd ?? region.end;
      regionName = existing?.name ?? region.name;
      regionColor = existing?.color ?? region.color;
      regionId = region.id;
    }

    const deletedDuration = regionEnd - regionStart;

    // For new regions, we can just remove them from pendingChanges entirely
    // For existing regions, we mark them as deleted
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
      // Find the previous region (by end time, closest before this one)
      // Must check both existing regions and new pending regions
      let bestPrevKey: number | null = null;
      let bestPrevEnd = -Infinity;

      // Check existing regions
      for (let i = 0; i < regions.length; i++) {
        if (i === index) continue;
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
        if (key >= 0 || key === index) continue;
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
    } else if (mode === 'ripple-back') {
      // Shift all regions that start at or after the deleted region's end back
      // Check existing regions
      for (let i = 0; i < regions.length; i++) {
        if (i === index) continue;
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
        if (key >= 0 || key === index) continue;
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
    // mode === 'leave-gap' - no additional changes needed

    set({
      pendingChanges: changes,
      selectedRegionIndices: get().selectedRegionIndices.filter((i) => i !== index),
    });
  },

  // Drag actions
  startDrag: (type, index, x, time) =>
    set({
      dragType: type,
      dragRegionIndex: index,
      dragStartX: x,
      dragStartTime: time,
      dragCurrentTime: time,
    }),

  updateDrag: (_x, time) => set({ dragCurrentTime: time }),

  endDrag: () =>
    set({
      dragType: 'none',
      dragRegionIndex: null,
      dragStartX: null,
      dragStartTime: null,
      dragCurrentTime: null,
      insertionPoint: null,
      resizeEdgePosition: null,
    }),

  cancelDrag: () =>
    set({
      dragType: 'none',
      dragRegionIndex: null,
      dragStartX: null,
      dragStartTime: null,
      dragCurrentTime: null,
      insertionPoint: null,
      resizeEdgePosition: null,
    }),

  // Commit/cancel actions
  commitChanges: () => {
    // This will be called after successful Lua script execution
    set({
      pendingChanges: {},
      nextNewRegionKey: -1,
      selectedRegionIndices: [],
      isCommitting: false,
      commitError: null,
    });
  },

  cancelChanges: () =>
    set({
      pendingChanges: {},
      nextNewRegionKey: -1,
      selectedRegionIndices: [],
      isCommitting: false,
      commitError: null,
    }),

  setCommitting: (committing) => set({ isCommitting: committing }),
  setCommitError: (error) => set({ commitError: error }),

  // Lua detection
  setLuaScriptInstalled: (installed) => set({ luaScriptInstalled: installed }),
  setLuaScriptChecked: (checked) => set({ luaScriptChecked: checked }),

  // Helpers
  hasPendingChanges: () => Object.keys(get().pendingChanges).length > 0,

  getDisplayRegions: (regions) => {
    const pending = get().pendingChanges;
    // Extended region type with pending metadata
    type DisplayRegion = Region & { _pendingKey: number; _isNew?: boolean };
    const result: DisplayRegion[] = [];

    // Add modified existing regions
    for (let i = 0; i < regions.length; i++) {
      const change = pending[i];
      if (change) {
        if (!change.isDeleted) {
          result.push({
            name: change.name,
            id: regions[i].id,
            start: change.newStart,
            end: change.newEnd,
            color: change.color,
            _pendingKey: i, // Key in pendingChanges
          });
        }
        // Skip deleted regions
      } else {
        result.push({
          ...regions[i],
          _pendingKey: i, // Key in pendingChanges (even if no pending change)
        });
      }
    }

    // Add new regions (negative keys)
    for (const key of Object.keys(pending)) {
      const numKey = parseInt(key, 10);
      if (numKey < 0) {
        const change = pending[numKey];
        if (change && change.isNew && !change.isDeleted) {
          result.push({
            name: change.name,
            id: numKey, // Temporary negative ID
            start: change.newStart,
            end: change.newEnd,
            color: change.color,
            _pendingKey: numKey, // Key in pendingChanges (negative)
            _isNew: true,
          });
        }
      }
    }

    // Sort by start time
    return result.sort((a, b) => a.start - b.start);
  },

  getPendingChange: (index) => get().pendingChanges[index],

  // Get preview regions during drag operation (shows live preview with ripple effects)
  getDragPreviewRegions: (regions) => {
    const state = get();
    const { dragType, dragRegionIndex, dragStartTime, dragCurrentTime } = state;

    // First get display regions (with pending changes applied)
    const displayRegions = state.getDisplayRegions(regions);

    // If not dragging, return display regions as-is
    if (dragType === 'none' || dragRegionIndex === null || dragStartTime === null || dragCurrentTime === null) {
      set({ insertionPoint: null });
      return displayRegions;
    }

    const delta = dragCurrentTime - dragStartTime;
    if (Math.abs(delta) < 0.01) {
      set({ insertionPoint: null });
      return displayRegions; // No significant movement
    }

    // Create a mutable copy for preview calculations
    const previewRegions = displayRegions.map((r, idx) => ({ ...r, _originalIdx: idx }));
    const draggedRegion = previewRegions[dragRegionIndex];
    if (!draggedRegion) return displayRegions;

    if (dragType === 'resize-start') {
      // Preview resize start edge
      let newStart = Math.max(0, dragCurrentTime);
      // Snap to beat grid if BPM is available
      const bpm = (get() as { bpm?: number | null }).bpm;
      if (bpm && bpm > 0) {
        newStart = snapToBeats(newStart, bpm);
      }
      const minLength = 0.5; // Minimum 0.5 second for preview
      const originalStart = draggedRegion.start;

      if (draggedRegion.end - newStart >= minLength) {
        previewRegions[dragRegionIndex] = {
          ...draggedRegion,
          start: newStart,
        };
        set({ insertionPoint: null, resizeEdgePosition: newStart });

        // RIPPLE: When extending start backwards, trim overlapped regions
        // Regions that overlap with the new position get their end trimmed
        if (newStart < originalStart) {
          for (let i = 0; i < previewRegions.length; i++) {
            if (i === dragRegionIndex) continue;
            const region = previewRegions[i];
            // If this region ends after the new start and starts before the new start,
            // it's being overlapped - trim its end to the new start
            if (region.end > newStart && region.start < newStart) {
              previewRegions[i] = {
                ...region,
                end: newStart,
              };
            }
          }
        }
      } else {
        set({ insertionPoint: null, resizeEdgePosition: null });
      }
    } else if (dragType === 'resize-end') {
      // Preview resize end edge
      let newEnd = dragCurrentTime;
      // Snap to beat grid if BPM is available
      const bpm = (get() as { bpm?: number | null }).bpm;
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
        set({ insertionPoint: null, resizeEdgePosition: newEnd });

        // RIPPLE: Shift subsequent regions when extending/shrinking end
        const resizeDelta = newEnd - originalEnd; // Positive = extending, negative = shrinking
        const epsilon = 0.001; // For floating point comparisons

        for (let i = 0; i < previewRegions.length; i++) {
          if (i === dragRegionIndex) continue;
          const region = previewRegions[i];
          // Only affect regions that start at or after the original end
          if (region.start >= originalEnd - epsilon) {
            previewRegions[i] = {
              ...region,
              start: region.start + resizeDelta,
              end: region.end + resizeDelta,
            };
          }
        }
      } else {
        set({ insertionPoint: null, resizeEdgePosition: null });
      }
    } else if (dragType === 'move') {
      const duration = draggedRegion.end - draggedRegion.start;
      const epsilon = 0.001; // For floating point comparisons

      // RIPPLE: "Remove then Insert" behavior
      // 1. Remove region from original position → gap closes (everything after shifts LEFT)
      // 2. Insert region at target position → gap opens (everything at/after shifts RIGHT)

      const dragFrom = draggedRegion.start; // Current position (with pending changes applied)
      // Note: Snapping to region boundaries is handled by Timeline.tsx before calling updateDrag
      const dragTo = Math.max(0, draggedRegion.start + delta); // Target position

      const newEnd = dragTo + duration;

      // Set the insertion point for the visual indicator
      set({ insertionPoint: dragTo, resizeEdgePosition: null });

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

          // Calculate net shift using "remove then insert" logic:
          // Step 1: If region was after original position, it shifts LEFT (gap closure)
          // Step 2: If region ends up at/after target, it shifts RIGHT (make room)
          let netShift = 0;

          if (P > dragFrom + epsilon) {
            // This region was after the dragged region - gap closure shifts it left
            const afterGapClosure = P - duration;
            netShift = -duration;

            // After gap closure, if it's at/after target, shift right to make room
            if (afterGapClosure >= dragTo - epsilon) {
              netShift += duration; // Net: 0
            }
          } else {
            // This region was before/at the dragged region
            // If it's at/after target, shift right to make room
            if (P >= dragTo - epsilon) {
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

      return finalRegions.sort((a, b) => a.start - b.start);
    }

    // Sort by start time for consistent display
    return previewRegions.sort((a, b) => a.start - b.start);
  },
});
