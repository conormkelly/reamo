# FX Preset Switching — Backend Implementation Plan

**Status:** ✅ COMPLETE (All 10 phases done)
**Last Updated:** 2026-01-02

This is a living document tracking the FX preset switching backend implementation. Update after completing each phase.

---

## Quick Context for New Sessions

**Read these files first:**
- `DEVELOPMENT.md` — Architecture, conventions, FFI validation layer pattern
- `extension/API.md` — Protocol format, existing events
- `PLANNED_FEATURES.md` — FX Preset Switching section for UI concept
- `docs/reaper_plugin_functions.h` — C API signatures (lines 7059-7136, 7306-7351, 7470-7484)

**Key architecture concepts:**
- `raw.zig` — Pure C bindings, returns what REAPER returns
- `RealBackend` — Adds validation via `ffi.safeFloatToInt()`
- `MockBackend` — Injectable state for testing
- `backend.zig` — `validateBackend(T)` ensures both backends have all methods
- Tiered polling in `main.zig`: HIGH=30Hz, MEDIUM=5Hz, LOW=1Hz

---

## Design Decisions

### FX in Tracks Event (Not Separate)

FX state is embedded in the `tracks` event payload, not a separate event. Rationale:
- Simpler frontend — single event contains all track info
- FX polling happens at 5Hz (MEDIUM tier) but is cached and merged into 30Hz track events
- Tracks without FX skip FX API calls entirely (optimization)

### Limits

| Resource | Limit | Rationale |
|----------|-------|-----------|
| FX per track | 64 | Covers extreme cases; most tracks have 1-10 FX |
| FX name length | 128 chars | Matches track name limit |
| Preset name length | 128 chars | Reasonable for display |

### "Modified" Flag Semantics

`TrackFX_GetPreset()` returns `true` if current parameters exactly match the loaded preset.
We invert this: `modified = !TrackFX_GetPreset_return_value`

---

## C API Functions

From `reaper_plugin_functions.h`:

```c
// Get FX count for track
int TrackFX_GetCount(MediaTrack* track);

// Get plugin name
bool TrackFX_GetFXName(MediaTrack* track, int fx, char* bufOut, int bufOut_sz);

// Get current preset index and total count (-1 on error)
int TrackFX_GetPresetIndex(MediaTrack* track, int fx, int* numberOfPresetsOut);

// Get preset name (returns true if params match preset = NOT modified)
bool TrackFX_GetPreset(MediaTrack* track, int fx, char* presetnameOut, int presetnameOut_sz);

// Navigate presets (+1=next, -1=prev)
bool TrackFX_NavigatePresets(MediaTrack* track, int fx, int presetmove);

// Jump to preset by index (-1=default user, -2=factory)
bool TrackFX_SetPresetByIndex(MediaTrack* track, int fx, int idx);
```

---

## Implementation Phases

### Phase 1: raw.zig — C Function Pointers ✅
- [x] Add 6 function pointer fields
- [x] Load in `Api.load()`
- [x] Add wrapper methods

**Files:** `extension/src/reaper/raw.zig`

### Phase 2: types.zig — FX Types ✅
- [x] Add `FxPresetInfo` struct

**Files:** `extension/src/reaper/types.zig`

### Phase 3: real.zig — RealBackend Methods ✅
- [x] Add 6 delegation methods

**Files:** `extension/src/reaper/real.zig`

### Phase 4: mock/ — MockBackend Support ✅
- [x] Add mock FX state fields to `state.zig`
- [x] Add mock methods in `tracks.zig`
- [x] Add to `state.zig` Method enum
- [x] Re-export in `mod.zig`

**Files:** `extension/src/reaper/mock/mod.zig`, `mock/state.zig`, `mock/tracks.zig`

### Phase 5: backend.zig — Update Validator ✅
- [x] Add 6 new methods to `required_methods`

**Files:** `extension/src/reaper/backend.zig`

### Phase 6: tracks.zig — Add FX State ✅
- [x] Add `MAX_FX_PER_TRACK = 64`
- [x] Add `FxSlot` struct
- [x] Add `fx` array and `fx_count` to `Track`
- [x] Update `Track.eql()` to compare FX
- [x] Add FX polling logic (skip if count=0)

**Files:** `extension/src/tracks.zig`

### Phase 7: main.zig — Tiered FX Polling ✅
- [x] FX polled in MEDIUM TIER (5Hz) block
- [x] Updates g_last_tracks directly (no separate cache)
- [x] Merged into 30Hz track events

**Files:** `extension/src/main.zig`

### Phase 8: tracks.zig toJson — Serialize FX ✅
- [x] Update `toJson()` to include `"fx":[...]` array per track

**Files:** `extension/src/tracks.zig`

### Phase 9: Commands — Add Handlers ✅
- [x] Create `commands/fx.zig`
- [x] Implement `fx/presetNext`
- [x] Implement `fx/presetPrev`
- [x] Implement `fx/presetSet`
- [x] Add to `registry.zig`

**Files:** `extension/src/commands/fx.zig`, `commands/registry.zig`

### Phase 10: Documentation ✅
- [x] Update `API.md` — tracks event FX array, FX commands, Limits table
- [x] Update `PLANNED_FEATURES.md` — mark backend done
- [x] Update this plan document

**Files:** `extension/API.md`, `PLANNED_FEATURES.md`, `FX_BACKEND_PLAN.md`

---

## JSON Output Format

After implementation, tracks event will include:

```json
{
  "type": "event",
  "event": "tracks",
  "payload": {
    "tracks": [
      {
        "idx": 1,
        "name": "Guitar",
        "volume": 1.0,
        ...
        "fx": [
          {
            "name": "Neural DSP Archetype Gojira",
            "presetName": "My Clean Tone",
            "presetIndex": 3,
            "presetCount": 12,
            "modified": false
          }
        ]
      }
    ]
  }
}
```

---

## Commands

| Command | Parameters | Description |
|---------|------------|-------------|
| `fx/presetNext` | `trackIdx`, `fxIdx` | Navigate to next preset |
| `fx/presetPrev` | `trackIdx`, `fxIdx` | Navigate to previous preset |
| `fx/presetSet` | `trackIdx`, `fxIdx`, `presetIdx` | Jump to specific preset |

---

## Testing Strategy

1. **Unit tests in tracks.zig** — FX state comparison, JSON serialization
2. **MockBackend tests** — Verify FX API calls are made correctly
3. **Integration test via websocat** — Verify FX appears in tracks event
4. **Command tests** — Verify preset navigation works

---

## Progress Log

| Date | Phase | Notes |
|------|-------|-------|
| 2026-01-02 | Phase 0 | Planning complete, document created |
| 2026-01-02 | Phase 1-9 | All implementation phases complete, tests passing |
| 2026-01-02 | Phase 10 | Documentation updates complete |

---

## Notes & Gotchas

- **Tracks with 0 FX:** Skip all FX API calls for efficiency
- **FX containers:** The API supports nested FX containers (0x2000000 flag) but we ignore this for MVP — only poll top-level FX chain
- **Record input FX:** Can be accessed with 0x1000000 flag but out of scope for MVP
- **Undo points:** Each `TrackFX_SetPresetByIndex` creates an undo point — document for frontend to debounce rapid clicks
