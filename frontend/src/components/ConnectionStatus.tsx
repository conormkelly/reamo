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
 */
export function ConnectionStatus({
  className = '',
  showReconnecting = true,
}: ConnectionStatusProps): ReactElement {
  const { connected, errorCount } = useReaper();

  const isReconnecting = !connected && errorCount > 0;

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
