# Transport Sync: Production-Grade Visual Latency Compensation

## Overview

This specification defines a complete system for synchronizing visual transport display (beat indicators, playhead position, BPM pulse) with audio playback over WiFi. The target is **±15ms visual accuracy** — comfortably below the 20ms human perception threshold — so a musician looking at their phone sees beat indicators pulse in sync with what they hear from REAPER.

> **Note:** 20ms is the detection threshold for trained musicians; targeting 15ms provides margin for jitter spikes.

**Problem:** WebSocket transport state arrives 50-200ms+ after the audio plays. On variable WiFi, this delay fluctuates (jitter), causing the visual beat indicator to stutter and drift from the audio.

**Solution:** Timestamp messages server-side, synchronize clocks using an NTP-style algorithm, predict beat positions client-side based on tempo, and smooth display updates using a hybrid jitter buffer + exponential blending approach.

---

## Architecture Decisions (Final)

These decisions are research-backed and final. Do not revisit.

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Protocol** | WebSocket | ~200μs RTT on LAN; WebRTC adds complexity (signaling, ICE) for negligible gain |
| **Timing API** | `GetPlayPosition()` | Latency-compensated, matches what user hears. `GetPlayPosition2()` runs ahead of audio — more jarring |
| **Encoding** | JSON with short keys | Native `JSON.parse` faster than JS MessagePack libs; debuggable in DevTools |
| **Sync method** | NTP-style clock sync + client-side prediction | Research-backed, achieves ±10-25ms on good WiFi |
| **Jitter handling** | Hybrid: smooth blending + lightweight jitter buffer | Pure buffering adds latency; pure blending shows jitter; hybrid gets both benefits |
| **Rendering** | `requestAnimationFrame` + Canvas | Bypass React reconciliation for 60fps updates independent of network rate |

### Known Limitations

**Tempo Automation / Ramps**

The prediction algorithm assumes constant tempo between server updates. This breaks down during tempo ramps (gradual tempo changes). When REAPER plays through a tempo automation envelope:

- Prediction continues at the old tempo until the next server message arrives
- This causes visible desync during the ramp, corrected on next update
- **Mitigation**: Detect tempo change > 0.1 BPM between updates → switch to "high-frequency sync mode" (disable prediction, show raw server values with blending only)

```typescript
// In BeatPredictor.onServerUpdate()
const tempoChanging = Math.abs(newTempo - this.lastServerState.tempo) > 0.1;

if (tempoChanging) {
  // Switch to high-frequency mode: disable prediction, rely on blending
  this.highFrequencyMode = true;
  this.highFrequencyModeUntil = performance.now() + 500; // 500ms after tempo stabilizes
}

// In getPredictedPosition()
if (this.highFrequencyMode) {
  // Return server position directly (smoothed by display blending)
  return this.lastServerState.position;
}
```

**Time Signature Changes**

Similar to tempo: position prediction assumes constant time signature. For meter changes mid-playback, the same high-frequency mode applies.

### Why Competitors Don't Solve This

TouchOSC, Lemur, Logic Remote, and other DAW remotes feel responsive because they use **immediate local feedback** — when you touch a fader, the UI moves instantly before the DAW confirms. But their transport displays are just as network-delayed as ours.

They get away with it because users typically look at the DAW screen, not the controller's transport. Our use case — visual beat sync on a remote device — requires actual latency compensation.

---

## Message Protocol

> **Clean Break:** This is a new protocol format with no backwards compatibility. The project is pre-release; no existing clients to support.

### Transport Broadcast Message

The Zig extension broadcasts transport state at ~30Hz. Add server timestamp to every message.

**New format:**
```json
{"t":1704067200123.456,"b":24.5,"bpm":120.0,"p":1,"r":0,"ts_n":4,"ts_d":4}
```

| Field | Type | Description |
|-------|------|-------------|
| `t` | `f64` | Server timestamp in ms (`reaper.time_precise() * 1000.0`) |
| `b` | `f64` | Beat position from `GetPlayPosition()` converted to beats |
| `bpm` | `f64` | Current tempo |
| `p` | `u8` | Play state: 0=stopped, 1=playing, 2=paused |
| `r` | `u8` | Recording: 0=no, 1=yes |
| `ts_n` | `u8` | Time signature numerator |
| `ts_d` | `u8` | Time signature denominator |

**Size comparison:** ~55 bytes → ~45 bytes (18% reduction from short keys)

### Clock Sync Request/Response

New message type for clock synchronization.

> **Implementation Note:** Clock sync **bypasses the command queue** and is handled directly in `ws_server.zig` when the message arrives. This ensures `t1` (receive time) is recorded at actual message arrival, not when dequeued. The command queue adds 0-33ms variable latency that would defeat clock sync accuracy.

**Client request:**
```json
{"type":"clockSync","t0":1704067200000.123}
```

**Server response (sent immediately, no queue):**
```json
{"type":"clockSyncResponse","t0":1704067200000.123,"t1":1704067200005.456,"t2":1704067200005.789}
```

| Field | Description |
|-------|-------------|
| `t0` | Client send time (echoed back) |
| `t1` | Server receive time |
| `t2` | Server send time |

The client calculates offset using NTP formula:
```
RTT = (t3 - t0) - (t2 - t1)
offset = ((t1 - t0) + (t2 - t3)) / 2
```

Where `t3` is client receive time.

---

## Server-Side Implementation (Zig Extension)

### Required Changes

1. **Add `time_precise()` timestamp to every transport broadcast**

```zig
const TransportMessage = struct {
    t: f64,        // Server timestamp (ms)
    b: f64,        // Beat position
    bpm: f64,      // Tempo
    p: u8,         // Play state
    r: u8,         // Recording
    ts_n: u8,      // Time sig numerator
    ts_d: u8,      // Time sig denominator
};

fn createTransportMessage() TransportMessage {
    const play_pos = reaper.GetPlayPosition();  // NOT GetPlayPosition2
    const tempo = reaper.Master_GetTempo();
    const play_state = reaper.GetPlayState();

    // Convert position to beats
    var beats: f64 = undefined;
    var measures: c_int = undefined;
    var cml: c_int = undefined;
    var fullbeats: f64 = undefined;
    _ = reaper.TimeMap2_timeToBeats(null, play_pos, &measures, &cml, &fullbeats, null);

    return .{
        .t = reaper.time_precise() * 1000.0,  // Convert to ms
        .b = fullbeats,
        .bpm = tempo,
        .p = @intCast(play_state & 0x7),
        .r = if (play_state & 4 != 0) 1 else 0,
        .ts_n = getTimeSignatureNumerator(),
        .ts_d = getTimeSignatureDenominator(),
    };
}
```

2. **Handle clock sync requests**

```zig
fn handleClockSyncRequest(msg: ClockSyncRequest) ClockSyncResponse {
    const t1 = reaper.time_precise() * 1000.0;  // Receive time
    // ... minimal processing ...
    const t2 = reaper.time_precise() * 1000.0;  // Send time

    return .{
        .type = "clockSyncResponse",
        .t0 = msg.t0,
        .t1 = t1,
        .t2 = t2,
    };
}
```

3. **Immediate broadcast on transport state changes** (if using C-Surface callbacks)

```zig
// C-Surface callback - fires immediately on transport change
fn SetPlayState(play: bool, pause: bool, rec: bool) void {
    // Push update immediately, don't wait for poll interval
    const msg = createTransportMessage();
    websocketBroadcastImmediate(msg);
}
```

### Polling Rate

Current ~30Hz (33ms) is adequate. The client predicts between updates, so faster polling provides diminishing returns. If using C-Surface callbacks for immediate transport state changes, polling is only needed for position updates during playback.

---

## Client-Side Implementation (TypeScript/React)

### File Structure

```
frontend/src/
├── lib/
│   └── transport-sync/
│       ├── index.ts           # Public exports
│       ├── ClockSync.ts       # NTP-style clock synchronization
│       ├── JitterMeasurement.ts  # Relative delay histogram
│       ├── AdaptiveBuffer.ts  # Buffer sizing algorithm
│       ├── BeatPredictor.ts   # Position prediction + blending
│       ├── NetworkState.ts    # Connection state machine
│       └── types.ts           # Shared types
├── components/
│   └── TransportDisplay/
│       ├── TransportDisplay.tsx  # Canvas-based beat display
│       └── useTransportSync.ts   # Hook combining all sync logic
```

### Core Classes

#### 1. ClockSync — NTP-Style Clock Synchronization

Establishes shared time reference between browser and REAPER.

```typescript
// frontend/src/lib/transport-sync/ClockSync.ts

interface SyncSample {
  rtt: number;
  offset: number;
  time: number;
}

export class ClockSync {
  private offset = 0;              // Current offset (local - server)
  private targetOffset = 0;        // Measured offset we're slewing toward
  private samples: SyncSample[] = [];
  private driftHistory: Array<{ time: number; driftPpm: number }> = [];
  private lastResyncTime = 0;

  // Configuration
  private readonly resyncIntervalMs = 5 * 60 * 1000;  // 5 minutes
  private readonly slewRateMs = 0.5;                   // Max correction per second
  private readonly driftThresholdMs = 50;              // Trigger resync if drift exceeds
  private readonly stepThresholdMs = 100;              // Step (don't slew) if offset exceeds

  constructor(private sendSyncRequest: (t0: number) => Promise<{ t1: number; t2: number }>) {}

  /**
   * Perform initial clock synchronization.
   * Call on connection establishment and after sleep/wake.
   */
  async performSync(numSamples = 8): Promise<{ offset: number; rtt: number; accuracy: number }> {
    const samples: SyncSample[] = [];

    for (let i = 0; i < numSamples; i++) {
      const t0 = performance.now();
      const { t1, t2 } = await this.sendSyncRequest(t0);
      const t3 = performance.now();

      // NTP formula
      const rtt = (t3 - t0) - (t2 - t1);
      const offset = ((t1 - t0) + (t2 - t3)) / 2;

      samples.push({ rtt, offset, time: t3 });

      // Brief pause between samples to avoid burst
      await new Promise(r => setTimeout(r, 100));
    }

    // Select sample with minimum RTT (most accurate per NTP clock filter algorithm)
    const best = samples.reduce((min, s) => s.rtt < min.rtt ? s : min);

    // Track drift rate from previous sync
    if (this.samples.length > 0) {
      const lastSample = this.samples[this.samples.length - 1];
      const timeDelta = best.time - lastSample.time;
      if (timeDelta > 0) {
        const offsetDelta = best.offset - lastSample.offset;
        const driftPpm = (offsetDelta / timeDelta) * 1e6;
        this.driftHistory.push({ time: best.time, driftPpm });
        if (this.driftHistory.length > 10) this.driftHistory.shift();
      }
    }

    this.targetOffset = best.offset;
    this.samples.push(best);
    if (this.samples.length > 16) this.samples.shift();
    this.lastResyncTime = performance.now();

    return {
      offset: best.offset,
      rtt: best.rtt,
      accuracy: best.rtt / 2  // Error bounded by RTT/2
    };
  }

  /**
   * Call every frame to gradually slew toward target offset.
   * Prevents jarring time jumps from small offset corrections.
   */
  tick(deltaMs: number): void {
    const diff = this.targetOffset - this.offset;

    if (Math.abs(diff) > this.stepThresholdMs) {
      // Large offset: step immediately (initial sync or major drift)
      this.offset = this.targetOffset;
    } else {
      // Small offset: slew gradually
      const maxSlew = this.slewRateMs * deltaMs / 1000;
      this.offset += Math.max(-maxSlew, Math.min(maxSlew, diff));
    }
  }

  /**
   * Get current time synchronized to server clock.
   *
   * NTP convention: offset = (server - client), so:
   * - Positive offset means server is ahead → add to local time
   * - Negative offset means server is behind → subtract from local time
   * Using + offset is correct: syncedTime = performance.now() + offset
   */
  getSyncedTime(): number {
    return performance.now() + this.offset;
  }

  /**
   * Check if resync is needed.
   */
  needsResync(): boolean {
    const elapsed = performance.now() - this.lastResyncTime;

    // Scheduled resync
    if (elapsed > this.resyncIntervalMs) return true;

    // Drift-triggered resync
    const estimatedDrift = this.getEstimatedDrift();
    if (Math.abs(estimatedDrift) > this.driftThresholdMs) return true;

    return false;
  }

  /**
   * Estimate accumulated drift since last sync based on measured drift rate.
   */
  private getEstimatedDrift(): number {
    if (this.driftHistory.length < 2) return 0;
    const recent = this.driftHistory.slice(-5);
    const avgPpm = recent.reduce((sum, d) => sum + d.driftPpm, 0) / recent.length;
    const elapsed = performance.now() - this.lastResyncTime;
    return avgPpm * elapsed / 1e6;
  }

  /**
   * Get current sync quality metrics for debugging/display.
   */
  getMetrics(): { offset: number; lastRtt: number; estimatedDrift: number } {
    const lastSample = this.samples[this.samples.length - 1];
    return {
      offset: this.offset,
      lastRtt: lastSample?.rtt ?? 0,
      estimatedDrift: this.getEstimatedDrift()
    };
  }
}
```

#### 2. JitterMeasurement — Relative Delay Histogram

Measures network jitter using WebRTC NetEQ's algorithm (switched to relative delay in 2022).

```typescript
// frontend/src/lib/transport-sync/JitterMeasurement.ts

interface PacketRecord {
  arrivalTime: number;
  expectedTime: number;
  travelTime: number;
}

export class JitterMeasurement {
  private packetHistory: PacketRecord[] = [];
  private histogram = new Map<number, number>();  // bucket -> weight

  // Configuration (WebRTC NetEQ defaults, adjusted for our use case)
  private readonly historyWindowMs = 2000;
  private readonly bucketSizeMs = 10;      // Finer than WebRTC's 20ms for ±20ms target
  private readonly forgetFactor = 0.983;   // ~175 packets to dominate

  /**
   * Record a packet arrival and update jitter statistics.
   * @param arrivalTime - Local time when packet was received
   * @param serverTime - Server timestamp from packet
   * @param clockOffset - Current clock sync offset
   * @returns Relative delay of this packet (ms)
   */
  addPacket(arrivalTime: number, serverTime: number, clockOffset: number): number {
    const expectedTime = serverTime + clockOffset;  // When we expected it
    const travelTime = arrivalTime - expectedTime;

    const packet: PacketRecord = { arrivalTime, expectedTime, travelTime };
    this.packetHistory.push(packet);

    // Trim history to window
    const cutoff = arrivalTime - this.historyWindowMs;
    this.packetHistory = this.packetHistory.filter(p => p.arrivalTime > cutoff);

    // Find fastest packet (minimum travel time = best case network)
    const fastest = this.packetHistory.reduce((min, p) =>
      p.travelTime < min.travelTime ? p : min);

    // Relative delay = how much slower than fastest
    const relativeDelay = Math.max(0, packet.travelTime - fastest.travelTime);

    // Update histogram with exponential forgetting
    for (const [bucket, weight] of this.histogram) {
      this.histogram.set(bucket, weight * this.forgetFactor);
    }
    const bucket = Math.floor(relativeDelay / this.bucketSizeMs);
    const current = this.histogram.get(bucket) || 0;
    this.histogram.set(bucket, current + (1 - this.forgetFactor));

    // Clean up near-zero buckets
    for (const [bucket, weight] of this.histogram) {
      if (weight < 0.001) this.histogram.delete(bucket);
    }

    return relativeDelay;
  }

  /**
   * Get target buffer delay for given quantile.
   * @param quantile - Fraction of packets to arrive in time (0.95 = 95%)
   * @returns Target delay in ms
   */
  getTargetDelay(quantile = 0.95): number {
    if (this.histogram.size === 0) return 40;  // Default before data (safe for mobile)

    const sorted = [...this.histogram.entries()].sort((a, b) => a[0] - b[0]);
    const total = sorted.reduce((sum, [_, w]) => sum + w, 0);

    if (total === 0) return 30;

    let cumulative = 0;
    for (const [bucket, weight] of sorted) {
      cumulative += weight / total;
      if (cumulative >= quantile) {
        return (bucket + 1) * this.bucketSizeMs;
      }
    }

    return 50;  // Fallback
  }

  /**
   * Get current jitter estimate (standard deviation approximation).
   */
  getJitterEstimate(): number {
    return this.getTargetDelay(0.95) - this.getTargetDelay(0.50);
  }
}
```

#### 3. AdaptiveBuffer — Buffer Sizing Algorithm

Dynamically sizes the jitter buffer based on network conditions.

```typescript
// frontend/src/lib/transport-sync/AdaptiveBuffer.ts

import { JitterMeasurement } from './JitterMeasurement';

export class AdaptiveBuffer {
  public targetDelayMs = 40;        // Current target
  private readonly minDelayMs = 35; // Floor: iOS Low-Power Mode = 30fps (33ms frames)
  private readonly maxDelayMs = 150; // Ceiling: beyond feels "laggy"
  private readonly adaptationRate = 0.1;  // Slow down rate

  private jitterMeasurement = new JitterMeasurement();
  private underrunCount = 0;
  private packetCount = 0;

  /**
   * Process incoming packet and update buffer target.
   */
  onPacketReceived(arrivalTime: number, serverTime: number, clockOffset: number): void {
    this.packetCount++;
    this.jitterMeasurement.addPacket(arrivalTime, serverTime, clockOffset);

    const measuredTarget = this.jitterMeasurement.getTargetDelay(0.95);

    // Smooth adaptation toward measured target (slow down)
    this.targetDelayMs += (measuredTarget - this.targetDelayMs) * this.adaptationRate;

    // Apply floor/ceiling
    this.targetDelayMs = Math.max(this.minDelayMs,
                         Math.min(this.maxDelayMs, this.targetDelayMs));
  }

  /**
   * Call when buffer underrun occurs (prediction had to fill gap).
   * Fast increase to prevent repeated underruns.
   */
  onUnderrun(): void {
    this.underrunCount++;
    // Immediate 50% increase on underrun (fast up, slow down pattern)
    this.targetDelayMs = Math.min(this.maxDelayMs, this.targetDelayMs * 1.5);
  }

  /**
   * Get human-readable network quality assessment.
   */
  getNetworkQuality(): 'excellent' | 'good' | 'moderate' | 'poor' {
    if (this.targetDelayMs < 30) return 'excellent';
    if (this.targetDelayMs < 50) return 'good';
    if (this.targetDelayMs < 100) return 'moderate';
    return 'poor';
  }

  /**
   * Get blend factor appropriate for current network quality.
   * Lower = smoother but slower correction; higher = snappier but shows jitter.
   */
  getBlendFactor(): number {
    const quality = this.getNetworkQuality();
    switch (quality) {
      case 'excellent': return 0.15;
      case 'good': return 0.12;
      case 'moderate': return 0.10;
      case 'poor': return 0.08;
    }
  }

  /**
   * Get metrics for debugging/display.
   */
  getMetrics() {
    return {
      targetDelay: this.targetDelayMs,
      jitter: this.jitterMeasurement.getJitterEstimate(),
      quality: this.getNetworkQuality(),
      underruns: this.underrunCount,
      packets: this.packetCount
    };
  }
}
```

#### 4. BeatPredictor — Position Prediction with Discontinuity Handling

Extrapolates beat position from tempo and handles transport state changes.

```typescript
// frontend/src/lib/transport-sync/BeatPredictor.ts

import { ClockSync } from './ClockSync';
import { AdaptiveBuffer } from './AdaptiveBuffer';

interface ServerState {
  position: number;      // Beat position
  tempo: number;         // BPM
  isPlaying: boolean;
  isRecording: boolean;
  serverTimestamp: number;
  localReceiveTime: number;
  timeSignature: { numerator: number; denominator: number };
}

export class BeatPredictor {
  private lastServerState: ServerState | null = null;
  private predictionDisabledUntil = 0;
  private displayPosition = 0;
  private isSeek = false;

  constructor(
    private clockSync: ClockSync,
    private adaptiveBuffer: AdaptiveBuffer
  ) {}

  /**
   * Process server transport update.
   */
  onServerUpdate(
    position: number,
    tempo: number,
    playState: number,
    isRecording: boolean,
    serverTimestamp: number,
    timeSignature: { numerator: number; denominator: number }
  ): void {
    const now = performance.now();
    const isPlaying = playState === 1;

    // Update jitter measurement
    this.adaptiveBuffer.onPacketReceived(
      now,
      serverTimestamp,
      this.clockSync.getSyncedTime() - performance.now()
    );

    // Detect state changes
    const wasStateChange = this.detectStateChange(position, tempo, isPlaying);

    this.lastServerState = {
      position,
      tempo,
      isPlaying,
      isRecording,
      serverTimestamp,
      localReceiveTime: this.clockSync.getSyncedTime(),
      timeSignature
    };

    if (wasStateChange) {
      // Disable prediction briefly after state change
      // Duration = 100ms base + 2x current jitter estimate
      const jitter = this.adaptiveBuffer.getMetrics().jitter;
      const disableDuration = Math.max(100, 100 + jitter * 2);
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
  private detectStateChange(newPosition: number, newTempo: number, newIsPlaying: boolean): boolean {
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
    // Two thresholds:
    // - SEEK_SNAP_THRESHOLD (1.0 beats): Large jump = user-initiated seek → snap immediately
    // - DRIFT_SNAP_THRESHOLD (0.25 beats): Small jump = prediction drift → blend smoothly
    const SEEK_SNAP_THRESHOLD = 1.0;   // User scrubbed/clicked timeline
    const DRIFT_SNAP_THRESHOLD = 0.25; // Accumulated prediction error

    if (prev.isPlaying) {
      const elapsed = (this.clockSync.getSyncedTime() - prev.localReceiveTime) / 1000;
      const expectedPosition = prev.position + elapsed * (prev.tempo / 60);
      const positionDelta = Math.abs(newPosition - expectedPosition);

      if (positionDelta > SEEK_SNAP_THRESHOLD) {
        // Large jump: user-initiated seek - snap immediately
        this.isSeek = true;
        return true;
      } else if (positionDelta > DRIFT_SNAP_THRESHOLD) {
        // Small jump: prediction drift - correct via blending, not state change
        // Don't trigger state change, let exponential blending handle it
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
    if (performance.now() < this.predictionDisabledUntil) {
      return this.lastServerState.position;
    }

    // Calculate elapsed time since last update
    const now = this.clockSync.getSyncedTime();
    const elapsed = (now - this.lastServerState.localReceiveTime) / 1000;

    // Predict position from tempo
    const beatsPerSecond = this.lastServerState.tempo / 60;
    const predicted = this.lastServerState.position + elapsed * beatsPerSecond;

    return predicted;
  }

  /**
   * Get display position (predicted + smoothly blended).
   * Call this every frame for rendering.
   */
  getDisplayPosition(): number {
    const predicted = this.getPredictedPosition();
    const blendFactor = this.adaptiveBuffer.getBlendFactor();

    const isPredictionDisabled = performance.now() < this.predictionDisabledUntil;

    if (isPredictionDisabled) {
      // Snap during state change
      this.displayPosition = predicted;
    } else {
      // Exponential blend toward predicted position
      this.displayPosition += (predicted - this.displayPosition) * blendFactor;
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
   * Get current state for display.
   */
  getState() {
    return {
      position: this.getDisplayPosition(),
      beat: this.getCurrentBeat(),
      phase: this.getBeatPhase(),
      tempo: this.lastServerState?.tempo ?? 120,
      isPlaying: this.lastServerState?.isPlaying ?? false,
      isRecording: this.lastServerState?.isRecording ?? false,
      timeSignature: this.lastServerState?.timeSignature ?? { numerator: 4, denominator: 4 }
    };
  }
}
```

#### 5. NetworkState — Connection State Machine

Handles network hiccups, reconnection, and graceful degradation.

```typescript
// frontend/src/lib/transport-sync/NetworkState.ts

export type NetworkStatus = 'OPTIMAL' | 'GOOD' | 'MODERATE' | 'POOR' | 'DEGRADED' | 'RECONNECTING' | 'DISCONNECTED';

export class NetworkState {
  public status: NetworkStatus = 'OPTIMAL';
  private lastMessageTime = performance.now();
  private messageGapHistory: number[] = [];
  private consecutiveTimeouts = 0;
  private lastKnownIsPlaying = false;

  // Callbacks
  public onStatusChange?: (status: NetworkStatus) => void;
  public onReconnectNeeded?: () => void;

  /**
   * Call when a message is received.
   */
  onMessage(isPlaying: boolean): void {
    const now = performance.now();
    const gap = now - this.lastMessageTime;
    this.lastMessageTime = now;
    this.lastKnownIsPlaying = isPlaying;

    this.messageGapHistory.push(gap);
    if (this.messageGapHistory.length > 20) this.messageGapHistory.shift();

    this.consecutiveTimeouts = 0;
    this.updateStatus();
  }

  /**
   * Call every frame to check for timeouts.
   */
  tick(): void {
    const silenceDuration = performance.now() - this.lastMessageTime;
    const prevStatus = this.status;

    // Only escalate if we expect messages (transport playing)
    // If stopped, silence is expected
    if (!this.lastKnownIsPlaying && this.status !== 'DISCONNECTED') {
      return;
    }

    if (silenceDuration > 500 && this.status !== 'DEGRADED' && this.status !== 'RECONNECTING' && this.status !== 'DISCONNECTED') {
      this.status = 'DEGRADED';
    }
    if (silenceDuration > 2000 && this.status === 'DEGRADED') {
      this.status = 'RECONNECTING';
      this.consecutiveTimeouts++;
      this.onReconnectNeeded?.();
    }
    if (silenceDuration > 10000) {
      this.status = 'DISCONNECTED';
    }

    if (this.status !== prevStatus) {
      this.onStatusChange?.(this.status);
    }
  }

  /**
   * Update status based on message gap statistics.
   */
  private updateStatus(): void {
    if (this.messageGapHistory.length < 5) return;

    const avgGap = this.messageGapHistory.reduce((a, b) => a + b) / this.messageGapHistory.length;
    const jitter = this.calculateJitter();

    const prevStatus = this.status;

    if (avgGap < 100 && jitter < 30) {
      this.status = 'OPTIMAL';
    } else if (avgGap < 150 && jitter < 40) {
      this.status = 'GOOD';
    } else if (avgGap < 200 && jitter < 50) {
      this.status = 'MODERATE';
    } else {
      this.status = 'POOR';
    }

    if (this.status !== prevStatus) {
      this.onStatusChange?.(this.status);
    }
  }

  private calculateJitter(): number {
    if (this.messageGapHistory.length < 2) return 0;
    const avg = this.messageGapHistory.reduce((a, b) => a + b) / this.messageGapHistory.length;
    const variance = this.messageGapHistory.reduce((sum, gap) => sum + Math.pow(gap - avg, 2), 0) / this.messageGapHistory.length;
    return Math.sqrt(variance);
  }

  /**
   * Whether prediction should continue during current state.
   * Prevents runaway prediction during extended outages.
   */
  shouldContinuePrediction(): boolean {
    // Continue prediction for up to 2 seconds during dropout
    return performance.now() - this.lastMessageTime < 2000;
  }

  /**
   * Get reconnection delay with exponential backoff + jitter.
   */
  getReconnectDelay(): number {
    const base = 1000;
    const maxDelay = 30000;
    const exponential = Math.min(maxDelay, base * Math.pow(2, this.consecutiveTimeouts));
    const jitter = exponential * 0.1 * Math.random();
    return exponential + jitter;
  }

  /**
   * Reset state after successful reconnection.
   */
  onReconnected(): void {
    this.consecutiveTimeouts = 0;
    this.status = 'OPTIMAL';
    this.messageGapHistory = [];
  }
}
```

#### 6. TransportSync Hook — Combining Everything

React hook that combines all sync logic.

```typescript
// frontend/src/components/TransportDisplay/useTransportSync.ts

import { useEffect, useRef, useCallback } from 'react';
import { ClockSync } from '../../lib/transport-sync/ClockSync';
import { AdaptiveBuffer } from '../../lib/transport-sync/AdaptiveBuffer';
import { BeatPredictor } from '../../lib/transport-sync/BeatPredictor';
import { NetworkState, NetworkStatus } from '../../lib/transport-sync/NetworkState';

interface TransportState {
  position: number;
  beat: number;
  phase: number;
  tempo: number;
  isPlaying: boolean;
  isRecording: boolean;
  timeSignature: { numerator: number; denominator: number };
}

interface SyncMetrics {
  networkStatus: NetworkStatus;
  networkQuality: 'excellent' | 'good' | 'moderate' | 'poor';
  rtt: number;
  jitter: number;
  bufferTarget: number;
  clockOffset: number;
}

interface UseTransportSyncOptions {
  ws: WebSocket | null;
  onStatusChange?: (status: NetworkStatus) => void;
}

export function useTransportSync({ ws, onStatusChange }: UseTransportSyncOptions) {
  const clockSyncRef = useRef<ClockSync | null>(null);
  const adaptiveBufferRef = useRef(new AdaptiveBuffer());
  const beatPredictorRef = useRef<BeatPredictor | null>(null);
  const networkStateRef = useRef(new NetworkState());
  const stateRef = useRef<TransportState>({
    position: 0,
    beat: 0,
    phase: 0,
    tempo: 120,
    isPlaying: false,
    isRecording: false,
    timeSignature: { numerator: 4, denominator: 4 }
  });
  const metricsRef = useRef<SyncMetrics>({
    networkStatus: 'OPTIMAL',
    networkQuality: 'excellent',
    rtt: 0,
    jitter: 0,
    bufferTarget: 30,
    clockOffset: 0
  });
  const lastFrameTimeRef = useRef(performance.now());

  // Clock sync request function
  const sendSyncRequest = useCallback(async (t0: number): Promise<{ t1: number; t2: number }> => {
    return new Promise((resolve, reject) => {
      if (!ws || ws.readyState !== WebSocket.OPEN) {
        reject(new Error('WebSocket not connected'));
        return;
      }

      const handler = (event: MessageEvent) => {
        const msg = JSON.parse(event.data);
        if (msg.type === 'clockSyncResponse' && msg.t0 === t0) {
          ws.removeEventListener('message', handler);
          resolve({ t1: msg.t1, t2: msg.t2 });
        }
      };

      ws.addEventListener('message', handler);
      ws.send(JSON.stringify({ type: 'clockSync', t0 }));

      // Timeout after 5 seconds
      setTimeout(() => {
        ws.removeEventListener('message', handler);
        reject(new Error('Clock sync timeout'));
      }, 5000);
    });
  }, [ws]);

  // Initialize on WebSocket connect
  useEffect(() => {
    if (!ws) return;

    const clockSync = new ClockSync(sendSyncRequest);
    clockSyncRef.current = clockSync;
    beatPredictorRef.current = new BeatPredictor(clockSync, adaptiveBufferRef.current);

    // Set up network state callbacks
    networkStateRef.current.onStatusChange = onStatusChange;

    // Perform initial clock sync
    clockSync.performSync().then(result => {
      console.log(`Clock sync complete: offset=${result.offset.toFixed(2)}ms, RTT=${result.rtt.toFixed(2)}ms`);
      metricsRef.current.rtt = result.rtt;
      metricsRef.current.clockOffset = result.offset;
    }).catch(err => {
      console.error('Clock sync failed:', err);
    });

    // Handle incoming messages
    const handleMessage = (event: MessageEvent) => {
      const msg = JSON.parse(event.data);

      // Skip clock sync responses (handled separately)
      if (msg.type === 'clockSyncResponse') return;

      // Transport update
      if ('t' in msg && 'b' in msg) {
        beatPredictorRef.current?.onServerUpdate(
          msg.b,           // position
          msg.bpm,         // tempo
          msg.p,           // playState
          msg.r === 1,     // isRecording
          msg.t,           // serverTimestamp
          { numerator: msg.ts_n || 4, denominator: msg.ts_d || 4 }
        );
        networkStateRef.current.onMessage(msg.p === 1);
      }
    };

    ws.addEventListener('message', handleMessage);

    return () => {
      ws.removeEventListener('message', handleMessage);
    };
  }, [ws, sendSyncRequest, onStatusChange]);

  // Handle visibility change (sleep/wake)
  useEffect(() => {
    const handleVisibilityChange = () => {
      if (document.visibilityState === 'visible') {
        // Resync clock after wake
        clockSyncRef.current?.performSync().catch(console.error);
        networkStateRef.current.onReconnected();
      }
    };

    document.addEventListener('visibilitychange', handleVisibilityChange);
    return () => document.removeEventListener('visibilitychange', handleVisibilityChange);
  }, []);

  // Periodic clock resync check
  useEffect(() => {
    const interval = setInterval(() => {
      if (clockSyncRef.current?.needsResync()) {
        clockSyncRef.current.performSync().catch(console.error);
      }
    }, 30000); // Check every 30 seconds

    return () => clearInterval(interval);
  }, []);

  /**
   * Get current transport state. Call every frame.
   */
  const getState = useCallback((): TransportState => {
    const now = performance.now();
    const deltaMs = now - lastFrameTimeRef.current;
    lastFrameTimeRef.current = now;

    // Tick clock sync (slewing)
    clockSyncRef.current?.tick(deltaMs);

    // Tick network state (timeout detection)
    networkStateRef.current.tick();

    // Get predicted state
    if (beatPredictorRef.current && networkStateRef.current.shouldContinuePrediction()) {
      stateRef.current = beatPredictorRef.current.getState();
    }

    return stateRef.current;
  }, []);

  /**
   * Get sync metrics for debugging/display.
   */
  const getMetrics = useCallback((): SyncMetrics => {
    const bufferMetrics = adaptiveBufferRef.current.getMetrics();
    const clockMetrics = clockSyncRef.current?.getMetrics();

    metricsRef.current = {
      networkStatus: networkStateRef.current.status,
      networkQuality: bufferMetrics.quality,
      rtt: clockMetrics?.lastRtt ?? 0,
      jitter: bufferMetrics.jitter,
      bufferTarget: bufferMetrics.targetDelay,
      clockOffset: clockMetrics?.offset ?? 0
    };

    return metricsRef.current;
  }, []);

  /**
   * Force clock resync.
   */
  const forceResync = useCallback(() => {
    clockSyncRef.current?.performSync().catch(console.error);
  }, []);

  return { getState, getMetrics, forceResync };
}
```

#### 7. TransportDisplay Component — Canvas Rendering

Bypasses React state for 60fps rendering.

```typescript
// frontend/src/components/TransportDisplay/TransportDisplay.tsx

import React, { useRef, useEffect, useState } from 'react';
import { useTransportSync } from './useTransportSync';
import { NetworkStatus } from '../../lib/transport-sync/NetworkState';

interface TransportDisplayProps {
  ws: WebSocket | null;
  width?: number;
  height?: number;
  showMetrics?: boolean;
}

export function TransportDisplay({
  ws,
  width = 400,
  height = 120,
  showMetrics = false
}: TransportDisplayProps) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const [networkStatus, setNetworkStatus] = useState<NetworkStatus>('OPTIMAL');

  const { getState, getMetrics, forceResync } = useTransportSync({
    ws,
    onStatusChange: setNetworkStatus
  });

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;

    const ctx = canvas.getContext('2d');
    if (!ctx) return;

    let animationId: number;

    const render = () => {
      const state = getState();
      const metrics = showMetrics ? getMetrics() : null;

      // Clear canvas
      ctx.fillStyle = '#1a1a1a';
      ctx.fillRect(0, 0, width, height);

      // Draw beat indicator (pulses on each beat)
      const beatPhase = state.phase;
      const beatIntensity = Math.max(0, 1 - beatPhase * 3); // Quick fade after beat
      const indicatorRadius = 20 + beatIntensity * 10;

      ctx.beginPath();
      ctx.arc(50, height / 2, indicatorRadius, 0, Math.PI * 2);
      ctx.fillStyle = state.isPlaying
        ? `rgba(74, 222, 128, ${0.3 + beatIntensity * 0.7})` // Green pulse
        : 'rgba(100, 100, 100, 0.5)'; // Gray when stopped
      ctx.fill();

      // Draw beat number (1-4 for 4/4)
      ctx.fillStyle = '#ffffff';
      ctx.font = 'bold 24px monospace';
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      const currentBeat = Math.floor(state.beat) + 1;
      ctx.fillText(currentBeat.toString(), 50, height / 2);

      // Draw tempo
      ctx.font = '18px monospace';
      ctx.textAlign = 'left';
      ctx.fillText(`${state.tempo.toFixed(1)} BPM`, 100, height / 2 - 15);

      // Draw time signature
      ctx.font = '14px monospace';
      ctx.fillStyle = '#888888';
      ctx.fillText(`${state.timeSignature.numerator}/${state.timeSignature.denominator}`, 100, height / 2 + 10);

      // Draw position (bars:beats)
      const bars = Math.floor(state.position / state.timeSignature.numerator) + 1;
      const beatsInBar = (state.position % state.timeSignature.numerator) + 1;
      ctx.fillStyle = '#ffffff';
      ctx.font = '16px monospace';
      ctx.fillText(`${bars}:${beatsInBar.toFixed(2)}`, 100, height / 2 + 35);

      // Draw play/record state
      if (state.isRecording) {
        ctx.fillStyle = '#ef4444';
        ctx.beginPath();
        ctx.arc(width - 30, 30, 8, 0, Math.PI * 2);
        ctx.fill();
      } else if (state.isPlaying) {
        ctx.fillStyle = '#22c55e';
        ctx.beginPath();
        ctx.moveTo(width - 38, 22);
        ctx.lineTo(width - 38, 38);
        ctx.lineTo(width - 22, 30);
        ctx.closePath();
        ctx.fill();
      }

      // Draw network status indicator
      const statusColors: Record<NetworkStatus, string> = {
        'OPTIMAL': '#22c55e',
        'GOOD': '#84cc16',
        'MODERATE': '#eab308',
        'POOR': '#f97316',
        'DEGRADED': '#ef4444',
        'RECONNECTING': '#ef4444',
        'DISCONNECTED': '#6b7280'
      };
      ctx.fillStyle = statusColors[networkStatus];
      ctx.beginPath();
      ctx.arc(width - 30, height - 30, 6, 0, Math.PI * 2);
      ctx.fill();

      // Draw metrics (debug mode)
      if (metrics && showMetrics) {
        ctx.fillStyle = '#666666';
        ctx.font = '10px monospace';
        ctx.textAlign = 'right';
        ctx.fillText(`RTT: ${metrics.rtt.toFixed(1)}ms`, width - 10, height - 50);
        ctx.fillText(`Jitter: ${metrics.jitter.toFixed(1)}ms`, width - 10, height - 38);
        ctx.fillText(`Buffer: ${metrics.bufferTarget.toFixed(0)}ms`, width - 10, height - 26);
        ctx.fillText(`Offset: ${metrics.clockOffset.toFixed(1)}ms`, width - 10, height - 14);
      }

      animationId = requestAnimationFrame(render);
    };

    animationId = requestAnimationFrame(render);

    return () => cancelAnimationFrame(animationId);
  }, [ws, width, height, showMetrics, networkStatus, getState, getMetrics]);

  return (
    <div style={{ position: 'relative' }}>
      <canvas
        ref={canvasRef}
        width={width}
        height={height}
        style={{ borderRadius: 8, background: '#1a1a1a' }}
      />
      {networkStatus === 'RECONNECTING' && (
        <div style={{
          position: 'absolute',
          top: '50%',
          left: '50%',
          transform: 'translate(-50%, -50%)',
          background: 'rgba(0,0,0,0.8)',
          padding: '8px 16px',
          borderRadius: 4,
          color: '#ef4444',
          fontSize: 14
        }}>
          Reconnecting...
        </div>
      )}
    </div>
  );
}
```

---

## Testing Strategy

### Unit Tests

```typescript
// frontend/src/lib/transport-sync/__tests__/ClockSync.test.ts

describe('ClockSync', () => {
  it('selects minimum RTT sample', async () => {
    const mockSend = jest.fn()
      .mockResolvedValueOnce({ t1: 100, t2: 100 })  // RTT ~50
      .mockResolvedValueOnce({ t1: 95, t2: 95 })    // RTT ~30 (best)
      .mockResolvedValueOnce({ t1: 110, t2: 110 }); // RTT ~80

    const sync = new ClockSync(mockSend);
    const result = await sync.performSync(3);

    expect(result.rtt).toBeLessThan(40);
  });

  it('slews gradually for small offsets', () => {
    const sync = new ClockSync(jest.fn());
    sync['offset'] = 0;
    sync['targetOffset'] = 50;
    sync.tick(1000); // 1 second

    expect(sync['offset']).toBeCloseTo(0.5, 1); // 0.5ms/s slew rate
  });

  it('steps immediately for large offsets', () => {
    const sync = new ClockSync(jest.fn());
    sync['offset'] = 0;
    sync['targetOffset'] = 500;
    sync.tick(16);

    expect(sync['offset']).toBe(500);
  });
});

describe('BeatPredictor', () => {
  it('predicts position from tempo', () => {
    const clockSync = { getSyncedTime: () => 1000 } as any;
    const buffer = new AdaptiveBuffer();
    const predictor = new BeatPredictor(clockSync, buffer);

    // 120 BPM = 2 beats per second
    predictor.onServerUpdate(0, 120, 1, false, 0, { numerator: 4, denominator: 4 });

    // After 500ms, should be at beat 1
    clockSync.getSyncedTime = () => 500;
    expect(predictor.getPredictedPosition()).toBeCloseTo(1, 1);
  });

  it('disables prediction after seek', () => {
    const clockSync = { getSyncedTime: () => 1000 } as any;
    const buffer = new AdaptiveBuffer();
    const predictor = new BeatPredictor(clockSync, buffer);

    predictor.onServerUpdate(0, 120, 1, false, 0, { numerator: 4, denominator: 4 });
    predictor.onServerUpdate(100, 120, 1, false, 100, { numerator: 4, denominator: 4 }); // Seek to beat 100

    // Should return raw server value during disable period
    expect(predictor.getPredictedPosition()).toBe(100);
  });
});
```

### Network Simulation

#### macOS (Primary Development Platform)

**Option 1: Network Link Conditioner** (Recommended)
- Part of Xcode Additional Tools (download from Apple Developer)
- GUI-based, easy to toggle profiles
- Simulates latency, bandwidth limits, packet loss

**Option 2: dnctl + pfctl** (Command line)
```bash
# Create a dummynet pipe with 100ms delay and 10% packet loss
sudo dnctl pipe 1 config delay 100ms plr 0.1

# Apply to loopback traffic
echo "dummynet in proto tcp from any to any pipe 1" | sudo pfctl -f -

# Enable packet filter
sudo pfctl -e

# Remove (disable pf)
sudo pfctl -d
```

#### Linux (CI/Docker)

```bash
# Good WiFi simulation
sudo tc qdisc add dev lo root netem delay 10ms 5ms distribution normal

# Moderate WiFi with packet loss
sudo tc qdisc add dev lo root netem delay 30ms 15ms loss 2%

# Poor WiFi with jitter
sudo tc qdisc add dev lo root netem delay 80ms 40ms 25% loss 5%

# Network hiccup (run briefly then remove)
sudo tc qdisc add dev lo root netem delay 2000ms

# Remove simulation
sudo tc qdisc del dev lo root
```

### Testing Requirements

All sync classes must be designed for testability:

| Principle | Implementation |
|-----------|----------------|
| **Dependency injection** | Classes accept interfaces, not concrete types. `ClockSync` takes a `sendRequest` callback, not a WebSocket. |
| **No side effects in constructor** | Initialization via explicit method or first use |
| **Deterministic time** | Tests inject fake `performance.now()` via parameter or wrapper |
| **Isolated units** | Each class testable without network, DOM, or React |

**Required test coverage:**
- `ClockSync`: NTP calculation, min-RTT selection, slew vs step, drift detection
- `JitterMeasurement`: histogram updates, quantile calculation, forgetting
- `AdaptiveBuffer`: buffer sizing, underrun handling, quality assessment
- `BeatPredictor`: tempo extrapolation, seek detection, dual-threshold snap

### Acceptance Criteria

| Metric | Target | How to Measure |
|--------|--------|----------------|
| Visual accuracy | ±15ms | Compare canvas beat flash to audio callback timestamp |
| Jitter visibility | None perceptible | User study: "Did you see stuttering?" |
| 8-hour drift | <50ms | Automated test with simulated clock drift at 100ppm |
| Recovery time | <3s | Time from network restore to stable display |
| CPU usage | <2% | Chrome DevTools Performance during 1-hour session |

---

## Configuration Reference

### Automatic (Default)

All users get automatic configuration with no setup required:

- Clock sync on connect (8 samples)
- Adaptive jitter buffer (35-150ms range)
- Automatic drift detection and resync
- Graceful degradation on poor networks

### User-Visible Status

All users see:

- Subtle colored dot indicating network quality (green/yellow/orange/red)
- "Reconnecting..." overlay during connection issues
- No numbers or technical details unless requested

### Advanced Settings (Power Users)

Exposed in settings menu:

| Setting | Range | Default | Description |
|---------|-------|---------|-------------|
| Latency/Smoothness | Slider | Center | Trades latency for smoothness |
| Manual Offset | ±50ms | 0 | Fine-tune if perceiving desync |
| Show Timing Stats | Toggle | Off | Display RTT, jitter, offset |
| Force Resync | Button | — | Trigger immediate clock sync |

### Not Exposed

These parameters are hardcoded and not user-configurable:

- Jitter histogram forget factor (0.983)
- Clock sync sample count (8)
- Slew rate (0.5ms/s)
- Buffer floor/ceiling (35-150ms)
- Prediction disable duration formula

---

## Mobile Browser Edge Cases

Mobile browsers have unique constraints that affect timing accuracy:

### iOS Specific

| Issue | Impact | Mitigation |
|-------|--------|------------|
| **Low-Power Mode** | Throttles to 30fps (33ms frames) | Buffer floor at 35ms handles this |
| **Background tab** | `setTimeout` throttled to 1000ms | Disable prediction when `document.hidden` |
| **Screen lock** | WebSocket may disconnect | Full resync on `visibilitychange` |
| **Safari audio policy** | Requires user gesture for audio | N/A for visual-only sync |

### Android Specific

| Issue | Impact | Mitigation |
|-------|--------|------------|
| **Doze Mode** | Network access restricted | WebSocket disconnects; reconnect on wake |
| **Battery Saver** | Variable throttling | Same as iOS Low-Power Mode |
| **Chrome tab freezing** | JS execution paused | Resync on `visibilitychange` |

### Detection and Handling

```typescript
// Detect reduced frame rate (Low-Power Mode, Battery Saver)
let lastFrameTime = performance.now();
let slowFrameCount = 0;

function checkFrameRate(now: number) {
  const delta = now - lastFrameTime;
  lastFrameTime = now;

  if (delta > 25) {  // Slower than 40fps
    slowFrameCount++;
    if (slowFrameCount > 10) {
      // Likely in power-saving mode - increase buffer floor
      adaptiveBuffer.setMinDelay(50);
    }
  } else {
    slowFrameCount = Math.max(0, slowFrameCount - 1);
    if (slowFrameCount === 0) {
      adaptiveBuffer.setMinDelay(35);  // Restore normal floor
    }
  }
}
```

### Page Lifecycle Events

```typescript
// Handle all visibility/lifecycle events
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') {
    // Full resync - clocks may have drifted significantly
    clockSync.performSync();
    networkState.onReconnected();
  } else {
    // Disable prediction to prevent runaway
    beatPredictor.disable();
  }
});

// iOS-specific: detect when returning from background
window.addEventListener('focus', () => {
  // Additional resync opportunity
  if (document.visibilityState === 'visible') {
    clockSync.performSync();
  }
});
```

---

## Implementation Phases

### Phase 1: MVP (Good Networks)

Minimum viable sync for typical home WiFi:

1. Add `t` (server timestamp) to transport messages in Zig extension
2. Implement clock sync request/response in Zig extension
3. Implement `ClockSync` class (NTP-style, 8 samples)
4. Implement basic `BeatPredictor` (tempo extrapolation)
5. Implement smooth exponential blending
6. Create Canvas-based `TransportDisplay` with `requestAnimationFrame`

**Exit criteria:** Beat indicator pulses in sync on good WiFi (RTT <30ms)

### Phase 2: Robustness (Moderate Networks)

Handle network variability:

7. Implement `JitterMeasurement` (relative delay histogram)
8. Implement `AdaptiveBuffer` (35-150ms range)
9. Add transport state change handling (100ms+ disable)
10. Implement `NetworkState` (OPTIMAL/DEGRADED/RECONNECTING)
11. Add network quality indicator to UI

**Exit criteria:** Smooth display on moderate WiFi (RTT 30-80ms, 10-30ms jitter)

### Phase 3: Hardening (Poor Networks)

Graceful degradation:

12. Add prediction runaway prevention (2s freeze)
13. Implement clock drift detection and automatic resync
14. Add sleep/wake recovery (visibility change handler)
15. Implement reconnection with exponential backoff
16. Add "Reconnecting..." overlay

**Exit criteria:** Graceful degradation on poor WiFi (RTT >80ms, >30ms jitter)

### Phase 4: Polish (Studio Quality) ✅ COMPLETE

Production readiness:

17. ✅ Add metrics collection (RTT histogram, prediction error)
18. ✅ Implement advanced settings panel (NetworkStatsModal)
19. ✅ Add manual offset adjustment (±50ms) with localStorage persistence
20. ⏳ Performance optimization (ensure <2% CPU) — needs profiling
21. ✅ Comprehensive test coverage (72 unit tests)

**Exit criteria:** All acceptance criteria met, ready for production use

**Implementation notes:**
- NetworkStatsModal accessible via long-press on ConnectionStatus dot
- Shows real-time RTT, jitter, buffer, offset, network status/quality
- Manual offset slider (±50ms) persists to localStorage
- Resync button forces immediate clock synchronization
- Clock sync uses `Date.now()` (not `performance.now()`) to match server's Unix epoch time

---

## Performance Targets

### Baseline (Must Meet)

These are the minimum acceptable performance levels:

| Metric | Target | Measurement Method |
|--------|--------|-------------------|
| Visual sync accuracy | ±15ms | Automated: compare predicted vs actual position over 1000 samples |
| Jitter visibility | None at 60fps | User study: 5 users, "did you see stuttering?" |
| Clock drift (8hr session) | <50ms accumulated | Automated: log offset delta over 8hr test run |
| Network hiccup recovery | <3 seconds | Automated: inject 2s dropout, measure time to stable display |
| CPU usage | <3% sustained | Chrome DevTools Performance, 1hr session |
| Memory usage | <20MB heap | Chrome DevTools Memory, no leaks over 1hr |
| Initial sync time | <2 seconds | Time from WebSocket open to first synced frame |

### Stretch Goals (Exceed)

Achieving these indicates a best-in-class implementation:

| Metric | Stretch Target | Notes |
|--------|----------------|-------|
| Visual sync accuracy | ±10ms | Matches Ableton Link perceptual quality |
| Clock drift (8hr) | <20ms | Near-NTP quality |
| Recovery time | <1 second | Imperceptible to user |
| CPU usage | <1% sustained | Negligible battery impact on mobile |
| Works on 2.4GHz WiFi | Usable (degraded but functional) | Currently "not recommended" |

### Validation Protocol

Before declaring "production ready," run this validation:

**1. Accuracy Test (Automated)**
```typescript
// Log prediction error over time
const errors: number[] = [];
setInterval(() => {
  const predicted = predictor.getDisplayPosition();
  const actual = lastServerState.position; // Ground truth from next message
  errors.push(Math.abs(predicted - actual));
}, 100);

// After 1000 samples, calculate percentiles
const p50 = percentile(errors, 0.50);
const p95 = percentile(errors, 0.95);
const p99 = percentile(errors, 0.99);

// Targets: p50 < 8ms, p95 < 15ms, p99 < 30ms
```

**2. Jitter Test (Visual)**
- Play transport at 120 BPM for 5 minutes
- Record screen at 120fps (if available) or 60fps
- Analyze beat indicator timing vs metronome reference
- Pass: No visible stutter or drift

**3. Long Session Test (Automated)**
```bash
# Run for 8 hours, log metrics every minute
node scripts/long-session-test.js --duration=8h --log-interval=60s

# Analyze drift: should stay within ±50ms of initial offset
# Check for memory leaks: heap should be stable
```

**4. Network Stress Test**
```bash
# Simulate various conditions, verify graceful degradation
for condition in "good" "moderate" "poor" "hiccup"; do
  ./scripts/apply-network-condition.sh $condition
  sleep 60
  ./scripts/capture-metrics.sh > results/$condition.json
done

# Verify: no crashes, appropriate status indicators, recovery after hiccup
```

**5. User Perception Test**
- 5 musicians use the app while playing along
- Ask: "Does the beat indicator feel in sync with what you hear?"
- Pass: 4/5 users report "yes" or "mostly yes"

### What To Do If Targets Aren't Met

If validation fails, investigate in this order:

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| p95 error > 30ms | Clock sync inaccurate | Increase sample count, check for asymmetric latency |
| Visible jitter | Blend factor too high | Reduce blend factor, increase buffer floor |
| Drift over time | Resync not triggering | Lower drift threshold, increase resync frequency |
| High CPU | Rendering too complex | Simplify canvas drawing, check for React re-renders |
| Memory leak | Unbounded arrays | Add size limits to history arrays |
| Poor WiFi unusable | Buffer ceiling too low | Increase max buffer, accept higher latency |

### Escape Hatches

If WebSocket + prediction can't meet targets:

1. **Increase polling rate** — Try 60Hz instead of 30Hz (diminishing returns)
2. **Binary protocol** — MessagePack for ~20% smaller messages (minimal impact)
3. **Dedicated sync channel** — Separate WebSocket for timing-critical messages only
4. **Ableton Link bridge** — Nuclear option: ReaBlink → Node bridge → WebSocket (see [research/VISUAL_LATENCY.md](../research/VISUAL_LATENCY.md))

The research strongly suggests WebSocket + prediction will meet targets. Escape hatches are documented for completeness but unlikely to be needed.

---



This specification is based on research into:

- **WebRTC NetEQ** — Google's jitter buffer implementation (switched to relative delay in 2022)
- **Source Engine netcode** — `cl_interp`, `cl_interp_ratio`, interpolation buffer
- **Overwatch/Valorant GDC talks** — Modern game networking practices
- **Ableton Link** — Beat synchronization protocol design
- **NTP RFC 5905** — Clock synchronization algorithms
- **VoIP systems** — Adaptive jitter buffer sizing strategies

Key insight: Professional systems never rely on a single strategy. The hybrid approach (blending + buffering + prediction) outperforms any single technique.

---

## Changelog

- **v1.2** — Implementation decisions:
  - Clock sync **bypasses command queue** — handled directly in `ws_server.zig` for timing accuracy
  - Clean break on message format — no backwards compatibility (pre-release project)
  - Added macOS network simulation (Network Link Conditioner, dnctl+pfctl)
  - Added testing requirements (dependency injection, deterministic time, isolated units)
  - Updated `TRANSPORT_SYNC_ANALYSIS.md` with full implementation decisions
- **v1.1** — Validation corrections:
  - Fixed sign error in `getSyncedTime()`: `performance.now() + offset` (not minus)
  - Tightened perception target from ±20ms to ±15ms (20ms is AT threshold, not below)
  - Increased buffer floor from 20ms to 35ms for iOS Low-Power Mode (30fps = 33ms frames)
  - Added "Known Limitations" section documenting tempo automation/ramps
  - Added "Mobile Browser Edge Cases" section (iOS/Android specifics)
  - Implemented dual-threshold snap logic: SEEK_SNAP (1.0 beats) vs DRIFT_SNAP (0.25 beats)
  - Updated validation targets: p50 < 8ms, p95 < 15ms, p99 < 30ms
- **v1.0** — Initial specification based on research sessions
