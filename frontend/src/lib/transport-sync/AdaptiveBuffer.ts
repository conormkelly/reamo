/**
 * AdaptiveBuffer - Buffer Sizing Algorithm
 *
 * Dynamically sizes the jitter buffer based on network conditions.
 * Uses "fast up, slow down" pattern:
 * - Quickly increases buffer on underruns (packet arrived late)
 * - Slowly decreases buffer when network is stable
 *
 * Floor of 35ms handles iOS Low-Power Mode (30fps = 33ms frames).
 * Ceiling of 150ms prevents "laggy" feeling.
 */

import { JitterMeasurement } from './JitterMeasurement';

export type NetworkQuality = 'excellent' | 'good' | 'moderate' | 'poor';

export class AdaptiveBuffer {
  public targetDelayMs = 40; // Current target

  private minDelayMs: number;
  private readonly maxDelayMs: number;
  private readonly adaptationRate: number;

  private jitterMeasurement: JitterMeasurement;
  private underrunCount = 0;
  private packetCount = 0;

  constructor(options?: {
    minDelayMs?: number;
    maxDelayMs?: number;
    adaptationRate?: number;
    jitterMeasurement?: JitterMeasurement;
  }) {
    this.minDelayMs = options?.minDelayMs ?? 35; // Floor: iOS Low-Power Mode = 30fps (33ms frames)
    this.maxDelayMs = options?.maxDelayMs ?? 150; // Ceiling: beyond feels "laggy"
    this.adaptationRate = options?.adaptationRate ?? 0.1; // Slow down rate
    this.jitterMeasurement = options?.jitterMeasurement ?? new JitterMeasurement();
  }

  /**
   * Process incoming packet and update buffer target.
   */
  onPacketReceived(arrivalTime: number, serverTime: number, clockOffset: number): void {
    this.packetCount++;
    this.jitterMeasurement.addPacket(arrivalTime, serverTime, clockOffset);

    const measuredTarget = this.jitterMeasurement.getTargetDelay(0.95);

    // Smooth adaptation toward measured target (slow down)
    this.targetDelayMs += (measuredTarget - this.targetDelayMs) * this.adaptationRate;

    // Apply floor/ceiling
    this.targetDelayMs = Math.max(this.minDelayMs, Math.min(this.maxDelayMs, this.targetDelayMs));
  }

  /**
   * Call when buffer underrun occurs (prediction had to fill gap).
   * Fast increase to prevent repeated underruns.
   */
  onUnderrun(): void {
    this.underrunCount++;
    // Immediate 50% increase on underrun (fast up, slow down pattern)
    this.targetDelayMs = Math.min(this.maxDelayMs, this.targetDelayMs * 1.5);
  }

  /**
   * Get human-readable network quality assessment.
   */
  getNetworkQuality(): NetworkQuality {
    if (this.targetDelayMs < 40) return 'excellent';
    if (this.targetDelayMs < 60) return 'good';
    if (this.targetDelayMs < 100) return 'moderate';
    return 'poor';
  }

  /**
   * Get blend factor appropriate for current network quality.
   * Lower = smoother but slower correction; higher = snappier but shows jitter.
   */
  getBlendFactor(): number {
    const quality = this.getNetworkQuality();
    switch (quality) {
      case 'excellent':
        return 0.15;
      case 'good':
        return 0.12;
      case 'moderate':
        return 0.1;
      case 'poor':
        return 0.08;
    }
  }

  /**
   * Set minimum delay floor (e.g., when power-saving mode detected).
   */
  setMinDelay(minMs: number): void {
    this.minDelayMs = minMs;
    if (this.targetDelayMs < minMs) {
      this.targetDelayMs = minMs;
    }
  }

  /**
   * Get metrics for debugging/display.
   */
  getMetrics(): {
    targetDelay: number;
    jitter: number;
    quality: NetworkQuality;
    underruns: number;
    packets: number;
  } {
    return {
      targetDelay: this.targetDelayMs,
      jitter: this.jitterMeasurement.getJitterEstimate(),
      quality: this.getNetworkQuality(),
      underruns: this.underrunCount,
      packets: this.packetCount,
    };
  }

  /**
   * Reset all measurements (e.g., after reconnection).
   */
  reset(): void {
    this.targetDelayMs = 40;
    this.underrunCount = 0;
    this.packetCount = 0;
    this.jitterMeasurement.reset();
  }
}
