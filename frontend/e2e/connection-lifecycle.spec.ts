/**
 * Connection Lifecycle E2E Tests
 *
 * Tests connection states: connected, disconnected, error banner.
 * Verifies the app handles connection state changes gracefully.
 */

import { test, expect, Page } from '@playwright/test';

async function waitForStore(page: Page) {
  await page.waitForFunction(() => (window as any).__REAPER_STORE__ !== undefined, {
    timeout: 10000,
  });
}

test.describe('Connection Lifecycle', () => {
  test.use({ viewport: { width: 414, height: 896 } });

  test('shows loading screen when not connected', async ({ page }) => {
    await page.goto('/');
    await waitForStore(page);

    // Enable test mode to prevent WebSocket from changing state
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      store.getState()._setTestMode(true);
      store.setState({ connected: false });
    });

    // App should show loading/connecting state
    // The LoadingScreen shows "REAmo" heading
    await expect(page.getByText('REAmo')).toBeVisible();
  });

  test('shows app content when connected', async ({ page }) => {
    await page.goto('/');
    await waitForStore(page);

    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      store.getState()._setTestMode(true);
      store.setState({
        connected: true,
        tracks: {},
        trackSkeleton: [],
        totalTracks: 0,
        regions: [],
        markers: [],
        bpm: 120,
        timeSignatureNumerator: 4,
        timeSignatureDenominator: 4,
      });
    });

    // Should show app content (tab bar visible)
    await expect(page.getByRole('button', { name: 'Timeline' })).toBeVisible();
  });

  test('connection banner hidden when connected', async ({ page }) => {
    await page.goto('/');
    await waitForStore(page);

    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      store.getState()._setTestMode(true);
      store.setState({
        connected: true,
        tracks: {},
        trackSkeleton: [],
        totalTracks: 0,
        regions: [],
        markers: [],
        bpm: 120,
        timeSignatureNumerator: 4,
        timeSignatureDenominator: 4,
      });
    });

    // Wait for app to render
    await page.waitForSelector('[data-view="timeline"]', { state: 'visible' });

    // Connection banner should not be visible
    const banner = page.locator('[data-testid="connection-banner"]');
    await expect(banner).not.toBeVisible();
  });

  test('state persists across view switches after connection', async ({ page }) => {
    await page.goto('/');
    await waitForStore(page);

    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      store.getState()._setTestMode(true);
      store.setState({
        connected: true,
        trackSkeleton: [{ n: 'MASTER', g: 'master' }],
        totalTracks: 0,
        trackCount: 1,
        tracks: {
          0: { index: 0, guid: 'master', name: 'MASTER', flags: 0, volume: 1.0, pan: 0, color: 0, lastMeterPeak: 0, lastMeterPos: 0, clipped: false, width: 0, panMode: 0, sendCount: 0, receiveCount: 0, hwOutCount: 0, fxCount: 0 },
        },
        bpm: 135,
        timeSignatureNumerator: 4,
        timeSignatureDenominator: 4,
        regions: [],
        markers: [],
      });
    });

    // Navigate to Clock, then back
    await page.waitForSelector('[data-view="timeline"]', { state: 'visible' });
    await page.getByRole('button', { name: 'Clock' }).click();
    await page.waitForSelector('[data-view="clock"]', { state: 'visible' });

    // BPM should still be what we set
    const bpm = await page.evaluate(() => {
      return (window as any).__REAPER_STORE__.getState().bpm;
    });
    expect(bpm).toBe(135);

    // Navigate back
    await page.getByRole('button', { name: 'Timeline' }).click();
    await page.waitForSelector('[data-view="timeline"]', { state: 'visible' });

    // Still connected
    const connected = await page.evaluate(() => {
      return (window as any).__REAPER_STORE__.getState().connected;
    });
    expect(connected).toBe(true);
  });
});
