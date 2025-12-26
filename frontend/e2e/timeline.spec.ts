/**
 * Timeline E2E Tests
 *
 * Tests gesture interactions on the Timeline component.
 * These run in a real browser where pointer events work properly.
 */

import { test, expect, Page } from '@playwright/test'

// Helper to get the RegionEditActionBar (amber background bar that appears when there are pending changes)
function getRegionEditActionBar(page: Page) {
  return page.locator('[class*="bg-amber-900"]')
}

// Wait for store to be available and inject test fixtures
async function setupTestFixtures(page: Page) {
  // Wait for the store to be exposed on window
  await page.waitForFunction(() => (window as any).__REAPER_STORE__ !== undefined, {
    timeout: 10000,
  })

  // Inject test data - use actions where available, setState for raw data
  await page.evaluate(() => {
    const store = (window as any).__REAPER_STORE__

    // Set localStorage first so the TimelineModeToggle useEffect doesn't override our mode
    localStorage.setItem('reamo-timeline-mode', 'regions')

    // Set raw data first
    store.setState({
      // Enable regions mode prerequisites
      luaScriptInstalled: true,
      luaScriptChecked: true,

      // Test regions: Intro[0-10], Verse[10-20], Chorus[20-30]
      // Timeline duration is ~31.5s (30s + 5% padding)
      // Intro: 0-31.7%, Verse: 31.7-63.5%, Chorus: 63.5-95.2%
      regions: [
        { id: 0, name: 'Intro', start: 0, end: 10, color: 0xff0000 },
        { id: 1, name: 'Verse', start: 10, end: 20, color: 0x00ff00 },
        { id: 2, name: 'Chorus', start: 20, end: 30, color: 0x0000ff },
      ],
      markers: [],

      // Set position just past regions so auto-select doesn't interfere with tests
      // Note: Timeline duration includes playhead, so 31s → ~32.5s timeline
      positionSeconds: 31,

      // Reset edit state
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
    })

    // Use the store action to switch to regions mode
    // This is necessary because setTimelineMode has side effects (clears selection, etc.)
    store.getState().setTimelineMode('regions')
  })

  // Wait for component to re-render
  await page.waitForTimeout(100)
}

// Get the interactive timeline container
async function getTimelineContainer(page: Page) {
  // The interactive timeline is bg-gray-800 with touch-none select-none
  return page.locator('.bg-gray-800.overflow-hidden').first()
}

// Click at a percentage position in the timeline (0-100)
async function clickAtPercent(page: Page, percent: number) {
  const timeline = await getTimelineContainer(page)
  const box = await timeline.boundingBox()
  if (!box) throw new Error('Timeline container not found')

  // Calculate position relative to element
  const relativeX = (box.width * percent) / 100
  const relativeY = box.height / 2

  // Click on the timeline at the specified position
  await timeline.click({ position: { x: relativeX, y: relativeY } })
}

// Drag from one percentage to another
async function dragPercent(page: Page, fromPercent: number, toPercent: number) {
  const timeline = await getTimelineContainer(page)
  const box = await timeline.boundingBox()
  if (!box) throw new Error('Timeline container not found')

  const startX = box.x + (box.width * fromPercent) / 100
  const endX = box.x + (box.width * toPercent) / 100
  const y = box.y + box.height / 2

  await page.mouse.move(startX, y)
  await page.mouse.down()
  await page.mouse.move(endX, y, { steps: 10 })
  await page.mouse.up()
}

test.describe('Timeline gestures', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/')
    await setupTestFixtures(page)
  })

  test('displays regions from test fixtures', async ({ page }) => {
    // All three regions should be visible in the label bar
    // Use span locator to target region labels specifically (not MarkerInfoBar buttons)
    await expect(page.locator('span:has-text("Intro")')).toBeVisible()
    await expect(page.locator('span:has-text("Verse")')).toBeVisible()
    await expect(page.locator('span:has-text("Chorus")')).toBeVisible()
  })

  test('tap region to select', async ({ page }) => {
    // Click at 15% (middle of Intro region which spans 0-31.7%)
    await clickAtPercent(page, 15)

    // Small wait for state update
    await page.waitForTimeout(50)

    // Verify store state
    const selected = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__
      return store.getState().selectedRegionIndices
    })

    expect(selected).toEqual([0])
  })

  test('tap another region changes selection', async ({ page }) => {
    // Select Intro (15%)
    await clickAtPercent(page, 15)

    // Verify Intro selected
    let selected = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__
      return store.getState().selectedRegionIndices
    })
    expect(selected).toEqual([0])

    // Select Verse (47% - middle of Verse region 31.7-63.5%)
    await clickAtPercent(page, 47)

    // Verify Verse selected (index 1)
    selected = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__
      return store.getState().selectedRegionIndices
    })
    expect(selected).toEqual([1])
  })

  test('tap empty area clears selection', async ({ page }) => {
    // First select a region
    await clickAtPercent(page, 15)

    // Verify selected
    let selected = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__
      return store.getState().selectedRegionIndices
    })
    expect(selected).toEqual([0])

    // Click empty area (98% - after all regions)
    await clickAtPercent(page, 98)

    // Selection should be cleared
    selected = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__
      return store.getState().selectedRegionIndices
    })
    expect(selected).toEqual([])
  })

  test('drag region to move shows pending changes', async ({ page }) => {
    // First select Intro
    await clickAtPercent(page, 15)

    // Drag from 15% to 50%
    await dragPercent(page, 15, 50)

    // Should have pending changes - region edit Save button visible (green one with text "Save")
    // Not the project Save button (blue with floppy icon)
    await expect(page.getByRole('button', { name: 'Save' }).nth(1)).toBeVisible({ timeout: 2000 })
  })

  test('cancel reverts pending changes', async ({ page }) => {
    // Make an edit via store
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__
      const state = store.getState()
      state.moveRegion([0], 5, state.regions)
    })

    // Should show Save/Cancel
    await expect(page.getByRole('button', { name: /cancel/i })).toBeVisible()

    // Click Cancel
    await page.getByRole('button', { name: /cancel/i }).click()

    // Pending changes should be cleared
    const hasPending = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__
      return store.getState().hasPendingChanges()
    })
    expect(hasPending).toBe(false)
  })
})

test.describe('Undo/Redo', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/')
    await setupTestFixtures(page)
  })

  test('undo button appears and reverts changes', async ({ page }) => {
    // Make an edit via store
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__
      const state = store.getState()
      state.moveRegion([0], 5, state.regions)
    })

    // Should show Undo button (now enabled) - scoped to RegionEditActionBar
    const actionBar = getRegionEditActionBar(page)
    const undoButton = actionBar.getByRole('button', { name: /undo/i })
    await expect(undoButton).toBeVisible()
    await expect(undoButton).toBeEnabled()

    // Click Undo
    await undoButton.click()

    // Pending changes should be cleared
    const hasPending = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__
      return store.getState().hasPendingChanges()
    })
    expect(hasPending).toBe(false)
  })

  test('redo button restores undone changes', async ({ page }) => {
    // Make an edit via store
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__
      const state = store.getState()
      state.moveRegion([0], 5, state.regions)
    })

    // Click Undo - scoped to RegionEditActionBar
    const actionBar = getRegionEditActionBar(page)
    await actionBar.getByRole('button', { name: /undo/i }).click()

    // Need to make another change to show the action bar again
    // since hasPendingChanges is now false
    // Actually, after undo we should have redo available but no pending changes
    // The action bar won't show if no pending changes...
    // Let me check if redo can work differently

    // Actually the redo button is only visible when the action bar is visible
    // which requires pending changes. After undo, if there are no pending changes,
    // the action bar disappears. Let's test the undo/redo flow with multiple changes.

    // Make two edits
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__
      const state = store.getState()
      state.moveRegion([0], 5, state.regions)
      state.moveRegion([1], 5, state.regions)
    })

    // Undo once (should still have pending changes from first edit)
    await actionBar.getByRole('button', { name: /undo/i }).click()

    // Should still have pending changes (from first move)
    let hasPending = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__
      return store.getState().hasPendingChanges()
    })
    expect(hasPending).toBe(true)

    // Redo button should be enabled now
    const redoButton = actionBar.getByRole('button', { name: /redo/i })
    await expect(redoButton).toBeEnabled()

    // Click Redo
    await redoButton.click()

    // Should have both changes back
    const historyLength = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__
      return store.getState().historyStack.length
    })
    expect(historyLength).toBe(2)
  })

  test('undo multiple edits sequentially', async ({ page }) => {
    // Make 3 edits via store
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__
      const state = store.getState()
      state.resizeRegion(0, 'end', 15, state.regions, 120)
      state.resizeRegion(1, 'end', 25, state.regions, 120)
      state.resizeRegion(2, 'end', 35, state.regions, 120)
    })

    // Verify history has 3 items
    let historyLength = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__
      return store.getState().historyStack.length
    })
    expect(historyLength).toBe(3)

    // Undo 3 times - scoped to RegionEditActionBar
    const actionBar = getRegionEditActionBar(page)
    await actionBar.getByRole('button', { name: /undo/i }).click()
    await actionBar.getByRole('button', { name: /undo/i }).click()
    await actionBar.getByRole('button', { name: /undo/i }).click()

    // Should have no pending changes
    const hasPending = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__
      return store.getState().hasPendingChanges()
    })
    expect(hasPending).toBe(false)
  })

  test('new edit after undo clears redo stack', async ({ page }) => {
    // Make 2 edits
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__
      const state = store.getState()
      state.moveRegion([0], 5, state.regions)
      state.moveRegion([1], 5, state.regions)
    })

    // Undo once - scoped to RegionEditActionBar
    const actionBar = getRegionEditActionBar(page)
    await actionBar.getByRole('button', { name: /undo/i }).click()

    // Verify redo is available
    let canRedo = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__
      return store.getState().canRedo()
    })
    expect(canRedo).toBe(true)

    // Make a new edit
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__
      const state = store.getState()
      state.moveRegion([2], 5, state.regions)
    })

    // Redo should no longer be available
    canRedo = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__
      return store.getState().canRedo()
    })
    expect(canRedo).toBe(false)
  })

  test('cancel clears undo/redo history', async ({ page }) => {
    // Make an edit
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__
      const state = store.getState()
      state.moveRegion([0], 5, state.regions)
    })

    // Verify we can undo
    let canUndo = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__
      return store.getState().canUndo()
    })
    expect(canUndo).toBe(true)

    // Click Cancel
    await page.getByRole('button', { name: /cancel/i }).click()

    // History should be cleared
    const historyCleared = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__
      const state = store.getState()
      return state.historyStack.length === 0 && state.redoStack.length === 0
    })
    expect(historyCleared).toBe(true)
  })
})

// ============================================================================
// Time Selection Tests
// ============================================================================

test.describe('Time selection', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/')
    await setupTestFixtures(page)

    // Switch to navigate mode for time selection gestures
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__
      localStorage.setItem('reamo-timeline-mode', 'navigate')
      store.getState().setTimelineMode('navigate')
    })
    await page.waitForTimeout(100)
  })

  test('displays time selection from store', async ({ page }) => {
    // Inject time selection into store
    // At 120 BPM: 20 beats = 10s, 40 beats = 20s
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__
      store.setState({
        timeSelection: { startSeconds: 10, endSeconds: 20 },
        bpm: 120,
      })
    })

    await page.waitForTimeout(50)

    // Find time selection element (has border-l-2, border-r-2, bg-white/15)
    const timeSelElement = page.locator('.border-l-2.border-r-2.bg-white\\/15')

    // Should be visible
    await expect(timeSelElement.first()).toBeVisible()

    // Should have left and width styles set
    const style = await timeSelElement.first().getAttribute('style')
    expect(style).toContain('left:')
    expect(style).toContain('width:')
  })

  test('does not show time selection when none is set', async ({ page }) => {
    // Ensure no time selection
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__
      store.setState({
        timeSelection: null,
        bpm: 120,
      })
    })

    await page.waitForTimeout(50)

    // Time selection element should not exist
    const timeSelElement = page.locator('.border-l-2.border-r-2.bg-white\\/15')
    await expect(timeSelElement).toHaveCount(0)
  })

  test('updates time selection position when changed', async ({ page }) => {
    // Set initial time selection (10s-20s)
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__
      store.setState({
        timeSelection: { startSeconds: 10, endSeconds: 20 },
        bpm: 120,
      })
    })

    await page.waitForTimeout(50)

    const timeSelElement = page.locator('.border-l-2.border-r-2.bg-white\\/15').first()
    const initialStyle = await timeSelElement.getAttribute('style')
    const initialLeft = parseFloat(initialStyle?.match(/left:\s*([\d.]+)%/)?.[1] || '0')

    // Change time selection to later position (20s-30s)
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__
      store.setState({
        timeSelection: { startSeconds: 20, endSeconds: 30 },
      })
    })

    await page.waitForTimeout(50)

    const newStyle = await timeSelElement.getAttribute('style')
    const newLeft = parseFloat(newStyle?.match(/left:\s*([\d.]+)%/)?.[1] || '0')

    // New position should be further right
    expect(newLeft).toBeGreaterThan(initialLeft)
  })

  test('clears time selection from display', async ({ page }) => {
    // Set time selection
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__
      store.setState({
        timeSelection: { startSeconds: 10, endSeconds: 20 },
        bpm: 120,
      })
    })

    await page.waitForTimeout(50)

    // Should be visible
    const timeSelElement = page.locator('.border-l-2.border-r-2.bg-white\\/15')
    await expect(timeSelElement.first()).toBeVisible()

    // Clear time selection
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__
      store.setState({ timeSelection: null })
    })

    await page.waitForTimeout(50)

    // Should no longer be visible
    await expect(timeSelElement).toHaveCount(0)
  })

  test('drag creates time selection (navigate mode)', async ({ page }) => {
    // Clear any existing selection
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__
      store.setState({ timeSelection: null, bpm: 120 })
    })

    // Drag from 20% to 60% of timeline
    await dragPercent(page, 20, 60)

    await page.waitForTimeout(100)

    // Check that time selection was set in store
    const timeSelection = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__
      return store.getState().timeSelection
    })

    expect(timeSelection).not.toBeNull()
    expect(timeSelection.startSeconds).toBeDefined()
    expect(timeSelection.endSeconds).toBeDefined()
    // End should be after start
    expect(timeSelection.endSeconds).toBeGreaterThan(timeSelection.startSeconds)
  })
})
