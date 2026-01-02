# Send Control — Backend Implementation Plan

**Status:** ✅ COMPLETE
**Last Updated:** 2026-01-02

This is a living document tracking the Send Control backend implementation. Update after completing each phase.

---

## Quick Context for New Sessions

**Read these files first:**
- `DEVELOPMENT.md` — Architecture, conventions, FFI validation layer pattern
- `extension/API.md` — Protocol format, existing events
- `features/SEND_CONTROL_FEATURE.md` — Full feature spec with UI concepts
- `FX_BACKEND_PLAN.md` — Similar implementation (FX in tracks event)

**Key architecture concepts:**
- `raw.zig` — Pure C bindings, returns what REAPER returns
- `RealBackend` — Adds validation via `ffi.safeFloatToInt()`
- `MockBackend` — Injectable state for testing
- `backend.zig` — `validateBackend(T)` ensures both backends have all methods
- Tiered polling in `main.zig`: HIGH=30Hz, MEDIUM=5Hz, LOW=1Hz
- Sends poll at 5Hz (MEDIUM tier), merged into 30Hz track events (same pattern as FX)

---

## Design Decisions

### Sends in Tracks Event (Not Separate)

Send state is embedded in the `tracks` event payload, not a separate event. Rationale:
- Matches FX pattern — consistent architecture
- Simpler frontend — single event contains all track info
- Sends polling happens at 5Hz (MEDIUM tier), merged into 30Hz track events
- Tracks without sends skip send API calls entirely (optimization)

### CSurf for Volume Changes

Use `CSurf_OnSendVolumeChange` instead of `SetTrackSendInfo_Value` for:
- Proper undo coalescing (matches track volume/pan behavior)
- Consistency with existing track control pattern

For mute, use `ToggleTrackSendUIMute` (no CSurf equivalent).

### Limits

| Resource | Limit | Rationale |
|----------|-------|-----------|
| Sends per track | 16 | Covers typical use cases; most tracks have 0-4 sends |
| Send dest name length | 128 chars | Matches track name limit |

### Category Parameter

REAPER's send APIs use a `category` parameter:
- `-1` = receives (incoming sends)
- `0` = sends to other tracks
- `1` = hardware outputs

**We only implement category 0 (track sends)** for v1. Hardware outputs excluded per spec.

---

## C API Functions

From `reaper_plugin_functions.h`:

```c
// Get send count for track
int GetTrackNumSends(MediaTrack* track, int category);
// category: 0 = sends to tracks

// Get send parameter value
double GetTrackSendInfo_Value(MediaTrack* tr, int category, int sendidx, const char* parmname);
// Key parmnames: "D_VOL" (linear), "B_MUTE" (0/1), "I_SENDMODE" (0/1/3)

// Get destination track name (convenience)
bool GetTrackSendName(MediaTrack* track, int send_index, char* bufOut, int bufOut_sz);

// Set send volume with undo coalescing
double CSurf_OnSendVolumeChange(MediaTrack* trackid, int send_index, double volume, bool relative);

// Toggle send mute
bool ToggleTrackSendUIMute(MediaTrack* track, int send_idx);

// Direct set (backup for mute if needed)
bool SetTrackSendInfo_Value(MediaTrack* tr, int category, int sendidx, const char* parmname, double newvalue);
```

---

## Implementation Phases

### Phase 1: raw.zig — C Function Pointers ✅
- [x] Add `GetTrackNumSends` function pointer + wrapper
- [x] Add `GetTrackSendInfo_Value` function pointer + wrapper
- [x] Add `GetTrackSendName` function pointer + wrapper
- [x] Add `CSurf_OnSendVolumeChange` function pointer + wrapper
- [x] Add `ToggleTrackSendUIMute` function pointer + wrapper
- [x] Add `SetTrackSendInfo_Value` for explicit mute set
- [x] Load all in `Api.load()`

**Files:** `extension/src/reaper/raw.zig`

### Phase 2: types.zig — Send Types ✅ (SKIPPED)
- [x] Not needed — send data stored directly in `tracks.zig` (matches FX pattern)

**Files:** N/A

### Phase 3: real.zig — RealBackend Methods ✅
- [x] Add `trackSendCount(track)` delegation
- [x] Add `trackSendGetVolume(track, idx)` delegation
- [x] Add `trackSendGetMute(track, idx)` delegation
- [x] Add `trackSendGetMode(track, idx)` delegation
- [x] Add `trackSendGetDestName(track, idx, buf)` delegation
- [x] Add `trackSendSetVolume(track, idx, volume)` using CSurf
- [x] Add `trackSendToggleMute(track, idx)` delegation
- [x] Add `trackSendSetMute(track, idx, muted)` using SetTrackSendInfo_Value

**Files:** `extension/src/reaper/real.zig`

### Phase 4: mock/ — MockBackend Support ✅
- [x] Add `MAX_SENDS_PER_TRACK = 16` constant
- [x] Add `MockSend` struct to `state.zig`
- [x] Add sends array + count to `MockTrack`
- [x] Add mock methods in `mock/tracks.zig`
- [x] Add to `state.zig` Method enum (8 entries)
- [x] Re-export in `mod.zig`

**Files:** `extension/src/reaper/mock/mod.zig`, `mock/state.zig`, `mock/tracks.zig`

### Phase 5: backend.zig — Update Validator ✅
- [x] Add 8 send methods to `required_methods`

**Files:** `extension/src/reaper/backend.zig`

### Phase 6: tracks.zig — Add Send State ✅
- [x] Add `MAX_SENDS_PER_TRACK = 16`
- [x] Add `MAX_SEND_NAME_LEN = 128`
- [x] Add `SendSlot` struct with `eql()` method
- [x] Add `sends` array and `send_count` to `Track`
- [x] Update `Track.eql()` to compare sends

**Files:** `extension/src/tracks.zig`

### Phase 7: main.zig — Tiered Send Polling ✅
- [x] Add send preservation in HIGH TIER (copy forward like FX)
- [x] Add send polling in MEDIUM TIER (5Hz) block alongside FX

**Files:** `extension/src/main.zig`

### Phase 8: tracks.zig toJson — Serialize Sends ✅
- [x] Update `toJson()` to include `"sends":[...]` array per track

**Files:** `extension/src/tracks.zig`

### Phase 9: Commands — Add Handlers ✅
- [x] Create `commands/send.zig`
- [x] Implement `send/setVolume` (uses CSurf_OnSendVolumeChange)
- [x] Implement `send/setMute` (uses SetTrackSendInfo_Value with B_MUTE)
- [x] Add to `registry.zig`

**Files:** `extension/src/commands/send.zig`, `commands/registry.zig`

### Phase 10: Documentation ✅
- [x] Update `API.md` — tracks event sends array, send commands, Limits table
- [x] Update `PLANNED_FEATURES.md` — mark backend done
- [x] Update this plan document

**Files:** `extension/API.md`, `PLANNED_FEATURES.md`, `SEND_BACKEND_PLAN.md`

---

## JSON Output Format

Tracks event includes sends:

```json
{
  "type": "event",
  "event": "tracks",
  "payload": {
    "tracks": [
      {
        "idx": 1,
        "name": "Vocals",
        "volume": 0.75,
        ...
        "sends": [
          {
            "idx": 0,
            "destName": "Reverb Bus",
            "volume": 0.5,
            "muted": false,
            "mode": 0
          },
          {
            "idx": 1,
            "destName": "Cue Mix",
            "volume": 1.0,
            "muted": false,
            "mode": 1
          }
        ]
      }
    ]
  }
}
```

**Note:** `destTrackIdx` and `volumeDb` from the spec are computed on frontend to keep backend simple.

---

## Commands

| Command | Parameters | Description |
|---------|------------|-------------|
| `send/setVolume` | `trackIdx`, `sendIdx`, `volume` | Set send level (linear, 1.0 = 0dB) |
| `send/setMute` | `trackIdx`, `sendIdx`, `muted` | Set send mute state (0/1) |

---

## Testing Strategy

1. **Unit tests in tracks.zig** — Send state comparison, JSON serialization
2. **MockBackend tests** — Verify send API calls are made correctly
3. **Integration test via websocat** — Verify sends appear in tracks event
4. **Command tests** — Verify volume/mute changes work

---

## Progress Log

| Date | Phase | Notes |
|------|-------|-------|
| 2026-01-02 | Phase 0 | Planning complete, document created |
| 2026-01-02 | Phases 1-10 | All phases complete — backend implementation done |

---

## Notes & Gotchas

- **Tracks with 0 sends:** Skip all send API calls for efficiency
- **Send index quirk:** `GetTrackSendName` uses different indexing than `GetTrackSendInfo_Value` — verify behavior
- **Volume range:** Sends can go to +12dB (~4.0 linear) — no clamping needed, frontend handles display
- **Mode values:** 0=post-fader, 1=pre-FX, 3=post-FX (2 is unused)
- **Category always 0:** We only poll/control track sends, not receives or hardware outputs
- **Mute command uses getInt():** `CommandMessage` doesn't have `getBool()`, so we use `getInt("muted")` and convert
