# Phase 2: FX Parameter Subscription — Implementation Plan

## Design Decisions (Confirmed)

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Gesture ControlId | Add fxGuid with fixed [40]u8 buffer | GUIDs stable across FX reorder. Matches existing patterns. |
| Skeleton caching | One-time fetch (no backend cache) | Matches `action/getActions` pattern. Frontend caches in LRU. |
| Skeleton invalidation | paramCount + nameHash in events | Frontend refetches skeleton when paramCount OR nameHash differs from cached. |
| Update rate | 30Hz (HIGH tier) | Consistent with track/meter updates. Hash deduplication handles CSurf spam. Research shows GetNumParams() is lightweight enough for 30Hz (3Hz would suffice for structural changes only). |
| Subscription mode | Range + indices | Range for scroll, indices for filtered views. As designed in Phase 2 doc. |
| GUID storage | Fixed [40]u8 buffer | Simple, no allocation, stack-safe. |
| Param addressing | Index only | Simple. If FX updates break indices, user re-opens view. |
| Dirty granularity | Keep per-track | CSurf doesn't tell us which FX changed anyway. |
| Subscription per client | Single FX at a time | Auto-unsubscribes previous. Different clients can view different FX. |

---

## ✅ DECIDED: Undo Block Strategy — Bitfield Approach

**Problem:** No CSurf API for FX param setting. Must use `TrackFX_SetParamNormalized` directly → requires manual undo block.

> **REAPER Limitation (per DEVELOPMENT.md:1714):** REAPER doesn't support nested undo blocks. Calling `Undo_BeginBlock2` while another block is open corrupts undo state. This design uses a unified counter to ensure only one block is ever open, regardless of how many concurrent gestures are active.

**Solution:** Unified counter + bitfield for specific messages. Best of both worlds.

```zig
pub const ManualUndoControlType = enum(u8) {
    hw_output_volume = 0,
    hw_output_pan = 1,
    fx_param = 2,
    // future: master_volume, master_pan, etc.
};

pub const ManualUndoState = struct {
    gesture_count: usize = 0,
    active_types: u8 = 0,  // bitfield

    pub fn beginBlock(self: *ManualUndoState, control_type: ManualUndoControlType) void {
        if (self.gesture_count == 0) {
            Undo_BeginBlock2(proj);
        }
        self.gesture_count += 1;
        self.active_types |= (@as(u8, 1) << @intFromEnum(control_type));
    }

    pub fn endBlock(self: *ManualUndoState, control_type: ManualUndoControlType) void {
        self.gesture_count -= 1;
        // Don't clear the bit - remember all types touched during this block

        if (self.gesture_count == 0) {
            const msg = self.buildUndoMessage();
            Undo_EndBlock2(proj, msg, -1);  // msg is already [*:0]const u8
            self.active_types = 0;  // Reset for next block
        }
    }

    /// Returns null-terminated string literal for REAPER's Undo_EndBlock2.
    /// String literals are automatically [*:0]const u8 (null-terminated).
    fn buildUndoMessage(self: *ManualUndoState) [*:0]const u8 {
        const hw_vol = (self.active_types & (1 << 0)) != 0;
        const hw_pan = (self.active_types & (1 << 1)) != 0;
        const fx = (self.active_types & (1 << 2)) != 0;

        const hw = hw_vol or hw_pan;

        // Single category - specific message
        if (hw and !fx) return "REAmo: Adjust hardware outputs";
        if (fx and !hw) return "REAmo: Adjust FX parameters";

        // Mixed - combined message
        if (hw and fx) return "REAmo: Adjust parameters";

        return "REAmo: Adjust parameters";
    }
};
```

**Undo messages by scenario:**

| Scenario | Message |
|----------|---------|
| Single FX param drag | "REAmo: Adjust FX parameters" |
| Multiple FX params simultaneously | "REAmo: Adjust FX parameters" |
| HW output only | "REAmo: Adjust hardware outputs" |
| HW + FX simultaneously | "REAmo: Adjust parameters" |

**Why this works:**

- Bits accumulate during overlapping gestures
- Message reflects all control types touched
- Clears only when block fully closes
- Adding new types = add enum value + update `buildUndoMessage`

**Migration:** Replace `hw_gesture_control_count` in `gesture_state.zig` with `ManualUndoState`.

---

## Research Queries

### Query 1: FX Parameter Dynamic Behavior ✅ COMPLETE

**Results documented in:** `research/REAPER_FX_PARAMS_API.md`

```markdown
# Research Query: REAPER FX Parameter Behavior

## Context
Building a web controller for REAPER (DAW software). Implementing FX parameter
subscription - users view/edit plugin parameters from a web UI. Need to understand
edge cases for a 30Hz polling loop.

## Questions

### 1. Can VST/AU plugins dynamically change their parameter count?
Can a plugin's number of exposed parameters change while loaded, without user action
(like loading a different preset)?

Examples:
- Plugin that adds/removes parameters based on mode selection
- Multi-band processors that add bands dynamically

If yes: Does `TrackFX_GetNumParams()` return new count immediately? Any CSurf callback?

### 2. What happens with invalid param index after count change?
If plugin had 100 params, now has 50:
- `TrackFX_GetParamNormalized(track, fx, 75)` returns what? 0? NaN? Crash?
- `TrackFX_GetParamName(track, fx, 75, buf, sz)` returns what?

### 3. Is there a CSurf callback for parameter count changes?
Beyond `CSURF_EXT_SETFXCHANGE` (FX added/removed), any callback for internal
parameter structure changes?

### 4. Best practice: re-check param count every poll?
For 30Hz polling, should we call `TrackFX_GetNumParams()` every frame, or assume
count only changes on `CSURF_EXT_SETFXCHANGE`?

### 5. Container plugins (FX chains, Patcher)?
When FX is inside a container plugin:
- Does `TrackFX_GetNumParams()` work normally?
- Are parameters accessible via standard APIs?
```

### Query 2: Undo Block Nesting (If Needed)

```markdown
# Research Query: REAPER Undo Block Nesting Behavior

## Context
REAPER extension using undo blocks for gesture coalescing. Need to understand what
happens with nested `Undo_BeginBlock2`/`Undo_EndBlock2` calls.

## Questions

### 1. What exactly happens with nested undo blocks?
If we call:
```c
Undo_BeginBlock2(proj);
  // ... make changes ...
  Undo_BeginBlock2(proj);  // Nested - what happens?
    // ... make more changes ...
  Undo_EndBlock2(proj, "Inner", -1);
Undo_EndBlock2(proj, "Outer", -1);
```

Does it:

- Crash?
- Corrupt undo state?
- Work (nested blocks merged)?
- Only inner block recorded?
- Only outer block recorded?

### 2. Is there documentation on this behavior?

Any official docs or forum posts from Cockos developers on undo block nesting?

### 3. What do major extensions do?

How do SWS, ReaPack, or other major extensions handle concurrent operations that
might need undo blocks?

```

---

## New REAPER API Bindings

**File: `extension/src/reaper/raw.zig`**

Add function pointers (with `= null` defaults to match existing patterns):
```zig
trackFX_GetNumParams: ?*const fn(?*anyopaque, c_int) callconv(.c) c_int = null,
trackFX_GetParamName: ?*const fn(?*anyopaque, c_int, c_int, [*]u8, c_int) callconv(.c) bool = null,
trackFX_GetParamNormalized: ?*const fn(?*anyopaque, c_int, c_int) callconv(.c) f64 = null,
trackFX_SetParamNormalized: ?*const fn(?*anyopaque, c_int, c_int, f64) callconv(.c) bool = null,
trackFX_GetFormattedParamValue: ?*const fn(?*anyopaque, c_int, c_int, [*]u8, c_int) callconv(.c) bool = null,
```

**File: `extension/src/reaper/real.zig`**

Add wrapper methods delegating to raw.zig.

**File: `extension/src/reaper/mock/tracks.zig`**

Add MockBackend methods for testing.

---

## New Files

### 1. `extension/src/trackfxparam_subscriptions.zig`

Per-client subscription state for FX parameters.

```zig
pub const ClientSubscription = struct {
    active: bool = false,
    track_guid: [40]u8 = undefined,
    track_guid_len: usize = 0,
    fx_guid: [40]u8 = undefined,
    fx_guid_len: usize = 0,

    // Subscription mode: range OR indices
    mode: Mode = .range,
    range_start: c_int = 0,
    range_end: c_int = 0,
    indices: [MAX_SUBSCRIBED_PARAMS]c_int = undefined,
    indices_count: usize = 0,

    // Auto-unsubscribe after consecutive failures (FX deleted)
    consecutive_failures: u8 = 0,

    pub const Mode = enum { range, indices };
};

pub const TrackFxParamSubscriptions = struct {
    clients: [MAX_CLIENTS]ClientSubscription,
    prev_hash: [MAX_CLIENTS]u64,
    force_broadcast_clients: [MAX_CLIENTS]bool,
    // ... standard subscription management

    pub fn subscribe(self, client_id, track_guid, fx_guid, mode_params) !void;
    pub fn unsubscribe(self, client_id) void;
    pub fn activeSubscriptions(self) SubscriptionIterator;
    pub fn checkChanged(self, slot, hash) bool;
};
```

**Constants:**

- `MAX_SUBSCRIBED_PARAMS = 100` — max params in indices mode
- Reuse `MAX_CLIENTS = 32` from constants.zig

### 2. `extension/src/trackfxparam_generator.zig`

JSON generator for param value events.

```zig
pub fn generateParamValues(
    allocator: Allocator,
    api: anytype,
    guid_cache: *GuidCache,
    track_guid: []const u8,
    fx_guid: []const u8,
    mode: Mode,
    range_or_indices: anytype,
) ?struct { json: []const u8, param_count: c_int, name_hash: u64 };
```

**Implementation notes:**

- Returns struct with JSON + metadata for change detection
- `param_count` from `TrackFX_GetNumParams()` (called once per generate)
- `name_hash` computed as fnv1a of concatenated param names in subscribed range *(v1.1 optional)*
- Both fields included in JSON payload for frontend skeleton invalidation

**Event format:**

> **Naming convention:** Uses `trackFxParams` (camelCase) to match newer command patterns like `trackFx/getParams`. The codebase has some inconsistency (older events use snake_case), but camelCase is preferred going forward.

```json
{
  "type": "event",
  "event": "trackFxParams",
  "payload": {
    "trackGuid": "{AAA}",
    "fxGuid": "{FFF}",
    "paramCount": 50,
    "nameHash": 3847291,
    "values": {
      "0": [0.5, "-6.0 dB"],
      "5": [1.0, "On"],
      "12": [0.25, "250 Hz"]
    }
  }
}
```

**Skeleton invalidation fields:**

- `paramCount` — Total param count from `TrackFX_GetNumParams()`. Frontend compares to cached skeleton.
- `nameHash` — Hash of all param names concatenated. Detects name changes without count change. *(Optional for v1.1 — can defer if complexity is high)*

**Frontend logic:**

1. If `paramCount` differs from cached skeleton → refetch skeleton
2. If `nameHash` differs from cached skeleton → refetch skeleton

### 3. `extension/src/commands/trackfxparam_subs.zig`

Command handlers:

- `handleSubscribe` — `trackFxParams/subscribe`
- `handleUnsubscribe` — `trackFxParams/unsubscribe`

---

## Modified Files

### `extension/src/gesture_state.zig`

**1. Extend ControlId for FX params:**

```zig
pub const ControlId = struct {
    control_type: ControlType,
    track_idx: c_int,
    sub_idx: c_int = 0,

    // NEW: For FX param gestures
    fx_guid: [40]u8 = undefined,
    fx_guid_len: usize = 0,
    param_idx: c_int = 0,

    pub const ControlType = enum {
        volume,
        pan,
        send_volume,
        send_pan,
        receive_volume,
        receive_pan,
        hw_output_volume,
        hw_output_pan,
        fx_param,  // NEW
    };

    pub fn fxParam(track_idx: c_int, fx_guid: []const u8, param_idx: c_int) ControlId {
        var id = ControlId{
            .control_type = .fx_param,
            .track_idx = track_idx,
            .param_idx = param_idx,
        };
        const len = @min(fx_guid.len, 40);
        @memcpy(id.fx_guid[0..len], fx_guid[0..len]);
        id.fx_guid_len = len;
        return id;
    }
};
```

**CRITICAL: Add custom `eql()` and `hash()` for AutoHashMap compatibility.**

Since ControlId uses fixed-size arrays (`fx_guid: [40]u8`), default equality would compare all 40 bytes even when `fx_guid_len < 40`. Must implement custom methods:

```zig
// SAFETY: @alignCast unnecessary - u8 has alignment 1, always valid
pub fn eql(self: ControlId, other: ControlId) bool {
    if (self.control_type != other.control_type) return false;
    if (self.track_idx != other.track_idx) return false;
    if (self.control_type == .fx_param) {
        if (self.fx_guid_len != other.fx_guid_len) return false;
        if (!std.mem.eql(u8, self.fx_guid[0..self.fx_guid_len], other.fx_guid[0..other.fx_guid_len])) return false;
        if (self.param_idx != other.param_idx) return false;
    }
    return self.sub_idx == other.sub_idx;
}

pub fn hash(self: ControlId) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.asBytes(&self.control_type));
    h.update(std.mem.asBytes(&self.track_idx));
    if (self.control_type == .fx_param) {
        h.update(self.fx_guid[0..self.fx_guid_len]);
        h.update(std.mem.asBytes(&self.param_idx));
    }
    h.update(std.mem.asBytes(&self.sub_idx));
    return h.final();
}
```

Then update `GestureState.gestures` to use context-aware hash map:
```zig
gestures: std.HashMap(ControlId, ActiveGesture, ControlId.HashContext, std.hash_map.default_max_load_percentage),
```

**2. Replace `hw_gesture_control_count` with `ManualUndoState`:**

Remove:

```zig
hw_gesture_control_count: usize,
pub fn beginHwUndoBlock(self: *GestureState) bool;
pub fn endHwUndoBlock(self: *GestureState) bool;
pub fn hasHwUndoBlock(self: *const GestureState) bool;
```

Add `ManualUndoState` (see "Undo Block Strategy" section above) and integrate with `GestureState`:

```zig
manual_undo: ManualUndoState = .{},
```

Update callers in `commands/gesture.zig` to use the new API.

### `extension/src/commands/fx.zig`

Add `handleGetParams` for skeleton fetch:

```zig
pub fn handleGetParams(api: anytype, cmd: CommandMessage, response: *ResponseWriter) void {
    // Resolve trackGuid → track, fxGuid → fx_idx
    // Enumerate all params: [name1, name2, ...]
    // Return JSON array of param names
}
```

**Response format:**

```json
{
  "success": true,
  "payload": {
    "trackGuid": "{AAA}",
    "fxGuid": "{FFF}",
    "params": ["Gain", "Frequency", "Q", "Output"]
  }
}
```

### `extension/src/commands/trackfxparam.zig` (new)

Add `handleSetParam`:

```zig
pub fn handleSetParam(api: anytype, cmd: CommandMessage, response: *ResponseWriter) void {
    // Resolve trackGuid → track, fxGuid → fx_idx
    // Call TrackFX_SetParamNormalized
    // Record gesture activity if gesture active
    response.success(null);
}
```

### `extension/src/commands/gesture.zig`

Update `parseControlId` to handle fx_param control type:

```zig
if (std.mem.eql(u8, control_type, "trackFxParam")) {
    const track_result = tracks.resolveTrack(api, cmd) orelse return null;
    const fx_guid = cmd.getString("fxGuid") orelse return null;
    const param_idx = cmd.getInt("paramIdx") orelse return null;
    return ControlId.fxParam(track_result.idx, fx_guid, param_idx);
}
```

### `extension/src/commands/registry.zig`

Add new commands:

```zig
.{ "trackFx/getParams", fx.handleGetParams },
.{ "trackFxParams/subscribe", trackfxparam_subs.handleSubscribe },
.{ "trackFxParams/unsubscribe", trackfxparam_subs.handleUnsubscribe },
.{ "trackFxParams/set", trackfxparam.handleSetParam },
```

### `extension/src/commands/mod.zig`

Add `trackfxparam_subs` and `trackfxparam` to imports and `GlobalContext`:

```zig
param_subs: ?*TrackFxParamSubscriptions = null,
```

### `extension/src/main.zig`

1. **Initialize** `g_param_subs` in `doInitialization()`
2. **Poll loop** (HIGH tier):
   - If `fx_dirty` consumed OR subscriptions exist, iterate `activeSubscriptions()`
   - For each subscription, generate param values JSON
   - Check hash with `std.hash.Wyhash.hash(0, json_bytes)`, broadcast if changed
3. **Cleanup** on client disconnect — Mirror `track_subscriptions.zig:295-315` pattern:
   ```zig
   pub fn removeClient(self: *TrackFxParamSubscriptions, client_id: usize) void {
       const slot = self.client_id_to_slot.get(client_id) orelse return;
       const client = &self.clients[slot];
       client.clear();

       // Clear previous hash
       self.prev_hash[slot] = 0;

       _ = self.client_id_to_slot.remove(client_id);

       // Add slot to free list for reuse
       self.free_slots[self.free_count] = slot;
       self.free_count += 1;

       logging.debug("trackfxparam_subscriptions: client {d} removed", .{client_id});
   }
   ```
4. **Deinit** on shutdown

---

## FX Index Resolution

When client sends `fxGuid`, resolve to `fx_idx`:

```zig
fn resolveFxIndex(api: anytype, track: *anyopaque, fx_guid: []const u8) ?c_int {
    const fx_count = api.trackFxCount(track);
    var buf: [64]u8 = undefined;
    var i: c_int = 0;
    while (i < fx_count) : (i += 1) {
        const guid = api.trackFxGetGuid(track, i, &buf);
        if (std.mem.eql(u8, guid, fx_guid)) return i;
    }
    return null;
}
```

Cache this in the subscription for performance? Or resolve each frame?

**Recommendation**: Resolve each frame (O(n) where n = FX count, typically <20). Simple, handles FX reorder automatically.

---

## Error Handling

| Error Code | Condition |
|------------|-----------|
| `NOT_FOUND` | Track GUID not found |
| `FX_NOT_FOUND` | FX GUID not found on track |
| `INVALID_RANGE` | range.start > range.end or out of bounds |
| `TOO_MANY_PARAMS` | indices array exceeds MAX_SUBSCRIBED_PARAMS |
| `TOO_MANY_CLIENTS` | Subscription limit reached |

---

## Edge Case Handling

### Track/FX Deleted While Subscribed

During polling, if GUID resolution fails:

1. Increment per-client `consecutive_failures` counter
2. If `consecutive_failures < 3`: Skip this frame silently (allows undo recovery)
3. If `consecutive_failures >= 3` (~100ms at 30Hz):
   - Send error event: `{"type":"event","event":"trackFxParamsError","error":"FX_NOT_FOUND"}`
   - Auto-unsubscribe the client
   - Frontend closes modal with toast message
4. On successful resolution: Reset `consecutive_failures` to 0

**Rationale:** 3 failures = 100ms grace period. Long enough for undo to restore FX, short enough to not spam errors.

### Param Count Changes (Research Complete)

**Research findings:** Param counts CAN change dynamically (VST2 Cockos extension, VST3 restartComponent). NO CSurf callback exists for param count changes. `GetNumParams()` is extremely lightweight — safe to call every frame. Invalid indices return 0.0/false safely (no crash).

**Handling:**

1. Call `TrackFX_GetNumParams()` every poll frame
2. Clamp subscribed range to actual count
3. Include `paramCount` and `nameHash` in every event payload
4. Frontend compares to cached skeleton and refetches if either differs

**Container plugins:** Deferred. Native containers use 0x2000000 addressing; third-party containers are opaque. Not worth the complexity for v1.

### FX Reorder During Subscription

FX GUID remains stable → subscription continues working. FX index is resolved fresh each poll from GUID.

---

## Buffer Sizing

- **Skeleton response**: 64KB (supports ~1000 param names)
  - Use `response.successLargePayload()` per DEVELOPMENT.md:1620 (user-generated content)
  - Some plugins (Kontakt, complex synths) can have 500+ parameters
- **Values event**: 32KB (supports ~200 params with formatted strings)
- Each param value entry: `"123": [0.5, "Formatted Value"]` ≈ 50 bytes
- **Hash function**: Use `std.hash.Wyhash.hash(0, json_bytes)` for change detection (per existing patterns)

---

## Testing

1. **Unit tests** in each new module (copy patterns from trackfx_subscriptions)
2. **MockBackend extensions** for new API methods
3. **websocat tests**:
   - Subscribe to FX params, verify events
   - Scroll (update range), verify event filtering
   - Filter (switch to indices mode), verify sparse values
4. **Gesture tests**: Start/end gesture on FX param, verify undo coalescing

---

## Implementation Order

### Phase A: Research (Before Coding) ✅ COMPLETE

1. ~~**Run Research Query 1** — FX param dynamic behavior~~ ✅ COMPLETE
2. ~~**Decision**: Undo block strategy~~ ✅ DECIDED — Bitfield approach
3. ~~**Run Research Query 2**~~ — Not needed (bitfield avoids nesting)

### Phase B: Read-Only Commands

1. **REAPER API bindings** (raw.zig, real.zig, mock) — GetNumParams, GetParamName, GetParamNormalized, GetFormattedParamValue
2. **trackFx/getParams** command (skeleton fetch)
3. **trackfxparam_subscriptions.zig** (subscription state)
4. **trackfxparam_generator.zig** (JSON generation)
5. **trackFxParams/subscribe, unsubscribe** commands
6. **main.zig integration** (poll loop)
7. **Tests** for read-only path

### Phase C: Write Commands + Gestures

1. **REAPER API binding** — SetParamNormalized
2. **Gesture extension** (ControlId.fx_param, unified undo block)
3. **trackFxParams/set** command with gesture support
4. **Tests** for write path

### Phase D: Documentation

1. **Update API.md** with new commands
2. **Update DEVELOPMENT.md** with FX param patterns
3. **Update TRACK_FX_ENHANCEMENTS.md** — mark Phase 2 complete

---

## Files to Modify/Create

| File | Action |
|------|--------|
| `extension/src/reaper/raw.zig` | Add 5 new function pointers |
| `extension/src/reaper/real.zig` | Add 5 wrapper methods |
| `extension/src/reaper/mock/tracks.zig` | Add mock methods |
| `extension/src/reaper/mock/mod.zig` | Export new methods |
| `extension/src/reaper/backend.zig` | Add to validateBackend |
| `extension/src/trackfxparam_subscriptions.zig` | **NEW** |
| `extension/src/trackfxparam_generator.zig` | **NEW** |
| `extension/src/commands/trackfxparam_subs.zig` | **NEW** |
| `extension/src/commands/trackfxparam.zig` | **NEW** |
| `extension/src/commands/fx.zig` | Add handleGetParams |
| `extension/src/commands/gesture.zig` | Parse fx_param control |
| `extension/src/commands/registry.zig` | Register 4 new commands |
| `extension/src/commands/mod.zig` | Add imports, GlobalContext |
| `extension/src/gesture_state.zig` | Extend ControlId |
| `extension/src/main.zig` | Init, poll, cleanup |
| `extension/API.md` | Document new commands |
| `docs/architecture/TRACK_FX_ENHANCEMENTS.md` | Mark Phase 2 ready |
