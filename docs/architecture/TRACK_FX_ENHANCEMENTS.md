# FX Chain Subscription & Management APIs

## Overview

Add subscription-based FX chain updates + full FX management (add/delete/reorder) with GUID-based stability, modeled after the routing subscription pattern.

**Scope:** Backend only. Frontend integration deferred to separate work.

---

## Command Naming Convention

Use `trackFx/` prefix for all track FX commands to:

- Match REAPER's API families (`TrackFX_*` vs `TakeFX_*`)
- Align with existing `trackFx/setEnabled` command
- Future-proof for item/take FX support (`takeFx/*`)

**Migrate existing commands (same PR):**

| Current | Migrate To |
|---------|------------|
| `fx/presetNext` | `trackFx/presetNext` |
| `fx/presetPrev` | `trackFx/presetPrev` |
| `fx/presetSet` | `trackFx/presetSet` |

---

## Phase 1: FX Chain Subscription + Management (This PR)

### New Files

| File | Purpose |
|------|---------|
| `extension/src/trackfx_subscriptions.zig` | Per-client subscription state (copy routing_subscriptions.zig pattern) |
| `extension/src/trackfx_generator.zig` | JSON generator for `trackFxChain` events |
| `extension/src/commands/trackfx_subs.zig` | `trackFx/subscribe`, `trackFx/unsubscribe` handlers |

### Modified Files

| File | Changes |
|------|---------|
| `extension/src/reaper/raw.zig` | Add `TrackFX_AddByName`, `TrackFX_Delete`, `TrackFX_CopyToTrack`, `TrackFX_GetFXGUID` bindings |
| `extension/src/reaper/real.zig` | Add RealBackend delegation methods |
| `extension/src/reaper/mock/` | Add MockBackend methods for testing |
| `extension/src/fx.zig` | Extend `FxSlot` with `guid` field |
| `extension/src/commands/fx.zig` | Add `handleAdd`, `handleDelete`, `handleMove`; rename preset handlers |
| `extension/src/commands/registry.zig` | Register new commands, update `fx/*` → `trackFx/*` |
| `extension/src/commands/mod.zig` | Add `trackfx_subs` to `GlobalContext` |
| `extension/src/main.zig` | Initialize `g_trackfx_subs`, consume `fx_dirty` flags, poll FX subscriptions |

---

## New Commands

### `trackFx/subscribe`

```json
{"command": "trackFx/subscribe", "trackGuid": "{AAA-BBB-CCC}", "id": "1"}
```

Response: `{"success": true}`
Then receives `trackFxChain` events when FX changes.

### `trackFx/unsubscribe`

```json
{"command": "trackFx/unsubscribe", "id": "1"}
```

### `trackFx/add`

```json
{"command": "trackFx/add", "trackGuid": "{AAA}", "fxName": "ReaEQ", "position": 0, "id": "1"}
```

Response: `{"fxGuid": "{NEW-GUID}", "fxIndex": 0}`

### `trackFx/delete`

```json
{"command": "trackFx/delete", "trackGuid": "{AAA}", "fxGuid": "{FFF}", "id": "1"}
// OR by index:
{"command": "trackFx/delete", "trackGuid": "{AAA}", "fxIndex": 0, "id": "1"}
```

### `trackFx/move`

```json
{"command": "trackFx/move", "trackGuid": "{AAA}", "fxGuid": "{FFF}", "toIndex": 2, "id": "1"}
```

Response: `{"newIndex": 2}`

---

## Event Format

```json
{
  "type": "event",
  "event": "trackFxChain",
  "payload": {
    "trackGuid": "{AAA-BBB-CCC}",
    "fx": [
      {
        "fxGuid": "{FFF-GGG-HHH}",
        "fxIndex": 0,
        "name": "ReaEQ",
        "presetName": "Default",
        "presetIndex": 0,
        "presetCount": 12,
        "modified": false,
        "enabled": true
      }
    ]
  }
}
```

---

## Implementation Steps

### 0. Prerequisites (before Step 1)

- Verify `guidToString` binding exists in `raw.zig` (it does)
- Understand GUID* → string conversion pattern from `real.zig:433-444`

### 1. REAPER API Bindings

In `raw.zig`, add function pointers:

```zig
trackFxAddByName: ?*const fn(*anyopaque, [*:0]const u8, c_int, c_int) callconv(.c) c_int,
trackFxDelete: ?*const fn(*anyopaque, c_int) callconv(.c) bool,
trackFxCopyToTrack: ?*const fn(*anyopaque, c_int, *anyopaque, c_int, bool) callconv(.c) void,
trackFxGetFXGUID: ?*const fn(*anyopaque, c_int) callconv(.c) ?*anyopaque,  // returns GUID*
```

In `real.zig`, add wrapper using `guidToString` pattern:

```zig
pub fn trackFxGetGuid(self: *const RealBackend, track: *anyopaque, fx_idx: c_int, buf: []u8) []const u8 {
    const getGuid = self.inner.trackFxGetFXGUID orelse return "";
    const toString = self.inner.guidToString_fn orelse return "";
    if (buf.len < 64) return "";
    const guid_ptr = getGuid(track, fx_idx) orelse return "";
    toString(guid_ptr, @ptrCast(buf.ptr));
    // Find null terminator and return slice
    for (buf, 0..) |c, i| {
        if (c == 0) return buf[0..i];
    }
    return "";
}
```

### 2. Extend FxSlot

```zig
pub const FxSlot = struct {
    // ... existing fields ...
    guid: [40]u8 = undefined,  // NEW
    guid_len: usize = 0,       // NEW

    pub fn getGuid(self: *const FxSlot) []const u8 {
        return self.guid[0..self.guid_len];
    }

    pub fn eql(self: FxSlot, other: FxSlot) bool {
        // ... existing checks ...
        if (!std.mem.eql(u8, self.guid[0..self.guid_len], other.guid[0..other.guid_len])) return false;
        return true;
    }
};
```

Update `State.poll()` to populate GUID, update `toJson()` to include it.

### 3. Create trackfx_subscriptions.zig

Copy `routing_subscriptions.zig` pattern:

- `ClientSubscription` struct (track GUID)
- `TrackFxSubscriptions` struct with slot management
- `subscribe()`, `unsubscribe()`, `removeClient()`
- `activeSubscriptions()` iterator
- `checkChanged()` with hash comparison
- `consumeForceBroadcast()`

### 4. Create trackfx_generator.zig

```zig
pub fn generateTrackFxChain(
    allocator: Allocator,
    api: anytype,
    guid_cache: *GuidCache,
    track_guid: []const u8,
) ?[]const u8
```

Returns JSON event payload for `trackFxChain` event, uses Wyhash for change detection.

### 5. Add Command Handlers

In `commands/fx.zig`:

- `handleAdd` - wrap in undo block, return fxGuid
- `handleDelete` - resolve by GUID or index, undo block
- `handleMove` - use `TrackFX_CopyToTrack` with same track

**Defensive programming requirements:**
- Call `validateTrackPtr()` after GUID resolution
- Use descriptive undo strings: `"REAmo: Add FX: {fx_name}"`, `"REAmo: Delete FX"`, `"REAmo: Move FX"`
- Log errors before returning: `logging.warn("trackFx/add: {reason}", .{...})`

In `commands/trackfx_subs.zig`:

- `handleSubscribe` - validate trackGuid, call subs.subscribe()
- `handleUnsubscribe` - call subs.unsubscribe()

### 6. Main Loop Integration

In `main.zig`:

- Initialize `g_fx_subs` in `doInitialization()`
- Consume `fx_dirty` flags: `flags.consumeFxDirty()`
- Poll FX subscriptions in HIGH tier loop (similar to routing)
- Clean up on client disconnect
- Deinit on shutdown

### 7. Registry

Add to `registry.zig`:

```zig
// New subscription commands
.{ "trackFx/subscribe", trackfx_subs.handleSubscribe },
.{ "trackFx/unsubscribe", trackfx_subs.handleUnsubscribe },

// New management commands
.{ "trackFx/add", fx.handleAdd },
.{ "trackFx/delete", fx.handleDelete },
.{ "trackFx/move", fx.handleMove },

// Rename existing (update registry entries)
.{ "trackFx/presetNext", fx.handlePresetNext },  // was fx/presetNext
.{ "trackFx/presetPrev", fx.handlePresetPrev },  // was fx/presetPrev
.{ "trackFx/presetSet", fx.handlePresetSet },    // was fx/presetSet
```

---

## Error Handling

| Error Code | Condition |
|------------|-----------|
| `NOT_FOUND` | Track GUID not found |
| `FX_NOT_FOUND` | FX GUID not found on track |
| `INVALID_INDEX` | fxIndex out of range |
| `ADD_FAILED` | TrackFX_AddByName returned -1 |
| `TOO_MANY_CLIENTS` | Subscription limit reached |

---

## CSurf Integration

**Already implemented:**

- `fx_dirty` bitset in `csurf_dirty.zig`
- `consumeFxDirty()` method
- Callbacks wired in `csurf.zig`:
  - `SETFXPARAM` → `setFxDirty(track_idx)`
  - `SETFXENABLED` → `setFxDirty(track_idx)`
  - `SETFXCHANGE` → `skeleton_dirty = true`

**To implement:**

- Consume `fx_dirty` in main loop to force immediate broadcast

---

## Testing

1. **Unit tests** - Copy pattern from `routing_subscriptions.zig` tests
2. **websocat tests** - Subscribe, add FX, verify events
3. **CSurf integration** - Modify FX in REAPER, verify push

---

## Phase 1 Summary

The plan follows established patterns. Key implementation notes:

1. **Raw API bindings don't exist yet** - need adding to `raw.zig`
2. **GUID conversion requires two-step pattern** - `TrackFX_GetFXGUID` returns pointer → `guidToString` converts to string
3. **Defensive programming** - `ValidatePtr` checks, error logging, `"REAmo: ..."` undo prefix
4. **MockBackend/backend.zig updates** - not detailed, but required for testing

The architectural approach (copying `routing_subscriptions` pattern, using CSurf dirty flags) is correct.

---

## Phase 2: FX Parameter Subscription (NEEDS REFINEMENT - DO NOT START YET)

**Architecture:** Mirrors track skeleton + subscription pattern.

### Data Flow

1. **Fetch skeleton** → One-time request returns parameter names (frontend caches in LRU)
2. **Client caches skeleton** → Enables local search, knows total count for virtual scroll
3. **Subscribe to range OR indices** → Server pushes values at 30Hz for subscribed params only
4. **User drags param** → Gesture tracking for undo coalescing

### Commands

**`trackFx/getParams`** - One-time skeleton fetch (not a subscription)

```json
// Request
{"command": "trackFx/getParams", "trackGuid": "{AAA}", "fxGuid": "{FFF}", "id": "1"}

// Response (array index = param index, cache in frontend LRU)
{
  "success": true,
  "payload": {
    "skeleton": ["Gain", "Frequency", "Q", "Output", "Wet/Dry", ...],
    "trackGuid": "{AAA}",
    "fxGuid": "{FFF}"
  }
}
```

**`trackFxParams/subscribe`** - Subscribe to parameter values (virtual scroll)

```json
// Range mode - for scrolling through params in order
{"command": "trackFxParams/subscribe", "trackGuid": "{AAA}", "fxGuid": "{FFF}",
 "range": {"start": 0, "end": 39}}

// Index set mode - for filtered views (disjoint indices)
{"command": "trackFxParams/subscribe", "trackGuid": "{AAA}", "fxGuid": "{FFF}",
 "indices": [0, 5, 12, 47, 89, 102]}
```

**`trackFxParams/unsubscribe`** - Clear subscription

```json
{"command": "trackFxParams/unsubscribe", "id": "1"}
```

**`trackFxParams/set`** - Set parameter value

```json
{"command": "trackFxParams/set", "trackGuid": "{AAA}", "fxGuid": "{FFF}",
 "paramIdx": 5, "value": 0.75, "id": "1"}
```

### Event Format

```json
{
  "type": "event",
  "event": "trackFxParams",
  "payload": {
    "fxGuid": "{FFF}",
    "values": {
      "0": [0.5, "-6.0 dB"],
      "5": [1.0, "On"],
      "12": [0.25, "250 Hz"]
    }
  }
}
```

- Keys are param indices (strings for JSON)
- Values are `[normalizedValue, formattedString]` tuples
- Only includes subscribed indices that changed (or all on initial subscribe)

### Frontend UX Flow

1. User opens FX detail modal
2. Client sends `trackFx/getParams` → gets skeleton (cached in LRU)
3. Client renders virtual scroll (knows param count from skeleton length)
4. Client sends `trackFxParams/subscribe` with visible range + buffer
5. Server pushes `trackFxParams` events at 30Hz when values change
6. User scrolls → client updates subscription range
7. User types filter "freq" → client searches skeleton locally → switches to `indices` mode
8. User clears filter → client switches back to `range` mode
9. User drags parameter → gesture/start → setParam → gesture/end

### Gesture Tracking for Undo

Add new control type to existing gesture infrastructure:

```json
{"command": "gesture/start", "controlType": "trackFxParam",
 "trackGuid": "{AAA}", "fxGuid": "{FFF}", "paramIdx": 5}
// ... trackFxParams/set commands ...
{"command": "gesture/end", "controlType": "trackFxParam",
 "trackGuid": "{AAA}", "fxGuid": "{FFF}", "paramIdx": 5}
```

### CSurf Integration

- `SETFXPARAM` callback already wired → sets `fx_dirty` per track
- For param subscriptions: check if subscribed track's FX changed, re-poll subscribed indices
- Rate limiting: SETFXPARAM fires 43-187x/sec during automation
  - Hash-based change detection prevents duplicate broadcasts
  - Only push when actual values differ from last sent

### Files (Phase 2)

| File | Purpose |
|------|---------|
| `extension/src/trackfxparam_subscriptions.zig` | NEW - Per-client param subscription state |
| `extension/src/commands/trackfxparam_subs.zig` | NEW - subscribe, unsubscribe, set handlers |
| `extension/src/commands/fx.zig` | Add `handleGetParams` for skeleton fetch |
| `extension/src/gesture_state.zig` | Add `trackFxParam` control type |
| `extension/src/commands/gesture.zig` | Parse trackFxParam control ID |

### Key Differences from Track Subscriptions

| Aspect | Tracks | FX Params |
|--------|--------|-----------|
| Skeleton | trackSkeleton (name + GUID) | param names only (index = ID) |
| Addressing | GUID (stable) | index (stable within FX) |
| Subscription | per-track by GUID | per-FX by trackGuid + fxGuid |
| Range mode | track indices | param indices |
| Set mode | track GUIDs | param indices |
| Update freq | 30Hz | 30Hz (rate-limited during automation) |

---

## Documentation Updates

After implementation:

- [ ] Update `extension/API.md` with new commands
- [ ] Update `DEVELOPMENT.md` with FX GUID patterns
- [ ] Update `features/ROADMAP.md` to mark backend complete, frontend pending
