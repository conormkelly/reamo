/**
 * Track Selection E2E Tests
 *
 * Tests track rendering and selection state in the Mixer view.
 * MixerStrip (portrait): data-testid="mixer-strip", data-track-index={n}
 * MixerStripCompact (landscape): data-testid="mixer-strip-compact", data-track-index={n}
 * Use [data-testid^="mixer-strip"] to match both orientations.
 */

import { test, expect, Page } from '@playwright/test'

// Wait for store to be available and inject test fixtures
async function setupTestFixtures(page: Page) {
  await page.waitForFunction(() => (window as any).__REAPER_STORE__ !== undefined, {
    timeout: 10000,
  })

  await page.evaluate(() => {
    const store = (window as any).__REAPER_STORE__
    store.getState()._setTestMode(true)
  })

  await page.evaluate(() => {
    const store = (window as any).__REAPER_STORE__
    store.setState({
      connected: true,
      trackSkeleton: [
        { n: 'MASTER', g: 'master' },
        { n: 'DRUMS', g: '{TEST-GUID-DRUMS}' },
        { n: 'BASS', g: '{TEST-GUID-BASS}' },
      ],
      totalTracks: 2,
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
  test.use({ viewport: { width: 1024, height: 768 } })

  test.beforeEach(async ({ page }) => {
    await page.goto('/')
    await setupTestFixtures(page)

    // Navigate to Mixer view where mixer strips are rendered
    await page.getByRole('button', { name: 'Mixer' }).click()
    await page.waitForSelector('[data-view="mixer"]', { state: 'visible' })

    // Wait for tracks to render
    await page.waitForSelector('text=DRUMS')
  })

  test('mixer strips render for each track', async ({ page }) => {
    const masterStrip = page.locator('[data-testid^="mixer-strip"][data-track-index="0"]')
    const drumsStrip = page.locator('[data-testid^="mixer-strip"][data-track-index="1"]')
    const bassStrip = page.locator('[data-testid^="mixer-strip"][data-track-index="2"]')

    await expect(masterStrip).toBeVisible()
    await expect(drumsStrip).toBeVisible()
    await expect(bassStrip).toBeVisible()
  })

  test('track names are displayed', async ({ page }) => {
    await expect(page.getByText('DRUMS')).toBeVisible()
    await expect(page.getByText('BASS')).toBeVisible()
    await expect(page.getByText('MASTER')).toBeVisible()
  })

  test('selected track has elevated styling', async ({ page }) => {
    // BASS (index 2, flags=2 selected) strip div gets bg-bg-elevated
    const bassStrip = page.locator('[data-testid^="mixer-strip"][data-track-index="2"]')
    const drumsStrip = page.locator('[data-testid^="mixer-strip"][data-track-index="1"]')

    // Selected track strip has bg-bg-elevated, unselected has bg-bg-surface
    await expect(bassStrip).toHaveClass(/bg-bg-elevated/)
    await expect(drumsStrip).toHaveClass(/bg-bg-surface/)
  })

  test('track name button is interactive', async ({ page }) => {
    const drumsStrip = page.locator('[data-testid^="mixer-strip"][data-track-index="1"]')
    const nameButton = drumsStrip.locator('button').first()

    await expect(nameButton).toBeVisible()
    await expect(nameButton).toContainText('DRUMS')
  })

  test('non-master tracks show track number', async ({ page }) => {
    // DRUMS (index 1) should show "1" in its color bar
    const drumsStrip = page.locator('[data-testid^="mixer-strip"][data-track-index="1"]')
    await expect(drumsStrip.getByText('1', { exact: true })).toBeVisible()
  })

  test('master track does not show track number', async ({ page }) => {
    // Master track should not display a track index number
    const masterStrip = page.locator('[data-testid^="mixer-strip"][data-track-index="0"]')
    await expect(masterStrip).toBeVisible()

    // Master strip renders "MASTER" text but no numeric index
    // The color bar span (text-[8px]) is only rendered for !isMaster
    await expect(masterStrip.getByText('0', { exact: true })).not.toBeVisible()
  })
})
