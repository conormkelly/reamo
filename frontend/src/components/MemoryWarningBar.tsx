/**
 * MemoryWarningBar Component
 * Shows a dismissable warning when arena memory utilization is high (> 80%)
 * Includes Info button to show detailed memory stats and explanation
 */

import { useState, useCallback, type ReactElement } from 'react';
import { AlertTriangle, Info, X } from 'lucide-react';
import { useReaperStore } from '../store';
import { useReaper } from './ReaperProvider';

interface MemoryStats {
  high: { used: number; capacity: number; peak: number; utilization: number };
  medium: { used: number; capacity: number; peak: number; utilization: number };
  low: { used: number; capacity: number; peak: number; utilization: number };
  scratch: { used: number; capacity: number };
  total: { allocated: number; allocatedMB: number };
  frameCount: number;
}

export interface MemoryWarningBarProps {
  className?: string;
}

export function MemoryWarningBar({ className = '' }: MemoryWarningBarProps): ReactElement | null {
  const { memoryWarning, memoryWarningDismissed, dismissMemoryWarning } = useReaperStore();
  const { sendAsync, connected } = useReaper();
  const [showModal, setShowModal] = useState(false);
  const [stats, setStats] = useState<MemoryStats | null>(null);
  const [statsLoading, setStatsLoading] = useState(false);

  const handleInfo = useCallback(async () => {
    if (!connected) return;

    setShowModal(true);
    setStatsLoading(true);

    try {
      const response = await sendAsync('debug/memoryStats', {}) as {
        success: boolean;
        payload?: MemoryStats;
      };
      if (response.success && response.payload) {
        setStats(response.payload);
      }
    } catch {
      // Failed to fetch stats
    } finally {
      setStatsLoading(false);
    }
  }, [connected, sendAsync]);

  const handleDismiss = useCallback(() => {
    dismissMemoryWarning();
  }, [dismissMemoryWarning]);

  const handleCloseModal = useCallback(() => {
    setShowModal(false);
  }, []);

  // Don't show if no warning or already dismissed
  if (!memoryWarning || memoryWarningDismissed) {
    return null;
  }

  const formatBytes = (bytes: number): string => {
    if (bytes >= 1024 * 1024) {
      return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
    }
    return `${(bytes / 1024).toFixed(0)} KB`;
  };

  return (
    <>
      <div
        data-testid="memory-warning-bar"
        className={`flex items-center justify-center gap-3 px-4 py-2 bg-memory-warning-bg ${className}`}
      >
        <AlertTriangle size={16} className="text-memory-warning-icon flex-shrink-0" />
        <span className="text-sm text-memory-warning-text">
          REAmo memory usage is high
        </span>
        <button
          onClick={handleInfo}
          className="flex items-center gap-1.5 px-3 py-1 text-xs font-medium text-white bg-memory-warning-btn hover:bg-memory-warning-btn-hover rounded transition-colors"
        >
          <Info size={12} />
          Info
        </button>
        <button
          onClick={handleDismiss}
          className="flex items-center gap-1.5 px-3 py-1 text-xs font-medium text-text-primary bg-bg-hover hover:bg-bg-disabled rounded transition-colors"
        >
          <X size={12} />
          Dismiss
        </button>
      </div>

      {/* Info Modal */}
      {showModal && (
        <div
          className="fixed inset-0 bg-black/70 flex items-center justify-center z-modal"
          onClick={handleCloseModal}
        >
          <div
            className="bg-bg-surface rounded-lg p-6 max-w-md mx-4 shadow-xl"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="flex items-center gap-2 mb-4">
              <AlertTriangle size={20} className="text-memory-warning-icon" />
              <h2 className="text-lg font-semibold text-text-primary">Memory Usage Warning</h2>
            </div>

            {statsLoading ? (
              <p className="text-text-secondary">Loading memory stats...</p>
            ) : stats ? (
              <div className="space-y-4">
                <div className="text-sm text-text-tertiary space-y-2">
                  <div className="grid grid-cols-2 gap-x-4 gap-y-1 font-mono text-xs bg-bg-deep p-3 rounded">
                    <span className="text-text-muted">HIGH tier:</span>
                    <span>{stats.high.utilization.toFixed(1)}% ({formatBytes(stats.high.peak)} peak)</span>
                    <span className="text-text-muted">MEDIUM tier:</span>
                    <span>{stats.medium.utilization.toFixed(1)}% ({formatBytes(stats.medium.peak)} peak)</span>
                    <span className="text-text-muted">LOW tier:</span>
                    <span>{stats.low.utilization.toFixed(1)}% ({formatBytes(stats.low.peak)} peak)</span>
                    <span className="text-text-muted">Total allocated:</span>
                    <span>{stats.total.allocatedMB.toFixed(1)} MB</span>
                  </div>
                </div>

                <p className="text-sm text-text-secondary">
                  Memory is reserved when your project loads for performance reasons.
                  If you&apos;ve added many tracks, items, or FX since loading, some data
                  may not be visible in REAmo.
                </p>

                <p className="text-sm text-text-secondary">
                  <strong className="text-text-tertiary">To resolve:</strong> Save your project and restart REAPER.
                  Or you can dismiss this warning and continue working.
                </p>
              </div>
            ) : (
              <p className="text-text-secondary">Unable to load memory stats.</p>
            )}

            <div className="mt-6 flex justify-end">
              <button
                onClick={handleCloseModal}
                className="px-4 py-2 text-sm font-medium text-text-primary bg-bg-hover hover:bg-bg-disabled rounded transition-colors"
              >
                Close
              </button>
            </div>
          </div>
        </div>
      )}
    </>
  );
}
