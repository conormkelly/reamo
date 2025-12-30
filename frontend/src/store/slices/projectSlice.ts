/**
 * Project state slice
 * Manages REAPER's project-level undo/redo state and tempo map
 * Note: This is SEPARATE from regionEditSlice's local undo/redo for uncommitted region changes
 */

import type { StateCreator } from 'zustand';
import type { WSTempoMarker } from '../../core/WebSocketTypes';

export interface ProjectSlice {
  // State - REAPER's project-level undo/redo
  reaperCanUndo: string | null; // Description of next undo action, or null
  reaperCanRedo: string | null; // Description of next redo action, or null

  // Tempo map - for bar-aware time calculations
  tempoMarkers: WSTempoMarker[];

  // Actions
  setReaperUndoState: (canUndo: string | null, canRedo: string | null) => void;
  setTempoMarkers: (markers: WSTempoMarker[]) => void;
}

export const createProjectSlice: StateCreator<ProjectSlice> = (set) => ({
  // Initial state
  reaperCanUndo: null,
  reaperCanRedo: null,
  tempoMarkers: [],

  // Actions
  setReaperUndoState: (canUndo, canRedo) => set({ reaperCanUndo: canUndo, reaperCanRedo: canRedo }),
  setTempoMarkers: (markers) => set({ tempoMarkers: markers }),
});
