/**
 * WebSocket Connection Manager
 * Handles connection, hello handshake, reconnection, and message dispatch
 */

import {
  type ServerMessage,
  type ConnectionState,
  createHello,
  createCommand,
  isHelloResponse,
  isEventMessage,
  isResponseMessage,
  isClockSyncResponse,
} from './WebSocketTypes';

export interface WebSocketConnectionOptions {
  /** WebSocket port (default: 9224, or auto-discover from EXTSTATE) */
  port?: number;
  /** Auth token (optional - will auto-fetch from EXTSTATE if not provided) */
  token?: string;
  /** Called when connection state changes */
  onStateChange?: (state: ConnectionState, error?: string) => void;
  /** Called when a server message is received */
  onMessage?: (message: ServerMessage) => void;
  /** Called when we've exhausted all retry attempts */
  onGaveUp?: () => void;
  /** Max retry attempts before giving up (default: 10) */
  maxRetries?: number;
}

/**
 * Fetch EXTSTATE value from REAPER's HTTP control surface
 * Assumes we're served from the same origin (REAPER's web root)
 *
 * CRITICAL: Has a 2s timeout to prevent hanging on PWA cold start.
 * On iOS PWA, the network stack may not be ready immediately after launch,
 * causing fetch() to hang indefinitely. Without timeout, discoverAndConnect()
 * never completes and the WebSocket connection is never attempted.
 */
async function fetchExtState(section: string, key: string): Promise<string | null> {
  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 2000); // 2s timeout

    const response = await fetch(`/_/GET/EXTSTATE/${section}/${key}`, {
      signal: controller.signal,
    });
    clearTimeout(timeout);

    const text = await response.text();
    const parts = text.trim().split('\t');
    if (parts.length >= 4 && parts[0] === 'EXTSTATE') {
      return parts[3] || null;
    }
    return null;
  } catch {
    // Timeout, network error, or abort - all return null (use defaults)
    return null;
  }
}

// Reconnection settings
const INITIAL_RETRY_DELAY = 1000;
const MAX_RETRY_DELAY = 30000;
const RETRY_MULTIPLIER = 1.5;
const DEFAULT_MAX_RETRIES = 10;

// PWA suspension and heartbeat settings
const HEARTBEAT_INTERVAL_MS = 10000;   // Ping every 10s when visible
const HEARTBEAT_TIMEOUT_MS = 3000;     // Pong must arrive within 3s
const CONNECT_TIMEOUT_MS = 5000;       // Safari: detect stuck CONNECTING state (no events fire after iOS suspension)

export class WebSocketConnection {
  private ws: WebSocket | null = null;
  private options: WebSocketConnectionOptions;
  private state: ConnectionState = 'disconnected';
  private retryDelay = INITIAL_RETRY_DELAY;
  private retryCount = 0;
  private retryTimeout: ReturnType<typeof setTimeout> | null = null;
  private extensionVersion: string | null = null;
  private pendingResponses = new Map<string, (response: unknown) => void>();
  private gaveUp = false;
  // Discovered values (can be refreshed on reconnect)
  private discoveredPort: number | null = null;
  private discoveredToken: string | null = null;
  // HTML mtime for stale content detection on reconnect
  private htmlMtime: number | null = null;
  // PWA suspension and heartbeat tracking
  private heartbeatInterval: ReturnType<typeof setInterval> | null = null;
  private heartbeatTimeout: ReturnType<typeof setTimeout> | null = null;
  // Safari CONNECTING timeout - detects frozen socket after iOS suspension
  private connectTimeout: ReturnType<typeof setTimeout> | null = null;

  constructor(options: WebSocketConnectionOptions = {}) {
    this.options = {
      port: 9224,
      maxRetries: DEFAULT_MAX_RETRIES,
      ...options,
    };
  }

  /** Current connection state */
  get connectionState(): ConnectionState {
    return this.state;
  }

  /** Extension version (after successful hello) */
  get version(): string | null {
    return this.extensionVersion;
  }

  /** Start the connection */
  async start(): Promise<void> {
    if (this.state === 'connecting' || this.state === 'connected') {
      return;
    }

    // Reset retry state on fresh start
    this.retryCount = 0;
    this.retryDelay = INITIAL_RETRY_DELAY;
    this.gaveUp = false;

    // Detect browser and mode
    const isSafari = navigator.userAgent.includes('Safari') && !navigator.userAgent.includes('Chrome');
    const isPWA = window.matchMedia('(display-mode: standalone)').matches;
    console.log(`[WS] start() - Safari: ${isSafari}, PWA: ${isPWA}, readyState: ${document.readyState}`);

    // Gather diagnostic data for Safari PWA debugging
    if (isSafari && isPWA) {
      console.log('[WS] Safari PWA diagnostic data:', {
        onLine: navigator.onLine,
        visibilityState: document.visibilityState,
        hasFocus: document.hasFocus(),
        timeOrigin: performance.timeOrigin,
        timeSinceOrigin: Math.round(performance.now()),
        connection: (navigator as Navigator & { connection?: { type?: string; effectiveType?: string } }).connection?.effectiveType ?? 'unknown',
      });

      // EXPERIMENT: Trigger focus cycle to simulate navigate-back conditions
      // Safari PWA cold start may need a focus event to initialize WebSocket stack
      console.log('[WS] Safari PWA: Triggering focus cycle to initialize WebSocket stack');
      window.blur();
      await new Promise(r => setTimeout(r, 50));
      window.focus();
      await new Promise(r => setTimeout(r, 50));
    }

    await this.discoverAndConnect();
  }

  /** Retry connection after giving up (for manual retry button) */
  async retry(): Promise<void> {
    if (this.state === 'connecting' || this.state === 'connected') {
      return;
    }

    console.log('[WS] Manual retry requested');
    this.retryCount = 0;
    this.retryDelay = INITIAL_RETRY_DELAY;
    this.gaveUp = false;

    await this.discoverAndConnect();
  }

  /** Whether we've given up reconnecting */
  get hasGivenUp(): boolean {
    return this.gaveUp;
  }

  /** Discover connection params and connect */
  private async discoverAndConnect(): Promise<void> {
    // Signal connecting state BEFORE fetches (fixes 2s black screen on iOS PWA cold start)
    this.setState('connecting');

    // Always refresh port and token from EXTSTATE (handles REAPER restart)
    // Run both fetches in parallel to minimize startup time
    console.log('[WS] Discovering connection params from EXTSTATE...');

    const [port, token] = await Promise.all([
      fetchExtState('Reamo', 'WebSocketPort'),
      fetchExtState('Reamo', 'SessionToken'),
    ]);

    if (port) {
      this.discoveredPort = parseInt(port, 10);
      console.log(`[WS] Discovered port: ${this.discoveredPort}`);
    }
    if (token) {
      this.discoveredToken = token;
      console.log('[WS] Discovered session token');
    }

    // iOS Safari: Try iframe pre-connection to warm network stack before real connection
    // Safari's NSURLSession has lazy WebSocket initialization on cold start
    const isIOS = /iPad|iPhone|iPod/.test(navigator.userAgent);
    const isSafari = navigator.userAgent.includes('Safari') && !navigator.userAgent.includes('Chrome');
    if (isIOS && isSafari) {
      const wsPort = this.discoveredPort ?? this.options.port ?? 9224;
      const host = window.location.hostname || 'localhost';
      const wsUrl = `ws://${host}:${wsPort}/`;
      await this.warmupViaIframe(wsUrl);
    }

    this.connect();
  }

  /**
   * iOS Safari workaround: Create hidden iframe that attempts WebSocket first.
   * Safari's NSURLSession has lazy WebSocket initialization - the iframe's connection
   * attempt warms the shared network context, allowing the main connection to succeed.
   */
  private async warmupViaIframe(wsUrl: string): Promise<void> {
    console.log('[WS] iOS Safari: Attempting iframe pre-warmup');

    return new Promise((resolve) => {
      const iframe = document.createElement('iframe');
      iframe.style.display = 'none';
      iframe.srcdoc = `
        <script>
          try {
            const ws = new WebSocket('${wsUrl}');
            ws.onopen = () => {
              console.log('[iframe] WebSocket opened');
              ws.close();
              parent.postMessage('warmup-done', '*');
            };
            ws.onerror = () => {
              console.log('[iframe] WebSocket error');
              parent.postMessage('warmup-done', '*');
            };
            ws.onclose = () => {
              console.log('[iframe] WebSocket closed');
            };
            // Timeout fallback
            setTimeout(() => {
              console.log('[iframe] Timeout - posting done');
              parent.postMessage('warmup-done', '*');
            }, 2000);
          } catch (e) {
            console.log('[iframe] Exception:', e);
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
          console.log('[WS] Iframe warmup completed');
          cleanup();
          resolve();
        }
      };

      window.addEventListener('message', handler);
      document.body.appendChild(iframe);

      // Fallback timeout (longer than iframe's internal timeout)
      setTimeout(() => {
        console.log('[WS] Iframe warmup timeout (fallback)');
        cleanup();
        resolve();
      }, 3000);
    });
  }

  /** Stop the connection */
  stop(): void {
    console.log(`[WS] stop() called at T+${Math.round(performance.now())}ms`);
    this.clearRetryTimeout();
    this.stopHeartbeat();
    if (this.ws) {
      this.ws.onclose = null; // Prevent reconnection
      this.ws.close();
      this.ws = null;
    }
    this.setState('disconnected');
  }

  /**
   * Handle page visibility change - ALWAYS force reconnect on return
   * Safari iOS: WebSocket can become zombie after suspension, readyState lies.
   * Research shows: never trust existing connection after backgrounding.
   */
  handleVisibilityChange(isVisible: boolean): void {
    if (isVisible) {
      // ALWAYS force reconnect on visibility return - Safari zombies can't be trusted
      // iOS suspension freezes WebSocket in pre-suspension state (readyState lies)
      console.log('[WS] Visibility returned - forcing fresh connection');
      this.forceReconnect();
    } else {
      // Going to background - stop heartbeat
      this.stopHeartbeat();
    }
  }

  /** Force close and reconnect - resets all retry state */
  forceReconnect(): void {
    console.log(`[WS] forceReconnect() called at T+${Math.round(performance.now())}ms`);
    this.clearRetryTimeout();
    this.clearConnectTimeout();
    this.stopHeartbeat();

    // Close existing socket - null handlers FIRST because frozen sockets may ignore .close()
    if (this.ws) {
      this.ws.onopen = null;
      this.ws.onclose = null;
      this.ws.onerror = null;
      this.ws.onmessage = null;
      try { this.ws.close(); } catch { /* ignore - frozen socket */ }
      this.ws = null;
    }

    // Reset retry state for fresh start
    this.retryCount = 0;
    this.retryDelay = INITIAL_RETRY_DELAY;
    this.gaveUp = false;

    // Small delay for network stack recovery after iOS suspension
    setTimeout(() => this.discoverAndConnect(), 200);
  }

  /** Send a command and optionally wait for response */
  send(command: string, params?: Record<string, unknown>): void {
    if (this.state !== 'connected' || !this.ws) {
      return;
    }
    const msg = createCommand(command, params);
    this.ws.send(JSON.stringify(msg));
  }

  /** Send a raw message string (for clock sync and other low-level messages) */
  sendRaw(message: string): void {
    if (this.state !== 'connected' || !this.ws) {
      return;
    }
    this.ws.send(message);
  }

  /** Send a command and wait for response */
  sendAsync(
    command: string,
    params?: Record<string, unknown>
  ): Promise<unknown> {
    return new Promise((resolve, reject) => {
      if (this.state !== 'connected' || !this.ws) {
        reject(new Error('Not connected'));
        return;
      }

      const msg = createCommand(command, params);
      this.pendingResponses.set(msg.id!, resolve);

      // Timeout after 5 seconds
      setTimeout(() => {
        if (this.pendingResponses.has(msg.id!)) {
          this.pendingResponses.delete(msg.id!);
          reject(new Error('Command timeout'));
        }
      }, 5000);

      this.ws.send(JSON.stringify(msg));
    });
  }

  private connect(): void {
    this.setState('connecting');

    // Use discovered port, fallback to options, then default
    const port = this.discoveredPort ?? this.options.port ?? 9224;

    // Use same hostname as page (works for both localhost and network access)
    const host = window.location.hostname || 'localhost';
    const url = `ws://${host}:${port}/`;
    const connectStart = performance.now();
    console.log(`[WS] Connecting to ${url} (attempt ${this.retryCount + 1}/${this.options.maxRetries}) at T+${Math.round(connectStart)}ms`);

    try {
      this.ws = new WebSocket(url);
    } catch (err) {
      console.error('[WS] Failed to create WebSocket:', err);
      this.scheduleRetry();
      return;
    }

    // CRITICAL: Safari CONNECTING timeout - socket may never fire events after iOS suspension
    // WebSocket can get stuck in CONNECTING state forever with no onopen/onclose/onerror
    // Use scheduleRetry (not forceReconnect) to properly count attempts and eventually give up
    this.connectTimeout = setTimeout(() => {
      if (this.ws?.readyState === WebSocket.CONNECTING) {
        console.log('[WS] Safari: Connection stuck in CONNECTING, scheduling retry');
        // Clean up frozen socket - null handlers first, frozen sockets ignore close()
        this.ws.onopen = null;
        this.ws.onclose = null;
        this.ws.onerror = null;
        this.ws.onmessage = null;
        try { this.ws.close(); } catch { /* ignore */ }
        this.ws = null;
        this.setState('error', 'Connection timeout');
        this.scheduleRetry();
      }
    }, CONNECT_TIMEOUT_MS);

    const wsCreateTime = performance.now();

    this.ws.onopen = () => {
      this.clearConnectTimeout();
      const elapsed = Math.round(performance.now() - wsCreateTime);
      console.log(`[WS] onopen fired at T+${Math.round(performance.now())}ms (${elapsed}ms after create)`);
      this.retryDelay = INITIAL_RETRY_DELAY; // Reset on successful connect
      this.sendHello();
    };

    this.ws.onmessage = (event) => {
      this.handleMessage(event.data);
    };

    this.ws.onerror = () => {
      this.clearConnectTimeout();
      const elapsed = Math.round(performance.now() - wsCreateTime);
      console.error(`[WS] onerror fired at T+${Math.round(performance.now())}ms (${elapsed}ms after create), readyState=${this.ws?.readyState}`);
    };

    this.ws.onclose = (event) => {
      this.clearConnectTimeout();
      const elapsed = Math.round(performance.now() - wsCreateTime);
      console.log(`[WS] onclose fired at T+${Math.round(performance.now())}ms (${elapsed}ms after create): code=${event.code} wasClean=${event.wasClean}`);
      this.ws = null;

      if (this.state !== 'disconnected') {
        // Unexpected close - retry
        this.setState('error', event.reason || `Connection closed (code ${event.code})`);
        this.scheduleRetry();
      }
    };
  }

  private sendHello(): void {
    if (!this.ws) return;
    // Use discovered token, fallback to options
    const token = this.discoveredToken ?? this.options.token;
    const hello = createHello(token);
    this.ws.send(JSON.stringify(hello));
  }

  private handleMessage(data: string): void {
    let msg: unknown;
    try {
      msg = JSON.parse(data);
    } catch {
      console.error('[WS] Invalid JSON:', data);
      return;
    }

    // Handle pong response for heartbeat
    if (typeof msg === 'object' && msg !== null && 'type' in msg) {
      if ((msg as { type: string }).type === 'pong') {
        this.handlePong();
        return; // Don't dispatch pong to app
      }
    }

    // Hello response completes connection
    if (isHelloResponse(msg)) {
      this.extensionVersion = msg.extensionVersion;
      console.log(`[WS] Hello received, extension v${msg.extensionVersion}`);

      // Check for stale content on reconnect
      if (msg.htmlMtime !== undefined) {
        if (this.htmlMtime !== null && this.htmlMtime !== msg.htmlMtime) {
          console.log(`[WS] HTML mtime changed (${this.htmlMtime} -> ${msg.htmlMtime}), reloading...`);
          window.location.reload();
          return;
        }
        this.htmlMtime = msg.htmlMtime;
      }

      this.setState('connected');
      return;
    }

    // Command response
    if (isResponseMessage(msg)) {
      const pending = this.pendingResponses.get(msg.id);
      if (pending) {
        this.pendingResponses.delete(msg.id);
        pending(msg);
      }
    }

    // Dispatch to callback (events, responses, and clock sync)
    if (isEventMessage(msg) || isResponseMessage(msg) || isClockSyncResponse(msg)) {
      this.options.onMessage?.(msg as ServerMessage);
    }
  }

  private setState(state: ConnectionState, error?: string): void {
    if (this.state === state) return;
    this.state = state;
    console.log(`[WS] State: ${state}${error ? ` (${error})` : ''}`);

    // Manage heartbeat lifecycle based on connection state
    if (state === 'connected') {
      this.startHeartbeat();
    } else {
      this.stopHeartbeat();
    }

    this.options.onStateChange?.(state, error);
  }

  private scheduleRetry(): void {
    this.clearRetryTimeout();
    this.retryCount++;

    // Check if we've exceeded max retries
    if (this.retryCount >= (this.options.maxRetries ?? DEFAULT_MAX_RETRIES)) {
      console.log(`[WS] Gave up after ${this.retryCount} attempts`);
      this.gaveUp = true;
      this.setState('disconnected');
      this.options.onGaveUp?.();
      return;
    }

    console.log(`[WS] Retrying in ${this.retryDelay}ms (attempt ${this.retryCount}/${this.options.maxRetries})`);
    this.retryTimeout = setTimeout(() => {
      this.retryTimeout = null;
      // Refresh token on each retry (handles REAPER restart with new token)
      this.discoverAndConnect();
    }, this.retryDelay);

    // Exponential backoff
    this.retryDelay = Math.min(
      this.retryDelay * RETRY_MULTIPLIER,
      MAX_RETRY_DELAY
    );
  }

  private clearRetryTimeout(): void {
    if (this.retryTimeout) {
      clearTimeout(this.retryTimeout);
      this.retryTimeout = null;
    }
  }

  private clearConnectTimeout(): void {
    if (this.connectTimeout) {
      clearTimeout(this.connectTimeout);
      this.connectTimeout = null;
    }
  }

  /** Start heartbeat pings when connected and visible */
  private startHeartbeat(): void {
    if (this.state !== 'connected' || this.heartbeatInterval) return;

    this.heartbeatInterval = setInterval(() => {
      this.sendHealthCheck();
    }, HEARTBEAT_INTERVAL_MS);
  }

  /** Stop heartbeat (when disconnected or going to background) */
  private stopHeartbeat(): void {
    if (this.heartbeatInterval) {
      clearInterval(this.heartbeatInterval);
      this.heartbeatInterval = null;
    }
    if (this.heartbeatTimeout) {
      clearTimeout(this.heartbeatTimeout);
      this.heartbeatTimeout = null;
    }
  }

  /** Send ping and expect pong within timeout */
  private sendHealthCheck(): void {
    if (this.state !== 'connected' || !this.ws) return;

    // Clear any existing timeout
    if (this.heartbeatTimeout) {
      clearTimeout(this.heartbeatTimeout);
    }

    // Set timeout for pong response
    this.heartbeatTimeout = setTimeout(() => {
      console.log('[WS] Heartbeat timeout - zombie connection detected');
      this.forceReconnect();
    }, HEARTBEAT_TIMEOUT_MS);

    // Send ping (server must respond with pong)
    this.ws.send(JSON.stringify({ type: 'ping', timestamp: Date.now() }));
  }

  /** Called when pong received to clear timeout */
  private handlePong(): void {
    if (this.heartbeatTimeout) {
      clearTimeout(this.heartbeatTimeout);
      this.heartbeatTimeout = null;
    }
  }
}
