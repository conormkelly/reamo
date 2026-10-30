/**
 * Dialog Safe Area E2E Tests
 *
 * Added to the home screen, the app draws under the iPhone's status bar and
 * Dynamic Island (black-translucent with viewport-fit=cover), and above the
 * home indicator. A dialog must keep clear of both, however little room is
 * left: its title and close button can't be tapped under the status bar.
 *
 * Chromium reports no safe-area insets, so these tests set the --safe-*
 * properties the app reads them through to an iPhone's values.
 */

import { test, expect, Page, Locator } from '@playwright/test';

const SAFE_TOP = 59;
const SAFE_BOTTOM = 34;
const VIEWPORT = { width: 390, height: 400 };

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
    store.getState().addSection({ name: 'Transport' });
  });
}

/** The dialog panel: the backdrop's child that holds the given heading. */
function panelWith(page: Page, heading: string): Locator {
  return page
    .locator('.z-modal > div')
    .filter({ has: page.getByRole('heading', { name: heading }) });
}

async function expectInsideSafeArea(panel: Locator) {
  await expect(panel).toBeVisible();
  const box = (await panel.boundingBox())!;
  expect(box.y, 'top edge below the status bar').toBeGreaterThanOrEqual(SAFE_TOP);
  expect(box.y + box.height, 'bottom edge above the home indicator').toBeLessThanOrEqual(
    VIEWPORT.height - SAFE_BOTTOM,
  );
}

test.describe('Dialogs on a home-screen iPhone', () => {
  test.use({ viewport: VIEWPORT });

  test.beforeEach(async ({ page }) => {
    await page.goto('/');
    await page.addStyleTag({
      content: `:root { --safe-top: ${SAFE_TOP}px; --safe-bottom: ${SAFE_BOTTOM}px; }`,
    });
    await setupTestStore(page);
    await page.waitForSelector('[data-view="mixer"]', { state: 'visible' });
  });

  test('a Modal stays clear of the status bar and home indicator', async ({ page }) => {
    await page.getByRole('button', { name: 'Create track' }).click();

    await expectInsideSafeArea(page.getByRole('dialog'));
  });

  test('the section editor stays clear of the status bar and home indicator', async ({ page }) => {
    await page.getByRole('button', { name: 'Actions', exact: true }).click();
    await page.getByRole('button', { name: 'Edit', exact: true }).click();
    await page.getByRole('button', { name: 'Section', exact: true }).click();

    await expectInsideSafeArea(panelWith(page, 'New Section'));
  });

  test('the action editor stays clear of the status bar while choosing an action', async ({ page }) => {
    await page.getByRole('button', { name: 'Actions', exact: true }).click();
    await page.getByRole('button', { name: 'Edit', exact: true }).click();
    await page.getByRole('button', { name: 'Add Action' }).click();
    await page.getByRole('button', { name: 'Search and Select Action...' }).click();

    await expectInsideSafeArea(panelWith(page, 'Add Action Button'));
  });
});
