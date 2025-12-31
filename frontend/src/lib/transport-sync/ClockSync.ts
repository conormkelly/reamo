/**
 * ClockSync - NTP-Style Clock Synchronization
 *
 * Establishes a shared time reference between browser and REAPER.
 * Uses NTP-style algorithm with min-RTT sample selection for accuracy.
 *
 * Supports two modes:
 * 1. Async mode: Call performSync() which handles the full sync flow
 * 2. Callback mode: Call startSync() to send request, then onSyncResponse() when response arrives
 */

import type {
  SyncSample,
  DriftRecord,
  SyncResult,
  ClockSyncMetrics,
  TimeProvider,
} from './types';
import { defaultTimeProvider } from './types';

/** Function type for sending clock sync requests (fire-and-forget) */
export type SendSyncRequest = (t0: number) => void;

export class ClockSync {
  private sendSyncRequest: SendSyncRequest;
  private timeProvider: TimeProvider;

  private offset = 0;
  private targetOffset = 0;
  private samples: SyncSample[] = [];
  private driftHistory: DriftRecord[] = [];
  private lastResyncTime = 0;
  private lastFrameTime = 0;

  // Pending sync state (for callback mode)
  private pendingSyncT0: number | null = null;
  private syncInProgress = false;

  // Configuration
  private readonly resyncIntervalMs = 5 * 60 * 1000; // 5 minutes
  private readonly slewRateMs = 0.5; // Max correction per second
  private readonly driftThresholdMs = 50; // Trigger resync if drift exceeds
  private readonly stepThresholdMs = 100; // Step (don't slew) if offset exceeds

  constructor(
    sendSyncRequest: SendSyncRequest,
    timeProvider: TimeProvider = defaultTimeProvider
  ) {
    this.sendSyncRequest = sendSyncRequest;
    this.timeProvider = timeProvider;
  }

  /**
   * Start a clock sync by sending a request.
   * Call onSyncResponse() when the response arrives.
   */
  startSync(): void {
    if (this.syncInProgress) return;

    const t0 = this.timeProvider.now();
    this.pendingSyncT0 = t0;
    this.syncInProgress = true;
    this.sendSyncRequest(t0);
  }

  /**
   * Handle clock sync response from server.
   * Call this when a clockSyncResponse message is received.
   */
  onSyncResponse(t0: number, t1: number, t2: number): SyncResult | null {
    const t3 = this.timeProvider.now();

    // Validate that this response matches our pending request
    if (this.pendingSyncT0 === null || Math.abs(t0 - this.pendingSyncT0) > 1) {
      // Response doesn't match pending request (stale or unexpected)
      return null;
    }

    this.pendingSyncT0 = null;
    this.syncInProgress = false;

    // NTP formula
    // RTT = (t3 - t0) - (t2 - t1) = total roundtrip minus server processing
    // Offset = ((t1 - t0) + (t2 - t3)) / 2 = average of one-way delays
    const rtt = t3 - t0 - (t2 - t1);
    const offset = ((t1 - t0) + (t2 - t3)) / 2;

    const sample: SyncSample = { rtt, offset, time: t3 };

    // Track drift rate from previous sync
    if (this.samples.length > 0) {
      const lastSample = this.samples[this.samples.length - 1];
      const timeDelta = sample.time - lastSample.time;
      if (timeDelta > 0) {
        const offsetDelta = sample.offset - lastSample.offset;
        const driftPpm = (offsetDelta / timeDelta) * 1e6;
        this.driftHistory.push({ time: sample.time, driftPpm });
        if (this.driftHistory.length > 10) this.driftHistory.shift();
      }
    }

    const isFirstSync = this.samples.length === 0;
    this.targetOffset = sample.offset;
    this.samples.push(sample);
    if (this.samples.length > 16) this.samples.shift();
    this.lastResyncTime = this.timeProvider.now();

    // Always step on first sync, or step for large offset changes
    if (isFirstSync || Math.abs(sample.offset - this.offset) > this.stepThresholdMs) {
      this.offset = sample.offset;
    }

    return {
      offset: sample.offset,
      rtt: sample.rtt,
      accuracy: sample.rtt / 2,
    };
  }

  /**
   * Call every frame to gradually slew toward target offset.
   * Prevents jarring time jumps from small offset corrections.
   */
  tick(): void {
    const now = this.timeProvider.now();
    const deltaMs = this.lastFrameTime > 0 ? now - this.lastFrameTime : 16;
    this.lastFrameTime = now;

    const diff = this.targetOffset - this.offset;

    if (Math.abs(diff) > this.stepThresholdMs) {
      // Large offset: step immediately (initial sync or major drift)
      this.offset = this.targetOffset;
    } else {
      // Small offset: slew gradually
      const maxSlew = (this.slewRateMs * deltaMs) / 1000;
      this.offset += Math.max(-maxSlew, Math.min(maxSlew, diff));
    }

    // Check if resync is needed and start one
    if (this.needsResync() && !this.syncInProgress) {
      this.startSync();
    }
  }

  /**
   * Get synced time (local time + offset).
   */
  getSyncedTime(): number {
    return this.timeProvider.now() + this.offset;
  }

  /**
   * Get current offset in milliseconds.
   */
  getOffset(): number {
    return this.offset;
  }

  /**
   * Check if clock is synchronized (has at least one valid sample).
   */
  isSynced(): boolean {
    return this.samples.length > 0;
  }

  /**
   * Check if resync is needed.
   */
  needsResync(): boolean {
    if (this.samples.length === 0) return true;

    const elapsed = this.timeProvider.now() - this.lastResyncTime;

    // Scheduled resync
    if (elapsed > this.resyncIntervalMs) return true;

    // Drift-triggered resync
    const estimatedDrift = this.getEstimatedDrift();
    if (Math.abs(estimatedDrift) > this.driftThresholdMs) return true;

    return false;
  }

  /**
   * Force a resync on next check (e.g., after page visibility change).
   */
  invalidate(): void {
    this.lastResyncTime = 0;
    this.samples = [];
  }

  /**
   * Clean up resources.
   */
  destroy(): void {
    this.samples = [];
    this.driftHistory = [];
    this.pendingSyncT0 = null;
    this.syncInProgress = false;
  }

  /**
   * Estimate accumulated drift since last sync based on measured drift rate.
   */
  private getEstimatedDrift(): number {
    if (this.driftHistory.length < 2) return 0;
    const recent = this.driftHistory.slice(-5);
    const avgPpm = recent.reduce((sum, d) => sum + d.driftPpm, 0) / recent.length;
    const elapsed = this.timeProvider.now() - this.lastResyncTime;
    return (avgPpm * elapsed) / 1e6;
  }

  /**
   * Get current sync quality metrics for debugging/display.
   */
  getMetrics(): ClockSyncMetrics {
    const lastSample = this.samples[this.samples.length - 1];
    return {
      offset: this.offset,
      lastRtt: lastSample?.rtt ?? 0,
      estimatedDrift: this.getEstimatedDrift(),
    };
  }
}
