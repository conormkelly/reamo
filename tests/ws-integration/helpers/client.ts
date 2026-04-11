/**
 * WebSocket test client for REAmo integration tests.
 *
 * Handles connection, hello handshake, command/response correlation,
 * and event waiting with timeouts.
 */

import WebSocket from 'ws';
import http from 'node:http';

// ---------------------------------------------------------------------------
// Types (mirrors the extension protocol — kept minimal to avoid coupling)
// ---------------------------------------------------------------------------

export interface HelloMessage {
  type: 'hello';
  clientVersion: string;
  protocolVersion: number;
  token?: string;
}

export interface HelloResponse {
  type: 'hello';
  extensionVersion: string;
  protocolVersion: number;
  htmlMtime?: number;
}

export interface CommandMessage {
  type: 'command';
  command: string;
  id?: string;
  [key: string]: unknown;
}

export interface ResponseMessage {
  type: 'response';
  id: string;
  success: boolean;
  payload?: Record<string, unknown>;
  error?: { code: string; message: string };
}

export interface EventMessage {
  type: 'event';
  event: string;
  payload?: unknown;
}

export type ServerMessage = HelloResponse | ResponseMessage | EventMessage | { type: string; [key: string]: unknown };

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

const DEFAULT_PORT = 9224;
const PROTOCOL_VERSION = 1;

export interface ClientOptions {
  port?: number;
  token?: string;
  /** Timeout for the initial connection + hello handshake (ms) */
  connectTimeout?: number;
}

let correlationCounter = 0;

// Cache the token per port to avoid repeated HTTP fetches
const tokenCache = new Map<number, string | null>();

/**
 * Fetch the session token from the extension's HTML page.
 * The server injects `<meta name="reamo-token" content="TOKEN">` into the served HTML.
 * Results are cached per port for the duration of the test run.
 */
async function fetchToken(port: number): Promise<string | null> {
  if (tokenCache.has(port)) return tokenCache.get(port)!;

  const token = await new Promise<string | null>((resolve, reject) => {
    const req = http.get(`http://localhost:${port}/`, {
      headers: { Host: `localhost:${port}` },
    }, (res) => {
      let body = '';
      res.on('data', (chunk: Buffer) => { body += chunk.toString(); });
      res.on('end', () => {
        const match = body.match(/<meta\s+name="reamo-token"\s+content="([^"]+)"/);
        resolve(match ? match[1] : null);
      });
    });
    req.on('error', (err) => reject(new Error(`Failed to fetch token from http://localhost:${port}/: ${err.message}`)));
    req.setTimeout(5000, () => { req.destroy(); reject(new Error('Token fetch timed out')); });
  });

  tokenCache.set(port, token);
  return token;
}

export class ReamoClient {
  private ws: WebSocket | null = null;
  private eventListeners: Array<(msg: ServerMessage) => void> = [];
  private pendingResponses = new Map<string, { resolve: (r: ResponseMessage) => void; reject: (e: Error) => void }>();

  public helloResponse: HelloResponse | null = null;

  /**
   * Connect to a running REAPER instance and complete the hello handshake.
   * Automatically fetches the session token from the HTML unless one is provided.
   * Rejects if REAPER isn't running or the handshake fails.
   */
  async connect(opts: ClientOptions = {}): Promise<HelloResponse> {
    const port = opts.port ?? DEFAULT_PORT;
    const timeout = opts.connectTimeout ?? 5000;

    // Fetch token from HTML if not explicitly provided
    const token = opts.token ?? await fetchToken(port);

    return new Promise<HelloResponse>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.close();
        reject(new Error(`Connection to ws://localhost:${port} timed out after ${timeout}ms — is REAPER running with the extension loaded?`));
      }, timeout);

      const ws = new WebSocket(`ws://localhost:${port}/ws`, {
        headers: { Host: `localhost:${port}` },
      });

      ws.on('open', () => {
        const hello: HelloMessage = {
          type: 'hello',
          clientVersion: '0.0.0-test',
          protocolVersion: PROTOCOL_VERSION,
          ...(token ? { token } : {}),
        };
        ws.send(JSON.stringify(hello));
      });

      ws.on('message', (data) => {
        const msg = JSON.parse(data.toString()) as ServerMessage;

        // First message should be the hello response
        if (msg.type === 'hello' && !this.helloResponse) {
          this.helloResponse = msg as HelloResponse;
          clearTimeout(timer);
          resolve(this.helloResponse);
        }

        // Route response messages to pending command promises
        if (msg.type === 'response') {
          const resp = msg as ResponseMessage;
          const pending = this.pendingResponses.get(resp.id);
          if (pending) {
            this.pendingResponses.delete(resp.id);
            pending.resolve(resp);
          }
        }

        // Notify all event listeners
        for (const listener of this.eventListeners) {
          listener(msg);
        }
      });

      ws.on('error', (err) => {
        clearTimeout(timer);
        reject(new Error(`WebSocket error: ${err.message} — is REAPER running on port ${port}?`));
      });

      ws.on('close', () => {
        clearTimeout(timer);
        // Reject any pending command responses
        for (const [id, pending] of this.pendingResponses) {
          pending.reject(new Error(`Connection closed while waiting for response to ${id}`));
        }
        this.pendingResponses.clear();
      });

      this.ws = ws;
    });
  }

  /**
   * Send a command and wait for the correlated response.
   */
  async sendCommand(command: string, params: Record<string, unknown> = {}): Promise<ResponseMessage> {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      throw new Error('Not connected');
    }

    const id = `test-${++correlationCounter}-${Date.now()}`;

    const msg: CommandMessage = {
      type: 'command',
      command,
      id,
      ...params,
    };

    return new Promise<ResponseMessage>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pendingResponses.delete(id);
        reject(new Error(`Command "${command}" timed out waiting for response (id=${id})`));
      }, 5000);

      this.pendingResponses.set(id, {
        resolve: (resp) => {
          clearTimeout(timer);
          resolve(resp);
        },
        reject: (err) => {
          clearTimeout(timer);
          reject(err);
        },
      });

      this.ws!.send(JSON.stringify(msg));
    });
  }

  /**
   * Send a fire-and-forget command (no response expected).
   * Use this for simple commands like transport/play, transport/stop, etc.
   */
  sendFireAndForget(command: string, params: Record<string, unknown> = {}): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      throw new Error('Not connected');
    }
    const msg = { type: 'command', command, ...params };
    this.ws.send(JSON.stringify(msg));
  }

  /**
   * Send a raw JSON message (for ping, clockSync, etc.).
   */
  send(msg: Record<string, unknown>): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      throw new Error('Not connected');
    }
    this.ws.send(JSON.stringify(msg));
  }

  /**
   * Wait for a specific event type to arrive.
   * Optionally filter with a predicate on the payload.
   */
  waitForEvent<T = unknown>(
    eventType: string,
    opts: { timeout?: number; predicate?: (payload: T) => boolean } = {},
  ): Promise<T> {
    const timeout = opts.timeout ?? 5000;

    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        removeListener();
        reject(new Error(`Timed out waiting for "${eventType}" event after ${timeout}ms`));
      }, timeout);

      const removeListener = this.onMessage((msg) => {
        if (msg.type === 'event') {
          const evt = msg as EventMessage;
          if (evt.event === eventType) {
            const payload = evt.payload as T;
            if (!opts.predicate || opts.predicate(payload)) {
              clearTimeout(timer);
              removeListener();
              resolve(payload);
            }
          }
        }
      });
    });
  }

  /**
   * Collect events of a given type for a duration.
   */
  async collectEvents(eventType: string, durationMs: number): Promise<unknown[]> {
    const events: unknown[] = [];
    const remove = this.onMessage((msg) => {
      if (msg.type === 'event' && (msg as EventMessage).event === eventType) {
        events.push((msg as EventMessage).payload);
      }
    });
    await new Promise((r) => setTimeout(r, durationMs));
    remove();
    return events;
  }

  /**
   * Register a message listener. Returns an unsubscribe function.
   */
  onMessage(listener: (msg: ServerMessage) => void): () => void {
    this.eventListeners.push(listener);
    return () => {
      const idx = this.eventListeners.indexOf(listener);
      if (idx !== -1) this.eventListeners.splice(idx, 1);
    };
  }

  /** Close the connection. Safe to call multiple times. */
  close(): void {
    if (this.ws) {
      this.ws.removeAllListeners();
      try {
        if (this.ws.readyState === WebSocket.OPEN) {
          this.ws.close();
        } else if (this.ws.readyState === WebSocket.CONNECTING) {
          this.ws.terminate();
        }
      } catch {
        // Ignore errors during cleanup
      }
      this.ws = null;
    }
    this.helloResponse = null;
    this.eventListeners = [];
    this.pendingResponses.clear();
  }
}
