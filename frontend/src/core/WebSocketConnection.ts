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
 */
async function fetchExtState(section: string, key: string): Promise<string | null> {
  try {
    const response = await fetch(`/_/GET/EXTSTATE/${section}/${key}`);
    const text = await response.text();
    const parts = text.trim().split('\t');
    if (parts.length >= 4 && parts[0] === 'EXTSTATE') {
      return parts[3] || null;
    }
    return null;
  } catch {
    return null;
  }
}

// Reconnection settings
const INITIAL_RETRY_DELAY = 1000;
const MAX_RETRY_DELAY = 30000;
const RETRY_MULTIPLIER = 1.5;
const DEFAULT_MAX_RETRIES = 10;

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
    // Always refresh port and token from EXTSTATE (handles REAPER restart)
    console.log('[WS] Discovering connection params from EXTSTATE...');

    const port = await fetchExtState('Reamo', 'WebSocketPort');
    if (port) {
      this.discoveredPort = parseInt(port, 10);
      console.log(`[WS] Discovered port: ${this.discoveredPort}`);
    }

    const token = await fetchExtState('Reamo', 'SessionToken');
    if (token) {
      this.discoveredToken = token;
      console.log('[WS] Discovered session token');
    }

    this.connect();
  }

  /** Stop the connection */
  stop(): void {
    this.clearRetryTimeout();
    if (this.ws) {
      this.ws.onclose = null; // Prevent reconnection
      this.ws.close();
      this.ws = null;
    }
    this.setState('disconnected');
  }

  /** Send a command and optionally wait for response */
  send(command: string, params?: Record<string, unknown>): void {
    if (this.state !== 'connected' || !this.ws) {
      return;
    }
    const msg = createCommand(command, params);
    this.ws.send(JSON.stringify(msg));
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
    const url = `ws://${host}:${port}`;
    console.log(`[WS] Connecting to ${url} (attempt ${this.retryCount + 1}/${this.options.maxRetries})`);

    try {
      this.ws = new WebSocket(url);
    } catch (err) {
      console.error('[WS] Failed to create WebSocket:', err);
      this.scheduleRetry();
      return;
    }

    this.ws.onopen = () => {
      console.log('[WS] Connected, sending hello');
      this.retryDelay = INITIAL_RETRY_DELAY; // Reset on successful connect
      this.sendHello();
    };

    this.ws.onmessage = (event) => {
      this.handleMessage(event.data);
    };

    this.ws.onerror = (event) => {
      console.error('[WS] Error:', event);
    };

    this.ws.onclose = (event) => {
      console.log(`[WS] Closed: code=${event.code} reason=${event.reason}`);
      this.ws = null;

      if (this.state !== 'disconnected') {
        // Unexpected close - retry
        this.setState('error', event.reason || 'Connection closed');
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

    // Dispatch to callback
    if (isEventMessage(msg) || isResponseMessage(msg)) {
      this.options.onMessage?.(msg as ServerMessage);
    }
  }

  private setState(state: ConnectionState, error?: string): void {
    if (this.state === state) return;
    this.state = state;
    console.log(`[WS] State: ${state}${error ? ` (${error})` : ''}`);
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
}
