/**
 * REAPER WebSocket Connection Hook
 * Manages the WebSocket connection lifecycle and wires messages to the store
 */

import { useEffect, useRef, useCallback } from 'react';
import { WebSocketConnection } from '../core/WebSocketConnection';
import type { ConnectionState } from '../core/WebSocketTypes';
import type { WSCommand } from '../core/WebSocketCommands';
import { useReaperStore } from '../store';

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
  /** Start the connection */
  start: () => void;
  /** Stop the connection */
  stop: () => void;
  /** Send a command (raw) */
  send: (command: string, params?: Record<string, unknown>) => void;
  /** Send a WSCommand object */
  sendCommand: (cmd: WSCommand) => void;
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

  // Get store actions and state
  const handleWebSocketMessage = useReaperStore(
    (state) => state.handleWebSocketMessage
  );
  const setConnected = useReaperStore((state) => state.setConnected);
  const setErrorCount = useReaperStore((state) => state.setErrorCount);
  const connected = useReaperStore((state) => state.connected);
  const errorCount = useReaperStore((state) => state.errorCount);

  // Track connection state
  const connectionStateRef = useRef<ConnectionState>('disconnected');

  // Initialize connection
  useEffect(() => {
    const connection = new WebSocketConnection({
      port,
      token,
      onStateChange: (state, error) => {
        connectionStateRef.current = state;
        setConnected(state === 'connected');
        if (state === 'error') {
          // Increment error count - get current value from store
          const currentCount = useReaperStore.getState().errorCount;
          setErrorCount(currentCount + 1);
          console.error('[useReaperConnection] Error:', error);
        } else if (state === 'connected') {
          setErrorCount(0);
        }
      },
      onMessage: handleWebSocketMessage,
    });

    connectionRef.current = connection;

    return () => {
      connection.stop();
      connectionRef.current = null;
      startedRef.current = false;
    };
  }, [port, token, handleWebSocketMessage, setConnected, setErrorCount]);

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

  // Send command (raw)
  const send = useCallback(
    (command: string, params?: Record<string, unknown>) => {
      if (connectionRef.current) {
        connectionRef.current.send(command, params);
      }
    },
    []
  );

  // Send WSCommand object
  const sendCommand = useCallback((cmd: WSCommand) => {
    if (connectionRef.current) {
      connectionRef.current.send(cmd.command, cmd.params);
    }
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
    start,
    stop,
    send,
    sendCommand,
    connection: connectionRef.current,
  };
}
