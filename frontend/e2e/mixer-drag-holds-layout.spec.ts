/**
 * Mixer drag layout hold E2E Tests
 *
 * While a fader is dragged, the mixer's strips keep the tracks they showed
 * when the drag began, so a track inserted, removed or moved in REAPER
 * cannot slide another track under the finger. The held changes apply when
 * the drag ends, by release or by the browser cancelling the touch. If the
 * dragged track itself is deleted, its fader greys out and sends nothing
 * more.
 *
 * Runs against a fake extension over a routed WebSocket: it pushes the
 * track events a test asks for, sends each tracks event for the page's
 * current track subscription as the extension does, and records the volume
 * and gesture commands the page sends. Like the extension, which answers a
 * subscription on its next poll, it sends the tracks event for a new
 * subscription a poll later, so a page that briefly lacks a track between
 * subscriptions shows it.
 */

import { test, expect, type Locator, type Page, type WebSocketRoute } from '@playwright/test';

interface Sent {
  command: string;
  trackGuid?: string;
}

type Row = { g: string; name: string };

const MASTER: Row = { g: 'master', name: 'MASTER' };
const DRUMS: Row = { g: '{DRUMS}', name: 'Drums' };
const BASS: Row = { g: '{BASS}', name: 'Bass' };
const KEYS: Row = { g: '{KEYS}', name: 'Keys' };
const NEW: Row = { g: '{NEW}', name: 'New track' };

/** The extension's high-tier poll interval. */
const POLL_MS = 33;

const RECORDED = new Set(['track/setVolume', 'gesture/start', 'gesture/end']);

interface FakeReaper {
  sent: Sent[];
  /** Sends REAPER's track list as both a skeleton and a tracks event. */
  setTracks: (rows: Row[]) => void;
  /** Sets a track's volume in REAPER and sends the tracks event. */
  setVolume: (guid: string, volume: number) => void;
}

interface Subscription {
  range?: { start: number; end: number };
  guids?: string[];
  extraGuids?: string[];
  includeMaster?: boolean;
}

/** Whether the extension sends the track at idx to a page with this subscription. */
function subscribed(sub: Subscription | null, row: Row, idx: number): boolean {
  if (!sub) return false;
  if (sub.includeMaster && row.g === 'master') return true;
  if (sub.extraGuids?.includes(row.g)) return true;
  if (sub.guids) return sub.guids.includes(row.g);
  return !!sub.range && idx >= sub.range.start && idx <= sub.range.end;
}

async function installFakeReaper(page: Page): Promise<FakeReaper> {
  const sent: Sent[] = [];
  let socket: WebSocketRoute | null = null;
  let current: Row[] = [MASTER, DRUMS, BASS, KEYS];
  let subscription: Subscription | null = null;
  const volumes = new Map<string, number>();

  const send = (msg: unknown) => socket?.send(JSON.stringify(msg));
  const pushTracksEvent = () => {
    send({
      type: 'event',
      event: 'tracks',
      payload: {
        total: current.length - 1,
        tracks: current
          .map((r, idx) => ({ r, idx }))
          .filter(({ r, idx }) => subscribed(subscription, r, idx))
          .map(({ r, idx }) => ({
            idx, g: r.g, name: r.name, color: 0, volume: volumes.get(r.g) ?? 1.0, pan: 0,
            mute: false, solo: 0, recArm: false, recMon: 0, fxEnabled: true, selected: false,
            fxCount: 0, sendCount: 0, receiveCount: 0, hwOutCount: 0,
          })),
      },
    });
  };
  const pushTracks = () => {
    send({
      type: 'event',
      event: 'trackSkeleton',
      payload: {
        tracks: current.map((r) => ({
          n: r.name, g: r.g, m: false, sl: null, sel: false, r: false,
          fd: 0, sc: 0, hc: 0, cl: false, ic: 0, fm: 0, c: 0,
        })),
      },
    });
    pushTracksEvent();
  };

  await page.routeWebSocket(/\/ws$/, (ws: WebSocketRoute) => {
    socket = ws;
    ws.onMessage((raw) => {
      const msg = JSON.parse(String(raw)) as Record<string, unknown>;
      if (msg.type === 'hello') {
        send({ type: 'hello', extensionVersion: '0.0.0-e2e', protocolVersion: 1 });
        pushTracks();
        return;
      }
      if (msg.type === 'ping') {
        send({ type: 'pong' });
        return;
      }
      if (msg.type !== 'command') return;
      const command = msg.command as string;
      if (command === 'track/subscribe') {
        subscription = msg as Subscription;
        setTimeout(pushTracksEvent, POLL_MS);
      }
      if (RECORDED.has(command)) {
        sent.push({ command, trackGuid: msg.trackGuid as string | undefined });
      }
      const id = msg.id as string | undefined;
      if (id) send({ type: 'response', id, success: true, payload: {} });
    });
  });

  return {
    sent,
    setTracks: (rows) => {
      current = rows;
      pushTracks();
    },
    setVolume: (guid, volume) => {
      volumes.set(guid, volume);
      pushTracksEvent();
    },
  };
}

async function openMixer(page: Page): Promise<void> {
  await page.goto('/');
  await page.waitForFunction(() => (window as any).__REAPER_STORE__?.getState().connected === true, {
    timeout: 10000,
  });
  await page.getByRole('button', { name: 'Mixer' }).click();
  await expect(stripAt(page, 2)).toBeVisible();
}

function stripAt(page: Page, index: number): Locator {
  return page.locator(`[data-testid="mixer-strip"][data-track-index="${index}"]`);
}

/** The name shown on the strip at an index. */
function nameAt(page: Page, index: number): Locator {
  return stripAt(page, index).getByTitle(/ - tap to (de)?select$/);
}

function faderAt(page: Page, index: number): Locator {
  return stripAt(page, index).getByTitle('Volume - double-tap to reset to 0dB');
}

async function centre(el: Locator): Promise<{ x: number; y: number }> {
  const box = await el.boundingBox();
  if (!box) throw new Error('element has no box');
  return { x: box.x + box.width / 2, y: box.y + box.height / 2 };
}

/** Lets pushed events reach the page and sent commands reach the fake. */
async function settle(page: Page): Promise<void> {
  await page.waitForTimeout(300);
}

test.describe('Mixer drag holds the track layout, mouse', () => {
  test.use({ viewport: { width: 414, height: 896 } });

  test('a track inserted above the dragged one moves nothing until the release', async ({ page }) => {
    const fake = await installFakeReaper(page);
    await openMixer(page);
    await expect(nameAt(page, 2)).toHaveText('Bass');

    const at = await centre(faderAt(page, 2));
    await page.mouse.move(at.x, at.y);
    await page.mouse.down();
    fake.setTracks([MASTER, NEW, DRUMS, BASS, KEYS]);
    await settle(page);

    await expect(nameAt(page, 1)).toHaveText('Drums');
    await expect(nameAt(page, 2)).toHaveText('Bass');
    await page.mouse.move(at.x, at.y - 30, { steps: 3 });
    await settle(page);

    await page.mouse.up();
    await expect(nameAt(page, 2)).toHaveText('Drums');
    await expect(nameAt(page, 1)).toHaveText('New track');

    const volumeGuids = new Set(fake.sent.filter((s) => s.command === 'track/setVolume').map((s) => s.trackGuid));
    expect(volumeGuids).toEqual(new Set(['{BASS}']));
    expect(fake.sent.filter((s) => s.command === 'gesture/end')).toEqual([{ command: 'gesture/end', trackGuid: '{BASS}' }]);
  });

  test('a dragged track deleted mid-drag greys its fader, which sends nothing more', async ({ page }) => {
    const fake = await installFakeReaper(page);
    await openMixer(page);

    const fader = faderAt(page, 2);
    const at = await centre(fader);
    await page.mouse.move(at.x, at.y);
    await page.mouse.down();
    await page.mouse.move(at.x, at.y - 10, { steps: 2 });
    await settle(page);
    const writesBefore = fake.sent.filter((s) => s.command === 'track/setVolume').length;
    expect(writesBefore).toBeGreaterThan(0);

    fake.setTracks([MASTER, DRUMS, KEYS]);
    await settle(page);

    await expect(nameAt(page, 2)).toHaveText('Bass');
    await expect(fader).toHaveAttribute('aria-disabled', 'true');
    await page.mouse.move(at.x, at.y - 60, { steps: 4 });
    await page.mouse.up();
    await settle(page);

    expect(fake.sent.filter((s) => s.command === 'track/setVolume')).toHaveLength(writesBefore);
    expect(fake.sent.filter((s) => s.command === 'gesture/end')).toEqual([]);
    await expect(nameAt(page, 2)).toHaveText('Keys');
    await expect(fader).not.toHaveAttribute('aria-disabled');
  });

  test('the window losing focus mid-drag ends it and applies the held changes', async ({ page }) => {
    const fake = await installFakeReaper(page);
    await openMixer(page);

    const at = await centre(faderAt(page, 2));
    await page.mouse.move(at.x, at.y);
    await page.mouse.down();
    fake.setTracks([MASTER, NEW, DRUMS, BASS, KEYS]);
    await settle(page);
    await expect(nameAt(page, 2)).toHaveText('Bass');

    // Cmd/Alt-Tab to another app: the window blurs and no release comes.
    await page.evaluate(() => window.dispatchEvent(new Event('blur')));
    await expect(nameAt(page, 2)).toHaveText('Drums');
    expect(fake.sent.filter((s) => s.command === 'gesture/end')).toHaveLength(1);
    await page.mouse.up();
  });
});

test.describe('Mixer drag holds the track layout, touch', () => {
  test.use({ viewport: { width: 414, height: 896 }, hasTouch: true, isMobile: true });

  test('a touch the browser cancels mid-drag ends it and applies the held changes', async ({ page }) => {
    const fake = await installFakeReaper(page);
    await openMixer(page);

    const at = await centre(faderAt(page, 2));
    const cdp = await page.context().newCDPSession(page);
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ ...at, id: 1 }] });
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ x: at.x, y: at.y - 10, id: 1 }] });
    fake.setTracks([MASTER, NEW, DRUMS, BASS, KEYS]);
    await settle(page);
    await expect(nameAt(page, 2)).toHaveText('Bass');

    await cdp.send('Input.dispatchTouchEvent', { type: 'touchCancel', touchPoints: [] });
    await expect(nameAt(page, 2)).toHaveText('Drums');
    await settle(page);
    expect(fake.sent.filter((s) => s.command === 'gesture/end')).toEqual([{ command: 'gesture/end', trackGuid: '{BASS}' }]);
  });
});

test.describe('Mixer drag holds the track layout, tablet', () => {
  // A portrait tablet: every track fits in one bank, so the last is on screen.
  test.use({ viewport: { width: 768, height: 1024 } });

  test('the last track keeps receiving its values when an insert above moves it past the subscribed range', async ({ page }) => {
    const fake = await installFakeReaper(page);
    await openMixer(page);
    await expect(nameAt(page, 3)).toHaveText('Keys');

    const at = await centre(faderAt(page, 3));
    await page.mouse.move(at.x, at.y);
    await page.mouse.down();
    // Keys moves from index 3, the last, to 4.
    fake.setTracks([MASTER, NEW, DRUMS, BASS, KEYS]);
    await settle(page);
    fake.setVolume('{KEYS}', 0.5);

    await expect(nameAt(page, 3)).toHaveText('Keys');
    await expect(stripAt(page, 3)).toContainText('-6.02 dB');
    await page.mouse.up();

    // The release subscribes the index range again: the new track arrives.
    await expect(nameAt(page, 1)).toHaveText('New track');
    await expect(nameAt(page, 4)).toHaveText('Keys');
    await expect(stripAt(page, 4)).toContainText('-6.02 dB');
  });
});

test.describe('Mixer drag holds the track layout, info track', () => {
  test.use({ viewport: { width: 414, height: 896 } });

  const T = (n: number): Row => ({ g: `{T${n}}`, name: `T${n}` });
  const TWELVE: Row[] = [MASTER, ...Array.from({ length: 12 }, (_, i) => T(i + 1))];

  test('off-screen prefetched tracks and the info track stay in the store and updating through a drag and its release', async ({ page }) => {
    await page.addInitScript(() => localStorage.setItem('reamo-mixer-info-selected', '{T5}'));
    const fake = await installFakeReaper(page);
    await openMixer(page);
    fake.setTracks(TWELVE);
    await settle(page);
    // T5 is in the prefetched range, not on screen.
    await expect(stripAt(page, 5)).toHaveCount(0);
    // T5 is the info track; T6 is only prefetched.
    await page.waitForFunction(() => {
      const { tracks } = (window as any).__REAPER_STORE__.getState();
      return tracks[5]?.guid === '{T5}' && tracks[6]?.guid === '{T6}';
    });

    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      const w = window as any;
      w.__offScreenMissing = 0;
      store.subscribe((s: any) => {
        if (s.tracks[5]?.guid !== '{T5}' || s.tracks[6]?.guid !== '{T6}') w.__offScreenMissing++;
      });
    });

    const at = await centre(faderAt(page, 1));
    await page.mouse.move(at.x, at.y);
    await page.mouse.down();
    await page.mouse.move(at.x, at.y - 20, { steps: 2 });
    await settle(page);
    fake.setVolume('{T5}', 0.5);
    fake.setVolume('{T6}', 0.25);
    await settle(page);
    // Their values keep arriving during the drag.
    expect(
      await page.evaluate(() => {
        const { tracks } = (window as any).__REAPER_STORE__.getState();
        return [tracks[5]?.volume, tracks[6]?.volume];
      })
    ).toEqual([0.5, 0.25]);

    await page.mouse.up();
    await settle(page);

    expect(await page.evaluate(() => (window as any).__offScreenMissing)).toBe(0);
  });
});
