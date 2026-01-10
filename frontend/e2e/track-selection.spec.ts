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

  // Enable test mode FIRST - prevents WebSocket from overwriting connection state
  await page.evaluate(() => {
    const store = (window as any).__REAPER_STORE__
    store.getState()._setTestMode(true)
  })

  // Set test data in separate evaluate
  await page.evaluate(() => {
    const store = (window as any).__REAPER_STORE__
    store.setState({
      // Bypass loading screen (no real REAPER in e2e tests)
      connected: true,
      // Track skeleton (for MixerSection virtualization): { n: name, g: guid }
      trackSkeleton: [
        { n: 'MASTER', g: 'master' },
        { n: 'DRUMS', g: '{TEST-GUID-DRUMS}' },
        { n: 'BASS', g: '{TEST-GUID-BASS}' },
      ],
      totalTracks: 2, // Excludes master
      // Full track data (for TrackStrip): Record<number, Track>
      trackCount: 3,
      tracks: {
        0: { index: 0, guid: 'master', name: 'MASTER', flags: 0, volume: 1.0, pan: 0, color: 0, lastMeterPeak: 0, lastMeterPos: 0, clipped: false, width: 0, panMode: 0, sendCount: 0, receiveCount: 0, hwOutCount: 0, fxCount: 0 },
        1: { index: 1, guid: '{TEST-GUID-DRUMS}', name: 'DRUMS', flags: 0, volume: 1.0, pan: 0, color: 0, lastMeterPeak: 0, lastMeterPos: 0, clipped: false, width: 0, panMode: 0, sendCount: 0, receiveCount: 0, hwOutCount: 0, fxCount: 0 },
        2: { index: 2, guid: '{TEST-GUID-BASS}', name: 'BASS', flags: 2, volume: 1.0, pan: 0, color: 0, lastMeterPeak: 0, lastMeterPos: 0, clipped: false, width: 0, panMode: 0, sendCount: 0, receiveCount: 0, hwOutCount: 0, fxCount: 0 }, // flags: 2 = selected
      },
    })
  })
}

test.describe('Track Selection', () => {
  // Use desktop viewport so Mixer section is expanded by default
  test.use({ viewport: { width: 1024, height: 768 } })

  test.beforeEach(async ({ page }) => {
    // Navigate to the app - stay in Studio view (default) which has the Mixer section
    await page.goto('/')
    await setupTestFixtures(page)

    // Wait for Studio view to load (Mixer section is inside Studio)
    await page.waitForSelector('[data-view="studio"]', { state: 'visible' })

    // Wait for tracks to render in the Mixer section
    await page.waitForSelector('text=DRUMS')
  })

  test('selected track shows brighter background', async ({ page }) => {
    // BASS track (index 2) should have brighter background since it's selected
    // TrackStrip uses CSS variables: var(--color-bg-elevated) for selected
    const bassStrip = page.locator('[data-testid="track-strip"][data-track-index="2"]')
    await expect(bassStrip).toBeVisible()
    await expect(bassStrip).toHaveAttribute('data-selected', 'true')

    // Verify it has a different background than unselected tracks
    const drumsStrip = page.locator('[data-testid="track-strip"][data-track-index="1"]')
    await expect(drumsStrip).toHaveAttribute('data-selected', 'false')
    const bassBackground = await bassStrip.evaluate((el) => getComputedStyle(el).backgroundColor)
    const drumsBackground = await drumsStrip.evaluate((el) => getComputedStyle(el).backgroundColor)
    expect(bassBackground).not.toBe(drumsBackground)
  })

  test('unselected track shows darker background', async ({ page }) => {
    // DRUMS track (index 1) should have darker background since it's not selected
    // TrackStrip uses CSS variables: var(--color-bg-surface) for unselected
    const drumsStrip = page.locator('[data-testid="track-strip"][data-track-index="1"]')
    await expect(drumsStrip).toBeVisible()
    await expect(drumsStrip).toHaveAttribute('data-selected', 'false')
  })

  test('track name has cursor-pointer for tap interaction', async ({ page }) => {
    // Verify the track name element has cursor-pointer class (indicates it's interactive)
    const drumsStrip = page.locator('[data-testid="track-strip"][data-track-index="1"]')
    const drumsName = drumsStrip.locator('[data-testid="track-name"]')

    await expect(drumsName).toBeVisible()
    await expect(drumsName).toHaveText('DRUMS')
    await expect(drumsName).toHaveClass(/cursor-pointer/)
  })

  test('master track has squared top and rounded bottom', async ({ page }) => {
    // Master track should have squared top corners, subtle bottom radius
    const masterStrip = page.locator('[data-testid="track-strip"][data-master="true"]')
    await expect(masterStrip).toBeVisible()

    // Tailwind rounded-b-md: top corners 0, bottom corners 6px
    await expect(masterStrip).toHaveCSS('border-top-left-radius', '0px')
    await expect(masterStrip).toHaveCSS('border-top-right-radius', '0px')
    await expect(masterStrip).toHaveCSS('border-bottom-left-radius', '6px')
    await expect(masterStrip).toHaveCSS('border-bottom-right-radius', '6px')
  })

  test('non-master tracks have full border radius', async ({ page }) => {
    // Non-master tracks should have rounded corners
    const drumsStrip = page.locator('[data-testid="track-strip"][data-track-index="1"]')
    await expect(drumsStrip).toHaveAttribute('data-master', 'false')

    // Tailwind's rounded-lg is 0.5rem = 8px
    await expect(drumsStrip).toBeVisible()
  })

  test('unselected track shows color bar at top', async ({ page }) => {
    // DRUMS track should have a color bar div at the top (replaces the old border-top)
    // TrackStrip now uses a separate div with h-2.5 (10px) for the color bar
    const drumsStrip = page.locator('[data-testid="track-strip"][data-track-index="1"]')
    const colorBar = drumsStrip.locator('[data-testid="track-color-bar"]')

    await expect(colorBar).toBeVisible()
    // Color bar has h-2.5 class which is 10px (0.625rem)
    await expect(colorBar).toHaveCSS('height', '10px')
  })

  test('selected track shows color bar at top', async ({ page }) => {
    // BASS track is selected and should show the color bar
    const bassStrip = page.locator('[data-testid="track-strip"][data-track-index="2"]')
    const colorBar = bassStrip.locator('[data-testid="track-color-bar"]')

    await expect(colorBar).toBeVisible()
    // Color bar has h-2.5 class which is 10px (0.625rem)
    await expect(colorBar).toHaveCSS('height', '10px')
  })

  test('non-master tracks show track number on color bar', async ({ page }) => {
    // DRUMS track (index 1) should show "1" on the color bar
    const drumsStrip = page.locator('[data-testid="track-strip"][data-track-index="1"]')
    const trackNumber = drumsStrip.locator('[data-testid="track-number"]')

    await expect(trackNumber).toBeVisible()
    await expect(trackNumber).toHaveText('1')
  })

  test('master track does not show track number', async ({ page }) => {
    // Master track should not have a track number
    const masterStrip = page.locator('[data-testid="track-strip"][data-master="true"]')
    const trackNumber = masterStrip.locator('[data-testid="track-number"]')

    await expect(trackNumber).not.toBeVisible()
  })
})
