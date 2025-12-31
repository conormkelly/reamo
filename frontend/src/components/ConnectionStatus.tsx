/**
 * Connection Status Components
 * - ConnectionDot: Minimal green dot when connected
 * - ConnectionBanner: Full-width banner when disconnected/error
 */

import { useState, useEffect, type ReactElement } from 'react';
import { Wifi, WifiOff, RefreshCw } from 'lucide-react';
import { useReaper } from './ReaperProvider';

// Grace period before showing banner on initial connection
const INITIAL_CONNECT_GRACE_MS = 250;

export interface ConnectionStatusProps {
  className?: string;
}

/**
 * Minimal connection indicator - just a dot
 * Green when connected, yellow/orange alternating when reconnecting
 */
export function ConnectionStatus({ className = '' }: ConnectionStatusProps): ReactElement | null {
  const { connected, errorCount, gaveUp } = useReaper();

  const isReconnecting = !connected && errorCount > 0 && !gaveUp;

  // Hide when disconnected/gave up - banner will show instead
  if (gaveUp || (!connected && !isReconnecting)) {
    return null;
  }

  return (
    <div className={`flex items-center ${className}`} title={connected ? 'Connected' : 'Reconnecting...'}>
      <div
        className={`w-2.5 h-2.5 rounded-full ${
          connected
            ? 'bg-green-500'
            : 'animate-connection-pulse'
        }`}
        style={!connected ? {
          animation: 'connection-pulse 1s ease-in-out infinite',
        } : undefined}
      />
      <style>{`
        @keyframes connection-pulse {
          0%, 100% { background-color: #eab308; }
          50% { background-color: #f97316; }
        }
      `}</style>
    </div>
  );
}

export interface ConnectionBannerProps {
  className?: string;
}

/**
 * Full-width banner shown when connection is lost
 * Includes reconnect button
 * Has a grace period on initial load to avoid flashing during normal connection
 */
export function ConnectionBanner({ className = '' }: ConnectionBannerProps): ReactElement | null {
  const { connected, errorCount, gaveUp, retry } = useReaper();
  const [gracePeriodOver, setGracePeriodOver] = useState(false);
  const [wasEverConnected, setWasEverConnected] = useState(false);

  // Track if we've ever been connected
  useEffect(() => {
    if (connected) {
      setWasEverConnected(true);
    }
  }, [connected]);

  // Start grace period timer on mount
  useEffect(() => {
    const timer = setTimeout(() => {
      setGracePeriodOver(true);
    }, INITIAL_CONNECT_GRACE_MS);
    return () => clearTimeout(timer);
  }, []);

  const isReconnecting = !connected && errorCount > 0 && !gaveUp;

  // Only show when there's a problem
  if (connected) {
    return null;
  }

  // During grace period on initial load, don't show banner unless we previously connected
  if (!gracePeriodOver && !wasEverConnected && !gaveUp) {
    return null;
  }

  return (
    <div className={`flex items-center justify-center gap-3 px-4 py-2 ${
      gaveUp ? 'bg-red-900/90' : 'bg-yellow-900/90'
    } ${className}`}>
      {gaveUp ? (
        <WifiOff size={16} className="text-red-400" />
      ) : (
        <Wifi size={16} className="text-yellow-400 animate-pulse" />
      )}
      <span className="text-sm">
        {gaveUp
          ? 'Connection lost'
          : isReconnecting
            ? `Reconnecting... (attempt ${errorCount})`
            : 'Disconnected'}
      </span>
      {gaveUp && (
        <button
          onClick={retry}
          className="flex items-center gap-1.5 px-3 py-1 text-xs font-medium text-white bg-red-600 hover:bg-red-500 rounded transition-colors"
        >
          <RefreshCw size={12} />
          Reconnect
        </button>
      )}
    </div>
  );
}
