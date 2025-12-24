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

  // Inject test data
  await page.evaluate(() => {
    const store = (window as any).__REAPER_STORE__

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

// Helper to perform a long-press (hold for duration)
async function longPress(page: Page, selector: string, duration = 350) {
  const element = page.locator(selector)
  await element.hover()
  await page.mouse.down()
  await page.waitForTimeout(duration)
  await page.mouse.up()
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
    const bassTrack = page.locator('text=BASS').locator('..')

    // Check for blue box-shadow (selection indicator)
    await expect(bassTrack).toHaveCSS('box-shadow', /rgba\(59, 130, 246/)
  })

  test('unselected track shows gray border', async ({ page }) => {
    // DRUMS track (index 1) should have gray border since it's not selected
    const drumsTrack = page.locator('text=DRUMS').locator('..')

    // Check for no blue box-shadow
    const boxShadow = await drumsTrack.evaluate(el => getComputedStyle(el).boxShadow)
    expect(boxShadow).not.toContain('rgba(59, 130, 246')
  })

  test('long-press on track name sends setSelected command', async ({ page }) => {
    // Track WebSocket messages sent
    const sentMessages: any[] = []

    await page.evaluate(() => {
      // Mock the WebSocket send
      const store = (window as any).__REAPER_STORE__
      const originalConnection = store.getState().connection
      if (originalConnection) {
        const originalSend = originalConnection.send.bind(originalConnection)
        originalConnection.send = (command: string, params: any) => {
          (window as any).__SENT_COMMANDS__ = (window as any).__SENT_COMMANDS__ || []
          ;(window as any).__SENT_COMMANDS__.push({ command, params })
          // Don't actually send to avoid connection issues
        }
      }
    })

    // Long-press on DRUMS track name
    await longPress(page, 'text=DRUMS', 350)

    // Check that a track/setSelected command was sent
    const commands = await page.evaluate(() => (window as any).__SENT_COMMANDS__ || [])

    const selectCmd = commands.find((c: any) => c.command === 'track/setSelected')
    expect(selectCmd).toBeDefined()
    expect(selectCmd.params.trackIdx).toBe(1) // DRUMS is track index 1
  })
})
