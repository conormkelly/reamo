# Viewport-Driven Architecture

> Research and architecture decisions for scaling Reamo to 1000+ tracks.
>
> **Date:** 2026-01-06
> **Status:** Architecture defined, ready for implementation

---

## Executive Summary

We're moving from "broadcast everything" to "viewport-driven subscriptions" to support large projects (1000+ tracks, 5000+ items) without overwhelming clients or the DAW.

**Key insight:** We subscribe to **slots, not entities**. "Give me tracks 20-30" means "whatever is in those index positions right now." Reorders and deletes just show the new slot contents on the next poll.

---

## The Problem

### Original Assumptions (No Longer Valid)

The polling system assumed small-to-medium projects:
- 20-50 tracks
- ~200 items
- "Poll everything" was fast enough

**New goal: "Audio Production Without Limits"** — 1000+ tracks, 5000+ items, arbitrarily large sessions.

### Why Pagination Is Hard

REAPER is not a database. Tracks/items are:
- Indexed by position (track 0, track 1, ...)
- Subject to insertion/deletion at any time
- Reordered by user actions (drag track up/down)

**Example failure with offset-based pagination:**
```
Frame 1: Poll tracks 50-100 (offset=50, limit=50)
         User deletes track 30
Frame 2: Poll tracks 100-150 (offset=100, limit=50)
         Track 51 is now at index 50 — we skip it forever!
         Track 100 is now at index 99 — we poll it twice!
```

### The Solution: Slots Not Entities (for Reads)

The viewport subscription is about **index slots**, not stable entity IDs:
- "Give me tracks 20-30" = "whatever is in slots 20-30 right now"
- If track 25 gets deleted, slot 25 now contains what was track 26
- Next 30Hz poll shows the new reality
- No cursor tracking needed for read subscriptions

This simplifies reads. Write commands use GUIDs for stability (see [Write Command Stability](#write-command-stability)).

---

## Architecture Overview

### Two-Tier Data Model

| Event | Tier | Frequency | Payload | Purpose |
|-------|------|-----------|---------|---------|
| `trackSkeleton` | LOW | 1-5Hz | All tracks, minimal fields | Search, navigation, structure |
| `tracks` | HIGH | 30Hz | Subscribed tracks only, full data | Live mixing, meters |

### Skeleton Event (broadcast on change only)

```json
{
  "event": "trackSkeleton",
  "t": [
    { "n": "Master", "g": "master" },
    { "n": "Drums", "g": "{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}" },
    { "n": "Kick", "g": "{YYYYYYYY-YYYY-YYYY-YYYY-YYYYYYYYYYYY}" }
  ]
}
```

- **`t`**: Array of track objects (index = array position)
  - `n`: Track name
  - `g`: Track GUID (or `"master"` for master track)
- **Size**: ~65 bytes/track with JSON overhead, 1000 tracks = 65KB
- **No color/depth** — Those come from HIGH tier when track is visible
- **GUIDs included** — Client uses for write command targeting

**Polling vs Broadcasting:**
- **Poll at 5Hz** — Safe even with 2000 tracks (count + names + guids)
- **Broadcast only on change** — Most frames, nothing changes
- **Change detection:**
  - `CountTracks()` → O(1) check
  - If count changed → immediate broadcast
  - If count same → compare cached names (O(n) string compare, no API calls)
- **On client connect** — Send current skeleton immediately (before any `tracks` events, so client has GUIDs for write commands)

**Search flow:**
1. User types "Guitar"
2. Client filters: `skeleton.filter(t => t.n.includes("Guitar")).map((t, i) => i)` → `[5, 23, 67]`
3. Client subscribes to `[5, 23, 67]`
4. Server sends full track data at 30Hz
5. UI shows with color, volume, meters — feels instant

### Tracks Event (HIGH tier, subscribed only)

```json
{
  "event": "tracks",
  "total": 847,
  "data": {
    "5": { "idx": 5, "guid": "{AAA...}", "name": "Drums", "volume": 0.8, "pan": 0, ... },
    "23": { "idx": 23, "guid": "{BBB...}", "name": "Guitar", "volume": 0.6, "pan": -0.3, ... }
  }
}
```

- **`total`**: Track count canary — catches structural changes within 33ms
- **`data`**: Keyed by index, only includes subscribed tracks
- Each track includes `guid` for write command targeting
- Full track data: volume, pan, mute, solo, recArm, meters, etc.

---

## Subscription Protocol

### Two Subscription Modes

**Why two modes?** Different use cases need different stability guarantees:

1. **Range-based (slot subscriptions)** — User scrolling through the mixer. "Give me tracks 0-32." If tracks shift, that's fine — next poll shows the new slot contents. Fast, simple.

2. **GUID-based (stable subscriptions)** — User filtering by name (e.g., "guitar"). The filtered set should be stable even if tracks are reordered. Subscribe by GUID so the subscription doesn't break when "Rhythm Guitar" moves from index 3 to index 4.

### Commands

```typescript
// Range-based: scrolling through mixer
// "Give me whatever is in slots 0-32 right now"
{ "type": "track/subscribe", "range": { "start": 0, "end": 32 } }

// GUID-based: filtered view
// "Give me these specific tracks, regardless of their current index"
{ "type": "track/subscribe", "guids": ["{AAA...}", "{BBB...}", "{CCC...}"] }

// Unsubscribe all
{ "type": "track/unsubscribe" }
```

### Use Case: Scrolling Through Mixer

```
1. User opens mixer, sees tracks 0-32
2. Client subscribes: { range: { start: 0, end: 32 } }
3. User scrolls right
4. Client subscribes: { range: { start: 20, end: 52 } }
5. Someone deletes track 10 in REAPER
6. Server sends data for slots 20-52 — now contains different tracks
7. Client displays updated content, user sees the shift
```

Slot-based is correct here. The mixer scroll position is spatial — "show me what's in the right side of my mixer."

### Use Case: Filtered View

```
1. User types "guitar" in filter
2. Client filters skeleton: matches at indices [3, 12, 17, 45]
3. Client subscribes: { guids: ["{AAA}", "{BBB}", "{CCC}", "{DDD}"] }
4. Someone moves "Rhythm Guitar" from track 3 to track 4
5. Server looks up GUIDs, sends data with CURRENT indices:
   { "4": {...}, "12": {...}, "17": {...}, "45": {...} }
6. Client displays filtered tracks in correct order
7. On next skeleton refresh, client re-filters, updates subscription if needed
```

GUID-based is correct here. The filter is semantic — "show me all guitar tracks" shouldn't break when tracks move.

### Filtered View with Many Matches

**Q: What if filter matches 140 tracks but max subscription is 64?**

Filtered views still use virtual scrolling. You never subscribe to all 140 — only what's visible.

**Key distinction:**
- **Skeleton**: Client has ALL track names/GUIDs locally (for filtering, showing "140 matches")
- **Subscription**: Client only subscribes to VISIBLE tracks (for live data: volume, meters)

```
1. User types "a" in filter
2. Client filters skeleton locally: 140 matches
3. UI shows: "140 tracks" in filter badge (no subscription needed for this)
4. Virtual scroller renders first 20 visible filtered tracks
5. Client subscribes to those 20 GUIDs + buffer (32 total)
6. User scrolls down in filtered view
7. Virtual scroller updates visible items
8. Client subscribes to new visible GUIDs
```

**Client-side implementation:**

```typescript
// Filter skeleton locally
const filteredTracks = skeleton.t
  .map((t, i) => ({ ...t, originalIndex: i }))
  .filter(t => t.n.toLowerCase().includes(query));
// filteredTracks has 140 items

// Virtual scroll within filtered results
const virtualizer = useVirtualizer({
  count: filteredTracks.length,  // 140
  estimateSize: () => TRACK_HEIGHT,
  overscan: 5,
});

// Subscribe only to visible GUIDs
const visibleGuids = virtualizer.getVirtualItems()
  .slice(0, 32)  // respect max subscription size
  .map(item => filteredTracks[item.index].g);

sendCommand({ type: 'track/subscribe', guids: visibleGuids });
```

The 64 GUID limit is fine — you can't see 64 tracks at once anyway.

### Response Format (same for both modes)

```json
{
  "event": "tracks",
  "total": 847,
  "data": {
    "4": { "idx": 4, "guid": "{AAA...}", "name": "Rhythm Guitar", ... },
    "12": { "idx": 12, "guid": "{BBB...}", "name": "Lead Guitar", ... }
  }
}
```

Response always includes current index and GUID for each track. Client can use index for ordering, GUID for write commands.

### Constraints

- **Max 64 GUIDs per subscription** — Beyond this, return `subscription_too_large` error
- **Replace-whole-set semantics** — Each subscribe replaces previous subscription
- **Mutually exclusive modes** — Range and GUID subscriptions are mutually exclusive. Sending a range subscription clears any GUID subscription and vice versa.
- **Reference counting** — Multiple clients can subscribe to same tracks
- **Grace periods** — Delay actual unsubscription to reduce churn
- **Deleted GUIDs** — If a subscribed GUID no longer exists, omit from response. Client detects by comparing requested GUIDs vs received keys — missing means "show fewer rows" in filtered view, handled on next skeleton refresh.

### Grace Period Timing

| Context | Duration | Rationale |
|---------|----------|-----------|
| Scroll-based | 500ms | Smooth scroll-back UX |
| Tab backgrounding | 30 seconds | User might return |
| Reconnection | 2 minutes | Restore previous viewport |

---

## Client-Side Patterns

### Debounce/Throttle Timing

| Operation | Technique | Timing |
|-----------|-----------|--------|
| Viewport position updates | Throttle | 100ms |
| Subscription range changes | Debounce | 200ms |
| Initial subscription | Immediate | 0ms |
| Unsubscribe grace | Delay | 500ms |

### Virtual Scrolling Integration

Use TanStack Virtual (recommended) or similar:

```typescript
const virtualizer = useVirtualizer({
  count: totalTracks,
  getScrollElement: () => parentRef.current,
  estimateSize: () => TRACK_HEIGHT,
  overscan: 5,  // DOM buffer (small for performance)
});

// Subscription buffer is larger than DOM buffer
const SUBSCRIPTION_BUFFER = 50;

const updateSubscription = useDebouncedCallback((items) => {
  const visibleStart = items[0]?.index ?? 0;
  const visibleEnd = items[items.length - 1]?.index ?? 0;

  sendCommand({
    type: 'track/subscribe',
    range: {
      start: Math.max(0, visibleStart - SUBSCRIPTION_BUFFER),
      end: Math.min(totalTracks, visibleEnd + SUBSCRIPTION_BUFFER)
    }
  });
}, 200);
```

### Filtered/Search Views

1. Client receives skeleton at 1-5Hz (all tracks: name + guid)
2. Client filters locally: `skeleton.t.filter(t => t.n.includes(query))`
3. Client subscribes to matching GUIDs: `["{AAA...}", "{BBB...}", ...]`
4. Server looks up GUIDs, polls those tracks at 30Hz

No server-side filter state needed. Search is instant, no round-trip.

---

## Backend Implementation Notes

### Slot-Based Polling

```zig
// Poll only subscribed indices
fn pollSubscribedTracks(subscribed_indices: []const c_int, out: *TrackDataMap) void {
    for (subscribed_indices) |idx| {
        if (getTrackByUnifiedIdx(idx)) |track| {
            out.put(idx, pollTrackData(track));
        }
    }
}
```

### GUID-Based Polling

```zig
// Poll subscribed GUIDs, return with current indices
fn pollSubscribedTracksByGuid(subscribed_guids: []const []const u8, out: *TrackDataMap) void {
    for (subscribed_guids) |guid| {
        if (guid_to_track.get(guid)) |track| {
            const idx = getTrackIndex(track);  // Current index, may have changed
            out.put(idx, pollTrackData(track));
        }
        // If GUID not found, omit silently — client handles on skeleton refresh
    }
}
```

### Skeleton Polling

```zig
// LOW tier: poll all tracks, name + guid only
fn pollTrackSkeleton(allocator: Allocator) []SkeletonTrack {
    const count = trackCount();
    var skeleton = allocator.alloc(SkeletonTrack, count);

    for (0..count) |i| {
        if (getTrackByUnifiedIdx(i)) |track| {
            skeleton[i] = .{
                .name = getTrackName(track),
                .guid = getTrackGuidString(track),  // "master" for idx 0
            };
        }
    }
    return skeleton;
}
```

---

## Write Command Stability

### The Problem: Reads vs Writes

**Reads** use index-based subscriptions (slots) — this works because the next poll shows the new reality. No stability needed.

**Writes** are dangerous when tracks shift mid-gesture:

```
1. User starts dragging fader on track 5 ("Drums" in their view)
2. Someone deletes track 3 in REAPER
3. Track 5 is now track 4. What was track 6 is now track 5.
4. Client's setVolume(trackIdx=5, ...) applies to WRONG track
```

This is especially bad during gestures (fader drags) which span many commands over 1-2 seconds.

**Industry context:** No control surface protocol (MCU, HUI, EUCON, OSC) has solved this — they all use indices. We'd be first to use stable IDs for writes.

### The Solution: GUID-Based Write Commands

Write commands use track GUID instead of index:

```json
// Read subscription (index-based, unchanged)
{ "type": "track/subscribe", "range": { "start": 20, "end": 50 } }

// Write command (GUID-based)
{ "type": "track/setVolume", "trackGuid": "{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}", "volume": 0.8 }
```

**Why this works:**
- GUIDs are stable — assigned on track creation, survive undo/redo, persist in .RPP file
- Duplicated tracks get new GUIDs (they're distinct entities)
- Commands target the intended track regardless of index shifts

### Server-Side GUID Cache

REAPER has no `GetTrackByGUID()` — we'd have to iterate all tracks. Instead, maintain a server-side HashMap:

```zig
const GuidTrackMap = std.StringHashMap(*c.MediaTrack);
var guid_to_track: GuidTrackMap = undefined;

fn rebuildGuidMap(allocator: Allocator) void {
    guid_to_track.clearRetainingCapacity();
    const count = c.CountTracks(null);
    for (0..@intCast(count)) |i| {
        const track = c.GetTrack(null, @intCast(i));
        const guid = c.GetTrackGUID(track);
        var buf: [64]u8 = undefined;
        c.guidToString(guid, &buf);
        guid_to_track.put(buf[0..38], track) catch {};
    }
}
```

**Invalidation:** Rebuild on track add/delete (detected via `CountTracks()` change) or reorder (detected via name array mismatch during skeleton polling).

**Performance:** HashMap lookup is sub-microsecond vs O(n) iteration.

### Gesture Locking Pattern

Lock GUID resolution at gesture start, not on each command:

```typescript
// Client-side
onGestureStart(displayIndex: number) {
  const track = tracksByIndex[displayIndex];
  this.activeGesture = { guid: track.guid };
  sendCommand({ type: 'gesture/start', trackGuid: track.guid, controlType: 'volume' });
}

onGestureMove(value: number) {
  // Always use locked GUID, never re-resolve from display index
  sendCommand({ type: 'track/setVolume', trackGuid: this.activeGesture.guid, volume: value });
}

onGestureEnd() {
  sendCommand({ type: 'gesture/end', trackGuid: this.activeGesture.guid, controlType: 'volume' });
  this.activeGesture = null;
}
```

### Master Track Special Case

**Gotcha:** REAPER has a known bug where `GetTrackGUID()` returns inconsistent values for master track.

**Solution:** Use reserved identifier `"master"` instead of GUID:

```json
{ "type": "track/setVolume", "trackGuid": "master", "volume": 0.8 }
```

Server resolves `"master"` to `GetMasterTrack()` directly.

### Error Handling

**Track deleted during gesture:**

1. Server returns `{ "error": "TRACK_NOT_FOUND", "trackGuid": "..." }`
2. Client provides haptic feedback (vibration)
3. Fader visual shows "disconnected" state (greyed out)
4. Gesture is released, client refreshes track state

**Track reordered during gesture:**

The gesture continues correctly (GUID-based targeting still works). However, the visual slot may now show a different track's data. Next skeleton update will refresh the UI — the fader the user is touching will suddenly show the correct track. This is acceptable: reordering mid-gesture is rare, and the command went to the right track.

### FX and Sends

FX and sends have their own GUIDs — but for simplicity, we identify them by track GUID + index:

```json
{ "type": "fx/presetSet", "trackGuid": "{...}", "fxIdx": 0, "presetIdx": 5 }
{ "type": "send/setVolume", "trackGuid": "{...}", "sendIdx": 0, "volume": 0.5 }
```

If the track's FX chain or sends are reordered during a gesture, this can still apply to wrong FX/send. Acceptable tradeoff — FX/send reordering mid-gesture is extremely rare.

### Why No Version Tracking?

**Q: Why not include a structure version in the skeleton and validate it on writes?**

The GUID-based design makes version tracking redundant. Here's the real-world scenario:

**Typical session:** A musician is mixing on an iPad while sitting at their instrument. Maybe a collaborator is at the DAW making edits. They're not adversaries — they're working together, occasionally making light structural changes (add a track, rename something, reorder the drum bus).

**What GUID-based writes give us:**

1. **Reads are always fresh** — Skeleton broadcasts on change at 1-5Hz. The iPad sees structural changes within 200-1000ms. No version needed — arrival of new skeleton IS the signal.

2. **Writes target intent, not position** — When the iPad user drags a fader, the command says "set volume on GUID X" not "set volume on track 5." If someone at the DAW deletes track 3, the iPad's command still goes to the right track.

3. **Mid-gesture stability without locking** — User starts dragging a fader. We lock the GUID at gesture start. Even if a new skeleton arrives showing the track moved from slot 5 to slot 4, the gesture continues correctly. The UI might briefly show stale slot data until next skeleton refresh — acceptable for a rare edge case.

4. **Clean failure modes** — If the target track is deleted mid-gesture, server returns `TRACK_NOT_FOUND` with the GUID. Client can show haptic feedback, grey out the fader. No ambiguity about what went wrong.

**What version tracking would add:**

- Complexity (track version, include in payloads, validate on server)
- A failure mode we just eliminated ("stale version, please refresh")
- No benefit — the GUID lookup already tells us if the track exists

**Recommended: pause skeleton updates mid-gesture** — While the user is dragging a fader, defer applying incoming skeleton updates until gesture ends. This prevents the track row from visually shifting under their finger. The GUID-based commands continue working correctly regardless — if the track was deleted, the server returns `TRACK_NOT_FOUND` and the client handles it on gesture end.

---

## Tier Frequency Tuning

Tiers are configurable, not hardcoded:

| Tier | Default | Notes |
|------|---------|-------|
| HIGH | 30Hz | Transport, meters, subscribed tracks |
| MEDIUM | 5Hz | Items, markers, regions |
| LOW | 1Hz | Skeleton, tempo map |

**Tuning guidelines:**
- If 1Hz skeleton feels laggy on reorders, bump to 5Hz
- Use `total` canary for immediate structural change detection
- 65KB skeleton sent only on change — typical bandwidth near zero, worst case (rapid renames) ~65KB/sec

---

## Migration Path

### Phase 1: Add skeleton broadcast (non-breaking)
- Add `trackSkeleton` event at LOW tier
- Existing clients ignore unknown events
- New clients can use for search

### Phase 2: Add track subscriptions (opt-in)
- Add `track/subscribe` command handler
- Clients that subscribe get filtered `tracks` events
- Clients that don't subscribe get everything (backwards compatible)

### Phase 3: Require subscriptions
- After all clients updated, make subscription required
- Unsubscribed clients get no `tracks` events
- Skeleton always broadcast regardless

---

## Entity Roadmap

Priority order for viewport-driven implementation:

| Entity | Viewport Type | Status |
|--------|---------------|--------|
| Meters | Track indices | Done (POC) |
| Tracks | Track indices | Next |
| Items | Time range | Future |
| Markers/Regions | Time range | Future |
| FX/Sends | Expanded track state | Future |

Items and markers use time-range viewport instead of index-based:
```typescript
{ "type": "item/subscribe", "timeRange": { "start": 0.0, "end": 120.0 } }
```

---

## Key Insights from Research

### What Figma/Miro Do (and why we can't)
- Full-document sync: clients download complete files, filter locally
- Works because documents are small (< 10MB)
- Reamo can't do this: 1000+ tracks with waveforms/automation is too large

### What Game Engines Do (our inspiration)
- Interest management: only send entities within player's "area of interest"
- Distance-based update frequency tiers
- Adaptive frequency based on change rate
- This maps directly to our tiered polling + viewport subscriptions

### Mobile Safari Gotchas
- Momentum scroll doesn't fire events during inertial scrolling
- Need `requestAnimationFrame` polling during scroll
- Memory limit: 2-4GB regardless of device RAM
- Prune data outside 2× viewport aggressively

---

## Open Questions (Deferred)

1. **Payload compression** — Probably not needed if viewport-driven keeps payloads small. Revisit if bandwidth becomes issue.

2. **Binary formats** — Keep JSON for debuggability. MessagePack if we ever send waveform data.

3. **Cross-tier dependencies** — Playlist engine needs regions (MEDIUM) while running at HIGH tier. Current solution: cache regions between polls.

---

## References

- [meter_subscriptions.zig](extension/src/meter_subscriptions.zig) — POC implementation
- [useMeterSubscription.ts](frontend/src/hooks/useMeterSubscription.ts) — Frontend hook
- [TanStack Virtual](https://tanstack.com/virtual/latest) — Recommended virtualization library
- [Unreal Engine Network Relevancy](https://docs.unrealengine.com/en-US/InteractiveExperiences/Networking/Actors/Relevancy/) — Interest management patterns
