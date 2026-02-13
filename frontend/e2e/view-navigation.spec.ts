/**
 * View Navigation E2E Tests
 *
 * Tests tab switching between views and that each view renders correctly.
 * Covers the critical flow: user navigates between views without losing state.
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
      trackSkeleton: [
        { n: 'MASTER', g: 'master' },
        { n: 'Guitar', g: '{1}' },
        { n: 'Bass', g: '{2}' },
      ],
      totalTracks: 2,
      trackCount: 3,
      tracks: {
        0: { index: 0, guid: 'master', name: 'MASTER', flags: 0, volume: 1.0, pan: 0, color: 0, lastMeterPeak: 0, lastMeterPos: 0, clipped: false, width: 0, panMode: 0, sendCount: 0, receiveCount: 0, hwOutCount: 0, fxCount: 0 },
        1: { index: 1, guid: '{1}', name: 'Guitar', flags: 0, volume: 1.0, pan: 0, color: 0, lastMeterPeak: 0, lastMeterPos: 0, clipped: false, width: 0, panMode: 0, sendCount: 0, receiveCount: 0, hwOutCount: 0, fxCount: 0 },
        2: { index: 2, guid: '{2}', name: 'Bass', flags: 0, volume: 1.0, pan: 0, color: 0, lastMeterPeak: 0, lastMeterPos: 0, clipped: false, width: 0, panMode: 0, sendCount: 0, receiveCount: 0, hwOutCount: 0, fxCount: 0 },
      },
      regions: [
        { id: 0, name: 'Intro', start: 0, end: 10, color: 0 },
      ],
      markers: [],
      bpm: 120,
      timeSignatureNumerator: 4,
      timeSignatureDenominator: 4,
    });
  });
}

test.describe('View Navigation', () => {
  test.use({ viewport: { width: 414, height: 896 } }); // iPhone-sized (bottom tab bar)

  test.beforeEach(async ({ page }) => {
    await page.goto('/');
    await setupTestStore(page);
    // Default view is timeline
    await page.waitForSelector('[data-view="timeline"]', { state: 'visible' });
  });

  test('default view is Timeline', async ({ page }) => {
    const timelineView = page.locator('[data-view="timeline"]');
    await expect(timelineView).toBeVisible();
  });

  test('can switch to Mixer view', async ({ page }) => {
    await page.getByRole('button', { name: 'Mixer' }).click();
    await expect(page.locator('[data-view="mixer"]')).toBeVisible();
    // Mixer should show mixer strips
    await expect(page.locator('[data-testid^="mixer-strip"]').first()).toBeVisible();
  });

  test('can switch to Clock view', async ({ page }) => {
    await page.getByRole('button', { name: 'Clock' }).click();
    await expect(page.locator('[data-view="clock"]')).toBeVisible();
    // Clock should show transport controls
    await expect(page.locator('[data-testid="transport-controls"]')).toBeVisible();
  });

  test('can switch to Playlist view', async ({ page }) => {
    await page.getByRole('button', { name: 'Playlist' }).click();
    await expect(page.locator('[data-view="playlist"]')).toBeVisible();
  });

  test('can switch to Actions view', async ({ page }) => {
    await page.getByRole('button', { name: 'Actions', exact: true }).click();
    await expect(page.locator('[data-view="actions"]')).toBeVisible();
  });

  test('navigating away and back preserves connection state', async ({ page }) => {
    // Navigate to Mixer
    await page.getByRole('button', { name: 'Mixer' }).click();
    await expect(page.locator('[data-view="mixer"]')).toBeVisible();

    // Navigate back to Timeline
    await page.getByRole('button', { name: 'Timeline' }).click();
    await expect(page.locator('[data-view="timeline"]')).toBeVisible();

    // Verify still connected (no loading screen / connection banner)
    const connected = await page.evaluate(() => {
      return (window as any).__REAPER_STORE__.getState().connected;
    });
    expect(connected).toBe(true);
  });

  test('tab bar highlights active view', async ({ page }) => {
    // Timeline tab should be active initially
    const timelineTab = page.getByRole('button', { name: 'Timeline' });
    await expect(timelineTab).toHaveClass(/text-text-primary/);

    // Switch to Mixer
    const mixerTab = page.getByRole('button', { name: 'Mixer' });
    await mixerTab.click();
    await expect(mixerTab).toHaveClass(/text-text-primary/);
    // Timeline tab should no longer be active
    await expect(timelineTab).toHaveClass(/text-text-secondary/);
  });
});
