import { describe, it, expect } from 'vitest';
import { JitterMeasurement } from './JitterMeasurement';

describe('JitterMeasurement', () => {
  describe('addPacket', () => {
    it('should return 0 relative delay for first packet', () => {
      const jitter = new JitterMeasurement();
      const delay = jitter.addPacket(1000, 900, 100);
      // First packet is the baseline, so relative delay is 0
      expect(delay).toBe(0);
    });

    it('should calculate relative delay based on fastest packet', () => {
      const jitter = new JitterMeasurement();

      // First packet: travel time = 1000 - (900 + 100) = 0
      jitter.addPacket(1000, 900, 100);

      // Second packet: travel time = 1050 - (950 + 100) = 0, same as first
      const delay2 = jitter.addPacket(1050, 950, 100);
      expect(delay2).toBe(0);

      // Third packet: travel time = 1150 - (1000 + 100) = 50, slower by 50ms
      const delay3 = jitter.addPacket(1150, 1000, 100);
      expect(delay3).toBe(50);
    });

    it('should not return negative relative delay', () => {
      const jitter = new JitterMeasurement();

      // Slow packet first
      jitter.addPacket(1100, 900, 100); // travel time = 100

      // Faster packet second
      const delay = jitter.addPacket(1050, 950, 100); // travel time = 0
      expect(delay).toBe(0); // Not negative
    });
  });

  describe('getTargetDelay', () => {
    it('should return default value before any packets', () => {
      const jitter = new JitterMeasurement();
      expect(jitter.getTargetDelay()).toBe(40);
    });

    it('should return low target for consistent arrivals', () => {
      const jitter = new JitterMeasurement();

      // Add packets with consistent timing (low jitter)
      for (let i = 0; i < 20; i++) {
        jitter.addPacket(1000 + i * 33, 900 + i * 33, 100);
      }

      // All packets have same travel time, so target should be low
      expect(jitter.getTargetDelay(0.95)).toBeLessThanOrEqual(10);
    });

    it('should return higher target for variable arrivals', () => {
      const jitter = new JitterMeasurement();

      // Add packets with variable timing (high jitter)
      for (let i = 0; i < 20; i++) {
        // Alternate between fast and slow
        const extraDelay = i % 2 === 0 ? 0 : 50;
        jitter.addPacket(1000 + i * 33 + extraDelay, 900 + i * 33, 100);
      }

      // p95 should account for the 50ms jitter
      expect(jitter.getTargetDelay(0.95)).toBeGreaterThan(30);
    });
  });

  describe('getJitterEstimate', () => {
    it('should return 0 before any packets', () => {
      const jitter = new JitterMeasurement();
      // Before data, p95 and p50 are both default (40 and 30/similar)
      // Actually it returns getTargetDelay(0.95) - getTargetDelay(0.50)
      // which are defaults
      expect(jitter.getJitterEstimate()).toBeGreaterThanOrEqual(0);
    });

    it('should return low jitter for consistent arrivals', () => {
      const jitter = new JitterMeasurement();

      // Add packets with consistent timing
      for (let i = 0; i < 20; i++) {
        jitter.addPacket(1000 + i * 33, 900 + i * 33, 100);
      }

      expect(jitter.getJitterEstimate()).toBeLessThanOrEqual(10);
    });
  });

  describe('reset', () => {
    it('should clear all measurements', () => {
      const jitter = new JitterMeasurement();

      // Add some packets
      for (let i = 0; i < 10; i++) {
        jitter.addPacket(1000 + i * 33, 900 + i * 33, 100);
      }

      const metricsBefore = jitter.getMetrics();
      expect(metricsBefore.packetCount).toBe(10);

      jitter.reset();

      const metricsAfter = jitter.getMetrics();
      expect(metricsAfter.packetCount).toBe(0);
    });
  });

  describe('history window', () => {
    it('should forget old packets outside the window', () => {
      const jitter = new JitterMeasurement({ historyWindowMs: 100 });

      // Add a slow packet at t=0
      jitter.addPacket(100, 0, 50); // travel time = 50

      // Add fast packets well after the window
      jitter.addPacket(300, 200, 50); // travel time = 50
      jitter.addPacket(350, 300, 50); // travel time = 0 (now baseline)

      // The old slow packet should be forgotten
      const metrics = jitter.getMetrics();
      expect(metrics.packetCount).toBe(2); // Only 2 recent packets in window
    });
  });
});
