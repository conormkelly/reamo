/**
 * WebSocket Actor Singleton
 *
 * Creates and manages the global XState actor for WebSocket connection.
 * Syncs state to Zustand store and provides command sending API.
 *
 * Usage:
 *   import { wsActor, sendCommand, sendCommandAsync } from './websocketActor';
 *
 *   // Start connection
 *   wsActor.send({ type: 'START' });
 *
 *   // Send command
 *   sendCommand('transport/play');
 *
 *   // Send command and wait for response
 *   const result = await sendCommandAsync('track/get', { idx: 0 });
 */

import { createActor, type Subscription } from 'xstate';
import { websocketMachine, getConnectionStatus, type ConnectionStatus, type WebSocketEvent } from './websocketMachine';
import type { ServerMessage } from './WebSocketTypes';
import { useReaperStore } from '../store';
import { checkVersionMismatch, storeVersion, hardRefresh } from '../utils/versionStorage';

// =============================================================================
// Pending Responses Management
// =============================================================================

interface PendingRequest {
  resolve: (response: unknown) => void;
  reject: (error: Error) => void;
  timeoutId: ReturnType<typeof setTimeout>;
}

const MAX_PENDING_REQUESTS = 100;
const DEFAULT_REQUEST_TIMEOUT = 30000; // 30s per request

const pendingResponses = new Map<string, PendingRequest>();
let messageIdCounter = 0;

function generateMessageId(): string {
  messageIdCounter = (messageIdCounter + 1) % 1000000;
  return `msg_${Date.now()}_${messageIdCounter}`;
}

function clearAllPendingResponses(error: string): void {
  pendingResponses.forEach((pending) => {
    clearTimeout(pending.timeoutId);
    pending.reject(new Error(error));
  });
  pendingResponses.clear();
}

// =============================================================================
// Message Handling
// =============================================================================

function handleServerMessage(msg: ServerMessage): void {
  // Check if this is a response to a pending request
  if ('id' in msg && typeof msg.id === 'string') {
    const pending = pendingResponses.get(msg.id);
    if (pending) {
      clearTimeout(pending.timeoutId);
      pendingResponses.delete(msg.id);
      pending.resolve(msg);
      return;
    }
  }

  // Forward to store's message handler
  useReaperStore.getState().handleWebSocketMessage(msg);
}

// =============================================================================
// Actor Creation and State Sync
// =============================================================================

// Create the actor with initial context
const actor = createActor(websocketMachine, {
  input: undefined,
  // Set the onMessage callback in context
  snapshot: undefined,
});

// Track current status for consumers
let currentStatus: ConnectionStatus = 'idle';
let previousStatus: ConnectionStatus = 'idle';
let currentRetryCount = 0;
let storeSubscription: Subscription | null = null;
let versionCheckDone = false; // Only check version once per page load

// Sync actor state to Zustand store
function syncToStore(): void {
  const snapshot = actor.getSnapshot();
  // XState v5: compound states are objects like {connected: "active"}, simple states are strings
  const stateValue = snapshot.value;
  const status = getConnectionStatus(stateValue as string | Record<string, unknown>);
  const context = snapshot.context;

  // Update tracking vars
  currentStatus = status;
  currentRetryCount = context.retryCount;

  // Skip store updates in test mode
  if (useReaperStore.getState()._testMode) {
    return;
  }

  const store = useReaperStore.getState();

  // Update connected status
  const isConnected = status === 'connected';
  if (store.connected !== isConnected) {
    store.setConnected(isConnected);
  }

  // Update error info
  if (context.lastError !== store.lastError) {
    store.setLastError(context.lastError);
  }

  // Update connection status (full state)
  if (store.connectionStatus !== status) {
    store.setConnectionStatus(status);
  }

  // Update retry count
  if (store.retryCount !== context.retryCount) {
    store.setRetryCount(context.retryCount);
  }

  // Clear pending responses on disconnect
  if (status === 'retrying' || status === 'gave_up' || status === 'idle') {
    if (pendingResponses.size > 0) {
      clearAllPendingResponses('Connection lost');
    }
  }

  // Version check on first connect (PWA cache busting)
  // Only check once per page load to avoid infinite reload loops
  if (status === 'connected' && previousStatus !== 'connected' && !versionCheckDone) {
    versionCheckDone = true;
    const { extensionVersion, htmlMtime } = context;

    if (extensionVersion && htmlMtime !== null) {
      const result = checkVersionMismatch(extensionVersion, htmlMtime);

      if (result === 'mismatch') {
        // Version changed since last load - either auto-refresh or show banner
        const autoUpdateEnabled = useReaperStore.getState().autoUpdateEnabled;
        if (autoUpdateEnabled) {
          // Store new version BEFORE refresh to prevent infinite reload loop
          storeVersion(extensionVersion, htmlMtime);
          // Silent hard refresh
          hardRefresh();
        } else {
          // Store new version so banner doesn't re-trigger on every reconnect
          storeVersion(extensionVersion, htmlMtime);
          // Show "Update available" banner
          useReaperStore.getState().setUpdateAvailable(true);
        }
      } else {
        // First load or same version - store for future comparison
        storeVersion(extensionVersion, htmlMtime);
      }
    }
  }

  // Update previous status for next comparison
  previousStatus = status;
}

// Subscribe to actor state changes
storeSubscription = actor.subscribe(syncToStore);

// Set up message handler in actor context
// We need to update the context with the message handler
// This is done by sending an event that modifies context... but our machine doesn't have that
// Instead, we'll use the window.__wsSocket approach for now and handle messages there

// Actually, we need to patch the actor's context or use a different approach
// Let's create a wrapper that handles message dispatch

// Global message handler that the websocket actor calls
(window as unknown as { __wsMessageHandler?: (msg: ServerMessage) => void }).__wsMessageHandler = handleServerMessage;

// Global event sender for socket events
// CRITICAL: This bypasses the XState actor lifecycle issue where sendBack becomes invalid
// after state transitions (connecting → handshaking). Socket handlers use this instead of sendBack.
(window as unknown as { __wsEventSender?: (event: WebSocketEvent) => void }).__wsEventSender = (event) => {
  actor.send(event);
};

// =============================================================================
// Public API
// =============================================================================

export const wsActor = actor;

/**
 * Get current connection status
 */
export function getStatus(): ConnectionStatus {
  return currentStatus;
}

/**
 * Get current retry count
 */
export function getRetryCount(): number {
  return currentRetryCount;
}

/**
 * Check if connected
 */
export function isConnected(): boolean {
  return currentStatus === 'connected';
}

// Debug flag for MIDI timing analysis (enable via console: window.__debugMidi = true)
const DEBUG_MIDI = () => (window as unknown as { __debugMidi?: boolean }).__debugMidi === true;
let midiSendCounter = 0;

/**
 * Send a command (fire-and-forget)
 */
export function sendCommand(command: string, params?: Record<string, unknown>): void {
  const socket = (window as unknown as { __wsSocket?: WebSocket }).__wsSocket;
  if (!socket || socket.readyState !== WebSocket.OPEN) {
    if (DEBUG_MIDI() && command.startsWith('midi/')) {
      console.warn(`[WS] MIDI blocked - socket not ready (readyState=${socket?.readyState})`);
    }
    return;
  }

  const msg = {
    type: 'command',
    command,
    ...params,
  };

  // Debug MIDI timing at the socket layer
  if (DEBUG_MIDI() && command.startsWith('midi/')) {
    const sendId = ++midiSendCounter;
    const preStringify = performance.now();
    const json = JSON.stringify(msg);
    const postStringify = performance.now();
    socket.send(json);
    const postSend = performance.now();
    console.log(
      `[WS] MIDI #${sendId} ${command} @ ${postSend.toFixed(1)}ms | ` +
      `stringify=${(postStringify - preStringify).toFixed(2)}ms, ` +
      `send=${(postSend - postStringify).toFixed(2)}ms, ` +
      `payload=${json.length}b`
    );
  } else {
    socket.send(JSON.stringify(msg));
  }
}

/**
 * Send a raw message string (for clock sync and other low-level messages)
 */
export function sendRaw(message: string): void {
  const socket = (window as unknown as { __wsSocket?: WebSocket }).__wsSocket;
  if (!socket || socket.readyState !== WebSocket.OPEN) {
    return;
  }
  socket.send(message);
}

/**
 * Send a command and wait for response
 */
export function sendCommandAsync(
  command: string,
  params?: Record<string, unknown>,
  timeout: number = DEFAULT_REQUEST_TIMEOUT
): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const socket = (window as unknown as { __wsSocket?: WebSocket }).__wsSocket;
    if (!socket || socket.readyState !== WebSocket.OPEN) {
      reject(new Error('Not connected'));
      return;
    }

    // Check pending limit
    if (pendingResponses.size >= MAX_PENDING_REQUESTS) {
      reject(new Error('Too many pending requests'));
      return;
    }

    const id = generateMessageId();

    // Set up timeout
    const timeoutId = setTimeout(() => {
      if (pendingResponses.has(id)) {
        pendingResponses.delete(id);
        reject(new Error('Request timeout'));
      }
    }, timeout);

    // Store pending request
    pendingResponses.set(id, { resolve, reject, timeoutId });

    // Send message
    const msg = {
      type: 'command',
      command,
      id,
      ...params,
    };
    socket.send(JSON.stringify(msg));
  });
}

/**
 * Start the connection
 */
export function start(): void {
  actor.start();
  actor.send({ type: 'START' });
}

/**
 * Stop the connection
 */
export function stop(): void {
  actor.send({ type: 'STOP' });
  clearAllPendingResponses('Connection stopped');
}

/**
 * Retry after giving up
 */
export function retry(): void {
  actor.send({ type: 'MANUAL_RETRY' });
}

/**
 * Notify visibility change
 *
 * CRITICAL: Safari iOS zombies - never trust existing connection after backgrounding.
 * iOS suspension freezes WebSocket in pre-suspension state (readyState lies).
 * Always force full reconnect on Safari visibility return - from ANY state, not just connected.
 * This matches the old WebSocketConnection behavior exactly.
 */
export function handleVisibilityChange(isVisible: boolean): void {
  if (isVisible) {
    const isSafari = navigator.userAgent.includes('Safari') && !navigator.userAgent.includes('Chrome');

    if (isSafari && currentStatus !== 'idle') {
      // Safari: ALWAYS force reconnect from any non-idle state
      // Connection could be stuck in discovering/connecting/handshaking after suspension
      forceReconnect();
    } else if (currentStatus === 'connected') {
      // Non-Safari: verify connection with ping/pong
      actor.send({ type: 'VISIBILITY_RETURN' });
    } else if (currentStatus === 'gave_up') {
      // Auto-retry on visibility return if we gave up
      actor.send({ type: 'MANUAL_RETRY' });
    }
  } else {
    actor.send({ type: 'VISIBILITY_HIDDEN' });
  }
}

/**
 * Force reconnect (e.g., on network online event)
 */
export function forceReconnect(): void {
  actor.send({ type: 'STOP' });
  clearAllPendingResponses('Forcing reconnect');
  // Small delay then start fresh
  setTimeout(() => {
    actor.send({ type: 'START' });
  }, 200);
}

/**
 * Clean up (call on app unmount)
 */
export function cleanup(): void {
  storeSubscription?.unsubscribe();
  actor.stop();
  clearAllPendingResponses('Cleanup');
}

// =============================================================================
// Export types
// =============================================================================

export type { ConnectionStatus };
