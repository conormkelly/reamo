/**
 * NetworkState - Connection State Machine
 *
 * Handles network hiccups, reconnection, and graceful degradation.
 * Tracks message gaps to detect network issues and escalates through states:
 *
 * OPTIMAL → GOOD → MODERATE → POOR → DEGRADED → RECONNECTING → DISCONNECTED
 *
 * Key behaviors:
 * - Only escalates when transport is playing (silence when stopped is expected)
 * - Prevents runaway prediction during extended outages
 * - Provides exponential backoff for reconnection attempts
 */

export type NetworkStatus =
  | 'OPTIMAL'
  | 'GOOD'
  | 'MODERATE'
  | 'POOR'
  | 'DEGRADED'
  | 'RECONNECTING'
  | 'DISCONNECTED';

export interface NetworkStateCallbacks {
  onStatusChange?: (status: NetworkStatus) => void;
  onReconnectNeeded?: () => void;
}

export class NetworkState {
  public status: NetworkStatus = 'OPTIMAL';

  private lastMessageTime: number;
  private messageGapHistory: number[] = [];
  private consecutiveTimeouts = 0;
  private lastKnownIsPlaying = false;
  private callbacks: NetworkStateCallbacks = {};
  private timeProvider: () => number;

  constructor(
    callbacks?: NetworkStateCallbacks,
    timeProvider?: () => number
  ) {
    this.callbacks = callbacks ?? {};
    this.timeProvider = timeProvider ?? (() => performance.now());
    this.lastMessageTime = this.timeProvider();
  }

  /**
   * Set callbacks after construction.
   */
  setCallbacks(callbacks: NetworkStateCallbacks): void {
    this.callbacks = callbacks;
  }

  /**
   * Call when a message is received.
   */
  onMessage(isPlaying: boolean): void {
    const now = this.timeProvider();
    const gap = now - this.lastMessageTime;
    this.lastMessageTime = now;
    this.lastKnownIsPlaying = isPlaying;

    this.messageGapHistory.push(gap);
    if (this.messageGapHistory.length > 20) this.messageGapHistory.shift();

    this.consecutiveTimeouts = 0;
    this.updateStatus();
  }

  /**
   * Call every frame to check for timeouts.
   */
  tick(): void {
    const now = this.timeProvider();
    const silenceDuration = now - this.lastMessageTime;
    const prevStatus = this.status;

    // Only escalate if we expect messages (transport playing)
    // If stopped, silence is expected
    if (!this.lastKnownIsPlaying && this.status !== 'DISCONNECTED') {
      return;
    }

    if (
      silenceDuration > 500 &&
      this.status !== 'DEGRADED' &&
      this.status !== 'RECONNECTING' &&
      this.status !== 'DISCONNECTED'
    ) {
      this.status = 'DEGRADED';
    }
    if (silenceDuration > 2000 && this.status === 'DEGRADED') {
      this.status = 'RECONNECTING';
      this.consecutiveTimeouts++;
      this.callbacks.onReconnectNeeded?.();
    }
    if (silenceDuration > 10000) {
      this.status = 'DISCONNECTED';
    }

    if (this.status !== prevStatus) {
      this.callbacks.onStatusChange?.(this.status);
    }
  }

  /**
   * Update status based on message gap statistics.
   */
  private updateStatus(): void {
    if (this.messageGapHistory.length < 5) return;

    const avgGap =
      this.messageGapHistory.reduce((a, b) => a + b) / this.messageGapHistory.length;
    const jitter = this.calculateJitter();

    const prevStatus = this.status;

    if (avgGap < 50 && jitter < 20) {
      this.status = 'OPTIMAL';
    } else if (avgGap < 80 && jitter < 30) {
      this.status = 'GOOD';
    } else if (avgGap < 150 && jitter < 50) {
      this.status = 'MODERATE';
    } else {
      this.status = 'POOR';
    }

    if (this.status !== prevStatus) {
      this.callbacks.onStatusChange?.(this.status);
    }
  }

  /**
   * Calculate jitter (standard deviation of message gaps).
   */
  private calculateJitter(): number {
    if (this.messageGapHistory.length < 2) return 0;
    const avg =
      this.messageGapHistory.reduce((a, b) => a + b) / this.messageGapHistory.length;
    const variance =
      this.messageGapHistory.reduce((sum, gap) => sum + Math.pow(gap - avg, 2), 0) /
      this.messageGapHistory.length;
    return Math.sqrt(variance);
  }

  /**
   * Whether prediction should continue during current state.
   * Prevents runaway prediction during extended outages.
   */
  shouldContinuePrediction(): boolean {
    // Continue prediction for up to 2 seconds during dropout
    return this.timeProvider() - this.lastMessageTime < 2000;
  }

  /**
   * Get reconnection delay with exponential backoff + jitter.
   */
  getReconnectDelay(): number {
    const base = 1000;
    const maxDelay = 30000;
    const exponential = Math.min(maxDelay, base * Math.pow(2, this.consecutiveTimeouts));
    const jitter = exponential * 0.1 * Math.random();
    return exponential + jitter;
  }

  /**
   * Reset state after successful reconnection.
   */
  onReconnected(): void {
    this.consecutiveTimeouts = 0;
    this.status = 'OPTIMAL';
    this.messageGapHistory = [];
    this.lastMessageTime = this.timeProvider();
  }

  /**
   * Get metrics for debugging/display.
   */
  getMetrics(): {
    status: NetworkStatus;
    lastMessageAge: number;
    avgGap: number;
    jitter: number;
    consecutiveTimeouts: number;
  } {
    const now = this.timeProvider();
    const avgGap =
      this.messageGapHistory.length > 0
        ? this.messageGapHistory.reduce((a, b) => a + b) / this.messageGapHistory.length
        : 0;

    return {
      status: this.status,
      lastMessageAge: now - this.lastMessageTime,
      avgGap,
      jitter: this.calculateJitter(),
      consecutiveTimeouts: this.consecutiveTimeouts,
    };
  }
}
