/**
 * Region Edit state slice
 * Manages region editing mode, selection, and pending changes
 * Always uses ripple edit behavior (regions shift to accommodate changes)
 */

import type { StateCreator } from 'zustand';
import type { Region } from '../../core/types';

// Re-export types for consumers
export type { TimelineMode, DragType, PendingRegionChange, RegionEditSlice, DisplayRegion } from './regionEditSlice.types';
export type { DeleteMode, PendingChangesRecord, RegionEditHistorySnapshot } from './regionEditSlice.types';

import type { RegionEditSlice } from './regionEditSlice.types';
import {
  calculateResizeRipple,
  calculateMoveRipple,
  calculateCreateRipple,
  calculateDeleteRipple,
  calculateDragPreview,
} from './regionEdit';

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
  historyStack: [],
  redoStack: [],

  // Mode actions
  setTimelineMode: (mode) => {
    // When leaving region mode, cancel any pending changes
    if (mode === 'navigate' && get().hasPendingChanges()) {
      get().cancelChanges();
    }

    // When entering regions mode, auto-select the region at current playhead position
    let autoSelectedIndex: number[] = [];
    if (mode === 'regions') {
      // Access the full store to get position and regions
      const store = get() as { positionSeconds?: number; regions?: Region[] };
      const position = store.positionSeconds ?? 0;
      const regions = store.regions ?? [];

      // Find region containing the playhead (start <= position < end)
      const regionIndex = regions.findIndex(
        (r) => r.start <= position && position < r.end
      );
      if (regionIndex !== -1) {
        autoSelectedIndex = [regionIndex];
      }
    }

    set({ timelineMode: mode, selectedRegionIndices: autoSelectedIndex });
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
    get().pushToHistory();
    // Get beatsPerBar from time signature
    const store = get() as { timeSignature?: string };
    const timeSignature = store.timeSignature ?? '4/4';
    const [num] = timeSignature.split('/').map(Number);
    const beatsPerBar = num || 4;

    const changes = calculateResizeRipple({
      index,
      edge,
      newTime,
      regions,
      bpm,
      beatsPerBar,
      pendingChanges: get().pendingChanges,
    });
    set({ pendingChanges: changes });
  },

  moveRegion: (indices, deltaTime, regions) => {
    get().pushToHistory();
    const changes = calculateMoveRipple({
      indices,
      deltaTime,
      regions,
      pendingChanges: get().pendingChanges,
    });
    set({ pendingChanges: changes });
  },

  createRegion: (start, end, name, bpm, color, regions) => {
    get().pushToHistory();
    // Get beatsPerBar from time signature
    const store = get() as { timeSignature?: string };
    const timeSignature = store.timeSignature ?? '4/4';
    const [num] = timeSignature.split('/').map(Number);
    const beatsPerBar = num || 4;

    const result = calculateCreateRipple({
      start,
      end,
      name,
      bpm,
      beatsPerBar,
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

  deleteRegion: (index, regions) => {
    const region = regions[index];
    if (!region) return;

    get().pushToHistory();
    set({
      pendingChanges: {
        ...get().pendingChanges,
        [index]: {
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
      selectedRegionIndices: get().selectedRegionIndices.filter((i) => i !== index),
    });
  },

  deleteRegionWithMode: (index, mode, regions) => {
    get().pushToHistory();
    const changes = calculateDeleteRipple({
      index,
      mode,
      regions,
      pendingChanges: get().pendingChanges,
    });
    set({
      pendingChanges: changes,
      selectedRegionIndices: get().selectedRegionIndices.filter((i) => i !== index),
    });
  },

  updateRegionMeta: (index, updates, regions) => {
    get().pushToHistory();
    const changes = { ...get().pendingChanges };
    const existing = changes[index];

    // Handle new regions (negative keys) - they only exist in pendingChanges
    if (index < 0) {
      if (!existing) return;
      changes[index] = {
        ...existing,
        name: updates.name ?? existing.name,
        color: updates.color ?? existing.color,
      };
    } else {
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
    set({
      pendingChanges: {},
      nextNewRegionKey: -1,
      selectedRegionIndices: [],
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
      selectedRegionIndices: [],
      isCommitting: false,
      commitError: null,
      historyStack: [],
      redoStack: [],
    }),

  setCommitting: (committing) => set({ isCommitting: committing }),
  setCommitError: (error) => set({ commitError: error }),

  // Undo/redo actions
  pushToHistory: () => {
    const { pendingChanges, nextNewRegionKey, selectedRegionIndices, historyStack } = get();
    const maxHistorySize = 50;

    // Create snapshot of current state
    const snapshot = {
      pendingChanges: { ...pendingChanges },
      nextNewRegionKey,
      selectedRegionIndices: [...selectedRegionIndices],
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
    const { historyStack, pendingChanges, nextNewRegionKey, selectedRegionIndices, redoStack } = get();

    if (historyStack.length === 0) return;

    // Save current state to redo stack before reverting
    const currentSnapshot = {
      pendingChanges: { ...pendingChanges },
      nextNewRegionKey,
      selectedRegionIndices: [...selectedRegionIndices],
    };

    // Pop last state from history stack
    const newHistoryStack = [...historyStack];
    const previousState = newHistoryStack.pop()!;

    set({
      pendingChanges: previousState.pendingChanges,
      nextNewRegionKey: previousState.nextNewRegionKey,
      selectedRegionIndices: previousState.selectedRegionIndices,
      historyStack: newHistoryStack,
      redoStack: [...redoStack, currentSnapshot],
    });
  },

  redo: () => {
    const { redoStack, pendingChanges, nextNewRegionKey, selectedRegionIndices, historyStack } = get();

    if (redoStack.length === 0) return;

    // Save current state to history stack
    const currentSnapshot = {
      pendingChanges: { ...pendingChanges },
      nextNewRegionKey,
      selectedRegionIndices: [...selectedRegionIndices],
    };

    // Pop from redo stack
    const newRedoStack = [...redoStack];
    const nextState = newRedoStack.pop()!;

    set({
      pendingChanges: nextState.pendingChanges,
      nextNewRegionKey: nextState.nextNewRegionKey,
      selectedRegionIndices: nextState.selectedRegionIndices,
      historyStack: [...historyStack, currentSnapshot],
      redoStack: newRedoStack,
    });
  },

  canUndo: () => get().historyStack.length > 0,

  canRedo: () => get().redoStack.length > 0,

  clearHistory: () => set({ historyStack: [], redoStack: [] }),

  // Lua detection
  setLuaScriptInstalled: (installed) => set({ luaScriptInstalled: installed }),
  setLuaScriptChecked: (checked) => set({ luaScriptChecked: checked }),

  // Helpers
  hasPendingChanges: () => Object.keys(get().pendingChanges).length > 0,

  getDisplayRegions: (regions) => {
    const pending = get().pendingChanges;
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
            _pendingKey: i,
          });
        }
      } else {
        result.push({
          ...regions[i],
          _pendingKey: i,
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
            id: numKey,
            start: change.newStart,
            end: change.newEnd,
            color: change.color,
            _pendingKey: numKey,
            _isNew: true,
          });
        }
      }
    }

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
      return displayRegions;
    }

    // Use the extracted drag preview calculation
    const result = calculateDragPreview(displayRegions, {
      dragType,
      dragRegionIndex,
      dragStartTime,
      dragCurrentTime,
      bpm: (get() as { bpm?: number | null }).bpm,
    });

    set({
      insertionPoint: result.insertionPoint,
      resizeEdgePosition: result.resizeEdgePosition,
    });

    return result.regions;
  },
});

// Re-export helpers that may be needed externally
export { snapToBeats, getMinRegionLength } from './regionEdit';
