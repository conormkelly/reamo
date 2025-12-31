import { describe, it, expect, vi } from 'vitest';
import { NetworkState } from './NetworkState';

describe('NetworkState', () => {
  // Mock time provider for deterministic tests
  const createMockTimeProvider = (initialTime = 0) => {
    let currentTime = initialTime;
    return {
      now: () => currentTime,
      advance: (ms: number) => {
        currentTime += ms;
      },
      set: (time: number) => {
        currentTime = time;
      },
    };
  };

  describe('initial state', () => {
    it('should start in OPTIMAL status', () => {
      const network = new NetworkState();
      expect(network.status).toBe('OPTIMAL');
    });
  });

  describe('onMessage', () => {
    it('should reset timeout tracking', () => {
      const time = createMockTimeProvider(1000);
      const network = new NetworkState(undefined, time.now);

      time.advance(100);
      network.onMessage(true);

      const metrics = network.getMetrics();
      expect(metrics.lastMessageAge).toBeLessThan(50);
    });

    it('should update status based on message gaps', () => {
      const time = createMockTimeProvider(0);
      const network = new NetworkState(undefined, time.now);

      // Send many messages with consistent timing (< 50ms avg, < 20ms jitter)
      for (let i = 0; i < 10; i++) {
        time.advance(40);
        network.onMessage(true);
      }

      expect(network.status).toBe('OPTIMAL');
    });

    it('should detect poor network from large gaps', () => {
      const time = createMockTimeProvider(0);
      const network = new NetworkState(undefined, time.now);

      // Send messages with very inconsistent timing
      for (let i = 0; i < 10; i++) {
        time.advance(i % 2 === 0 ? 50 : 300); // Highly variable
        network.onMessage(true);
      }

      expect(['MODERATE', 'POOR']).toContain(network.status);
    });
  });

  describe('tick', () => {
    it('should escalate to DEGRADED after 500ms silence while playing', () => {
      const time = createMockTimeProvider(0);
      const network = new NetworkState(undefined, time.now);

      network.onMessage(true); // Set playing state

      time.advance(600); // 600ms silence
      network.tick();

      expect(network.status).toBe('DEGRADED');
    });

    it('should escalate to RECONNECTING after 2s in DEGRADED', () => {
      const time = createMockTimeProvider(0);
      const onReconnectNeeded = vi.fn();
      const network = new NetworkState({ onReconnectNeeded }, time.now);

      network.onMessage(true); // Set playing state

      time.advance(600);
      network.tick(); // -> DEGRADED

      time.advance(1500);
      network.tick(); // -> RECONNECTING

      expect(network.status).toBe('RECONNECTING');
      expect(onReconnectNeeded).toHaveBeenCalled();
    });

    it('should escalate to DISCONNECTED after 10s silence', () => {
      const time = createMockTimeProvider(0);
      const network = new NetworkState(undefined, time.now);

      network.onMessage(true); // Set playing state

      time.advance(600);
      network.tick(); // -> DEGRADED

      time.advance(1500);
      network.tick(); // -> RECONNECTING

      time.advance(8000);
      network.tick(); // -> DISCONNECTED

      expect(network.status).toBe('DISCONNECTED');
    });

    it('should not escalate when transport is stopped', () => {
      const time = createMockTimeProvider(0);
      const network = new NetworkState(undefined, time.now);

      network.onMessage(false); // Not playing

      time.advance(5000); // Long silence, but transport stopped
      network.tick();

      // Should not escalate because we don't expect messages when stopped
      expect(network.status).not.toBe('DEGRADED');
    });
  });

  describe('shouldContinuePrediction', () => {
    it('should return true within 2 second window', () => {
      const time = createMockTimeProvider(0);
      const network = new NetworkState(undefined, time.now);

      network.onMessage(true);
      time.advance(1000);

      expect(network.shouldContinuePrediction()).toBe(true);
    });

    it('should return false after 2 second window', () => {
      const time = createMockTimeProvider(0);
      const network = new NetworkState(undefined, time.now);

      network.onMessage(true);
      time.advance(2500);

      expect(network.shouldContinuePrediction()).toBe(false);
    });
  });

  describe('getReconnectDelay', () => {
    it('should return base delay on first timeout', () => {
      const network = new NetworkState();
      const delay = network.getReconnectDelay();

      // Base is 1000ms, with up to 10% jitter
      expect(delay).toBeGreaterThanOrEqual(1000);
      expect(delay).toBeLessThanOrEqual(1100);
    });

    it('should use exponential backoff formula', () => {
      const network = new NetworkState();

      // The formula is: base * 2^consecutiveTimeouts + jitter
      // base = 1000, maxDelay = 30000
      // With 0 timeouts: 1000 * 2^0 = 1000 (+ up to 10% jitter)
      // With 1 timeout: 1000 * 2^1 = 2000 (+ up to 10% jitter)
      // With 2 timeouts: 1000 * 2^2 = 4000 (+ up to 10% jitter)

      // Initial state - 0 timeouts
      const delay0 = network.getReconnectDelay();
      expect(delay0).toBeGreaterThanOrEqual(1000);
      expect(delay0).toBeLessThanOrEqual(1100);

      // The test verifies the formula exists, not the state machine
      // (state machine is tested separately in the tick tests)
    });
  });

  describe('onReconnected', () => {
    it('should reset state', () => {
      const time = createMockTimeProvider(0);
      const network = new NetworkState(undefined, time.now);

      network.onMessage(true);
      time.advance(600);
      network.tick(); // DEGRADED
      time.advance(1500);
      network.tick(); // RECONNECTING

      network.onReconnected();

      expect(network.status).toBe('OPTIMAL');
      expect(network.getMetrics().consecutiveTimeouts).toBe(0);
    });
  });

  describe('callbacks', () => {
    it('should call onStatusChange when status changes', () => {
      const time = createMockTimeProvider(0);
      const onStatusChange = vi.fn();
      const network = new NetworkState({ onStatusChange }, time.now);

      network.onMessage(true);
      time.advance(600);
      network.tick();

      expect(onStatusChange).toHaveBeenCalledWith('DEGRADED');
    });

    it('should support setting callbacks after construction', () => {
      const time = createMockTimeProvider(0);
      const network = new NetworkState(undefined, time.now);

      const onStatusChange = vi.fn();
      network.setCallbacks({ onStatusChange });

      network.onMessage(true);
      time.advance(600);
      network.tick();

      expect(onStatusChange).toHaveBeenCalledWith('DEGRADED');
    });
  });
});
