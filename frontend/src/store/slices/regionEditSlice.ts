/**
 * Region Edit state slice
 * Manages region editing mode, selection, and pending changes
 * Always uses ripple edit behavior (regions shift to accommodate changes)
 *
 * KEY DESIGN: All region references use region.id (REAPER's markrgnidx),
 * NOT array indices. This ensures stability when server pushes updates
 * that change array ordering.
 */

import type { StateCreator } from 'zustand';
import type { Region } from '../../core/types';

// Re-export types for consumers
export type { TimelineMode, DragType, PendingRegionChange, RegionEditSlice, DisplayRegion } from './regionEditSlice.types';
export type { DeleteMode, PendingChangesRecord, RegionEditHistorySnapshot, RegionEditSharedState } from './regionEditSlice.types';

// Re-export pure helper functions for direct use by components
// These allow components to call with explicit dependencies, satisfying ESLint exhaustive-deps
export { computeDisplayRegions, computeDragPreview } from './regionDisplayHelpers';
export type { DragState, DragPreviewResult } from './regionDisplayHelpers';

import type { RegionEditSlice, RegionEditSharedState } from './regionEditSlice.types';
import {
  calculateResizeRipple,
  calculateMoveRipple,
  calculateCreateRipple,
  calculateDeleteRipple,
} from './regionEdit';
import { computeDisplayRegions, computeDragPreview } from './regionDisplayHelpers';

/** Combined store type for proper typing of get() - includes shared state from other slices */
type RegionEditStore = RegionEditSharedState & RegionEditSlice;

/** Helper to find a region by ID (works for both positive IDs from REAPER and negative IDs for new regions) */
function findRegionById(regions: Region[], id: number): Region | undefined {
  // Negative IDs are new regions that don't exist in the regions array
  if (id < 0) return undefined;
  return regions.find((r) => r.id === id);
}

export const createRegionEditSlice: StateCreator<RegionEditStore, [], [], RegionEditSlice> = (set, get) => ({
  // Initial state
  timelineMode: 'navigate',
  selectedRegionIds: [],
  pendingChanges: {},
  nextNewRegionKey: -1,
  dragType: 'none',
  dragRegionId: null,
  dragStartX: null,
  dragStartTime: null,
  dragCurrentTime: null,
  insertionPoint: null,
  resizeEdgePosition: null,
  isCommitting: false,
  commitError: null,
  historyStack: [],
  redoStack: [],

  // Mode actions
  setTimelineMode: (mode) => {
    // When leaving region mode, cancel any pending changes
    if (mode === 'navigate' && get().hasPendingChanges()) {
      get().cancelChanges();
    }

    // When entering regions mode, auto-select the region at current playhead position
    let autoSelectedIds: number[] = [];
    if (mode === 'regions') {
      const { positionSeconds, regions } = get();

      // Find region containing the playhead (start <= position < end)
      const region = regions.find(
        (r) => r.start <= positionSeconds && positionSeconds < r.end
      );
      if (region) {
        autoSelectedIds = [region.id];
      }
    }

    set({ timelineMode: mode, selectedRegionIds: autoSelectedIds });
  },

  // Selection actions (all use region ID)
  selectRegion: (id) => set({ selectedRegionIds: [id] }),

  addToSelection: (id) => {
    const current = get().selectedRegionIds;
    if (!current.includes(id)) {
      set({ selectedRegionIds: [...current, id].sort((a, b) => a - b) });
    }
  },

  deselectRegion: (id) => {
    const current = get().selectedRegionIds;
    set({ selectedRegionIds: current.filter((i) => i !== id) });
  },

  clearSelection: () => set({ selectedRegionIds: [] }),

  isRegionSelected: (id) => get().selectedRegionIds.includes(id),

  // Edit actions (all use region ID, always ripple mode)
  resizeRegion: (id, edge, newTime, regions, bpm) => {
    get().pushToHistory();
    const { timeSignatureNumerator, timeSignatureDenominator } = get();

    const changes = calculateResizeRipple({
      id,
      edge,
      newTime,
      regions,
      bpm,
      beatsPerBar: timeSignatureNumerator,
      denominator: timeSignatureDenominator,
      pendingChanges: get().pendingChanges,
    });
    set({ pendingChanges: changes });
  },

  moveRegion: (ids, deltaTime, regions) => {
    get().pushToHistory();
    const changes = calculateMoveRipple({
      ids,
      deltaTime,
      regions,
      pendingChanges: get().pendingChanges,
    });
    set({ pendingChanges: changes });
  },

  createRegion: (start, end, name, bpm, color, regions) => {
    get().pushToHistory();
    const { timeSignatureNumerator, timeSignatureDenominator } = get();

    const result = calculateCreateRipple({
      start,
      end,
      name,
      bpm,
      beatsPerBar: timeSignatureNumerator,
      denominator: timeSignatureDenominator,
      color,
      regions,
      pendingChanges: get().pendingChanges,
      nextNewRegionKey: get().nextNewRegionKey,
    });
    set({
      pendingChanges: result.changes,
      nextNewRegionKey: result.newRegionKey,
    });
  },

  deleteRegion: (id, regions) => {
    // For new regions (negative ID), they only exist in pendingChanges
    if (id < 0) {
      const existing = get().pendingChanges[id];
      if (!existing) return;

      get().pushToHistory();
      const changes = { ...get().pendingChanges };
      delete changes[id]; // Just remove from pendingChanges
      set({
        pendingChanges: changes,
        selectedRegionIds: get().selectedRegionIds.filter((i) => i !== id),
      });
      return;
    }

    // For existing regions, find by ID
    const region = findRegionById(regions, id);
    if (!region) return;

    get().pushToHistory();
    set({
      pendingChanges: {
        ...get().pendingChanges,
        [id]: {
          originalIdx: region.id,
          originalStart: region.start,
          originalEnd: region.end,
          newStart: region.start,
          newEnd: region.end,
          name: region.name,
          color: region.color,
          isDeleted: true,
        },
      },
      selectedRegionIds: get().selectedRegionIds.filter((i) => i !== id),
    });
  },

  deleteRegionWithMode: (id, mode, regions) => {
    get().pushToHistory();
    const changes = calculateDeleteRipple({
      id,
      mode,
      regions,
      pendingChanges: get().pendingChanges,
    });
    set({
      pendingChanges: changes,
      selectedRegionIds: get().selectedRegionIds.filter((i) => i !== id),
    });
  },

  updateRegionMeta: (id, updates, regions) => {
    get().pushToHistory();
    const changes = { ...get().pendingChanges };
    const existing = changes[id];

    // Handle new regions (negative keys) - they only exist in pendingChanges
    if (id < 0) {
      if (!existing) return;
      changes[id] = {
        ...existing,
        name: updates.name ?? existing.name,
        color: updates.color ?? existing.color,
      };
    } else {
      const region = findRegionById(regions, id);
      if (!region) return;

      changes[id] = {
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

  // Update region bounds directly (no snapping, no ripple) - for precise info bar edits
  updateRegionBounds: (id, updates, regions) => {
    get().pushToHistory();
    const changes = { ...get().pendingChanges };
    const existing = changes[id];

    // Handle new regions (negative keys) - they only exist in pendingChanges
    if (id < 0) {
      if (!existing) return;
      const newStart = updates.start ?? existing.newStart;
      const newEnd = updates.end ?? existing.newEnd;
      // Validate bounds
      if (newStart >= newEnd || newStart < 0) return;
      changes[id] = {
        ...existing,
        newStart,
        newEnd,
      };
    } else {
      const region = findRegionById(regions, id);
      if (!region) return;

      const currentStart = existing?.newStart ?? region.start;
      const currentEnd = existing?.newEnd ?? region.end;
      const newStart = updates.start ?? currentStart;
      const newEnd = updates.end ?? currentEnd;

      // Validate bounds
      if (newStart >= newEnd || newStart < 0) return;

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

    set({ pendingChanges: changes });
  },

  // Drag actions (use region ID)
  startDrag: (type, id, x, time) =>
    set({
      dragType: type,
      dragRegionId: id,
      dragStartX: x,
      dragStartTime: time,
      dragCurrentTime: time,
    }),

  updateDrag: (_x, time) => set({ dragCurrentTime: time }),

  endDrag: () =>
    set({
      dragType: 'none',
      dragRegionId: null,
      dragStartX: null,
      dragStartTime: null,
      dragCurrentTime: null,
      insertionPoint: null,
      resizeEdgePosition: null,
    }),

  cancelDrag: () =>
    set({
      dragType: 'none',
      dragRegionId: null,
      dragStartX: null,
      dragStartTime: null,
      dragCurrentTime: null,
      insertionPoint: null,
      resizeEdgePosition: null,
    }),

  // Commit/cancel actions
  commitChanges: () => {
    set({
      pendingChanges: {},
      nextNewRegionKey: -1,
      selectedRegionIds: [],
      isCommitting: false,
      commitError: null,
      historyStack: [],
      redoStack: [],
    });
  },

  cancelChanges: () =>
    set({
      pendingChanges: {},
      nextNewRegionKey: -1,
      selectedRegionIds: [],
      isCommitting: false,
      commitError: null,
      historyStack: [],
      redoStack: [],
    }),

  setCommitting: (committing) => set({ isCommitting: committing }),
  setCommitError: (error) => set({ commitError: error }),

  // Undo/redo actions
  pushToHistory: () => {
    const { pendingChanges, nextNewRegionKey, selectedRegionIds, historyStack } = get();
    const maxHistorySize = 50;

    // Create snapshot of current state
    const snapshot = {
      pendingChanges: { ...pendingChanges },
      nextNewRegionKey,
      selectedRegionIds: [...selectedRegionIds],
    };

    // Add to history stack, respecting max size
    const newStack = [...historyStack, snapshot];
    if (newStack.length > maxHistorySize) {
      newStack.shift(); // Remove oldest entry (FIFO)
    }

    set({
      historyStack: newStack,
      redoStack: [], // Clear redo stack on any new action
    });
  },

  undo: () => {
    const { historyStack, pendingChanges, nextNewRegionKey, selectedRegionIds, redoStack } = get();

    if (historyStack.length === 0) return;

    // Save current state to redo stack before reverting
    const currentSnapshot = {
      pendingChanges: { ...pendingChanges },
      nextNewRegionKey,
      selectedRegionIds: [...selectedRegionIds],
    };

    // Pop last state from history stack
    const newHistoryStack = [...historyStack];
    const previousState = newHistoryStack.pop()!;

    set({
      pendingChanges: previousState.pendingChanges,
      nextNewRegionKey: previousState.nextNewRegionKey,
      selectedRegionIds: previousState.selectedRegionIds,
      historyStack: newHistoryStack,
      redoStack: [...redoStack, currentSnapshot],
    });
  },

  redo: () => {
    const { redoStack, pendingChanges, nextNewRegionKey, selectedRegionIds, historyStack } = get();

    if (redoStack.length === 0) return;

    // Save current state to history stack
    const currentSnapshot = {
      pendingChanges: { ...pendingChanges },
      nextNewRegionKey,
      selectedRegionIds: [...selectedRegionIds],
    };

    // Pop from redo stack
    const newRedoStack = [...redoStack];
    const nextState = newRedoStack.pop()!;

    set({
      pendingChanges: nextState.pendingChanges,
      nextNewRegionKey: nextState.nextNewRegionKey,
      selectedRegionIds: nextState.selectedRegionIds,
      historyStack: [...historyStack, currentSnapshot],
      redoStack: newRedoStack,
    });
  },

  canUndo: () => get().historyStack.length > 0,

  canRedo: () => get().redoStack.length > 0,

  clearHistory: () => set({ historyStack: [], redoStack: [] }),

  // Helpers
  hasPendingChanges: () => Object.keys(get().pendingChanges).length > 0,

  getDisplayRegions: (regions) => {
    // Delegate to pure function - store method exists for backwards compatibility
    return computeDisplayRegions(regions, get().pendingChanges);
  },

  getPendingChange: (id) => get().pendingChanges[id],

  // Get preview regions during drag operation (shows live preview with ripple effects)
  // Note: This store method has side effects (sets insertionPoint/resizeEdgePosition).
  // For pure computation, use computeDragPreview() directly.
  getDragPreviewRegions: (regions) => {
    const state = get();

    // Delegate to pure function
    const result = computeDragPreview(
      regions,
      state.pendingChanges,
      {
        dragType: state.dragType,
        dragRegionId: state.dragRegionId,
        dragStartTime: state.dragStartTime,
        dragCurrentTime: state.dragCurrentTime,
      },
      state.bpm,
      state.timeSignatureDenominator
    );

    // Side effect: update insertion point and resize edge position in store
    set({
      insertionPoint: result.insertionPoint,
      resizeEdgePosition: result.resizeEdgePosition,
    });

    return result.regions;
  },
});

// Re-export helpers that may be needed externally
export { snapToBeats, getMinRegionLength } from './regionEdit';
