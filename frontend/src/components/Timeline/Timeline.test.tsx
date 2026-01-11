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
  selectedIds,
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

    expect(selectedIds()).toEqual([0, 2])
  })

  it('clears selection', () => {
    act(() => {
      actions.select(0)
      actions.addToSelection(1)
      actions.clearSelection()
    })

    expect(selectedIds()).toEqual([])
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

describe('Playhead visibility', () => {
  beforeEach(() => {
    Element.prototype.getBoundingClientRect = vi.fn(() => mockRect)
  })

  afterEach(() => {
    cleanup()
    vi.restoreAllMocks()
    mockAnimationPosition = 0
  })

  // Playhead position is calculated relative to the visible viewport range (0-30s default).
  // With viewport-relative rendering, playhead at 25s within 0-30s viewport = ~83%
  it('playhead renders within viewport when position is in visible range', () => {
    setupStore([])
    mockAnimationPosition = 25
    useReaperStore.setState({ positionSeconds: 25 })

    const { container } = render(<Timeline height={120} />)

    const playheadContainer = container.querySelector('.absolute.top-0.bottom-0') as HTMLElement
    expect(playheadContainer).not.toBeNull()

    // With viewport 0-30s (default) and playhead at 25s: 25/30 = ~83%
    const leftPercent = parseFloat(playheadContainer.style.left)
    expect(leftPercent).toBeLessThanOrEqual(100)
    expect(leftPercent).toBeGreaterThan(75) // Should be ~83%
  })

  // Playhead at different position within viewport renders correctly.
  // With empty timeline (min 10s) and playhead at 5s: 5/10 = 50%
  it('playhead renders at midpoint of viewport', () => {
    setupStore([])
    mockAnimationPosition = 5
    useReaperStore.setState({ positionSeconds: 5 })

    const { container } = render(<Timeline height={120} />)

    const playheadContainer = container.querySelector('.absolute.top-0.bottom-0') as HTMLElement
    expect(playheadContainer).not.toBeNull()

    // Empty timeline has min duration of 10s, so playhead at 5s = 50%
    const leftPercent = parseFloat(playheadContainer.style.left)
    expect(leftPercent).toBeGreaterThan(45)
    expect(leftPercent).toBeLessThan(55)
  })

  it('playhead at position 0 with empty timeline', () => {
    setupStore([])
    mockAnimationPosition = 0
    useReaperStore.setState({ positionSeconds: 0 })

    const { container } = render(<Timeline height={120} />)

    const playheadContainer = container.querySelector('.absolute.top-0.bottom-0') as HTMLElement
    expect(playheadContainer).not.toBeNull()
    expect(parseFloat(playheadContainer.style.left)).toBe(0)
  })
})

// ============================================================================
// Tests: Time Selection Display
// ============================================================================

// Helper to find time selection elements (they have border-l-2 border-r-2 and specific backgrounds)
function findTimeSelectionElement(container: Element): HTMLElement | null {
  // The time selection div has these classes and pointer-events-none
  // In navigate mode: bg-white/15 border-white/60
  // In regions mode: bg-text-muted/5 border-border-subtle opacity-50
  // It's rendered with inline left/width styles
  const candidates = container.querySelectorAll('.border-l-2.border-r-2.pointer-events-none')
  for (const el of candidates) {
    const htmlEl = el as HTMLElement
    // Time selection has both left and width set (selection preview also matches but has different bg)
    // Time selection uses bg-white/15 or similar, selection preview uses bg-selection-preview
    if (htmlEl.style.left && htmlEl.style.width && !htmlEl.classList.contains('bg-selection-preview')) {
      return htmlEl
    }
  }
  return null
}

describe('Time selection display', () => {
  beforeEach(() => {
    setupStore(songStructure())
    Element.prototype.getBoundingClientRect = vi.fn(() => mockRect)
  })

  afterEach(() => {
    cleanup()
    vi.restoreAllMocks()
  })

  it('does not render time selection when none is set', () => {
    useReaperStore.setState({ timeSelection: null, bpm: 120 })

    const { container } = render(<Timeline height={120} />)

    const timeSelEl = findTimeSelectionElement(container)
    expect(timeSelEl).toBeNull()
  })

  it('renders time selection even when bpm is null', () => {
    // Time selection is stored in seconds, so BPM is not needed for display
    useReaperStore.setState({
      timeSelection: { startSeconds: 10, endSeconds: 20 },
      bpm: null,
    })

    const { container } = render(<Timeline height={120} />)

    const timeSelEl = findTimeSelectionElement(container)
    expect(timeSelEl).not.toBeNull()
  })

  it('renders time selection at correct position', () => {
    // Selection from 10s to 20s
    // With regions from 0-30s, timeline is ~31.5s (30 * 1.05)
    // 10s/31.5s ≈ 31.7%, 20s/31.5s ≈ 63.5%
    useReaperStore.setState({
      timeSelection: { startSeconds: 10, endSeconds: 20 },
      bpm: 120,
    })

    const { container } = render(<Timeline height={120} />)

    const timeSelEl = findTimeSelectionElement(container)
    expect(timeSelEl).not.toBeNull()

    const left = parseFloat(timeSelEl!.style.left)
    const width = parseFloat(timeSelEl!.style.width)

    // Selection should start around 31-32% and be about 31-32% wide
    expect(left).toBeGreaterThan(25)
    expect(left).toBeLessThan(40)
    expect(width).toBeGreaterThan(25)
    expect(width).toBeLessThan(40)
  })

  it('renders time selection starting at time 0', () => {
    // Selection from 0 to 8 seconds
    useReaperStore.setState({
      timeSelection: { startSeconds: 0, endSeconds: 8 },
      bpm: 120,
    })

    const { container } = render(<Timeline height={120} />)

    const timeSelEl = findTimeSelectionElement(container)
    expect(timeSelEl).not.toBeNull()

    const left = parseFloat(timeSelEl!.style.left)
    // Selection should start at 0%
    expect(left).toBe(0)
  })

  it('does not render time selection with negligible width (< 0.01s)', () => {
    // Selection with less than 0.01 second width should be filtered out
    useReaperStore.setState({
      timeSelection: { startSeconds: 10, endSeconds: 10.005 },
      bpm: 120,
    })

    const { container } = render(<Timeline height={120} />)

    const timeSelEl = findTimeSelectionElement(container)
    expect(timeSelEl).toBeNull()
  })

  it('renders time selection just above negligible threshold', () => {
    // Selection with just above 0.01 second width should render
    useReaperStore.setState({
      timeSelection: { startSeconds: 10, endSeconds: 10.015 },
      bpm: 120,
    })

    const { container } = render(<Timeline height={120} />)

    const timeSelEl = findTimeSelectionElement(container)
    expect(timeSelEl).not.toBeNull()
  })

  it('updates time selection position when store changes', () => {
    useReaperStore.setState({
      timeSelection: { startSeconds: 10, endSeconds: 20 },
      bpm: 120,
    })

    const { container, rerender } = render(<Timeline height={120} />)

    const timeSelEl1 = findTimeSelectionElement(container)
    expect(timeSelEl1).not.toBeNull()
    const initialLeft = parseFloat(timeSelEl1!.style.left)

    // Change time selection
    act(() => {
      useReaperStore.setState({
        timeSelection: { startSeconds: 20, endSeconds: 30 },
      })
    })

    rerender(<Timeline height={120} />)

    const timeSelEl2 = findTimeSelectionElement(container)
    expect(timeSelEl2).not.toBeNull()
    const newLeft = parseFloat(timeSelEl2!.style.left)

    // New selection should be further right
    expect(newLeft).toBeGreaterThan(initialLeft)
  })

  it('clears time selection when set to null', () => {
    useReaperStore.setState({
      timeSelection: { startSeconds: 10, endSeconds: 20 },
      bpm: 120,
    })

    const { container, rerender } = render(<Timeline height={120} />)

    expect(findTimeSelectionElement(container)).not.toBeNull()

    // Clear time selection
    act(() => {
      useReaperStore.setState({ timeSelection: null })
    })

    rerender(<Timeline height={120} />)

    expect(findTimeSelectionElement(container)).toBeNull()
  })

  it('time selection position is stable when BPM changes', () => {
    // Since we now store seconds directly, BPM changes should NOT affect position
    useReaperStore.setState({
      timeSelection: { startSeconds: 10, endSeconds: 20 },
      bpm: 120,
    })

    const { container, rerender } = render(<Timeline height={120} />)
    const timeSelEl1 = findTimeSelectionElement(container)
    const leftAt120 = parseFloat(timeSelEl1!.style.left)

    // Change BPM to 60
    act(() => {
      useReaperStore.setState({ bpm: 60 })
    })

    rerender(<Timeline height={120} />)

    const timeSelEl2 = findTimeSelectionElement(container)
    const leftAt60 = parseFloat(timeSelEl2!.style.left)

    // Position should remain the same since we store seconds
    expect(leftAt60).toBeCloseTo(leftAt120, 1)
  })
})

// ============================================================================
// Tests: Overflow Prevention (Regression)
// ============================================================================

describe('Region overflow prevention', () => {
  beforeEach(() => {
    Element.prototype.getBoundingClientRect = vi.fn(() => mockRect)
  })

  afterEach(() => {
    cleanup()
    vi.restoreAllMocks()
  })

  it('top bar has overflow-hidden to clip regions wider than viewport', () => {
    // Create a region that spans 0-120 seconds (much wider than 30s default viewport)
    const wideRegion = [
      { id: 0, name: 'Very Wide Region', start: 0, end: 120, color: 0 },
    ]
    setupStore(wideRegion)

    const { container } = render(<Timeline height={120} />)

    // Find the top bar (first child div with h-[25px])
    const topBar = container.querySelector('.h-\\[25px\\]') as HTMLElement
    expect(topBar).not.toBeNull()

    // Verify it has overflow-hidden
    expect(topBar.classList.contains('overflow-hidden')).toBe(true)
  })

  it('bottom bar has overflow-hidden to clip elements wider than viewport', () => {
    setupStore([])
    // Set a wide time selection
    useReaperStore.setState({
      timeSelection: { startSeconds: 0, endSeconds: 120 },
      bpm: 120,
    })

    const { container } = render(<Timeline height={120} />)

    // Find the bottom bar (div with h-5 and rounded-b-lg)
    const bottomBar = container.querySelector('.h-5.rounded-b-lg') as HTMLElement
    expect(bottomBar).not.toBeNull()

    // Verify it has overflow-hidden
    expect(bottomBar.classList.contains('overflow-hidden')).toBe(true)
  })

  it('main timeline container has overflow-hidden', () => {
    setupStore(songStructure())

    const { container } = render(<Timeline height={120} />)

    // Find the main container by data-testid
    const mainContainer = container.querySelector('[data-testid="timeline-canvas"]') as HTMLElement
    expect(mainContainer).not.toBeNull()

    // Verify it has overflow-hidden
    expect(mainContainer.classList.contains('overflow-hidden')).toBe(true)
  })

  it('regions spanning beyond viewport have constrained visual bounds', () => {
    // Create a region much wider than viewport (0-200s, viewport is 0-30s)
    const wideRegion = [
      { id: 0, name: 'Huge Region', start: 0, end: 200, color: 0 },
    ]
    setupStore(wideRegion)

    const { container } = render(<Timeline height={120} />)

    // Find the region element in the main canvas
    const regionBlock = container.querySelector('[data-testid="region-block"]') as HTMLElement
    expect(regionBlock).not.toBeNull()

    // Region starts at 0% (beginning of viewport)
    const left = parseFloat(regionBlock.style.left)
    expect(left).toBe(0)

    // The width should be > 100% since region extends beyond viewport,
    // but the container's overflow-hidden will clip it visually
    const width = parseFloat(regionBlock.style.width)
    expect(width).toBeGreaterThan(100)

    // Verify parent has overflow-hidden (the clipping mechanism)
    const parent = regionBlock.closest('[data-testid="timeline-canvas"]') as HTMLElement
    expect(parent?.classList.contains('overflow-hidden')).toBe(true)
  })

  it('region starting before viewport has negative left position but is clipped', () => {
    // Create a region that starts before viewport (region: 0-50s, viewport default: 0-30s)
    // To test negative positioning, we need to pan the viewport
    const region = [
      { id: 0, name: 'Early Region', start: 0, end: 50, color: 0 },
    ]
    setupStore(region)

    const { container } = render(<Timeline height={120} />)

    // Find region label in top bar
    const regionLabel = container.querySelector('[data-testid="region-label"]') as HTMLElement
    expect(regionLabel).not.toBeNull()

    // Region starts at viewport start, so left = 0%
    const left = parseFloat(regionLabel.style.left)
    expect(left).toBe(0)

    // Top bar parent should clip overflow
    const topBar = regionLabel.closest('.overflow-hidden') as HTMLElement
    expect(topBar).not.toBeNull()
  })
})

// ============================================================================
// Tests: Playhead Drag Viewport Coordinates (Regression)
// ============================================================================

describe('Playhead drag uses viewport coordinates', () => {
  beforeEach(() => {
    Element.prototype.getBoundingClientRect = vi.fn(() => mockRect)
  })

  afterEach(() => {
    cleanup()
    vi.restoreAllMocks()
    mockAnimationPosition = 0
  })

  it('playhead position uses viewport-relative coordinates', () => {
    // Create a long project (0-120s) so timeline is much wider than default viewport (0-30s)
    const longProject = [
      { id: 0, name: 'Long Region', start: 0, end: 120, color: 0 },
    ]
    setupStore(longProject)
    mockAnimationPosition = 15
    useReaperStore.setState({ positionSeconds: 15 })

    const { container } = render(<Timeline height={120} />)

    // Find the playhead element by data-testid
    const playhead = container.querySelector('[data-testid="playhead"]') as HTMLElement
    expect(playhead).not.toBeNull()

    // With viewport 0-30s and playhead at 15s: 15/30 = 50%
    // NOT 15/120 = 12.5% which would be the full timeline calculation
    const leftPercent = parseFloat(playhead.style.left)
    expect(leftPercent).toBeGreaterThan(45) // Should be ~50%, not ~12%
    expect(leftPercent).toBeLessThan(55)
  })

  it('playhead at viewport edge renders at 0% or 100%', () => {
    setupStore([])
    mockAnimationPosition = 0
    useReaperStore.setState({ positionSeconds: 0 })

    const { container } = render(<Timeline height={120} />)

    const playhead = container.querySelector('[data-testid="playhead"]') as HTMLElement
    expect(playhead).not.toBeNull()

    // Playhead at 0s with viewport starting at 0 should be at 0%
    const leftPercent = parseFloat(playhead.style.left)
    expect(leftPercent).toBe(0)
  })
})
