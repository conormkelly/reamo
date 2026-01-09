/**
 * WebSocketConnection Tests
 *
 * Unit tests for WebSocket connection management including:
 * - Connection lifecycle (start → connect → hello → connected)
 * - Reconnection with exponential backoff
 * - Heartbeat and stale connection detection
 * - Safari/iOS workarounds (CONNECTING timeout, visibility change)
 * - Async command handling
 *
 * Uses mocked WebSocket, fetch, and timers for deterministic testing.
 */

import { describe, it, expect, vi, beforeEach, afterEach, type MockInstance } from 'vitest';
import { WebSocketConnection } from './WebSocketConnection';

// =============================================================================
// Mock WebSocket
// =============================================================================

interface MockWebSocketInstance {
  url: string;
  readyState: number;
  onopen: ((event: Event) => void) | null;
  onclose: ((event: CloseEvent) => void) | null;
  onerror: ((event: Event) => void) | null;
  onmessage: ((event: MessageEvent) => void) | null;
  send: MockInstance;
  close: MockInstance;
  // Test helpers
  simulateOpen: () => void;
  simulateClose: (code?: number, reason?: string) => void;
  simulateError: () => void;
  simulateMessage: (data: unknown) => void;
}

// Track created WebSocket instances for assertions
let mockWebSocketInstances: MockWebSocketInstance[] = [];

// Mock WebSocket class (must be a proper class for `new` to work)
class MockWebSocket implements MockWebSocketInstance {
  url: string;
  readyState: number = 0; // CONNECTING
  onopen: ((event: Event) => void) | null = null;
  onclose: ((event: CloseEvent) => void) | null = null;
  onerror: ((event: Event) => void) | null = null;
  onmessage: ((event: MessageEvent) => void) | null = null;
  send = vi.fn();
  close = vi.fn(() => {
    this.readyState = 3; // CLOSED
  });

  // Static constants
  static CONNECTING = 0;
  static OPEN = 1;
  static CLOSING = 2;
  static CLOSED = 3;

  constructor(url: string) {
    this.url = url;
    mockWebSocketInstances.push(this);
  }

  simulateOpen() {
    this.readyState = 1; // OPEN
    this.onopen?.(new Event('open'));
  }

  simulateClose(code = 1000, reason = '') {
    this.readyState = 3; // CLOSED
    this.onclose?.(new CloseEvent('close', { code, reason, wasClean: code === 1000 }));
  }

  simulateError() {
    this.onerror?.(new Event('error'));
  }

  simulateMessage(data: unknown) {
    const messageData = typeof data === 'string' ? data : JSON.stringify(data);
    this.onmessage?.(new MessageEvent('message', { data: messageData }));
  }
}

// =============================================================================
// Mock fetch for EXTSTATE discovery
// =============================================================================

function createMockFetch(responses: Record<string, string> = {}) {
  return vi.fn((url: string) => {
    const body = responses[url] || '';
    return Promise.resolve({
      text: () => Promise.resolve(body),
    });
  });
}

// =============================================================================
// Test Setup
// =============================================================================

describe('WebSocketConnection', () => {
  let originalWebSocket: typeof WebSocket;
  let originalFetch: typeof fetch;
  let originalMatchMedia: typeof window.matchMedia;
  let mockFetch: MockInstance;

  beforeEach(() => {
    // Store originals
    originalWebSocket = globalThis.WebSocket;
    originalFetch = globalThis.fetch;
    originalMatchMedia = window.matchMedia;

    // Reset mock instances
    mockWebSocketInstances = [];

    // Mock WebSocket with our class
    (globalThis as unknown as { WebSocket: typeof MockWebSocket }).WebSocket = MockWebSocket;

    // Mock fetch for EXTSTATE discovery
    mockFetch = createMockFetch({
      '/_/GET/EXTSTATE/Reamo/WebSocketPort': 'EXTSTATE\tReamo\tWebSocketPort\t9224',
      '/_/GET/EXTSTATE/Reamo/SessionToken': 'EXTSTATE\tReamo\tSessionToken\ttest-token-123',
    });
    globalThis.fetch = mockFetch as unknown as typeof fetch;

    // Mock matchMedia (for PWA detection)
    window.matchMedia = vi.fn().mockReturnValue({ matches: false }) as unknown as typeof matchMedia;

    // Use fake timers
    vi.useFakeTimers();
  });

  afterEach(() => {
    // Restore originals
    globalThis.WebSocket = originalWebSocket;
    globalThis.fetch = originalFetch;
    window.matchMedia = originalMatchMedia;

    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  // ===========================================================================
  // Connection Lifecycle Tests
  // ===========================================================================

  describe('connection lifecycle', () => {
    it('should transition from disconnected → connecting → connected on successful start', async () => {
      const onStateChange = vi.fn();
      const conn = new WebSocketConnection({ onStateChange });

      // Start connection
      const startPromise = conn.start();

      // Should immediately be connecting (set before async fetch)
      await vi.advanceTimersByTimeAsync(0);
      expect(onStateChange).toHaveBeenCalledWith('connecting', undefined);

      // Let EXTSTATE fetches complete
      await vi.advanceTimersByTimeAsync(100);
      await startPromise;

      // Should have created WebSocket
      expect(mockWebSocketInstances).toHaveLength(1);
      const ws = mockWebSocketInstances[0];
      expect(ws.url).toBe('ws://localhost:9224/');

      // Simulate WebSocket open
      ws.simulateOpen();

      // Should have sent hello
      expect(ws.send).toHaveBeenCalledWith(expect.stringContaining('"type":"hello"'));

      // Simulate hello response
      ws.simulateMessage({
        type: 'hello',
        extensionVersion: '1.0.0',
        protocolVersion: 1,
      });

      // Should be connected
      expect(conn.connectionState).toBe('connected');
      expect(onStateChange).toHaveBeenCalledWith('connected', undefined);
    });

    it('should use discovered port and token from EXTSTATE', async () => {
      mockFetch = createMockFetch({
        '/_/GET/EXTSTATE/Reamo/WebSocketPort': 'EXTSTATE\tReamo\tWebSocketPort\t8888',
        '/_/GET/EXTSTATE/Reamo/SessionToken': 'EXTSTATE\tReamo\tSessionToken\tmy-secret-token',
      });
      globalThis.fetch = mockFetch as unknown as typeof fetch;

      const conn = new WebSocketConnection();
      await conn.start();
      await vi.advanceTimersByTimeAsync(100);

      expect(mockWebSocketInstances[0].url).toBe('ws://localhost:8888/');

      // Check that token was included in hello
      mockWebSocketInstances[0].simulateOpen();
      const helloCall = mockWebSocketInstances[0].send.mock.calls[0][0];
      const helloMsg = JSON.parse(helloCall);
      expect(helloMsg.token).toBe('my-secret-token');
    });

    it('should fall back to default port if EXTSTATE fetch fails', async () => {
      mockFetch = vi.fn(() => Promise.reject(new Error('Network error')));
      globalThis.fetch = mockFetch as unknown as typeof fetch;

      const conn = new WebSocketConnection({ port: 9999 });
      await conn.start();
      await vi.advanceTimersByTimeAsync(100);

      expect(mockWebSocketInstances[0].url).toBe('ws://localhost:9999/');
    });

    it('should stop cleanly and not reconnect', async () => {
      const onStateChange = vi.fn();
      const conn = new WebSocketConnection({ onStateChange });

      await conn.start();
      await vi.advanceTimersByTimeAsync(100);

      const ws = mockWebSocketInstances[0];
      ws.simulateOpen();
      ws.simulateMessage({ type: 'hello', extensionVersion: '1.0.0', protocolVersion: 1 });

      expect(conn.connectionState).toBe('connected');

      // Stop connection
      conn.stop();

      expect(conn.connectionState).toBe('disconnected');
      expect(ws.close).toHaveBeenCalled();

      // Advance time - should not attempt to reconnect
      await vi.advanceTimersByTimeAsync(60000);
      expect(mockWebSocketInstances).toHaveLength(1);
    });
  });

  // ===========================================================================
  // Reconnection Tests
  // ===========================================================================

  describe('reconnection logic', () => {
    it('should retry with exponential backoff on connection failure', async () => {
      const onStateChange = vi.fn();
      const conn = new WebSocketConnection({ onStateChange, maxRetries: 5 });

      await conn.start();
      await vi.advanceTimersByTimeAsync(100);

      // First connection attempt fails
      mockWebSocketInstances[0].simulateClose(1006, 'Connection refused');

      expect(onStateChange).toHaveBeenCalledWith('error', expect.any(String));

      // First retry after 1000ms
      await vi.advanceTimersByTimeAsync(1000);
      expect(mockWebSocketInstances).toHaveLength(2);

      // Second failure
      mockWebSocketInstances[1].simulateClose(1006, 'Connection refused');

      // Second retry after 1500ms (1000 * 1.5)
      await vi.advanceTimersByTimeAsync(1500);
      expect(mockWebSocketInstances).toHaveLength(3);

      // Third failure
      mockWebSocketInstances[2].simulateClose(1006, 'Connection refused');

      // Third retry after 2250ms (1500 * 1.5)
      await vi.advanceTimersByTimeAsync(2250);
      expect(mockWebSocketInstances).toHaveLength(4);
    });

    it('should give up after maxRetries attempts', async () => {
      const onGaveUp = vi.fn();
      const onStateChange = vi.fn();
      const conn = new WebSocketConnection({ onStateChange, onGaveUp, maxRetries: 3 });

      await conn.start();
      await vi.advanceTimersByTimeAsync(100);

      // Fail maxRetries times
      for (let i = 0; i < 3; i++) {
        mockWebSocketInstances[i].simulateClose(1006, 'Connection refused');
        await vi.advanceTimersByTimeAsync(30000); // Enough time for any backoff
      }

      expect(onGaveUp).toHaveBeenCalled();
      expect(conn.hasGivenUp).toBe(true);
      expect(conn.connectionState).toBe('disconnected');
    });

    it('should reset retry count on successful connection', async () => {
      const conn = new WebSocketConnection({ maxRetries: 5 });

      await conn.start();
      await vi.advanceTimersByTimeAsync(100);

      // First attempt fails
      mockWebSocketInstances[0].simulateClose(1006, 'Connection refused');
      await vi.advanceTimersByTimeAsync(1000);

      // Second attempt fails
      mockWebSocketInstances[1].simulateClose(1006, 'Connection refused');
      await vi.advanceTimersByTimeAsync(1500);

      // Third attempt succeeds
      mockWebSocketInstances[2].simulateOpen();
      mockWebSocketInstances[2].simulateMessage({
        type: 'hello',
        extensionVersion: '1.0.0',
        protocolVersion: 1,
      });

      expect(conn.connectionState).toBe('connected');

      // Now disconnect again - retry count should be reset
      mockWebSocketInstances[2].simulateClose(1006, 'Connection lost');

      // Should retry with initial delay (1000ms), not continuing backoff
      await vi.advanceTimersByTimeAsync(1000);
      expect(mockWebSocketInstances).toHaveLength(4);
    });

    it('should allow manual retry after giving up', async () => {
      const onGaveUp = vi.fn();
      const conn = new WebSocketConnection({ onGaveUp, maxRetries: 1 });

      await conn.start();
      await vi.advanceTimersByTimeAsync(100);

      // Fail once to give up
      mockWebSocketInstances[0].simulateClose(1006, 'Connection refused');
      await vi.advanceTimersByTimeAsync(30000);

      expect(conn.hasGivenUp).toBe(true);

      // Manual retry
      await conn.retry();
      await vi.advanceTimersByTimeAsync(100);

      expect(conn.hasGivenUp).toBe(false);
      expect(mockWebSocketInstances).toHaveLength(2);
    });
  });

  // ===========================================================================
  // Heartbeat Tests
  // ===========================================================================

  describe('heartbeat and stale detection', () => {
    it('should start heartbeat after connection', async () => {
      const conn = new WebSocketConnection();

      await conn.start();
      await vi.advanceTimersByTimeAsync(100);

      const ws = mockWebSocketInstances[0];
      ws.simulateOpen();
      ws.simulateMessage({ type: 'hello', extensionVersion: '1.0.0', protocolVersion: 1 });

      // Clear hello send call
      ws.send.mockClear();

      // Advance to first heartbeat (10s)
      await vi.advanceTimersByTimeAsync(10000);

      expect(ws.send).toHaveBeenCalledWith(expect.stringContaining('"type":"ping"'));
    });

    it('should detect stale connection when pong is not received', async () => {
      const onStateChange = vi.fn();
      const conn = new WebSocketConnection({ onStateChange });

      await conn.start();
      await vi.advanceTimersByTimeAsync(100);

      const ws = mockWebSocketInstances[0];
      ws.simulateOpen();
      ws.simulateMessage({ type: 'hello', extensionVersion: '1.0.0', protocolVersion: 1 });

      // Advance to first heartbeat
      await vi.advanceTimersByTimeAsync(10000);

      // Don't respond with pong - advance past timeout (3s)
      await vi.advanceTimersByTimeAsync(3100);

      // Should have triggered reconnect (forceReconnect creates new WebSocket after 200ms delay)
      await vi.advanceTimersByTimeAsync(300);
      expect(mockWebSocketInstances.length).toBeGreaterThan(1);
    });

    it('should not trigger timeout when pong is received', async () => {
      const conn = new WebSocketConnection();

      await conn.start();
      await vi.advanceTimersByTimeAsync(100);

      const ws = mockWebSocketInstances[0];
      ws.simulateOpen();
      ws.simulateMessage({ type: 'hello', extensionVersion: '1.0.0', protocolVersion: 1 });

      // Advance to first heartbeat
      await vi.advanceTimersByTimeAsync(10000);

      // Respond with pong
      ws.simulateMessage({ type: 'pong' });

      // Advance past timeout - should NOT reconnect
      await vi.advanceTimersByTimeAsync(5000);

      expect(mockWebSocketInstances).toHaveLength(1);
      expect(conn.connectionState).toBe('connected');
    });

    it('should stop heartbeat when going to background', async () => {
      const conn = new WebSocketConnection();

      await conn.start();
      await vi.advanceTimersByTimeAsync(100);

      const ws = mockWebSocketInstances[0];
      ws.simulateOpen();
      ws.simulateMessage({ type: 'hello', extensionVersion: '1.0.0', protocolVersion: 1 });

      ws.send.mockClear();

      // Simulate going to background
      conn.handleVisibilityChange(false);

      // Advance past heartbeat interval
      await vi.advanceTimersByTimeAsync(15000);

      // Should not have sent ping (heartbeat stopped)
      expect(ws.send).not.toHaveBeenCalled();
    });
  });

  // ===========================================================================
  // Safari/iOS Workaround Tests
  // ===========================================================================

  describe('Safari/iOS workarounds', () => {
    it('should timeout stuck CONNECTING state', async () => {
      const onStateChange = vi.fn();
      const conn = new WebSocketConnection({ onStateChange, maxRetries: 5 });

      await conn.start();
      await vi.advanceTimersByTimeAsync(100);

      const ws = mockWebSocketInstances[0];

      // Simulate Safari bug: WebSocket stays in CONNECTING, no events fire
      expect(ws.readyState).toBe(WebSocket.CONNECTING);

      // Advance past connect timeout (5000ms)
      await vi.advanceTimersByTimeAsync(5100);

      // Should have triggered retry
      expect(onStateChange).toHaveBeenCalledWith('error', 'Connection timeout');
      await vi.advanceTimersByTimeAsync(1100);
      expect(mockWebSocketInstances.length).toBeGreaterThan(1);
    });

    it('should force reconnect on visibility return', async () => {
      const conn = new WebSocketConnection();

      await conn.start();
      await vi.advanceTimersByTimeAsync(100);

      const ws = mockWebSocketInstances[0];
      ws.simulateOpen();
      ws.simulateMessage({ type: 'hello', extensionVersion: '1.0.0', protocolVersion: 1 });

      expect(conn.connectionState).toBe('connected');

      // Simulate returning from background (iOS PWA)
      conn.handleVisibilityChange(true);

      // Should force reconnect after 200ms delay
      await vi.advanceTimersByTimeAsync(300);

      expect(mockWebSocketInstances.length).toBeGreaterThan(1);
    });

    it('should reset retry state on forceReconnect', async () => {
      const conn = new WebSocketConnection({ maxRetries: 5 });

      await conn.start();
      await vi.advanceTimersByTimeAsync(100);

      const ws = mockWebSocketInstances[0];
      ws.simulateOpen();
      ws.simulateMessage({ type: 'hello', extensionVersion: '1.0.0', protocolVersion: 1 });

      // Fail a few times to increment retry count
      ws.simulateClose(1006, 'Lost connection');
      await vi.advanceTimersByTimeAsync(1000);
      mockWebSocketInstances[1].simulateClose(1006);
      await vi.advanceTimersByTimeAsync(1500);
      mockWebSocketInstances[2].simulateClose(1006);

      // Now forceReconnect (simulating visibility return)
      conn.forceReconnect();

      // Should have reset gaveUp flag
      expect(conn.hasGivenUp).toBe(false);
    });
  });

  // ===========================================================================
  // Async Command Tests
  // ===========================================================================

  describe('sendAsync', () => {
    it('should resolve when response is received', async () => {
      const conn = new WebSocketConnection();

      await conn.start();
      await vi.advanceTimersByTimeAsync(100);

      const ws = mockWebSocketInstances[0];
      ws.simulateOpen();
      ws.simulateMessage({ type: 'hello', extensionVersion: '1.0.0', protocolVersion: 1 });

      // Send async command
      const responsePromise = conn.sendAsync('test/command', { foo: 'bar' });

      // Extract the command ID from the sent message
      const sentMsg = JSON.parse(ws.send.mock.calls[1][0]); // [0] is hello
      const commandId = sentMsg.id;

      // Simulate response
      ws.simulateMessage({
        type: 'response',
        id: commandId,
        success: true,
        payload: { result: 'ok' },
      });

      const response = await responsePromise;
      expect(response).toEqual({
        type: 'response',
        id: commandId,
        success: true,
        payload: { result: 'ok' },
      });
    });

    it('should reject when not connected', async () => {
      const conn = new WebSocketConnection();

      // Not connected yet
      await expect(conn.sendAsync('test/command')).rejects.toThrow('Not connected');
    });

    it('should reject on timeout', async () => {
      const conn = new WebSocketConnection();

      await conn.start();
      await vi.advanceTimersByTimeAsync(100);

      const ws = mockWebSocketInstances[0];
      ws.simulateOpen();
      ws.simulateMessage({ type: 'hello', extensionVersion: '1.0.0', protocolVersion: 1 });

      // Send async command but don't respond
      const responsePromise = conn.sendAsync('test/command');

      // Catch the promise early to prevent unhandled rejection during timer advance
      let error: Error | null = null;
      const caughtPromise = responsePromise.catch((e) => {
        error = e as Error;
      });

      // Advance past timeout (5s)
      await vi.advanceTimersByTimeAsync(5100);

      // Wait for the caught promise to settle
      await caughtPromise;

      expect(error).not.toBeNull();
      expect(error!.message).toBe('Command timeout');
    });

    it('should clear pending responses on disconnect', async () => {
      const conn = new WebSocketConnection();

      await conn.start();
      await vi.advanceTimersByTimeAsync(100);

      const ws = mockWebSocketInstances[0];
      ws.simulateOpen();
      ws.simulateMessage({ type: 'hello', extensionVersion: '1.0.0', protocolVersion: 1 });

      // Send async command
      const responsePromise = conn.sendAsync('test/command');

      // Disconnect (stop clears pending)
      conn.stop();

      // Should resolve with error response (not hang)
      const response = await responsePromise;
      expect(response).toEqual(expect.objectContaining({
        success: false,
        error: 'Connection closed',
      }));
    });
  });

  // ===========================================================================
  // Message Handling Tests
  // ===========================================================================

  describe('message handling', () => {
    it('should dispatch events to onMessage callback', async () => {
      const onMessage = vi.fn();
      const conn = new WebSocketConnection({ onMessage });

      await conn.start();
      await vi.advanceTimersByTimeAsync(100);

      const ws = mockWebSocketInstances[0];
      ws.simulateOpen();
      ws.simulateMessage({ type: 'hello', extensionVersion: '1.0.0', protocolVersion: 1 });

      // Simulate event message
      ws.simulateMessage({
        type: 'event',
        event: 'transport',
        payload: { playState: 1, position: 0 },
      });

      expect(onMessage).toHaveBeenCalledWith(expect.objectContaining({
        type: 'event',
        event: 'transport',
      }));
    });

    it('should not dispatch pong to onMessage', async () => {
      const onMessage = vi.fn();
      const conn = new WebSocketConnection({ onMessage });

      await conn.start();
      await vi.advanceTimersByTimeAsync(100);

      const ws = mockWebSocketInstances[0];
      ws.simulateOpen();
      ws.simulateMessage({ type: 'hello', extensionVersion: '1.0.0', protocolVersion: 1 });

      onMessage.mockClear();

      // Simulate pong
      ws.simulateMessage({ type: 'pong' });

      expect(onMessage).not.toHaveBeenCalled();
    });

    it('should reload page when htmlMtime changes', async () => {
      const originalReload = window.location.reload;
      const mockReload = vi.fn();
      Object.defineProperty(window, 'location', {
        value: { ...window.location, reload: mockReload },
        writable: true,
      });

      const conn = new WebSocketConnection();

      await conn.start();
      await vi.advanceTimersByTimeAsync(100);

      const ws = mockWebSocketInstances[0];
      ws.simulateOpen();
      ws.simulateMessage({ type: 'hello', extensionVersion: '1.0.0', protocolVersion: 1, htmlMtime: 12345 });

      // Reconnect
      ws.simulateClose(1006);
      await vi.advanceTimersByTimeAsync(1100);

      const ws2 = mockWebSocketInstances[1];
      ws2.simulateOpen();
      ws2.simulateMessage({ type: 'hello', extensionVersion: '1.0.0', protocolVersion: 1, htmlMtime: 12346 }); // Different mtime

      expect(mockReload).toHaveBeenCalled();

      // Restore
      Object.defineProperty(window, 'location', { value: { reload: originalReload }, writable: true });
    });

    it('should handle invalid JSON gracefully', async () => {
      const onMessage = vi.fn();
      const conn = new WebSocketConnection({ onMessage });

      await conn.start();
      await vi.advanceTimersByTimeAsync(100);

      const ws = mockWebSocketInstances[0];
      ws.simulateOpen();
      ws.simulateMessage({ type: 'hello', extensionVersion: '1.0.0', protocolVersion: 1 });

      // Simulate invalid JSON - this will log error but shouldn't crash
      ws.onmessage?.(new MessageEvent('message', { data: 'not valid json {' }));

      // Should still be connected
      expect(conn.connectionState).toBe('connected');
    });
  });

  // ===========================================================================
  // send() and sendRaw() Tests
  // ===========================================================================

  describe('send and sendRaw', () => {
    it('should not send when disconnected', async () => {
      const conn = new WebSocketConnection();

      // Not connected
      conn.send('test/command');

      // Should not have created WebSocket
      expect(mockWebSocketInstances).toHaveLength(0);
    });

    it('should send raw message', async () => {
      const conn = new WebSocketConnection();

      await conn.start();
      await vi.advanceTimersByTimeAsync(100);

      const ws = mockWebSocketInstances[0];
      ws.simulateOpen();
      ws.simulateMessage({ type: 'hello', extensionVersion: '1.0.0', protocolVersion: 1 });

      ws.send.mockClear();

      conn.sendRaw('{"type":"clockSync","t0":12345}');

      expect(ws.send).toHaveBeenCalledWith('{"type":"clockSync","t0":12345}');
    });
  });
});
