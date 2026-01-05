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

  // Project dirty state - true when project has unsaved changes
  isProjectDirty: boolean;

  // Memory warning - true when arena utilization is high (any tier > 80%)
  memoryWarning: boolean;
  memoryWarningDismissed: boolean; // User dismissed the warning (session state)

  // Tempo map - for bar-aware time calculations
  tempoMarkers: WSTempoMarker[];

  // Actions
  setReaperUndoState: (canUndo: string | null, canRedo: string | null) => void;
  setProjectDirty: (isDirty: boolean) => void;
  setMemoryWarning: (warning: boolean) => void;
  dismissMemoryWarning: () => void;
  setTempoMarkers: (markers: WSTempoMarker[]) => void;
}

export const createProjectSlice: StateCreator<ProjectSlice> = (set) => ({
  // Initial state
  reaperCanUndo: null,
  reaperCanRedo: null,
  isProjectDirty: false,
  memoryWarning: false,
  memoryWarningDismissed: false,
  tempoMarkers: [],

  // Actions
  setReaperUndoState: (canUndo, canRedo) => set({ reaperCanUndo: canUndo, reaperCanRedo: canRedo }),
  setProjectDirty: (isDirty) => set({ isProjectDirty: isDirty }),
  setMemoryWarning: (warning) => set({ memoryWarning: warning }),
  dismissMemoryWarning: () => set({ memoryWarningDismissed: true }),
  setTempoMarkers: (markers) => set({ tempoMarkers: markers }),
});
