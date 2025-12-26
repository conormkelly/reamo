/**
 * Type definitions for region editing state
 */

import type { Region } from '../../core/types';

/**
 * Properties from other slices that RegionEditSlice needs access to.
 * Used to properly type the StateCreator so get() returns the correct type.
 */
export interface RegionEditSharedState {
  positionSeconds: number;
  regions: Region[];
  bpm: number | null;
  timeSignatureNumerator: number;
  timeSignatureDenominator: number;
}

/** Timeline mode: navigate (existing behavior) or regions (editing) */
export type TimelineMode = 'navigate' | 'regions';

/** Drag operation type */
export type DragType = 'none' | 'resize-start' | 'resize-end' | 'move';

/** Delete operation mode */
export type DeleteMode = 'leave-gap' | 'extend-previous' | 'ripple-back';

/**
 * A pending change to a region (local only until committed)
 */
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

/** Extended region type with pending metadata for display */
export type DisplayRegion = Region & {
  _pendingKey: number;
  _isNew?: boolean;
};

/** Record of pending changes keyed by region index */
export type PendingChangesRecord = Record<number, PendingRegionChange>;

/**
 * A snapshot of the undoable region edit state
 * Used for undo/redo within a single editing session
 */
export interface RegionEditHistorySnapshot {
  pendingChanges: PendingChangesRecord;
  nextNewRegionKey: number;
  selectedRegionIndices: number[];
}

export interface RegionEditSlice {
  // Mode state
  timelineMode: TimelineMode;

  // Selection state (indices into the regions array)
  selectedRegionIndices: number[];

  // Pending changes (keyed by original index, or negative for new regions)
  pendingChanges: PendingChangesRecord;
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

  // Commit state
  isCommitting: boolean;
  commitError: string | null;

  // Undo/redo history (local to editing session)
  historyStack: RegionEditHistorySnapshot[];
  redoStack: RegionEditHistorySnapshot[];

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
  deleteRegionWithMode: (index: number, mode: DeleteMode, regions: Region[]) => void;
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

  // Undo/redo actions
  undo: () => void;
  redo: () => void;
  canUndo: () => boolean;
  canRedo: () => boolean;
  clearHistory: () => void;
  pushToHistory: () => void;

  // Helpers
  hasPendingChanges: () => boolean;
  getDisplayRegions: (regions: Region[]) => DisplayRegion[];
  getPendingChange: (index: number) => PendingRegionChange | undefined;
  getDragPreviewRegions: (regions: Region[]) => Region[];
}
