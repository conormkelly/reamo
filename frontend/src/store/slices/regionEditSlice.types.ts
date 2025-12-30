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

/** Timeline mode: navigate (existing behavior), regions (editing), or items (waveform view) */
export type TimelineMode = 'navigate' | 'regions' | 'items';

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
  _isNew?: boolean;
};

/**
 * Record of pending changes keyed by REGION ID (not array index).
 *
 * - For existing regions: key = region.id (REAPER's markrgnidx, always positive)
 * - For new regions: key = negative number from nextNewRegionKey counter
 *
 * This ensures pending changes track correctly even when the server pushes
 * updates that change array indices (e.g., region added/deleted in REAPER).
 */
export type PendingChangesRecord = Record<number, PendingRegionChange>;

/**
 * A snapshot of the undoable region edit state
 * Used for undo/redo within a single editing session
 */
export interface RegionEditHistorySnapshot {
  pendingChanges: PendingChangesRecord;
  nextNewRegionKey: number;
  selectedRegionIds: number[];
}

export interface RegionEditSlice {
  // Mode state
  timelineMode: TimelineMode;

  // Selection state (region IDs, not array indices)
  selectedRegionIds: number[];

  // Pending changes (keyed by region ID, or negative for new regions)
  pendingChanges: PendingChangesRecord;
  nextNewRegionKey: number; // Counter for new region keys (negative)

  // Drag state
  dragType: DragType;
  dragRegionId: number | null;
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

  // Selection actions (all use region ID, not array index)
  selectRegion: (id: number) => void;
  addToSelection: (id: number) => void;
  deselectRegion: (id: number) => void;
  clearSelection: () => void;
  isRegionSelected: (id: number) => boolean;

  // Edit actions (all use region ID, not array index)
  resizeRegion: (id: number, edge: 'start' | 'end', newTime: number, regions: Region[], bpm: number | null) => void;
  moveRegion: (ids: number[], deltaTime: number, regions: Region[]) => void;
  createRegion: (start: number, end: number, name: string, bpm: number | null, color: number | undefined, regions: Region[]) => void;
  deleteRegion: (id: number, regions: Region[]) => void;
  deleteRegionWithMode: (id: number, mode: DeleteMode, regions: Region[]) => void;
  updateRegionMeta: (id: number, updates: { name?: string; color?: number }, regions: Region[]) => void;
  /** Update region bounds directly (no snapping, no ripple) - for precise info bar edits */
  updateRegionBounds: (id: number, updates: { start?: number; end?: number }, regions: Region[]) => void;

  // Drag actions (use region ID)
  startDrag: (type: DragType, id: number, x: number, time: number) => void;
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
  getPendingChange: (id: number) => PendingRegionChange | undefined;
  getDragPreviewRegions: (regions: Region[]) => Region[];
}
