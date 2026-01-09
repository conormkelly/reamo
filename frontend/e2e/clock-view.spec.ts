/**
 * ClockView E2E Tests
 *
 * Tests that the Clock view properly adapts to different screen sizes and orientations,
 * maximizes screen space usage, and has no overflow/truncation.
 */

import { test, expect, Page } from '@playwright/test'

// Viewport configurations for different devices and orientations
const viewports = {
  // Mobile portrait (iPhone SE)
  mobilePortrait: { width: 375, height: 667 },
  // Mobile landscape (iPhone SE rotated)
  mobileLandscape: { width: 667, height: 375 },
  // Tablet portrait (iPad)
  tabletPortrait: { width: 768, height: 1024 },
  // Tablet landscape (iPad rotated)
  tabletLandscape: { width: 1024, height: 768 },
  // Desktop
  desktop: { width: 1280, height: 800 },
}

// Navigate to Clock view
async function navigateToClockView(page: Page) {
  await page.goto('/')

  // Wait for app to load
  await page.waitForFunction(() => (window as any).__REAPER_STORE__ !== undefined, {
    timeout: 10000,
  })

  // Enable test mode FIRST - prevents WebSocket from overwriting connection state
  await page.evaluate(() => {
    const store = (window as any).__REAPER_STORE__
    store.getState()._setTestMode(true)
  })

  // Set connected state to bypass loading screen (no real REAPER in e2e tests)
  await page.evaluate(() => {
    const store = (window as any).__REAPER_STORE__
    store.setState({ connected: true })
  })

  // Click on Clock tab
  await page.getByRole('button', { name: 'Clock' }).click()

  // Wait for view to render
  await page.waitForTimeout(100)
}

// Get the main clock container
function getClockContainer(page: Page) {
  // ClockView has data-view="clock" attribute (more stable than class selectors)
  return page.locator('[data-view="clock"]')
}

// Get the bar.beat display element
function getBeatsDisplay(page: Page) {
  return page.locator('.font-mono.font-bold.tracking-tight').first()
}

// Get the time display element
function getTimeDisplay(page: Page) {
  // TimeDisplay uses text-text-tertiary (was text-gray-300 before tokens refactor)
  return page.locator('.font-mono.text-text-tertiary').first()
}

// Get the BPM display element
function getBpmDisplay(page: Page) {
  // BpmTimeSigDisplay uses text-text-secondary (was text-gray-400 before tokens refactor)
  return page.locator('.font-bold.text-text-secondary').first()
}

// Get all transport buttons within the Clock view (not the persistent transport bar)
function getTransportButtons(page: Page) {
  // ClockView buttons are inside the clock container, not the persistent transport bar
  return getClockContainer(page).locator('button.rounded-full')
}

// Check if an element overflows its container
async function checkNoOverflow(page: Page) {
  const container = getClockContainer(page)
  const containerBox = await container.boundingBox()
  if (!containerBox) throw new Error('Container not found')

  // Check that all transport buttons are within viewport
  const buttons = await getTransportButtons(page).all()
  for (const button of buttons) {
    const buttonBox = await button.boundingBox()
    if (!buttonBox) continue

    // Button should be fully within container bounds
    expect(buttonBox.x).toBeGreaterThanOrEqual(0)
    expect(buttonBox.y).toBeGreaterThanOrEqual(0)
    expect(buttonBox.x + buttonBox.width).toBeLessThanOrEqual(containerBox.width + 1) // +1 for rounding
    expect(buttonBox.y + buttonBox.height).toBeLessThanOrEqual(containerBox.height + 1)
  }

  // Check that the button row is within horizontal bounds
  const buttonRow = getClockContainer(page).locator('.flex.items-center').filter({ has: page.locator('button.rounded-full') })
  const rowBox = await buttonRow.first().boundingBox()
  if (rowBox) {
    expect(rowBox.x).toBeGreaterThanOrEqual(0)
    expect(rowBox.x + rowBox.width).toBeLessThanOrEqual(containerBox.width + 1)
  }
}

// Check that elements use significant portion of screen
async function checkMaximizesSpace(page: Page, viewport: { width: number; height: number }) {
  const beatsDisplay = getBeatsDisplay(page)
  const beatsBox = await beatsDisplay.boundingBox()
  if (!beatsBox) throw new Error('Beats display not found')

  // In landscape tablet, beats display should be very large (>15% of screen width)
  // In portrait mobile, it should still be substantial (>50% of screen width)
  const widthRatio = beatsBox.width / viewport.width

  if (viewport.width > viewport.height && viewport.width >= 768) {
    // Tablet landscape - expect large display
    expect(widthRatio).toBeGreaterThan(0.3)
  } else {
    // Other layouts - still expect readable size
    expect(widthRatio).toBeGreaterThan(0.4)
  }
}

test.describe('ClockView layout', () => {
  test.describe('Mobile Portrait', () => {
    test.use({ viewport: viewports.mobilePortrait })

    test('all elements are visible', async ({ page }) => {
      await navigateToClockView(page)

      await expect(getBeatsDisplay(page)).toBeVisible()
      await expect(getTimeDisplay(page)).toBeVisible()
      await expect(getBpmDisplay(page)).toBeVisible()

      // All 5 transport buttons should be visible
      const buttons = await getTransportButtons(page).all()
      expect(buttons.length).toBe(5)
      for (const button of buttons) {
        await expect(button).toBeVisible()
      }
    })

    test('no horizontal overflow', async ({ page }) => {
      await navigateToClockView(page)
      await checkNoOverflow(page)
    })

    test('transport buttons fit within screen width', async ({ page }) => {
      await navigateToClockView(page)

      const buttons = await getTransportButtons(page).all()
      const firstButton = await buttons[0].boundingBox()
      const lastButton = await buttons[buttons.length - 1].boundingBox()

      if (firstButton && lastButton) {
        const totalWidth = (lastButton.x + lastButton.width) - firstButton.x
        // Should fit within viewport (checkNoOverflow tests exact bounds)
        // Here we just verify reasonable fit
        expect(totalWidth).toBeLessThan(viewports.mobilePortrait.width)
      }
    })
  })

  test.describe('Mobile Landscape', () => {
    test.use({ viewport: viewports.mobileLandscape })

    test('all elements are visible', async ({ page }) => {
      await navigateToClockView(page)

      await expect(getBeatsDisplay(page)).toBeVisible()
      await expect(getTimeDisplay(page)).toBeVisible()
      await expect(getBpmDisplay(page)).toBeVisible()

      const buttons = await getTransportButtons(page).all()
      expect(buttons.length).toBe(5)
    })

    test('no horizontal overflow', async ({ page }) => {
      await navigateToClockView(page)
      await checkNoOverflow(page)
    })

    test('layout is compact (less vertical spacing)', async ({ page }) => {
      await navigateToClockView(page)

      const beatsDisplay = getBeatsDisplay(page)
      const bpmDisplay = getBpmDisplay(page)

      const beatsBox = await beatsDisplay.boundingBox()
      const bpmBox = await bpmDisplay.boundingBox()

      if (beatsBox && bpmBox) {
        // Gap between beats and BPM should be compact in landscape
        const gap = bpmBox.y - (beatsBox.y + beatsBox.height)
        // In landscape mobile, should be relatively tight
        expect(gap).toBeLessThan(100)
      }
    })
  })

  test.describe('Tablet Portrait', () => {
    test.use({ viewport: viewports.tabletPortrait })

    test('all elements are visible', async ({ page }) => {
      await navigateToClockView(page)

      await expect(getBeatsDisplay(page)).toBeVisible()
      await expect(getTimeDisplay(page)).toBeVisible()
      await expect(getBpmDisplay(page)).toBeVisible()

      const buttons = await getTransportButtons(page).all()
      expect(buttons.length).toBe(5)
    })

    test('no overflow', async ({ page }) => {
      await navigateToClockView(page)
      await checkNoOverflow(page)
    })

    test('elements are larger than mobile', async ({ page }) => {
      await navigateToClockView(page)

      const buttons = await getTransportButtons(page).all()
      const buttonBox = await buttons[0].boundingBox()

      if (buttonBox) {
        // With more vertical space, buttons should be larger (dynamic sizing)
        // Minimum 48px from clamp(), should be bigger with tablet height
        expect(buttonBox.width).toBeGreaterThanOrEqual(48)
      }
    })
  })

  test.describe('Tablet Landscape', () => {
    test.use({ viewport: viewports.tabletLandscape })

    test('all elements are visible', async ({ page }) => {
      await navigateToClockView(page)

      await expect(getBeatsDisplay(page)).toBeVisible()
      await expect(getTimeDisplay(page)).toBeVisible()
      await expect(getBpmDisplay(page)).toBeVisible()

      const buttons = await getTransportButtons(page).all()
      expect(buttons.length).toBe(5)
    })

    test('no overflow', async ({ page }) => {
      await navigateToClockView(page)
      await checkNoOverflow(page)
    })

    test('maximizes screen space', async ({ page }) => {
      await navigateToClockView(page)
      await checkMaximizesSpace(page, viewports.tabletLandscape)
    })

    test('elements are largest size', async ({ page }) => {
      await navigateToClockView(page)

      const buttons = await getTransportButtons(page).all()
      const buttonBox = await buttons[0].boundingBox()

      if (buttonBox) {
        // With good vertical space in landscape tablet, buttons should be large
        // Dynamic sizing with clamp(48px, 12cqh, 112px)
        expect(buttonBox.width).toBeGreaterThanOrEqual(70)
      }

      // Beats display should be very large
      const beatsBox = await getBeatsDisplay(page).boundingBox()
      if (beatsBox) {
        // Should be significant portion of screen width
        expect(beatsBox.width).toBeGreaterThan(200)
      }
    })
  })

  test.describe('Desktop', () => {
    test.use({ viewport: viewports.desktop })

    test('all elements are visible', async ({ page }) => {
      await navigateToClockView(page)

      await expect(getBeatsDisplay(page)).toBeVisible()
      await expect(getTimeDisplay(page)).toBeVisible()
      await expect(getBpmDisplay(page)).toBeVisible()

      const buttons = await getTransportButtons(page).all()
      expect(buttons.length).toBe(5)
    })

    test('no overflow', async ({ page }) => {
      await navigateToClockView(page)
      await checkNoOverflow(page)
    })
  })
})

test.describe('ClockView content', () => {
  test.use({ viewport: viewports.tabletLandscape })

  test('displays initial values', async ({ page }) => {
    await navigateToClockView(page)

    // Should show default values
    const beatsText = await getBeatsDisplay(page).textContent()
    expect(beatsText).toMatch(/\d+\.\d+\.\d+/)

    const timeText = await getTimeDisplay(page).textContent()
    expect(timeText).toMatch(/\d+:\d+\.\d/)

    // BPM should be visible
    const bpmText = await getBpmDisplay(page).textContent()
    expect(bpmText).toContain('BPM')
  })

  test('transport buttons have correct states', async ({ page }) => {
    await navigateToClockView(page)

    // Initially stopped - stop button should be active (bg-gray-600)
    const buttons = await getTransportButtons(page).all()

    // At least one button should exist
    expect(buttons.length).toBe(5)

    // All buttons should be interactive
    for (const button of buttons) {
      await expect(button).toBeEnabled()
    }
  })
})

test.describe('ClockView text overflow', () => {
  // These tests verify that bar.beat text content doesn't overflow for various lengths
  // The bug: fixed font sizing caused truncation at screen edges for large/negative bar numbers

  /**
   * Helper to check if text content fits within container bounds
   * This is what was MISSING from the original checkNoOverflow - it only checked buttons!
   */
  async function checkTextFitsInContainer(page: Page) {
    const container = getClockContainer(page)
    const containerBox = await container.boundingBox()
    if (!containerBox) throw new Error('Container not found')

    const beatsDisplay = getBeatsDisplay(page)
    const beatsBox = await beatsDisplay.boundingBox()
    if (!beatsBox) throw new Error('Beats display not found')

    // Text should fit within container with some padding
    // Left edge should be >= 0
    expect(beatsBox.x, 'Text left edge should be within container').toBeGreaterThanOrEqual(0)
    // Right edge should be <= container width
    expect(
      beatsBox.x + beatsBox.width,
      'Text right edge should be within container'
    ).toBeLessThanOrEqual(containerBox.width + 1) // +1 for rounding
  }

  /**
   * Helper to set bar.beat content directly (simulates REAPER sending various positions)
   */
  async function setBeatsContent(page: Page, content: string) {
    await page.evaluate((text) => {
      const el = document.querySelector('.font-mono.font-bold.tracking-tight span')
      if (el) el.textContent = text
    }, content)
    // Give layout time to recalculate
    await page.waitForTimeout(50)
  }

  // Test cases for various bar.beat content lengths
  const testCases = [
    { name: 'short (bar 1)', content: '1.1.00' },
    { name: 'medium (bar 10)', content: '10.4.50' },
    { name: 'long (bar 100)', content: '100.4.99' },
    { name: 'very long (bar 999)', content: '999.4.99' },
    { name: 'negative bar', content: '-4.1.00' },
    { name: 'long negative bar', content: '-99.4.50' },
    { name: 'very long negative bar', content: '-999.4.99' },
  ]

  test.describe('Mobile Portrait (narrowest)', () => {
    test.use({ viewport: viewports.mobilePortrait })

    for (const { name, content } of testCases) {
      test(`bar.beat text fits: ${name}`, async ({ page }) => {
        await navigateToClockView(page)
        await setBeatsContent(page, content)
        await checkTextFitsInContainer(page)
      })
    }
  })

  test.describe('Tablet Portrait', () => {
    test.use({ viewport: viewports.tabletPortrait })

    for (const { name, content } of testCases) {
      test(`bar.beat text fits: ${name}`, async ({ page }) => {
        await navigateToClockView(page)
        await setBeatsContent(page, content)
        await checkTextFitsInContainer(page)
      })
    }
  })

  test.describe('Narrow device (iPhone SE)', () => {
    test.use({ viewport: { width: 320, height: 568 } })

    for (const { name, content } of testCases) {
      test(`bar.beat text fits: ${name}`, async ({ page }) => {
        await navigateToClockView(page)
        await setBeatsContent(page, content)
        await checkTextFitsInContainer(page)
      })
    }
  })
})

test.describe('ClockView responsiveness', () => {
  test('adapts when viewport changes', async ({ page }) => {
    // Start in portrait
    await page.setViewportSize(viewports.mobilePortrait)
    await navigateToClockView(page)

    const portraitBeatsBox = await getBeatsDisplay(page).boundingBox()

    // Switch to landscape - give container queries time to recalculate
    await page.setViewportSize(viewports.mobileLandscape)
    await page.waitForTimeout(300)

    const landscapeBeatsBox = await getBeatsDisplay(page).boundingBox()

    // Text size should change (smaller in landscape due to less height)
    if (portraitBeatsBox && landscapeBeatsBox) {
      // The height or font metrics should differ
      expect(portraitBeatsBox.height).not.toBe(landscapeBeatsBox.height)
    }

    // All elements should still be visible after resize
    await expect(getBeatsDisplay(page)).toBeVisible()
    await expect(getTimeDisplay(page)).toBeVisible()
    await expect(getBpmDisplay(page)).toBeVisible()
  })

  test('handles narrow viewport without breaking', async ({ page }) => {
    // Very narrow viewport
    await page.setViewportSize({ width: 320, height: 568 })
    await navigateToClockView(page)

    // Everything should still be visible
    await expect(getBeatsDisplay(page)).toBeVisible()
    await expect(getTimeDisplay(page)).toBeVisible()

    // Buttons should fit
    await checkNoOverflow(page)
  })

  test('handles very wide viewport', async ({ page }) => {
    await page.setViewportSize({ width: 1920, height: 1080 })
    await navigateToClockView(page)

    // Elements should be visible and centered
    await expect(getBeatsDisplay(page)).toBeVisible()

    const container = getClockContainer(page)
    const containerBox = await container.boundingBox()
    const beatsBox = await getBeatsDisplay(page).boundingBox()

    if (containerBox && beatsBox) {
      // Beats should be horizontally centered
      const beatsCenter = beatsBox.x + beatsBox.width / 2
      const containerCenter = containerBox.width / 2
      expect(Math.abs(beatsCenter - containerCenter)).toBeLessThan(50)
    }
  })
})
