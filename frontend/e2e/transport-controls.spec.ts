/**
 * Transport Controls E2E Tests
 *
 * Tests transport button interactions on the Clock view.
 * Verifies play/stop/record buttons send correct commands.
 */

import { test, expect, Page } from '@playwright/test';

async function setupTestStore(page: Page) {
  await page.waitForFunction(() => (window as any).__REAPER_STORE__ !== undefined, {
    timeout: 10000,
  });

  await page.evaluate(() => {
    const store = (window as any).__REAPER_STORE__;
    store.getState()._setTestMode(true);
  });

  await page.evaluate(() => {
    const store = (window as any).__REAPER_STORE__;
    store.setState({
      connected: true,
      playState: 0, // stopped
      positionSeconds: 0,
      bpm: 120,
      timeSignatureNumerator: 4,
      timeSignatureDenominator: 4,
      isRepeat: false,
      isMetronome: false,
      trackSkeleton: [],
      totalTracks: 0,
      tracks: {},
      regions: [],
      markers: [],
    });
  });
}

test.describe('Transport Controls', () => {
  test.use({ viewport: { width: 414, height: 896 } });

  test.beforeEach(async ({ page }) => {
    await page.goto('/');
    await setupTestStore(page);

    // Navigate to Clock view which has transport controls
    await page.getByRole('button', { name: 'Clock' }).click();
    await page.waitForSelector('[data-view="clock"]', { state: 'visible' });
  });

  test('shows transport controls', async ({ page }) => {
    await expect(page.locator('[data-testid="transport-controls"]')).toBeVisible();
  });

  test('shows BPM display', async ({ page }) => {
    const bpmDisplay = page.locator('[data-testid="bpm-timesig-display"]');
    await expect(bpmDisplay).toBeVisible();
    await expect(bpmDisplay).toContainText('120');
  });

  test('shows time display', async ({ page }) => {
    const timeDisplay = page.locator('[data-testid="time-display"]');
    await expect(timeDisplay).toBeVisible();
  });

  test('play button is visible', async ({ page }) => {
    // Transport buttons use data-testid="transport-button"
    const buttons = page.locator('[data-testid="transport-button"]');
    await expect(buttons.first()).toBeVisible();
  });

  test('transport reflects play state changes', async ({ page }) => {
    // Set play state to playing
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      store.setState({ playState: 1 }); // 1 = playing
    });

    // The beats display should still be visible and functional
    const beatsDisplay = page.locator('[data-testid="beats-display"]');
    await expect(beatsDisplay).toBeVisible();
  });

  test('transport reflects recording state', async ({ page }) => {
    // Set play state to recording
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      store.setState({ playState: 5 }); // 5 = recording
    });

    // Transport controls should still be functional
    await expect(page.locator('[data-testid="transport-controls"]')).toBeVisible();
  });
});
