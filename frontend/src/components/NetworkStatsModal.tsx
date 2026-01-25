/**
 * NetworkStatsModal
 * Shows real-time network/sync stats and advanced settings.
 * Triggered by long-pressing the connection status dot.
 */

import { useState, useEffect, useCallback, type ReactElement } from 'react';
import { RefreshCw, Activity, Wifi, Clock, Gauge } from 'lucide-react';
import { transportSyncEngine } from '../core/TransportSyncEngine';
import type { NetworkQuality, NetworkStatus, ClockSyncMetrics } from '../lib/transport-sync';
import { Modal } from './Modal';

export interface NetworkStatsModalProps {
  isOpen: boolean;
  onClose: () => void;
}

interface DisplayMetrics {
  clock: ClockSyncMetrics;
  network: {
    status: NetworkStatus;
    quality: NetworkQuality;
    jitter: number;
    targetDelay: number;
  };
  isSynced: boolean;
}

// Status colors - OPTIMAL/GOOD/MODERATE are all "working fine"
const STATUS_COLORS: Record<NetworkStatus, string> = {
  OPTIMAL: 'text-network-optimal',
  GOOD: 'text-network-good',
  MODERATE: 'text-network-moderate',  // Still working well
  POOR: 'text-network-poor',          // May notice sync issues
  DEGRADED: 'text-network-degraded',
  RECONNECTING: 'text-network-reconnecting',
  DISCONNECTED: 'text-text-muted',
};

// Quality colors - moderate is normal for WiFi, not a warning
const QUALITY_COLORS: Record<NetworkQuality, string> = {
  excellent: 'text-network-optimal',
  good: 'text-network-good',
  moderate: 'text-network-moderate',  // Normal WiFi - sync still meets ±15ms target
  poor: 'text-network-poor',          // May notice sync issues
};

export function NetworkStatsModal({ isOpen, onClose }: NetworkStatsModalProps): ReactElement | null {
  const [metrics, setMetrics] = useState<DisplayMetrics | null>(null);
  const [manualOffset, setManualOffset] = useState(() => transportSyncEngine.getManualOffset());
  const [isResyncing, setIsResyncing] = useState(false);

  // Load current offset when modal opens
  useEffect(() => {
    if (isOpen) {
      setManualOffset(transportSyncEngine.getManualOffset());
    }
  }, [isOpen]);

  // Poll metrics at 2Hz when modal is open
  useEffect(() => {
    if (!isOpen) return;

    const updateMetrics = () => {
      const extended = transportSyncEngine.getExtendedMetrics();
      setMetrics({
        ...extended,
        isSynced: transportSyncEngine.isSynced(),
      });
    };

    updateMetrics();
    const interval = setInterval(updateMetrics, 500);
    return () => clearInterval(interval);
  }, [isOpen]);

  // Handle force resync
  const handleResync = useCallback(() => {
    setIsResyncing(true);
    transportSyncEngine.resync();
    // Reset after a short delay
    setTimeout(() => setIsResyncing(false), 1500);
  }, []);

  // Handle manual offset change
  const handleOffsetChange = useCallback((value: number) => {
    setManualOffset(value);
    transportSyncEngine.setManualOffset(value);
  }, []);

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title="Network Stats"
      icon={<Activity size={20} className="text-info" />}
    >
      {/* Content */}
      <div className="p-modal space-y-4">
          {/* Status Section */}
          <div className="grid grid-cols-2 gap-3">
            <StatCard
              icon={<Wifi size={16} />}
              label="Status"
              value={metrics?.network.status ?? 'Unknown'}
              valueClassName={STATUS_COLORS[metrics?.network.status ?? 'DISCONNECTED']}
            />
            <StatCard
              icon={<Gauge size={16} />}
              label="Quality"
              value={metrics?.network.quality ?? 'unknown'}
              valueClassName={QUALITY_COLORS[metrics?.network.quality ?? 'poor']}
            />
          </div>

          {/* Timing Stats */}
          <div className="bg-bg-surface/50 rounded-lg p-3 space-y-2">
            <div className="text-xs text-text-secondary uppercase tracking-wide mb-2">
              Timing
            </div>
            <div className="grid grid-cols-2 gap-x-4 gap-y-1.5 text-sm">
              <StatRow label="RTT" value={formatRtt(metrics?.clock.lastRtt)} />
              <StatRow label="Jitter" value={formatMs(metrics?.network.jitter)} />
              <StatRow label="Buffer" value={formatMs(metrics?.network.targetDelay)} />
              <StatRow label="Offset" value={formatMs(metrics?.clock.offset)} signed />
            </div>
          </div>

          {/* Clock Sync Status */}
          <div className="bg-bg-surface/50 rounded-lg p-3">
            <div className="text-xs text-text-secondary uppercase tracking-wide mb-2">
              Clock Sync
            </div>
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-2">
                <Clock size={16} className={metrics?.isSynced ? 'text-network-optimal' : 'text-network-poor'} />
                <span className="text-sm">
                  {metrics?.isSynced ? 'Synchronized' : 'Not synced'}
                </span>
                {metrics?.isSynced && metrics.clock.estimatedDrift !== 0 && (
                  <span className="text-xs text-text-muted">
                    (drift: {formatMs(metrics.clock.estimatedDrift)})
                  </span>
                )}
              </div>
              <button
                onClick={handleResync}
                disabled={isResyncing}
                className="flex items-center gap-1.5 px-2.5 py-1 text-xs font-medium bg-primary hover:bg-primary-hover disabled:bg-primary-active disabled:text-text-secondary rounded transition-colors"
              >
                <RefreshCw size={12} className={isResyncing ? 'animate-spin' : ''} />
                {isResyncing ? 'Syncing...' : 'Resync'}
              </button>
            </div>
          </div>

          {/* Manual Offset */}
          <div className="bg-bg-surface/50 rounded-lg p-3">
            <div className="flex items-center justify-between mb-2">
              <div className="text-xs text-text-secondary uppercase tracking-wide">
                Manual Offset
              </div>
              <span className="text-xs text-text-muted font-mono">
                {manualOffset > 0 ? '+' : ''}{manualOffset}ms
              </span>
            </div>
            <input
              type="range"
              min={-50}
              max={50}
              step={1}
              value={manualOffset}
              onChange={(e) => handleOffsetChange(Number(e.target.value))}
              className="w-full h-1.5 bg-bg-elevated rounded-lg appearance-none cursor-pointer accent-primary-hover"
            />
            <div className="flex justify-between text-xs text-text-disabled mt-1">
              <span>-50ms</span>
              <span className="text-text-muted">Earlier ← → Later</span>
              <span>+50ms</span>
            </div>
          </div>
        </div>

    </Modal>
  );
}

// Helper Components

function StatCard({
  icon,
  label,
  value,
  valueClassName = 'text-text-primary',
}: {
  icon: ReactElement;
  label: string;
  value: string;
  valueClassName?: string;
}) {
  return (
    <div className="bg-bg-surface/50 rounded-lg p-3">
      <div className="flex items-center gap-1.5 text-text-secondary text-xs mb-1">
        {icon}
        {label}
      </div>
      <div className={`text-sm font-medium capitalize ${valueClassName}`}>
        {value}
      </div>
    </div>
  );
}

function StatRow({
  label,
  value,
  signed = false,
}: {
  label: string;
  value: string;
  signed?: boolean;
}) {
  return (
    <>
      <span className="text-text-secondary">{label}</span>
      <span className={`font-mono text-right ${signed ? 'text-info-muted' : 'text-text-primary'}`}>
        {value}
      </span>
    </>
  );
}

function formatMs(value: number | undefined): string {
  if (value === undefined) return '—';
  const absValue = Math.abs(value);
  if (absValue < 10) {
    return `${value.toFixed(1)}ms`;
  }
  return `${Math.round(value)}ms`;
}

/** Format RTT - clamps negative/tiny values to "< 1ms" (Date.now() precision limit) */
function formatRtt(value: number | undefined): string {
  if (value === undefined) return '—';
  if (value < 1) return '< 1ms';
  return formatMs(value);
}
