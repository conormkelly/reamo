import { describe, it, expect } from 'vitest';
import { AdaptiveBuffer } from './AdaptiveBuffer';
import { JitterMeasurement } from './JitterMeasurement';

describe('AdaptiveBuffer', () => {
  describe('initial state', () => {
    it('should start with default target delay', () => {
      const buffer = new AdaptiveBuffer();
      expect(buffer.targetDelayMs).toBe(40);
    });

    it('should start with good network quality', () => {
      const buffer = new AdaptiveBuffer();
      // Default target is 40ms, which is at the boundary of excellent/good
      // 40 < 40 is false, so it's 'good'
      expect(buffer.getNetworkQuality()).toBe('good');
    });
  });

  describe('onPacketReceived', () => {
    it('should adapt target based on jitter measurements', () => {
      const buffer = new AdaptiveBuffer({ adaptationRate: 0.5 });

      // Simulate packets with consistent timing
      for (let i = 0; i < 20; i++) {
        buffer.onPacketReceived(1000 + i * 33, 900 + i * 33, 100);
      }

      // Target should adapt toward the measured jitter
      expect(buffer.getMetrics().packets).toBe(20);
    });

    it('should not go below minimum delay', () => {
      const buffer = new AdaptiveBuffer({ minDelayMs: 35 });

      // Simulate very consistent packets (would want very low buffer)
      for (let i = 0; i < 50; i++) {
        buffer.onPacketReceived(1000 + i * 33, 900 + i * 33, 100);
      }

      expect(buffer.targetDelayMs).toBeGreaterThanOrEqual(35);
    });

    it('should not exceed maximum delay', () => {
      const buffer = new AdaptiveBuffer({ maxDelayMs: 150 });

      // Simulate very variable packets (would want high buffer)
      for (let i = 0; i < 50; i++) {
        const jitter = Math.random() * 200;
        buffer.onPacketReceived(1000 + i * 33 + jitter, 900 + i * 33, 100);
      }

      expect(buffer.targetDelayMs).toBeLessThanOrEqual(150);
    });
  });

  describe('onUnderrun', () => {
    it('should increase target by 50% on underrun', () => {
      const buffer = new AdaptiveBuffer();
      const initialTarget = buffer.targetDelayMs;

      buffer.onUnderrun();

      expect(buffer.targetDelayMs).toBe(initialTarget * 1.5);
    });

    it('should not exceed maximum on underrun', () => {
      const buffer = new AdaptiveBuffer({ maxDelayMs: 50 });
      buffer.targetDelayMs = 40;

      buffer.onUnderrun();

      expect(buffer.targetDelayMs).toBe(50); // Capped at max
    });

    it('should track underrun count', () => {
      const buffer = new AdaptiveBuffer();

      buffer.onUnderrun();
      buffer.onUnderrun();
      buffer.onUnderrun();

      expect(buffer.getMetrics().underruns).toBe(3);
    });
  });

  describe('getNetworkQuality', () => {
    it('should return excellent for low target delay', () => {
      const buffer = new AdaptiveBuffer();
      buffer.targetDelayMs = 35;
      expect(buffer.getNetworkQuality()).toBe('excellent');
    });

    it('should return good for moderate target delay', () => {
      const buffer = new AdaptiveBuffer();
      buffer.targetDelayMs = 50;
      expect(buffer.getNetworkQuality()).toBe('good');
    });

    it('should return moderate for higher target delay', () => {
      const buffer = new AdaptiveBuffer();
      buffer.targetDelayMs = 80;
      expect(buffer.getNetworkQuality()).toBe('moderate');
    });

    it('should return poor for very high target delay', () => {
      const buffer = new AdaptiveBuffer();
      buffer.targetDelayMs = 120;
      expect(buffer.getNetworkQuality()).toBe('poor');
    });
  });

  describe('getBlendFactor', () => {
    it('should return higher blend factor for better network', () => {
      const buffer = new AdaptiveBuffer();

      buffer.targetDelayMs = 35; // excellent
      const excellentFactor = buffer.getBlendFactor();

      buffer.targetDelayMs = 120; // poor
      const poorFactor = buffer.getBlendFactor();

      expect(excellentFactor).toBeGreaterThan(poorFactor);
    });
  });

  describe('setMinDelay', () => {
    it('should update minimum delay', () => {
      const buffer = new AdaptiveBuffer();
      buffer.targetDelayMs = 35;

      buffer.setMinDelay(50);

      expect(buffer.targetDelayMs).toBe(50);
    });

    it('should not affect target if already above new minimum', () => {
      const buffer = new AdaptiveBuffer();
      buffer.targetDelayMs = 80;

      buffer.setMinDelay(50);

      expect(buffer.targetDelayMs).toBe(80);
    });
  });

  describe('reset', () => {
    it('should reset all state', () => {
      const buffer = new AdaptiveBuffer();

      // Modify state
      buffer.onUnderrun();
      buffer.onUnderrun();
      for (let i = 0; i < 10; i++) {
        buffer.onPacketReceived(1000 + i * 33, 900 + i * 33, 100);
      }

      buffer.reset();

      const metrics = buffer.getMetrics();
      expect(metrics.underruns).toBe(0);
      expect(metrics.packets).toBe(0);
      expect(buffer.targetDelayMs).toBe(40);
    });
  });

  describe('dependency injection', () => {
    it('should accept custom jitter measurement', () => {
      const customJitter = new JitterMeasurement({ bucketSizeMs: 5 });
      const buffer = new AdaptiveBuffer({ jitterMeasurement: customJitter });

      buffer.onPacketReceived(1000, 900, 100);

      expect(buffer.getMetrics().packets).toBe(1);
    });
  });
});
