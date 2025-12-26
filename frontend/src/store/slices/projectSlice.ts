/**
 * Project state slice
 * Manages REAPER's project-level undo/redo state
 * Note: This is SEPARATE from regionEditSlice's local undo/redo for uncommitted region changes
 */

import type { StateCreator } from 'zustand';

export interface ProjectSlice {
  // State - REAPER's project-level undo/redo
  reaperCanUndo: string | null; // Description of next undo action, or null
  reaperCanRedo: string | null; // Description of next redo action, or null

  // Actions
  setReaperUndoState: (canUndo: string | null, canRedo: string | null) => void;
}

export const createProjectSlice: StateCreator<ProjectSlice> = (set) => ({
  // Initial state
  reaperCanUndo: null,
  reaperCanRedo: null,

  // Actions
  setReaperUndoState: (canUndo, canRedo) => set({ reaperCanUndo: canUndo, reaperCanRedo: canRedo }),
});
