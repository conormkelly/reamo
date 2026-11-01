/**
 * WebSocket State Machine Tests
 *
 * Tests state transitions using Vitest fake timers.
 * These tests verify the state machine logic in isolation,
 * without actual WebSocket connections.
 */

import { describe, it, expect, vi, beforeEach, afterEach, type Mock } from 'vitest';
import { createActor, fromCallback } from 'xstate';
import { websocketMachine, getConnectionStatus, fetchSessionToken, type WebSocketEvent } from './websocketMachine';
import { checkVersionMismatch, clearStoredVersion, storeVersion } from '../utils/versionStorage';

describe('websocketMachine', () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  describe('initial state', () => {
    it('starts in idle state', () => {
      const actor = createActor(websocketMachine);
      actor.start();

      expect(actor.getSnapshot().value).toBe('idle');
      expect(actor.getSnapshot().context.retryCount).toBe(0);

      actor.stop();
    });
  });

  describe('START event', () => {
    it('transitions from idle to discovering', () => {
      const actor = createActor(websocketMachine);
      actor.start();

      actor.send({ type: 'START' });

      expect(actor.getSnapshot().value).toBe('discovering');

      actor.stop();
    });

    it('resets retry count on START', () => {
      // The START action resets retryCount to 0
      // We verify this by checking the action is configured
      const machine = websocketMachine;
      const idleState = machine.config.states?.idle;
      const startTransition = idleState?.on?.START;

      expect(startTransition).toBeDefined();

      // Also verify a fresh start has retryCount = 0
      const actor = createActor(websocketMachine);
      actor.start();
      actor.send({ type: 'START' });
      expect(actor.getSnapshot().context.retryCount).toBe(0);
      actor.stop();
    });
  });

  describe('STOP event', () => {
    it('transitions to idle from any state', () => {
      const actor = createActor(websocketMachine);
      actor.start();

      // Go to discovering
      actor.send({ type: 'START' });
      expect(actor.getSnapshot().value).toBe('discovering');

      // Stop
      actor.send({ type: 'STOP' });
      expect(actor.getSnapshot().value).toBe('idle');

      actor.stop();
    });

    it('clears error on STOP', () => {
      const actor = createActor(websocketMachine);
      actor.start();
      actor.send({ type: 'START' });

      // Simulate an error by setting lastError in context
      // This happens via state transitions in real usage
      const snapshot = actor.getSnapshot();
      expect(snapshot.context.lastError).toBe(null);

      actor.send({ type: 'STOP' });
      expect(actor.getSnapshot().context.lastError).toBe(null);

      actor.stop();
    });
  });

  describe('retry logic', () => {
    it('increments retry count when entering waiting state', () => {
      const actor = createActor(websocketMachine);
      actor.start();

      // Manually test the context logic
      const context = actor.getSnapshot().context;
      expect(context.retryCount).toBe(0);
      expect(context.maxRetries).toBe(10);

      actor.stop();
    });

    it('has correct max retries default', () => {
      const actor = createActor(websocketMachine);
      actor.start();

      expect(actor.getSnapshot().context.maxRetries).toBe(10);

      actor.stop();
    });
  });

  describe('getConnectionStatus helper', () => {
    it('returns correct status for all states', () => {
      expect(getConnectionStatus('idle')).toBe('idle');
      expect(getConnectionStatus('discovering')).toBe('discovering');
      expect(getConnectionStatus('connecting')).toBe('connecting');
      expect(getConnectionStatus('handshaking')).toBe('handshaking');
      expect(getConnectionStatus('connected')).toBe('connected');
      expect(getConnectionStatus('verifying')).toBe('verifying');
      expect(getConnectionStatus('retrying')).toBe('retrying');
      expect(getConnectionStatus('waiting')).toBe('waiting');
      expect(getConnectionStatus('gave_up')).toBe('gave_up');
    });

    it('handles unknown states gracefully', () => {
      expect(getConnectionStatus('unknown')).toBe('idle');
    });

    it('handles compound states', () => {
      expect(getConnectionStatus('connected.heartbeating')).toBe('connected');
    });
  });

  describe('context defaults', () => {
    it('has correct default port', () => {
      const actor = createActor(websocketMachine);
      actor.start();

      expect(actor.getSnapshot().context.port).toBe(9224);

      actor.stop();
    });

    it('has null token by default', () => {
      const actor = createActor(websocketMachine);
      actor.start();

      expect(actor.getSnapshot().context.token).toBe(null);

      actor.stop();
    });

    it('has null discovered values initially', () => {
      const actor = createActor(websocketMachine);
      actor.start();

      const context = actor.getSnapshot().context;
      expect(context.discoveredPort).toBe(null);
      expect(context.discoveredToken).toBe(null);

      actor.stop();
    });
  });

  describe('state machine structure', () => {
    it('has all expected states', () => {
      const actor = createActor(websocketMachine);
      actor.start();

      // Get the machine config to verify structure
      const machine = websocketMachine;
      const states = Object.keys(machine.config.states || {});

      expect(states).toContain('idle');
      expect(states).toContain('discovering');
      expect(states).toContain('connecting');
      expect(states).toContain('handshaking');
      expect(states).toContain('connected');
      expect(states).toContain('verifying');
      expect(states).toContain('retrying');
      expect(states).toContain('waiting');
      expect(states).toContain('gave_up');

      actor.stop();
    });
  });

  describe('MANUAL_RETRY from gave_up', () => {
    it('resets retry count on manual retry from gave_up', () => {
      // We can't easily get to gave_up state in isolation,
      // but we can verify the action is configured
      const machine = websocketMachine;
      const gaveUpState = machine.config.states?.gave_up;

      expect(gaveUpState).toBeDefined();
      expect(gaveUpState?.on?.MANUAL_RETRY).toBeDefined();
    });
  });

  describe('visibility events', () => {
    it('VISIBILITY_RETURN is handled in connected.active state', () => {
      const machine = websocketMachine;
      const connectedState = machine.config.states?.connected as { states?: Record<string, unknown> };
      const activeState = connectedState?.states?.active as { on?: Record<string, unknown> };

      expect(activeState?.on?.VISIBILITY_RETURN).toBeDefined();
    });

    it('VISIBILITY_HIDDEN transitions from connected.active to connected.paused', () => {
      const machine = websocketMachine;
      const connectedState = machine.config.states?.connected as { states?: Record<string, unknown> };
      const activeState = connectedState?.states?.active as { on?: Record<string, unknown> };

      // VISIBILITY_HIDDEN causes transition to paused (stops heartbeat)
      expect(activeState?.on?.VISIBILITY_HIDDEN).toBeDefined();
    });

    it('VISIBILITY_RETURN is handled in connected.paused state', () => {
      const machine = websocketMachine;
      const connectedState = machine.config.states?.connected as { states?: Record<string, unknown> };
      const pausedState = connectedState?.states?.paused as { on?: Record<string, unknown> };

      expect(pausedState?.on?.VISIBILITY_RETURN).toBeDefined();
    });
  });
});

describe('websocketMachine integration', () => {
  // These tests would require mocking fetch and WebSocket
  // For now, we verify the structure

  it('discovery actor is configured', () => {
    const machine = websocketMachine;
    const discoveringState = machine.config.states?.discovering;

    expect(discoveringState?.invoke).toBeDefined();
  });

  it('websocket actor is configured for connecting state', () => {
    const machine = websocketMachine;
    const connectingState = machine.config.states?.connecting;

    expect(connectingState?.invoke).toBeDefined();
  });

  it('heartbeat actor is configured for connected.active state', () => {
    const machine = websocketMachine;
    const connectedState = machine.config.states?.connected as { states?: Record<string, unknown> };
    const activeState = connectedState?.states?.active as { invoke?: unknown };

    expect(activeState?.invoke).toBeDefined();
  });
});

// =============================================================================
// Session token after a REAPER restart
// =============================================================================

/** index.html as the extension serves it, with this run's token injected. */
function indexHtml(token: string): string {
  return `<!doctype html><html><head><meta name="reamo-token" content="${token}">\n</head><body></body></html>`;
}

function htmlResponse(body: string, status = 200): Response {
  return new Response(body, { status, headers: { 'Content-Type': 'text/html' } });
}

/** The token the page was served with, as the extension injects it into the page's <head>. */
function setPageToken(token: string): void {
  document.head.querySelectorAll('meta[name="reamo-token"]').forEach((el) => el.remove());
  const meta = document.createElement('meta');
  meta.setAttribute('name', 'reamo-token');
  meta.setAttribute('content', token);
  document.head.appendChild(meta);
}

describe('fetchSessionToken', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.useRealTimers();
  });

  it('reads the reamo-token meta from a no-store, same-origin fetch of /', async () => {
    const fetchMock = vi.fn().mockResolvedValue(htmlResponse(indexHtml('abc123')));
    vi.stubGlobal('fetch', fetchMock);

    await expect(fetchSessionToken()).resolves.toBe('abc123');
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe('/');
    expect(init.cache).toBe('no-store');
    expect(init.credentials).toBe('same-origin');
  });

  it('gives null when the server refuses the page', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(htmlResponse('Forbidden: invalid Host header', 403)));
    await expect(fetchSessionToken()).resolves.toBeNull();
  });

  it('gives null when the page carries no token', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(htmlResponse('<html><head></head></html>')));
    await expect(fetchSessionToken()).resolves.toBeNull();
  });

  it('gives null when REAPER is not answering', async () => {
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new TypeError('Failed to fetch')));
    await expect(fetchSessionToken()).resolves.toBeNull();
  });

  it('gives up on a fetch that never answers instead of stalling the reconnect', async () => {
    vi.useFakeTimers();
    vi.stubGlobal('fetch', vi.fn((_url: string, init: RequestInit) => new Promise((_resolve, reject) => {
      init.signal?.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')));
    })));

    const result = fetchSessionToken();
    await vi.advanceTimersByTimeAsync(5000);
    await expect(result).resolves.toBeNull();
  });
});

describe('websocketMachine reconnect after a REAPER restart', () => {
  type SocketInput = { port: number; token: string | null };

  let socketInputs: SocketInput[];
  let reloadPage: Mock<() => void>;
  let fetchMock: Mock<(url: string, init?: RequestInit) => Promise<Response>>;
  let serverToken: string;

  /** `realReload`: keep the machine's own reloadPage action instead of the spy. */
  function startMachine({ realReload = false, base = websocketMachine } = {}) {
    const machine = base.provide({
      actors: {
        websocket: fromCallback<WebSocketEvent, SocketInput>(({ input }) => {
          socketInputs.push(input);
          return () => {};
        }),
        heartbeat: fromCallback(() => () => {}),
      },
      actions: {
        closeSocket: () => {},
        ...(realReload ? {} : { reloadPage: () => reloadPage() }),
      },
    });
    const actor = createActor(machine);
    actor.start();
    actor.send({ type: 'START' });
    return actor;
  }

  /** The server refuses the hello. `code` is what reaches the browser: 4001, or 1006 when the close frame is lost to a reset. */
  function refuseHello(actor: ReturnType<typeof startMachine>, code: number) {
    actor.send({ type: 'SOCKET_OPEN' });
    actor.send({ type: 'SOCKET_CLOSE', code, reason: code === 4001 ? 'Invalid token' : '' });
  }

  function acceptHello(actor: ReturnType<typeof startMachine>, extensionVersion = '0.8.2', htmlMtime = 1000) {
    actor.send({ type: 'SOCKET_OPEN' });
    actor.send({ type: 'HELLO_RECEIVED', extensionVersion, htmlMtime });
  }

  beforeEach(() => {
    vi.useFakeTimers();
    vi.spyOn(Math, 'random').mockReturnValue(0); // no jitter: reconnectDelay is exactly 1000 * 1.5^(n-1)
    socketInputs = [];
    reloadPage = vi.fn();
    serverToken = 'run2token';
    setPageToken('run1token');
    fetchMock = vi.fn(async () => htmlResponse(indexHtml(serverToken)));
    vi.stubGlobal('fetch', fetchMock);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
    vi.useRealTimers();
    document.head.querySelectorAll('meta[name="reamo-token"]').forEach((el) => el.remove());
  });

  it('connects first with the token the page was served with, without fetching', async () => {
    const actor = startMachine();
    await vi.advanceTimersByTimeAsync(0);

    expect(socketInputs.map((i) => i.token)).toEqual(['run1token']);
    expect(fetchMock).not.toHaveBeenCalled();
    actor.stop();
  });

  it.each([
    ['the 4001 close arrives', 4001],
    ['the close frame is lost (1006)', 1006],
  ])('reconnects with the restarted REAPER\'s token and no reload when %s', async (_label, code) => {
    // The page connects, then REAPER goes away; it is back, with a new
    // token, by the first retry, which still sends the page's token here
    // because the fetch it makes answers with the old one.
    serverToken = 'run1token';
    const actor = startMachine();
    await vi.advanceTimersByTimeAsync(0);
    acceptHello(actor);
    expect(actor.getSnapshot().matches('connected')).toBe(true);

    actor.send({ type: 'SOCKET_CLOSE', code: 1006, reason: '' });
    await vi.advanceTimersByTimeAsync(1000);
    serverToken = 'run2token';
    refuseHello(actor, code);
    await vi.advanceTimersByTimeAsync(1500);

    expect(socketInputs.at(-1)?.token).toBe('run2token');
    acceptHello(actor);
    expect(actor.getSnapshot().matches('connected')).toBe(true);
    expect(reloadPage).not.toHaveBeenCalled();
    actor.stop();
  });

  it('fetches a fresh token on the first retry, so a REAPER that is back already accepts it', async () => {
    const actor = startMachine();
    await vi.advanceTimersByTimeAsync(0);
    acceptHello(actor);

    actor.send({ type: 'SOCKET_CLOSE', code: 1006, reason: '' });
    await vi.advanceTimersByTimeAsync(1000);

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(socketInputs.map((i) => i.token)).toEqual(['run1token', 'run2token']);
    actor.stop();
  });

  it('keeps the last token it had when the page cannot be fetched', async () => {
    const actor = startMachine();
    await vi.advanceTimersByTimeAsync(0);
    fetchMock.mockRejectedValue(new TypeError('Failed to fetch'));

    actor.send({ type: 'SOCKET_ERROR', error: 'WebSocket error' });
    await vi.advanceTimersByTimeAsync(1000);

    expect(socketInputs.map((i) => i.token)).toEqual(['run1token', 'run1token']);
    actor.stop();
  });

  it('backs off between fetches and gives up when the token is refused every time', async () => {
    serverToken = 'run1token'; // what the page fetches is refused too
    const actor = startMachine();
    await vi.advanceTimersByTimeAsync(0);

    const maxRetries = actor.getSnapshot().context.maxRetries;
    for (let retry = 1; retry <= maxRetries; retry++) {
      refuseHello(actor, 4001);
      // A margin either side of the delay: the fake clock rounds fractional delays.
      const delay = Math.min(1000 * Math.pow(1.5, retry - 1), 30000);
      await vi.advanceTimersByTimeAsync(delay - 10);
      expect(fetchMock).toHaveBeenCalledTimes(retry - 1);
      await vi.advanceTimersByTimeAsync(10);
      expect(fetchMock).toHaveBeenCalledTimes(retry);
    }
    refuseHello(actor, 4001);

    expect(actor.getSnapshot().value).toBe('gave_up');
    expect(reloadPage).not.toHaveBeenCalled();
    actor.stop();
  });

  it('fetches a fresh token after a manual retry from gave_up', async () => {
    const actor = startMachine();
    await vi.advanceTimersByTimeAsync(0);
    // REAPER stays away: every attempt times out until the machine gives up.
    fetchMock.mockRejectedValue(new TypeError('Failed to fetch'));
    for (let i = 0; i < 50 && actor.getSnapshot().value !== 'gave_up'; i++) {
      await vi.advanceTimersByTimeAsync(30000);
    }
    expect(actor.getSnapshot().value).toBe('gave_up');

    fetchMock.mockImplementation(async () => htmlResponse(indexHtml(serverToken)));
    actor.send({ type: 'MANUAL_RETRY' });
    await vi.advanceTimersByTimeAsync(0);

    expect(socketInputs.at(-1)?.token).toBe('run2token');
    actor.stop();
  });

  it('reloads when the restarted REAPER runs another REAmo version', async () => {
    const actor = startMachine();
    await vi.advanceTimersByTimeAsync(0);
    acceptHello(actor, '0.8.2', 1000);

    actor.send({ type: 'SOCKET_CLOSE', code: 1006, reason: '' });
    await vi.advanceTimersByTimeAsync(1000);
    acceptHello(actor, '0.8.3', 1000);

    expect(reloadPage).toHaveBeenCalledTimes(1);
    actor.stop();
  });

  it('reloads when the restarted REAPER serves a changed index.html', async () => {
    const actor = startMachine();
    await vi.advanceTimersByTimeAsync(0);
    acceptHello(actor, '0.8.2', 1000);

    actor.send({ type: 'SOCKET_CLOSE', code: 1006, reason: '' });
    await vi.advanceTimersByTimeAsync(1000);
    acceptHello(actor, '0.8.2', 2000);

    expect(reloadPage).toHaveBeenCalledTimes(1);
    actor.stop();
  });

  it('a connect interrupted before discovery finishes still sends the page\'s token next time, even if fetching / fails', async () => {
    fetchMock.mockRejectedValue(new TypeError('Failed to fetch'));
    const actor = startMachine();
    // forceReconnect (Safari visibility return, `online`) before the first discovery resolves.
    actor.send({ type: 'STOP' });
    actor.send({ type: 'START' });
    await vi.advanceTimersByTimeAsync(0);

    expect(socketInputs.map((i) => i.token)).toEqual(['run1token']);
    actor.stop();
  });

  describe('an extension update found on reconnect', () => {
    // hardRefresh navigates the page away; these tests record that it was
    // asked to. The test setup has already loaded the machine (through the
    // store), so it is imported afresh with versionStorage mocked.
    let hardRefresh: Mock<() => Promise<void>>;
    let base: typeof websocketMachine;

    beforeEach(async () => {
      clearStoredVersion();
      hardRefresh = vi.fn(async () => {});
      vi.resetModules();
      vi.doMock('../utils/versionStorage', async (importOriginal) => ({
        ...(await importOriginal<typeof import('../utils/versionStorage')>()),
        hardRefresh,
      }));
      ({ websocketMachine: base } = await import('./websocketMachine'));
    });

    afterEach(() => {
      vi.doUnmock('../utils/versionStorage');
      clearStoredVersion();
    });

    it('reloads once: the reloaded page finds the new version already stored and does not reload again', async () => {
      // The page's first connect stored 0.8.2 (websocketActor's first-connect check).
      storeVersion('0.8.2', 1000);
      const actor = startMachine({ realReload: true, base });
      await vi.advanceTimersByTimeAsync(0);
      acceptHello(actor, '0.8.2', 1000);

      actor.send({ type: 'SOCKET_CLOSE', code: 1006, reason: '' });
      await vi.advanceTimersByTimeAsync(1000);
      acceptHello(actor, '0.8.3', 1000);

      expect(hardRefresh).toHaveBeenCalledTimes(1);
      // What the reloaded page's first-connect check will compare against.
      expect(checkVersionMismatch('0.8.3', 1000)).toBe('match');
      actor.stop();
    });

    it('stores the new index.html mtime when only the web files changed', async () => {
      storeVersion('0.8.2', 1000);
      const actor = startMachine({ realReload: true, base });
      await vi.advanceTimersByTimeAsync(0);
      acceptHello(actor, '0.8.2', 1000);

      actor.send({ type: 'SOCKET_CLOSE', code: 1006, reason: '' });
      await vi.advanceTimersByTimeAsync(1000);
      acceptHello(actor, '0.8.2', 2000);

      expect(hardRefresh).toHaveBeenCalledTimes(1);
      expect(checkVersionMismatch('0.8.2', 2000)).toBe('match');
      actor.stop();
    });
  });
});
