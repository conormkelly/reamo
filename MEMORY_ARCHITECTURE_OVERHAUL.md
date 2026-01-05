# Memory Architecture Overhaul — Implementation Plan

**Status:** Ready for implementation
**Date:** 2026-01-05
**Context:** Decisions from memory research + flattened data model discussion

This document synthesizes all decisions from the memory allocation research. A new Claude session can use this to implement the changes without needing the full conversation context.

---

## Executive Summary

We're moving from fixed entity limits (128 tracks, 512 items, etc.) to a **"no limits" architecture** aligned with REAPER's philosophy. Key changes:

1. **Flattened data model** — Tracks don't contain nested FX/sends arrays
2. **Sparse polling** — Heavy data fetched on-demand, not every poll cycle
3. **Project-size detection** — Calculate arena size from actual entity counts
4. **Dynamic allocation with 2x headroom** — Minimum 20 MB, ceiling 200 MB
5. **Graceful degradation** — Skip entities when full, never crash

---

## Memory Budget

### Per-Tier Allocation (Double-Buffered)

```
HIGH TIER (30Hz) — Tracks + Meters only
───────────────────────────────────────
Track (flattened):  ~150 B (no nested fx/sends, just counts)
TrackMeter:         ~21 B
Per track total:    ~171 B

Extreme (3,000 tracks): 513 KB per arena
With 2x headroom:       ~1 MB per arena
Double-buffered:        2 MB total

MEDIUM TIER (5Hz) — Flat entity arrays
───────────────────────────────────────
Items:    10,000 × 700 B  = 7.0 MB
Markers:  500 × 172 B     = 86 KB
Regions:  500 × 228 B     = 114 KB
FX:       5,000 × 281 B   = 1.4 MB  (flat array, not nested)
Sends:    3,000 × 157 B   = 471 KB  (flat array, not nested)
────────────────────────────────────────
Subtotal:                 ~9.1 MB per arena
With 2x headroom:         ~18 MB per arena
Double-buffered:          36 MB total

LOW TIER (1Hz) — Tempo map
───────────────────────────────────────
Tempo events:       ~50 KB typical
With 2x headroom:   128 KB per arena
Double-buffered:    256 KB total

SCRATCH — JSON serialization
───────────────────────────────────────
Single arena (reset every frame): 2 MB

═══════════════════════════════════════════════════
TOTAL FOR EXTREME PROJECT:      ~40 MB
MINIMUM ALLOCATION:             20 MB
ABSOLUTE CEILING:               200 MB
═══════════════════════════════════════════════════
```

---

## Key Decisions

### 1. Initial Allocation Strategy
**Decision:** Project-size detection with 20 MB minimum

On startup and project load:
1. Count all tracks, FX, sends, items, markers, regions via REAPER API
2. Calculate required memory using struct sizes
3. Multiply by 2x headroom
4. Use max(calculated, 20 MB) as allocation
5. Cap at 200 MB ceiling

### 2. Resize Strategy
**Decision:** Opportunistic resize on project change only

- Detect project change via `GetProjectPath()` changing
- Pause polling during resize
- Recalculate size for new project
- Shrink or grow as needed (within 20 MB - 200 MB bounds)
- Never resize mid-session (2x headroom should cover growth)

### 3. Degraded Mode
**Decision:** Skip newest entities, broadcast warning

When arena utilization hits 90%:
- Log warning
- Skip adding new entities (newest tracks/items not visible)
- Broadcast `ARENA_FULL` warning event to clients
- Continue operating with partial data
- Never crash REAPER

### 4. Warning Threshold
**Decision:** 80% utilization

At 80% arena usage:
- Log info message
- Broadcast `ARENA_WARNING` event to clients
- Continue normal operation

### 5. Configuration
**Decision:** Automatic with power-user escape hatches

- Fully automatic by default — just works
- Leave architecture open for future ExtState settings:
  - Memory ceiling override
  - "Low memory mode" toggle
- Not implementing user config UI in this phase

### 6. Monitoring
**Decision:** Expose metrics via debug/memoryStats command

New command `debug/memoryStats` returns:
```json
{
  "high_tier": { "used_bytes": 512000, "capacity_bytes": 1048576, "utilization_pct": 48.8 },
  "medium_tier": { "used_bytes": 8000000, "capacity_bytes": 18874368, "utilization_pct": 42.4 },
  "low_tier": { "used_bytes": 2048, "capacity_bytes": 131072, "utilization_pct": 1.6 },
  "scratch": { "used_bytes": 0, "capacity_bytes": 2097152, "peak_bytes": 156000 },
  "entity_counts": { "tracks": 150, "fx": 800, "sends": 200, "items": 2000, "markers": 50, "regions": 30 },
  "degraded_mode": false
}
```

---

## Flattened Data Model

### Problem: Cross-Tier Pointer Dependencies

Original design had tracks containing FX/send slices:
```zig
const Track = struct {
    fx: []FxSlot,      // Points into MEDIUM tier arena
    sends: []SendSlot, // Points into MEDIUM tier arena
};
```

When MEDIUM tier swaps arenas at 5Hz, HIGH tier's pointers become dangling.

### Solution: Separate Top-Level Collections

Tracks only contain **counts**, not nested data:
```zig
const Track = struct {
    idx: c_int,
    name: [128]u8,
    volume: f64,
    pan: f64,
    mute: bool,
    solo: ?c_int,
    // ... other fields ...

    // Sparse hints only:
    fx_count: u16,
    send_count: u16,
    receive_count: u16,
};
```

FX and sends become separate flat arrays in MEDIUM tier:
```zig
const FxSlot = struct {
    track_idx: c_int,   // Parent reference
    fx_index: u16,      // Position in chain
    name: [128]u8,
    preset_name: [128]u8,
    enabled: bool,
    // ... summary fields only, no params
};

const SendSlot = struct {
    src_track_idx: c_int,
    dest_track_idx: c_int,
    send_index: u16,
    volume: f64,
    pan: f64,
    muted: bool,
};
```

### Item Sparse Fields

Items also use sparse pattern:
```zig
const Item = struct {
    // ... existing fields ...

    // Sparse hints (replaces 1024B notes buffer + 1488B takes array):
    has_notes: bool,
    take_count: u8,
    active_take_idx: u8,
};
```

**Struct size reduction:**
- Track: ~232 B → ~150 B (no fx/sends slices)
- Item: ~2,211 B → ~700 B (no notes buffer, no takes array)

---

## Protocol Changes

### Modified Events

**`tracks` event (30Hz):**
- Remove: `fx`, `sends` arrays
- Add: `fx_count`, `send_count`, `receive_count`

**`items` event (5Hz):**
- Remove: `notes`, `takes` arrays
- Add: `has_notes`, `take_count`, `active_take_idx`

### New Events (5Hz)

**`fx_state` event:**
```json
{
  "type": "event",
  "event": "fx_state",
  "payload": {
    "fx": [
      {"track_idx": 1, "fx_index": 0, "name": "Pro-Q 3", "enabled": true},
      {"track_idx": 1, "fx_index": 1, "name": "LA-2A", "enabled": true}
    ]
  }
}
```

**`sends_state` event:**
```json
{
  "type": "event",
  "event": "sends_state",
  "payload": {
    "sends": [
      {"src_track_idx": 1, "dest_track_idx": 5, "send_index": 0, "volume": 0.5, "muted": false}
    ]
  }
}
```

### New Commands

| Command | Purpose | Response |
|---------|---------|----------|
| `track/getFx` | Full FX detail for track (all params) | FX array with full param values |
| `track/getSends` | Full send routing for track | Send array with extended info |
| `item/getNotes` | Fetch notes content | Notes string |
| `item/getTakes` | Fetch take list | Takes array with full details |
| `debug/memoryStats` | Arena usage metrics | Stats object (see above) |

---

## Implementation Phases

### Phase A: Flatten Track Struct
**Files:** `extension/src/tracks.zig`

1. Remove `fx: []FxSlot` and `sends: []SendSlot` from Track struct
2. Add `fx_count: u16`, `send_count: u16`, `receive_count: u16`
3. Update `pollInto()` to populate counts from REAPER API
4. Update `toJson()` to serialize counts instead of arrays
5. Update `eql()` comparison
6. Update tests

### Phase B: Create FX/Sends Modules
**Files:** `extension/src/fx.zig` (new), `extension/src/sends.zig` (new)

1. Create `FxSlot` struct with `track_idx` parent reference
2. Create `fx.State` with flat `[]FxSlot` slice
3. Create `fx.poll()` that iterates all tracks, all FX
4. Create `fx.toJson()` for `fx_state` event
5. Repeat for sends module

### Phase C: Sparse Item Fields
**Files:** `extension/src/items.zig`

1. Remove `notes: [1024]u8` and `takes: [8]Take` from Item struct
2. Add `has_notes: bool`, `take_count: u8`, `active_take_idx: u8`
3. Update `pollInto()` to check if item has notes (non-empty)
4. Update `toJson()` to serialize sparse fields
5. Update tests

### Phase D: On-Demand Commands
**Files:** `extension/src/commands/tracks.zig`, `extension/src/commands/items.zig`

1. Add `track/getFx` handler — fetch full FX detail for single track
2. Add `track/getSends` handler — fetch full send detail for single track
3. Add `item/getNotes` handler — fetch notes content for single item
4. Add `item/getTakes` handler — fetch take list for single item
5. Register in `commands/registry.zig`

### Phase E: Arena Sizing
**Files:** `extension/src/tiered_state.zig`, `extension/src/main.zig`

1. Add `calculateRequiredSize()` that counts entities via REAPER API
2. Update `TieredArenas.init()` to use calculated size with 2x headroom
3. Add minimum 20 MB floor, 200 MB ceiling
4. Add `usage()` method to each arena for monitoring
5. Add project path tracking for resize detection

### Phase F: Project Change Detection
**Files:** `extension/src/main.zig`

1. Track `g_last_project_path` global
2. On each LOW tier poll (1Hz), check if project path changed
3. If changed: pause polling, recalculate arena sizes, resize, resume
4. Log resize events

### Phase G: Graceful Degradation
**Files:** `extension/src/tracks.zig`, `extension/src/items.zig`, etc.

1. Check arena remaining space before allocating each entity
2. If insufficient: set `degraded_mode = true`, break loop
3. At 80% utilization: broadcast `ARENA_WARNING` event
4. At 90% utilization: broadcast `ARENA_FULL` event
5. Log warnings

### Phase H: Memory Stats Command
**Files:** `extension/src/commands/debug.zig` (new)

1. Create `debug/memoryStats` handler
2. Collect stats from all arenas: used, capacity, peak
3. Collect entity counts
4. Include degraded_mode flag
5. Register in registry

### Phase I: Frontend Updates
**Files:** `frontend/src/store/`, `frontend/src/core/types.ts`

1. Update `WSTrack` type — remove fx/sends, add counts
2. Update `WSItem` type — remove notes/takes, add sparse fields
3. Add `fxStore` slice for `fx_state` events
4. Add `sendsStore` slice for `sends_state` events
5. Add on-demand fetch functions for detail views
6. Update components that display FX/sends/notes/takes

---

## Files to Modify

**Extension (Zig):**
- `extension/src/tracks.zig` — flatten Track struct
- `extension/src/items.zig` — sparse fields
- `extension/src/fx.zig` — new, flat FX polling
- `extension/src/sends.zig` — new, flat sends polling
- `extension/src/tiered_state.zig` — arena sizing
- `extension/src/main.zig` — project change detection, integrate new events
- `extension/src/commands/tracks.zig` — getFx, getSends handlers
- `extension/src/commands/items.zig` — getNotes, getTakes handlers
- `extension/src/commands/debug.zig` — new, memoryStats handler
- `extension/src/commands/registry.zig` — register new commands

**Frontend (TypeScript):**
- `frontend/src/core/types.ts` — updated WebSocket types
- `frontend/src/core/WebSocketTypes.ts` — new event types
- `frontend/src/store/slices/` — new fx/sends slices
- `frontend/src/store/index.ts` — handle new events
- Components displaying FX/sends/notes/takes

---

## Testing Strategy

1. **Unit tests:** Arena sizing calculation, struct serialization
2. **Integration:** Open projects of various sizes, verify correct entity counts
3. **Degradation:** Artificially limit arena size, verify graceful degradation
4. **Resize:** Open small project, then large project, verify resize occurs
5. **Memory stats:** Call `debug/memoryStats`, verify accurate reporting
6. **Frontend:** Verify on-demand fetching works for FX/sends/notes/takes

---

## Success Criteria

- [ ] No fixed MAX_* limits in code (except as config defaults)
- [ ] Extreme project (3000 tracks, 10000 items) works without truncation
- [ ] Memory usage scales with project size, not fixed allocation
- [ ] Graceful degradation when limits exceeded (no crash)
- [ ] `debug/memoryStats` reports accurate usage
- [ ] Frontend displays FX/sends via on-demand fetch
- [ ] All existing tests pass
- [ ] New tests for arena sizing and degradation
