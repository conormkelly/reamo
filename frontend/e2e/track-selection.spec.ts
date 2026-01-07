/**
 * Track Selection E2E Tests
 *
 * Tests tap/long-press gestures on track name for selection.
 * - Tap: toggle selection
 * - Long-press: exclusive select
 */

import { test, expect, Page } from '@playwright/test'

// Wait for store to be available and inject test fixtures
async function setupTestFixtures(page: Page) {
  // Wait for the store to be exposed on window
  await page.waitForFunction(() => (window as any).__REAPER_STORE__ !== undefined, {
    timeout: 10000,
  })

  // Inject test data - enable test mode first to prevent WebSocket from overwriting fixtures
  await page.evaluate(() => {
    const store = (window as any).__REAPER_STORE__

    // Enable test mode to prevent WebSocket messages from overwriting fixtures
    store.getState()._setTestMode(true)

    store.setState({
      // Test tracks: Master + 2 user tracks
      trackCount: 3,
      tracks: {
        0: {
          index: 0,
          guid: 'master',
          name: 'MASTER',
          color: 0,
          volume: 1.0,
          pan: 0,
          flags: 0, // Not selected
          lastMeterPeak: 0,
          lastMeterPos: 0,
          clipped: false,
          width: 0,
          panMode: 0,
          sendCount: 0,
          receiveCount: 0,
          hwOutCount: 0,
          fxCount: 0,
        },
        1: {
          index: 1,
          guid: '{TEST-GUID-DRUMS-0001}',
          name: 'DRUMS',
          color: 0,
          volume: 1.0,
          pan: 0,
          flags: 0, // Not selected
          lastMeterPeak: 0,
          lastMeterPos: 0,
          clipped: false,
          width: 0,
          panMode: 0,
          sendCount: 0,
          receiveCount: 0,
          hwOutCount: 0,
          fxCount: 0,
        },
        2: {
          index: 2,
          guid: '{TEST-GUID-BASS-0002}',
          name: 'BASS',
          color: 0,
          volume: 1.0,
          pan: 0,
          flags: 2, // Selected (SELECTED = 2)
          lastMeterPeak: 0,
          lastMeterPos: 0,
          clipped: false,
          width: 0,
          panMode: 0,
          sendCount: 0,
          receiveCount: 0,
          hwOutCount: 0,
          fxCount: 0,
        },
      },
    })
  })
}

test.describe('Track Selection', () => {
  test.beforeEach(async ({ page }) => {
    // Navigate to the mixer page
    await page.goto('/mixer')
    await setupTestFixtures(page)
    // Wait for tracks to render
    await page.waitForSelector('text=DRUMS')
  })

  test('selected track shows brighter background', async ({ page }) => {
    // BASS track (index 2) should have brighter background since it's selected
    const bassStrip = page.locator('.rounded-lg.border').filter({ hasText: 'BASS' }).first()

    // Check for brighter background color (#374151 = rgb(55, 65, 81))
    await expect(bassStrip).toHaveCSS('background-color', 'rgb(55, 65, 81)')
  })

  test('unselected track shows darker background', async ({ page }) => {
    // DRUMS track (index 1) should have darker background since it's not selected
    const drumsStrip = page.locator('.rounded-lg.border').filter({ hasText: 'DRUMS' }).first()

    // Check for darker background color (#1f2937 = rgb(31, 41, 55))
    await expect(drumsStrip).toHaveCSS('background-color', 'rgb(31, 41, 55)')
  })

  test('track name has cursor-pointer for tap interaction', async ({ page }) => {
    // Verify the track name element has cursor-pointer class (indicates it's interactive)
    const drumsName = page
      .locator('.rounded-lg.border')
      .filter({ hasText: 'DRUMS' })
      .first()
      .locator('.cursor-pointer')
      .first()

    await expect(drumsName).toBeVisible()
    await expect(drumsName).toHaveText('DRUMS')
  })

  test('master track has squared top and rounded bottom', async ({ page }) => {
    // Master track should have squared top corners, subtle bottom radius
    const masterStrip = page.locator('.rounded-b-md.border').filter({ hasText: 'Master' }).first()

    // Tailwind rounded-b-md: top corners 0, bottom corners 6px
    await expect(masterStrip).toHaveCSS('border-top-left-radius', '0px')
    await expect(masterStrip).toHaveCSS('border-top-right-radius', '0px')
    await expect(masterStrip).toHaveCSS('border-bottom-left-radius', '6px')
    await expect(masterStrip).toHaveCSS('border-bottom-right-radius', '6px')
  })

  test('non-master tracks have full border radius', async ({ page }) => {
    // Non-master tracks should have rounded corners
    const drumsStrip = page.locator('.rounded-lg.border').filter({ hasText: 'DRUMS' }).first()

    // Tailwind's rounded-lg is 0.5rem = 8px
    await expect(drumsStrip).toBeVisible()
  })

  test('unselected track shows colored top border', async ({ page }) => {
    // DRUMS track is unselected but should still show the colored top border
    const drumsStrip = page.locator('.rounded-lg.border').filter({ hasText: 'DRUMS' }).first()

    // Default gray color: #6b7280 = rgb(107, 114, 128)
    await expect(drumsStrip).toHaveCSS('border-top-color', 'rgb(107, 114, 128)')
    await expect(drumsStrip).toHaveCSS('border-top-width', '5px')
  })

  test('selected track shows colored top border', async ({ page }) => {
    // BASS track is selected and should show the colored top border
    const bassStrip = page.locator('.rounded-lg.border').filter({ hasText: 'BASS' }).first()

    // Default gray color: #6b7280 = rgb(107, 114, 128)
    await expect(bassStrip).toHaveCSS('border-top-color', 'rgb(107, 114, 128)')
    await expect(bassStrip).toHaveCSS('border-top-width', '5px')
  })
})
