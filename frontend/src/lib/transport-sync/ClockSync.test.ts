/**
 * ClockSync Tests
 *
 * Tests for NTP-style clock synchronization.
 * Uses mocked time and network for deterministic testing.
 */

import { describe, it, expect } from 'vitest';
import { ClockSync } from './ClockSync';
import type { TimeProvider } from './types';

// Mock time provider for deterministic tests
function createMockTimeProvider(
  initialTime = 0
): TimeProvider & { advance: (ms: number) => void; setTime: (ms: number) => void; get: () => number } {
  let currentTime = initialTime;
  return {
    now: () => currentTime,
    advance: (ms: number) => {
      currentTime += ms;
    },
    setTime: (ms: number) => {
      currentTime = ms;
    },
    get: () => currentTime,
  };
}

describe('ClockSync', () => {
  describe('startSync and onSyncResponse', () => {
    it('calculates correct offset with symmetric network delay', () => {
      const timeProvider = createMockTimeProvider(1000);
      const serverOffset = 50; // Server clock is 50ms ahead of client
      const networkDelay = 10; // 10ms each way

      let capturedT0 = 0;
      const sendRequest = (t0: number) => {
        capturedT0 = t0;
      };

      const clockSync = new ClockSync(sendRequest, timeProvider);
      clockSync.startSync();

      // Client sent at t0 (1000)
      expect(capturedT0).toBe(1000);

      // Simulate network delay and server processing
      timeProvider.advance(networkDelay * 2 + 0.1);

      // Server times
      const t1 = capturedT0 + networkDelay + serverOffset;
      const t2 = t1 + 0.1;

      const result = clockSync.onSyncResponse(capturedT0, t1, t2);

      // NTP offset formula: ((t1 - t0) + (t2 - t3)) / 2
      // = serverOffset
      expect(result).not.toBeNull();
      expect(result!.offset).toBeCloseTo(serverOffset, 1);

      // RTT = (t3 - t0) - (t2 - t1) = (2*networkDelay + 0.1) - 0.1 = 2*networkDelay
      expect(result!.rtt).toBeCloseTo(networkDelay * 2, 1);
    });

    it('applies offset immediately on first sync (step, not slew)', () => {
      const timeProvider = createMockTimeProvider(1000);
      const serverOffset = 200; // Large offset > 100ms threshold
      const networkDelay = 5;

      let capturedT0 = 0;
      const sendRequest = (t0: number) => {
        capturedT0 = t0;
      };

      const clockSync = new ClockSync(sendRequest, timeProvider);
      clockSync.startSync();

      timeProvider.advance(networkDelay * 2 + 0.1);

      const t1 = capturedT0 + networkDelay + serverOffset;
      const t2 = t1 + 0.1;

      clockSync.onSyncResponse(capturedT0, t1, t2);

      // Should step to the offset immediately on first sync
      expect(clockSync.getOffset()).toBeCloseTo(serverOffset, 1);
    });

    it('rejects stale sync responses', () => {
      const timeProvider = createMockTimeProvider(1000);

      const clockSync = new ClockSync(() => {}, timeProvider);
      clockSync.startSync();

      timeProvider.advance(20);

      // Try to send a response with wrong t0 (differs by more than 1ms tolerance)
      // clockSync sent t0=1000, but we're responding with t0=990
      const result = clockSync.onSyncResponse(990, 1005, 1006);

      // Should reject because t0 doesn't match pending request (1000 vs 990)
      expect(result).toBeNull();
    });

    it('reports isSynced correctly', () => {
      const timeProvider = createMockTimeProvider(1000);

      let capturedT0 = 0;
      const sendRequest = (t0: number) => {
        capturedT0 = t0;
      };

      const clockSync = new ClockSync(sendRequest, timeProvider);

      // Not synced before first sync
      expect(clockSync.isSynced()).toBe(false);

      clockSync.startSync();
      timeProvider.advance(20);

      // Still not synced (waiting for response)
      expect(clockSync.isSynced()).toBe(false);

      clockSync.onSyncResponse(capturedT0, capturedT0 + 10 + 50, capturedT0 + 10.1 + 50);

      // Now synced
      expect(clockSync.isSynced()).toBe(true);
    });
  });

  describe('getSyncedTime', () => {
    it('returns local time plus offset', () => {
      const timeProvider = createMockTimeProvider(1000);
      const serverOffset = 50;
      const networkDelay = 5;

      let capturedT0 = 0;
      const sendRequest = (t0: number) => {
        capturedT0 = t0;
      };

      const clockSync = new ClockSync(sendRequest, timeProvider);
      clockSync.startSync();

      timeProvider.advance(networkDelay * 2 + 0.1);

      const t1 = capturedT0 + networkDelay + serverOffset;
      const t2 = t1 + 0.1;

      clockSync.onSyncResponse(capturedT0, t1, t2);

      // After sync, set time to a known value
      timeProvider.setTime(2000);
      const syncedTime = clockSync.getSyncedTime();

      // Synced time should be local time (2000) + offset (~50)
      expect(syncedTime).toBeCloseTo(2000 + serverOffset, 1);
    });
  });

  describe('tick', () => {
    it('slews gradually for small offset differences within threshold', () => {
      const timeProvider = createMockTimeProvider(1000);

      let capturedT0 = 0;
      let targetOffset = 20;

      const sendRequest = (t0: number) => {
        capturedT0 = t0;
      };

      const clockSync = new ClockSync(sendRequest, timeProvider);

      // First sync with 20ms offset
      clockSync.startSync();
      timeProvider.advance(10);
      clockSync.onSyncResponse(capturedT0, capturedT0 + 5 + targetOffset, capturedT0 + 5.1 + targetOffset);

      const initialOffset = clockSync.getOffset();
      expect(initialOffset).toBeCloseTo(20, 1);

      // Second sync with 30ms offset (10ms difference, within step threshold of 100ms)
      targetOffset = 30;
      timeProvider.advance(100);
      clockSync.startSync();
      timeProvider.advance(10);
      clockSync.onSyncResponse(capturedT0, capturedT0 + 5 + targetOffset, capturedT0 + 5.1 + targetOffset);

      // Since 30-20 = 10ms < 100ms threshold, it should NOT step
      expect(clockSync.getOffset()).toBeCloseTo(20, 1);

      // Now call tick to slew - tick calculates deltaMs internally
      timeProvider.advance(1000); // 1 second for slew calculation
      clockSync.tick();

      // Should have slewed toward 30 (max 0.5ms per second)
      const afterTick = clockSync.getOffset();
      expect(afterTick).toBeGreaterThan(20);
      expect(afterTick).toBeLessThan(30);
    });

    it('steps immediately for large offset differences', () => {
      const timeProvider = createMockTimeProvider(1000);

      let capturedT0 = 0;
      let targetOffset = 20;

      const sendRequest = (t0: number) => {
        capturedT0 = t0;
      };

      const clockSync = new ClockSync(sendRequest, timeProvider);

      // First sync
      clockSync.startSync();
      timeProvider.advance(10);
      clockSync.onSyncResponse(capturedT0, capturedT0 + 5 + targetOffset, capturedT0 + 5.1 + targetOffset);

      expect(clockSync.getOffset()).toBeCloseTo(20, 1);

      // Second sync with 150ms offset (130ms difference, > step threshold of 100ms)
      targetOffset = 150;
      timeProvider.advance(100);
      clockSync.startSync();
      timeProvider.advance(10);
      clockSync.onSyncResponse(capturedT0, capturedT0 + 5 + targetOffset, capturedT0 + 5.1 + targetOffset);

      // Should have stepped immediately
      expect(clockSync.getOffset()).toBeCloseTo(150, 1);
    });
  });

  describe('needsResync', () => {
    it('returns true before first sync', () => {
      const timeProvider = createMockTimeProvider(1000);
      const clockSync = new ClockSync(() => {}, timeProvider);

      expect(clockSync.needsResync()).toBe(true);
    });

    it('returns true when resync interval has passed', () => {
      const timeProvider = createMockTimeProvider(0);

      let capturedT0 = 0;
      const sendRequest = (t0: number) => {
        capturedT0 = t0;
      };

      const clockSync = new ClockSync(sendRequest, timeProvider);
      clockSync.startSync();
      timeProvider.advance(10);
      clockSync.onSyncResponse(capturedT0, capturedT0 + 5, capturedT0 + 5.1);

      // Initially should not need resync
      expect(clockSync.needsResync()).toBe(false);

      // Advance past resync interval (5 minutes)
      timeProvider.advance(5 * 60 * 1000 + 1);

      expect(clockSync.needsResync()).toBe(true);
    });

    it('returns true after invalidate() is called', () => {
      const timeProvider = createMockTimeProvider(1000);

      let capturedT0 = 0;
      const sendRequest = (t0: number) => {
        capturedT0 = t0;
      };

      const clockSync = new ClockSync(sendRequest, timeProvider);
      clockSync.startSync();
      timeProvider.advance(10);
      clockSync.onSyncResponse(capturedT0, capturedT0 + 5, capturedT0 + 5.1);

      expect(clockSync.needsResync()).toBe(false);

      clockSync.invalidate();

      // After invalidate, samples are cleared, so needsResync returns true
      expect(clockSync.needsResync()).toBe(true);
    });
  });

  describe('getMetrics', () => {
    it('returns current sync metrics', () => {
      const timeProvider = createMockTimeProvider(1000);
      const serverOffset = 50;
      const networkDelay = 10;

      let capturedT0 = 0;
      const sendRequest = (t0: number) => {
        capturedT0 = t0;
      };

      const clockSync = new ClockSync(sendRequest, timeProvider);
      clockSync.startSync();

      timeProvider.advance(networkDelay * 2 + 0.1);

      const t1 = capturedT0 + networkDelay + serverOffset;
      const t2 = t1 + 0.1;

      clockSync.onSyncResponse(capturedT0, t1, t2);

      const metrics = clockSync.getMetrics();

      expect(metrics.offset).toBeCloseTo(50, 1);
      expect(metrics.lastRtt).toBeCloseTo(20, 1);
      expect(typeof metrics.estimatedDrift).toBe('number');
    });
  });
});
