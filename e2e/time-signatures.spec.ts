/**
 * Time Signature E2E Tests
 *
 * Tests that different time signatures (4/4, 3/4, 6/8, etc.)
 * display correctly in the UI with proper BPM normalization
 * and bar/beat formatting.
 */

import { test, expect, Page } from '@playwright/test'

// Wait for store to be available and inject test fixtures
async function setupWithTimeSignature(
  page: Page,
  timeSignature: { numerator: number; denominator: number },
  bpm: number
) {
  // Wait for the store to be exposed on window
  await page.waitForFunction(() => (window as any).__REAPER_STORE__ !== undefined, {
    timeout: 10000,
  })

  // Calculate what REAPER would send for fullBeatPosition
  // At 2 seconds position, with given BPM and denominator
  const positionSeconds = 2
  // Convert quarter-note BPM to denominator-note BPM
  const denominatorBpm = bpm * (timeSignature.denominator / 4)
  // fullBeatPosition in denominator beats
  const fullBeatPosition = (positionSeconds * denominatorBpm) / 60

  await page.evaluate(
    ({ numerator, denominator, bpm, fullBeatPosition, positionSeconds }) => {
      const store = (window as any).__REAPER_STORE__

      // Set localStorage first so the TimelineModeToggle useEffect doesn't override our mode
      localStorage.setItem('reamo-timeline-mode', 'regions')

      // Set raw data
      store.setState({
        // Enable regions mode prerequisites
        luaScriptInstalled: true,
        luaScriptChecked: true,

        // Test regions
        regions: [
          { id: 0, name: 'Region 1', start: 0, end: 10, color: 0xff0000 },
        ],
        markers: [],

        // Set position with time signature data
        positionSeconds: positionSeconds,
        positionBeats: '1.1.00',
        fullBeatPosition: fullBeatPosition,
        timeSignature: `${numerator}/${denominator}`,

        // BPM will be calculated by updateBeatPosition
        bpm: null,

        // Reset edit state
        selectedRegionIndices: [0],
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

      // Use the store action to simulate BEATPOS update (which calculates BPM)
      store.getState().updateBeatPosition({
        playState: 1,
        positionSeconds: positionSeconds,
        fullBeatPosition: fullBeatPosition,
        measureCount: 1,
        beatsInMeasure: 1,
        timeSignatureNumerator: numerator,
        timeSignatureDenominator: denominator,
      })

      // Switch to regions mode
      store.getState().setTimelineMode('regions')
    },
    {
      numerator: timeSignature.numerator,
      denominator: timeSignature.denominator,
      bpm,
      fullBeatPosition,
      positionSeconds,
    }
  )

  // Wait for component to re-render
  await page.waitForTimeout(100)
}

test.describe('Time Signature Display - 4/4', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/')
    await setupWithTimeSignature(page, { numerator: 4, denominator: 4 }, 120)
  })

  test('displays correct BPM in 4/4', async ({ page }) => {
    // Check that store has correct BPM
    const bpm = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__
      return Math.round(store.getState().bpm)
    })
    expect(bpm).toBe(120)
  })

  test('displays correct time signature', async ({ page }) => {
    const timeSig = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__
      return store.getState().timeSignature
    })
    expect(timeSig).toBe('4/4')
  })
})

test.describe('Time Signature Display - 6/8', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/')
    await setupWithTimeSignature(page, { numerator: 6, denominator: 8 }, 90)
  })

  test('displays normalized BPM (90, not 180)', async ({ page }) => {
    // The key test: 6/8 at 90 BPM should show 90, not 180
    const bpm = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__
      return Math.round(store.getState().bpm)
    })
    expect(bpm).toBe(90)
  })

  test('displays 6/8 time signature', async ({ page }) => {
    const timeSig = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__
      return store.getState().timeSignature
    })
    expect(timeSig).toBe('6/8')
  })
})

test.describe('Time Signature Display - 3/4', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/')
    await setupWithTimeSignature(page, { numerator: 3, denominator: 4 }, 120)
  })

  test('displays correct BPM in 3/4', async ({ page }) => {
    const bpm = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__
      return Math.round(store.getState().bpm)
    })
    expect(bpm).toBe(120)
  })

  test('displays 3/4 time signature', async ({ page }) => {
    const timeSig = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__
      return store.getState().timeSignature
    })
    expect(timeSig).toBe('3/4')
  })
})

test.describe('Time Signature Display - 12/8', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/')
    await setupWithTimeSignature(page, { numerator: 12, denominator: 8 }, 60)
  })

  test('displays normalized BPM (60, not 120)', async ({ page }) => {
    const bpm = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__
      return Math.round(store.getState().bpm)
    })
    expect(bpm).toBe(60)
  })

  test('displays 12/8 time signature', async ({ page }) => {
    const timeSig = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__
      return store.getState().timeSignature
    })
    expect(timeSig).toBe('12/8')
  })
})

test.describe('Region bar position calculations (store verification)', () => {
  /**
   * These tests verify that the store correctly computes bar positions.
   * The actual formatting is thoroughly tested in unit tests (time.test.ts).
   * UI rendering of formatted positions depends on BPM being available,
   * which is tested via the store state verification below.
   */

  test('6/8: Store correctly normalizes BPM for bar calculations', async ({ page }) => {
    await page.goto('/')

    await page.waitForFunction(() => (window as any).__REAPER_STORE__ !== undefined, {
      timeout: 10000,
    })

    // Setup 6/8 at 90 BPM
    const result = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__

      // Simulate BEATPOS for 6/8 at 90 BPM
      // At 0.5 seconds with 180 eighths/min = 1.5 eighth notes
      store.getState().updateBeatPosition({
        playState: 0,
        positionSeconds: 0.5,
        fullBeatPosition: 1.5,
        measureCount: 1,
        beatsInMeasure: 1.5,
        timeSignatureNumerator: 6,
        timeSignatureDenominator: 8,
      })

      return {
        bpm: Math.round(store.getState().bpm),
        timeSignature: store.getState().timeSignature,
      }
    })

    // Verify BPM is normalized to 90 (not 180)
    expect(result.bpm).toBe(90)
    expect(result.timeSignature).toBe('6/8')
  })

  test('4/4: Store correctly computes BPM', async ({ page }) => {
    await page.goto('/')

    await page.waitForFunction(() => (window as any).__REAPER_STORE__ !== undefined, {
      timeout: 10000,
    })

    const result = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__

      // Simulate BEATPOS for 4/4 at 120 BPM
      // At 0.5 seconds = 1 quarter note
      store.getState().updateBeatPosition({
        playState: 0,
        positionSeconds: 0.5,
        fullBeatPosition: 1,
        measureCount: 1,
        beatsInMeasure: 1,
        timeSignatureNumerator: 4,
        timeSignatureDenominator: 4,
      })

      return {
        bpm: Math.round(store.getState().bpm),
        timeSignature: store.getState().timeSignature,
      }
    })

    expect(result.bpm).toBe(120)
    expect(result.timeSignature).toBe('4/4')
  })

  test('3/4: Store correctly computes BPM', async ({ page }) => {
    await page.goto('/')

    await page.waitForFunction(() => (window as any).__REAPER_STORE__ !== undefined, {
      timeout: 10000,
    })

    const result = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__

      // Simulate BEATPOS for 3/4 at 180 BPM
      // At 1 second = 3 quarter notes
      store.getState().updateBeatPosition({
        playState: 0,
        positionSeconds: 1,
        fullBeatPosition: 3,
        measureCount: 1,
        beatsInMeasure: 0,
        timeSignatureNumerator: 3,
        timeSignatureDenominator: 4,
      })

      return {
        bpm: Math.round(store.getState().bpm),
        timeSignature: store.getState().timeSignature,
      }
    })

    expect(result.bpm).toBe(180)
    expect(result.timeSignature).toBe('3/4')
  })
})
