/**
 * BeatPredictor - Position Prediction with Discontinuity Handling
 *
 * Extrapolates beat position from tempo and handles transport state changes.
 * Phase 1: Basic prediction without adaptive jitter buffer.
 */

import type { TimeProvider, TimeSignature } from './types';
import { defaultTimeProvider } from './types';

/** Server state from last transport update */
export interface ServerState {
  position: number; // Beat position
  tempo: number; // BPM
  isPlaying: boolean;
  isRecording: boolean;
  serverTimestamp: number; // Server time in ms
  localReceiveTime: number; // Synced local time when received
  timeSignature: TimeSignature;
}

/** Interface for clock sync (dependency injection) */
export interface ClockSyncInterface {
  getSyncedTime(): number;
}

export class BeatPredictor {
  private clockSync: ClockSyncInterface;
  private timeProvider: TimeProvider;
  private lastServerState: ServerState | null = null;
  private predictionDisabledUntil = 0;
  private displayPosition = 0;
  private isSeek = false;

  // Configuration
  private readonly blendFactor = 0.15; // 15% blend per frame (default for good networks)
  private readonly seekSnapThreshold = 1.0; // beats - large jump = user seek
  private readonly driftSnapThreshold = 0.25; // beats - small jump = prediction drift
  private readonly baseDisableDuration = 100; // ms - base duration to disable prediction after state change

  constructor(
    clockSync: ClockSyncInterface,
    timeProvider: TimeProvider = defaultTimeProvider
  ) {
    this.clockSync = clockSync;
    this.timeProvider = timeProvider;
  }

  /**
   * Process server transport update.
   */
  onServerUpdate(
    position: number,
    tempo: number,
    playState: number,
    isRecording: boolean,
    serverTimestamp: number,
    timeSignature: TimeSignature
  ): void {
    const now = this.timeProvider.now();
    const isPlaying = (playState & 1) !== 0; // Bit 0 indicates playing

    // Detect state changes
    const wasStateChange = this.detectStateChange(position, tempo, isPlaying);

    this.lastServerState = {
      position,
      tempo,
      isPlaying,
      isRecording,
      serverTimestamp,
      localReceiveTime: this.clockSync.getSyncedTime(),
      timeSignature,
    };

    if (wasStateChange) {
      // Disable prediction briefly after state change
      // Duration = 100ms base (Phase 2 adds jitter-based duration)
      const disableDuration = this.baseDisableDuration;
      this.predictionDisabledUntil = now + disableDuration;

      // Snap display to new position on seek
      if (this.isSeek) {
        this.displayPosition = position;
      }
    }
  }

  /**
   * Detect if this update represents a state change (play/stop/seek/tempo change).
   */
  private detectStateChange(
    newPosition: number,
    newTempo: number,
    newIsPlaying: boolean
  ): boolean {
    if (!this.lastServerState) return false;

    const prev = this.lastServerState;

    // Play/stop state change
    if (prev.isPlaying !== newIsPlaying) {
      this.isSeek = false;
      return true;
    }

    // Tempo change (more than 0.01 BPM)
    if (Math.abs(prev.tempo - newTempo) > 0.01) {
      this.isSeek = false;
      return true;
    }

    // Seek detection: position jump > expected from elapsed time
    if (prev.isPlaying) {
      const elapsed = (this.clockSync.getSyncedTime() - prev.localReceiveTime) / 1000;
      const expectedPosition = prev.position + elapsed * (prev.tempo / 60);
      const positionDelta = Math.abs(newPosition - expectedPosition);

      if (positionDelta > this.seekSnapThreshold) {
        // Large jump: user-initiated seek - snap immediately
        this.isSeek = true;
        return true;
      } else if (positionDelta > this.driftSnapThreshold) {
        // Small jump: prediction drift - correct via blending, not state change
        this.isSeek = false;
        return false;
      }
    }

    return false;
  }

  /**
   * Get raw predicted position (without blending).
   */
  getPredictedPosition(): number {
    if (!this.lastServerState) return 0;
    if (!this.lastServerState.isPlaying) return this.lastServerState.position;

    // Check if prediction is temporarily disabled
    if (this.timeProvider.now() < this.predictionDisabledUntil) {
      return this.lastServerState.position;
    }

    // Calculate elapsed time since last update
    const now = this.clockSync.getSyncedTime();
    const elapsed = (now - this.lastServerState.localReceiveTime) / 1000;

    // Clamp elapsed time to prevent runaway prediction (2 seconds max)
    const clampedElapsed = Math.min(elapsed, 2.0);

    // Predict position from tempo
    const beatsPerSecond = this.lastServerState.tempo / 60;
    const predicted = this.lastServerState.position + clampedElapsed * beatsPerSecond;

    return predicted;
  }

  /**
   * Get display position (predicted + smoothly blended).
   * Call this every frame for rendering.
   */
  getDisplayPosition(): number {
    const predicted = this.getPredictedPosition();

    const isPredictionDisabled = this.timeProvider.now() < this.predictionDisabledUntil;

    if (isPredictionDisabled) {
      // Snap during state change
      this.displayPosition = predicted;
    } else {
      // Exponential blend toward predicted position
      this.displayPosition += (predicted - this.displayPosition) * this.blendFactor;
    }

    return this.displayPosition;
  }

  /**
   * Get current beat within measure (0 to numerator-1).
   */
  getCurrentBeat(): number {
    const pos = this.getDisplayPosition();
    const ts = this.lastServerState?.timeSignature ?? { numerator: 4, denominator: 4 };
    return pos % ts.numerator;
  }

  /**
   * Get beat phase (0 to 1) for beat indicator animation.
   */
  getBeatPhase(): number {
    const pos = this.getDisplayPosition();
    return pos % 1;
  }

  /**
   * Check if currently playing.
   */
  isPlaying(): boolean {
    return this.lastServerState?.isPlaying ?? false;
  }

  /**
   * Check if currently recording.
   */
  isRecording(): boolean {
    return this.lastServerState?.isRecording ?? false;
  }

  /**
   * Get current tempo.
   */
  getTempo(): number {
    return this.lastServerState?.tempo ?? 120;
  }

  /**
   * Get current time signature.
   */
  getTimeSignature(): TimeSignature {
    return this.lastServerState?.timeSignature ?? { numerator: 4, denominator: 4 };
  }

  /**
   * Get current state for display.
   */
  getState() {
    return {
      position: this.getDisplayPosition(),
      beat: this.getCurrentBeat(),
      phase: this.getBeatPhase(),
      tempo: this.getTempo(),
      isPlaying: this.isPlaying(),
      isRecording: this.isRecording(),
      timeSignature: this.getTimeSignature(),
    };
  }
}
