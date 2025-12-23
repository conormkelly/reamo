# WebSocket Extension Refactoring Strategy

## Overview

This document captures the architectural changes needed to scale the extension from 23 commands to 100+ commands while maintaining robustness and testability.

**Current state:** Phase 4b-7 complete (61 commands total, protocol hardened)
**Target:** Complete frontend feature parity per AUDIT.md

---

## ⚠️ Critical Implementation Principle

**Always prefer REAPER's built-in action commands over manual implementations.**

REAPER has thousands of battle-tested action commands (accessible via `Main_OnCommand`). Before implementing any functionality manually:

1. **Search for existing REAPER commands** - Check the REAPER action list or `reaper_plugin_functions.h`
2. **Use `runCommand(id)` when possible** - One line, battle-tested, handles edge cases
3. **Only implement manually when**:
   - No REAPER command exists for the exact operation
   - You need to return data (REAPER commands are fire-and-forget)
   - You need parameter flexibility beyond what the command offers

**Example - marker navigation:**
```zig
// BAD: Manual implementation (30+ lines, potential bugs)
fn handleMarkerNext(...) {
    var best_pos: ?f64 = null;
    while (api.enumMarker(idx)) |info| { ... }  // Reimplementing REAPER logic
}

// GOOD: Use REAPER's built-in command (1 line, battle-tested)
fn handleMarkerNext(...) {
    api.runCommand(reaper.Command.GO_TO_NEXT_MARKER);  // Command 40173
}
```

---

## Current Architecture

```
extension/src/
├── main.zig        (222 lines) - Entry, lifecycle, timers
├── reaper.zig      (398 lines) - REAPER C API wrapper
├── transport.zig   (183 lines) - Transport state, change detection
├── markers.zig     (238 lines) - Marker/region state
├── items.zig       (315 lines) - Item/take state
├── protocol.zig    (333 lines) - JSON parsing/building
├── commands.zig    (404 lines) - Command handlers, registry
└── ws_server.zig   (315 lines) - WebSocket server, threading
```

**Total: 2,408 lines, 23 commands**

### Strengths
- Clean module separation by domain
- Testable state modules (run without REAPER)
- Safe patterns (safeFloatToInt, validatePosition)
- O(1) ring buffer command queue
- Change detection (only broadcast on actual changes)

### Scaling Problems
1. `commands.zig` will grow to 1200+ lines with 77 new commands
2. No response correlation (fire-and-forget commands)
3. No protocol versioning or authentication
4. Missing track state module

---

## Target Architecture

```
extension/src/
├── main.zig              - Entry, lifecycle, timers (minimal changes)
├── reaper.zig            - REAPER C API wrapper (add ~30 APIs)
├── protocol.zig          - JSON + hello/version/response (expand)
├── ws_server.zig         - WebSocket server (add response routing)
│
├── state/                - State polling modules
│   ├── mod.zig           - Re-exports
│   ├── transport.zig     - Transport + repeat + bar offset
│   ├── markers.zig       - Markers & regions
│   ├── items.zig         - Items & takes
│   └── tracks.zig        - NEW: Track state + input metering
│
└── commands/             - Command handlers by domain
    ├── mod.zig           - Dispatch + registry aggregation
    ├── transport.zig     - play, stop, seek, goStart, goEnd, etc.
    ├── time_sel.zig      - set, setBeats, clear, goStart, goEnd
    ├── repeat.zig        - set, toggle
    ├── markers.zig       - add, update, delete, goto, prev, next
    ├── regions.zig       - add, update, delete, goto
    ├── items.zig         - setActiveTake, move, color, lock, etc.
    ├── takes.zig         - delete, cropToActive, next, prev
    ├── tracks.zig        - setVolume, setPan, setMute, setSolo, etc.
    ├── tempo.zig         - set, tap, setTimeSignature
    ├── metronome.zig     - toggle, setVolume
    ├── undo.zig          - add, begin, end
    ├── extstate.zig      - get, set, setPersist, projGet, projSet
    └── actions.zig       - getState, execute
```

---

## Key Design Decisions

### 1. Response Routing

**Problem:** Currently all messages broadcast to all clients. Commands need individual responses.

**Solution:** Add response writer that routes to requesting client only:

```zig
pub const ResponseWriter = struct {
    client_id: usize,
    cmd_id: ?[]const u8,  // Correlation ID from client
    shared_state: *SharedState,

    pub fn success(self: *ResponseWriter, payload: ?[]const u8) void {
        // Send only to client_id
    }

    pub fn error(self: *ResponseWriter, code: []const u8, msg: []const u8) void {
        // Send only to client_id
    }
};

// Handler signature change
pub const Handler = *const fn (
    *const reaper.Api,
    protocol.CommandMessage,
    *ResponseWriter,
) void;
```

State broadcasts still go to all clients via `shared_state.broadcast()`.

### 2. Input Metering (Not Full Track Metering)

**Clarification from user:** Only need input monitoring for record-armed tracks with monitoring enabled, plus a sticky clip indicator.

**Implementation:**

```zig
// state/tracks.zig
pub const InputMeter = struct {
    track_idx: c_int,
    peak: f64,           // Current peak (0.0 - 1.0+)
    clipped: bool,       // Sticky flag, true if ever exceeded 1.0
};

pub const MeteringState = struct {
    inputs: [MAX_ARMED_TRACKS]InputMeter,
    input_count: usize,

    pub fn poll(api: *const reaper.Api) MeteringState {
        // Only poll tracks where:
        // - Record armed (I_RECARM == 1)
        // - Input monitoring enabled (I_RECMON > 0)
    }
};
```

Client sends `meter/clearClip { trackIdx }` to reset clip indicator.

### 3. Bar/Beat Time Conversion

**Decision:** Use REAPER's native `TimeMap2_beatsToTime` and `TimeMap2_timeToBeats`.

```zig
// reaper.zig additions
timeMap2_beatsToTime: ?*const fn (?*anyopaque, f64, ?*c_int) callconv(.c) f64,
timeMap2_timeToBeats: ?*const fn (?*anyopaque, f64, ?*c_int, ?*f64, ?*f64, ?*c_int) callconv(.c) f64,

pub fn beatsToTime(self: *const Api, beats: f64) f64 {
    const f = self.timeMap2_beatsToTime orelse return 0;
    return f(null, beats, null);
}

pub fn timeToBeats(self: *const Api, time: f64) struct { beats: f64, measures: c_int } {
    const f = self.timeMap2_timeToBeats orelse return .{ .beats = 0, .measures = 0 };
    var measures: c_int = 0;
    const beats = f(null, time, &measures, null, null, null);
    return .{ .beats = beats, .measures = measures };
}
```

### 4. Batch Commands (Deferred)

**Decision:** Defer explicit batch command support. With native REAPER access, individual commands can use undo blocks directly when needed. If batching becomes necessary, we can add it later.

### 5. Protocol Versioning

```zig
// protocol.zig
pub const PROTOCOL_VERSION: u32 = 1;
pub const EXTENSION_VERSION = "0.5.0";

// Client sends on connect:
// {"type":"hello","clientVersion":"1.0.0","protocolVersion":1}

// Server responds:
// {"type":"hello","extensionVersion":"0.5.0","protocolVersion":1}

// Or closes with 4001 (invalid token) / 4002 (protocol mismatch)
```

---

## Implementation Phases

### Phase 4b-1: Foundation Refactoring ✅ COMPLETE
**Goal:** Restructure without adding features, ensure tests pass

- [x] Create `commands/` directory structure
- [x] Move existing handlers to domain-specific files
- [x] Add `commands/mod.zig` that aggregates all registries
- [x] Add `ResponseWriter` and update handler signatures
- [x] Add `id` field extraction to `CommandMessage`
- [x] Add `sendToClient` to `ws_server.zig` for per-client responses
- [x] Update `main.zig` imports
- [x] Verify all existing tests pass
- [x] Remove old `commands.zig`

**Files changed:** commands.zig → commands/*.zig, protocol.zig, ws_server.zig, main.zig

### Phase 4b-2: Transport & Time Selection Expansion ✅ COMPLETE
**Goal:** Complete transport and time selection commands

- [x] Add to `reaper.zig`: GetRepeat, SetRepeat, TimeMap2_*, GetSet_LoopTimeRange2
- [x] Expand `transport.zig` state: repeat, time_sig_denom
- [x] Add `commands/time_sel.zig`: set, setBeats, clear, goStart, goEnd, setStart, setEnd
- [x] Add `commands/repeat.zig`: set, toggle
- [x] Expand `commands/transport.zig`: abort, goStart, goEnd, seekBeats

**New commands:** 13 (transport: 4, time_sel: 7, repeat: 2)

### Phase 4b-3: Navigation Commands ✅ COMPLETE
**Goal:** Marker/region/take navigation

- [x] Add to `commands/markers.zig`: prev, next
- [x] Add to `commands/takes.zig`: next, prev
- [x] Add to `commands/items.zig`: selectInTimeSel, unselectAll
- [x] Add to `reaper.zig`: NEXT_TAKE, PREV_TAKE, UNSELECT_ALL_ITEMS, SELECT_ALL_ITEMS_IN_TIME_SEL commands

**New commands:** 6 (marker: 2, take: 2, item: 2)

### Phase 4b-4: Track Control ✅ PARTIAL
**Goal:** Track state and control commands

- [x] Create `tracks.zig` with Track struct and polling
- [x] Add to `reaper.zig`: GetMediaTrackInfo_Value, SetMediaTrackInfo_Value
- [x] Create `commands/tracks.zig`: setVolume, setPan, setMute, setSolo, setRecArm, setRecMon, setFxEnabled
- [x] Add track event broadcasting in `main.zig`
- [ ] Add input metering (record-armed tracks only) - **DEFERRED**
- [ ] Add `meter/clearClip` command - **DEFERRED**

**New commands:** 7 (track: setVolume, setPan, setMute, setSolo, setRecArm, setRecMon, setFxEnabled)

### Phase 4b-5: Tempo & Metronome ✅ PARTIAL
**Goal:** Tempo and metronome control

- [x] Add to `reaper.zig`: SetCurrentBPM, GetToggleCommandState
- [x] Create `commands/tempo.zig`: set, tap
- [x] Create `commands/metronome.zig`: toggle
- [x] Add metronome state to transport event
- [ ] `metronome/setVolume` - **DEFERRED** (requires project preferences access)

**New commands:** 3 (tempo: set, tap; metronome: toggle)

### Phase 4b-6: Advanced Features ✅ COMPLETE
**Goal:** ExtState, Undo, Actions

- [x] Add to `reaper.zig`: GetExtState, GetProjExtState, SetProjExtState, Undo_BeginBlock2, Undo_EndBlock2, Undo_OnStateChange
- [x] Create `commands/extstate.zig`: get, set, projGet, projSet
- [x] Create `commands/undo.zig`: add, begin, end
- [x] Create `commands/actions.zig`: getState, execute

**New commands:** 9 (extstate: 4, undo: 3, action: 2)

### Phase 4b-7: Protocol Hardening ✅ COMPLETE
**Goal:** Auth and versioning

- [x] Add hello handshake requirement
- [x] Generate session token on startup, store in EXTSTATE
- [x] Validate token on WebSocket connect
- [x] Add version checking with appropriate close codes (4001=invalid token, 4002=protocol mismatch)
- [x] Update `ws_server.zig` for auth flow
- [x] Update `protocol.zig` with HelloMessage parsing and buildHelloResponse

**New commands:** 0 (protocol changes only)

---

## New REAPER APIs Required

### Transport
- `GetRepeat() -> int`
- `SetRepeat(int) -> void`
- `CSurf_OnStop()` - for abort recording

### Time
- `TimeMap2_beatsToTime(proj, beats, *measures) -> time`
- `TimeMap2_timeToBeats(proj, time, *measures, *beats, *frac, *sig) -> beats`

### Tracks
- `GetTrack(proj, idx) -> MediaTrack*` ✅ (have)
- `GetTrackState(track, *flags) -> int` - for mute/solo/recarm
- `SetTrackUIVol(track, vol) -> void`
- `SetTrackUIPan(track, pan) -> void`
- `CSurf_SetTrackMute(track, mute) -> void`
- `CSurf_SetTrackSolo(track, solo) -> void`
- `CSurf_SetTrackRecArm(track, recarm) -> void`
- `GetTrackColor(track) -> int`
- `GetTrackPeakInfo(track, chan) -> float` - for metering

### Selection
- `SetMediaItemSelected(item, selected) -> void`
- `CountSelectedMediaItems(proj) -> int`
- `GetSelectedMediaItem(proj, idx) -> MediaItem*`

### ExtState
- `GetExtState(section, key, buf, buflen) -> void` ✅ (partial - need full)
- `SetExtState(section, key, value, persist) -> void` ✅ (have)
- `GetProjExtState(proj, section, key, buf, buflen) -> int`
- `SetProjExtState(proj, section, key, value) -> int`

### Undo
- `Undo_BeginBlock2(proj) -> void`
- `Undo_EndBlock2(proj, desc, flags) -> void`
- `Undo_OnStateChange(desc) -> void`

### Actions
- `GetToggleCommandState(cmd) -> int`
- `Main_OnCommand(cmd, flag) -> void` ✅ (have)
- `NamedCommandLookup(name) -> int` - for SWS commands

---

## Testing Strategy

### Unit Tests (run without REAPER)
- All state modules: change detection, JSON serialization
- Protocol: parsing, building, escaping
- Command registry: lookup, dispatch
- Ring buffer: push/pop, wraparound, overflow

### Integration Tests (require REAPER)
- Test client HTML page (existing)
- Python/JS test scripts for automated command sequences
- Fuzz testing: random messages, verify no crashes

### Pre-commit Checklist
```bash
cd extension
zig build test  # All unit tests
zig build       # Compile succeeds
```

---

## Migration Notes

### Import Path Changes
After restructuring, `main.zig` changes from:
```zig
const commands = @import("commands.zig");
```
To:
```zig
const commands = @import("commands/mod.zig");
```

### Backward Compatibility
- Existing 23 commands continue to work unchanged
- New response format is additive (commands that don't send `id` get no response)
- Protocol version 1 maintains current behavior; version checking is opt-in initially

---

## Open Questions (Resolved)

| Question | Resolution |
|----------|------------|
| Metering frequency | Input metering only for armed+monitoring tracks |
| Response delivery | Responses to requesting client only; state broadcasts to all |
| Batch commands | Deferred; use undo blocks for atomicity when needed |
| Bar/beat parsing | Use REAPER's native TimeMap2_* functions |

---

## References

- [AUDIT.md](AUDIT.md) - Complete feature gap analysis
- [PLAN.md](PLAN.md) - Original project plan and philosophy
- [docs/reaper_plugin_functions.h](docs/reaper_plugin_functions.h) - REAPER API signatures
