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
 * iOS Safari workaround: Open a throwaway WebSocket to prime Safari's networking.
 * Safari's NSURLSession has lazy WebSocket initialization — the first connection
 * attempt in a new page context often fails. This warmup connection triggers the
 * internal initialization so subsequent connections succeed.
 *
 * Previously used a srcdoc iframe, but srcdoc origins are "null" which the server's
 * Origin validation rejects (403). A direct warmup from the main page uses the
 * correct same-origin header.
 */
function warmupWebSocket(wsUrl: string): Promise<void> {
  return new Promise((resolve) => {
    try {
      const ws = new WebSocket(wsUrl);
      const timer = setTimeout(() => {
        try { ws.close(); } catch { /* ignore */ }
        resolve();
      }, 3000);

      ws.onopen = () => {
        clearTimeout(timer);
        try { ws.close(); } catch { /* ignore */ }
        resolve();
      };
      ws.onerror = () => {
        clearTimeout(timer);
        resolve();
      };
    } catch {
      resolve();
    }
  });
}

// =============================================================================
// Actors (async operations)
// =============================================================================

/**
 * Discovery actor - reads port and token from same-origin <meta> tag
 * Also handles Safari PWA workarounds for WebSocket initialization
 */
const discoveryActor = fromPromise<
  { port: number | null; token: string | null },
  void
>(async () => {
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

  // Read token from <meta> tag injected by extension HTTP server
  const metaEl = document.querySelector('meta[name="reamo-token"]');
  const token = metaEl?.getAttribute('content') ?? null;
  const port = parseInt(window.location.port, 10) || null;
  console.log(`[WS] Same-origin mode: port=${port}`);

  // Safari network warmup: fetch a lightweight HTTP endpoint before WebSocket.
  // Safari's network stack is lazy — the page's initial HTTP load isn't always
  // enough to prepare WebSocket connections. Previously the EXTSTATE fetches
  // provided this warmup accidentally. Without it, WebSocket attempts fail
  // on first try and require retries.
  if (isSafari) {
    try {
      await fetch('/api/ping');
      console.log('[WS] Safari: ping warmup complete');
    } catch {
      console.log('[WS] Safari: ping warmup failed (server may not be ready)');
    }
  }

  // iOS Safari: iframe warmup to ensure WebSocket stack is ready.
  // This is a separate issue from the HTTP warmup above — Safari's NSURLSession
  // has lazy WebSocket initialization that the iframe's connection primes.
  if (isIOS && isSafari) {
    const wsPort = port ?? DEFAULT_PORT;
    const host = window.location.hostname || 'localhost';
    await warmupWebSocket(`ws://${host}:${wsPort}/ws`);
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
    socket.binaryType = 'arraybuffer'; // Enable binary frame reception (audio streaming)
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
    // Binary frame → audio pipeline (avoid JSON parse overhead)
    if (event.data instanceof ArrayBuffer) {
      const handler = (window as unknown as { __wsBinaryHandler?: (data: ArrayBuffer) => void }).__wsBinaryHandler;
      if (handler) handler(event.data);
      return;
    }

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
