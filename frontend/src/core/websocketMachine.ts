/**
 * WebSocket State Machine
 *
 * XState v5 state machine for managing WebSocket connection lifecycle.
 * Handles Safari/iOS edge cases including zombie connections, suspended tabs,
 * and the CONNECTING state timeout.
 *
 * State flow:
 *   idle → discovering → connecting → handshaking → connected
 *                                         ↓ (on visibility return)
 *                                     verifying
 *                                         ↓ (on error/timeout)
 *                                     retrying → waiting → gave_up
 *                                                  ↓ (after delay)
 *                                              connecting
 *
 * Optional: Stately.ai visualization can be used for debugging Safari issues.
 * Visit https://stately.ai/viz and paste this machine for interactive debugging.
 */

import { setup, assign, fromCallback, fromPromise, type AnyActorRef } from 'xstate';
import type { ServerMessage } from './WebSocketTypes';

// =============================================================================
// Types
// =============================================================================

export type ConnectionStatus =
  | 'idle'
  | 'discovering'
  | 'connecting'
  | 'handshaking'
  | 'connected'
  | 'verifying'
  | 'retrying'
  | 'waiting'
  | 'gave_up';

export interface WebSocketContext {
  // Connection params
  port: number;
  token: string | null;
  discoveredPort: number | null;
  discoveredToken: string | null;

  // Retry tracking
  retryCount: number;
  maxRetries: number;
  lastError: string | null;

  // HTML mtime for stale content detection
  htmlMtime: number | null;

  // Extension version (after hello)
  extensionVersion: string | null;

  // Socket reference (managed by actor)
  socketRef: AnyActorRef | null;
}

export type WebSocketEvent =
  | { type: 'START' }
  | { type: 'STOP' }
  | { type: 'MANUAL_RETRY' }
  | { type: 'VISIBILITY_RETURN' }
  | { type: 'VISIBILITY_HIDDEN' }
  // Discovery events
  | { type: 'DISCOVERY_SUCCESS'; port: number | null; token: string | null }
  | { type: 'DISCOVERY_ERROR'; error: string }
  // Socket events
  | { type: 'SOCKET_OPEN' }
  | { type: 'SOCKET_CLOSE'; code: number; reason: string }
  | { type: 'SOCKET_ERROR'; error: string }
  // Protocol events
  | { type: 'HELLO_RECEIVED'; extensionVersion: string; htmlMtime?: number }
  | { type: 'PONG_RECEIVED' }
  | { type: 'MESSAGE_RECEIVED'; message: ServerMessage };

// =============================================================================
// Constants
// =============================================================================

const DEFAULT_PORT = 9224;
const DEFAULT_MAX_RETRIES = 10;

// Timeouts (in ms)
const DISCOVERY_TIMEOUT = 2000;    // EXTSTATE fetch timeout (iOS PWA cold start)
const CONNECT_TIMEOUT = 5000;      // Safari: detect stuck CONNECTING state (must match old code)
const HELLO_TIMEOUT = 5000;        // Wait for hello response
const PONG_TIMEOUT = 3000;         // Per API.md: pong must arrive within 3s
const HEARTBEAT_INTERVAL = 10000;  // Per API.md: ping every 10s when visible
const VERIFY_TIMEOUT = 5000;       // Ping/pong on visibility return

// Retry delays
const INITIAL_RETRY_DELAY = 1000;
const MAX_RETRY_DELAY = 30000;

// =============================================================================
// Safari iOS Workaround
// =============================================================================

/**
 * iOS Safari workaround: Create hidden iframe that attempts WebSocket first.
 * Safari's NSURLSession has lazy WebSocket initialization - the iframe's connection
 * attempt warms the shared network context, allowing the main connection to succeed.
 * Returns a Promise that resolves when warmup completes (success, error, or timeout).
 */
function warmupViaIframe(wsUrl: string): Promise<void> {
  return new Promise((resolve) => {
    try {
      const iframe = document.createElement('iframe');
      iframe.style.display = 'none';
      iframe.srcdoc = `
        <script>
          try {
            const ws = new WebSocket('${wsUrl}');
            ws.onopen = () => { ws.close(); parent.postMessage('warmup-done', '*'); };
            ws.onerror = () => { parent.postMessage('warmup-done', '*'); };
            setTimeout(() => { parent.postMessage('warmup-done', '*'); }, 2000);
          } catch (e) {
            parent.postMessage('warmup-done', '*');
          }
        </script>
      `;

      const cleanup = () => {
        window.removeEventListener('message', handler);
        if (document.body.contains(iframe)) {
          document.body.removeChild(iframe);
        }
      };

      const handler = (e: MessageEvent) => {
        if (e.data === 'warmup-done') {
          cleanup();
          resolve();
        }
      };

      window.addEventListener('message', handler);
      document.body.appendChild(iframe);

      // Fallback timeout (longer than iframe's internal timeout)
      setTimeout(() => {
        cleanup();
        resolve();
      }, 3000);
    } catch {
      resolve();
    }
  });
}

// =============================================================================
// Actors (async operations)
// =============================================================================

/**
 * Discovery actor - fetches port and token from EXTSTATE
 * Also handles Safari PWA workarounds for WebSocket initialization
 */
const discoveryActor = fromPromise<
  { port: number | null; token: string | null },
  { timeout: number }
>(async ({ input }) => {
  // Detect Safari and PWA mode
  const isSafari = navigator.userAgent.includes('Safari') && !navigator.userAgent.includes('Chrome');
  const isPWA = window.matchMedia('(display-mode: standalone)').matches;
  const isIOS = /iPad|iPhone|iPod/.test(navigator.userAgent);

  // Safari PWA cold start workarounds (ALWAYS run regardless of serving mode)
  if (isSafari && isPWA) {
    // Focus cycle to initialize WebSocket stack
    // Safari PWA's network stack may not be ready immediately after launch
    window.blur();
    await new Promise(r => setTimeout(r, 50));
    window.focus();
    await new Promise(r => setTimeout(r, 50));
  }

  // Same-origin detection: if served from extension HTTP server,
  // the token is in a <meta> tag and port is our origin.
  // Skip EXTSTATE fetch (would 404 on extension server) but keep Safari workarounds.
  const metaEl = document.querySelector('meta[name="reamo-token"]');
  if (metaEl) {
    const token = metaEl.getAttribute('content');
    const port = parseInt(window.location.port, 10) || null;
    console.log(`[WS] Same-origin mode: port=${port}`);

    // iOS Safari: iframe warmup even in same-origin mode
    // HTTP loading doesn't guarantee WebSocket stack is ready
    if (isIOS && isSafari) {
      const wsPort = port ?? DEFAULT_PORT;
      const host = window.location.hostname || 'localhost';
      await warmupViaIframe(`ws://${host}:${wsPort}/ws`);
    }

    return { port, token };
  }

  // Legacy mode: served from REAPER's built-in HTTP server.
  // Discover port and token from EXTSTATE API.

  const fetchExtState = async (section: string, key: string): Promise<string | null> => {
    try {
      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), input.timeout);

      const response = await fetch(`/_/GET/EXTSTATE/${section}/${key}`, {
        signal: controller.signal,
      });
      clearTimeout(timeoutId);

      const text = await response.text();
      const parts = text.trim().split('\t');
      if (parts.length >= 4 && parts[0] === 'EXTSTATE') {
        return parts[3] || null;
      }
      return null;
    } catch {
      return null;
    }
  };

  // Parallel fetch for port and token
  const [portStr, token] = await Promise.all([
    fetchExtState('Reamo', 'WebSocketPort'),
    fetchExtState('Reamo', 'SessionToken'),
  ]);

  const port = portStr ? parseInt(portStr, 10) : null;

  // iOS Safari: Await iframe warmup to ensure network stack is ready
  if (isIOS && isSafari) {
    const wsPort = port ?? DEFAULT_PORT;
    const host = window.location.hostname || 'localhost';
    await warmupViaIframe(`ws://${host}:${wsPort}/ws`);
  }

  return { port, token };
});

/**
 * Helper to send events to the machine via global event sender
 * CRITICAL: This bypasses the XState actor lifecycle issue where sendBack becomes invalid
 * after state transitions (connecting → handshaking). The global event sender is set up
 * by websocketActor.ts and always routes to the live actor.
 */
function sendEvent(event: WebSocketEvent): void {
  const sender = (window as unknown as { __wsEventSender?: (event: WebSocketEvent) => void }).__wsEventSender;
  if (sender) {
    sender(event);
  }
}

/**
 * WebSocket connection actor
 * Uses fromCallback for bidirectional communication with cleanup
 *
 * IMPORTANT: Socket handlers use sendEvent() (global sender) instead of sendBack
 * because sendBack becomes invalid when the actor is stopped during state transitions.
 */
const websocketActor = fromCallback<
  WebSocketEvent,
  {
    port: number;
    token: string | null;
  }
>(({ input }) => {
  const host = window.location.hostname || 'localhost';
  const url = `ws://${host}:${input.port}/ws`;

  let socket: WebSocket;

  try {
    socket = new WebSocket(url);
  } catch {
    sendEvent({ type: 'SOCKET_ERROR', error: 'Failed to create WebSocket' });
    return () => {};
  }

  socket.onopen = () => {
    // Send hello message
    const hello = {
      type: 'hello',
      clientVersion: '1.0.0',
      protocolVersion: 1,
      token: input.token ?? undefined,
    };
    socket.send(JSON.stringify(hello));
    sendEvent({ type: 'SOCKET_OPEN' });
  };

  socket.onmessage = (event) => {
    try {
      const msg = JSON.parse(event.data);

      // Handle hello response
      if (msg.type === 'hello') {
        sendEvent({
          type: 'HELLO_RECEIVED',
          extensionVersion: msg.extensionVersion,
          htmlMtime: msg.htmlMtime,
        });
        return;
      }

      // Handle pong response
      if (msg.type === 'pong') {
        sendEvent({ type: 'PONG_RECEIVED' });
        return;
      }

      // Forward to global message handler (set by websocketActor.ts)
      const handler = (window as unknown as { __wsMessageHandler?: (msg: ServerMessage) => void }).__wsMessageHandler;
      if (handler) {
        handler(msg as ServerMessage);
      }

      // Also send to machine for potential state handling
      sendEvent({ type: 'MESSAGE_RECEIVED', message: msg as ServerMessage });
    } catch {
      // Ignore invalid JSON
    }
  };

  socket.onerror = () => {
    sendEvent({ type: 'SOCKET_ERROR', error: 'WebSocket error' });
  };

  socket.onclose = (event) => {
    sendEvent({ type: 'SOCKET_CLOSE', code: event.code, reason: event.reason || '' });
  };

  // Expose socket for sending
  (window as unknown as { __wsSocket?: WebSocket }).__wsSocket = socket;

  // Cleanup: Don't close socket here - it persists across state transitions.
  // Socket closing is handled explicitly by the closeSocket action.
  return () => {};
});

/**
 * Close the WebSocket properly (old code pattern)
 * CRITICAL: Null handlers BEFORE any close operations to prevent zombie events
 */
function closeSocketProperly(): void {
  const socket = (window as unknown as { __wsSocket?: WebSocket }).__wsSocket;
  if (socket) {
    // Null handlers first to prevent zombie events
    socket.onopen = null;
    socket.onclose = null;
    socket.onerror = null;
    socket.onmessage = null;
    // Then close
    try {
      socket.close();
    } catch {
      // Ignore - frozen socket
    }
    delete (window as unknown as { __wsSocket?: WebSocket }).__wsSocket;
  }
}

/**
 * Heartbeat actor - sends ping every HEARTBEAT_INTERVAL with per-ping timeout
 *
 * CRITICAL FIX for Safari: The old code set timeout ONLY when ping is sent,
 * and cleared it when pong received. The XState state-level `after` timer
 * doesn't work because it runs continuously (3s) while pings are every 10s.
 *
 * This actor now manages the timeout internally:
 * - Start 3s timeout when ping sent
 * - Clear timeout when pong received
 * - Send HEARTBEAT_TIMEOUT if no pong within 3s
 */
const heartbeatActor = fromCallback<WebSocketEvent, void>(() => {
  let pongTimeoutId: ReturnType<typeof setTimeout> | null = null;
  let pingIntervalId: ReturnType<typeof setInterval> | null = null;

  const clearPongTimeout = () => {
    if (pongTimeoutId !== null) {
      clearTimeout(pongTimeoutId);
      pongTimeoutId = null;
    }
  };

  const sendPing = () => {
    const socket = (window as unknown as { __wsSocket?: WebSocket }).__wsSocket;
    if (socket && socket.readyState === WebSocket.OPEN) {
      // Clear any existing timeout (shouldn't happen, but defensive)
      clearPongTimeout();

      // Start timeout BEFORE sending ping
      pongTimeoutId = setTimeout(() => {
        sendEvent({ type: 'SOCKET_ERROR', error: 'Heartbeat timeout' });
      }, PONG_TIMEOUT);

      socket.send(JSON.stringify({ type: 'ping', timestamp: Date.now() }));
    }
  };

  // Handle pong received - clear the timeout
  // We intercept socket.onmessage to detect pong and clear the timeout.
  // The original handler (set by websocketActor) continues to process the message.
  const socket = (window as unknown as { __wsSocket?: WebSocket }).__wsSocket;
  const originalOnMessage = socket?.onmessage;

  if (socket) {
    socket.onmessage = (event: MessageEvent) => {
      // Check for pong and clear timeout
      try {
        const msg = JSON.parse(event.data);
        if (msg.type === 'pong') {
          clearPongTimeout();
        }
      } catch {
        // Not JSON, ignore
      }
      // Call original handler (processes all messages including pong)
      if (originalOnMessage) {
        originalOnMessage.call(socket, event);
      }
    };
  }

  // Send initial ping
  sendPing();

  // Set up interval for subsequent pings
  pingIntervalId = setInterval(sendPing, HEARTBEAT_INTERVAL);

  return () => {
    clearPongTimeout();
    if (pingIntervalId !== null) {
      clearInterval(pingIntervalId);
    }
    // Restore original message handler
    if (socket && originalOnMessage) {
      socket.onmessage = originalOnMessage;
    }
  };
});

// =============================================================================
// Guards
// =============================================================================

const canRetry = ({ context }: { context: WebSocketContext }) =>
  context.retryCount < context.maxRetries;

const htmlMtimeChanged = (
  { context }: { context: WebSocketContext },
  params: { htmlMtime?: number }
) => {
  if (params.htmlMtime === undefined) return false;
  if (context.htmlMtime === null) return false;
  return context.htmlMtime !== params.htmlMtime;
};

// =============================================================================
// Delays
// =============================================================================

const reconnectDelay = ({ context }: { context: WebSocketContext }) => {
  const base = INITIAL_RETRY_DELAY;
  const max = MAX_RETRY_DELAY;
  const multiplier = 1.5;
  const jitter = Math.random() * 500;
  return Math.min(base * Math.pow(multiplier, context.retryCount - 1), max) + jitter;
};

// =============================================================================
// Machine Definition
// =============================================================================

export const websocketMachine = setup({
  types: {
    context: {} as WebSocketContext,
    events: {} as WebSocketEvent,
  },
  actors: {
    discovery: discoveryActor,
    websocket: websocketActor,
    heartbeat: heartbeatActor,
  },
  guards: {
    canRetry,
    htmlMtimeChanged: ({ context, event }) => {
      if (event.type !== 'HELLO_RECEIVED') return false;
      return htmlMtimeChanged({ context }, { htmlMtime: event.htmlMtime });
    },
  },
  delays: {
    CONNECT_TIMEOUT,
    HELLO_TIMEOUT,
    PONG_TIMEOUT,
    VERIFY_TIMEOUT,
    reconnectDelay,
  },
  actions: {
    logTransition: () => {
      // State transitions logged for debugging when needed
    },
    storeDiscoveryResults: assign({
      discoveredPort: (_, params: { port: number | null; token: string | null }) => params.port,
      discoveredToken: (_, params: { port: number | null; token: string | null }) => params.token,
    }),
    storeHelloData: assign({
      extensionVersion: (_, params: { extensionVersion: string; htmlMtime?: number }) => params.extensionVersion,
      htmlMtime: ({ context }, params: { extensionVersion: string; htmlMtime?: number }) =>
        params.htmlMtime ?? context.htmlMtime,
    }),
    incrementRetryCount: assign({
      retryCount: ({ context }) => context.retryCount + 1,
    }),
    resetRetryCount: assign({
      retryCount: 0,
    }),
    setError: assign({
      lastError: (_, params: { error: string }) => params.error,
    }),
    clearError: assign({
      lastError: null,
    }),
    reloadPage: () => {
      window.location.reload();
    },
    closeSocket: () => {
      closeSocketProperly();
    },
  },
}).createMachine({
  id: 'websocket',
  initial: 'idle',
  context: {
    port: DEFAULT_PORT,
    token: null,
    discoveredPort: null,
    discoveredToken: null,
    retryCount: 0,
    maxRetries: DEFAULT_MAX_RETRIES,
    lastError: null,
    htmlMtime: null,
    extensionVersion: null,
    socketRef: null,
  },

  // Global event handlers
  on: {
    STOP: {
      target: '.idle',
      actions: [
        { type: 'logTransition', params: { from: '*', to: 'idle' } },
        { type: 'closeSocket' },  // Close socket when stopping
        { type: 'resetRetryCount' },
        { type: 'clearError' },
      ],
    },
  },

  states: {
    idle: {
      on: {
        START: {
          target: 'discovering',
          actions: [
            { type: 'logTransition', params: { from: 'idle', to: 'discovering' } },
            { type: 'resetRetryCount' },
            { type: 'clearError' },
          ],
        },
      },
    },

    discovering: {
      invoke: {
        src: 'discovery',
        input: { timeout: DISCOVERY_TIMEOUT },
        onDone: {
          target: 'connecting',
          actions: [
            { type: 'logTransition', params: { from: 'discovering', to: 'connecting' } },
            {
              type: 'storeDiscoveryResults',
              params: ({ event }: { event: { output: { port: number | null; token: string | null } } }) => ({
                port: event.output.port,
                token: event.output.token,
              }),
            },
          ],
        },
        onError: {
          target: 'connecting',
          actions: [
            { type: 'logTransition', params: { from: 'discovering', to: 'connecting (no discovery)' } },
          ],
        },
      },
    },

    connecting: {
      invoke: {
        src: 'websocket',
        input: ({ context }) => ({
          port: context.discoveredPort ?? context.port,
          token: context.discoveredToken ?? context.token,
        }),
      },
      after: {
        CONNECT_TIMEOUT: {
          target: 'retrying',
          actions: [
            { type: 'logTransition', params: { from: 'connecting', to: 'retrying (timeout)' } },
            { type: 'closeSocket' },
            { type: 'setError', params: { error: 'Connection timeout' } },
          ],
        },
      },
      on: {
        SOCKET_OPEN: {
          target: 'handshaking',
          actions: [
            { type: 'logTransition', params: { from: 'connecting', to: 'handshaking' } },
          ],
        },
        SOCKET_ERROR: {
          target: 'retrying',
          actions: [
            { type: 'logTransition', params: { from: 'connecting', to: 'retrying (error)' } },
            { type: 'closeSocket' },
            { type: 'setError', params: ({ event }) => ({ error: event.error }) },
          ],
        },
        SOCKET_CLOSE: {
          target: 'retrying',
          actions: [
            { type: 'logTransition', params: { from: 'connecting', to: 'retrying (closed)' } },
            { type: 'closeSocket' },
            { type: 'setError', params: ({ event }) => ({ error: event.reason || `Closed (${event.code})` }) },
          ],
        },
      },
    },

    handshaking: {
      // Socket actor still running from connecting state
      after: {
        HELLO_TIMEOUT: {
          target: 'retrying',
          actions: [
            { type: 'logTransition', params: { from: 'handshaking', to: 'retrying (hello timeout)' } },
            { type: 'closeSocket' },
            { type: 'setError', params: { error: 'Hello timeout' } },
          ],
        },
      },
      on: {
        HELLO_RECEIVED: [
          {
            guard: 'htmlMtimeChanged',
            actions: ['reloadPage'],
          },
          {
            target: 'connected',
            actions: [
              { type: 'logTransition', params: { from: 'handshaking', to: 'connected' } },
              {
                type: 'storeHelloData',
                params: ({ event }: { event: { extensionVersion: string; htmlMtime?: number } }) => ({
                  extensionVersion: event.extensionVersion,
                  htmlMtime: event.htmlMtime,
                }),
              },
              { type: 'resetRetryCount' },
              { type: 'clearError' },
            ],
          },
        ],
        SOCKET_CLOSE: {
          target: 'retrying',
          actions: [
            { type: 'logTransition', params: { from: 'handshaking', to: 'retrying (closed)' } },
            { type: 'closeSocket' },
            { type: 'setError', params: ({ event }) => ({ error: event.reason || `Closed (${event.code})` }) },
          ],
        },
        SOCKET_ERROR: {
          target: 'retrying',
          actions: [
            { type: 'logTransition', params: { from: 'handshaking', to: 'retrying (error)' } },
            { type: 'closeSocket' },
            { type: 'setError', params: ({ event }) => ({ error: event.error }) },
          ],
        },
      },
    },

    connected: {
      initial: 'active',
      // Common handlers for both substates
      on: {
        SOCKET_CLOSE: {
          target: 'retrying',
          actions: [
            { type: 'logTransition', params: { from: 'connected', to: 'retrying (closed)' } },
            { type: 'closeSocket' },
            { type: 'setError', params: ({ event }) => ({ error: event.reason || `Closed (${event.code})` }) },
          ],
        },
        SOCKET_ERROR: {
          target: 'retrying',
          actions: [
            { type: 'logTransition', params: { from: 'connected', to: 'retrying (error)' } },
            { type: 'closeSocket' },
            { type: 'setError', params: ({ event }) => ({ error: event.error }) },
          ],
        },
      },
      states: {
        // Active: heartbeat running, page visible
        // Note: PONG_TIMEOUT is handled internally by heartbeatActor (sends SOCKET_ERROR on timeout)
        // This fixes Safari bug where state-level timer fired between pings
        active: {
          invoke: {
            src: 'heartbeat',
          },
          on: {
            // PONG_RECEIVED no longer needs reenter - heartbeat actor clears its own timeout
            PONG_RECEIVED: {},
            VISIBILITY_HIDDEN: {
              target: 'paused',
              actions: [
                { type: 'logTransition', params: { from: 'connected.active', to: 'connected.paused' } },
              ],
            },
            VISIBILITY_RETURN: {
              target: '#websocket.verifying',
              actions: [
                { type: 'logTransition', params: { from: 'connected.active', to: 'verifying' } },
              ],
            },
          },
        },
        // Paused: no heartbeat, page hidden (Safari may kill connection)
        paused: {
          on: {
            VISIBILITY_RETURN: {
              target: '#websocket.verifying',
              actions: [
                { type: 'logTransition', params: { from: 'connected.paused', to: 'verifying' } },
              ],
            },
          },
        },
      },
    },

    verifying: {
      // Entered on visibility return - send ping and wait for pong
      entry: () => {
        const socket = (window as unknown as { __wsSocket?: WebSocket }).__wsSocket;
        if (socket && socket.readyState === WebSocket.OPEN) {
          socket.send(JSON.stringify({ type: 'ping', timestamp: Date.now() }));
        }
      },
      after: {
        VERIFY_TIMEOUT: {
          target: 'retrying',
          actions: [
            { type: 'logTransition', params: { from: 'verifying', to: 'retrying (verify timeout)' } },
            { type: 'closeSocket' },
            { type: 'setError', params: { error: 'Verify timeout - zombie connection' } },
          ],
        },
      },
      on: {
        PONG_RECEIVED: {
          target: 'connected',
          actions: [
            { type: 'logTransition', params: { from: 'verifying', to: 'connected' } },
          ],
        },
        SOCKET_CLOSE: {
          target: 'retrying',
          actions: [
            { type: 'logTransition', params: { from: 'verifying', to: 'retrying (closed)' } },
            { type: 'closeSocket' },
            { type: 'setError', params: ({ event }) => ({ error: event.reason || `Closed (${event.code})` }) },
          ],
        },
        SOCKET_ERROR: {
          target: 'retrying',
          actions: [
            { type: 'logTransition', params: { from: 'verifying', to: 'retrying (error)' } },
            { type: 'closeSocket' },
            { type: 'setError', params: ({ event }) => ({ error: event.error }) },
          ],
        },
      },
    },

    retrying: {
      always: [
        {
          guard: 'canRetry',
          target: 'waiting',
          actions: [
            { type: 'incrementRetryCount' },
          ],
        },
        {
          target: 'gave_up',
          actions: [
            { type: 'logTransition', params: { from: 'retrying', to: 'gave_up' } },
          ],
        },
      ],
    },

    waiting: {
      after: {
        reconnectDelay: {
          target: 'discovering',
          actions: [
            { type: 'logTransition', params: { from: 'waiting', to: 'discovering' } },
          ],
        },
      },
      on: {
        MANUAL_RETRY: {
          target: 'discovering',
          actions: [
            { type: 'logTransition', params: { from: 'waiting', to: 'discovering (manual)' } },
          ],
        },
      },
    },

    gave_up: {
      on: {
        MANUAL_RETRY: {
          target: 'discovering',
          actions: [
            { type: 'logTransition', params: { from: 'gave_up', to: 'discovering (manual)' } },
            { type: 'resetRetryCount' },
          ],
        },
      },
    },
  },
});

// =============================================================================
// Helper to get status from state value
// =============================================================================

export function getConnectionStatus(stateValue: string | Record<string, unknown>): ConnectionStatus {
  // XState v5 represents compound states as objects: {connected: "active"}
  // Simple states are strings: "idle", "discovering", etc.
  let mainState: string;

  if (typeof stateValue === 'string') {
    // Simple state or dot-notation (shouldn't happen in v5 but handle it)
    mainState = stateValue.split('.')[0];
  } else if (typeof stateValue === 'object' && stateValue !== null) {
    // Compound state object - get the first key
    mainState = Object.keys(stateValue)[0];
  } else {
    mainState = 'idle';
  }

  switch (mainState) {
    case 'idle':
    case 'discovering':
    case 'connecting':
    case 'handshaking':
    case 'connected':
    case 'verifying':
    case 'retrying':
    case 'waiting':
    case 'gave_up':
      return mainState as ConnectionStatus;
    default:
      return 'idle';
  }
}
