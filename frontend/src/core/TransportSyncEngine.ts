/**
 * TransportSyncEngine
 *
 * Clock-synchronized transport display with ±15ms visual accuracy.
 * Singleton that manages NTP-style clock sync and client-side beat prediction.
 *
 * Architecture:
 * - ClockSync: NTP-style offset calculation from periodic sync requests
 * - BeatPredictor: Extrapolates beat position from tempo and synced time
 * - 60fps animation loop with requestAnimationFrame
 */

import { ClockSync, BeatPredictor, type ClockSyncMetrics, type TimeSignature, type TempoMarker } from '../lib/transport-sync';
import type { TransportEventPayload, ClockSyncResponse, WSTempoMarker } from './WebSocketTypes';

/** State provided to subscribers on each animation frame */
export interface TransportSyncState {
  /** Predicted beat position (total beats from project start) */
  position: number;
  /** Current beat within measure (0 to numerator-1) */
  beat: number;
  /** Beat phase (0 to 1) for smooth animations */
  phase: number;
  /** Current tempo in BPM */
  tempo: number;
  /** Whether transport is playing */
  isPlaying: boolean;
  /** Whether transport is recording */
  isRecording: boolean;
  /** Current time signature */
  timeSignature: TimeSignature;
  /** Whether clock is synchronized */
  isSynced: boolean;
}

export type TransportSyncSubscriber = (state: TransportSyncState) => void;

export class TransportSyncEngine {
  private clockSync: ClockSync;
  private beatPredictor: BeatPredictor;
  private subscribers = new Set<TransportSyncSubscriber>();
  private rafId: number | null = null;
  private isPlaying = false;
  private sendRaw: ((msg: string) => void) | null = null;

  // Cached state to avoid allocations
  private cachedState: TransportSyncState = {
    position: 0,
    beat: 0,
    phase: 0,
    tempo: 120,
    isPlaying: false,
    isRecording: false,
    timeSignature: { numerator: 4, denominator: 4 },
    isSynced: false,
  };

  constructor() {
    // Create clock sync with a placeholder send function
    this.clockSync = new ClockSync((t0: number) => {
      if (this.sendRaw) {
        this.sendRaw(JSON.stringify({ type: 'clockSync', t0 }));
      }
    });

    this.beatPredictor = new BeatPredictor(this.clockSync);
  }

  /**
   * Set the raw send function for clock sync requests.
   * Call this when WebSocket connection is established.
   */
  setSendRaw(sendRaw: (msg: string) => void): void {
    this.sendRaw = sendRaw;
  }

  /**
   * Clear the send function (call on disconnect).
   */
  clearSendRaw(): void {
    this.sendRaw = null;
  }

  /**
   * Handle clock sync response from server.
   * Call this when receiving a clockSyncResponse message.
   */
  onClockSyncResponse(response: ClockSyncResponse): void {
    this.clockSync.onSyncResponse(response.t0, response.t1, response.t2);
  }

  /**
   * Handle transport event from server.
   * Call this when receiving a transport event.
   */
  onTransportEvent(payload: TransportEventPayload): void {
    // Only use sync if we have the new fields and clock is synced
    if (payload.t !== undefined && payload.b !== undefined && this.clockSync.isSynced()) {
      this.beatPredictor.onServerUpdate(
        payload.b, // Raw beat position
        payload.bpm,
        payload.playState,
        payload.playState === 5, // isRecording
        payload.t, // Server timestamp
        payload.timeSignature
      );
    }

    // Track play state for animation loop
    const nowPlaying = payload.playState === 1 || payload.playState === 5;
    const wasPlaying = this.isPlaying;
    this.isPlaying = nowPlaying;

    // Start/stop animation loop
    if (nowPlaying && !wasPlaying) {
      this.startAnimation();
    } else if (!nowPlaying && wasPlaying) {
      this.stopAnimation();
      this.notifySubscribers();
    } else if (!nowPlaying) {
      this.notifySubscribers();
    }
  }

  /**
   * Handle lightweight tick event with enhanced format.
   * Includes BPM, time signature, and pre-computed bar.beat.ticks.
   */
  onTickEvent(
    t: number,
    b: number,
    bpm: number,
    ts: [number, number],
    bbt: string
  ): void {
    if (!this.clockSync.isSynced()) return;
    this.beatPredictor.onTickUpdate(b, t, bpm, ts);
    this.lastBbt = bbt;
  }

  /** Last bar.beat.ticks string from server (for display) */
  private lastBbt = '1.1.00';

  /** Get pre-computed bar.beat.ticks from server */
  getBarBeatTicks(): string {
    return this.lastBbt;
  }

  /**
   * Update tempo map for tempo-map-aware prediction.
   * Call this when receiving a tempoMap event.
   */
  setTempoMarkers(markers: WSTempoMarker[]): void {
    // Convert WSTempoMarker to internal TempoMarker format
    const internalMarkers: TempoMarker[] = markers.map((m) => ({
      positionBeats: m.positionBeats,
      bpm: m.bpm,
      timesigNum: m.timesigNum,
      timesigDenom: m.timesigDenom,
      linear: m.linear,
    }));
    this.beatPredictor.setTempoMarkers(internalMarkers);
  }

  /**
   * Animation frame callback
   */
  private tick = (): void => {
    if (!this.isPlaying) {
      this.rafId = null;
      return;
    }

    // Tick clock sync for slewing
    this.clockSync.tick();

    this.notifySubscribers();

    // Schedule next frame
    this.rafId = requestAnimationFrame(this.tick);
  };

  private startAnimation(): void {
    if (this.rafId !== null) return;
    this.rafId = requestAnimationFrame(this.tick);
  }

  private stopAnimation(): void {
    if (this.rafId !== null) {
      cancelAnimationFrame(this.rafId);
      this.rafId = null;
    }
  }

  private notifySubscribers(): void {
    const state = this.beatPredictor.getState();

    // Update cached state
    this.cachedState.position = state.position;
    this.cachedState.beat = state.beat;
    this.cachedState.phase = state.phase;
    this.cachedState.tempo = state.tempo;
    this.cachedState.isPlaying = state.isPlaying;
    this.cachedState.isRecording = state.isRecording;
    this.cachedState.timeSignature = state.timeSignature;
    this.cachedState.isSynced = this.clockSync.isSynced();

    this.subscribers.forEach(fn => fn(this.cachedState));
  }

  /**
   * Subscribe to transport sync updates at 60fps.
   * @returns Unsubscribe function
   */
  subscribe(callback: TransportSyncSubscriber): () => void {
    this.subscribers.add(callback);
    // Immediately notify with current state
    callback(this.cachedState);
    return () => this.subscribers.delete(callback);
  }

  /**
   * Get current state snapshot
   */
  getState(): TransportSyncState {
    return { ...this.cachedState };
  }

  /**
   * Check if clock is synchronized
   */
  isSynced(): boolean {
    return this.clockSync.isSynced();
  }

  /**
   * Get sync metrics for debugging
   */
  getMetrics(): ClockSyncMetrics {
    return this.clockSync.getMetrics();
  }

  /**
   * Force clock resync
   */
  resync(): void {
    this.clockSync.invalidate();
  }

  /**
   * Check if resync is needed (after disconnect, etc.)
   */
  needsResync(): boolean {
    return this.clockSync.needsResync();
  }

  /**
   * Clean up - stop animation and clear subscribers
   */
  destroy(): void {
    this.stopAnimation();
    this.clockSync.destroy();
    this.subscribers.clear();
  }
}

// Singleton instance
export const transportSyncEngine = new TransportSyncEngine();
