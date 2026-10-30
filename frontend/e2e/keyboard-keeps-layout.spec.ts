/**
 * On-screen Keyboard E2E Tests
 *
 * The layout takes "is the phone on its side?" from screen.orientation, so
 * nothing that only shortens the viewport (the on-screen keyboard, or a
 * browser that leaves its viewport short after the keyboard closes) may
 * switch an upright phone to the side rail: the switch remounts the view,
 * which closes the dialog being typed in.
 *
 * Playwright's viewport resize also turns the emulated screen, which a real
 * keyboard never does, so these tests hold the device upright with a fake
 * screen.orientation and turn it explicitly with window.__turnDevice().
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

/** Replace screen.orientation with one the test controls, held upright. */
async function holdDeviceUpright(page: Page) {
  await page.addInitScript(() => {
    const orientation = new EventTarget() as EventTarget & { type: string; angle: number };
    orientation.type = 'portrait-primary';
    orientation.angle = 0;
    Object.defineProperty(Screen.prototype, 'orientation', { get: () => orientation });
    (window as any).__turnDevice = (type: string) => {
      orientation.type = type;
      orientation.dispatchEvent(new Event('change'));
    };
  });
}

test.describe('On-screen keyboard', () => {
  test.use({ viewport: { width: 412, height: 780 } }); // phone held upright

  test.beforeEach(async ({ page }) => {
    await holdDeviceUpright(page);
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

  test('an upright phone keeps bottom navigation when the browser leaves its viewport short', async ({ page }) => {
    // Replays an iPhone (Brave): the viewport shrinks with the keyboard for
    // Create Track and stays at 334px after the dialog closes.
    await resizeHeight(page, 664, 390);
    await page.getByRole('button', { name: 'Create track' }).click();
    await resizeHeight(page, 339, 390);
    await resizeHeight(page, 334, 390);
    await page.getByRole('button', { name: 'Cancel' }).click();
    await expect(page.getByRole('heading', { name: 'Create Track' })).toBeHidden();
    // The browser reports the short viewport again with nothing focused.
    await page.evaluate(() => window.dispatchEvent(new Event('resize')));

    await expect(page.getByTestId('nav-rail')).toHaveCount(0);
  });

  test('turning the phone to landscape still moves navigation to the side', async ({ page }) => {
    await page.evaluate(() => (window as any).__turnDevice('landscape-primary'));
    await resizeHeight(page, 412, 780);

    await expect(page.getByTestId('nav-rail')).toBeVisible();
  });
});
