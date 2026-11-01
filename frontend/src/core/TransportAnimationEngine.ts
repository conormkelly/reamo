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
  private serverBpm = 120;
  private serverPlayState: PlayState = 0;

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

    // Hard snap on state changes; otherwise snap or smooth by display error
    const isStateChange = !wasPlaying || previousPlayState !== data.playState;
    this.correctToward(data.position, isStateChange);

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
    // A snap stamps lastFrameTime with performance.now(), which can be later
    // than the next frame's timestamp, so the delta is floored at 0.
    const deltaMs = this.lastFrameTime > 0 ? timestamp - this.lastFrameTime : 0;
    const safeDelta = Math.min(Math.max(deltaMs, 0), MAX_DELTA_MS);
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
   * Called when lightweight tick event arrives (~30Hz during playback).
   * Updates position and bar.beat.ticks for accurate display during playback,
   * especially important after seeks where client-side interpolation would be wrong.
   */
  onTickUpdate(position: number, positionBeats: string): void {
    this.lastPositionBeats = positionBeats;
    this.correctToward(position, false);
  }

  /**
   * Correct the displayed position toward a server position.
   *
   * The error is measured against the displayed position, not against an
   * extrapolation of the previous server sample: animation frames stop while
   * the page is hidden, so the display falls behind even when server samples
   * line up perfectly with each other.
   *
   * Snaps on a large error (seek, or a page returning from hidden), or when
   * animation frames have stalled: nothing is being drawn then, so blending
   * buys no smoothness and only leaves the display trailing the server.
   * Otherwise a small error (drift, jitter) is blended, and one below
   * SMOOTH_THRESHOLD is normal playback variance and ignored.
   */
  private correctToward(position: number, forceSnap: boolean): void {
    const now = performance.now();
    const error = Math.abs(position - this.localPosition);
    const framesStalled = this.rafId !== null && now - this.lastFrameTime > MAX_DELTA_MS;
    if (forceSnap || framesStalled || error > SNAP_THRESHOLD) {
      // The snapped position is the position now: restart frame timing from
      // here, or the next frame adds time the server sample already counts.
      this.localPosition = position;
      this.lastFrameTime = now;
    } else if (error > SMOOTH_THRESHOLD) {
      this.localPosition += (position - this.localPosition) * CORRECTION_FACTOR;
    }
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
