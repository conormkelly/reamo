/**
 * JitterMeasurement - Relative Delay Histogram
 *
 * Measures network jitter using WebRTC NetEQ's algorithm (switched to relative delay in 2022).
 * Tracks how much slower each packet arrives compared to the fastest recent packet.
 *
 * Key insight: We don't care about absolute latency (clock sync handles that).
 * We care about variance - how much packets deviate from the "best case" path.
 */

interface PacketRecord {
  arrivalTime: number;
  expectedTime: number;
  travelTime: number;
}

export class JitterMeasurement {
  private packetHistory: PacketRecord[] = [];
  private histogram = new Map<number, number>(); // bucket -> weight

  // Configuration (WebRTC NetEQ defaults, adjusted for our use case)
  private readonly historyWindowMs: number;
  private readonly bucketSizeMs: number;
  private readonly forgetFactor: number;

  constructor(options?: {
    historyWindowMs?: number;
    bucketSizeMs?: number;
    forgetFactor?: number;
  }) {
    this.historyWindowMs = options?.historyWindowMs ?? 2000;
    this.bucketSizeMs = options?.bucketSizeMs ?? 10; // Finer than WebRTC's 20ms for ±15ms target
    this.forgetFactor = options?.forgetFactor ?? 0.983; // ~175 packets to dominate
  }

  /**
   * Record a packet arrival and update jitter statistics.
   * @param arrivalTime - Local time when packet was received
   * @param serverTime - Server timestamp from packet
   * @param clockOffset - Current clock sync offset
   * @returns Relative delay of this packet (ms)
   */
  addPacket(arrivalTime: number, serverTime: number, clockOffset: number): number {
    const expectedTime = serverTime + clockOffset; // When we expected it
    const travelTime = arrivalTime - expectedTime;

    const packet: PacketRecord = { arrivalTime, expectedTime, travelTime };
    this.packetHistory.push(packet);

    // Trim history to window
    const cutoff = arrivalTime - this.historyWindowMs;
    this.packetHistory = this.packetHistory.filter((p) => p.arrivalTime > cutoff);

    // Find fastest packet (minimum travel time = best case network)
    const fastest = this.packetHistory.reduce((min, p) =>
      p.travelTime < min.travelTime ? p : min
    );

    // Relative delay = how much slower than fastest
    const relativeDelay = Math.max(0, packet.travelTime - fastest.travelTime);

    // Update histogram with exponential forgetting
    for (const [bucket, weight] of this.histogram) {
      this.histogram.set(bucket, weight * this.forgetFactor);
    }
    const bucket = Math.floor(relativeDelay / this.bucketSizeMs);
    const current = this.histogram.get(bucket) || 0;
    this.histogram.set(bucket, current + (1 - this.forgetFactor));

    // Clean up near-zero buckets
    for (const [bucket, weight] of this.histogram) {
      if (weight < 0.001) this.histogram.delete(bucket);
    }

    return relativeDelay;
  }

  /**
   * Get target buffer delay for given quantile.
   * @param quantile - Fraction of packets to arrive in time (0.95 = 95%)
   * @returns Target delay in ms
   */
  getTargetDelay(quantile = 0.95): number {
    if (this.histogram.size === 0) return 40; // Default before data (safe for mobile)

    const sorted = [...this.histogram.entries()].sort((a, b) => a[0] - b[0]);
    const total = sorted.reduce((sum, [, w]) => sum + w, 0);

    if (total === 0) return 30;

    let cumulative = 0;
    for (const [bucket, weight] of sorted) {
      cumulative += weight / total;
      if (cumulative >= quantile) {
        return (bucket + 1) * this.bucketSizeMs;
      }
    }

    return 50; // Fallback
  }

  /**
   * Get current jitter estimate (standard deviation approximation).
   * This is the difference between p95 and p50 - how much variance there is.
   */
  getJitterEstimate(): number {
    return this.getTargetDelay(0.95) - this.getTargetDelay(0.5);
  }

  /**
   * Get metrics for debugging/display.
   */
  getMetrics(): {
    packetCount: number;
    p50: number;
    p95: number;
    jitter: number;
  } {
    return {
      packetCount: this.packetHistory.length,
      p50: this.getTargetDelay(0.5),
      p95: this.getTargetDelay(0.95),
      jitter: this.getJitterEstimate(),
    };
  }

  /**
   * Reset all measurements (e.g., after reconnection).
   */
  reset(): void {
    this.packetHistory = [];
    this.histogram.clear();
  }
}
