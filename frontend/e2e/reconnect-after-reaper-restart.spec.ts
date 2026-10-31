/**
 * Reconnect After a REAPER Restart E2E Tests
 *
 * Each REAPER start makes a new session token and injects it into the
 * index.html it serves; a hello with any other token is refused. A page left
 * open across a restart still carries the old run's token, so it has to get
 * the new one to reconnect.
 *
 * The extension is faked here: `page.route` serves '/' with the current
 * run's token injected the way the extension does, and `page.routeWebSocket`
 * answers '/ws' the way its WsHandler does.
 */

import { test, expect, Page, WebSocketRoute } from '@playwright/test';

/** How the server's refusal of a stale hello reaches the browser. */
type Refusal = 'close 4001' | 'connection reset';

class FakeReaper {
  token = 'run1-token';
  running = true;
  /** Tokens the page sent in its hellos, in order. */
  hellos: (string | undefined)[] = [];
  /** Hellos refused for a stale token. */
  refused = 0;
  /** Fetches of '/' still answered with the previous run's token. */
  private staleFetches = 0;
  private previousToken = '';
  private sockets = new Set<WebSocketRoute>();

  constructor(private refusal: Refusal) {}

  async install(page: Page): Promise<void> {
    await page.route((url) => url.pathname === '/', async (route) => {
      if (!this.running) {
        await route.abort('connectionrefused');
        return;
      }
      let token = this.token;
      if (this.staleFetches > 0) {
        this.staleFetches--;
        token = this.previousToken;
      }
      const response = await route.fetch();
      const html = await response.text();
      await route.fulfill({
        response,
        body: html.replace('</head>', `<meta name="reamo-token" content="${token}">\n</head>`),
      });
    });

    await page.routeWebSocket((url) => url.pathname === '/ws', (ws) => {
      if (!this.running) {
        ws.close({ code: 1011, reason: '' });
        return;
      }
      this.sockets.add(ws);
      ws.onClose(() => this.sockets.delete(ws));
      ws.onMessage((data) => {
        const msg = JSON.parse(String(data));
        if (msg.type === 'hello') {
          this.hellos.push(msg.token);
          if (msg.token !== this.token) {
            this.refused++;
            if (this.refusal === 'close 4001') {
              ws.send(JSON.stringify({ type: 'error', error: { code: 'INVALID_TOKEN', message: 'Invalid or missing authentication token' } }));
              ws.close({ code: 4001, reason: 'Invalid token' });
            } else {
              // The error and the close frame are lost: the server closed
              // with the client's data unread, so the peer got a reset.
              ws.close({ code: 1011, reason: '' });
            }
            return;
          }
          ws.send(JSON.stringify({ type: 'hello', extensionVersion: '0.8.2', protocolVersion: 1, htmlMtime: 1761900000 }));
        } else if (msg.type === 'ping') {
          ws.send(JSON.stringify({ type: 'pong', timestamp: msg.timestamp }));
        }
      });
    });
  }

  /** REAPER quits: every open socket drops and nothing answers. */
  quit(): void {
    this.running = false;
    for (const ws of this.sockets) ws.close({ code: 1001, reason: '' });
    this.sockets.clear();
  }

  /**
   * REAPER starts again, with a new session token. The restart lands between
   * the page's next fetch of '/' and its connect: that fetch still gets the
   * old run's token, so the hello after it is refused.
   */
  start(): void {
    this.previousToken = this.token;
    this.token = 'run2-token';
    this.staleFetches = 1;
    this.running = true;
  }
}

async function connectionStatus(page: Page): Promise<string> {
  return page.evaluate(() => (window as any).__REAPER_STORE__?.getState().connectionStatus);
}

for (const refusal of ['close 4001', 'connection reset'] as Refusal[]) {
  test(`a page open across a REAPER restart reconnects by itself, without a reload (${refusal})`, async ({ page }) => {
    const reaper = new FakeReaper(refusal);
    await reaper.install(page);

    await page.goto('/');
    await expect.poll(() => connectionStatus(page)).toBe('connected');
    expect(reaper.hellos).toEqual(['run1-token']);

    // Marks this page load; a reload would lose it.
    await page.evaluate(() => { (window as any).__pageLoadMarker = true; });

    reaper.quit();
    await expect.poll(() => connectionStatus(page)).not.toBe('connected');
    // Down long enough for at least one retry to fail.
    await page.waitForTimeout(2500);
    reaper.start();

    await expect.poll(() => connectionStatus(page), { timeout: 20000 }).toBe('connected');
    // The first connect, the stale hello the restarted REAPER refused, then
    // the fresh token from the next fetch of '/'. While REAPER was down no
    // hello got through.
    expect(reaper.hellos).toEqual(['run1-token', 'run1-token', 'run2-token']);
    expect(reaper.refused).toBe(1);
    expect(await page.evaluate(() => (window as any).__pageLoadMarker)).toBe(true);
    await expect(page.getByText('Having trouble connecting to REAPER.')).not.toBeVisible();
  });
}
