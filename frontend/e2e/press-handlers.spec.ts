/**
 * Press Handler E2E Tests
 *
 * The timeline's selection mode button, the track info bar's FX button, the
 * toolbar's buttons and the Actions view's pads in a real browser, against a fake extension over a
 * routed WebSocket that records each command the page sends. A tap and a
 * hold do what each button says; a press that is neither (a release with no
 * press on the button, a right-click, a finger dragged across it) does
 * nothing. A tap or hold commits a name being edited before it acts.
 */

import { test, expect, type Locator, type Page, type WebSocketRoute } from '@playwright/test';

interface Sent {
  command: string;
  params?: Record<string, unknown>;
}

type At = { x: number; y: number };

/** The commands these buttons send; the page sends others on its own. */
const BUTTON_COMMANDS = new Set(['track/rename', 'track/setFxEnabled', 'action/execute']);

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
        const { type: _type, command: _command, id: _id, ...params } = msg;
        sent.push({ command, params });
      }
      const id = msg.id as string | undefined;
      if (id) send({ type: 'response', id, success: true, payload: {} });
    });
  });
  return sent;
}

async function connect(page: Page): Promise<void> {
  await page.goto('/');
  await page.waitForFunction(() => (window as any).__REAPER_STORE__?.getState().connected === true, {
    timeout: 10000,
  });
}

async function centre(el: Locator): Promise<At> {
  const box = await el.boundingBox();
  if (!box) throw new Error('element has no box');
  return { x: box.x + box.width / 2, y: box.y + box.height / 2 };
}

/** Lets any command or state change a gesture made land. */
async function settle(page: Page): Promise<void> {
  await page.waitForTimeout(300);
}

/**
 * Presses the mouse beside the element, on the bar behind it, then drags onto
 * the element and releases. The press starts on nothing that takes the
 * pointer for itself (a button, or the timeline, which captures it), so the
 * release lands on the element.
 */
async function pressBesideReleaseOn(page: Page, el: Locator, dx: number): Promise<void> {
  const at = await centre(el);
  const start = { x: at.x + dx, y: at.y };
  const startsOnBar = await page.evaluate(
    ({ x, y }) => document.elementFromPoint(x, y)?.closest('button, [data-testid="timeline-canvas"]') === null,
    start
  );
  expect(startsOnBar, 'the press starts on the bar, not a button or the timeline').toBe(true);
  await page.mouse.move(start.x, start.y);
  await page.mouse.down();
  await page.mouse.move(at.x, at.y, { steps: 10 });
  await page.mouse.up();
}

/** Holds the right mouse button on the element past every hold time. */
async function rightHold(page: Page, el: Locator): Promise<void> {
  await el.hover();
  await page.mouse.down({ button: 'right' });
  await page.waitForTimeout(700);
  await page.mouse.up({ button: 'right' });
}

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

// ============================================
// Timeline selection mode button
// ============================================

async function openTimeline(page: Page): Promise<Locator> {
  await connect(page);
  await page.evaluate(() => {
    (window as any).__REAPER_STORE__.setState({ duration: 120, regions: [], markers: [], items: [], tracks: {} });
  });
  await page.getByRole('button', { name: 'Timeline' }).click();
  const toggle = page.getByTestId('selection-toggle');
  await expect(toggle).toBeVisible();
  await expect(toggle).toHaveAttribute('aria-pressed', 'false');
  return toggle;
}

test.describe('Selection mode button, mouse and keyboard', () => {
  test.use({ viewport: { width: 414, height: 896 } });

  test('a click toggles selection mode', async ({ page }) => {
    await installFakeReaper(page);
    const toggle = await openTimeline(page);

    await toggle.click();

    await expect(toggle).toHaveAttribute('aria-pressed', 'true');
  });

  test('a press that starts beside the button and is released over it does not toggle', async ({ page }) => {
    await installFakeReaper(page);
    const toggle = await openTimeline(page);

    await pressBesideReleaseOn(page, toggle, 60);
    await settle(page);

    await expect(toggle).toHaveAttribute('aria-pressed', 'false');
  });

  test('a right-click does not toggle', async ({ page }) => {
    await installFakeReaper(page);
    const toggle = await openTimeline(page);

    await toggle.click({ button: 'right' });
    await settle(page);

    await expect(toggle).toHaveAttribute('aria-pressed', 'false');
  });

  test('Enter on the focused button toggles selection mode', async ({ page }) => {
    await installFakeReaper(page);
    const toggle = await openTimeline(page);

    await toggle.focus();
    await page.keyboard.press('Enter');

    await expect(toggle).toHaveAttribute('aria-pressed', 'true');
  });
});

test.describe('Selection mode button, touch', () => {
  test.use({ viewport: { width: 414, height: 896 }, hasTouch: true, isMobile: true });

  test('a tap toggles selection mode', async ({ page }) => {
    await installFakeReaper(page);
    const toggle = await openTimeline(page);

    await toggle.tap();

    await expect(toggle).toHaveAttribute('aria-pressed', 'true');
  });

  test('a finger dragged 20 px across the button does not toggle', async ({ page }) => {
    await installFakeReaper(page);
    const toggle = await openTimeline(page);
    const at = await centre(toggle);
    const f = await finger(page);

    await f.down(at);
    for (let dx = 4; dx <= 20; dx += 4) await f.move({ x: at.x + dx, y: at.y });
    await f.up();
    await settle(page);

    await expect(toggle).toHaveAttribute('aria-pressed', 'false');
  });
});

// ============================================
// Track info bar FX button
// ============================================

const TRACK_GUID = '{TRACK-1}';
const FX_TOGGLE: Sent = { command: 'track/setFxEnabled', params: { trackGuid: TRACK_GUID } };

async function openFxButton(page: Page): Promise<Locator> {
  await connect(page);
  await page.evaluate((trackGuid) => {
    const track = (index: number, guid: string, name: string, fxCount: number) => ({
      index, guid, name, flags: 0, volume: 1.0, pan: 0, color: 0,
      lastMeterPeak: 0, lastMeterPos: 0, clipped: false, width: 0, panMode: 0,
      sendCount: 0, receiveCount: 0, hwOutCount: 0, fxCount,
    });
    (window as any).__REAPER_STORE__.setState({
      trackSkeleton: [
        { n: 'MASTER', g: 'master' },
        { n: 'Synth', g: trackGuid },
      ],
      totalTracks: 1,
      trackCount: 2,
      tracks: { 0: track(0, 'master', 'MASTER', 0), 1: track(1, trackGuid, 'Synth', 2) },
    });
  }, TRACK_GUID);
  await page.waitForSelector('[data-view="mixer"]', { state: 'visible' });
  await page.locator('[data-testid^="mixer-strip"][data-track-index="1"]').getByTitle('Select for info').click();
  const fx = page.getByTitle(/FX enabled \(2 FX\)/);
  await expect(fx).toBeVisible();
  return fx;
}

/** The FX list a hold on the FX button opens. */
function fxList(page: Page): Locator {
  return page.getByRole('dialog').filter({ hasText: 'Synth' });
}

test.describe('FX button, mouse', () => {
  test.use({ viewport: { width: 414, height: 896 } });

  test('a click toggles the track FX once', async ({ page }) => {
    const sent = await installFakeReaper(page);
    const fx = await openFxButton(page);

    await fx.click();
    await settle(page);

    expect(sent).toEqual([FX_TOGGLE]);
  });

  test('a hold opens the FX list and toggles nothing', async ({ page }) => {
    const sent = await installFakeReaper(page);
    const fx = await openFxButton(page);

    await fx.hover();
    await page.mouse.down();
    await page.waitForTimeout(700);
    await page.mouse.up();
    await settle(page);

    await expect(fxList(page)).toBeVisible();
    expect(sent).toEqual([]);
  });

  test('a right-button hold neither opens the FX list nor toggles', async ({ page }) => {
    const sent = await installFakeReaper(page);
    const fx = await openFxButton(page);

    await rightHold(page, fx);
    await settle(page);

    await expect(fxList(page)).toHaveCount(0);
    expect(sent).toEqual([]);
  });
});

test.describe('FX button, touch', () => {
  test.use({ viewport: { width: 414, height: 896 }, hasTouch: true, isMobile: true });

  test('a tap toggles the track FX once', async ({ page }) => {
    const sent = await installFakeReaper(page);
    const fx = await openFxButton(page);

    await fx.tap();
    await settle(page);

    expect(sent).toEqual([FX_TOGGLE]);
  });

  test('a hold opens the FX list and toggles nothing', async ({ page }) => {
    const sent = await installFakeReaper(page);
    const fx = await openFxButton(page);
    const at = await centre(fx);
    const f = await finger(page);

    await f.down(at);
    await page.waitForTimeout(700);
    await f.up();
    await settle(page);

    await expect(fxList(page)).toBeVisible();
    expect(sent).toEqual([]);
  });

  test('a tap while the track name is being edited commits the rename, then toggles', async ({ page }) => {
    const sent = await installFakeReaper(page);
    const fx = await openFxButton(page);
    await page.getByTitle('Click to edit name').tap();
    const name = page.locator('input[type="text"]');
    await expect(name).toBeFocused();
    await name.fill('Lead');

    await fx.tap();
    await settle(page);

    expect(sent).toEqual([{ command: 'track/rename', params: { trackGuid: TRACK_GUID, name: 'Lead' } }, FX_TOGGLE]);
    await expect(name).toHaveCount(0);
  });
});

// ============================================
// Toolbar buttons
// ============================================

async function openToolbar(page: Page): Promise<Locator> {
  await connect(page);
  await page.evaluate(() => {
    (window as any).__REAPER_STORE__.setState({ duration: 120, regions: [], markers: [], items: [], tracks: {} });
  });
  await page.getByRole('button', { name: 'Timeline' }).click();
  await page.getByRole('tab', { name: 'Toolbar' }).click();
  const expand = page.getByRole('button', { name: 'Expand panel' });
  if (await expand.isVisible()) await expand.click();
  const split = page.getByTitle('Split', { exact: true });
  await expect(split).toBeVisible();
  return split;
}

/** What the Split button, and a pad set to the same action, send. */
const SPLIT: Sent = { command: 'action/execute', params: { commandId: 40012 } };

/** The editor a tap in edit mode opens. */
const toolbarEditor = (page: Page) => page.getByRole('heading', { name: /^(Edit|Add) / });

const toolbarEditMode = (page: Page) =>
  page.evaluate(() => (window as any).__REAPER_STORE__.getState().toolbarEditMode as boolean);

const toolbarLabels = (page: Page) =>
  page.evaluate(() =>
    ((window as any).__REAPER_STORE__.getState().toolbarActions as Array<{ label: string }>).map((a) => a.label)
  );

test.describe('Toolbar button, mouse', () => {
  test.use({ viewport: { width: 414, height: 896 } });

  test('a click runs the action once', async ({ page }) => {
    const sent = await installFakeReaper(page);
    const split = await openToolbar(page);

    await split.click();
    await settle(page);

    expect(sent).toEqual([SPLIT]);
  });

  test('a hold enters edit mode and runs nothing', async ({ page }) => {
    const sent = await installFakeReaper(page);
    const split = await openToolbar(page);

    await split.hover();
    await page.mouse.down();
    await page.waitForTimeout(600);
    await page.mouse.up();
    await settle(page);

    expect(await toolbarEditMode(page)).toBe(true);
    expect(sent).toEqual([]);
  });

  test('a right-button hold does not enter edit mode', async ({ page }) => {
    const sent = await installFakeReaper(page);
    const split = await openToolbar(page);

    await rightHold(page, split);
    await settle(page);

    expect(await toolbarEditMode(page)).toBe(false);
    expect(sent).toEqual([]);
  });

  test('in edit mode a mouse drag still reorders the buttons', async ({ page }) => {
    await installFakeReaper(page);
    const split = await openToolbar(page);
    await page.evaluate(() => (window as any).__REAPER_STORE__.getState().setToolbarEditMode(true));
    const before = await toolbarLabels(page);
    expect(before.slice(0, 2)).toEqual(['Split', 'Glue']);

    await split.dragTo(page.getByTitle('Glue', { exact: true }));
    await settle(page);

    const after = await toolbarLabels(page);
    expect(after.slice(0, 2)).toEqual(['Glue', 'Split']);
    await expect(toolbarEditor(page)).toHaveCount(0);
  });
});

test.describe('Toolbar button, touch', () => {
  test.use({ viewport: { width: 414, height: 896 }, hasTouch: true, isMobile: true });

  test('a tap runs the action once', async ({ page }) => {
    const sent = await installFakeReaper(page);
    const split = await openToolbar(page);

    await split.tap();
    await settle(page);

    expect(sent).toEqual([SPLIT]);
  });

  test('a hold enters edit mode, and its release runs nothing and opens no editor', async ({ page }) => {
    const sent = await installFakeReaper(page);
    const split = await openToolbar(page);
    const at = await centre(split);
    const f = await finger(page);

    await f.down(at);
    await page.waitForTimeout(450);
    await f.up();
    await settle(page);

    expect(await toolbarEditMode(page)).toBe(true);
    await expect(toolbarEditor(page)).toHaveCount(0);
    expect(sent).toEqual([]);
  });

  test('a tap in edit mode opens the editor and runs nothing', async ({ page }) => {
    const sent = await installFakeReaper(page);
    const split = await openToolbar(page);
    await page.evaluate(() => (window as any).__REAPER_STORE__.getState().setToolbarEditMode(true));

    await split.tap();

    await expect(toolbarEditor(page)).toHaveCount(1);
    expect(sent).toEqual([]);
  });

  test('in edit mode a finger drag reorders the buttons and opens no editor', async ({ page }) => {
    await installFakeReaper(page);
    const split = await openToolbar(page);
    await page.evaluate(() => (window as any).__REAPER_STORE__.getState().setToolbarEditMode(true));
    expect((await toolbarLabels(page)).slice(0, 2)).toEqual(['Split', 'Glue']);
    const at = await centre(split);
    const f = await finger(page);

    await f.down(at);
    for (let dy = 10; dy <= 120; dy += 10) await f.move({ x: at.x, y: at.y + dy });
    await f.up();
    await settle(page);

    expect((await toolbarLabels(page))[0]).not.toBe('Split');
    await expect(toolbarEditor(page)).toHaveCount(0);
  });
});

// ============================================
// Actions view pads (ToolbarButton)
// ============================================

async function openActionPad(page: Page): Promise<Locator> {
  await connect(page);
  await page.evaluate(() => {
    const store = (window as any).__REAPER_STORE__;
    store.getState().addSection({ name: 'Pads' });
    const id = store.getState().actionsSections.at(-1).id;
    store.getState().addActionToSection(id, {
      id: 'pad-1', type: 'reaper_action', label: 'PadA', actionId: '40012', sectionId: 0,
    });
  });
  await page.getByRole('button', { name: 'Actions', exact: true }).click();
  const pad = page.getByTitle('PadA', { exact: true });
  await expect(pad).toBeVisible();
  return pad;
}

test.describe('Actions view pad, touch', () => {
  test.use({ viewport: { width: 414, height: 896 }, hasTouch: true, isMobile: true });

  test('a tap runs the action once', async ({ page }) => {
    const sent = await installFakeReaper(page);
    const pad = await openActionPad(page);

    await pad.tap();
    await settle(page);

    expect(sent).toEqual([SPLIT]);
  });

  test('a finger that drifts 12 px, past the tap tolerance, runs nothing', async ({ page }) => {
    const sent = await installFakeReaper(page);
    const pad = await openActionPad(page);
    const at = await centre(pad);
    const f = await finger(page);

    await f.down(at);
    await f.move({ x: at.x + 12, y: at.y });
    await f.up();
    await settle(page);

    expect(sent).toEqual([]);
  });
});
