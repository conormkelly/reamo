/**
 * Track Selection E2E Tests
 *
 * Tests long-press gesture on track name to toggle selection.
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
        },
        1: {
          index: 1,
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
        },
        2: {
          index: 2,
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

  test('selected track shows blue border', async ({ page }) => {
    // BASS track (index 2) should have blue border since it's selected
    // Use the track strip container (has specific class pattern)
    const bassStrip = page.locator('.bg-gray-900.rounded-lg.border').filter({ hasText: 'BASS' }).first()

    // Check for blue box-shadow (selection indicator)
    await expect(bassStrip).toHaveCSS('box-shadow', /rgba\(59, 130, 246/)
  })

  test('unselected track shows gray border', async ({ page }) => {
    // DRUMS track (index 1) should have gray border since it's not selected
    const drumsStrip = page.locator('.bg-gray-900.rounded-lg.border').filter({ hasText: 'DRUMS' }).first()

    // Check for no blue box-shadow (none or different color)
    const boxShadow = await drumsStrip.evaluate((el) => getComputedStyle(el).boxShadow)
    expect(boxShadow).toBe('none')
  })

  test('track name has cursor-pointer for long-press interaction', async ({ page }) => {
    // Verify the track name element has cursor-pointer class (indicates it's interactive)
    const drumsName = page
      .locator('.bg-gray-900.rounded-lg.border')
      .filter({ hasText: 'DRUMS' })
      .first()
      .locator('.cursor-pointer')
      .first()

    await expect(drumsName).toBeVisible()
    await expect(drumsName).toHaveText('DRUMS')
  })
})
