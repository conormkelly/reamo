/**
 * REAPER Connection Hook
 * Manages the connection lifecycle and wires responses to the store
 */

import { useEffect, useRef, useCallback } from 'react';
import { ReaperConnection, type ReaperConnectionOptions } from '../core/ReaperConnection';
import { useReaperStore } from '../store';
import * as commands from '../core/CommandBuilder';

export interface UseReaperConnectionOptions {
  /** Base URL for REAPER's HTTP server (default: '') */
  baseUrl?: string;
  /** Auto-start connection on mount (default: true) */
  autoStart?: boolean;
  /** Transport polling interval in ms (default: 30) */
  transportInterval?: number;
  /** Track polling interval in ms (default: 500) */
  trackInterval?: number;
}

export interface UseReaperConnectionReturn {
  /** Whether connected to REAPER */
  connected: boolean;
  /** Current error count */
  errorCount: number;
  /** Start the connection */
  start: () => void;
  /** Stop the connection */
  stop: () => void;
  /** Send a one-time command */
  send: (command: string) => void;
  /** The underlying connection instance */
  connection: ReaperConnection | null;
}

/**
 * Hook to manage the REAPER connection
 */
export function useReaperConnection(
  options: UseReaperConnectionOptions = {}
): UseReaperConnectionReturn {
  const {
    baseUrl = '',
    autoStart = true,
    transportInterval = 30,
    trackInterval = 500,
  } = options;

  const connectionRef = useRef<ReaperConnection | null>(null);
  const startedRef = useRef(false);

  // Get store actions and state
  const handleResponses = useReaperStore((state) => state.handleResponses);
  const updateConnectionStatus = useReaperStore(
    (state) => state.updateConnectionStatus
  );
  const connected = useReaperStore((state) => state.connected);
  const errorCount = useReaperStore((state) => state.errorCount);

  // Initialize connection
  useEffect(() => {
    const connectionOptions: ReaperConnectionOptions = {
      baseUrl,
      onResponse: handleResponses,
      onConnectionChange: updateConnectionStatus,
    };

    connectionRef.current = new ReaperConnection(connectionOptions);

    return () => {
      if (connectionRef.current) {
        connectionRef.current.stop();
        connectionRef.current = null;
      }
      startedRef.current = false;
    };
  }, [baseUrl, handleResponses, updateConnectionStatus]);

  // Start connection
  const start = useCallback(() => {
    if (!connectionRef.current || startedRef.current) return;

    startedRef.current = true;

    // Set up default polling (TRANSPORT + BEATPOS for BPM calculation + metronome/auto-punch state)
    connectionRef.current.poll(
      commands.join(
        commands.transport(),
        commands.beatPos(),
        commands.getCommandState(40364), // Metronome state
        commands.getCommandState(40076)  // Auto-punch state
      ),
      transportInterval
    );
    connectionRef.current.poll(
      commands.join(commands.trackCount(), commands.allTracks()),
      trackInterval
    );
    // Poll regions and markers less frequently (every 2 seconds)
    connectionRef.current.poll(
      commands.join(commands.regions(), commands.markers()),
      2000
    );

    // Start the connection
    connectionRef.current.start();

    // Mark as connected initially (will be updated by actual responses)
    updateConnectionStatus(true, 0);
  }, [transportInterval, trackInterval, updateConnectionStatus]);

  // Stop connection
  const stop = useCallback(() => {
    if (connectionRef.current) {
      connectionRef.current.stop();
      startedRef.current = false;
      updateConnectionStatus(false, 0);
    }
  }, [updateConnectionStatus]);

  // Send command
  const send = useCallback((command: string) => {
    if (connectionRef.current) {
      connectionRef.current.send(command);
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
    errorCount,
    start,
    stop,
    send,
    connection: connectionRef.current,
  };
}
