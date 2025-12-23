/**
 * Behavior-Driven Tests for Region Editing
 *
 * Tests describe what users do and what they expect to see.
 * Uses clean utilities from src/test for easy reading and writing.
 */

import { describe, it, expect, beforeEach } from 'vitest'
import {
  songStructure,
  BPM,
} from '../../test/fixtures'
import {
  setupStore,
  findRegion,
  positions,
  regionOrder,
  hasPendingChanges,
  isSelected,
  selectedIndices,
  actions,
} from '../../test/store'

// ============================================================================
// User Story: Rearranging Song Sections
// ============================================================================

describe('Rearranging Song Sections', () => {
  beforeEach(() => {
    setupStore(songStructure())
  })

  describe('moving a section to a new position', () => {
    it('moves the section', () => {
      actions.move([2], -20) // Move Chorus to beginning

      expect(findRegion('Chorus')?.start).toBe(0)
    })

    it('reorders other sections', () => {
      actions.move([2], -10) // Move Chorus between Intro and Verse

      expect(regionOrder()).toEqual(['Intro', 'Chorus', 'Verse'])
    })

    it('marks changes as pending', () => {
      expect(hasPendingChanges()).toBe(false)

      actions.move([0], 5)

      expect(hasPendingChanges()).toBe(true)
    })

    it('allows multiple edits before saving', () => {
      actions.move([0], 5)
      actions.move([2], -5)

      expect(hasPendingChanges()).toBe(true)
    })
  })

  describe('saving changes', () => {
    it('clears pending state', () => {
      actions.move([0], 5)
      actions.commit()

      expect(hasPendingChanges()).toBe(false)
    })
  })

  describe('cancelling changes', () => {
    it('reverts to original positions', () => {
      const original = positions()

      actions.move([0], 5)
      actions.cancel()

      expect(positions()).toEqual(original)
    })
  })
})

// ============================================================================
// User Story: Extending/Shrinking Sections
// ============================================================================

describe('Extending/Shrinking Sections', () => {
  beforeEach(() => {
    setupStore(songStructure())
  })

  describe('extending a section', () => {
    it('makes the section longer', () => {
      actions.resize(0, 'end', 15, BPM) // Extend Intro to 15s

      expect(findRegion('Intro')?.end).toBe(15)
    })

    it('shifts following sections', () => {
      actions.resize(0, 'end', 15, BPM)

      expect(findRegion('Verse')?.start).toBe(15)
      expect(findRegion('Chorus')?.start).toBe(25)
    })
  })

  describe('shrinking a section', () => {
    it('makes the section shorter', () => {
      actions.resize(0, 'end', 8, BPM)

      expect(findRegion('Intro')?.end).toBe(8)
    })

    it('shifts following sections back', () => {
      actions.resize(0, 'end', 8, BPM)

      expect(findRegion('Verse')?.start).toBe(8)
    })
  })

  describe('extending start edge', () => {
    it('trims the previous section', () => {
      actions.resize(1, 'start', 5, BPM) // Extend Verse start to 5s

      expect(findRegion('Intro')?.end).toBe(5)
    })
  })

  describe('minimum length constraint', () => {
    it('enforces minimum of 1 bar', () => {
      // At 120 BPM, 1 bar = 2 seconds
      actions.resize(0, 'end', 0.5, BPM)

      const intro = findRegion('Intro')!
      expect(intro.end - intro.start).toBeGreaterThanOrEqual(2)
    })
  })
})

// ============================================================================
// User Story: Selecting Sections
// ============================================================================

describe('Selecting Sections', () => {
  beforeEach(() => {
    setupStore(songStructure())
  })

  describe('tapping a section', () => {
    it('selects the section', () => {
      actions.select(0)

      expect(isSelected(0)).toBe(true)
    })

    it('deselects others', () => {
      actions.select(1)
      actions.select(0)

      expect(isSelected(0)).toBe(true)
      expect(isSelected(1)).toBe(false)
    })
  })

  describe('tapping selected section', () => {
    it('deselects it', () => {
      actions.select(0)
      actions.deselect(0)

      expect(isSelected(0)).toBe(false)
    })
  })

  describe('multi-selecting', () => {
    it('selects multiple sections', () => {
      actions.select(0)
      actions.addToSelection(2)

      expect(selectedIndices()).toEqual([0, 2])
    })

    it('allows moving multiple together', () => {
      actions.select(0)
      actions.addToSelection(1)
      actions.move([0, 1], 5)

      expect(findRegion('Intro')?.start).toBe(5)
      expect(findRegion('Verse')?.start).toBe(15)
    })
  })

  describe('clearing selection', () => {
    it('deselects all', () => {
      actions.select(0)
      actions.clearSelection()

      expect(selectedIndices()).toEqual([])
    })
  })
})

// ============================================================================
// User Story: Creating New Sections
// ============================================================================

describe('Creating New Sections', () => {
  beforeEach(() => {
    setupStore(songStructure())
  })

  it('adds section at specified position', () => {
    actions.create(30, 40, 'Bridge', BPM)

    expect(findRegion('Bridge')).toBeDefined()
    expect(findRegion('Bridge')?.start).toBe(30)
  })

  it('marks as pending', () => {
    actions.create(30, 40, 'Bridge', BPM)

    expect(hasPendingChanges()).toBe(true)
  })

  it('shifts following sections when inserting', () => {
    // Insert 5-second Pre-Chorus at position 15 (middle of Verse)
    actions.create(15, 20, 'Pre-Chorus', BPM)

    expect(findRegion('Verse')?.end).toBe(15) // Trimmed
    expect(findRegion('Chorus')?.start).toBe(25) // Shifted by 5s
  })
})

// ============================================================================
// User Story: Deleting Sections
// ============================================================================

describe('Deleting Sections', () => {
  beforeEach(() => {
    setupStore(songStructure())
  })

  describe('with ripple', () => {
    it('removes the section', () => {
      actions.delete(1, 'ripple-back')

      expect(findRegion('Verse')).toBeUndefined()
    })

    it('shifts following sections back', () => {
      actions.delete(1, 'ripple-back')

      expect(findRegion('Chorus')?.start).toBe(10)
    })
  })

  describe('leaving gap', () => {
    it('keeps following sections in place', () => {
      actions.delete(1, 'leave-gap')

      expect(findRegion('Chorus')?.start).toBe(20)
    })
  })

  describe('extending previous', () => {
    it('fills gap with previous section', () => {
      actions.delete(1, 'extend-previous')

      expect(findRegion('Intro')?.end).toBe(20)
    })
  })
})

// ============================================================================
// Edge Cases
// ============================================================================

describe('Edge Cases', () => {
  beforeEach(() => {
    setupStore(songStructure())
  })

  it('can move section to position 0', () => {
    actions.move([2], -20)

    expect(findRegion('Chorus')?.start).toBe(0)
  })

  it('clamps movement at position 0', () => {
    actions.move([0], -10)

    expect(findRegion('Intro')?.start).toBeGreaterThanOrEqual(0)
  })

  describe('switching modes', () => {
    it('cancels pending changes', () => {
      actions.move([0], 5)
      actions.setMode('navigate')

      expect(hasPendingChanges()).toBe(false)
    })

    it('clears selection', () => {
      actions.select(0)
      actions.setMode('navigate')

      expect(selectedIndices()).toEqual([])
    })
  })
})
