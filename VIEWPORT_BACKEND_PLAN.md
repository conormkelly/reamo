# Viewport-Driven Track Subscriptions — Backend Implementation Plan

**Goal:** Implement track subscriptions so large projects (1000+ tracks) don't poll everything at 30Hz.

**Approach:** Clean implementation, no backwards compatibility. Frontend will be updated after backend is solid and tested via websocat.

---

## Architecture Overview

```
LOW TIER (1Hz)
┌─────────────────────┐
│ trackSkeleton event │ ──→ name + GUID for ALL tracks (~65 bytes/track)
│ (broadcast on change)│     Clients use this to build track list UI
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│ GUID Cache rebuild  │     HashMap: GUID string → MediaTrack*
│ (on skeleton change)│     Enables O(1) lookup for write commands
└─────────────────────┘

HIGH TIER (30Hz)
┌─────────────────────┐     ┌─────────────────────┐
│ track/subscribe cmd │ ──→ │ TrackSubscriptions  │
│ (range OR guids)    │     │ (per-client state)  │
└─────────────────────┘     └──────────┬──────────┘
                                       │
                                       ▼
                            ┌─────────────────────┐
                            │ tracks event        │ ──→ Only subscribed tracks
                            │ (keyed by index)    │     + total count for UI
                            └─────────────────────┘

WRITE COMMANDS
┌─────────────────────┐     ┌─────────────────────┐
│ track/setVolume     │ ──→ │ GUID Cache resolve  │ ──→ MediaTrack*
│ (trackGuid param)   │     │ O(1) lookup         │
└─────────────────────┘     └─────────────────────┘
```

---

## Implementation Phases

### Phase 1: GUID Cache
**New file:** `extension/src/guid_cache.zig`

Core data structure for O(1) GUID → track pointer lookup.

```zig
pub const GuidCache = struct {
    allocator: Allocator,
    map: std.StringHashMap(*anyopaque),
    generation: u32,  // Incremented on rebuild for staleness detection

    pub fn init(allocator: Allocator) GuidCache;
    pub fn deinit(self: *GuidCache) void;

    /// Rebuild entire cache from current REAPER state
    /// Called when track structure changes (add/delete/reorder)
    pub fn rebuild(self: *GuidCache, api: anytype) !void;

    /// Resolve GUID to track pointer, or null if not found
    /// "master" resolves to master track
    pub fn resolve(self: *const GuidCache, guid: []const u8) ?*anyopaque;
};
```

**Backend API addition:** Add `getTrackGuid(track, buf) -> []const u8` to RealBackend and MockBackend.

**Why first:** Write commands need this. Can be tested in isolation.

---

### Phase 2: Track Skeleton
**New file:** `extension/src/track_skeleton.zig`

Lightweight track list for client-side filtering.

```zig
pub const SkeletonTrack = struct {
    name: [128]u8 = undefined,
    name_len: usize = 0,
    guid: [40]u8 = undefined,  // 38 char GUID + padding
    guid_len: usize = 0,

    pub fn getName(self: *const SkeletonTrack) []const u8;
    pub fn getGuid(self: *const SkeletonTrack) []const u8;
};

pub const State = struct {
    tracks: []SkeletonTrack = &.{},

    pub fn poll(allocator: Allocator, api: anytype) !State;
    pub fn eql(self: *const State, other: *const State) bool;
    pub fn toJsonAlloc(self: *const State, allocator: Allocator) ![]const u8;
};
```

**Integration:**
- Add to `LowTierState` in tiered_state.zig
- Poll at 1Hz in LOW tier block
- Broadcast only when changed
- Trigger GUID cache rebuild on change
- Send to new clients in snapshot block

**Event format:**
```json
{
  "type": "event",
  "event": "trackSkeleton",
  "tracks": [
    {"name": "Master", "guid": "master"},
    {"name": "Drums", "guid": "{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}"}
  ]
}
```

---

### Phase 3: Track Subscriptions State
**New file:** `extension/src/track_subscriptions.zig`

Per-client subscription management with two modes.

```zig
pub const MAX_TRACKS_PER_CLIENT: usize = 64;
pub const MAX_CLIENTS: usize = 16;
pub const GRACE_PERIOD_MS: u64 = 500;  // Scroll debounce

pub const SubscriptionMode = enum { none, range, guids };

pub const TrackSubscriptions = struct {
    allocator: Allocator,

    // Per-client subscription state
    clients: [MAX_CLIENTS]ClientSubscription,
    client_map: std.AutoHashMap(usize, usize),  // client_id → slot

    // Grace period: tracks recently unsubscribed still get polled briefly
    grace_tracks: std.AutoHashMap(c_int, i64),  // track_idx → expiry_timestamp

    pub fn init(allocator: Allocator) TrackSubscriptions;
    pub fn deinit(self: *TrackSubscriptions) void;

    /// Subscribe by index range (inclusive). Replaces previous subscription.
    pub fn subscribeRange(self: *TrackSubscriptions, client_id: usize, start: c_int, end: c_int) !void;

    /// Subscribe by GUID list. Replaces previous subscription.
    pub fn subscribeGuids(self: *TrackSubscriptions, client_id: usize, guids: []const []const u8) !void;

    /// Unsubscribe completely
    pub fn unsubscribe(self: *TrackSubscriptions, client_id: usize) void;

    /// Remove client on disconnect
    pub fn removeClient(self: *TrackSubscriptions, client_id: usize) void;

    /// Get unified list of track indices to poll
    /// Resolves GUIDs via cache, includes grace period tracks
    pub fn getSubscribedIndices(
        self: *TrackSubscriptions,
        guid_cache: *const GuidCache,
        out_buf: []c_int,
    ) []c_int;

    /// Check if any subscriptions exist
    pub fn hasSubscriptions(self: *const TrackSubscriptions) bool;

    /// Expire old grace period entries (call at 1Hz)
    pub fn expireGracePeriods(self: *TrackSubscriptions) void;
};

const ClientSubscription = struct {
    mode: SubscriptionMode = .none,
    range_start: c_int = 0,
    range_end: c_int = 0,
    guids: std.ArrayList([]const u8),  // Owned copies
    include_master: bool = false,  // Always include master track regardless of range/guids
};
```

---

### Phase 4: Subscription Commands
**Modify:** `extension/src/commands/tracks.zig`, `commands/registry.zig`

Wire up subscription state to WebSocket protocol.

**New handlers:**
```zig
pub var g_track_subs: ?*TrackSubscriptions = null;
pub var g_guid_cache: ?*GuidCache = null;

pub fn handleTrackSubscribe(api: anytype, client_id: usize, json: JsonObject, writer: anytype) void;
pub fn handleTrackUnsubscribe(api: anytype, client_id: usize, json: JsonObject, writer: anytype) void;
```

**Commands:**

```json
// Range subscription
{
  "type": "command",
  "command": "track/subscribe",
  "range": {"start": 0, "end": 31},
  "id": "1"
}

// GUID subscription
{
  "type": "command",
  "command": "track/subscribe",
  "guids": ["master", "{AAA...}", "{BBB...}"],
  "id": "2"
}

// Range subscription with pinned master (for mixer views that always show master)
{
  "type": "command",
  "command": "track/subscribe",
  "range": {"start": 5, "end": 10},
  "includeMaster": true,
  "id": "3"
}

// Unsubscribe
{
  "type": "command",
  "command": "track/unsubscribe",
  "id": "4"
}
```

**Responses:**
```json
{"type": "response", "id": "1", "success": true, "payload": {"subscribedCount": 32}}
{"type": "response", "id": "2", "success": true, "payload": {"subscribedCount": 3}}
{"type": "response", "id": "3", "success": true}
```

---

### Phase 5: Subscription-Aware Track Polling
**Modify:** `extension/src/tracks.zig`, `main.zig`

Only poll subscribed tracks. Include GUID in track data.

**Changes to tracks.zig:**

```zig
pub const Track = struct {
    idx: c_int = 0,
    guid: [40]u8 = undefined,  // NEW: GUID for stable targeting
    guid_len: usize = 0,
    name: [MAX_NAME_LEN]u8 = undefined,
    name_len: usize = 0,
    // ... rest unchanged

    pub fn getGuid(self: *const Track) []const u8 {
        return self.guid[0..self.guid_len];
    }
};

/// Poll only the specified track indices
pub fn pollIndices(allocator: Allocator, api: anytype, indices: []const c_int) !State;
```

**Changes to main.zig HIGH tier:**

```zig
// Get subscribed indices
var indices_buf: [256]c_int = undefined;
const indices = g_track_subs.?.getSubscribedIndices(g_guid_cache.?, &indices_buf);

if (indices.len > 0) {
    // Poll only subscribed tracks
    const track_state = tracks.State.pollIndices(high_alloc, &backend, indices);
    high_state.tracks = track_state.tracks;

    // Get user track count for client virtual scrolling (excludes master)
    const total: usize = @intCast(@max(0, backend.trackCount()));

    // Broadcast with total
    if (track_state.toJsonAllocWithTotal(scratch, metering_ptr, total)) |json| {
        shared_state.broadcast(json);
    }
} else {
    // No subscriptions = no tracks event
    high_state.tracks = &.{};
}
```

**Modified tracks event format:**

```json
{
  "type": "event",
  "event": "tracks",
  "payload": {
    "total": 847,
    "tracks": [
      {
        "idx": 0,
        "guid": "master",
        "name": "MASTER",
        "volume": 1.0,
        ...
      },
      {
        "idx": 5,
        "guid": "{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}",
        "name": "Drums",
        "volume": 0.8,
        ...
      }
    ]
  }
}
```

Key changes:
- `total` field shows user track count, excludes master (for virtual scroll sizing)
- Each track includes `guid` field
- Only subscribed tracks are present in array
- Meters sent separately via `meters` event (see below)

---

### Phase 6: GUID-Based Write Commands
**Modify:** `extension/src/commands/tracks.zig`

All track write commands accept `trackGuid` instead of `trackIdx`.

**Pattern for all handlers:**

```zig
fn resolveTrack(json: JsonObject, cache: *const GuidCache, api: anytype) ?*anyopaque {
    if (json.getString("trackGuid")) |guid| {
        if (std.mem.eql(u8, guid, "master")) {
            return api.getMasterTrack();
        }
        return cache.resolve(guid);
    }
    return null;
}

pub fn handleSetVolume(api: anytype, client_id: usize, json: JsonObject, writer: anytype) void {
    const track = resolveTrack(json, g_guid_cache.?, api) orelse {
        writeError(writer, json, "TRACK_NOT_FOUND", "Track GUID not found");
        return;
    };

    const volume = json.getFloat("volume") orelse {
        writeError(writer, json, "MISSING_VOLUME", "volume required");
        return;
    };

    api.setTrackVolume(track, volume);
    writeSuccess(writer, json, null);
}
```

**Commands to update:**
- `track/setVolume`
- `track/setPan`
- `track/setMute`
- `track/setSolo`
- `track/setRecArm`
- `track/setRecMon`
- `track/setFxEnabled`
- `track/rename`
- `track/delete`
- `track/duplicate`
- `fx/presetNext`, `fx/presetPrev`, `fx/presetSet`
- `send/setVolume`, `send/setMute`
- `meter/clearClip`

**New command format:**
```json
{"type": "command", "command": "track/setVolume", "trackGuid": "{AAA...}", "volume": 0.8, "id": "1"}
{"type": "command", "command": "track/setVolume", "trackGuid": "master", "volume": 0.5, "id": "2"}
```

---

### Phase 7: Wiring & Cleanup
**Modify:** `extension/src/main.zig`

Initialize and wire everything together.

**New globals:**
```zig
var g_track_subs: ?*track_subscriptions.TrackSubscriptions = null;
var g_guid_cache: ?*guid_cache.GuidCache = null;
```

**In doInitialization():**
```zig
// GUID cache
const cache = try g_allocator.create(guid_cache.GuidCache);
cache.* = guid_cache.GuidCache.init(g_allocator);
g_guid_cache = cache;
commands.tracks.g_guid_cache = cache;

// Initial build
var backend = reaper.RealBackend{ .inner = api };
try cache.rebuild(&backend);

// Track subscriptions
const subs = try g_allocator.create(track_subscriptions.TrackSubscriptions);
subs.* = track_subscriptions.TrackSubscriptions.init(g_allocator);
g_track_subs = subs;
commands.tracks.g_track_subs = subs;
```

**In shutdown():**
```zig
if (g_track_subs) |subs| {
    commands.tracks.g_track_subs = null;
    subs.deinit();
    g_allocator.destroy(subs);
    g_track_subs = null;
}

if (g_guid_cache) |cache| {
    commands.tracks.g_guid_cache = null;
    cache.deinit();
    g_allocator.destroy(cache);
    g_guid_cache = null;
}
```

**Client disconnect:**
```zig
if (g_track_subs) |subs| {
    subs.removeClient(client_id);
}
```

**LOW tier (skeleton + grace expiry):**
```zig
// Poll skeleton
const skeleton = track_skeleton.State.poll(low_alloc, &backend);
if (!skeletonEql(low_state.skeleton, low_prev.skeleton)) {
    // Rebuild GUID cache
    g_guid_cache.?.rebuild(&backend) catch |err| {
        logging.err("GUID cache rebuild failed: {s}", .{@errorName(err)});
    };
    // Broadcast skeleton
    if (skeleton.toJsonAlloc(scratch)) |json| {
        shared_state.broadcast(json);
    }
}
low_state.skeleton = skeleton.tracks;

// Expire grace periods
if (g_track_subs) |subs| {
    subs.expireGracePeriods();
}
```

---

## File Summary

| File | Action | Description |
|------|--------|-------------|
| `guid_cache.zig` | NEW | GUID → MediaTrack* cache |
| `track_skeleton.zig` | NEW | Skeleton polling and serialization |
| `track_subscriptions.zig` | NEW | Subscription state management |
| `reaper.zig` (RealBackend) | MODIFY | Add `getTrackGuid()` |
| `reaper.zig` (MockBackend) | MODIFY | Add `getTrackGuid()` |
| `tiered_state.zig` | MODIFY | Add skeleton to LowTierState |
| `tracks.zig` | MODIFY | Add GUID to Track, add `pollIndices()` |
| `commands/tracks.zig` | MODIFY | Subscribe handlers, GUID-based writes |
| `commands/registry.zig` | MODIFY | Register new commands |
| `main.zig` | MODIFY | Initialize systems, wire polling |

---

## API Reference

### Commands

#### `track/subscribe`

Subscribe to track updates. Replaces any previous subscription.

**Range mode** (for scrolling mixer):
```json
{
  "type": "command",
  "command": "track/subscribe",
  "range": {"start": 0, "end": 31},
  "id": "1"
}
```

**GUID mode** (for filtered views):
```json
{
  "type": "command",
  "command": "track/subscribe",
  "guids": ["master", "{XXXXXXXX-...}"],
  "id": "2"
}
```

**Optional `includeMaster` parameter:**

When `includeMaster: true` is set, the master track (index 0) is always included in the subscription regardless of the range or GUID list. This is useful for mixer views that have a "pinned" master track strip that's always visible even when scrolling through other tracks.

```json
{
  "type": "command",
  "command": "track/subscribe",
  "range": {"start": 5, "end": 10},
  "includeMaster": true,
  "id": "1"
}
```

This would subscribe to tracks 5-10 plus the master track (7 tracks total).

**Use case:** A mixer UI might want to always display the master fader for overall level monitoring/metering, while the user scrolls through tracks 5-10 in the main viewport. Without `includeMaster`, the client would need to include "master" in a GUID subscription, which is less convenient for range-based scrolling scenarios.

**Response:**
```json
{"type": "response", "id": "1", "success": true, "payload": {"subscribedCount": 32}}
```

**Errors:**
- `INVALID_RANGE` — end < start
- `SUBSCRIPTION_TOO_LARGE` — more than 64 GUIDs
- `TOO_MANY_CLIENTS` — client slot limit reached

#### `track/unsubscribe`

Stop receiving track updates.

```json
{"type": "command", "command": "track/unsubscribe", "id": "1"}
```

#### Write Commands (all use `trackGuid`)

```json
{"type": "command", "command": "track/setVolume", "trackGuid": "{...}", "volume": 0.8}
{"type": "command", "command": "track/setPan", "trackGuid": "{...}", "pan": -0.5}
{"type": "command", "command": "track/setMute", "trackGuid": "{...}", "mute": 1}
{"type": "command", "command": "track/setSolo", "trackGuid": "{...}", "solo": 1}
{"type": "command", "command": "track/setRecArm", "trackGuid": "{...}", "arm": 1}
{"type": "command", "command": "track/setRecMon", "trackGuid": "{...}", "mon": 1}
{"type": "command", "command": "track/setFxEnabled", "trackGuid": "{...}", "enabled": 1}
{"type": "command", "command": "track/rename", "trackGuid": "{...}", "name": "New Name"}
{"type": "command", "command": "track/delete", "trackGuid": "{...}"}
{"type": "command", "command": "fx/presetNext", "trackGuid": "{...}", "fxIdx": 0}
{"type": "command", "command": "send/setVolume", "trackGuid": "{...}", "sendIdx": 0, "volume": 0.5}
{"type": "command", "command": "meter/clearClip", "trackGuid": "{...}"}
```

Master track uses `"master"` as GUID:
```json
{"type": "command", "command": "track/setVolume", "trackGuid": "master", "volume": 0.8}
```

### Events

#### `trackSkeleton`

Broadcast at 1Hz when track structure changes. Contains name + GUID for all tracks.

```json
{
  "type": "event",
  "event": "trackSkeleton",
  "tracks": [
    {"name": "Master", "guid": "master"},
    {"name": "Drums", "guid": "{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}"},
    {"name": "Bass", "guid": "{YYYYYYYY-YYYY-YYYY-YYYY-YYYYYYYYYYYY}"}
  ]
}
```

#### `tracks` (modified)

Broadcast when track data changes. Only contains subscribed tracks.

```json
{
  "type": "event",
  "event": "tracks",
  "payload": {
    "total": 847,
    "tracks": [
      {
        "idx": 0,
        "guid": "master",
        "name": "MASTER",
        "color": 0,
        "volume": 1.0,
        "pan": 0.0,
        "mute": false,
        "solo": 0,
        "recArm": false,
        "recMon": 0,
        "fxEnabled": true,
        "selected": false,
        "folderDepth": 0,
        "fxCount": 2,
        "sendCount": 0,
        "receiveCount": 0
      }
    ]
  }
}
```

**New fields:**
- `total` — User track count, excludes master (for virtual scroll)
- `guid` — Track GUID (per track)

**Behavior change:**
- Only subscribed tracks included
- Meters sent separately via `meters` event

#### `meters` (new)

Broadcast at 30Hz for subscribed tracks. Map format keyed by GUID for O(1) frontend lookup.

```json
{
  "type": "event",
  "event": "meters",
  "m": {
    "master": {"i": 0, "l": 0.75, "r": 0.68, "c": false},
    "{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}": {"i": 5, "l": 0.5, "r": 0.6, "c": false}
  }
}
```

**Fields:**
- `m` — Map of GUID → meter data
- `i` — Track index
- `l`, `r` — Left/right peak levels (0.0-1.0+)
- `c` — Clip indicator (sticky until `meter/clearClip`)

---

## Testing via websocat

### Setup

```bash
# Get session token
TOKEN=$(curl -s "http://localhost:8099/_/GET/EXTSTATE/Reamo/SessionToken")

# Connect and authenticate
echo '{"type":"hello","clientVersion":"1.0.0","protocolVersion":1,"token":"'$TOKEN'"}' | \
  websocat ws://localhost:9224
```

### Test Skeleton Event

```bash
# Should receive trackSkeleton shortly after connect
(echo '{"type":"hello","clientVersion":"1.0.0","protocolVersion":1,"token":"'$TOKEN'"}'
 sleep 2) | websocat ws://localhost:9224 2>&1 | grep trackSkeleton
```

### Test Range Subscription

```bash
(echo '{"type":"hello","clientVersion":"1.0.0","protocolVersion":1,"token":"'$TOKEN'"}'
 sleep 0.2
 echo '{"type":"command","command":"track/subscribe","range":{"start":0,"end":5},"id":"sub1"}'
 sleep 1) | websocat ws://localhost:9224 2>&1 | grep -E "(response|tracks)"
```

Expected: Response with subscribedCount, then tracks events with only indices 0-5.

### Test Range Subscription with Pinned Master

```bash
(echo '{"type":"hello","clientVersion":"1.0.0","protocolVersion":1,"token":"'$TOKEN'"}'
 sleep 0.2
 echo '{"type":"command","command":"track/subscribe","range":{"start":5,"end":7},"includeMaster":true,"id":"sub1"}'
 sleep 1) | websocat ws://localhost:9224 2>&1 | grep -E "(response|tracks)"
```

Expected: Response with `subscribedCount: 4` (tracks 5-7 = 3 + master = 4), then tracks events containing idx 0 (master) plus idx 5, 6, 7.

### Test GUID Subscription

```bash
# First get skeleton to find GUIDs, then subscribe by GUID
(echo '{"type":"hello","clientVersion":"1.0.0","protocolVersion":1,"token":"'$TOKEN'"}'
 sleep 0.5
 echo '{"type":"command","command":"track/subscribe","guids":["master"],"id":"sub2"}'
 sleep 1) | websocat ws://localhost:9224 2>&1
```

### Test GUID-Based Write

```bash
(echo '{"type":"hello","clientVersion":"1.0.0","protocolVersion":1,"token":"'$TOKEN'"}'
 sleep 0.2
 echo '{"type":"command","command":"track/setVolume","trackGuid":"master","volume":0.5,"id":"vol1"}'
 sleep 0.2) | websocat ws://localhost:9224 2>&1 | grep response
```

### Test Unsubscribe

```bash
(echo '{"type":"hello","clientVersion":"1.0.0","protocolVersion":1,"token":"'$TOKEN'"}'
 sleep 0.2
 echo '{"type":"command","command":"track/subscribe","range":{"start":0,"end":5},"id":"sub"}'
 sleep 0.5
 echo '{"type":"command","command":"track/unsubscribe","id":"unsub"}'
 sleep 0.5) | websocat ws://localhost:9224 2>&1
```

After unsubscribe, should stop receiving tracks events.

---

## Unit Test Plan

### guid_cache.zig

```zig
test "rebuild populates map from backend" { ... }
test "resolve returns null for unknown GUID" { ... }
test "resolve handles master special case" { ... }
test "rebuild clears stale entries" { ... }
```

### track_skeleton.zig

```zig
test "poll extracts name and GUID" { ... }
test "eql detects name change" { ... }
test "eql detects track add" { ... }
test "eql detects track remove" { ... }
test "toJson format is correct" { ... }
```

### track_subscriptions.zig

```zig
test "subscribeRange sets mode and range" { ... }
test "subscribeGuids replaces range subscription" { ... }
test "unsubscribe moves tracks to grace period" { ... }
test "getSubscribedIndices returns range" { ... }
test "getSubscribedIndices resolves GUIDs" { ... }
test "getSubscribedIndices includes grace tracks" { ... }
test "expireGracePeriods removes old entries" { ... }
test "removeClient cleans up everything" { ... }
test "multiple clients same track" { ... }
test "includeMaster adds master to range subscription" { ... }
test "includeMaster adds master to GUID subscription" { ... }
```

### tracks.zig

```zig
test "pollIndices returns only requested tracks" { ... }
test "Track includes GUID" { ... }
test "toJson includes total field" { ... }
```

---

## Open Questions

1. **Empty subscription behavior:** When client has no subscription, should they receive:
   - Nothing (current plan)
   - Error response on connect saying "subscribe required"

   **Recommendation:** Nothing. Client is expected to subscribe after receiving skeleton.

2. **Snapshot on connect:** Should new clients receive tracks in snapshot, or wait for subscription?

   **Recommendation:** Skeleton only in snapshot. Tracks after subscription. This is cleaner.

3. **Grace period scope:** Should grace period be per-client or global?

   **Recommendation:** Global (current plan). If any client was recently watching a track, keep polling it. Simpler and handles multi-client scenarios.

---

## Risk Mitigation

| Risk | Mitigation |
|------|------------|
| GUID cache stale | Rebuild on every skeleton change (1Hz); write commands fail gracefully |
| Race: track deleted during GUID resolve | Return TRACK_NOT_FOUND, client handles gracefully |
| Memory: many GUID strings | Hard limit 64 per client; GUIDs are 38 chars |
| Performance: GUID HashMap overhead | StringHashMap is O(1); 1000 tracks = negligible |

---

## Definition of Done

- [ ] `make test-extension` passes with new tests
- [ ] Connect via websocat, receive skeleton
- [ ] Subscribe by range, receive only those tracks
- [ ] Subscribe by GUID, receive only those tracks
- [ ] Subscribe with `includeMaster: true`, receive master + range tracks
- [ ] Unsubscribe, stop receiving tracks
- [ ] Write command with trackGuid works
- [ ] Write command with "master" GUID works
- [ ] Add track in REAPER, skeleton updates
- [ ] Delete track in REAPER, skeleton updates
- [ ] Delete subscribed track, write command returns TRACK_NOT_FOUND
- [ ] Disconnect client, subscriptions cleaned up
