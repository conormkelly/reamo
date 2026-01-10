# Timeline V2 Backend Implementation Plan

**Status**: Simplifying (removing subscriptions)
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

## Simplified Architecture (2026-01-10 v2)

Further simplified to broadcast ALL data to all clients:

### Markers, Regions, AND Items (All Broadcast)
- **No subscription required** — all sent automatically to all clients
- Items included in snapshot on connect (like markers/regions)
- All polled at MEDIUM tier (5Hz), sent when changed via hash comparison
- Full data sent; frontend filters to visible viewport

### What Was Removed (This Revision)
- `timeline_subscriptions.zig` — per-client subscription state
- `commands/timeline_subs.zig` — subscribe/unsubscribe handlers
- `timeline/subscribe` and `timeline/unsubscribe` commands
- Per-client filtering for items
- `jsonGetFloatFromObject` in protocol.zig (no longer needed)

### What Was Removed (Previous Revision)
- `region_skeleton.zig`, `marker_skeleton.zig` (premature optimization)
- Backend buffer calculation
- Per-client filtering for markers/regions

### Rationale
- Bandwidth is negligible over LAN (typical: 50-200 items, <10KB per poll)
- Frontend can efficiently filter/render only visible items
- Subscription system added complexity for scroll/zoom that frontend must handle anyway
- Optimization can be added later (gzip, diff events) if actually needed
- **Simpler = faster to ship, easier to debug**

---

## API Design

### No New Commands

Items are broadcast automatically like markers and regions. No subscription commands needed.

### Event: `items`

Sent at 5Hz when item data changes.

```json
{
  "type": "event",
  "event": "items",
  "data": [
    {
      "trackIdx": 0,
      "position": 0.0,
      "length": 2.5,
      "name": "Audio Item",
      "color": "#FF5500",
      "muted": false
    }
  ]
}
```

**Behavior:**
- Sent to all connected clients when items change (hash-based change detection)
- Included in initial snapshot on connect
- Frontend filters to viewport range for rendering

---

## Frontend Integration

### Frontend Responsibility (Simplified)

Frontend receives ALL items and filters locally:

```javascript
// All items arrive automatically via 'items' event
const allItems = useReaperData().items;

// Filter to viewport for rendering
const visibleItems = useMemo(() =>
  allItems.filter(item =>
    item.position < viewportEnd &&
    (item.position + item.length) > viewportStart
  ),
  [allItems, viewportStart, viewportEnd]
);
```

### Data Flow (Simplified)

1. **On connect:** Receive snapshot with `markers`, `regions`, `trackSkeleton`, AND `items`
2. **Automatic updates:** All four data types update at 5Hz when changed
3. **On viewport change:** Frontend re-filters locally (no backend communication)

---

## Implementation Summary

### Files to Remove
- [ ] `extension/src/timeline_subscriptions.zig` — DELETE entirely
- [ ] `extension/src/commands/timeline_subs.zig` — DELETE entirely

### Files to Modify
- [ ] `extension/src/commands/registry.zig` — Remove timeline handler registrations
- [ ] `extension/src/commands/mod.zig` — Remove timeline_subs import and context
- [ ] `extension/src/main.zig` — Simplify poll loop (items broadcast like markers/regions)
- [ ] `extension/src/protocol.zig` — Remove `jsonGetFloatFromObject` (unused)
- [ ] `extension/API.md` — Remove subscription commands, document items event

### Files to Keep (No Changes)
- `extension/src/items.zig` — Already has `poll()` for full items, `computeHash()` for change detection
- `extension/src/markers.zig` — Already working for broadcast

### Poll Loop (All Broadcast)

```zig
// MEDIUM tier (5Hz) - ALL data types broadcast
if (markers_changed) broadcast(markers_json);
if (regions_changed) broadcast(regions_json);
if (items_changed) broadcast(items_json);  // Now just like markers/regions!
```

---

## Testing

### Build & Test
```bash
make test-extension     # Unit tests
make extension          # Build (requires REAPER restart)
```

### Manual WebSocket Testing

**Verify items arrive automatically:**
```bash
TOKEN=$(curl -s "http://localhost:8099/_/GET/EXTSTATE/Reamo/SessionToken" | awk '{print $4}')

/bin/bash -c 'TOKEN="'$TOKEN'"
(echo "{\"type\":\"hello\",\"clientVersion\":\"1.0.0\",\"protocolVersion\":1,\"token\":\"$TOKEN\"}"
 sleep 2) | websocat ws://localhost:9224 2>&1'
```

**Expected:** Receive snapshot with `items` array. No subscription command needed.

---

## Production Checklist

Per `research/ZIG_PRODUCTION_REVIEW_CHECKLIST.md`:

### Memory Safety
- [x] Arena allocation only in poll functions
- [x] No per-client state needed (broadcast model)
- [x] No pointers held across arena swap/reset

### Thread Safety
- [x] All REAPER API calls on main thread (timer callback)
- [x] Broadcast uses shared lock

### Error Handling
- [x] Graceful degradation: skip poll on error, don't crash

---

## Progress Log

| Date | Phase | Status | Notes |
|------|-------|--------|-------|
| 2026-01-10 | Planning | Complete | Backend plan created |
| 2026-01-10 | Implementation | Complete | Subscription system implemented |
| 2026-01-10 | Simplification v1 | Complete | Removed skeletons, markers/regions broadcast |
| 2026-01-10 | Simplification v2 | In Progress | Removing subscriptions, items broadcast |

---

## Gotchas & Learnings

1. **YAGNI on subscriptions** — Originally added per-client item filtering thinking it would help frontend performance. But frontend needs to filter for rendering anyway, and subscription management added complexity to both backend and frontend.

2. **Broadcast is simpler** — All clients get all data. Frontend filters locally. Scroll/zoom is instant (no round-trip). Server code is trivial.

3. **Optimize later** — If bandwidth becomes an issue (unlikely on LAN), can add:
   - gzip compression
   - Diff-based events (only send changes)
   - Subscription system (re-add if proven necessary)

4. **Items in snapshot** — Unlike the subscription model where items were excluded from snapshot, now items are included like markers/regions.
