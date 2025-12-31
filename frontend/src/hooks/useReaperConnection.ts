/**
 * REAPER WebSocket Connection Hook
 * Manages the WebSocket connection lifecycle and wires messages to the store
 */

import { useEffect, useRef, useCallback, useState } from 'react';
import { WebSocketConnection } from '../core/WebSocketConnection';
import type { ConnectionState } from '../core/WebSocketTypes';
import type { WSCommand } from '../core/WebSocketCommands';
import { useReaperStore } from '../store';
import { transportSyncEngine } from '../core/TransportSyncEngine';

export interface UseReaperConnectionOptions {
  /** WebSocket port (default: 9224) */
  port?: number;
  /** Auth token (optional) */
  token?: string;
  /** Auto-start connection on mount (default: true) */
  autoStart?: boolean;
}

export interface UseReaperConnectionReturn {
  /** Whether connected to REAPER */
  connected: boolean;
  /** Current connection state */
  connectionState: ConnectionState;
  /** Current error count */
  errorCount: number;
  /** Whether we've given up trying to reconnect */
  gaveUp: boolean;
  /** Start the connection */
  start: () => void;
  /** Stop the connection */
  stop: () => void;
  /** Retry connection after giving up */
  retry: () => void;
  /** Send a command (raw) */
  send: (command: string, params?: Record<string, unknown>) => void;
  /** Send a WSCommand object (fire-and-forget) */
  sendCommand: (cmd: WSCommand) => void;
  /** Send a WSCommand object and wait for response */
  sendCommandAsync: (cmd: WSCommand) => Promise<unknown>;
  /** The underlying connection instance */
  connection: WebSocketConnection | null;
}

/**
 * Hook to manage the REAPER WebSocket connection
 */
export function useReaperConnection(
  options: UseReaperConnectionOptions = {}
): UseReaperConnectionReturn {
  const { port = 9224, token, autoStart = true } = options;

  const connectionRef = useRef<WebSocketConnection | null>(null);
  const startedRef = useRef(false);

  // Track gave-up state
  const [gaveUp, setGaveUp] = useState(false);

  // Get store actions and state - use refs to avoid effect re-runs
  const handleWebSocketMessage = useReaperStore(
    (state) => state.handleWebSocketMessage
  );
  const setConnected = useReaperStore((state) => state.setConnected);
  const setErrorCount = useReaperStore((state) => state.setErrorCount);
  const connected = useReaperStore((state) => state.connected);
  const errorCount = useReaperStore((state) => state.errorCount);

  // Store callbacks in refs to avoid triggering effect re-runs
  const handleWebSocketMessageRef = useRef(handleWebSocketMessage);
  const setConnectedRef = useRef(setConnected);
  const setErrorCountRef = useRef(setErrorCount);

  // Keep refs updated
  useEffect(() => {
    handleWebSocketMessageRef.current = handleWebSocketMessage;
    setConnectedRef.current = setConnected;
    setErrorCountRef.current = setErrorCount;
  });

  // Track connection state
  const connectionStateRef = useRef<ConnectionState>('disconnected');

  // Initialize connection - only depends on port/token, not callbacks
  useEffect(() => {
    const connection = new WebSocketConnection({
      port,
      token,
      onStateChange: (state, error) => {
        connectionStateRef.current = state;
        setConnectedRef.current(state === 'connected');
        if (state === 'error') {
          // Increment error count - get current value from store
          const currentCount = useReaperStore.getState().errorCount;
          setErrorCountRef.current(currentCount + 1);
          console.error('[useReaperConnection] Error:', error);
        } else if (state === 'connected') {
          setErrorCountRef.current(0);
          setGaveUp(false); // Reset gave-up state on successful connect
          // Wire up transport sync engine for clock sync
          transportSyncEngine.setSendRaw((msg) => connection.sendRaw(msg));
        } else if (state === 'disconnected') {
          // Clear transport sync engine send function
          transportSyncEngine.clearSendRaw();
        }
      },
      onMessage: (msg) => handleWebSocketMessageRef.current(msg),
      onGaveUp: () => {
        console.log('[useReaperConnection] Connection gave up after max retries');
        setGaveUp(true);
      },
    });

    connectionRef.current = connection;

    return () => {
      connection.stop();
      connectionRef.current = null;
      startedRef.current = false;
    };
  }, [port, token]);

  // Start connection
  const start = useCallback(() => {
    if (!connectionRef.current || startedRef.current) return;
    startedRef.current = true;
    connectionRef.current.start();
  }, []);

  // Stop connection
  const stop = useCallback(() => {
    if (connectionRef.current) {
      connectionRef.current.stop();
      startedRef.current = false;
      setConnected(false);
    }
  }, [setConnected]);

  // Retry connection (after giving up)
  const retry = useCallback(() => {
    if (connectionRef.current) {
      setGaveUp(false);
      connectionRef.current.retry();
    }
  }, []);

  // Send command (raw)
  const send = useCallback(
    (command: string, params?: Record<string, unknown>) => {
      if (connectionRef.current) {
        connectionRef.current.send(command, params);
      }
    },
    []
  );

  // Send WSCommand object (fire-and-forget)
  const sendCommand = useCallback((cmd: WSCommand) => {
    if (connectionRef.current) {
      connectionRef.current.send(cmd.command, cmd.params);
    }
  }, []);

  // Send WSCommand object and wait for response
  const sendCommandAsync = useCallback((cmd: WSCommand): Promise<unknown> => {
    if (connectionRef.current) {
      return connectionRef.current.sendAsync(cmd.command, cmd.params);
    }
    return Promise.reject(new Error('Not connected'));
  }, []);

  // Auto-start if enabled
  useEffect(() => {
    if (autoStart && connectionRef.current && !startedRef.current) {
      start();
    }
  }, [autoStart, start]);

  return {
    connected,
    connectionState: connectionStateRef.current,
    errorCount,
    gaveUp,
    start,
    stop,
    retry,
    send,
    sendCommand,
    sendCommandAsync,
    connection: connectionRef.current,
  };
}
