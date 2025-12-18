/**
 * Test Fixtures
 *
 * Factory functions for creating test data.
 * All fixtures are immutable - they return new objects each call.
 */

import type { Region, Marker } from '../core/types'

// ============================================================================
// Region Fixtures
// ============================================================================

/**
 * Create a single region
 */
export function region(
  name: string,
  start: number,
  end: number,
  options?: { id?: number; color?: number }
): Region {
  return {
    id: options?.id ?? Math.floor(Math.random() * 10000),
    name,
    start,
    end,
    color: options?.color,
  }
}

/**
 * Standard 3-section song structure:
 * - Intro:  0-10s
 * - Verse:  10-20s
 * - Chorus: 20-30s
 */
export function songStructure(): Region[] {
  return [
    { id: 0, name: 'Intro', start: 0, end: 10, color: 0xff0000 },
    { id: 1, name: 'Verse', start: 10, end: 20, color: 0x00ff00 },
    { id: 2, name: 'Chorus', start: 20, end: 30, color: 0x0000ff },
  ]
}

/**
 * Extended song with more sections:
 * Intro → Verse → Pre-Chorus → Chorus → Verse → Chorus → Bridge → Outro
 */
export function fullSong(): Region[] {
  return [
    { id: 0, name: 'Intro', start: 0, end: 8 },
    { id: 1, name: 'Verse 1', start: 8, end: 24 },
    { id: 2, name: 'Pre-Chorus', start: 24, end: 32 },
    { id: 3, name: 'Chorus', start: 32, end: 48 },
    { id: 4, name: 'Verse 2', start: 48, end: 64 },
    { id: 5, name: 'Chorus 2', start: 64, end: 80 },
    { id: 6, name: 'Bridge', start: 80, end: 96 },
    { id: 7, name: 'Outro', start: 96, end: 104 },
  ]
}

/**
 * Create N consecutive regions of equal length
 */
export function consecutiveRegions(
  count: number,
  duration: number = 10,
  startAt: number = 0
): Region[] {
  return Array.from({ length: count }, (_, i) => ({
    id: i,
    name: `Region ${i + 1}`,
    start: startAt + i * duration,
    end: startAt + (i + 1) * duration,
  }))
}

// ============================================================================
// Marker Fixtures
// ============================================================================

/**
 * Create a single marker
 */
export function marker(
  name: string,
  position: number,
  options?: { id?: number; color?: number }
): Marker {
  return {
    id: options?.id ?? Math.floor(Math.random() * 10000),
    name,
    position,
    color: options?.color,
  }
}

/**
 * Create markers at region boundaries
 */
export function boundaryMarkers(regions: Region[]): Marker[] {
  const positions = new Set<number>()
  regions.forEach(r => {
    positions.add(r.start)
    positions.add(r.end)
  })
  return Array.from(positions)
    .sort((a, b) => a - b)
    .map((pos, i) => ({
      id: i + 1,
      name: `M${i + 1}`,
      position: pos,
    }))
}

// ============================================================================
// Time/Position Fixtures
// ============================================================================

/**
 * Standard BPM for tests (120 = easy math: 1 beat = 0.5s, 1 bar = 2s)
 */
export const BPM = 120

/**
 * Calculate bar duration at given BPM
 */
export function barDuration(bpm: number = BPM): number {
  return (60 / bpm) * 4 // 4 beats per bar
}

/**
 * Convert bars to seconds
 */
export function bars(count: number, bpm: number = BPM): number {
  return count * barDuration(bpm)
}

/**
 * Convert beats to seconds
 */
export function beats(count: number, bpm: number = BPM): number {
  return count * (60 / bpm)
}
