/**
 * On-screen Keyboard E2E Tests
 *
 * On Android, the viewport meta's interactive-widget=resizes-content makes the
 * keyboard shrink the page's height. A dialog that focuses a text field opens
 * the keyboard as it appears, and on an upright phone that can leave the page
 * wider than tall. The layout must not switch to the side rail for that: the
 * switch remounts the view, which closes the dialog.
 *
 * The keyboard is simulated by shrinking the viewport's height.
 */

import { test, expect, Page } from '@playwright/test';

async function setupTestStore(page: Page) {
  await page.waitForFunction(() => (window as any).__REAPER_STORE__ !== undefined, {
    timeout: 10000,
  });

  await page.evaluate(() => {
    const store = (window as any).__REAPER_STORE__;
    store.getState()._setTestMode(true);
    store.setState({
      connected: true,
      trackSkeleton: [{ n: 'MASTER', g: 'master' }],
      totalTracks: 0,
      trackCount: 1,
      tracks: {},
      regions: [],
      markers: [],
      bpm: 120,
    });
  });
}

/** Resize to `height`, then let the app handle it before anything is checked. */
async function resizeHeight(page: Page, height: number, width = 412) {
  await page.setViewportSize({ width, height });
  await page.waitForFunction((h) => window.innerHeight === h, height);
  await page.evaluate(
    () => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))),
  );
}

test.describe('On-screen keyboard', () => {
  test.use({ viewport: { width: 412, height: 780 } }); // phone held upright

  test.beforeEach(async ({ page }) => {
    await page.goto('/');
    await setupTestStore(page);
    await page.waitForSelector('[data-view="mixer"]', { state: 'visible' });
  });

  test('opening the keyboard keeps the New Section dialog open', async ({ page }) => {
    await page.getByRole('button', { name: 'Actions', exact: true }).click();
    await page.getByRole('button', { name: 'Create Section' }).click();
    const name = page.getByPlaceholder('e.g., Transport, FX, Navigation');
    await expect(name).toBeFocused();

    // The keyboard leaves less height than the phone's width.
    await resizeHeight(page, 400);

    await expect(page.getByTestId('nav-rail')).toHaveCount(0);
    await expect(page.getByRole('heading', { name: 'New Section' })).toBeVisible();
    await expect(name).toBeFocused();
  });

  test('a section named with the keyboard up is created', async ({ page }) => {
    await page.getByRole('button', { name: 'Actions', exact: true }).click();
    await page.getByRole('button', { name: 'Create Section' }).click();
    await resizeHeight(page, 400);
    await page.getByPlaceholder('e.g., Transport, FX, Navigation').fill('Drums');
    await page.getByRole('button', { name: 'Create', exact: true }).click();
    await resizeHeight(page, 780);

    await expect(page.getByRole('heading', { name: 'New Section' })).toBeHidden();
    await expect(page.getByText('Drums')).toBeVisible();
  });

  test('the Create Track name field keeps focus once the dialog has opened', async ({ page }) => {
    await page.getByRole('button', { name: 'Create track' }).click();
    const name = page.getByLabel('Name (optional)');
    await expect(name).toBeFocused();

    // Past the dialog's own focus handling, which runs after the first tick.
    await page.waitForTimeout(100);

    await expect(name).toBeFocused();
  });

  test('turning the phone to landscape still moves navigation to the side', async ({ page }) => {
    await resizeHeight(page, 412, 780);

    await expect(page.getByTestId('nav-rail')).toBeVisible();
  });
});
