/**
 * Record Button E2E Tests
 *
 * The Record button's presses in a real browser, against a fake extension
 * over a routed WebSocket that records each command the page sends. A tap
 * toggles recording and a hold sets the next record mode; a press that is
 * neither (a release with no press on the button, a right-click, a drag)
 * sends nothing, because a stray toggle starts a take.
 */

import { test, expect, type Locator, type Page, type WebSocketRoute } from '@playwright/test';

interface Sent {
  command: string;
  commandId?: number;
}

type At = { x: number; y: number };

const RECORD: Sent = { command: 'transport/record' };
const SET_TIME_SELECTION_PUNCH: Sent = { command: 'action/execute', commandId: 40076 };

/** The commands the Record button sends; the page sends others on its own. */
const BUTTON_COMMANDS = new Set(['transport/record', 'action/execute']);

async function installFakeReaper(page: Page): Promise<Sent[]> {
  const sent: Sent[] = [];
  await page.routeWebSocket(/\/ws$/, (ws: WebSocketRoute) => {
    const send = (msg: unknown) => ws.send(JSON.stringify(msg));
    ws.onMessage((raw) => {
      const msg = JSON.parse(String(raw)) as Record<string, unknown>;
      if (msg.type === 'hello') {
        send({ type: 'hello', extensionVersion: '0.0.0-e2e', protocolVersion: 1 });
        return;
      }
      if (msg.type === 'ping') {
        send({ type: 'pong' });
        return;
      }
      if (msg.type !== 'command') return;
      const command = msg.command as string;
      if (BUTTON_COMMANDS.has(command)) {
        sent.push(command === 'action/execute' ? { command, commandId: msg.commandId as number } : { command });
      }
      const id = msg.id as string | undefined;
      if (id) send({ type: 'response', id, success: true, payload: {} });
    });
  });
  return sent;
}

async function openClock(page: Page): Promise<Locator> {
  await page.goto('/');
  await page.waitForFunction(() => (window as any).__REAPER_STORE__?.getState().connected === true, {
    timeout: 10000,
  });
  await page.evaluate(() => {
    (window as any).__REAPER_STORE__.setState({ playState: 0, recordMode: 'normal' });
  });
  await page.getByRole('button', { name: 'Clock' }).click();
  const record = page.locator('[data-view="clock"] [data-action="record"]');
  await expect(record).toBeVisible();
  return record;
}

async function centre(el: Locator): Promise<At> {
  const box = await el.boundingBox();
  if (!box) throw new Error('element has no box');
  return { x: box.x + box.width / 2, y: box.y + box.height / 2 };
}

/** Lets any command a gesture sent reach the fake extension. */
async function settle(page: Page): Promise<void> {
  await page.waitForTimeout(300);
}

test.describe('Record button, mouse', () => {
  test.use({ viewport: { width: 414, height: 896 } });

  test('a click toggles recording once', async ({ page }) => {
    const sent = await installFakeReaper(page);
    const record = await openClock(page);

    await record.click();
    await settle(page);

    expect(sent).toEqual([RECORD]);
  });

  test('a press held past the hold time sets the next record mode and toggles nothing', async ({ page }) => {
    const sent = await installFakeReaper(page);
    const record = await openClock(page);

    await record.hover();
    await page.mouse.down();
    await page.waitForTimeout(500);
    await page.mouse.up();
    await settle(page);

    expect(sent).toEqual([SET_TIME_SELECTION_PUNCH]);
  });

  test('a press that starts off the button and is released over it sends nothing', async ({ page }) => {
    const sent = await installFakeReaper(page);
    const record = await openClock(page);
    const at = await centre(record);

    await page.mouse.move(at.x, at.y - 150);
    await page.mouse.down();
    await page.mouse.move(at.x, at.y, { steps: 10 });
    await page.mouse.up();
    await settle(page);

    expect(sent).toEqual([]);
  });

  test('a press held while the window loses focus sends nothing', async ({ page }) => {
    const sent = await installFakeReaper(page);
    const record = await openClock(page);

    await record.hover();
    await page.mouse.down();
    await page.waitForTimeout(100);
    // Cmd/Alt-Tab to another app: the window blurs and no pointer event comes.
    await page.evaluate(() => window.dispatchEvent(new Event('blur')));
    await page.waitForTimeout(500);
    await page.mouse.up();
    await settle(page);

    expect(sent).toEqual([]);
  });

  test('a right-click sends nothing', async ({ page }) => {
    const sent = await installFakeReaper(page);
    const record = await openClock(page);

    await record.click({ button: 'right' });
    await settle(page);

    expect(sent).toEqual([]);
  });
});

test.describe('Record button, keyboard', () => {
  test.use({ viewport: { width: 414, height: 896 } });

  test('Enter on the focused button toggles recording once', async ({ page }) => {
    const sent = await installFakeReaper(page);
    const record = await openClock(page);

    await record.focus();
    await page.keyboard.press('Enter');
    await settle(page);

    expect(sent).toEqual([RECORD]);
  });

  test('Enter held down toggles recording once, not again for each key repeat', async ({ page }) => {
    const sent = await installFakeReaper(page);
    const record = await openClock(page);

    await record.focus();
    // A held key, as the OS delivers it: one keydown, then auto-repeats.
    const cdp = await page.context().newCDPSession(page);
    const enter = { key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, text: '\r' };
    await cdp.send('Input.dispatchKeyEvent', { type: 'keyDown', ...enter });
    for (let i = 0; i < 5; i++) {
      await cdp.send('Input.dispatchKeyEvent', { type: 'keyDown', ...enter, autoRepeat: true });
    }
    await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13 });
    await settle(page);

    expect(sent).toEqual([RECORD]);
  });
});

test.describe('Record button, touch', () => {
  test.use({ viewport: { width: 414, height: 896 }, hasTouch: true, isMobile: true });

  /** One finger, driven through the DevTools protocol so it can move. */
  async function finger(page: Page) {
    const cdp = await page.context().newCDPSession(page);
    const send = (type: 'touchStart' | 'touchMove' | 'touchEnd', points: At[]) =>
      cdp.send('Input.dispatchTouchEvent', { type, touchPoints: points.map((p) => ({ ...p, id: 1 })) });
    return {
      down: (at: At) => send('touchStart', [at]),
      move: (at: At) => send('touchMove', [at]),
      up: () => send('touchEnd', []),
    };
  }

  test('a tap toggles recording once', async ({ page }) => {
    const sent = await installFakeReaper(page);
    const record = await openClock(page);

    await record.tap();
    await settle(page);

    expect(sent).toEqual([RECORD]);
  });

  test('a hold sets the next record mode and toggles nothing', async ({ page }) => {
    const sent = await installFakeReaper(page);
    const at = await centre(await openClock(page));

    const f = await finger(page);
    await f.down(at);
    await page.waitForTimeout(500);
    await f.up();
    await settle(page);

    expect(sent).toEqual([SET_TIME_SELECTION_PUNCH]);
  });

  test('a finger that drags across the button before lifting sends nothing', async ({ page }) => {
    const sent = await installFakeReaper(page);
    const at = await centre(await openClock(page));

    // 20 px stays on the button, which is at least 48 px across.
    const f = await finger(page);
    await f.down(at);
    for (let dx = 5; dx <= 20; dx += 5) {
      await f.move({ x: at.x + dx, y: at.y });
    }
    await f.up();
    await settle(page);

    expect(sent).toEqual([]);
  });
});
