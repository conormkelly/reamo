/**
 * Store Test Utilities
 *
 * Helpers for setting up and querying Zustand store state in tests.
 */

import { useReaperStore } from '../store'
import type { Region } from '../core/types'
import type { TimelineMode } from '../store/slices/regionEditSlice'

// ============================================================================
// Store Setup
// ============================================================================

/**
 * Reset store to clean state with given regions
 */
export function setupStore(regions: Region[], mode: TimelineMode = 'regions') {
  useReaperStore.setState({
    // Regions slice
    regions,

    // Region edit slice - reset to defaults
    timelineMode: mode,
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
    luaScriptInstalled: true,
    luaScriptChecked: true,
    isCommitting: false,
    commitError: null,
  })

  return useReaperStore.getState()
}

/**
 * Get fresh store state (always call this, don't cache getState())
 */
export function store() {
  return useReaperStore.getState()
}

// ============================================================================
// Region Queries
// ============================================================================

/**
 * Get display regions (with pending changes applied)
 */
export function displayRegions(): Region[] {
  const state = store()
  return state.getDisplayRegions(state.regions)
}

/**
 * Find a region by name in display regions
 */
export function findRegion(name: string): Region | undefined {
  return displayRegions().find(r => r.name === name)
}

/**
 * Get region positions as a simple object for assertions
 */
export function positions(): Record<string, { start: number; end: number }> {
  const result: Record<string, { start: number; end: number }> = {}
  for (const r of displayRegions()) {
    result[r.name] = { start: r.start, end: r.end }
  }
  return result
}

/**
 * Get region order (names sorted by start time)
 */
export function regionOrder(): string[] {
  return displayRegions().map(r => r.name)
}

// ============================================================================
// State Queries
// ============================================================================

/**
 * Check if store has pending changes
 */
export function hasPendingChanges(): boolean {
  return store().hasPendingChanges()
}

/**
 * Check if a region is selected (by index)
 */
export function isSelected(index: number): boolean {
  return store().isRegionSelected(index)
}

/**
 * Get selected region indices
 */
export function selectedIndices(): number[] {
  return store().selectedRegionIndices
}

/**
 * Get current timeline mode
 */
export function mode(): TimelineMode {
  return store().timelineMode
}

// ============================================================================
// Actions (wrapped for convenience)
// ============================================================================

export const actions = {
  /** Select a region by index */
  select: (index: number) => store().selectRegion(index),

  /** Add region to selection */
  addToSelection: (index: number) => store().addToSelection(index),

  /** Deselect a region */
  deselect: (index: number) => store().deselectRegion(index),

  /** Clear all selection */
  clearSelection: () => store().clearSelection(),

  /** Move region(s) by delta seconds */
  move: (indices: number[], deltaSeconds: number) => {
    const state = store()
    state.moveRegion(indices, deltaSeconds, state.regions)
  },

  /** Resize region edge */
  resize: (index: number, edge: 'start' | 'end', newTime: number, bpm: number = 120) => {
    const state = store()
    state.resizeRegion(index, edge, newTime, state.regions, bpm)
  },

  /** Create a new region */
  create: (start: number, end: number, name: string, bpm: number = 120, color?: number) => {
    const state = store()
    state.createRegion(start, end, name, bpm, color, state.regions)
  },

  /** Delete a region with mode */
  delete: (index: number, mode: 'leave-gap' | 'extend-previous' | 'ripple-back' = 'ripple-back') => {
    const state = store()
    state.deleteRegionWithMode(index, mode, state.regions)
  },

  /** Commit pending changes */
  commit: () => store().commitChanges(),

  /** Cancel pending changes */
  cancel: () => store().cancelChanges(),

  /** Set timeline mode */
  setMode: (mode: TimelineMode) => store().setTimelineMode(mode),
}
