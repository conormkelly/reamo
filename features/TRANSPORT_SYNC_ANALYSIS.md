# Transport Sync Implementation Analysis

> **Purpose:** This document maps the existing codebase to the [TRANSPORT_SYNC.md](TRANSPORT_SYNC.md) specification. It identifies what exists, what needs to change, and integration points. Use this as a guide when implementing — don't rely on assumptions about the codebase.

> **Status:** Living document. Cross-verify findings before implementation.

---

## Executive Summary

**Phase 1 Complete!** Core infrastructure implemented and tested.

**Existing infrastructure (unchanged):**
- ✅ 60fps animation engine with subscriber pattern
- ✅ Position interpolation (seconds-based)
- ✅ Direct DOM updates bypassing React
- ✅ Bidirectional WebSocket for clock sync requests
- ✅ ~30Hz transport polling from REAPER

**Phase 1 implemented:**
- ✅ Server timestamps on messages (`t` field in transport events)
- ✅ Raw beat position in messages (`b` field in transport events)
- ✅ NTP-style clock synchronization protocol (`clockSync`/`clockSyncResponse`)
- ✅ Client-side beat prediction (`BeatPredictor` class)
- ✅ New `TransportSyncEngine` singleton with 60fps updates
- ✅ `useTransportSync` hook for UI integration

**Deferred to Phase 2:**
- ❌ Jitter measurement (adaptive buffering)
- ❌ Canvas-based beat indicator rendering
- ❌ Network quality indicator UI

---

## Backend Architecture (Zig Extension)

### Transport Polling

**File:** [extension/src/main.zig](../extension/src/main.zig)

| Location | Description |
|----------|-------------|
| Line 168 | Timer callback registered at ~30Hz (33ms interval) |
| Line 173-276 | `processTimerCallback()` — polls and broadcasts state |
| Line 273 | `shared_state.broadcast(json)` — sends to all clients |

**Polling strategy:** Uses `.eql()` with tolerance (float diff ≤ 0.001) to avoid broadcasting unchanged state.

### Transport State Collection

**File:** [extension/src/transport.zig](../extension/src/transport.zig)

**`State.poll(api)` (lines 64-91)** calls these REAPER APIs:

| API Call | Purpose | Notes |
|----------|---------|-------|
| `api.playState()` | Transport state | 1=playing, 5=recording, etc. |
| `api.playPosition()` | Playhead in seconds | **Use this one** (latency-compensated) |
| `api.cursorPosition()` | Edit cursor position | Not needed for sync |
| `api.timeToBeats(pos)` | Bar.beat.ticks string | Currently formatted, need raw beats |
| `api.getTempoAtPosition(pos)` | BPM at position | Tempo-map aware |
| `api.timeSelection()` | Loop points | Not needed for sync |
| `api.getBarOffset()` | Bar offset for display | May need for beat calculation |

### Current Message Format

**`State.toJson()` (lines 99-144)** produces:

```json
{
  "type": "event",
  "event": "transport",
  "payload": {
    "playState": 1,
    "position": 24.5,
    "positionBeats": "12.3.45",
    "cursorPosition": 5.0,
    "bpm": 120.0,
    "timeSignature": { "numerator": 4, "denominator": 4 },
    "timeSelection": { "start": 0.0, "end": 30.0 },
    "tempoMarkerCount": 0
  }
}
```

### Required Changes for TRANSPORT_SYNC

1. **Add server timestamp:**
   ```zig
   // In transport.zig State struct, add:
   server_time: f64,  // reaper.time_precise() * 1000.0
   ```

2. **Add raw beat position:**
   ```zig
   // Call api.timeToBeats() but extract the raw fullbeats value
   beat_position: f64,  // Direct beat count, not formatted string
   ```

3. **Add clock sync handler:**
   ```zig
   // In main.zig, handle incoming clockSync requests
   // Echo back t0, add t1 (receive time), t2 (send time)
   ```

4. **Short keys (optional optimization):**
   ```json
   {"t":1234567890.123,"b":24.5,"bpm":120.0,"p":1,"r":0,"ts_n":4,"ts_d":4}
   ```

### REAPER API for Timestamps

**Available in extension API:**
```zig
// High-resolution timer for timestamps
const server_time = api.time_precise() * 1000.0;  // Convert to milliseconds
```

This is already accessible via the `api` pointer passed to `State.poll()`.

---

## Frontend Architecture (TypeScript/React)

### Message Flow

```
WebSocket frame received
    ↓
WebSocketConnection.ts (line 243) — JSON.parse
    ↓
store/index.ts (line 154) — handleWebSocketMessage
    ↓
TransportAnimationEngine.onServerUpdate() — feeds animation
    ↓
Zustand store update — React state
    ↓
Subscribers notified at 60fps — direct DOM updates
```

### WebSocket Connection

**File:** [frontend/src/core/WebSocketConnection.ts](../frontend/src/core/WebSocketConnection.ts)

| Location | Description |
|----------|-------------|
| Line 243 | `JSON.parse(data)` — raw message parsing |
| Line 250-266 | Hello/auth handshake |
| Line 269-275 | Routes to `options.onMessage?.(msg)` |

**Integration point for clock sync:** Add handler before line 269 to intercept `clockSyncResponse` messages and resolve pending promises.

### Store Message Handling

**File:** [frontend/src/store/index.ts](../frontend/src/store/index.ts)

**Transport event handler (lines 159-189):**
```typescript
if (isTransportEvent(message)) {
  const p = message.payload as TransportEventPayload;

  // Feeds animation engine BEFORE store update
  transportEngine.onServerUpdate({
    position: p.position,
    positionBeats: p.positionBeats,
    bpm: p.bpm,
    playState: p.playState,
    timeSignatureNumerator: p.timeSignature.numerator,
    timeSignatureDenominator: p.timeSignature.denominator,
    barOffset: get().barOffset,
  });

  // Then updates Zustand store
  set({ playState: p.playState, positionSeconds: p.position, ... });
}
```

**Integration point:** Insert clock sync processing before `transportEngine.onServerUpdate()`. The predictor should consume the message first, then pass predicted values to the animation engine.

---

## Animation Engine (Critical Component)

**File:** [frontend/src/core/TransportAnimationEngine.ts](../frontend/src/core/TransportAnimationEngine.ts)

This is the heart of the display system. **Read this file carefully before implementing.**

### Architecture

- **Singleton** exported at line 259 as `transportEngine`
- Receives server updates at ~30Hz via `onServerUpdate()` (lines 78-141)
- Runs 60fps loop via `requestAnimationFrame` in `tick()` (lines 154-173)
- Notifies subscribers with interpolated positions (lines 197-209)

### Current Interpolation Logic

**Prediction error detection (lines 107-110):**
```typescript
const elapsed = (now - this.lastServerTime) / 1000;
const predicted = this.serverPosition + (wasPlaying ? elapsed : 0);
const error = Math.abs(data.position - predicted);
```

**Correction strategy (lines 112-124):**
```typescript
const SNAP_THRESHOLD = 0.25;      // 250ms - hard snap for seeks
const SMOOTH_THRESHOLD = 0.05;    // 50ms - ignore small drifts
const CORRECTION_FACTOR = 0.15;   // 15% per update

if (error > SNAP_THRESHOLD) {
  this.localPosition = data.position;  // Snap immediately
} else if (error > SMOOTH_THRESHOLD) {
  // Blend toward server position
  this.localPosition += (data.position - this.localPosition) * CORRECTION_FACTOR;
}
// Errors < 50ms ignored (natural jitter)
```

**Animation frame (lines 154-173):**
```typescript
private tick = (timestamp: number): void => {
  const deltaMs = timestamp - this.lastFrameTime;
  const safeDelta = Math.min(deltaMs, 50);  // Prevent huge jumps
  this.localPosition += safeDelta / 1000;   // Advance by real time elapsed
  this.notifySubscribers();
  this.rafId = requestAnimationFrame(this.tick);
};
```

### Critical Gap: Beat Position Not Predicted

**Line 220-222:**
```typescript
private formatBeats(_positionSeconds: number): string {
  return this.lastPositionBeats;  // Always returns last SERVER value!
}
```

This means beats are NOT interpolated — they update at 30Hz (server rate), not 60fps. **This is the primary target for TRANSPORT_SYNC implementation.**

### Integration Strategy

**Option A: Extend TransportAnimationEngine**
- Add `ClockSync` and `BeatPredictor` as dependencies
- Modify `onServerUpdate()` to use synced timestamps
- Replace `formatBeats()` with predicted beat position

**Option B: Replace TransportAnimationEngine**
- Create new `transport-sync/` module per TRANSPORT_SYNC.md spec
- Update store to use new module instead
- Keep old engine as fallback

**Recommendation:** Option A — the existing engine already has the subscriber pattern, interpolation thresholds, and 60fps loop. Extend rather than replace.

---

## Display Components

### ClockView (Primary Target)

**File:** [frontend/src/views/clock/ClockView.tsx](../frontend/src/views/clock/ClockView.tsx)

**Transport consumption (lines 70-76):**
```typescript
useTransportAnimation((state) => {
  if (timeRef.current) {
    timeRef.current.textContent = formatTime(state.position, { precision: 1 });
  }
  if (beatsRef.current) {
    beatsRef.current.textContent = state.positionBeats;  // Server value, not predicted
  }
}, []);
```

**Key insight:** Already uses direct DOM updates via refs, bypassing React reconciliation. This is exactly what TRANSPORT_SYNC.md recommends. The component is ready — just needs predicted beat values.

**BPM display (line 63):**
```typescript
const bpm = useReaperStore((s) => s.bpm);
```
Comes from Zustand store, updates on server messages. Fine as-is (BPM doesn't need 60fps updates).

### Transport Hooks

**File:** [frontend/src/hooks/useTransport.ts](../frontend/src/hooks/useTransport.ts)

| Hook | Purpose |
|------|---------|
| `useTransport()` | Provides state + actions (play/pause/record) |
| `useTransportAnimation()` | Subscribes to 60fps animation updates |

Components using animation hook get smooth positions but stale beats. After TRANSPORT_SYNC, they'll get predicted beats too.

---

## Type Definitions

**File:** [frontend/src/core/WebSocketTypes.ts](../frontend/src/core/WebSocketTypes.ts)

### Current Transport Payload (lines 78-93)

```typescript
interface TransportEventPayload {
  playState: PlayState;
  position: number;              // seconds
  positionBeats: string;         // "bar.beat.ticks" formatted
  cursorPosition: number;        // seconds
  bpm: number;
  timeSignature: { numerator: number; denominator: number };
  timeSelection: { start: number; end: number };
  tempoMarkerCount: number;
}
```

### Required Additions

```typescript
// New message types for clock sync
interface ClockSyncRequest {
  type: 'clockSync';
  t0: number;  // Client send time
}

interface ClockSyncResponse {
  type: 'clockSyncResponse';
  t0: number;  // Echoed client send time
  t1: number;  // Server receive time
  t2: number;  // Server send time
}

// Extended transport payload (or new short-key format)
interface TransportEventPayloadV2 {
  t: number;    // Server timestamp (ms)
  b: number;    // Beat position (raw float)
  bpm: number;  // Tempo
  p: number;    // Play state
  r: number;    // Recording (0/1)
  ts_n: number; // Time sig numerator
  ts_d: number; // Time sig denominator
}
```

---

## Store State

**File:** [frontend/src/store/slices/transportSlice.ts](../frontend/src/store/slices/transportSlice.ts)

### Relevant State Fields

```typescript
playState: PlayState;
positionSeconds: number;
positionString: string;
positionBeats: string;
bpm: number | null;
fullBeatPosition: number;          // Exists but may not be populated
timeSignatureNumerator: number;
timeSignatureDenominator: number;
barOffset: number;
```

### BPM Calculation (lines 83-105)

```typescript
const rawBpm = (beatPos.fullBeatPosition / beatPos.positionSeconds) * 60;
const calculatedBpm = rawBpm * (4 / beatPos.timeSignatureDenominator);
```

Note: BPM is calculated from beat position, not just taken from server. This may need adjustment if beat prediction changes the position values.

---

## Prerequisites Checklist

**All prerequisites verified and implemented in Phase 1.**

### Backend Prerequisites

- [x] `api.time_precise()` is accessible in transport.zig
- [x] Raw beat position (not just formatted string) can be extracted
- [x] WebSocket can handle new message types (clockSync/clockSyncResponse)

### Frontend Prerequisites

- [x] `performance.now()` available (standard in browsers)
- [x] WebSocket connection stable enough for sync samples
- [x] Animation engine subscriber pattern tested at 60fps

### Testing Prerequisites

- [x] Can measure actual round-trip time (RTT) in DevTools
- [x] Can log prediction errors for validation
- [ ] Have a way to compare visual beat to audio (screen recording?)

---

## Integration Points Summary

| Component | File | Line(s) | Change Required |
|-----------|------|---------|-----------------|
| Transport polling | extension/src/transport.zig | 64-91 | Add `time_precise()` call |
| Message serialization | extension/src/transport.zig | 99-144 | Add `t`, `b` fields |
| Clock sync handler | extension/src/main.zig | New | Add request/response handler |
| Message types | frontend/src/core/WebSocketTypes.ts | 78-93 | Add sync types |
| Store handler | frontend/src/store/index.ts | 159-189 | Insert predictor before engine |
| Animation engine | frontend/src/core/TransportAnimationEngine.ts | 78-141, 220 | Add clock sync, beat prediction |
| Clock display | frontend/src/views/clock/ClockView.tsx | 70-76 | Already ready (uses refs) |

---

## Implementation Order

Based on dependencies and risk:

### Phase 1: Server Timestamps ✅ COMPLETE

1. ✅ Add `server_time` field to transport.zig (`t` field)
2. ✅ Update WebSocketTypes.ts with new field
3. ✅ Log timestamps in browser to verify flow
4. ✅ **Validated:** Messages contain timestamps, no breaking changes

### Phase 2: Clock Sync Protocol ✅ COMPLETE

5. ✅ Add ClockSync class to frontend (`lib/transport-sync/ClockSync.ts`)
6. ✅ Add clock sync handler to Zig extension (bypasses command queue)
7. ✅ Implement sync on WebSocket connect
8. ✅ **Validated:** RTT measurement works, offset calculated correctly

### Phase 3: Beat Prediction ✅ COMPLETE

9. ✅ Add BeatPredictor class (`lib/transport-sync/BeatPredictor.ts`)
10. ✅ Wire into TransportSyncEngine
11. ✅ Provide predicted beat values via useTransportSync hook
12. ✅ **Validated:** Beats predicted at 60fps, unit tests pass

### Phase 2: Performance & Precision (In Progress)

13. ✅ **Lightweight transport tick** - `tt` event with `t`, `b`, `bpm`, `ts`, `bbt` (~120 bytes vs ~350)
    - Backend: `stateOnlyEql()`, `toTickJson()` in transport.zig
    - Frontend: `onTickEvent()` in TransportSyncEngine, `onTickUpdate()` in BeatPredictor
14. ✅ **Tempo-map-aware prediction** - Server sends instantaneous BPM in each tick
    - Backend: `TimeMap_GetTimeSigAtTime` returns raw quarter-note BPM (verified in 6/8 project)
    - Frontend: Uses server-provided BPM directly (handles tempo ramps correctly)
    - `getTempoAtBeat()` still available as fallback for edge cases
15. ⏭️ **CSurf API integration** - EVALUATED, NOT NEEDED
    - Research: `research/ZIG_IREAPERCONTROLSURFACE.md`
    - Finding: CSurf `Run()` and `register("timer")` share same ~30Hz UI loop
    - Only benefit: Instant `SetPlayState()` callbacks (saves up to 33ms on play/pause)
    - Decision: Current timer + client interpolation achieves ±15ms goal without C++ shim complexity
16. **Goal:** Professional-quality sync with minimal bandwidth, accurate across tempo changes

**Enhanced tick format (verified working):**
```json
{"type":"event","event":"tt","payload":{"t":1767206735939.808,"b":82.08,"bpm":90.00,"ts":[6,8],"bbt":"9.5.08"}}
```
- `t`: Server timestamp (ms)
- `b`: Beat position (quarter notes from project start)
- `bpm`: Instantaneous quarter-note BPM from `TimeMap_GetTimeSigAtTime`
- `ts`: Time signature `[numerator, denominator]`
- `bbt`: Server-computed bar.beat.ticks (includes bar offset)

**Message frequency with CSurf:**
| Data | Trigger | Format |
|------|---------|--------|
| `t`, `b` | CSurf position callback (60Hz+) | Lightweight tick |
| Full transport state | Play/pause/stop/seek | Full event |
| Tempo map | On change | Dedicated event |

### Phase 3: Jitter Compensation (Deferred)

17. ❌ Add JitterMeasurement class
18. ❌ Add AdaptiveBuffer class
19. ❌ Wire into prediction pipeline
20. **Deferred:** Will implement if real-world testing shows jitter issues

### Phase 4: Polish (Deferred)

21. ❌ Add network quality indicator
22. ❌ Add advanced settings (manual offset)
23. ✅ Optimize message format (short keys: `t`, `b`)
24. **Partially complete:** Core functionality works, UI polish deferred

---

## Known Risks

| Risk | Mitigation |
|------|------------|
| Clock drift between browser and REAPER | Periodic resync (every 5 min per spec) |
| Tempo changes during playback | Detect tempo change, disable prediction briefly |
| Network hiccups cause runaway prediction | 2-second prediction timeout per spec |
| Breaking existing animation engine | Keep old code paths as fallback |
| Performance regression from sync overhead | Profile before/after, target <2% CPU |

---

## Answered Questions (Researched)

### 1. Tempo Map Handling ✅ ANSWERED

**Question:** Does `getTempoAtPosition()` return correct BPM during tempo ramps?

**Answer: YES.** It is position-aware and handles tempo automation correctly.

**Implementation:** [extension/src/reaper.zig](../extension/src/reaper.zig) lines 395-405
```zig
pub fn getTempoAtPosition(self: *const Api, time: f64) TempoAtPosition {
    var num: c_int = 4;
    var denom: c_int = 4;
    var bpm: f64 = 120;
    if (self.timeMap_GetTimeSigAtTime) |f| {
        f(null, time, &num, &denom, &bpm);
    }
    return .{ .bpm = bpm, .timesig_num = num, .timesig_denom = denom };
}
```

**Underlying REAPER API:** `TimeMap_GetTimeSigAtTime` — returns tempo AND time signature at any position.

**Implication for sync:** Beat prediction can use the tempo at the current position, which will be correct even with tempo automation/ramps.

---

### 2. Bar Offset ✅ ANSWERED

**Question:** How does `barOffset` affect beat calculation? Is it factored into `timeToBeats()`?

**Answer: SEPARATE.** `barOffset` is a display-only adjustment applied AFTER beat calculation.

**How it works:**
- `timeToBeats()` returns physical bar/beat numbers from REAPER (time-based)
- `barOffset` is added only for display: `display_bar = position_bar + bar_offset`
- When converting back, it's reversed: `actual_bar = bar - bar_offset`

**Location:** [extension/src/transport.zig](../extension/src/transport.zig) lines 101-102
```zig
var display_bar = self.position_bar + self.bar_offset;
```

**Implication for sync:** Beat prediction should use raw beat position, NOT display-adjusted values. The `barOffset` is purely cosmetic for display.

---

### 3. Time Signature Changes ✅ ANSWERED

**Question:** If time sig changes mid-song, does prediction need to detect this?

**Answer: YES, and infrastructure exists.** A dedicated `tempomap.State` already tracks all tempo/time signature markers.

**Implementation:** [extension/src/tempomap.zig](../extension/src/tempomap.zig) lines 14-36
```zig
pub fn poll(api: *const reaper.Api) State {
    var state = State{};
    state.count = api.tempoMarkerCount();

    var hash: u64 = 0;
    for (0..count) |i| {
        if (api.getTempoMarker(@intCast(i))) |marker| {
            state.markers[i] = marker;
            // Hash includes position, BPM, AND time signature
            hash ^= @as(u64, @intCast(marker.timesig_num)) << 32;
            hash ^= @as(u64, @intCast(marker.timesig_denom)) << 40;
        }
    }
    state.hash = hash;
    return state;
}
```

**Change detection:** `tempomap.changed()` compares hash — detects tempo AND time sig changes.

**TempoMarker structure includes:**
- `position: f64` — time position in seconds
- `position_beats: f64` — beat position (total beats from project start)
- `bpm: f64` — tempo at this marker
- `timesig_num: c_int` — time signature numerator
- `timesig_denom: c_int` — time signature denominator
- `linear_tempo: bool` — true = linear ramp to next marker

**Implication for sync:** When tempo map changes (detected via hash), prediction should briefly disable or re-anchor to server state. The `tempoMap` event is already broadcast when changes occur.

#### Key Research Findings (from REAPER_TEMPO_SYNC.md)

1. **Linear tempo ramps are TIME-linear, not beat-linear**
   - REAPER interpolates BPM linearly against wall-clock time
   - Current client-side interpolation by beat progress has ~0.2ms error (acceptable for ±15ms target)
   - Server now sends instantaneous BPM, making this a non-issue

2. **`fullbeats` are always quarter notes** regardless of time signature
   - In 6/8 at 90 BPM: REAPER counts 90 quarter notes per minute
   - Changing time signature doesn't affect beat accumulation rate
   - Prediction math is time-signature-independent

3. **API returns raw quarter-note BPM**
   - `TimeMap_GetTimeSigAtTime` returns 90 in 6/8 project (not 180)
   - No "undivide" logic needed for our use case
   - `TimeMap2_GetDividedBpmAtTime` would need undividing (we don't use it)

4. **Time signature role:**
   - Beat prediction: NOT needed (all quarter notes)
   - bar.beat.ticks display: Needed (server computes)
   - Beat indicator animation: Needed (sent in `ts` field)

---

### 4. Recording Latency ✅ ANSWERED

**Question:** Is `playPosition()` still accurate during recording, or is there additional latency?

**Answer: SAME BEHAVIOR.** No special recording latency compensation exists in the extension.

**Evidence:**
- Same `playPosition()` API used for both playing (state=1) and recording (state=5)
- [extension/src/transport.zig](../extension/src/transport.zig) line 67: `const play_pos = api.playPosition();`
- No conditional logic for recording mode

**Play state constants:** [extension/src/transport.zig](../extension/src/transport.zig) lines 147-166
```zig
pub const PlayState = struct {
    pub const STOPPED: c_int = 0;
    pub const PLAYING: c_int = 1;
    pub const PAUSED: c_int = 2;
    pub const RECORDING: c_int = 5;  // Uses same playPosition()
    pub const RECORD_PAUSED: c_int = 6;
};
```

**Implication for sync:** Recording uses the same position sync as playback. Any input latency compensation (for what the user is recording) is handled by REAPER's audio engine, not the display position. The visual transport position will match playback, which is correct for the remote display use case.

---

### 5. Multiple Clients ⚠️ NEEDS VERIFICATION

**Question:** Does clock sync work correctly with multiple browser clients connected?

**Answer: ARCHITECTURALLY YES, but needs testing.**

**Why it should work:**
- Each WebSocket client has its own connection instance
- Clock sync is per-client (each calculates its own offset)
- Transport broadcasts go to all clients simultaneously
- No shared state between client sync calculations

**Potential concern:**
- If clock sync requests are handled sequentially in the Zig extension, multiple clients syncing simultaneously could delay each other
- Need to verify the WebSocket command handler doesn't block

**Recommendation:** Test with 2-3 simultaneous clients before considering production-ready.

---

## Critical Finding: Raw Beat Position ✅ RESOLVED

### The `fullBeatPosition` Gap

**Previous problem:** Transport events sent `positionBeats` as a formatted string ("12.3.45"), but beat prediction needs the raw float value.

**Resolution:** Raw beat position is now sent as the `b` field in transport events.

**Where it exists:** [extension/src/reaper.zig](../extension/src/reaper.zig) lines 668-688
```zig
pub fn timeToBeats(self: *const Api, time: f64) BeatsInfo {
    // ...
    var fullbeats: f64 = 0;  // <-- THIS IS THE RAW BEAT POSITION
    const beats_in_measure = f(null, time, &measures, null, &fullbeats, &cdenom);
    return .{
        .beats = fullbeats,  // Total beats from project start
        .measures = measures + 1,
        .beats_in_measure = beats_in_measure,
        .time_sig_denom = cdenom,
    };
}
```

**BeatsInfo structure:**
```zig
pub const BeatsInfo = struct {
    beats: f64,           // Total beats from project start (in denominator units)
    measures: c_int,      // Measure number (1-based)
    beats_in_measure: f64, // Beat within measure (0-indexed with fraction)
    time_sig_denom: c_int, // Time signature denominator
};
```

**Current usage in transport.zig:**
- Line 72: `const beats_info = api.timeToBeats(current_pos);`
- But only formatted string is sent, not `beats_info.beats`

**Frontend type exists:** [frontend/src/core/types.ts](../frontend/src/core/types.ts) lines 42-51
```typescript
export interface BeatPosition {
  fullBeatPosition: number;  // RAW beat position (float) - EXISTS but not populated from transport event
  // ...
}
```

**Implemented in Phase 1:**
1. ✅ In `transport.zig`, added `beats_info.beats` to JSON payload as `b` field
2. ✅ Updated `WebSocketTypes.ts` to include the new field
3. ✅ BeatPredictor uses raw value for prediction

**Note on beat units:** `fullBeatPosition` counts in denominator units:
- 4/4 time: counts quarter notes
- 6/8 time: counts eighth notes
- Frontend already handles this — see [transportSlice.ts](../frontend/src/store/slices/transportSlice.ts) lines 84-96 for normalization

---

## Clock Sync Handler — BYPASS COMMAND QUEUE ✅ DECIDED

### Why Bypass the Command Queue

The normal command flow adds variable latency (0-33ms depending on timer cycle position):

```
Normal Command Path (DON'T USE FOR CLOCK SYNC):
WebSocket Message → SharedState.pushCommand() → Ring buffer queue
                  → Timer callback (~30Hz) → commands/mod.zig dispatch
                  → Handler → response
```

For NTP-style sync, `t1` must be recorded **at message arrival**, not "when dequeued". Using the queue adds 0-33ms of jitter to timestamp measurements, defeating the purpose.

### Clock Sync Path (BYPASS QUEUE)

```
Clock Sync Message
       ↓
ws_server.zig: Client.clientMessage() [line 288-346]
       ↓
INTERCEPT HERE: Check for "clock/sync" command
       ↓
Record t1 = time_precise() IMMEDIATELY
       ↓
Build response with t0, t1, t2
       ↓
Send response directly (bypass queue)
```

### Implementation Location

**File:** [extension/src/ws_server.zig](../extension/src/ws_server.zig)

In `Client.clientMessage()`, add clock sync interception **before** `pushCommand()`:

```zig
fn clientMessage(self: *Client, data: []const u8) void {
    // Parse message
    const parsed = protocol.parseMessage(data) orelse return;

    // CLOCK SYNC BYPASS: Handle immediately for timing accuracy
    if (parsed.isCommand("clock/sync")) {
        self.handleClockSync(parsed);
        return;  // Don't queue
    }

    // Normal path: queue for timer callback
    self.shared_state.pushCommand(parsed);
}

fn handleClockSync(self: *Client, msg: protocol.Message) void {
    const t1 = reaper.time_precise() * 1000.0;  // Receive time in ms

    const t0 = msg.getFloat("t0") orelse {
        self.sendError("MISSING_T0", "t0 is required");
        return;
    };

    const t2 = reaper.time_precise() * 1000.0;  // Send time in ms

    var buf: [256]u8 = undefined;
    const response = std.fmt.bufPrint(&buf,
        "{{\"type\":\"clockSyncResponse\",\"t0\":{d:.3},\"t1\":{d:.3},\"t2\":{d:.3}}}",
        .{ t0, t1, t2 }
    ) catch return;

    self.send(response);
}
```

### Protocol

**Client sends:**
```json
{"type":"clockSync","t0":1704067200000.123}
```

**Server responds (immediately, no queue):**
```json
{"type":"clockSyncResponse","t0":1704067200000.123,"t1":1704067200005.456,"t2":1704067200005.789}
```

Note: Uses dedicated message type `clockSync`/`clockSyncResponse`, not the command/response pattern. This makes interception cleaner and avoids command registry overhead.

### Threading Consideration

`time_precise()` is thread-safe (just reads a clock). The WebSocket runs in a separate thread from the REAPER timer callback, but this is fine — we're not calling REAPER APIs that modify state.

### Key Files

| File | Purpose |
|------|---------|
| `extension/src/ws_server.zig` | WebSocket server — add clock sync interception here |
| `extension/src/reaper.zig` | `time_precise()` wrapper |

---

## All Questions Answered

| Question | Status | Summary |
|----------|--------|---------|
| Tempo map handling | ✅ | `getTempoAtPosition()` is position-aware, handles automation |
| Bar offset | ✅ | Display-only adjustment, separate from beat calculation |
| Time signature changes | ✅ | `tempomap.State` tracks changes via hash |
| Recording latency | ✅ | Same `playPosition()` API, no special handling |
| Multiple clients | ⚠️ | Architecturally OK, needs testing |
| Clock sync handler | ✅ | **BYPASS queue** — handle directly in `ws_server.zig` for timing accuracy |
| Raw beat position | ✅ | Available as `beats_info.beats`, needs to be added to transport event |

**Implementation can now begin. No remaining unknowns.**

---

## Implementation Decisions (Final)

These decisions were made after spec validation and are locked in:

### Backend (Zig)

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Clock sync path** | Bypass command queue | t1/t2 timestamps need actual receive/send time, not "when dequeued". Queue adds 0-33ms jitter. |
| **Message format** | Clean break, new format only | No backwards compatibility needed — not shipped yet |
| **Transport message keys** | Short keys (`t`, `b`, `p`, `r`, `ts_n`, `ts_d`) | 18% size reduction, cleaner protocol |
| **Stability priority** | Mission critical | Crashing REAPER risks livelihoods. Defensive coding, thorough testing. |

### Frontend (TypeScript)

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Module location** | New `lib/transport-sync/` | Clean separation, unit testable in isolation, doesn't pollute existing code |
| **Rendering** | Canvas from the start | Spec recommends it for 60fps independent of React. Avoids later refactor. |
| **State exposure** | New `useTransportSync()` hook | Components opt-in to synced values. Can integrate with Redux later if needed. |
| **Existing code** | Keep as fallback initially | `TransportAnimationEngine` remains functional until new system proven |

### Testing Strategy

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Unit tests** | From day 1, all sync classes | `ClockSync`, `JitterMeasurement`, `AdaptiveBuffer`, `BeatPredictor` — all testable in isolation |
| **Dependency injection** | Required | Classes accept interfaces, not concrete implementations. Enables mocking. |
| **Network simulation** | Network Link Conditioner / dnctl+pfctl | macOS native tools, good enough for latency/jitter testing |
| **Automated validation** | Prediction error percentiles | p50 < 8ms, p95 < 15ms, p99 < 30ms — logged and verified |

### Code Quality

| Principle | Enforcement |
|-----------|-------------|
| **Modular classes** | Each class has single responsibility, injectable dependencies |
| **No side effects in constructors** | Initialization via explicit `init()` or first use |
| **Immutable configuration** | Config passed at construction, not mutated |
| **Explicit error handling** | No silent failures, errors propagate or log |
| **Memory safety (Zig)** | No allocations in hot paths, bounded buffers |

---

## Appendix: File Quick Reference

### Backend (Zig)
- `extension/src/main.zig` — Entry point, timer callback, WebSocket server
- `extension/src/transport.zig` — Transport state polling and serialization
- `extension/src/websocket.zig` — WebSocket connection handling (if exists)

### Frontend (TypeScript)
- `frontend/src/core/WebSocketConnection.ts` — WebSocket client
- `frontend/src/core/WebSocketTypes.ts` — Message type definitions
- `frontend/src/core/TransportAnimationEngine.ts` — 60fps interpolation
- `frontend/src/store/index.ts` — Message routing to store
- `frontend/src/store/slices/transportSlice.ts` — Transport state
- `frontend/src/hooks/useTransport.ts` — Transport hooks
- `frontend/src/views/clock/ClockView.tsx` — Big clock display

### Specification
- `features/TRANSPORT_SYNC.md` — Full implementation spec
- `research/VISUAL_LATENCY.md` — Background research
- `research/JITTER_COMPENSATION.md` — Algorithm research
- `research/REAPER_TEMPO_SYNC.md` — Tempo API research and equations

---

*Last updated: Phase 2 enhanced tick format complete. Server now sends BPM, time signature, and bar.beat.ticks in each tick event. Foundation verified correct before CSurf API integration.*
