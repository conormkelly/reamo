import { describe, it, expect, beforeEach } from 'vitest';
import { BeatPredictor, type ClockSyncInterface } from './BeatPredictor';
import type { TimeProvider, TimeSignature } from './types';

/** Mock clock sync that returns predictable synced time */
class MockClockSync implements ClockSyncInterface {
  private syncedTime = 0;

  getSyncedTime(): number {
    return this.syncedTime;
  }

  setSyncedTime(time: number): void {
    this.syncedTime = time;
  }

  advanceTime(ms: number): void {
    this.syncedTime += ms;
  }
}

/** Mock time provider for controlling "now" in tests */
class MockTimeProvider implements TimeProvider {
  private currentTime = 0;

  now(): number {
    return this.currentTime;
  }

  setNow(time: number): void {
    this.currentTime = time;
  }

  advance(ms: number): void {
    this.currentTime += ms;
  }
}

describe('BeatPredictor', () => {
  let clockSync: MockClockSync;
  let timeProvider: MockTimeProvider;
  let predictor: BeatPredictor;

  const defaultTimeSignature: TimeSignature = { numerator: 4, denominator: 4 };

  beforeEach(() => {
    clockSync = new MockClockSync();
    timeProvider = new MockTimeProvider();
    predictor = new BeatPredictor(clockSync, timeProvider);
  });

  describe('initial state', () => {
    it('returns zero position before any updates', () => {
      expect(predictor.getPredictedPosition()).toBe(0);
      expect(predictor.getDisplayPosition()).toBe(0);
    });

    it('reports not playing before any updates', () => {
      expect(predictor.isPlaying()).toBe(false);
      expect(predictor.isRecording()).toBe(false);
    });

    it('returns default tempo and time signature', () => {
      expect(predictor.getTempo()).toBe(120);
      expect(predictor.getTimeSignature()).toEqual({ numerator: 4, denominator: 4 });
    });
  });

  describe('stopped state', () => {
    it('returns server position when stopped', () => {
      predictor.onServerUpdate(10.0, 120, 0, false, 1000, defaultTimeSignature);

      expect(predictor.getPredictedPosition()).toBe(10.0);
      expect(predictor.isPlaying()).toBe(false);
    });

    it('does not predict when stopped', () => {
      clockSync.setSyncedTime(1000);
      predictor.onServerUpdate(10.0, 120, 0, false, 1000, defaultTimeSignature);

      // Advance time
      clockSync.advanceTime(500);
      timeProvider.advance(500);

      // Position should not change when stopped
      expect(predictor.getPredictedPosition()).toBe(10.0);
    });
  });

  describe('playing state prediction', () => {
    it('predicts position from tempo and elapsed time', () => {
      clockSync.setSyncedTime(1000);
      timeProvider.setNow(1000);

      // Start playing at position 0, 120 BPM (2 beats per second)
      predictor.onServerUpdate(0, 120, 1, false, 1000, defaultTimeSignature);

      // Wait for prediction to be enabled (past disable duration)
      timeProvider.advance(150);
      clockSync.advanceTime(500); // 0.5 seconds elapsed

      // At 120 BPM = 2 beats/sec, 0.5 seconds = 1 beat
      const predicted = predictor.getPredictedPosition();
      expect(predicted).toBeCloseTo(1.0, 1);
    });

    it('uses tempo for prediction calculation', () => {
      clockSync.setSyncedTime(1000);
      timeProvider.setNow(1000);

      // 60 BPM = 1 beat per second
      predictor.onServerUpdate(0, 60, 1, false, 1000, defaultTimeSignature);

      timeProvider.advance(150);
      clockSync.advanceTime(1000); // 1 second elapsed

      const predicted = predictor.getPredictedPosition();
      expect(predicted).toBeCloseTo(1.0, 1);
    });

    it('clamps prediction to prevent runaway (max 2 seconds)', () => {
      clockSync.setSyncedTime(1000);
      timeProvider.setNow(1000);

      predictor.onServerUpdate(0, 120, 1, false, 1000, defaultTimeSignature);

      timeProvider.advance(150);
      // Simulate huge time gap (5 seconds)
      clockSync.advanceTime(5000);

      // At 120 BPM, 2 seconds max = 4 beats max prediction
      const predicted = predictor.getPredictedPosition();
      expect(predicted).toBeLessThanOrEqual(4.0);
    });
  });

  describe('state change detection', () => {
    it('disables prediction briefly after play/stop change', () => {
      clockSync.setSyncedTime(1000);
      timeProvider.setNow(1000);

      // Start stopped
      predictor.onServerUpdate(5.0, 120, 0, false, 1000, defaultTimeSignature);

      // Start playing
      predictor.onServerUpdate(5.0, 120, 1, false, 1050, defaultTimeSignature);

      // Immediately after state change, should return server position
      expect(predictor.getPredictedPosition()).toBe(5.0);

      // Even with time elapsed, prediction disabled
      clockSync.advanceTime(50);
      expect(predictor.getPredictedPosition()).toBe(5.0);

      // After disable duration, prediction resumes
      timeProvider.advance(150);
      clockSync.advanceTime(500);

      const predicted = predictor.getPredictedPosition();
      expect(predicted).toBeGreaterThan(5.0);
    });

    it('disables prediction briefly after tempo change', () => {
      clockSync.setSyncedTime(1000);
      timeProvider.setNow(1000);

      predictor.onServerUpdate(0, 120, 1, false, 1000, defaultTimeSignature);
      timeProvider.advance(150);

      // Change tempo
      timeProvider.setNow(1200);
      predictor.onServerUpdate(0.4, 140, 1, false, 1200, defaultTimeSignature);

      // Prediction should be disabled
      expect(predictor.getPredictedPosition()).toBe(0.4);
    });
  });

  describe('seek detection', () => {
    it('snaps to new position on large seek', () => {
      clockSync.setSyncedTime(1000);
      timeProvider.setNow(1000);

      // Start playing at position 0
      predictor.onServerUpdate(0, 120, 1, false, 1000, defaultTimeSignature);
      predictor.getDisplayPosition(); // Initialize display position

      timeProvider.advance(150);
      clockSync.advanceTime(100);

      // User seeks to position 20 (large jump)
      timeProvider.setNow(1200);
      clockSync.setSyncedTime(1200);
      predictor.onServerUpdate(20.0, 120, 1, false, 1200, defaultTimeSignature);

      // Display should snap to new position
      expect(predictor.getDisplayPosition()).toBeCloseTo(20.0, 0);
    });

    it('does not trigger state change on small drift', () => {
      clockSync.setSyncedTime(1000);
      timeProvider.setNow(1000);

      predictor.onServerUpdate(0, 120, 1, false, 1000, defaultTimeSignature);

      timeProvider.advance(150);
      clockSync.advanceTime(500);

      // Small drift correction (0.1 beats) should not disable prediction
      // Expected: 1.0 beats, actual: 1.1 beats (0.1 beat drift)
      timeProvider.setNow(1650);
      clockSync.setSyncedTime(1500);
      predictor.onServerUpdate(1.1, 120, 1, false, 1500, defaultTimeSignature);

      // Prediction should still work (not disabled)
      clockSync.advanceTime(100);
      timeProvider.advance(100);

      const predicted = predictor.getPredictedPosition();
      expect(predicted).toBeGreaterThan(1.1);
    });
  });

  describe('display position blending', () => {
    it('blends toward predicted position', () => {
      clockSync.setSyncedTime(1000);
      timeProvider.setNow(1000);

      predictor.onServerUpdate(0, 120, 1, false, 1000, defaultTimeSignature);

      // Get initial display position
      predictor.getDisplayPosition();

      timeProvider.advance(150);
      clockSync.advanceTime(500);

      // First call after state change enable
      const display1 = predictor.getDisplayPosition();

      // Call again (should blend further)
      const display2 = predictor.getDisplayPosition();

      // Display should be moving toward predicted
      expect(display2).toBeGreaterThanOrEqual(display1);
    });

    it('snaps during state change', () => {
      clockSync.setSyncedTime(1000);
      timeProvider.setNow(1000);

      // First establish stopped state
      predictor.onServerUpdate(0, 120, 0, false, 1000, defaultTimeSignature);
      predictor.getDisplayPosition(); // Initialize

      // Now start playing (state change)
      timeProvider.setNow(1050);
      clockSync.setSyncedTime(1050);
      predictor.onServerUpdate(10.0, 120, 1, false, 1050, defaultTimeSignature);

      // During disabled period after state change, display snaps to predicted
      const display = predictor.getDisplayPosition();
      expect(display).toBe(10.0);
    });
  });

  describe('beat and phase calculations', () => {
    it('calculates current beat within measure', () => {
      clockSync.setSyncedTime(1000);
      timeProvider.setNow(1000);

      // First update, then state change to trigger snap
      predictor.onServerUpdate(0, 120, 1, false, 900, { numerator: 4, denominator: 4 });
      predictor.getDisplayPosition();

      // Stop (state change) at position 5.5 - this will snap
      timeProvider.setNow(1050);
      predictor.onServerUpdate(5.5, 120, 0, false, 1000, { numerator: 4, denominator: 4 });
      predictor.getDisplayPosition(); // Snap during state change

      // Position 5.5 in 4/4 = beat 1.5 (5.5 % 4)
      expect(predictor.getCurrentBeat()).toBeCloseTo(1.5, 1);
    });

    it('respects time signature for beat calculation', () => {
      clockSync.setSyncedTime(1000);
      timeProvider.setNow(1000);

      // First update
      predictor.onServerUpdate(0, 120, 1, false, 900, { numerator: 3, denominator: 4 });
      predictor.getDisplayPosition();

      // Stop (state change) at position 7.0 - this will snap
      timeProvider.setNow(1050);
      predictor.onServerUpdate(7.0, 120, 0, false, 1000, { numerator: 3, denominator: 4 });
      predictor.getDisplayPosition();

      // Position 7.0 in 3/4 = beat 1.0 (7 % 3)
      expect(predictor.getCurrentBeat()).toBeCloseTo(1.0, 1);
    });

    it('calculates beat phase (0 to 1)', () => {
      clockSync.setSyncedTime(1000);
      timeProvider.setNow(1000);

      // First update
      predictor.onServerUpdate(0, 120, 1, false, 900, defaultTimeSignature);
      predictor.getDisplayPosition();

      // Stop (state change) at position 2.25 - this will snap
      timeProvider.setNow(1050);
      predictor.onServerUpdate(2.25, 120, 0, false, 1000, defaultTimeSignature);
      predictor.getDisplayPosition();

      // Position 2.25 has phase 0.25
      expect(predictor.getBeatPhase()).toBeCloseTo(0.25, 2);
    });
  });

  describe('recording state', () => {
    it('tracks recording state', () => {
      predictor.onServerUpdate(0, 120, 5, true, 1000, defaultTimeSignature);

      expect(predictor.isPlaying()).toBe(true);
      expect(predictor.isRecording()).toBe(true);
    });
  });

  describe('getState()', () => {
    it('returns complete state object', () => {
      clockSync.setSyncedTime(1000);
      timeProvider.setNow(1000);

      // First update to establish prior state
      predictor.onServerUpdate(0, 120, 0, false, 900, { numerator: 3, denominator: 4 });
      predictor.getDisplayPosition();

      // State change (start playing/recording) to trigger snap
      timeProvider.setNow(1050);
      predictor.onServerUpdate(4.5, 140, 1, true, 1000, { numerator: 3, denominator: 4 });

      const state = predictor.getState();

      expect(state.position).toBe(4.5);
      expect(state.tempo).toBe(140);
      expect(state.isPlaying).toBe(true);
      expect(state.isRecording).toBe(true);
      expect(state.timeSignature).toEqual({ numerator: 3, denominator: 4 });
      expect(state.beat).toBeCloseTo(1.5, 1); // 4.5 % 3
      expect(state.phase).toBeCloseTo(0.5, 1); // 4.5 % 1
    });
  });
});
