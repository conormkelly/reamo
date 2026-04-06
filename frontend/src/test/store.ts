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
    regions,
    timelineMode: mode,
    selectedRegionIds: [],
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
 * Find a region by name
 */
export function findRegion(name: string): Region | undefined {
  return store().regions.find(r => r.name === name)
}

/**
 * Get region positions as a simple object for assertions
 */
export function positions(): Record<string, { start: number; end: number }> {
  const result: Record<string, { start: number; end: number }> = {}
  for (const r of store().regions) {
    result[r.name] = { start: r.start, end: r.end }
  }
  return result
}

/**
 * Get region order (names sorted by start time)
 */
export function regionOrder(): string[] {
  return [...store().regions].sort((a, b) => a.start - b.start).map(r => r.name)
}

// ============================================================================
// State Queries
// ============================================================================

/**
 * Check if a region is selected (by ID)
 */
export function isSelected(id: number): boolean {
  return store().isRegionSelected(id)
}

/**
 * Get selected region IDs
 */
export function selectedIds(): number[] {
  return store().selectedRegionIds
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
  /** Select a region by ID */
  select: (id: number) => store().selectRegion(id),

  /** Add region to selection by ID */
  addToSelection: (id: number) => store().addToSelection(id),

  /** Deselect a region by ID */
  deselect: (id: number) => store().deselectRegion(id),

  /** Clear all selection */
  clearSelection: () => store().clearSelection(),

  /** Set timeline mode */
  setMode: (mode: TimelineMode) => store().setTimelineMode(mode),
}
