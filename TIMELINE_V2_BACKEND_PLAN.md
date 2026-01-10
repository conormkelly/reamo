# Timeline V2 Backend Implementation Plan

**Status**: ✅ Implementation Complete
**Last Updated**: 2026-01-10
**PR Target**: PR4a (Backend Only)

---

## Quick Links

| Resource | Path | Purpose |
|----------|------|---------|
| Feature Overview | `TIMELINE_V2_OVERVIEW.md` | Full feature spec, research results, UX decisions |
| Development Guide | `DEVELOPMENT.md` | Architecture, conventions, pitfalls |
| API Reference | `extension/API.md` | WebSocket command/event documentation |
| Production Checklist | `research/ZIG_PRODUCTION_REVIEW_CHECKLIST.md` | Safety audit requirements |

---

## Simplified Architecture (2026-01-10)

The original design was simplified to remove unnecessary complexity:

### Markers & Regions (Broadcast)
- **No subscription required** — sent automatically to all clients
- Included in snapshot on connect
- Polled at MEDIUM tier (5Hz), sent when changed
- Full data: id, name, position/start/end, color, beats info

### Items (Subscription Required)
- Requires `timeline/subscribe` with `timeRange: {start, end}`
- **Frontend specifies exact range** including any buffer it needs
- **Backend does NOT calculate buffer** — simple separation of concerns
- Polled at MEDIUM tier (5Hz), per-client filtering by time range
- **NOT in snapshot** — client must subscribe to receive items

### What Was Removed
- `region_skeleton.zig`, `marker_skeleton.zig` (premature optimization)
- Backend buffer calculation
- Per-client filtering for markers/regions (now broadcast)

### Rationale
- Bandwidth is negligible over LAN
- Most users want marker/region data immediately
- Skeleton + full-data subscriptions added complexity for ~1% edge cases
- Optimization can be added later (gzip, diff events) if actually needed

---

## API Design

### Command: `timeline/subscribe`

Subscribe to **items** for a time range. Replaces any previous subscription.

```json
{
  "type": "command",
  "command": "timeline/subscribe",
  "timeRange": { "start": 0.0, "end": 30.0 },
  "id": "1"
}
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `timeRange.start` | float | Yes | Start time in seconds (≥0) |
| `timeRange.end` | float | Yes | End time in seconds (> start) |

**Response:**
```json
{
  "type": "response",
  "id": "1",
  "success": true,
  "payload": {
    "subscribedRange": { "start": 0.0, "end": 30.0 }
  }
}
```

**Behavior:**
- Items within range sent immediately, then on change at 5Hz (MEDIUM tier)
- Frontend specifies exact range (including any buffer it needs)
- Markers and regions are **broadcast to all clients** (no subscription needed)

**Errors:**
- `INVALID_PARAMS` — Missing or invalid timeRange
- `INVALID_RANGE` — start >= end or negative values

### Command: `timeline/unsubscribe`

Unsubscribe from items updates. Called automatically on disconnect.

```json
{
  "type": "command",
  "command": "timeline/unsubscribe",
  "id": "2"
}
```

**Response:**
```json
{
  "type": "response",
  "id": "2",
  "success": true
}
```

**Note:** This only affects items. Markers and regions continue to broadcast.

---

## Frontend Integration

### Buffer Calculation (Frontend Responsibility)

The frontend must calculate the buffer and include it in the subscription range:

```javascript
// Calculate buffer as 100% of visible duration
const buffer = viewportEnd - viewportStart;
const start = Math.max(0, viewportStart - buffer);
const end = viewportEnd + buffer;

ws.send({
  type: "command",
  command: "timeline/subscribe",
  timeRange: { start, end },
  id: "sub-1"
});
```

### Data Flow

1. **On connect:** Receive snapshot with `markers`, `regions`, `trackSkeleton` (NOT items)
2. **Subscribe to items:** Send `timeline/subscribe` with viewport range + buffer
3. **Receive items:** Get `items` event with items in subscribed range
4. **On viewport change:** Re-subscribe with new range
5. **Markers/regions:** Received automatically when they change (no subscription needed)

---

## Implementation Summary

### Files Created
- [x] `extension/src/timeline_subscriptions.zig` — Per-client subscription state (items only)
- [x] `extension/src/commands/timeline_subs.zig` — Command handlers

### Files Modified
- [x] `extension/src/commands/registry.zig` — Register 2 handlers
- [x] `extension/src/commands/mod.zig` — Add timeline_subs to CommandContext
- [x] `extension/src/protocol.zig` — Add `jsonGetFloatFromObject`
- [x] `extension/src/items.zig` — Add `pollTimeRange()`, `computeHash()`
- [x] `extension/src/markers.zig` — Add hash functions for change detection
- [x] `extension/src/main.zig` — Poll loop integration, init/cleanup
- [x] `extension/API.md` — Document commands and events
- [x] `DEVELOPMENT.md` — Document subscription pattern

### Key Implementation Details

**TimeRange struct (simplified):**
```zig
pub const TimeRange = struct {
    start: f64 = 0,  // Start time in seconds (>= 0)
    end: f64 = 0,    // End time in seconds (> start)
};
```

**ClientSubscription (items only):**
```zig
pub const ClientSubscription = struct {
    range: TimeRange = .{},
    active: bool = false,
    force_broadcast: bool = false,
    last_items_hash: u64 = 0,  // Only items - markers/regions are broadcast
};
```

**Poll loop (items per-client, markers/regions broadcast):**
```zig
// MEDIUM tier (5Hz)

// Markers/regions: broadcast to ALL clients (no subscription)
if (markers_changed) broadcast(markers_json);
if (regions_changed) broadcast(regions_json);

// Items: per-client filtering (subscription required)
if (timeline_subs.hasSubscriptions()) {
    var iter = timeline_subs.subscribedClientIterator();
    while (iter.next()) |entry| {
        const filtered_items = items.pollTimeRange(alloc, api, entry.range.start, entry.range.end);
        if (timeline_subs.shouldSendItems(entry.client_id, filtered_items.computeHash())) {
            sendToClient(entry.client_id, filtered_items.toJson());
        }
    }
}
```

---

## Testing

### Build & Test
```bash
make test-extension     # Unit tests
make extension          # Build (requires REAPER restart)
```

### Manual WebSocket Testing

**Subscribe to items:**
```bash
TOKEN=$(curl -s "http://localhost:8099/_/GET/EXTSTATE/Reamo/SessionToken" | awk '{print $4}')

/bin/bash -c 'TOKEN="'$TOKEN'"
(echo "{\"type\":\"hello\",\"clientVersion\":\"1.0.0\",\"protocolVersion\":1,\"token\":\"$TOKEN\"}"
 echo "{\"type\":\"command\",\"command\":\"timeline/subscribe\",\"timeRange\":{\"start\":0,\"end\":30},\"id\":\"1\"}"
 sleep 2) | websocat ws://localhost:9224 2>&1'
```

**Expected:** Receive response + `items` event. Markers/regions arrive in snapshot automatically.

---

## Production Checklist

Per `research/ZIG_PRODUCTION_REVIEW_CHECKLIST.md`:

### Memory Safety
- [x] Arena allocation only in poll functions
- [x] Fixed-size client slots (MAX_CLIENTS = 16)
- [x] Per-client hash tracking uses fixed slots (no dynamic allocation)
- [x] No pointers held across arena swap/reset

### FFI Correctness
- [x] Validate time values with `std.math.isFinite()`
- [x] Range validation in command handler

### Thread Safety
- [x] All REAPER API calls on main thread (timer callback)
- [x] Per-client sendToClient uses shared lock
- [x] Subscription state only modified from main thread

### Error Handling
- [x] Graceful degradation: skip client on poll error, don't crash
- [x] Client receives error response for invalid params

---

## Progress Log

| Date | Phase | Status | Notes |
|------|-------|--------|-------|
| 2026-01-10 | Planning | Complete | Backend plan created |
| 2026-01-10 | Implementation | Complete | All phases implemented |
| 2026-01-10 | Simplification | Complete | Removed skeletons, reverted markers/regions to broadcast |
| 2026-01-10 | Documentation | Complete | Updated API.md, DEVELOPMENT.md |

---

## Gotchas & Learnings

1. **Per-client filtering only for items** — Markers/regions are broadcast to all clients. Only items need per-client filtering since they can be numerous in large projects.

2. **Frontend calculates buffer** — Simple separation of concerns. Backend returns exactly what frontend asks for. Frontend knows its viewport and can calculate appropriate buffer.

3. **Items NOT in snapshot** — Unlike markers/regions which are always useful, items require a viewport context. Client must subscribe after connect.

4. **Overlap detection for items** — Items use `overlapsRange()` (partial overlap counts): `item.position < range.end AND item.end > range.start`.

5. **Force broadcast on subscribe** — When client subscribes or changes range, `force_broadcast` flag ensures immediate data delivery regardless of hash.
