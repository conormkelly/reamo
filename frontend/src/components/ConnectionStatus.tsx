/**
 * Connection Status Components
 * - ConnectionStatus: Minimal dot that reflects network quality
 *   Long-press opens NetworkStatsModal with real-time metrics
 * - ConnectionBanner: Full-width banner when disconnected/error
 */

import { useState, useEffect, useCallback, type ReactElement } from 'react';
import { Wifi, WifiOff, RefreshCw } from 'lucide-react';
import { useReaper } from './ReaperProvider';
import { transportSyncEngine } from '../core/TransportSyncEngine';
import { NetworkStatsModal } from './NetworkStatsModal';
import type { NetworkQuality } from '../lib/transport-sync';

// Grace period before showing banner on initial connection
// PWA cold start: bundle parse (1-2s) + 200ms init delay + EXTSTATE fetch + WebSocket handshake
// User expects loading screen for at least 2 seconds
const INITIAL_CONNECT_GRACE_MS = 2500;

// Network quality colors - moderate is still green because sync works fine on typical WiFi
const QUALITY_COLORS: Record<NetworkQuality, string> = {
  excellent: 'bg-green-500',
  good: 'bg-green-400',
  moderate: 'bg-green-300',  // Normal WiFi conditions - sync still meets ±15ms target
  poor: 'bg-yellow-500',     // May notice sync issues
};

const QUALITY_TITLES: Record<NetworkQuality, string> = {
  excellent: 'Connected - Excellent',
  good: 'Connected - Good',
  moderate: 'Connected',  // Don't alarm users - this is normal for WiFi
  poor: 'Connected - High latency',
};

export interface ConnectionStatusProps {
  className?: string;
}

/**
 * Minimal connection indicator - just a dot
 * Color reflects network quality when connected:
 * - Green (bright): excellent
 * - Green: good
 * - Green (light): moderate (normal WiFi - sync still works)
 * - Yellow: poor (may notice sync issues)
 *
 * Long-press to open Network Stats modal with real-time metrics
 */
export function ConnectionStatus({ className = '' }: ConnectionStatusProps): ReactElement | null {
  const { connected, errorCount, gaveUp } = useReaper();
  const [networkQuality, setNetworkQuality] = useState<NetworkQuality>('excellent');
  const [isModalOpen, setIsModalOpen] = useState(false);
  const [pressTimer, setPressTimer] = useState<ReturnType<typeof setTimeout> | null>(null);

  // Poll network quality when connected
  useEffect(() => {
    if (!connected) return;

    const updateQuality = () => {
      setNetworkQuality(transportSyncEngine.getNetworkQuality());
    };

    // Initial update
    updateQuality();

    // Poll every 500ms (network quality doesn't change that fast)
    const interval = setInterval(updateQuality, 500);
    return () => clearInterval(interval);
  }, [connected]);

  // Long press handling - opens stats modal
  const handlePointerDown = useCallback(() => {
    const timer = setTimeout(() => {
      setIsModalOpen(true);
      setPressTimer(null);
    }, 500);
    setPressTimer(timer);
  }, []);

  const handlePointerUp = useCallback(() => {
    if (pressTimer) {
      clearTimeout(pressTimer);
      setPressTimer(null);
    }
  }, [pressTimer]);

  const handleCloseModal = useCallback(() => {
    setIsModalOpen(false);
  }, []);

  const isReconnecting = !connected && errorCount > 0 && !gaveUp;

  // Hide when disconnected/gave up - banner will show instead
  if (gaveUp || (!connected && !isReconnecting)) {
    return null;
  }

  return (
    <>
      <div
        className={`flex items-center cursor-pointer select-none ${className}`}
        title={connected ? `${QUALITY_TITLES[networkQuality]} (hold for stats)` : 'Reconnecting...'}
        onPointerDown={handlePointerDown}
        onPointerUp={handlePointerUp}
        onPointerCancel={handlePointerUp}
        onPointerLeave={handlePointerUp}
      >
        <div
          className={`w-2.5 h-2.5 rounded-full ${
            connected
              ? QUALITY_COLORS[networkQuality]
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

      {/* Network stats modal */}
      <NetworkStatsModal isOpen={isModalOpen} onClose={handleCloseModal} />
    </>
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
    <div
      data-testid="connection-banner"
      role="status"
      aria-live="polite"
      aria-atomic="true"
      className={`flex items-center justify-center gap-3 px-4 py-2 ${
        gaveUp ? 'bg-red-900/90' : 'bg-yellow-900/90'
      } ${className}`}
    >
      {gaveUp ? (
        <WifiOff size={16} className="text-red-400" aria-hidden="true" />
      ) : (
        <Wifi size={16} className="text-yellow-400 animate-pulse" aria-hidden="true" />
      )}
      <span className="text-sm">
        {gaveUp
          ? 'Connection lost'
          : isReconnecting
            ? `Reconnecting... (attempt ${errorCount})`
            : 'Connecting...'}
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
