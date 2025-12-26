/**
 * Snap Utilities Tests
 *
 * Tests for time selection snap behavior.
 * When dragging to select time, the start/end should snap to:
 * - Region boundaries (start/end)
 * - Marker positions
 * - Playhead (edit cursor) position
 */

import { describe, it, expect } from 'vitest'
import { findNearestSnapTarget } from './snapUtils'

describe('findNearestSnapTarget', () => {
  const regions = [
    { start: 0, end: 10 },
    { start: 10, end: 20 },
    { start: 20, end: 30 },
  ]
  const markers = [{ position: 5 }, { position: 15 }, { position: 25 }]

  it('snaps to nearest region boundary', () => {
    // Time 9.8 is closest to region boundary at 10
    expect(findNearestSnapTarget(9.8, { regions, markers })).toBe(10)
  })

  it('snaps to nearest marker', () => {
    // Time 14.9 is closest to marker at 15
    expect(findNearestSnapTarget(14.9, { regions, markers })).toBe(15)
  })

  it('snaps to playhead position when nearest', () => {
    // Time 12.1 with playhead at 12 should snap to 12
    expect(findNearestSnapTarget(12.1, { regions, markers, playheadPosition: 12 })).toBe(12)
  })

  it('prefers region boundary over playhead when closer', () => {
    // Time 9.9 with playhead at 8 - region boundary at 10 is closer
    expect(findNearestSnapTarget(9.9, { regions, markers, playheadPosition: 8 })).toBe(10)
  })

  it('prefers playhead over region boundary when closer', () => {
    // Time 9.1 with playhead at 9 - playhead is closer than boundary at 10
    expect(findNearestSnapTarget(9.1, { regions, markers, playheadPosition: 9 })).toBe(9)
  })

  it('returns input time when no snap targets exist', () => {
    expect(findNearestSnapTarget(5.5, { regions: [], markers: [] })).toBe(5.5)
  })

  it('handles undefined playhead position', () => {
    // Should work without playhead, falling back to regions/markers
    expect(findNearestSnapTarget(9.8, { regions, markers, playheadPosition: undefined })).toBe(10)
  })
})
