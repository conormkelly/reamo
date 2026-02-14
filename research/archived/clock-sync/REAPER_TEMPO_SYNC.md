# REAPER Tempo Synchronization for Reamo: Achieving 15ms Beat Display Accuracy

REAPER's linear tempo ramps interpolate BPM with respect to **time, not beats**—a critical distinction from most DAWs that determines the exact prediction mathematics. For your WebSocket-based remote UI with variable latency, a **hybrid architecture** combining server-sent tempo maps with client-side prediction offers the best path to ±15ms accuracy. The key API function `TimeMap2_GetDividedBpmAtTime()` returns true interpolated BPM during ramps, and `fullbeats` from `TimeMap2_timeToBeats()` are always measured in **quarter notes** regardless of time signature.

## Linear tempo ramps use time-linear interpolation

When `lineartransOut=true` on a tempo marker, REAPER interpolates BPM linearly against wall-clock time, not beat position. Forum user EricTbone confirmed this behavior: a 120→40 BPM transition takes exactly 3 seconds per bar in REAPER (average tempo = 80 BPM), while Cubase and Guitar Pro take ~3.25 seconds because they interpolate linearly against beats.

**The governing equations for REAPER's time-linear model:**

Given markers with BPM₀ at time t₀ and BPM₁ at time t₁:

```
BPM(t) = BPM₀ + m·(t - t₀)    where m = (BPM₁ - BPM₀)/(t₁ - t₀)

Beats from time:  b(t) = b₀ + (BPM₀·Δt)/60 + m·Δt²/120

Time from beats:  Δt = (-BPM₀ + √(BPM₀² + 120·m·(b - b₀))) / m
```

The duration of a linear ramp region equals `120·(b₁ - b₀)/(BPM₀ + BPM₁)` seconds—equivalent to using the arithmetic mean tempo. This is why SWS source code uses `480*beatCount / (den * (b0 + b1))` for linear ramp calculations.

## Solving the concrete example reveals the asymmetry

**Given:** Marker A at beat 0 = 100 BPM, Marker B at beat 100 = 200 BPM, linear=true.

First, calculate the ramp duration: `Δt = 120·100/(100+200) = 40 seconds`. This gives tempo slope `m = 100/40 = 2.5 BPM/second`.

**At beat 50, instantaneous BPM = ~158.1 BPM** (not 150 as beat-linear would predict). Solving `50 = (100·Δt)/60 + 2.5·Δt²/120` yields t ≈ 23.25 seconds, then `BPM(23.25) = 100 + 2.5·23.25 = 158.1 BPM`.

**Time from beat 50 to beat 51 = ~375ms.** At beat 51, t ≈ 23.625 seconds, so the delta is 0.375 seconds. This matches 60/158 ≈ 380ms, confirming the calculation. Using just instantaneous BPM for 30ms prediction introduces negligible error (~0.2ms) because the tempo change over 30ms is only ~0.075 BPM.

## API clarifications and gotchas

**`GetTempoTimeSigMarker` returns marker BPM, not interpolated.** The `bpmOut` parameter gives the tempo value set AT that marker—the starting point of a ramp when `lineartempo=true`, not the current instantaneous tempo.

**`TimeMap2_GetDividedBpmAtTime(proj, time)` is your friend.** This function returns the true interpolated instantaneous BPM at any time position during linear ramps. The "divided" refers to adjustment for time signature denominator (BPM is 2× in /8 signatures to maintain quarter-note-per-minute consistency).

**`TimeMap_GetTimeSigAtTime` likely returns marker BPM,** not interpolated values. Forum evidence and API patterns suggest using `TimeMap2_GetDividedBpmAtTime` instead for ramp-aware queries.

**`fullbeats` are always quarter notes.** Forum user confirmed: "In reaper tempo is specified in quarters per minute (even though it's labeled as bpm)." Proof: changing time signature from 4/4 to 8/8 to 2/2 while keeping tempo at 120 BPM always puts measure 2 at exactly 2.000 seconds. The `cdenomOutOptional` parameter tells you the current time signature denominator for display conversion.

**Known edge cases:**

- `timesig_num/denom = 0` means "inherit from previous marker"
- When setting tempo markers via API, explicitly set time signature even if unchanged to fix grid alignment issues
- Linear tempo manipulation has "problematic corner cases" per SWS documentation—square markers are easier to manipulate programmatically
- Bug reports mention `TimeMap2_timeToBeats` issues with very large numbers of tempo markers

## Hybrid architecture is optimal for your constraints

Given 20-50ms typical WiFi latency with spikes to 100ms+, and your requirement for ±15ms visual accuracy:

**Recommended: Option C (Hybrid)**

- **Server sends tempo map** on session start and whenever tempo changes occur. This includes all tempo markers with their beat positions, BPM values, `lineartempo` flags, and time signature information.
- **Server sends lightweight ticks at ~30Hz** with: server timestamp, current beat position (fullbeats in quarter notes), current bar.beat.ticks for display, and a sequence number for drift detection.
- **Client maintains local prediction** at 60fps using the tempo map and your NTP-style clock sync. Between server updates, client advances beat position using the appropriate formula (constant or linear ramp based on current tempo region).
- **Client snaps to server position** on each tick, using exponential smoothing to avoid visual jitter: `displayed_beat = displayed_beat + 0.3·(server_beat - displayed_beat)`.

This hybrid approach lets you achieve sub-15ms visual accuracy because the client prediction compensates for network latency, while the 30Hz server updates prevent drift accumulation.

## Client-side prediction mathematics

**During constant tempo regions:**

```
beat_new = beat_current + (bpm / 60) · elapsed_seconds
```

**During linear tempo ramps (REAPER's time-linear model):**

```
// Given: current beat b_c, current time t_c, ramp parameters (t₀, b₀, BPM₀, m)
// Predict 30ms ahead:

t_new = t_c + 0.030
b_new = b₀ + (BPM₀·(t_new - t₀))/60 + m·(t_new - t₀)²/120
```

For practical implementation with small Δt (30ms), you can use a Taylor expansion approximation that's faster to compute:

```
current_bpm = BPM₀ + m·(t_current - t₀)
Δbeat ≈ (current_bpm/60)·Δt + (m/120)·Δt²
```

The quadratic term `(m/120)·Δt²` is tiny for 30ms—at your maximum slope (~2.5 BPM/s), it contributes only 0.00002 beats. **Using instantaneous BPM alone is sufficient** for 30ms prediction during typical ramps.

## Implementation pattern from similar projects

All major REAPER extensions (SWS, ReaLearn, OSC bridges) perform tempo computation server-side. However, they're plugins running in-process, not remote clients. For your networked case:

**From SWS BR_Tempo.cpp:**

```cpp
// Square tempo: offset += (t0 + (240*beatCount) / (den * b0)) - t1;
// Linear tempo: offset += (t0 + (480*beatCount) / (den * (b0 + b1))) - t1;
```

**From ReaLearn (Rust):** Uses audio block timestamps with intra-block MIDI offset for precision timing. Clips support both "Beat" (tempo-dependent) and "Time" (tempo-independent) timebase modes.

**REAPER's built-in web interface** provides a `BEATPOS` request returning: playstate, position_seconds, full_beat_position, measure_cnt, beats_in_measure, ts_numerator, ts_denominator. Your Zig backend can expose similar data via WebSocket.

## Converting fullbeats to bar.beat.ticks display

Since fullbeats are quarter notes regardless of time signature, conversion requires time signature context:

```typescript
function formatBarBeatTicks(
  fullbeats: number, 
  tsNum: number, 
  tsDenom: number, 
  ppq: number = 960
): string {
  const beatsPerBar = tsNum * (4 / tsDenom);  // e.g., 6/8 = 3 quarter-note beats
  const bar = Math.floor(fullbeats / beatsPerBar) + 1;
  const beatInBar = fullbeats % beatsPerBar;
  const wholeBeat = Math.floor(beatInBar) + 1;
  const ticks = Math.round((beatInBar % 1) * ppq);
  return `${bar}.${wholeBeat}.${ticks.toString().padStart(3, '0')}`;
}
```

REAPER's default PPQ is **960 ticks per quarter note**. The `HASDATA` line in item chunks specifies this value.

## Practical recommendations for Reamo

- **Cache tempo map client-side** and rebuild only when server signals changes via a tempo_map_version counter
- **Use TimeMap2_GetDividedBpmAtTime in Zig backend** to get true interpolated BPM for each tick event
- **Send bar.beat.ticks pre-computed from server** since it requires time signature context that may span multiple markers
- **Implement drift detection** by comparing predicted vs server beat positions; trigger tempo map resync if drift exceeds threshold
- **On mobile devices**, the simplified constant-tempo prediction (`beat += bpm/60 * dt`) is adequate for smooth 60fps animation—only enable ramp-aware math when actually inside a linear tempo region
- **Handle play rate changes** separately; REAPER supports non-1.0 play rates which scale tempo proportionally

The ±15ms accuracy target is achievable with this architecture. Your existing NTP-style clock sync handles the network latency measurement, and client-side prediction using REAPER's time-linear tempo model fills the gaps between 30Hz server updates. The main gotcha is ensuring your client correctly identifies which tempo region it's in and applies the appropriate prediction formula.

---

## Follow-up: Transport Tick Event Format

### Question

If we want to display accurate to what REAPER sends, would we send this type of event for the transport tick?

```json
{
  "type": "event",
  "event": "tt",
  "payload": {
    "t": 1234567890.123,
    "b": 45.678,
    "bpm": 127.5,
    "bbt": "12.3.480"
  }
}
```

### Answer

Almost! One catch: `TimeMap2_GetDividedBpmAtTime` returns BPM **scaled to the time signature denominator**, not quarter notes. So in 6/8 at "120 BPM", it returns 240 (eighth notes per minute). That breaks your prediction math which works in quarter notes.

You have a few options:

**Option A: Send raw BPM + time sig (recommended)**

```json
{
  "type": "event",
  "event": "tt",
  "payload": {
    "t": 1234567890.123,
    "b": 45.678,
    "bpm": 127.5,
    "ts": [6, 8],
    "bbt": "12.3.480"
  }
}
```

Get raw BPM by undividing: `rawBpm = dividedBpm * (4 / denom)` on server, or send `ts` and let client do display math. You need time sig anyway for beat indicator animation (knowing when beat 1 hits).

**Option B: Send both BPMs**

```json
{
  "payload": {
    "t": 1234567890.123,
    "b": 45.678,
    "bpmQ": 127.5,
    "bpmD": 255.0,
    "bbt": "12.3.480"
  }
}
```

Where `bpmQ` = quarter notes per minute (for prediction), `bpmD` = divided/display BPM (what REAPER's transport shows). Redundant but unambiguous.

**Option C: Just use marker data**

Since you're already tracking tempo regions client-side for linear ramp prediction, you could skip sending BPM in ticks entirely—client knows the current region and can compute instantaneous BPM itself. Just send:

```json
{
  "payload": {
    "t": 1234567890.123,
    "b": 45.678,
    "bbt": "12.3.480"
  }
}
```

Smallest payload, but requires client to maintain accurate tempo map state.

---

**Recommendation: Option A** with time signature. Here's why:

1. You need `ts` for beat indicator animation anyway (pulse pattern differs in 7/8 vs 4/4)
2. ~10 extra bytes is negligible at 30Hz
3. Client can compute display BPM if needed: `displayBpm = bpm * (ts[1] / 4)`
4. Simpler server code—just send the raw values

```typescript
// Server (Zig) - pseudocode
const tempo = TimeMap_GetTimeSigAtTime(proj, time, &sigNum, &sigDenom, &rawBpm);
// rawBpm here is quarter notes per minute

// Or if you only have divided:
const dividedBpm = TimeMap2_GetDividedBpmAtTime(proj, time);
const rawBpm = dividedBpm * (4.0 / sigDenom);
```

One more consideration: you may want to include measure length in beats (`cml` from `TimeMap2_timeToBeats`) if the client needs to know "how many beats until next bar" for countdown features, though you can derive it from `ts`.
