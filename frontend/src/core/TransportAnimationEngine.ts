/**
 * TransportAnimationEngine
 *
 * Client-side interpolation for smooth 60fps transport display.
 * Receives server updates at ~30Hz, interpolates position using rAF,
 * and notifies subscribers for direct DOM updates.
 *
 * Based on game networking patterns: dead reckoning with smooth correction.
 */

import type { PlayState } from './types';

export interface TransportAnimationState {
  /** Interpolated position in seconds (use this for display) */
  position: number;
  /** Position formatted as bar.beat.ticks */
  positionBeats: string;
  /** Current BPM */
  bpm: number;
  /** Whether transport is playing */
  isPlaying: boolean;
  /** Current play state */
  playState: PlayState;
  /** Time signature numerator */
  timeSignatureNumerator: number;
  /** Time signature denominator */
  timeSignatureDenominator: number;
  /** Bar offset for beat formatting */
  barOffset: number;
}

export type TransportSubscriber = (state: TransportAnimationState) => void;

/** Thresholds for snap vs smooth correction (in seconds) */
const SNAP_THRESHOLD = 0.25; // 250ms - hard snap for seeks
const SMOOTH_THRESHOLD = 0.05; // 50ms - ignore errors below this
const CORRECTION_FACTOR = 0.15; // 15% correction per server update

/** Max delta to prevent huge jumps on frame drops */
const MAX_DELTA_MS = 50;

export class TransportAnimationEngine {
  // Server state (authoritative)
  private serverPosition = 0;
  private serverBpm = 120;
  private serverPlayState: PlayState = 0;
  private lastServerTime = 0;

  // Time signature
  private timeSignatureNumerator = 4;
  private timeSignatureDenominator = 4;
  private barOffset = 0;

  // Local interpolated state
  private localPosition = 0;
  private lastPositionBeats = '1.1.00';

  // Animation state
  private rafId: number | null = null;
  private lastFrameTime = 0;
  private subscribers = new Set<TransportSubscriber>();

  // Cached state object to avoid allocations
  private cachedState: TransportAnimationState = {
    position: 0,
    positionBeats: '1.1.00',
    bpm: 120,
    isPlaying: false,
    playState: 0,
    timeSignatureNumerator: 4,
    timeSignatureDenominator: 4,
    barOffset: 0,
  };

  /**
   * Called when server sends transport update (~30Hz)
   */
  onServerUpdate(data: {
    position: number;
    positionBeats: string;
    bpm: number;
    playState: PlayState;
    timeSignatureNumerator?: number;
    timeSignatureDenominator?: number;
    barOffset?: number;
  }): void {
    const now = performance.now();
    const wasPlaying = this.isPlaying();
    const previousPlayState = this.serverPlayState;

    // Update time signature if provided
    if (data.timeSignatureNumerator !== undefined) {
      this.timeSignatureNumerator = data.timeSignatureNumerator;
    }
    if (data.timeSignatureDenominator !== undefined) {
      this.timeSignatureDenominator = data.timeSignatureDenominator;
    }
    if (data.barOffset !== undefined) {
      this.barOffset = data.barOffset;
    }

    // Always update these
    this.serverBpm = data.bpm;
    this.serverPlayState = data.playState;
    this.lastPositionBeats = data.positionBeats;

    // Calculate prediction error (position is in seconds, so just add elapsed seconds)
    const elapsed = (now - this.lastServerTime) / 1000;
    const predicted = this.serverPosition + (wasPlaying ? elapsed : 0);
    const error = Math.abs(data.position - predicted);

    // Decide correction strategy
    const isSeekOrStateChange = error > SNAP_THRESHOLD ||
                                 !wasPlaying ||
                                 previousPlayState !== data.playState;

    if (isSeekOrStateChange) {
      // Hard snap for seeks or state changes
      this.localPosition = data.position;
    } else if (error > SMOOTH_THRESHOLD) {
      // Smooth correction for drift
      this.localPosition += (data.position - this.localPosition) * CORRECTION_FACTOR;
    }
    // Errors below SMOOTH_THRESHOLD are ignored

    this.serverPosition = data.position;
    this.lastServerTime = now;

    // Handle play state transitions
    const nowPlaying = this.isPlaying();
    if (nowPlaying && !wasPlaying) {
      this.startAnimation();
    } else if (!nowPlaying && wasPlaying) {
      this.stopAnimation();
      // Ensure we notify with final position when stopped
      this.notifySubscribers();
    } else if (!nowPlaying) {
      // Not playing - still notify so display updates
      this.notifySubscribers();
    }
  }

  /**
   * Check if transport is currently playing (includes recording)
   */
  private isPlaying(): boolean {
    // 1 = playing, 5 = recording
    return this.serverPlayState === 1 || this.serverPlayState === 5;
  }

  /**
   * Animation tick - called at 60fps via requestAnimationFrame
   */
  private tick = (timestamp: number): void => {
    if (!this.isPlaying()) {
      this.rafId = null;
      return;
    }

    // Calculate delta with frame drop protection
    const deltaMs = this.lastFrameTime > 0 ? timestamp - this.lastFrameTime : 0;
    const safeDelta = Math.min(deltaMs, MAX_DELTA_MS);
    this.lastFrameTime = timestamp;

    // Interpolate position: add elapsed time in seconds (1x playback speed)
    this.localPosition += safeDelta / 1000;

    // Notify subscribers
    this.notifySubscribers();

    // Schedule next frame
    this.rafId = requestAnimationFrame(this.tick);
  };

  /**
   * Start the animation loop
   */
  private startAnimation(): void {
    if (this.rafId !== null) return; // Already running
    this.lastFrameTime = performance.now();
    this.rafId = requestAnimationFrame(this.tick);
  }

  /**
   * Stop the animation loop
   */
  private stopAnimation(): void {
    if (this.rafId !== null) {
      cancelAnimationFrame(this.rafId);
      this.rafId = null;
    }
  }

  /**
   * Notify all subscribers with current state
   */
  private notifySubscribers(): void {
    // Update cached state object
    this.cachedState.position = this.localPosition;
    this.cachedState.positionBeats = this.formatBeats(this.localPosition);
    this.cachedState.bpm = this.serverBpm;
    this.cachedState.isPlaying = this.isPlaying();
    this.cachedState.playState = this.serverPlayState;
    this.cachedState.timeSignatureNumerator = this.timeSignatureNumerator;
    this.cachedState.timeSignatureDenominator = this.timeSignatureDenominator;
    this.cachedState.barOffset = this.barOffset;

    this.subscribers.forEach(fn => fn(this.cachedState));
  }

  /**
   * Get the current beat position string.
   *
   * We don't interpolate bar.beat.ticks because calculating it correctly
   * across all time signatures (4/4, 6/8, etc.) with barOffset is complex.
   * The server sends the authoritative positionBeats string at ~30Hz,
   * which is sufficient for bar/beat display. The main visual improvement
   * from interpolation is in the seconds display and playhead position.
   */
  private formatBeats(_positionSeconds: number): string {
    return this.lastPositionBeats;
  }

  /**
   * Subscribe to position updates
   * @returns Unsubscribe function
   */
  subscribe(callback: TransportSubscriber): () => void {
    this.subscribers.add(callback);
    // Immediately notify with current state
    callback(this.cachedState);
    return () => this.subscribers.delete(callback);
  }

  /**
   * Get current interpolated position (for non-subscriber access)
   */
  getPosition(): number {
    return this.localPosition;
  }

  /**
   * Get current state snapshot
   */
  getState(): TransportAnimationState {
    return { ...this.cachedState };
  }

  /**
   * Clean up - stop animation and clear subscribers
   */
  destroy(): void {
    this.stopAnimation();
    this.subscribers.clear();
  }
}

// Singleton instance
export const transportEngine = new TransportAnimationEngine();
