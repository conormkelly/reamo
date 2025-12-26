/**
 * Timeline Component Integration Tests
 *
 * Tests the Timeline component with state integration.
 * Gesture tests use store actions directly to verify behavior,
 * while visual tests verify the component reflects state correctly.
 *
 * For full gesture testing (pointer events), use Playwright MCP.
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render, cleanup, act } from '@testing-library/react'
import { Timeline } from './Timeline'
import {
  songStructure,
} from '../../test/fixtures'
import {
  setupStore,
  actions,
  hasPendingChanges,
  isSelected,
  selectedIndices,
  findRegion,
} from '../../test/store'
import { useReaperStore } from '../../store'
import {
  findRegionElement,
  isVisuallySelected,
  getPositionPercent,
  findAllRegionElements,
} from '../../test/queries'

// ============================================================================
// Mocks
// ============================================================================

// Mock useReaper hook
vi.mock('../ReaperProvider', () => ({
  useReaper: () => ({
    send: vi.fn(),
    connected: true,
    errorCount: 0,
    start: vi.fn(),
    stop: vi.fn(),
    connection: null,
  }),
}))

// Mock TransportAnimationEngine - needed to control playhead position in tests
// The callback is invoked immediately upon subscription with current position
let mockAnimationPosition = 0
vi.mock('../../core/TransportAnimationEngine', () => ({
  transportEngine: {
    subscribe: (callback: (state: { position: number; positionBeats: string }) => void) => {
      callback({ position: mockAnimationPosition, positionBeats: '1.1.00' })
      return () => {}
    },
    getState: () => ({ position: mockAnimationPosition, positionBeats: '1.1.00' }),
  },
}))

// Mock getBoundingClientRect globally
const mockRect = {
  left: 0,
  top: 0,
  width: 1000,
  height: 120,
  right: 1000,
  bottom: 120,
  x: 0,
  y: 0,
  toJSON: () => ({}),
}

// ============================================================================
// Tests: State Integration (verifies store <-> component sync)
// ============================================================================

describe('Timeline state integration', () => {
  beforeEach(() => {
    setupStore(songStructure())
    Element.prototype.getBoundingClientRect = vi.fn(() => mockRect)
  })

  afterEach(() => {
    cleanup()
    vi.restoreAllMocks()
  })

  it('displays all regions from store', () => {
    const { container } = render(<Timeline height={120} />)

    expect(findRegionElement(container, 'Intro')).not.toBeNull()
    expect(findRegionElement(container, 'Verse')).not.toBeNull()
    expect(findRegionElement(container, 'Chorus')).not.toBeNull()
  })

  it('shows selected state visually when region selected in store', () => {
    act(() => {
      actions.select(0)
    })

    const { container } = render(<Timeline height={120} />)

    const introEl = findRegionElement(container, 'Intro')
    expect(introEl).not.toBeNull()
    expect(isVisuallySelected(introEl!)).toBe(true)

    // Other regions should not be selected
    const verseEl = findRegionElement(container, 'Verse')
    expect(isVisuallySelected(verseEl!)).toBe(false)
  })

  it('reflects moved region position after store move', () => {
    // Move Intro forward 5 seconds
    act(() => {
      actions.move([0], 5)
    })

    const { container } = render(<Timeline height={120} />)

    const introEl = findRegionElement(container, 'Intro')
    expect(introEl).not.toBeNull()
    const pos = getPositionPercent(introEl!)
    // Intro moved from 0s to 5s, should have positive left%
    expect(pos.left).toBeGreaterThan(0)
  })

  it('reverts to original positions after cancel', () => {
    act(() => {
      actions.move([0], 5)
      actions.cancel()
    })

    const { container } = render(<Timeline height={120} />)

    const introEl = findRegionElement(container, 'Intro')
    expect(introEl).not.toBeNull()
    const pos = getPositionPercent(introEl!)
    // Should be back at 0%
    expect(pos.left).toBe(0)
  })

  it('updates region order after move changes position', () => {
    // Move Chorus to the beginning (before Intro)
    act(() => {
      actions.move([2], -20)
    })

    const { container } = render(<Timeline height={120} />)

    // Find all region elements and check their order by left position
    const elements = findAllRegionElements(container)
    const positions = elements.map(el => ({
      name: el.querySelector('span')?.textContent,
      left: parseFloat(el.style.left) || 0,
    })).sort((a, b) => a.left - b.left)

    // Chorus should now be first
    expect(positions[0].name).toBe('Chorus')
  })
})

// ============================================================================
// Tests: Bug Fix Verification
// ============================================================================

describe('Bug fix: multiple moves before commit', () => {
  beforeEach(() => {
    setupStore(songStructure())
  })

  afterEach(() => {
    cleanup()
  })

  it('allows multiple moves on same region before committing', () => {
    // This was the bug: regions could only be moved once before Save/Cancel
    act(() => {
      actions.select(0)
      actions.move([0], 5)
    })

    expect(hasPendingChanges()).toBe(true)
    expect(findRegion('Intro')?.start).toBe(5)

    // Second move should work (this was broken)
    act(() => {
      actions.move([0], 3)
    })

    expect(hasPendingChanges()).toBe(true)
    // Region should now be at 8s (5 + 3)
    expect(findRegion('Intro')?.start).toBe(8)
  })

  it('allows editing different regions before commit', () => {
    // Move Intro forward 5 seconds
    act(() => {
      actions.move([0], 5)
    })

    // Intro is now at 5s, Verse rippled to 5s (fills gap left by Intro)
    expect(findRegion('Intro')?.start).toBe(5)

    // Move Chorus backward 5 seconds
    act(() => {
      actions.move([2], -5)
    })

    expect(hasPendingChanges()).toBe(true)
    // Both changes should be tracked
    expect(findRegion('Intro')?.start).toBe(5)
    expect(findRegion('Chorus')?.start).toBe(15) // 20 - 5
  })
})

// ============================================================================
// Tests: Selection Behavior
// ============================================================================

describe('Region selection behavior', () => {
  beforeEach(() => {
    setupStore(songStructure())
  })

  afterEach(() => {
    cleanup()
  })

  it('selects single region', () => {
    act(() => {
      actions.select(0)
    })

    expect(isSelected(0)).toBe(true)
    expect(isSelected(1)).toBe(false)
    expect(isSelected(2)).toBe(false)
  })

  it('replaces selection when selecting another region', () => {
    act(() => {
      actions.select(0)
      actions.select(1)
    })

    expect(isSelected(0)).toBe(false)
    expect(isSelected(1)).toBe(true)
  })

  it('supports multi-selection with addToSelection', () => {
    act(() => {
      actions.select(0)
      actions.addToSelection(2)
    })

    expect(selectedIndices()).toEqual([0, 2])
  })

  it('clears selection', () => {
    act(() => {
      actions.select(0)
      actions.addToSelection(1)
      actions.clearSelection()
    })

    expect(selectedIndices()).toEqual([])
  })
})

// ============================================================================
// Tests: Resize Behavior
// ============================================================================

describe('Region resize behavior', () => {
  beforeEach(() => {
    setupStore(songStructure())
  })

  afterEach(() => {
    cleanup()
  })

  it('extends region end and ripples subsequent', () => {
    act(() => {
      // Extend Intro from 10s to 15s
      actions.resize(0, 'end', 15, 120)
    })

    expect(findRegion('Intro')?.end).toBe(15)
    // Verse should be pushed forward
    expect(findRegion('Verse')?.start).toBe(15)
    expect(findRegion('Chorus')?.start).toBe(25)
  })

  it('shrinks region and closes gap', () => {
    act(() => {
      // Shrink Intro from 10s to 5s
      actions.resize(0, 'end', 5, 120)
    })

    expect(findRegion('Intro')?.end).toBe(5)
    // Verse should move back
    expect(findRegion('Verse')?.start).toBe(5)
  })

  it('extends start edge and trims previous', () => {
    act(() => {
      // Extend Verse start from 10s to 5s
      actions.resize(1, 'start', 5, 120)
    })

    // Intro should be trimmed
    expect(findRegion('Intro')?.end).toBe(5)
    expect(findRegion('Verse')?.start).toBe(5)
  })
})

// ============================================================================
// Tests: Delete Behavior
// ============================================================================

describe('Region delete behavior', () => {
  beforeEach(() => {
    setupStore(songStructure())
  })

  afterEach(() => {
    cleanup()
  })

  it('deletes with ripple back', () => {
    act(() => {
      actions.delete(1, 'ripple-back')
    })

    expect(findRegion('Verse')).toBeUndefined()
    // Chorus should move back to fill gap
    expect(findRegion('Chorus')?.start).toBe(10)
  })

  it('deletes leaving gap', () => {
    act(() => {
      actions.delete(1, 'leave-gap')
    })

    expect(findRegion('Verse')).toBeUndefined()
    // Chorus should stay in place
    expect(findRegion('Chorus')?.start).toBe(20)
  })

  it('deletes extending previous', () => {
    act(() => {
      actions.delete(1, 'extend-previous')
    })

    expect(findRegion('Verse')).toBeUndefined()
    // Intro should extend to fill gap
    expect(findRegion('Intro')?.end).toBe(20)
  })
})

// ============================================================================
// Tests: Create Behavior
// ============================================================================

describe('Region create behavior', () => {
  beforeEach(() => {
    setupStore(songStructure())
  })

  afterEach(() => {
    cleanup()
  })

  it('creates new region at position', () => {
    act(() => {
      actions.create(30, 40, 'Bridge', 120)
    })

    expect(findRegion('Bridge')).toBeDefined()
    expect(findRegion('Bridge')?.start).toBe(30)
    expect(findRegion('Bridge')?.end).toBe(40)
  })

  it('marks as pending after create', () => {
    act(() => {
      actions.create(30, 40, 'Bridge', 120)
    })

    expect(hasPendingChanges()).toBe(true)
  })

  it('shifts following regions when inserting in middle', () => {
    act(() => {
      // Insert a 5-second section in the middle of Verse
      actions.create(15, 20, 'Pre-Chorus', 120)
    })

    // Verse should be trimmed
    expect(findRegion('Verse')?.end).toBe(15)
    // Chorus should be shifted
    expect(findRegion('Chorus')?.start).toBe(25)
  })
})

// ============================================================================
// Tests: Playhead Visibility
// ============================================================================

describe('Playhead visibility on initial load', () => {
  beforeEach(() => {
    Element.prototype.getBoundingClientRect = vi.fn(() => mockRect)
  })

  afterEach(() => {
    cleanup()
    vi.restoreAllMocks()
    mockAnimationPosition = 0
  })

  it('playhead is visible when position is beyond empty timeline bounds', () => {
    // Bug: When regions/markers are empty, timeline defaults to 10s duration.
    // If playhead is at 50s, it calculates as 500% and goes off-screen.
    //
    // Setup: Empty store (no regions), transport position at 50s
    setupStore([])
    mockAnimationPosition = 50
    useReaperStore.setState({ positionSeconds: 50 })

    const { container } = render(<Timeline height={120} />)

    // Find the playhead container (it's the element with absolute positioning
    // that gets its left style set by the animation callback)
    const playheadContainer = container.querySelector('.absolute.top-0.bottom-0') as HTMLElement

    expect(playheadContainer).not.toBeNull()

    // The playhead's left position should be within visible range [0%, 100%]
    // With the bug, this would be 500% (50s / 10s * 100)
    const leftPercent = parseFloat(playheadContainer.style.left)
    expect(leftPercent).toBeLessThanOrEqual(100)
    expect(leftPercent).toBeGreaterThanOrEqual(0)
  })

  it('playhead is visible at position 0 with empty timeline', () => {
    // Sanity check: position 0 should always work
    setupStore([])
    mockAnimationPosition = 0
    useReaperStore.setState({ positionSeconds: 0 })

    const { container } = render(<Timeline height={120} />)

    const playheadContainer = container.querySelector('.absolute.top-0.bottom-0') as HTMLElement
    expect(playheadContainer).not.toBeNull()

    const leftPercent = parseFloat(playheadContainer.style.left)
    expect(leftPercent).toBe(0)
  })
})
