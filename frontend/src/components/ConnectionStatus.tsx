/**
 * Connection Status Component
 * Displays the current connection status to REAPER
 */

import type { ReactElement } from 'react';
import { useReaper } from './ReaperProvider';

export interface ConnectionStatusProps {
  className?: string;
  showReconnecting?: boolean;
}

/**
 * Shows connection status indicator
 * When connection gave up, shows a prominent banner with retry button
 */
export function ConnectionStatus({
  className = '',
  showReconnecting = true,
}: ConnectionStatusProps): ReactElement {
  const { connected, errorCount, gaveUp, retry } = useReaper();

  const isReconnecting = !connected && errorCount > 0 && !gaveUp;

  // Show prominent banner when gave up
  if (gaveUp) {
    return (
      <div className={`flex items-center gap-3 px-3 py-2 bg-red-900/80 rounded-lg ${className}`}>
        <div className="w-3 h-3 rounded-full bg-red-500" />
        <span className="text-sm text-red-100">Connection lost</span>
        <button
          onClick={retry}
          className="px-3 py-1 text-xs font-medium text-white bg-red-600 hover:bg-red-500 rounded transition-colors"
        >
          Retry
        </button>
      </div>
    );
  }

  return (
    <div className={`flex items-center gap-2 ${className}`}>
      <div
        className={`w-3 h-3 rounded-full ${
          connected
            ? 'bg-green-500'
            : isReconnecting
              ? 'bg-yellow-500 animate-pulse'
              : 'bg-red-500'
        }`}
      />
      <span className="text-sm">
        {connected
          ? 'Connected'
          : isReconnecting && showReconnecting
            ? `Reconnecting... (${errorCount})`
            : 'Disconnected'}
      </span>
    </div>
  );
}
