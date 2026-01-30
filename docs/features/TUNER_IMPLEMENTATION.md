# Tuner View Implementation Design

High-level design for adding a chromatic tuner view to REAmo. See [TUNER.md](./TUNER.md) for the JSFX algorithm specification.

---

## Overview

The Tuner view provides studio-quality pitch detection via a bundled JSFX plugin, displayed on the phone through the existing WebSocket infrastructure. Uses a **subscription model** following the `trackFxParams` pattern—multiple clients can subscribe to tuners on different tracks simultaneously.

### Key Behaviors

- **Subscription-based** — client subscribes to a track GUID, backend handles JSFX lifecycle
- **Multi-client** — guitarist and bassist can tune on different tracks simultaneously
- **Input FX chain** — JSFX inserted into Input FX (monitoring FX), not track FX chain
- **Auto-insert** — JSFX inserted at position 0 when first client subscribes to a track
- **Auto-remove** — JSFX removed when last client unsubscribes from that track
- **GUID-addressed** — track GUID + FX GUID for stability across track reordering
- **Adjustable params** — reference frequency (A4) and silence threshold from frontend
- **Strobe mode** — optional fine-tuning display with visual motion feedback

### Threading Model

**All tuner subscription operations run on the main thread only.** This is enforced by the existing command processing architecture:

1. WebSocket thread receives command → pushes to mutex-protected queue
2. Main thread timer callback processes queue → executes REAPER API calls
3. Main thread polls subscriptions → generates events → pushes to clients

The `ref_count` field in `TrackTuner` is safe without additional synchronization because all reads/writes occur on the main thread during command processing or polling.

### Why Input FX Chain?

The tuner JSFX is inserted into the **Input FX chain** (record input FX) rather than the regular track FX chain:

1. **Pre-recording** — Input FX processes signal before it reaches the track, so the tuner analyzes the raw input
2. **Non-destructive** — Doesn't affect what gets recorded or the playback FX chain
3. **Standard practice** — Input FX is where monitoring tools (tuners, input meters) belong
4. **No interference** — Won't interact with compression, EQ, or other track FX

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ REAPER                                                                       │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │ Guitar Track (subscribed by Client A)                                   ││
│  │                                                                          ││
│  │  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────┐   ││
│  │  │ Audio In    │───▶│ INPUT FX    │───▶│ Track FX    │───▶│ Record/ │   ││
│  │  └─────────────┘    │ PitchDetect │    │ (user's FX) │    │ Output  │   ││
│  │                      │ sliders 0-5 │    └─────────────┘    └─────────┘   ││
│  │                      └──────┬──────┘                                     ││
│  └─────────────────────────────┼───────────────────────────────────────────┘│
│                                │                                             │
│  ┌─────────────────────────────┼───────────────────────────────────────────┐│
│  │ Bass Track (subscribed by Client B)                                     ││
│  │                                                                          ││
│  │  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────┐   ││
│  │  │ Audio In    │───▶│ INPUT FX    │───▶│ Track FX    │───▶│ Record/ │   ││
│  │  └─────────────┘    │ PitchDetect │    │ (user's FX) │    │ Output  │   ││
│  │                      │ sliders 0-5 │    └─────────────┘    └─────────┘   ││
│  │                      └──────┬──────┘                                     ││
│  └─────────────────────────────┼───────────────────────────────────────────┘│
│                                │                                             │
│  ┌─────────────────────────────▼───────────────────────────────────────────┐│
│  │ Zig Extension                                                           ││
│  │  TunerSubscriptions (similar to TrackFxParamSubscriptions)              ││
│  │  - Insert to Input FX chain (recFX=true), use 0x1000000 offset          ││
│  │  - Per-track ref counting: insert JSFX on first sub, remove on last     ││
│  │  - 30Hz polling: TrackFX_GetParam(fx+0x1000000) → per-client events     ││
│  └─────────────────────────────┬───────────────────────────────────────────┘│
└────────────────────────────────┼────────────────────────────────────────────┘
                                 │ WebSocket (tuner events to each subscriber)
        ┌────────────────────────┴────────────────────────────────┐
        ▼                                                         ▼
┌───────────────────────────────────┐     ┌───────────────────────────────────┐
│ Client A (Guitarist)              │     │ Client B (Bassist)                │
│  ┌───────────────────────────────┐│     │  ┌───────────────────────────────┐│
│  │           ┌─────┐             ││     │  │           ┌─────┐             ││
│  │           │  E  │             ││     │  │           │  E  │             ││
│  │           │  2  │             ││     │  │           │  1  │             ││
│  │           └─────┘             ││     │  │           └─────┘             ││
│  │         82.4 Hz               ││     │  │         41.2 Hz               ││
│  │  [▼ Guitar Track        ]     ││     │  │  [▼ Bass Track          ]     ││
│  └───────────────────────────────┘│     │  └───────────────────────────────┘│
└───────────────────────────────────┘     └───────────────────────────────────┘
```

---

## Backend Changes

### 1. TrackSkeleton Enhancement

Add `it` (inputType) field to enable efficient client-side filtering without extra round-trips.

**Location:** `extension/src/state/track_skeleton.zig`

```zig
SkeletonTrack struct:
  + input_type: u8  // 0=none, 1=audio, 2=midi

JSON output:
  + "it": 0|1|2  // After "r" (rec_arm) field
```

**Encoding:**
- `0` = No input (I_RECINPUT < 0)
- `1` = Audio input (bit 12 NOT set)
- `2` = MIDI input (bit 12 set, 0x1000 mask)

```zig
// Implementation in track_skeleton.zig poll():
const rec_input = api.getTrackRecInput(track);  // c_int from I_RECINPUT
if (rec_input < 0) {
    entry.input_type = 0;  // No input
} else if ((rec_input & 0x1000) != 0) {
    entry.input_type = 2;  // MIDI (bit 12 set)
} else {
    entry.input_type = 1;  // Audio
}
```

The frontend filters `skeleton.filter(t => t.r && t.it === 1)` to get armed audio tracks.

### 2. Tuner Subscriptions Module

**Location:** `extension/src/subscriptions/tuner_subscriptions.zig` (new file)

Follows the `TrackFxParamSubscriptions` pattern with key difference: **per-track reference counting** for JSFX lifecycle management.

```zig
/// Input FX index offset — all TrackFX_* calls for Input FX need this added to the index
pub const INPUT_FX_OFFSET: c_int = 0x1000000;

/// Per-track tuner state (shared across clients subscribing to same track)
pub const TrackTuner = struct {
    track_guid: [40]u8,
    track_guid_len: u8,
    fx_guid: [40]u8,         // GUID of inserted PitchDetect JSFX (in Input FX chain)
    fx_guid_len: u8,
    fx_index: c_int,          // Raw index in Input FX chain (0, 1, 2...)
    ref_count: u8,            // Number of clients subscribed to this track

    // Configurable params (shared across subscribers to this track)
    reference_hz: f32 = 440.0,    // A4 reference frequency
    silence_threshold: f32 = -60.0, // dB threshold for "no signal"

    /// Get the FX index for use with TrackFX_* API calls
    pub fn getApiFxIndex(self: *const TrackTuner) c_int {
        return self.fx_index + INPUT_FX_OFFSET;
    }
};

/// Per-client subscription (which track they're subscribed to)
pub const ClientSubscription = struct {
    active: bool = false,
    track_guid: [40]u8,
    track_guid_len: u8,
    consecutive_failures: u8 = 0,  // Auto-unsub after 3 failures
};

pub const TunerSubscriptions = struct {
    allocator: Allocator,

    // Per-client subscriptions (slot-based, like TrackFxParamSubscriptions)
    clients: [MAX_CLIENTS]ClientSubscription,
    client_id_to_slot: AutoHashMap(usize, usize),

    // Per-track tuner state (multiple clients can share one track's tuner)
    track_tuners: AutoHashMap([40]u8, TrackTuner),

    // Previous state hash per client (for change detection)
    prev_hash: [MAX_CLIENTS]u64,

    // Force broadcast flag per client (set on subscribe)
    force_broadcast_clients: [MAX_CLIENTS]bool,

    // Free list for slot recycling
    free_slots: [MAX_CLIENTS]usize,
    free_count: usize,

    pub fn init(allocator: Allocator) TunerSubscriptions;
    pub fn deinit(self: *TunerSubscriptions) void;
    pub fn subscribe(self: *TunerSubscriptions, client_id: usize, track_guid: []const u8, api: anytype) !SubscribeResult;
    pub fn unsubscribe(self: *TunerSubscriptions, client_id: usize, api: anytype) void;
    pub fn setParam(self: *TunerSubscriptions, track_guid: []const u8, param: TunerParam, value: f32, api: anytype) !void;
    pub fn removeClient(self: *TunerSubscriptions, client_id: usize, api: anytype) void;
    pub fn hasSubscriptions(self: *const TunerSubscriptions) bool;
    pub fn activeSubscriptions(self: *TunerSubscriptions) SubscriptionIterator;
    pub fn getTrackTuner(self: *TunerSubscriptions, track_guid: []const u8) ?*TrackTuner;
    pub fn checkChanged(self: *TunerSubscriptions, slot: usize, data_hash: u64) bool;
    pub fn recordFailure(self: *TunerSubscriptions, client_id: usize) bool;  // Returns true if threshold reached
    pub fn resetFailures(self: *TunerSubscriptions, client_id: usize) void;

    /// Remove all clients and clean up all JSFXs (called on shutdown).
    /// Iterates all active subscriptions and calls unsubscribe for each,
    /// which handles ref_count decrement and JSFX removal.
    pub fn removeAllClients(self: *TunerSubscriptions, api: anytype) void {
        var key_iter = self.client_id_to_slot.keyIterator();
        while (key_iter.next()) |client_id_ptr| {
            const client_id = client_id_ptr.*;
            self.unsubscribe(client_id, api);
        }
        // Clear the map after iteration
        self.client_id_to_slot.clearRetainingCapacity();
    }
};
```

**Lifecycle:**

1. `subscribe(trackGuid)`:
   - If no existing `TrackTuner` for this GUID:
     - Insert JSFX: `TrackFX_AddByName(track, "JS:REAmo/PitchDetect", recFX=true, -1000)`
     - `recFX=true` → Input FX chain, `-1000` → insert at position 0
     - Get GUID: `TrackFX_GetFXGUID(track, fx_index + 0x1000000)`
     - Store `fx_index`, `fx_guid` in new `TrackTuner`
   - Increment `ref_count` on the `TrackTuner`
   - Store client subscription pointing to track GUID
   - Return `{ trackGuid, fxGuid, trackName }`

2. `unsubscribe()`:
   - Decrement `ref_count` on the `TrackTuner`
   - If `ref_count == 0`:
     - Remove JSFX: `TrackFX_Delete(track, fx_index + 0x1000000)`
     - Remove `TrackTuner` entry from map
   - Clear client subscription

3. `setParam(trackGuid, param, value)`:
   - Find `TrackTuner` for this GUID
   - Update `reference_hz` or `silence_threshold`
   - Call `TrackFX_SetParam(track, fx_index + 0x1000000, slider, value)` to update JSFX

### 3. Tuner Commands

**Location:** `extension/src/commands/tuner_subs.zig` (new file)

| Command | Parameters | Response | Description |
|---------|------------|----------|-------------|
| `tuner/subscribe` | `trackGuid` | `{trackGuid, fxGuid, trackName, reference, threshold}` | Subscribe to tuner on track. Inserts JSFX if first subscriber. |
| `tuner/unsubscribe` | — | `{success: true}` | Unsubscribe from tuner. Removes JSFX if last subscriber. |
| `tuner/setParam` | `trackGuid, param, value` | `{success: true}` | Set tuner param (reference or threshold) |

**Parameters for `tuner/setParam`:**
- `param`: `"reference"` (A4 Hz, default 440) or `"threshold"` (silence dB, default -60)
- `value`: float value

**Error responses (command failures):**
```json
{"type": "response", "id": "123", "success": false, "error": "TRACK_NOT_FOUND", "message": "Track GUID not found in cache"}
```

| Error Code | Cause |
|------------|-------|
| `TRACK_NOT_FOUND` | trackGuid doesn't exist in GUID cache |
| `FX_INSERT_FAILED` | TrackFX_AddByName returned -1 (JSFX not installed) |
| `NOT_SUBSCRIBED` | setParam called for track with no active tuner |
| `INVALID_PARAM` | Unknown param name (not "reference" or "threshold") |

**Error events (async failures during polling):**

When the tuner JSFX is deleted by the user or the track is removed, the polling loop detects the failure and sends an error event before auto-unsubscribing:

```json
{"type": "event", "event": "tunerError", "payload": {"trackGuid": "{...}", "error": "FX_NOT_FOUND"}}
```

### 4. Tuner Generator

**Location:** `extension/src/subscriptions/tuner_generator.zig` (new file)

Generates `tuner` events for active subscriptions at 30Hz.

```zig
const ffi = @import("../core/ffi.zig");

pub const TunerData = struct {
    freq: f64,
    note: i32,       // MIDI note number (69 = A4)
    cents: f64,      // Deviation from note (-50 to +50)
    conf: f64,       // Confidence 0-1
};

/// Generate tuner event JSON for a subscription.
/// fx_index is the raw Input FX index (0, 1, 2...) — offset is applied internally.
/// Returns null on error (track not found, FX not found, invalid slider values).
pub fn generateTunerEvent(
    allocator: Allocator,
    api: anytype,
    guid_cache: *GuidCache,
    track_guid: []const u8,
    fx_index: c_int,          // Raw Input FX index
    reference_hz: f32,
) ?[]const u8 {
    const track = guid_cache.resolve(track_guid) orelse return null;
    const api_fx_idx = fx_index + INPUT_FX_OFFSET;  // Add 0x1000000 for Input FX

    // Read sliders 0-3 from Input FX with FFI validation
    // REAPER can return NaN/Inf from slider reads - must validate per ffi.zig pattern
    const freq_raw = api.trackFxGetParam(track, api_fx_idx, 0, null, null);
    const note_raw = api.trackFxGetParam(track, api_fx_idx, 1, null, null);
    const cents_raw = api.trackFxGetParam(track, api_fx_idx, 2, null, null);
    const conf_raw = api.trackFxGetParam(track, api_fx_idx, 3, null, null);

    // Validate all values are finite (not NaN or Inf)
    if (!ffi.isFinite(freq_raw) or !ffi.isFinite(note_raw) or
        !ffi.isFinite(cents_raw) or !ffi.isFinite(conf_raw)) {
        return null;
    }

    const freq = freq_raw;
    const note = ffi.safeFloatToInt(i32, note_raw) catch return null;
    const cents = cents_raw;
    const conf = conf_raw;

    // Compute note name and octave from MIDI note number
    const note_names = [_][]const u8{ "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" };
    const note_name = note_names[@intCast(@mod(note, 12))];
    const octave = @divFloor(note, 12) - 1;  // MIDI note 0 = C-1
    const in_tune = @abs(cents) < 2.0;

    // Build JSON (allocate buffer, write event envelope)...
}

/// Compute hash of tuner event for change detection.
pub fn hashTunerEvent(json: []const u8) u64 {
    return std.hash.Wyhash.hash(0, json);
}
```

**Event format:**
```json
{
  "type": "event",
  "event": "tuner",
  "payload": {
    "trackGuid": "{AAAA...}",
    "freq": 440.02,
    "note": 69,
    "noteName": "A",
    "octave": 4,
    "cents": 0.08,
    "conf": 0.95,
    "inTune": true
  }
}
```

Note: `noteName`, `octave`, and `inTune` computed server-side. `inTune` is `|cents| < 2`.

### 5. main.zig Integration

The tuner follows the established subscription pattern in `main.zig`. Key integration points:

**1. Global state variable** (add near line 70):
```zig
var g_tuner_subs: ?*tuner_subscriptions.TunerSubscriptions = null;
```

**2. Import** (add near line 28):
```zig
const tuner_subscriptions = @import("subscriptions/tuner_subscriptions.zig");
const tuner_generator = @import("subscriptions/tuner_generator.zig");
```

**3. Initialization** in `doInitialization()` (add after trackfxparam_subs block ~line 272):
```zig
// Create tuner subscriptions state
const tuner_subs = try g_allocator.create(tuner_subscriptions.TunerSubscriptions);
tuner_subs.* = tuner_subscriptions.TunerSubscriptions.init(g_allocator);
g_tuner_subs = tuner_subs;
commands.g_ctx.tuner_subs = tuner_subs;
```

**4. Client context** in `ClientContext` struct (client_management.zig):
```zig
tuner_subs: ?*tuner_subscriptions.TunerSubscriptions,
```

**5. Polling context** in `PollingContext` struct (subscription_polling.zig):

Add field after `csurf_sends_dirty`:

```zig
/// Tuner subscriptions (optional, may be null if not initialized)
tuner_subs: ?*tuner_subscriptions.TunerSubscriptions = null,
```

And add import at top of file:

```zig
const tuner_subscriptions = @import("../subscriptions/tuner_subscriptions.zig");
const tuner_generator = @import("../subscriptions/tuner_generator.zig");
```

**6. Shutdown cleanup** (add before peaks_cache cleanup ~line 893):
```zig
if (g_tuner_subs) |subs| {
    logging.info("cleaning up tuner subscriptions", .{});
    commands.g_ctx.tuner_subs = null;
    // Note: unsubscribe all clients to remove JSFXs before deinit
    subs.removeAllClients(&backend);
    subs.deinit();
    g_allocator.destroy(subs);
    g_tuner_subs = null;
}
logging.info("tuner subscriptions cleaned up", .{});
```

### 6. Polling Integration

**Location:** `extension/src/server/subscription_polling.zig`

Add `pollTunerSubscriptions` function and call from main polling loop (30Hz):

```zig
pub fn pollTunerSubscriptions(
    ctx: *const PollingContext,
    subs: *tuner_subscriptions.TunerSubscriptions,
) !void {
    if (!subs.hasSubscriptions()) return;

    var iter = subs.activeSubscriptions();
    while (iter.next()) |entry| {
        const scratch = ctx.tiered.scratchAllocator();

        // Get track tuner state for this subscription
        const tuner = subs.getTrackTuner(entry.track_guid) orelse continue;

        if (tuner_generator.generateTunerEvent(
            scratch,
            ctx.backend,
            ctx.guid_cache_ptr,
            entry.track_guid,
            tuner.fx_index,
            tuner.reference_hz,
        )) |json| {
            // Check if changed using hash
            const data_hash = tuner_generator.hashTunerEvent(json);
            if (subs.checkChanged(entry.slot, data_hash)) {
                ctx.shared_state.sendToClient(entry.client_id, json);
            }
            // Reset failure count on successful generation
            subs.resetFailures(entry.client_id);
        } else {
            // Track or FX not found - increment failure count
            if (subs.recordFailure(entry.client_id)) {
                // Auto-unsubscribe after 3 failures (~100ms at 30Hz)
                logging.warn("tuner: auto-unsubscribing client {d} after repeated failures", .{entry.client_id});

                // Send error event to client before unsubscribing
                const error_json = std.fmt.allocPrint(scratch,
                    "{{\"type\":\"event\",\"event\":\"tunerError\",\"payload\":{{\"trackGuid\":\"{s}\",\"error\":\"FX_NOT_FOUND\"}}}}",
                    .{entry.track_guid}
                ) catch continue;
                ctx.shared_state.sendToClient(entry.client_id, error_json);

                subs.unsubscribe(entry.client_id, ctx.backend);
            }
        }
    }
}
```

**Call site** in `doProcessing()` (after trackfxparam polling ~line 724):
```zig
// Poll tuner subscriptions
if (g_tuner_subs) |tuner_subs| {
    try subscription_polling.pollTunerSubscriptions(&poll_ctx, tuner_subs);
}
```

---

## Frontend Changes

### 1. Navigation Integration

**Position in VIEW_ORDER:** After Clock

```typescript
// TabBar.tsx, SideRail.tsx
const VIEW_ORDER: ViewId[] = [
  'timeline', 'mixer', 'clock', 'tuner', 'playlist', 'actions', 'notes', 'instruments'
];
```

**Icon:** `AudioWaveform` from lucide-react (or similar waveform icon)

### 2. View Registration

**Location:** `frontend/src/viewRegistry.ts`

```typescript
import { TunerView } from './views/tuner';

export const views = {
  // ...existing
  tuner: TunerView,
} as const;

export const viewMeta = {
  // ...existing
  tuner: { label: 'Tuner' },
};
```

### 3. Tuner Store Slice

**Location:** `frontend/src/store/slices/tunerSlice.ts`

```typescript
interface TunerData {
  trackGuid: string;
  freq: number;
  note: number;
  noteName: string;
  octave: number;
  cents: number;
  conf: number;
  inTune: boolean;
}

interface TunerSlice {
  // State
  tunerSubscribed: boolean;
  tunerTrackGuid: string | null;
  tunerFxGuid: string | null;
  tunerData: TunerData | null;
  tunerReference: number;      // A4 Hz (default 440)
  tunerThreshold: number;      // Silence dB (default -60)
  strobeMode: boolean;

  // Actions
  subscribeTuner: (trackGuid: string) => Promise<void>;
  unsubscribeTuner: () => Promise<void>;
  setTunerParam: (param: 'reference' | 'threshold', value: number) => Promise<void>;
  setStrobeMode: (enabled: boolean) => void;
  _handleTunerEvent: (payload: TunerData) => void;
}
```

### 4. TunerView Component Structure

**Location:** `frontend/src/views/tuner/`

```
tuner/
├── index.ts
├── TunerView.tsx
└── components/
    ├── index.ts
    ├── NoteDisplay.tsx       # Large note + octave (e.g., "A4")
    ├── CentsMeter.tsx        # Linear -50 to +50 meter
    ├── StrobeMeter.tsx       # Animated strobe bars
    ├── FrequencyDisplay.tsx  # "440.0 Hz"
    ├── TrackSelector.tsx     # Dropdown of armed audio tracks
    ├── TunerSettings.tsx     # Reference Hz, threshold adjustments
    └── NoSignalState.tsx     # "Waiting for signal..." empty state
```

### 5. View Lifecycle

```typescript
function TunerView() {
  const subscribeTuner = useReaperStore(s => s.subscribeTuner);
  const unsubscribeTuner = useReaperStore(s => s.unsubscribeTuner);
  const [selectedTrack, setSelectedTrack] = useState<string | null>(null);

  // Get armed audio tracks from skeleton
  const armedAudioTracks = useMemo(() =>
    skeleton.filter(t => t.r && t.it === 1),
    [skeleton]
  );

  // Auto-select first armed audio track on mount
  useEffect(() => {
    if (!selectedTrack && armedAudioTracks.length > 0) {
      setSelectedTrack(armedAudioTracks[0].g);
    }
  }, [armedAudioTracks, selectedTrack]);

  // Subscribe/unsubscribe when selected track changes
  useEffect(() => {
    if (selectedTrack) {
      subscribeTuner(selectedTrack);
      return () => { unsubscribeTuner(); };
    }
  }, [selectedTrack, subscribeTuner, unsubscribeTuner]);

  // ... render
}
```

### 6. Track Filtering

Filter skeleton for armed tracks with audio input:

```typescript
const armedAudioTracks = useMemo(() =>
  skeleton.filter(t => t.r && t.it === 1),  // r=armed, it=1=audio
  [skeleton]
);
```

---

## UI Design

### Standard Meter Mode

```
┌────────────────────────────────────────────┐
│                                            │
│                  ┌─────┐                   │
│                  │  A  │                   │  ← Note name (96px font)
│                  │  4  │                   │  ← Octave (48px font)
│                  └─────┘                   │
│                                            │
│    -50          ▼          +50             │  ← Cents labels
│    ┌──────────────────────────────┐        │
│    │     │          ■            │        │  ← Meter bar with indicator
│    └──────────────────────────────┘        │
│                 +2.3¢                      │  ← Numeric cents value
│                                            │
│              440.0 Hz                      │  ← Frequency
│                                            │
│    [▼ Guitar Track 1              ]        │  ← Track selector dropdown
│    [⚙️ A4: 440 Hz | Threshold: -60dB]      │  ← Settings (collapsible)
│                                            │
└────────────────────────────────────────────┘
```

**Colors:**
- In tune (|cents| < 2): Green (`--color-success`)
- Close (|cents| < 10): Yellow (`--color-warning`)
- Out of tune: Red (`--color-error`)

### Strobe Mode

```
┌────────────────────────────────────────────┐
│                                            │
│                  ┌─────┐                   │
│                  │  A  │                   │
│                  │  4  │                   │
│                  └─────┘                   │
│                                            │
│    ║  ║  ║  ║  ║  ║  ║  ║  ║  ║  ║  ║     │  ← Strobe bars (animated)
│    ║  ║  ║  ║  ║  ║  ║  ║  ║  ║  ║  ║     │    Direction = sharp/flat
│                                            │    Speed = how far off
│               ✓ IN TUNE                    │  ← Status indicator
│                                            │
│              440.0 Hz                      │
│                                            │
│    [▼ Guitar Track 1              ]        │
│                                            │
└────────────────────────────────────────────┘
```

**Strobe behavior:**
- **Stationary** = In tune
- **Moving right** = Sharp (pitch too high)
- **Moving left** = Flat (pitch too low)
- **Speed** = Proportional to |cents| deviation
- Animation uses CSS `@keyframes` with `transform: translateX()` for 60fps

### No Signal State

```
┌────────────────────────────────────────────┐
│                                            │
│                   🎸                       │  ← Icon (muted)
│                                            │
│          Waiting for signal...             │
│                                            │
│        Play a note on your instrument      │
│                                            │
│    [▼ Guitar Track 1              ]        │
│                                            │
└────────────────────────────────────────────┘
```

Shown when `conf < 0.3` or `freq === 0`.

---

## Implementation Sequence

### Wave 1: Backend Foundation
1. Add `it` field to track_skeleton.zig
2. Create tuner_subscriptions.zig (following trackfxparam_subscriptions pattern)
3. Create tuner_generator.zig
4. Create tuner_subs.zig commands (subscribe/unsubscribe/setParam)
5. Register commands in registry.zig
6. Add polling to 30Hz timer
7. Update API.md

### Wave 2: Frontend Core
1. Add tuner event type to WebSocketTypes
2. Create tunerSlice
3. Add event handler in store
4. Create TunerView skeleton
5. Register in viewRegistry, TabBar, SideRail

### Wave 3: Frontend UI
1. NoteDisplay component
2. CentsMeter component
3. TrackSelector component
4. NoSignalState component

### Wave 4: Polish
1. StrobeMeter component with CSS animation
2. TunerSettings component (reference Hz, threshold)
3. Mode toggle in ViewHeader or settings
4. Persist preferences to localStorage

---

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| No armed tracks | Show "No armed tracks with audio input" message |
| Track deleted while subscribed | Auto-unsubscribe (consecutive failures → auto-unsub) |
| WebSocket disconnect | Client re-subscribes on reconnect |
| User arms new track | No change to existing subscription (sticky selection) |
| User disarms current track | Keep subscription (input still flows) |
| Multiple clients, same track | Shared JSFX, ref-counted cleanup |
| Multiple clients, different tracks | Independent JSFX per track |
| FX manually deleted by user | Next poll fails → consecutive failures → auto-unsub |

---

## JSFX Slider Mapping

From [TUNER.md](./TUNER.md):

| Slider | Name | Range | Description |
|--------|------|-------|-------------|
| 0 | Frequency | 0-4000 Hz | Detected fundamental frequency |
| 1 | Note | 0-127 | MIDI note number (69 = A4) |
| 2 | Cents | -50 to +50 | Deviation from nearest note |
| 3 | Confidence | 0-1 | Detection confidence |
| 4 | Reference | 400-480 Hz | A4 reference (adjustable) |
| 5 | Threshold | -96 to 0 dB | Silence threshold (adjustable) |

**Read:** sliders 0-3 at 30Hz via `TrackFX_GetParam(track, fx_index + 0x1000000, slider)`
**Write:** sliders 4-5 via `tuner/setParam` → `TrackFX_SetParam(track, fx_index + 0x1000000, slider, value)`

**Input FX Offset:** All TrackFX_* calls for Input FX require adding `0x1000000` to the FX index.

---

## Future Enhancements

- **Alternate tunings presets** (Drop D, DADGAD, etc.)
- **Calibration mode** (adjust A4 reference from external source)
- **Polyphonic mode** (detect all 6 strings simultaneously)
- **Reference tone generator** (play target pitch through REAPER)

---

## Test Cases

Unit tests should cover the following scenarios (in `tuner_subscriptions_test.zig`):

### Subscription Lifecycle
- `init` and `deinit` without leaks
- `subscribe` creates TrackTuner with ref_count=1
- `subscribe` same track increments ref_count
- `unsubscribe` decrements ref_count
- `unsubscribe` with ref_count=1 removes TrackTuner
- `removeClient` cleans up properly
- `removeAllClients` removes all JSFXs on shutdown

### Multi-Client Scenarios
- Two clients subscribe to same track → shared JSFX, ref_count=2
- One client unsubscribes → JSFX remains, ref_count=1
- Second client unsubscribes → JSFX removed
- Two clients subscribe to different tracks → separate JSFXs

### Error Handling
- Subscribe to non-existent track GUID returns error
- FX insert failure (JSFX not installed) returns error
- `setParam` on non-subscribed track returns error
- Consecutive failures trigger auto-unsubscribe

### Generator Tests
- Valid slider values produce correct JSON
- NaN/Inf slider values return null
- Note name computation (A4=69, C4=60, etc.)
- `inTune` flag set correctly for |cents| < 2

### Change Detection
- Same data produces same hash (no spurious broadcasts)
- Different data produces different hash
- `force_broadcast` triggers send even if hash unchanged

---

## JSFX Installation

The PitchDetect JSFX must be installed in REAPER's Effects folder:

| Platform | Path |
|----------|------|
| macOS | `~/Library/Application Support/REAPER/Effects/REAmo/PitchDetect.jsfx` |
| Windows | `%APPDATA%\REAPER\Effects\REAmo\PitchDetect.jsfx` |
| Linux | `~/.config/REAPER/Effects/REAmo/PitchDetect.jsfx` |

The `JS:REAmo/PitchDetect` identifier used in `TrackFX_AddByName` relies on this path structure.

---

## Related Files

| File | Purpose |
|------|---------|
| [TUNER.md](./TUNER.md) | JSFX algorithm specification |
| `Effects/REAmo/PitchDetect.jsfx` | The bundled JSFX plugin (see installation paths above) |
| `frontend/src/utils/input.ts` | Input type utilities (isMidiInput) |
| `extension/src/subscriptions/trackfxparam_subscriptions.zig` | Reference pattern for subscriptions |
| `extension/src/subscriptions/trackfxparam_generator.zig` | Reference pattern for event generation |
| `extension/src/core/ffi.zig` | FFI validation utilities (safeFloatToInt, isFinite) |
