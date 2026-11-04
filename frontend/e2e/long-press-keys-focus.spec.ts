/**
 * Long press: held keys and focus loss, in a real browser.
 *
 * Driven through the persistent transport's time display, which uses
 * useLongPress: two taps within 300 ms open Quick actions, and a 500 ms hold
 * opens Marker navigation. So an extra tap shows as Quick actions opening,
 * and a hold that should have ended shows as Marker navigation opening.
 */

import { test, expect, type CDPSession, type Locator, type Page } from '@playwright/test';

async function openTimeDisplay(page: Page): Promise<Locator> {
  await page.goto('/');
  await page.waitForFunction(() => (window as any).__REAPER_STORE__ !== undefined, { timeout: 10000 });
  await page.evaluate(() => {
    const store = (window as any).__REAPER_STORE__;
    store.getState()._setTestMode(true);
    store.setState({ connected: true, playState: 0, positionSeconds: 0, markers: [], regions: [] });
  });
  const display = page.getByRole('button', { name: /^Time display - double-tap/ });
  await expect(display).toBeVisible();
  return display;
}

const quickActions = (page: Page) => page.getByRole('dialog', { name: 'Quick actions panel' });
const markerNav = (page: Page) => page.getByRole('dialog', { name: 'Marker navigation' });

/** Lets a panel that a gesture opened finish rendering. */
async function settle(page: Page): Promise<void> {
  await page.waitForTimeout(300);
}

type Key = { key: string; code: string; windowsVirtualKeyCode: number; text: string };
const ENTER: Key = { key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, text: '\r' };
const SPACE: Key = { key: ' ', code: 'Space', windowsVirtualKeyCode: 32, text: ' ' };

/**
 * Time between two keyboard events. useDoubleTap needs its taps at least a
 * millisecond apart, and an OS repeats a held key about every 30 ms.
 */
const KEY_GAP_MS = 30;

/** A held key, as the OS delivers it: one keydown, auto-repeats, one keyup. */
async function holdKey(page: Page, cdp: CDPSession, k: Key, repeats: number): Promise<void> {
  await cdp.send('Input.dispatchKeyEvent', { type: 'keyDown', ...k });
  for (let i = 0; i < repeats; i++) {
    await page.waitForTimeout(KEY_GAP_MS);
    await cdp.send('Input.dispatchKeyEvent', { type: 'keyDown', ...k, autoRepeat: true });
  }
  await page.waitForTimeout(KEY_GAP_MS);
  const { text: _text, ...up } = k;
  await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', ...up });
}

test.describe('Long press, keyboard', () => {
  test.use({ viewport: { width: 414, height: 896 } });

  test('Enter pressed twice is two taps', async ({ page }) => {
    const display = await openTimeDisplay(page);

    await display.focus();
    await page.keyboard.press('Enter');
    await page.waitForTimeout(KEY_GAP_MS);
    await page.keyboard.press('Enter');

    await expect(quickActions(page)).toBeVisible();
  });

  test('Enter held down is one tap, not one more for each key repeat', async ({ page }) => {
    const display = await openTimeDisplay(page);

    await display.focus();
    await holdKey(page, await page.context().newCDPSession(page), ENTER, 5);
    await settle(page);

    await expect(quickActions(page)).toHaveCount(0);
  });

  test('Space held down still taps once on release', async ({ page }) => {
    const display = await openTimeDisplay(page);

    // The held Space's tap plus one more make a double tap.
    await display.focus();
    const cdp = await page.context().newCDPSession(page);
    await holdKey(page, cdp, SPACE, 5);
    await page.waitForTimeout(KEY_GAP_MS);
    await holdKey(page, cdp, SPACE, 0);

    await expect(quickActions(page)).toBeVisible();
  });
});

test.describe('Long press, focus loss', () => {
  test.use({ viewport: { width: 414, height: 896 } });

  test('a mouse hold opens Marker navigation', async ({ page }) => {
    const display = await openTimeDisplay(page);

    await display.hover();
    await page.mouse.down();
    await page.waitForTimeout(700);
    await page.mouse.up();

    await expect(markerNav(page)).toBeVisible();
  });

  test('the window losing focus mid-hold ends the hold', async ({ page }) => {
    const display = await openTimeDisplay(page);

    await display.hover();
    await page.mouse.down();
    await page.waitForTimeout(100);
    // Cmd/Alt-Tab to another app: the window blurs and no pointer event comes.
    await page.evaluate(() => window.dispatchEvent(new Event('blur')));
    await page.waitForTimeout(700);
    await page.mouse.up();
    await settle(page);

    await expect(markerNav(page)).toHaveCount(0);
    await expect(quickActions(page)).toHaveCount(0);
  });

  test('the page being hidden mid-hold ends the hold', async ({ page }) => {
    const display = await openTimeDisplay(page);

    await display.hover();
    await page.mouse.down();
    await page.waitForTimeout(100);
    await page.evaluate(() => {
      Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => 'hidden' });
      document.dispatchEvent(new Event('visibilitychange'));
    });
    await page.waitForTimeout(700);
    await page.mouse.up();
    await settle(page);

    await expect(markerNav(page)).toHaveCount(0);
  });
});
