/**
 * TransportSyncEngine
 *
 * Clock-synchronized transport display with ±15ms visual accuracy.
 * Singleton that manages NTP-style clock sync and client-side beat prediction.
 *
 * Architecture:
 * - ClockSync: NTP-style offset calculation from periodic sync requests
 * - BeatPredictor: Extrapolates beat position from tempo and synced time
 * - AdaptiveBuffer: Dynamic jitter buffer sizing
 * - NetworkState: Connection quality tracking
 * - 60fps animation loop with requestAnimationFrame
 */

import {
  ClockSync,
  BeatPredictor,
  AdaptiveBuffer,
  NetworkState,
  type ClockSyncMetrics,
  type TimeSignature,
  type TempoMarker,
  type NetworkQuality,
  type NetworkStatus,
} from '../lib/transport-sync';
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
  /** Server-computed bar.beat.ticks display string (e.g., "12.3.48") */
  barBeatTicks: string;
}

export type TransportSyncSubscriber = (state: TransportSyncState) => void;

export class TransportSyncEngine {
  private clockSync: ClockSync;
  private beatPredictor: BeatPredictor;
  private adaptiveBuffer: AdaptiveBuffer;
  private networkState: NetworkState;
  private subscribers = new Set<TransportSyncSubscriber>();
  private rafId: number | null = null;
  private isPlaying = false;
  private sendRaw: ((msg: string) => void) | null = null;

  // Callbacks for network status changes
  private onNetworkStatusChange?: (status: NetworkStatus) => void;

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
    barBeatTicks: '1.1.00',
  };

  constructor() {
    // Create clock sync with a placeholder send function
    this.clockSync = new ClockSync((t0: number) => {
      if (this.sendRaw) {
        this.sendRaw(JSON.stringify({ type: 'clockSync', t0 }));
      }
    });

    this.beatPredictor = new BeatPredictor(this.clockSync);
    this.adaptiveBuffer = new AdaptiveBuffer();
    this.networkState = new NetworkState({
      onStatusChange: (status) => this.onNetworkStatusChange?.(status),
    });

    // Load saved manual offset from localStorage
    this.loadManualOffset();
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
    const nowPlaying = payload.playState === 1 || payload.playState === 5;

    // Update jitter measurement and network state
    if (payload.t !== undefined) {
      const arrivalTime = performance.now();
      const clockOffset = this.clockSync.isSynced() ? this.clockSync.getOffset() : 0;
      this.adaptiveBuffer.onPacketReceived(arrivalTime, payload.t, clockOffset);
      this.networkState.onMessage(nowPlaying);
    }

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

    // Update bar.beat.ticks from full transport event (used when stopped or no tick events)
    if (payload.positionBeats) {
      this.lastBbt = payload.positionBeats;
    }

    // Track play state for animation loop
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
    // Always update server-computed bar.beat.ticks (doesn't need clock sync)
    this.lastBbt = bbt;

    // Update jitter measurement and network state
    const arrivalTime = performance.now();
    const clockOffset = this.clockSync.isSynced() ? this.clockSync.getOffset() : 0;
    this.adaptiveBuffer.onPacketReceived(arrivalTime, t, clockOffset);
    this.networkState.onMessage(this.isPlaying);

    // Beat predictor needs clock sync for accurate prediction
    if (!this.clockSync.isSynced()) return;
    this.beatPredictor.onTickUpdate(b, t, bpm, ts);
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

    // Tick network state for timeout detection
    this.networkState.tick();

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
    this.cachedState.barBeatTicks = this.lastBbt;

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
   * Get extended metrics including jitter and network quality
   */
  getExtendedMetrics(): {
    clock: ClockSyncMetrics;
    network: {
      status: NetworkStatus;
      quality: NetworkQuality;
      jitter: number;
      targetDelay: number;
    };
  } {
    const bufferMetrics = this.adaptiveBuffer.getMetrics();
    const networkMetrics = this.networkState.getMetrics();
    return {
      clock: this.clockSync.getMetrics(),
      network: {
        status: networkMetrics.status,
        quality: bufferMetrics.quality,
        jitter: bufferMetrics.jitter,
        targetDelay: bufferMetrics.targetDelay,
      },
    };
  }

  /**
   * Get current network quality
   */
  getNetworkQuality(): NetworkQuality {
    return this.adaptiveBuffer.getNetworkQuality();
  }

  /**
   * Get current network status
   */
  getNetworkStatus(): NetworkStatus {
    return this.networkState.status;
  }

  /**
   * Set callback for network status changes
   */
  setOnNetworkStatusChange(callback: ((status: NetworkStatus) => void) | undefined): void {
    this.onNetworkStatusChange = callback;
  }

  /**
   * Force clock resync
   */
  resync(): void {
    this.clockSync.invalidate();
    this.clockSync.startSync();
  }

  /**
   * Set manual offset adjustment (±50ms range).
   * Persists to localStorage.
   */
  setManualOffset(ms: number): void {
    this.clockSync.setManualOffset(ms);
    try {
      localStorage.setItem('reamo:manualOffset', String(ms));
    } catch {
      // localStorage may be unavailable
    }
  }

  /**
   * Get current manual offset in milliseconds.
   */
  getManualOffset(): number {
    return this.clockSync.getManualOffset();
  }

  /**
   * Load manual offset from localStorage (call on init).
   */
  private loadManualOffset(): void {
    try {
      const saved = localStorage.getItem('reamo:manualOffset');
      if (saved !== null) {
        const ms = parseFloat(saved);
        if (!isNaN(ms)) {
          this.clockSync.setManualOffset(ms);
        }
      }
    } catch {
      // localStorage may be unavailable
    }
  }

  /**
   * Check if resync is needed (after disconnect, etc.)
   */
  needsResync(): boolean {
    return this.clockSync.needsResync();
  }

  /**
   * Notify that connection was re-established (reset network state)
   */
  onReconnected(): void {
    this.networkState.onReconnected();
    this.adaptiveBuffer.reset();
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
