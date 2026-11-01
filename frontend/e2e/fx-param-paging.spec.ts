/**
 * FX Parameter Paging E2E Tests
 *
 * The parameter list subscribes to a window of parameters around the rows
 * on screen and moves it as the list scrolls. The page talks to a fake
 * extension over a routed WebSocket that answers like the real one:
 * trackFxParams/subscribe pushes the values of exactly the requested
 * parameters, so a row shows a value only if the subscription covers it. A
 * request for more than 100 parameters, or a negative one, is rejected with
 * no event, as the extension rejects it.
 */

import { test, expect, type Page, type WebSocketRoute } from '@playwright/test';

const TRACK_GUID = '{TRACK-1}';
const FX_GUID = '{FX-1}';
const FX_NAME = 'Big Synth';
const PARAM_COUNT = 200;
/** The extension's per-subscription limit (MAX_SUBSCRIBED_PARAMS). */
const MAX_SUBSCRIBED_PARAMS = 100;

/** Parameter names: "Osc 0" … "Osc 99", then "Filter 100" … "Filter 199". */
function paramName(i: number): string {
  return i < 100 ? `Osc ${i}` : `Filter ${i}`;
}

/** Formatted value the fake extension reports for parameter i. */
function formattedValue(i: number): string {
  return `val-${i}`;
}

interface SubscribeRequest {
  indices?: number[];
  range?: { start: number; end: number };
}

interface FakeReaper {
  /** trackFxParams/subscribe requests, oldest first. */
  subscribes: SubscribeRequest[];
  /** trackFxParams/set requests, oldest first. */
  sets: Array<{ paramIdx: number; value: number }>;
  /** gesture/start and gesture/end requests, oldest first. */
  gestures: Array<{ command: string; paramIdx: number }>;
}

/**
 * The error code the extension answers a subscribe request with, or null
 * if it accepts it.
 */
function subscribeError(req: SubscribeRequest): string | null {
  if (req.indices) {
    if (req.indices.length > MAX_SUBSCRIBED_PARAMS) return 'TOO_MANY_PARAMS';
    if (req.indices.some((i) => i < 0)) return 'INVALID_INDEX';
    return null;
  }
  const start = req.range?.start ?? 0;
  const end = req.range?.end ?? 20;
  if (start < 0 || start > end) return 'INVALID_RANGE';
  if (end - start + 1 > MAX_SUBSCRIBED_PARAMS) return 'TOO_MANY_PARAMS';
  return null;
}

/** Parameter indices an accepted subscribe request covers, as the extension reads it. */
function coveredIndices(req: SubscribeRequest): number[] {
  if (req.indices) {
    return [...new Set(req.indices)].filter((i) => i < PARAM_COUNT);
  }
  const start = req.range?.start ?? 0;
  const end = Math.min(req.range?.end ?? 20, PARAM_COUNT - 1);
  const out: number[] = [];
  for (let i = start; i <= end; i++) out.push(i);
  return out;
}

async function installFakeReaper(page: Page): Promise<FakeReaper> {
  const fake: FakeReaper = { subscribes: [], sets: [], gestures: [] };

  await page.routeWebSocket(/\/ws$/, (ws: WebSocketRoute) => {
    const send = (msg: unknown) => ws.send(JSON.stringify(msg));
    const respond = (id: string | undefined, payload: unknown = {}) => {
      if (id) send({ type: 'response', id, success: true, payload });
    };

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

      const id = msg.id as string | undefined;
      switch (msg.command) {
        case 'trackFx/subscribe':
          respond(id);
          send({
            type: 'event',
            event: 'trackFxChain',
            payload: {
              trackGuid: TRACK_GUID,
              fx: [{
                fxGuid: FX_GUID, fxIndex: 0, name: FX_NAME, presetName: '',
                presetIndex: -1, presetCount: 0, modified: false, enabled: true,
              }],
            },
          });
          return;

        case 'trackFx/getParams':
          respond(id, {
            trackGuid: TRACK_GUID,
            fxGuid: FX_GUID,
            paramCount: PARAM_COUNT,
            nameHash: PARAM_COUNT,
            params: Array.from({ length: PARAM_COUNT }, (_, i) => paramName(i)),
          });
          return;

        case 'trackFxParams/subscribe': {
          const req: SubscribeRequest = {
            indices: msg.indices as number[] | undefined,
            range: msg.range as SubscribeRequest['range'],
          };
          fake.subscribes.push(req);
          const error = subscribeError(req);
          if (error) {
            // The previous subscription stays, so no event follows
            if (id) send({ type: 'response', id, success: false, error: { code: error, message: error } });
            return;
          }
          respond(id);
          const values: Record<string, [number, string]> = {};
          for (const i of coveredIndices(req)) {
            values[String(i)] = [i / PARAM_COUNT, formattedValue(i)];
          }
          send({
            type: 'event',
            event: 'trackFxParams',
            payload: {
              trackGuid: TRACK_GUID,
              fxGuid: FX_GUID,
              paramCount: PARAM_COUNT,
              // Matches the hash the client stores from getParams, so the
              // skeleton is not refetched.
              nameHash: PARAM_COUNT,
              values,
            },
          });
          return;
        }

        case 'trackFxParams/set':
          fake.sets.push({ paramIdx: msg.paramIdx as number, value: msg.value as number });
          respond(id);
          return;

        case 'gesture/start':
        case 'gesture/end':
          fake.gestures.push({ command: msg.command, paramIdx: msg.paramIdx as number });
          respond(id);
          return;

        default:
          respond(id);
      }
    });
  });

  return fake;
}

/** Seed one track with one FX, then open its parameter list. */
async function openParamList(page: Page): Promise<void> {
  await page.goto('/');
  await page.waitForFunction(() => (window as any).__REAPER_STORE__?.getState().connected === true, {
    timeout: 10000,
  });

  await page.evaluate((trackGuid) => {
    const store = (window as any).__REAPER_STORE__;
    store.setState({
      trackSkeleton: [
        { n: 'MASTER', g: 'master' },
        { n: 'Synth', g: trackGuid },
      ],
      totalTracks: 1,
      trackCount: 2,
      tracks: {
        0: {
          index: 0, guid: 'master', name: 'MASTER', flags: 0,
          volume: 1.0, pan: 0, color: 0,
          lastMeterPeak: 0, lastMeterPos: 0, clipped: false,
          width: 0, panMode: 0,
          sendCount: 0, receiveCount: 0, hwOutCount: 0, fxCount: 0,
        },
        1: {
          index: 1, guid: trackGuid, name: 'Synth', flags: 0,
          volume: 1.0, pan: 0, color: 0,
          lastMeterPeak: 0, lastMeterPos: 0, clipped: false,
          width: 0, panMode: 0,
          sendCount: 0, receiveCount: 0, hwOutCount: 0, fxCount: 1,
        },
      },
    });
  }, TRACK_GUID);

  await page.waitForSelector('[data-view="mixer"]', { state: 'visible' });
  await page
    .locator('[data-testid^="mixer-strip"][data-track-index="1"]')
    .getByTitle('Select for info')
    .click();

  // Hold the FX button to open the FX chain
  const fxButton = page.getByTitle(/FX enabled \(1 FX\)/);
  await fxButton.hover();
  await page.mouse.down();
  await page.waitForTimeout(700);
  await page.mouse.up();

  await page.getByText(FX_NAME).click();
  await expect(page.getByRole('dialog', { name: `Parameters for ${FX_NAME}` })).toBeVisible();
}

function paramDialog(page: Page) {
  return page.getByRole('dialog', { name: `Parameters for ${FX_NAME}` });
}

function paramRow(page: Page, i: number) {
  return paramDialog(page).locator(`[data-param-index="${i}"]`);
}

/**
 * Scroll the parameter list straight to the row at list position
 * `position` (parameter `paramIdx`) and wait until it is on screen.
 *
 * Rows are all one height, so the row's offset is its position times the
 * distance between two rendered rows; one scroll lands on it, with no
 * stepping that could outrun the virtualizer's re-render.
 */
async function scrollToParam(page: Page, paramIdx: number, position = paramIdx): Promise<void> {
  await paramDialog(page).getByTestId('fx-param-list').evaluate((el, pos) => {
    const rows = [...el.querySelectorAll<HTMLElement>('[data-index]')]
      .map((r) => ({ index: Number(r.dataset.index), top: r.getBoundingClientRect().top }))
      .sort((a, b) => a.index - b.index);
    if (rows.length < 2) throw new Error('need two rendered rows to measure the row stride');
    const [a, b] = rows;
    const stride = (b.top - a.top) / (b.index - a.index);
    el.scrollTop = pos * stride - (el.clientHeight - stride) / 2;
  }, position);
  await expect(paramRow(page, paramIdx)).toBeInViewport();
}

test.describe('FX parameter paging', () => {
  test.use({ viewport: { width: 414, height: 896 } });

  test('a row scrolled to past the first 50 shows its live value', async ({ page }) => {
    await installFakeReaper(page);
    await openParamList(page);

    await expect(paramRow(page, 0)).toContainText(formattedValue(0));

    await scrollToParam(page, 150);
    await expect(paramRow(page, 150)).toContainText(formattedValue(150));
    await expect(paramRow(page, 150).getByRole('slider')).toBeEnabled();
  });

  test('every subscription stays within the extension limit and covers the rows on screen', async ({ page }) => {
    const fake = await installFakeReaper(page);
    await openParamList(page);

    await scrollToParam(page, 150);
    await expect(paramRow(page, 150)).toContainText(formattedValue(150));

    expect(fake.subscribes.length).toBeGreaterThan(0);
    for (const req of fake.subscribes) {
      const requested = req.indices?.length ?? (req.range ? req.range.end - req.range.start + 1 : 0);
      expect(requested).toBeLessThanOrEqual(MAX_SUBSCRIBED_PARAMS);
    }
    const latest = coveredIndices(fake.subscribes[fake.subscribes.length - 1]);
    expect(latest).toContain(150);
  });

  test('the header counts all parameters and no truncation notice is shown', async ({ page }) => {
    await installFakeReaper(page);
    await openParamList(page);

    await expect(paramDialog(page).getByText(`${PARAM_COUNT} parameters`)).toBeVisible();
    await expect(paramDialog(page).getByText(/Showing \d+ of \d+ matches/)).toHaveCount(0);
  });

  test('filtering subscribes to the matching rows by parameter index', async ({ page }) => {
    const fake = await installFakeReaper(page);
    await openParamList(page);

    await paramDialog(page).getByPlaceholder('Filter parameters...').fill('Filter');
    await expect(paramDialog(page).getByText(`100 of ${PARAM_COUNT} parameters`)).toBeVisible();

    // The first match is parameter 100, which the unfiltered window never covered
    await expect(paramRow(page, 100)).toContainText(formattedValue(100));
    const latest = coveredIndices(fake.subscribes[fake.subscribes.length - 1]);
    expect(latest).toContain(100);
    expect(latest.every((i) => i >= 100)).toBe(true);

    // Parameter 180 is the 81st match
    await scrollToParam(page, 180, 80);
    await expect(paramRow(page, 180)).toContainText(formattedValue(180));
  });

  test('a filter typed while scrolled down subscribes its first matches straight away', async ({ page }) => {
    const fake = await installFakeReaper(page);
    await openParamList(page);
    // Row 120 keeps the unfiltered window (about 71..170) clear of the last
    // 100 parameters, so it differs from any window of the filtered list
    await scrollToParam(page, 120);
    await expect(paramRow(page, 120)).toContainText(formattedValue(120));
    // Let the subscribe throttle (100 ms) lapse, so the filter's first
    // window would go out at once rather than wait to be superseded
    await page.waitForTimeout(300);
    const before = fake.subscribes.length;

    // "1" matches 119 parameters (Osc 1, 10-19, 21, 31 ... 91 and Filter
    // 100-199): more than one window, so a window worked out from the old
    // scroll position would differ from the top one. The first match is
    // parameter 1.
    await paramDialog(page).getByPlaceholder('Filter parameters...').fill('1');
    await expect(paramDialog(page).getByText(`119 of ${PARAM_COUNT} parameters`)).toBeVisible();
    await expect(paramRow(page, 1)).toContainText(formattedValue(1));
    await expect(paramRow(page, 1)).toBeInViewport();

    // Every subscribe the filter caused starts at its first match: none was
    // worked out from the scroll position the unfiltered list had
    const after = fake.subscribes.slice(before);
    expect(after.length).toBeGreaterThan(0);
    for (const req of after) {
      expect(coveredIndices(req)[0]).toBe(1);
    }
  });

  test('a refetched skeleton with the same names keeps the scrolled rows live', async ({ page }) => {
    const fake = await installFakeReaper(page);
    await openParamList(page);
    await scrollToParam(page, 150);
    await expect(paramRow(page, 150)).toContainText(formattedValue(150));
    const before = fake.subscribes.length;

    // The skeleton comes back with the same names, as a new array
    await page.evaluate(() => {
      const s = (window as any).__REAPER_STORE__.getState();
      s.setFxParamSkeleton([...s.fxParamSkeleton], s.fxParamSkeletonHash);
    });
    await page.waitForTimeout(300);

    await expect(paramRow(page, 150)).toBeInViewport();
    await expect(paramRow(page, 150)).toContainText(formattedValue(150));
    await expect(paramRow(page, 150).getByRole('slider')).toBeEnabled();
    expect(fake.subscribes.slice(before)).toEqual([]);
  });

  test('rows announce their position in the whole list', async ({ page }) => {
    await installFakeReaper(page);
    await openParamList(page);

    const list = paramDialog(page).getByRole('list', { name: 'Parameters' });
    await expect(list.getByRole('listitem').first()).toHaveAttribute('aria-posinset', '1');
    await expect(list.getByRole('listitem').first()).toHaveAttribute('aria-setsize', String(PARAM_COUNT));

    await scrollToParam(page, 150);
    const row150 = list.getByRole('listitem').filter({ has: page.locator('[data-param-index="150"]') });
    await expect(row150).toHaveAttribute('aria-posinset', '151');
  });

  test('a row with no value yet cannot send a value', async ({ page }) => {
    const fake = await installFakeReaper(page);
    await openParamList(page);
    // Drop incoming values and forget the ones already received, so every
    // row is left without a value
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      store.setState({ handleFxParamsEvent: () => {} });
      store.setState({ fxParamValues: new Map() });
    });

    const row = paramRow(page, 1);
    await expect(row).toContainText('—');
    const slider = row.getByRole('slider');
    await expect(slider).toBeDisabled();

    // Drag across the slider, then double-tap it, once the sheet has
    // finished sliding in (hovering the row waits for it to be stable)
    await row.hover();
    const box = (await slider.boundingBox())!;
    const y = box.y + box.height / 2;
    await page.mouse.move(box.x + box.width * 0.2, y);
    await page.mouse.down();
    await page.mouse.move(box.x + box.width * 0.8, y, { steps: 5 });
    await page.mouse.up();
    await page.mouse.click(box.x + box.width * 0.5, y);
    await page.mouse.click(box.x + box.width * 0.5, y);
    await page.waitForTimeout(100);
    expect(fake.sets).toEqual([]);
  });

  test('a row scrolled out of view mid-drag still ends its gesture', async ({ page }) => {
    const fake = await installFakeReaper(page);
    await openParamList(page);

    const row = paramRow(page, 1);
    await expect(row).toContainText(formattedValue(1));
    await row.hover();
    const box = (await row.getByRole('slider').boundingBox())!;
    await page.mouse.move(box.x + box.width * 0.5, box.y + box.height / 2);
    await page.mouse.down();
    await expect.poll(() => fake.gestures).toEqual([{ command: 'gesture/start', paramIdx: 1 }]);

    // Scroll far enough that the row is unmounted, without releasing
    await paramDialog(page).getByTestId('fx-param-list').evaluate((el) => {
      el.scrollTop = el.scrollHeight;
    });
    await expect(row).toHaveCount(0);
    await expect.poll(() => fake.gestures).toEqual([
      { command: 'gesture/start', paramIdx: 1 },
      { command: 'gesture/end', paramIdx: 1 },
    ]);
    await page.mouse.up();
  });
});
