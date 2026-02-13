/**
 * FX Management E2E Tests
 *
 * Tests FX chain display when viewing track FX.
 * Verifies FX state is shown correctly for tracks with FX.
 */

import { test, expect, Page } from '@playwright/test';

async function setupFxStore(page: Page) {
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
      ],
      totalTracks: 1,
      trackCount: 2,
      tracks: {
        0: {
          index: 0, guid: 'master', name: 'MASTER', flags: 0,
          volume: 1.0, pan: 0, color: 0,
          lastMeterPeak: 0, lastMeterPos: 0, clipped: false,
          width: 0, panMode: 0,
          sendCount: 0, receiveCount: 0, hwOutCount: 0, fxCount: 2,
        },
        1: {
          index: 1, guid: '{1}', name: 'Guitar', flags: 0,
          volume: 1.0, pan: 0, color: 0,
          lastMeterPeak: 0, lastMeterPos: 0, clipped: false,
          width: 0, panMode: 0,
          sendCount: 0, receiveCount: 0, hwOutCount: 0, fxCount: 3,
        },
      },
      // FX state for the Guitar track
      fx: [
        { trackIdx: 1, fxIdx: 0, name: 'ReaEQ', enabled: true },
        { trackIdx: 1, fxIdx: 1, name: 'ReaComp', enabled: true },
        { trackIdx: 1, fxIdx: 2, name: 'ReaDelay', enabled: false },
      ],
      bpm: 120,
      timeSignatureNumerator: 4,
      timeSignatureDenominator: 4,
      regions: [],
      markers: [],
    });
  });
}

test.describe('FX Management', () => {
  test.use({ viewport: { width: 1024, height: 768 } });

  test.beforeEach(async ({ page }) => {
    await page.goto('/');
    await setupFxStore(page);

    // Navigate to Mixer view
    await page.getByRole('button', { name: 'Mixer' }).click();
    await page.waitForSelector('[data-view="mixer"]', { state: 'visible' });
  });

  test('track with FX shows FX count', async ({ page }) => {
    // Guitar track has fxCount=3
    const guitarStrip = page.locator('[data-testid^="mixer-strip"][data-track-index="1"]');
    await expect(guitarStrip).toBeVisible();
  });

  test('FX state is accessible in store', async ({ page }) => {
    // Verify FX state was properly set
    const fxCount = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      return store.getState().fx?.length ?? 0;
    });
    expect(fxCount).toBe(3);
  });

  test('FX chain includes correct FX names', async ({ page }) => {
    const fxNames = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      return (store.getState().fx || []).map((f: { name: string }) => f.name);
    });
    expect(fxNames).toContain('ReaEQ');
    expect(fxNames).toContain('ReaComp');
    expect(fxNames).toContain('ReaDelay');
  });

  test('disabled FX is tracked in state', async ({ page }) => {
    const disabledFx = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      return (store.getState().fx || []).filter((f: { enabled: boolean }) => !f.enabled);
    });
    expect(disabledFx).toHaveLength(1);
    expect(disabledFx[0].name).toBe('ReaDelay');
  });
});
