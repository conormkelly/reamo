/**
 * REAPER WebSocket Connection Hook
 * Manages the WebSocket connection lifecycle via XState actor
 *
 * @example
 * ```tsx
 * // Usually accessed via useReaper() from ReaperProvider context:
 * const { sendCommand, sendCommandAsync, connected } = useReaper();
 *
 * // Direct usage (rare - only in ReaperProvider):
 * const connection = useReaperConnection({ autoStart: true });
 * ```
 */

import { useEffect, useCallback, useRef } from 'react';
import type { WSCommand } from '../core/WebSocketCommands';
import type { ConnectionStatus } from '../core/websocketMachine';
import {
  start as actorStart,
  stop as actorStop,
  retry as actorRetry,
  sendCommand as actorSendCommand,
  sendCommandAsync as actorSendCommandAsync,
  sendRaw as actorSendRaw,
  handleVisibilityChange as actorHandleVisibility,
  forceReconnect as actorForceReconnect,
  isConnected,
} from '../core/websocketActor';
import { useReaperStore, parseActionResponse } from '../store';
import { transportSyncEngine } from '../core/TransportSyncEngine';

/**
 * Fetch and cache REAPER actions on connect.
 * This runs during the splash screen to populate the action search cache.
 */
async function fetchActionCache(): Promise<void> {
  const store = useReaperStore.getState();

  // Don't refetch if already loaded (reconnect scenario)
  if (store.actionCache.length > 0) {
    console.log('[useReaperConnection] Action cache already populated, skipping fetch');
    return;
  }

  store.setActionCacheLoading(true);
  console.log('[useReaperConnection] Fetching action cache...');

  try {
    const response = await actorSendCommandAsync('action/getActions', {}) as {
      success?: boolean;
      payload?: unknown;
      error?: string;
    };

    if (response.success && response.payload) {
      const actions = parseActionResponse(response.payload);
      store.setActionCache(actions);
      console.log(`[useReaperConnection] Action cache loaded: ${actions.length} actions`);
    } else {
      store.setActionCacheError(response.error ?? 'Unknown error fetching actions');
      console.error('[useReaperConnection] Failed to fetch actions:', response.error);
    }
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Unknown error';
    store.setActionCacheError(message);
    console.error('[useReaperConnection] Error fetching action cache:', err);
  }
}

export interface UseReaperConnectionOptions {
  /** Auto-start connection on mount (default: true) */
  autoStart?: boolean;
}

export interface UseReaperConnectionReturn {
  /** Whether connected to REAPER */
  connected: boolean;
  /** Current connection status (full state machine status) */
  connectionStatus: ConnectionStatus;
  /** Current error count */
  errorCount: number;
  /** Current retry count */
  retryCount: number;
  /** Whether we've given up trying to reconnect */
  gaveUp: boolean;
  /** Start the connection */
  start: () => void;
  /** Stop the connection */
  stop: () => void;
  /** Retry connection after giving up */
  retry: () => void;
  /** Send a command (raw, fire-and-forget) */
  send: (command: string, params?: Record<string, unknown>) => void;
  /** Send a WSCommand object (fire-and-forget) */
  sendCommand: (cmd: WSCommand) => void;
  /** Send a WSCommand object and wait for response */
  sendCommandAsync: (cmd: WSCommand) => Promise<unknown>;
  /** Send a command and wait for response (raw API) */
  sendAsync: (command: string, params?: Record<string, unknown>) => Promise<unknown>;
}

/**
 * Hook to manage the REAPER WebSocket connection
 * Wraps the XState actor for React lifecycle management
 */
export function useReaperConnection(
  options: UseReaperConnectionOptions = {}
): UseReaperConnectionReturn {
  const { autoStart = true } = options;

  const startedRef = useRef(false);
  const prevConnectedRef = useRef(false);

  // Get store state
  const connected = useReaperStore((state) => state.connected);
  const connectionStatus = useReaperStore((state) => state.connectionStatus);
  const errorCount = useReaperStore((state) => state.errorCount);
  const retryCount = useReaperStore((state) => state.retryCount);

  // Computed state
  const gaveUp = connectionStatus === 'gave_up';

  // Handle connection state changes (for transport sync and action cache)
  useEffect(() => {
    if (connected && !prevConnectedRef.current) {
      // Just connected
      console.log('[useReaperConnection] Connected - setting up transport sync');
      transportSyncEngine.setSendRaw(actorSendRaw);
      transportSyncEngine.resync();
      fetchActionCache();
    } else if (!connected && prevConnectedRef.current) {
      // Just disconnected
      console.log('[useReaperConnection] Disconnected - clearing transport sync');
      transportSyncEngine.clearSendRaw();
    }
    prevConnectedRef.current = connected;
  }, [connected]);

  // Start connection on mount if autoStart
  useEffect(() => {
    if (autoStart && !startedRef.current) {
      console.log('[useReaperConnection] Auto-starting connection');
      startedRef.current = true;
      actorStart();
    }

    return () => {
      // Don't stop on unmount - actor persists across component lifecycle
      // The actor is a singleton that should keep running
    };
  }, [autoStart]);

  // Handle visibility change
  useEffect(() => {
    const handleVisibilityChange = () => {
      const isVisible = document.visibilityState === 'visible';
      actorHandleVisibility(isVisible);

      // Also resync clock if visible and connected
      if (isVisible && isConnected()) {
        transportSyncEngine.resync();
        transportSyncEngine.onReconnected();
      }
    };

    document.addEventListener('visibilitychange', handleVisibilityChange);
    return () => document.removeEventListener('visibilitychange', handleVisibilityChange);
  }, []);

  // Handle online/offline events
  useEffect(() => {
    const handleOnline = () => {
      console.log('[useReaperConnection] Network online, forcing reconnect');
      actorForceReconnect();
    };

    const handleOffline = () => {
      console.log('[useReaperConnection] Network offline');
      actorHandleVisibility(false);
    };

    window.addEventListener('online', handleOnline);
    window.addEventListener('offline', handleOffline);

    return () => {
      window.removeEventListener('online', handleOnline);
      window.removeEventListener('offline', handleOffline);
    };
  }, []);

  // Start connection
  const start = useCallback(() => {
    if (!startedRef.current) {
      startedRef.current = true;
      actorStart();
    }
  }, []);

  // Stop connection
  const stop = useCallback(() => {
    actorStop();
    startedRef.current = false;
  }, []);

  // Retry connection
  const retry = useCallback(() => {
    actorRetry();
  }, []);

  // Send command (raw)
  const send = useCallback(
    (command: string, params?: Record<string, unknown>) => {
      actorSendCommand(command, params);
    },
    []
  );

  // Send WSCommand object (fire-and-forget)
  const sendCommand = useCallback((cmd: WSCommand) => {
    actorSendCommand(cmd.command, cmd.params);
  }, []);

  // Send WSCommand object and wait for response
  const sendCommandAsync = useCallback((cmd: WSCommand): Promise<unknown> => {
    return actorSendCommandAsync(cmd.command, cmd.params);
  }, []);

  // Send a command and wait for response (raw API)
  const sendAsync = useCallback(
    (command: string, params?: Record<string, unknown>): Promise<unknown> => {
      return actorSendCommandAsync(command, params);
    },
    []
  );

  return {
    connected,
    connectionStatus,
    errorCount,
    retryCount,
    gaveUp,
    start,
    stop,
    retry,
    send,
    sendCommand,
    sendCommandAsync,
    sendAsync,
  };
}
