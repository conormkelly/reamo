# Send Control Feature Specification

## Why This Feature Matters

### The Problem

From user research, "adjusting headphone mix or levels" is a reason musicians walk to the computer. While Reamo's mixer handles basic level balance (your track vs other tracks), it doesn't expose **send levels** — the routing to aux buses like reverb, delay, or dedicated cue/headphone mixes.

### Who Actually Needs This

Research reveals a split:
- **70-80%** of home studio users rely on hardware monitoring (interface's zero-latency knob) — the existing mixer solves their needs
- **5-10%** use DAW-based cue systems with pre-fader sends — this feature is for them
- **Professional studios** universally use send-based cue systems — supporting this positions Reamo for demanding use cases

### When Adjustments Happen

Send adjustments occur **between takes, not during performance**:
- Vocalist requests "more me" in headphones
- Drummer wants less click in their mix
- Guitarist asks for more reverb on their monitor

This means sends can live in a secondary UI panel rather than competing for main mixer space.

---

## Feature Overview

| Capability | v1 Scope |
|------------|----------|
| View sends per track | Yes |
| Adjust send level | Yes |
| Mute/unmute send | Yes |
| See destination name | Yes |
| Pre/post fader toggle | No (v2) |
| Send pan | No (v2) |
| Create/delete sends | No (excluded) |
| Hardware output routing | No (excluded) |

---

## REAPER API

### Enumerating Sends

```c
int GetTrackNumSends(MediaTrack* track, int category);
// category: -1 = receives, 0 = sends to tracks, 1 = hardware outputs
// Returns: count of sends in that category
```

### Getting/Setting Send Parameters

```c
double GetTrackSendInfo_Value(
    MediaTrack* tr,
    int category,      // 0 for track sends
    int sendidx,       // 0-based send index
    const char* parmname
);

bool SetTrackSendInfo_Value(
    MediaTrack* tr,
    int category,
    int sendidx,
    const char* parmname,
    double newvalue
);
```

**Key parameters for v1:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `D_VOL` | double | Volume (1.0 = 0dB, linear scale) |
| `B_MUTE` | double | Mute state (0.0 = unmuted, 1.0 = muted) |
| `P_DESTTRACK` | pointer | Destination MediaTrack* (cast from double) |
| `I_SENDMODE` | int | 0=post-fader, 1=pre-FX, 3=post-FX (read-only for v1) |

**Getting destination track name:**

```c
// Option A: Two-step lookup
MediaTrack* destTrack = (MediaTrack*)(intptr_t)GetTrackSendInfo_Value(track, 0, sendIdx, "P_DESTTRACK");
char name[256];
GetTrackName(destTrack, name, sizeof(name));

// Option B: Convenience function
bool GetTrackSendName(MediaTrack* track, int send_index, char* buf, int buf_sz);
```

### Volume Conversion

`D_VOL` is linear, not dB. Conversion:

```zig
// Linear to dB
fn linearToDb(linear: f64) f64 {
    if (linear <= 0.0) return -150.0; // Effectively -inf
    return 20.0 * @log10(linear);
}

// dB to linear
fn dbToLinear(db: f64) f64 {
    return std.math.pow(f64, 10.0, db / 20.0);
}
```

---

## Data Model

### Send State

```typescript
interface Send {
  idx: number;           // Send index on source track
  destTrackIdx: number;  // Destination track index (-1 if master)
  destName: string;      // Destination track name
  volume: number;        // Linear volume (1.0 = 0dB)
  volumeDb: number;      // Volume in dB (computed)
  muted: boolean;        // Mute state
  mode: number;          // 0=post-fader, 1=pre-FX, 3=post-FX (read-only)
}
```

### Extended Track State

Add sends array to existing track data:

```json
{
  "type": "event",
  "event": "tracks",
  "payload": {
    "tracks": [{
      "idx": 1,
      "name": "Vocals",
      "volume": 0.75,
      "sends": [
        {
          "idx": 0,
          "destTrackIdx": 8,
          "destName": "Reverb Bus",
          "volume": 0.5,
          "volumeDb": -6.0,
          "muted": false,
          "mode": 0
        },
        {
          "idx": 1,
          "destTrackIdx": 9,
          "destName": "Cue Mix",
          "volume": 1.0,
          "volumeDb": 0.0,
          "muted": false,
          "mode": 1
        }
      ]
    }]
  }
}
```

---

## Protocol

### Commands

**Set send level:**
```json
{
  "type": "command",
  "command": "send/setVolume",
  "trackIdx": 1,
  "sendIdx": 0,
  "volume": 0.5,
  "id": "1"
}
```

**Set send mute:**
```json
{
  "type": "command",
  "command": "send/setMute",
  "trackIdx": 1,
  "sendIdx": 0,
  "muted": true,
  "id": "2"
}
```

**Alternative: relative adjustment**
```json
{
  "type": "command",
  "command": "send/adjustVolume",
  "trackIdx": 1,
  "sendIdx": 0,
  "deltaDb": -3.0,
  "id": "3"
}
```

### Response

Standard command acknowledgment. Updated send state appears in next `tracks` event.

---

## UI Design

### Recommended Pattern: Per-Track Expandable Panel

Research on personal monitor mixers (Behringer P16, Allen & Heath ME-1, Aviom) shows this mental model:
1. Select a channel
2. See that channel's sends/aux levels
3. Adjust as needed
4. Dismiss and return to main view

**Trigger:** Long-press on track in mixer view

**Panel slides up from bottom:**

```
┌─────────────────────────────────────────────────────────┐
│ Sends from: Vocals                                  [×] │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  → Reverb Bus                                           │
│    ════════════●══════════════════  [M]         -6.0 dB │
│                                                         │
│  → Delay Bus                                            │
│    ══●════════════════════════════  [M]        -18.0 dB │
│                                                         │
│  → Cue Mix                                              │
│    ════════════════════════════════●  M          0.0 dB │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

**Panel elements:**
- Header with source track name and close button
- One row per send
- Destination name (left-aligned)
- Horizontal fader
- Mute button (M) — highlighted when muted
- Current level in dB (right-aligned)

**Dismiss:** Tap [×], tap outside panel, or swipe down

### Empty State

When track has no sends:

```
┌─────────────────────────────────────────────────────────┐
│ Sends from: Vocals                                  [×] │
├─────────────────────────────────────────────────────────┤
│                                                         │
│              No sends configured                        │
│                                                         │
│     Add sends in REAPER to control them here.           │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### Visual Indicators

**In main mixer view:** Consider showing a subtle indicator on tracks that have sends (e.g., small "S" badge or dot). Optional — may add clutter.

**Pre-fader sends:** Show "(pre)" label next to destination name to indicate the send is pre-fader (mode 1 or 3). This is informational only in v1.

---

## Implementation Checklist

### Extension

**API imports:**
- [ ] `GetTrackNumSends`
- [ ] `GetTrackSendInfo_Value`
- [ ] `SetTrackSendInfo_Value`
- [ ] `GetTrackSendName` (or manual P_DESTTRACK lookup)

**State polling:**
- [ ] Add sends array to track state struct
- [ ] Iterate sends per track: `GetTrackNumSends(track, 0)`
- [ ] For each send: get volume, mute, destination
- [ ] Include in tracks event broadcast
- [ ] Consider polling optimization (sends change less frequently than meters)

**Commands:**
- [ ] `send/setVolume` — validate indices, call `SetTrackSendInfo_Value(..., "D_VOL", ...)`
- [ ] `send/setMute` — call `SetTrackSendInfo_Value(..., "B_MUTE", ...)`

### Frontend

**Types:**
- [ ] Add `Send` interface
- [ ] Extend `Track` type with `sends: Send[]`

**Components:**
- [ ] `SendPanel` — slide-up panel container
- [ ] `SendRow` — individual send with fader and mute
- [ ] `SendFader` — horizontal fader component (can reuse/adapt existing fader)

**Interactions:**
- [ ] Long-press track → open SendPanel
- [ ] Fader drag → send `send/setVolume` command
- [ ] Mute button tap → send `send/setMute` command
- [ ] Close button / outside tap / swipe → dismiss panel

**State:**
- [ ] Track which track's send panel is open (if any)
- [ ] Dismiss on track change or navigation

---

## Polling Considerations

Sends change less frequently than track volume/meters. Options:

1. **Poll with tracks (current approach):** Simple, slight overhead
2. **Poll at lower rate:** Only update sends every 5th frame (~6Hz)
3. **Poll on demand:** Only fetch sends when panel is open

**Recommendation:** Start with option 1 (simplest). Optimize if profiling shows impact.

For most projects, track count × sends per track is small (e.g., 16 tracks × 2 sends = 32 sends). This is negligible overhead.

---

## Edge Cases

### Master Track Sends

Master track can have sends (e.g., to parallel compression bus). Handle `destTrackIdx: -1` or special master track index.

### Send to Folder Parent

Valid in REAPER — destination may be the source track's folder parent. No special handling needed, just display correctly.

### Circular Sends

REAPER prevents circular routing at the DAW level. No validation needed in Reamo.

### Many Sends

Some users create elaborate routing (10+ sends per track). The panel should scroll vertically if sends exceed visible area.

### Send Volume Range

REAPER allows send volumes up to +12dB (linear ~4.0). Fader should accommodate this range, or cap display at +12dB.

---

## What's Explicitly Out of Scope

### Hardware Output Routing

Research found **zero evidence** of mid-session hardware routing changes. Every competing app (Avid Control, Logic Remote, TouchOSC templates, SSL 360) excludes this. Hardware outputs are tied to physical studio wiring — set once during session setup.

**Excluded:** `GetTrackNumSends(track, 1)` category for hardware outputs.

### Creating/Deleting Sends

Routing architecture is a setup-time decision. Adding/removing sends mid-session would be unusual and risks breaking the user's carefully configured signal flow.

### MIDI Routing

Completely different subsystem. Out of scope for audio-focused remote control.

### Receives

Category -1 ("receives" — incoming sends to a track) is the inverse view of sends. Could be useful for aux tracks ("who's sending to me?") but adds complexity. Defer to v2.

---

## Future Enhancements (v2)

- **Pre/post fader toggle:** Let users switch send mode remotely
- **Send pan:** For stereo positioning in aux buses
- **Receives view:** Show incoming sends on aux/bus tracks
- **Cue Mix Quick View:** Auto-detect cue buses (by name heuristics: "Cue", "HP", "Headphone", "Monitor") and surface their incoming sends prominently
- **Send meters:** Show send signal level (requires additional API work)
- **Grouped sends:** Show all sends to a particular destination across tracks
