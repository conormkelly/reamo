# Peak Subscription System Design

## Implementation Status

| Phase | Description | Status |
|-------|-------------|--------|
| 1 | Frontend GUID-based selection | ✅ Complete |
| 2a | Backend subscription infrastructure | ✅ Complete |
| 2b | Backend peak generation & broadcasting | ⏳ Next |
| 3 | Backend caching with LRU | Pending |
| 4 | Frontend subscription hook | Pending |
| 5 | Cleanup old code | Pending |

**Current state:** Phase 2a complete. Backend has `peaks/subscribe` and `peaks/unsubscribe` commands wired up with per-client subscription state management. Next step is adding peak generation and broadcasting in the poll loop (Phase 2b).

---

## Overview

A per-client subscription system for mini-peaks (low-resolution waveform data) that enables timeline waveform display without per-item fetching or complex frontend cache management.

## Goals

1. **Eliminate per-item peak fetching** - No more N requests for N items
2. **Automatic invalidation** - Backend pushes updates when items change
3. **Per-client isolation** - Each client can subscribe to different tracks
4. **Efficient caching** - Avoid recalculating unchanged peaks
5. **Simple frontend** - No loading states, no cache keys, just render what arrives
6. **GUID-based identification** - Use stable GUIDs everywhere, indices only for rendering position

---

## GUID-First Philosophy

**Why GUIDs matter:**
- Indices change when items/tracks are reordered, deleted, or inserted
- GUIDs are stable across session, survive undo/redo, and work across clients
- Frontend selection should survive backend state changes

**GUID usage throughout the system:**

| Entity | GUID Field | Index Field | Use GUID for | Use Index for |
|--------|-----------|-------------|--------------|---------------|
| Track | `trackGuid` | `trackIdx` | Subscriptions, commands, selection | Rendering order |
| Item | `itemGuid` | `itemIdx` | Selection, peaks lookup | Rendering order |
| Take | `takeGuid` | `activeTakeIdx` | Cache keys, commands | Display "Take 2/3" |

**Frontend state changes:**
```typescript
// OLD (fragile)
selectedItemKey: "1:3"  // trackIdx:itemIdx - breaks on reorder

// NEW (stable)
selectedItemGuid: "abc-123-def"  // survives reorder, undo, etc.
```

---

## Protocol Design

### Subscribe Command

```typescript
// Frontend → Backend
{
  command: "peaks/subscribe",
  trackGuid: string,      // Track to get peaks for (use track GUID for stability)
  sampleCount: number,    // Peaks per item (default 30 for timeline blobs)
  id: string
}

// Backend → Frontend (immediate response)
{
  type: "response",       // Required wrapper (matches existing protocol)
  id: string,
  success: true,
  payload: {
    trackGuid: string,
    items: PeakItem[]
  }
}

interface PeakItem {
  itemGuid: string,       // Stable item identifier
  trackIdx: number,       // Current track index (for rendering position)
  itemIdx: number,        // Current item index
  position: number,       // Item position in seconds
  length: number,         // Item length in seconds
  // Peak format matches existing item/getPeaks response (items.zig:529-543):
  // Mono: [min, max][] - array of [min, max] tuples
  // Stereo: {l: [min, max], r: [min, max]}[] - array of L/R channel objects
  peaks: MonoPeak[] | StereoPeak[]
}

type MonoPeak = [number, number];  // [min, max]
interface StereoPeak {
  l: [number, number];  // [min, max]
  r: [number, number];  // [min, max]
}
```

### Unsubscribe Command

```typescript
// Frontend → Backend
{
  command: "peaks/unsubscribe",
  id: string
}

// Backend → Frontend
{
  type: "response",
  id: string,
  success: true
}
```

### Push Event (on item changes)

```typescript
// Backend → Frontend (broadcast to subscribed client)
{
  event: "peaks",
  payload: {
    trackGuid: string,
    items: PeakItem[]     // Full list for subscribed track
  }
}
```

---

## Backend Implementation

### Important: Codebase Alignment Notes

The pseudocode below uses simplified API names for readability. Actual implementation must use:

| Document Pseudocode | Actual Codebase API |
|---------------------|---------------------|
| `api.getTrackByGuid(guid)` | `g_ctx.guid_cache.resolve(guid)` via GuidCache |
| `api.trackItemCount(track)` | `api.countTrackMediaItems(track)` |
| `api.getItemByIdx(track, idx)` | `api.getTrackMediaItem(track, idx)` |
| `api.getTakeGuid(take)` | `api.getTakeGUID(take, &buf)` |
| `ArrayList.init(alloc)` | `var list: std.ArrayList(T) = .empty;` (Zig 0.15 unmanaged) |

### Data Structures

```zig
// Per-client subscription state (stored parallel to TrackSubscriptions pattern)
// See track_subscriptions.zig for similar pattern
const PeaksSubscription = struct {
    track_guid: [40]u8,
    sample_count: u32,
};

// Storage: Create peaks_subscriptions.zig similar to track_subscriptions.zig
// Maps client connection ID → PeaksSubscription
// NOT stored in ClientState directly (ws_server uses AutoArrayHashMap for clients)
var peaks_subscriptions: std.AutoArrayHashMap(usize, PeaksSubscription) = undefined;

// Global peaks cache (content-addressed)
const PeaksCacheKey = struct {
    take_guid: [40]u8,
    start_offset_ms: i32,   // Rounded to ms
    playrate_x1000: i32,    // 1.0 = 1000
    length_ms: i32,         // Rounded to ms
    sample_count: u16,
};

const CachedPeaks = struct {
    peaks: []f32,           // Interleaved min/max (or L/R for stereo)
    is_stereo: bool,
    last_used: i64,         // For LRU eviction
};

// Global cache with LRU eviction
var peaks_cache: std.AutoHashMap(PeaksCacheKey, CachedPeaks) = undefined;
const MAX_CACHE_ENTRIES = 2000;
```

### Command Handlers

```zig
// peaks/subscribe handler
pub fn handlePeaksSubscribe(client: *ClientState, cmd: CommandMessage, response: *ResponseWriter) void {
    const track_guid = cmd.getString("trackGuid") orelse {
        response.err("MISSING_PARAM", "trackGuid required");
        return;
    };
    const sample_count = cmd.getInt("sampleCount") orelse 30;

    // Update client's subscription (replaces any previous)
    client.peaks_subscription = .{
        .track_guid = parseGuid(track_guid),
        .sample_count = @intCast(sample_count),
    };

    // Generate and send initial peaks
    const peaks = generatePeaksForTrack(track_guid, sample_count);
    response.successJson(peaks);
}

// peaks/unsubscribe handler
pub fn handlePeaksUnsubscribe(client: *ClientState, cmd: CommandMessage, response: *ResponseWriter) void {
    client.peaks_subscription = null;
    response.success("{}");
}
```

### Peak Generation with Caching

```zig
// NOTE: Pseudocode - see "Codebase Alignment Notes" above for actual API names
fn generatePeaksForTrack(allocator: std.mem.Allocator, guid_cache: *GuidCache, track_guid: []const u8, sample_count: u32) PeaksPayload {
    // Use GuidCache to resolve track GUID (rebuilt at 1Hz)
    const track = guid_cache.resolve(track_guid) orelse return empty;
    const item_count = api.countTrackMediaItems(track);

    // Zig 0.15: ArrayList is unmanaged, pass allocator to each method
    var items: std.ArrayList(PeakItem) = .empty;
    defer items.deinit(allocator);

    for (0..item_count) |i| {
        const item = api.getTrackMediaItem(track, @intCast(i)) orelse continue;
        const take = api.getActiveTake(item) orelse continue;

        // Skip MIDI takes
        if (api.takeIsMidi(take)) continue;

        // Get take GUID into buffer
        var take_guid_buf: [40]u8 = undefined;
        api.getTakeGUID(take, &take_guid_buf);

        // Build cache key from content properties
        const key = PeaksCacheKey{
            .take_guid = take_guid_buf,
            .start_offset_ms = @intFromFloat(api.getTakeStartOffset(take) * 1000),
            .playrate_x1000 = @intFromFloat(api.getTakePlayrate(take) * 1000),
            .length_ms = @intFromFloat(api.getItemLength(item) * 1000),
            .sample_count = @intCast(sample_count),
        };

        // Check cache
        const peaks = if (peaks_cache.get(key)) |cached| blk: {
            cached.last_used = std.time.timestamp();
            break :blk cached.peaks;
        } else blk: {
            // Generate peaks using AudioAccessor (reuse logic from items.zig handleGetPeaks)
            const new_peaks = generatePeaksFromSource(allocator, take, item, sample_count);

            // Cache with LRU eviction if needed
            if (peaks_cache.count() >= MAX_CACHE_ENTRIES) {
                evictOldestEntry(allocator);
            }
            peaks_cache.put(allocator, key, .{
                .peaks = new_peaks,
                .is_stereo = isStereo(take),
                .last_used = std.time.timestamp(),
            });

            break :blk new_peaks;
        };

        // Get item GUID
        var item_guid_buf: [40]u8 = undefined;
        api.getItemGUID(item, &item_guid_buf);

        items.append(allocator, .{
            .item_guid = item_guid_buf,
            .track_idx = api.getTrackIdx(track),
            .item_idx = @intCast(i),
            .position = api.getItemPosition(item),
            .length = api.getItemLength(item),
            .peaks = peaks,
        }) catch continue;
    }

    return .{ .track_guid = track_guid, .items = items.toOwnedSlice(allocator) };
}
```

### Broadcasting Updates

In the main broadcast loop (5Hz tick), check if items changed and push to subscribed clients:

```zig
// In broadcast tick
fn broadcastPeaksIfNeeded(clients: []ClientState) void {
    // Track which track GUIDs have subscribed clients
    var subscribed_tracks = std.StringHashMap(void).init(allocator);
    defer subscribed_tracks.deinit();

    for (clients) |client| {
        if (client.peaks_subscription) |sub| {
            subscribed_tracks.put(&sub.track_guid, {});
        }
    }

    // For each subscribed track, check if items changed
    var iter = subscribed_tracks.iterator();
    while (iter.next()) |entry| {
        const track_guid = entry.key_ptr.*;

        if (itemsChangedForTrack(track_guid)) {
            // Generate fresh peaks (using cache for unchanged items)
            const peaks = generatePeaksForTrack(track_guid, 30);

            // Send to all clients subscribed to this track
            for (clients) |client| {
                if (client.peaks_subscription) |sub| {
                    if (std.mem.eql(u8, &sub.track_guid, track_guid)) {
                        client.sendEvent("peaks", peaks);
                    }
                }
            }
        }
    }
}
```

### Detecting Item Changes

Track a hash of item properties that affect peaks:

```zig
// Per-track change detection
var track_items_hash: std.StringHashMap(u64) = undefined;

fn itemsChangedForTrack(track_guid: []const u8) bool {
    const current_hash = computeTrackItemsHash(track_guid);
    const prev_hash = track_items_hash.get(track_guid);

    if (prev_hash == null or prev_hash.? != current_hash) {
        track_items_hash.put(track_guid, current_hash);
        return true;
    }
    return false;
}

fn computeTrackItemsHash(track_guid: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);

    const track = api.getTrackByGuid(track_guid) orelse return 0;
    const item_count = api.trackItemCount(track);

    for (0..item_count) |i| {
        const item = api.getItemByIdx(track, @intCast(i)) orelse continue;
        const take = api.getActiveTake(item) orelse continue;

        // Hash properties that affect peaks
        hasher.update(api.getTakeGuid(take));
        hasher.update(std.mem.asBytes(&api.getTakeStartOffset(take)));
        hasher.update(std.mem.asBytes(&api.getTakePlayrate(take)));
        hasher.update(std.mem.asBytes(&api.getItemLength(item)));
        hasher.update(std.mem.asBytes(&api.getActiveTakeIdx(item)));
    }

    return hasher.final();
}
```

---

## Frontend Implementation

### Store Slice

```typescript
// frontend/src/store/slices/peaksSlice.ts

export interface TrackPeaks {
  trackGuid: string;
  items: Map<string, PeakItem>;  // itemGuid → peaks
}

export interface PeakItem {
  itemGuid: string;
  trackIdx: number;
  itemIdx: number;
  position: number;
  length: number;
  // Matches existing format from item/getPeaks (WebSocketTypes.ts)
  peaks: MonoPeak[] | StereoPeak[];
}

// Reuse existing types from WebSocketTypes.ts
type MonoPeak = [number, number];  // [min, max]
interface StereoPeak {
  l: [number, number];
  r: [number, number];
}

export interface PeaksSlice {
  // State
  subscribedTrackGuid: string | null;
  trackPeaks: TrackPeaks | null;

  // Actions
  subscribeToPeaks: (trackGuid: string) => void;
  unsubscribeFromPeaks: () => void;
  setTrackPeaks: (peaks: TrackPeaks) => void;
}
```

### Hook

```typescript
// frontend/src/hooks/usePeaksSubscription.ts

export function usePeaksSubscription(trackGuid: string | null) {
  const { sendAsync, connected } = useReaper();
  const setTrackPeaks = useReaperStore(s => s.setTrackPeaks);
  const trackPeaks = useReaperStore(s => s.trackPeaks);
  const subscribedGuid = useRef<string | null>(null);

  useEffect(() => {
    if (!connected) return;

    // Unsubscribe from previous if different
    if (subscribedGuid.current && subscribedGuid.current !== trackGuid) {
      sendAsync('peaks/unsubscribe', {});
      subscribedGuid.current = null;
    }

    // Subscribe to new track
    if (trackGuid && trackGuid !== subscribedGuid.current) {
      sendAsync('peaks/subscribe', { trackGuid, sampleCount: 30 })
        .then((response) => {
          if (response.success) {
            setTrackPeaks(response.payload);
          }
        });
      subscribedGuid.current = trackGuid;
    }

    return () => {
      if (subscribedGuid.current) {
        sendAsync('peaks/unsubscribe', {});
        subscribedGuid.current = null;
      }
    };
  }, [trackGuid, connected, sendAsync, setTrackPeaks]);

  return trackPeaks;
}
```

### Event Handler

```typescript
// In store message handler
} else if (isPeaksEvent(message)) {
  const p = message.payload as PeaksEventPayload;
  // Only update if we're still subscribed to this track
  if (get().subscribedTrackGuid === p.trackGuid) {
    get().setTrackPeaks({
      trackGuid: p.trackGuid,
      items: new Map(p.items.map(i => [i.itemGuid, i])),
    });
  }
}
```

### Timeline Component Integration

```typescript
// TimelineWaveformOverlay.tsx (simplified)

export function TimelineWaveformOverlay({ coloredTrackGuid, ... }) {
  // Subscribe to peaks for the colored track
  const trackPeaks = usePeaksSubscription(coloredTrackGuid);

  // No loading state needed - if peaks exist, render them
  if (!trackPeaks || trackPeaks.trackGuid !== coloredTrackGuid) {
    return null;
  }

  return (
    <div className="absolute inset-0">
      {Array.from(trackPeaks.items.values()).map(item => (
        <WaveformBlob
          key={item.itemGuid}
          peaks={item.peaks}
          position={item.position}
          length={item.length}
          // ... rendering props
        />
      ))}
    </div>
  );
}
```

---

## Cache Invalidation Strategy

### Content-Addressed Keys

Cache keys are based on **what affects the audio**, not identity:

```
Key = hash(takeGuid + startOffset + playrate + length + sampleCount)
```

This means:
- Item moves → same cache hit (position doesn't affect peaks)
- Item resized → cache miss → regenerate
- Take switched → cache miss → regenerate
- Playrate changed → cache miss → regenerate

### Automatic Cleanup

No explicit invalidation needed:
- Unused entries age out via LRU
- Deleted items simply stop being looked up
- Track change → client unsubscribes → no more lookups

### Memory Budget

- 30 samples × 4 floats × 4 bytes = 480 bytes per item
- 2000 cache entries = ~1MB max
- Very reasonable for a desktop plugin

---

## Multi-Client Scenarios

### Different Tracks

```
Client A: subscribes to "track-guid-drums"
Client B: subscribes to "track-guid-vocals"

Backend maintains:
  client_a.peaks_subscription = { track_guid: "drums", sample_count: 30 }
  client_b.peaks_subscription = { track_guid: "vocals", sample_count: 30 }

On drums item change:
  → Only Client A receives peaks event

On vocals item change:
  → Only Client B receives peaks event
```

### Same Track

```
Client A: subscribes to "track-guid-drums"
Client B: subscribes to "track-guid-drums"

On drums item change:
  → Both clients receive peaks event
  → Peaks generated once, sent to both
```

### Client Disconnect

```
Client A disconnects

→ client_a.peaks_subscription cleared during cleanup
→ If no other clients subscribed to that track, no more peaks generated for it
```

---

## Migration Path

### Phase 1: Migrate frontend to GUID-based selection ✅ COMPLETE

**Goal:** Make frontend selection stable before adding peaks subscription.

**Status:** Completed on 2025-01-14

**Changes made:**

| File | Change |
|------|--------|
| `itemsSlice.ts` | `selectedItemKey` → `selectedItemGuid`, `selectItem(trackIdx, itemIdx)` → `selectItem(guid)`, removed `makeItemKey()`/`parseItemKey()` |
| `ItemDensityBlobs.tsx` | Prop renamed to `selectedItemGuid`, selection comparison uses GUID |
| `Timeline.tsx` | Uses `item.guid` for selection, removed `parseItemKey` import |
| `NavigateItemInfoBar.tsx` | All lookups and nav use GUID, added REAPER sync on track change |
| `ItemsTimeline.tsx` | Selection and click handlers use GUID, React keys use GUID |
| `TimelineSection.tsx` | Uses `selectedItemGuid` |
| `useBatchPeaksFetch.ts` | Cache key format: `${item.guid}:${item.length.toFixed(3)}:${item.activeTakeIdx}` |
| `TimelineWaveformOverlay.tsx` | Key format synced with hook |
| `store/index.ts` | Removed `makeItemKey`/`parseItemKey` exports |

**Benefits achieved:**
- Selection survives item reordering, undo/redo, session reload
- Simpler code without index-based key parsing
- Cache keys use stable GUIDs

**Tests:** 742/742 passing

### Phase 2a: Add peaks subscription infrastructure (backend) ✅ COMPLETE

**Status:** Completed on 2026-01-14

**Files created:**

| File | Description |
|------|-------------|
| `extension/src/peaks_subscriptions.zig` | Per-client subscription state, similar pattern to `track_subscriptions.zig` |
| `extension/src/commands/peaks_subs.zig` | Command handlers for `peaks/subscribe` and `peaks/unsubscribe` |

**Files modified:**

| File | Change |
|------|--------|
| `extension/src/commands/registry.zig` | Added `peaks/subscribe`, `peaks/unsubscribe` commands |
| `extension/src/commands/mod.zig` | Added `peaks_subs` to `CommandContext`, imported `peaks_subscriptions` |
| `extension/src/main.zig` | Initialize `g_peaks_subs`, cleanup on client disconnect |

**Protocol implemented:**
- `peaks/subscribe` accepts `trackGuid` (required) and `sampleCount` (optional, default 30)
- `peaks/unsubscribe` clears client subscription
- Client disconnect automatically cleans up subscription

**Tests:** Zig build + tests pass, frontend 742/742 passing

### Phase 2b: Add peak generation & broadcasting ⏳ NEXT

1. Implement `generatePeaksForTrack()` (reuse existing AudioAccessor code from `item/getPeaks`)
2. Add `peaks` event type to protocol
3. Add broadcasting in tick loop (check subscribed tracks, push if changed)
4. Handle `force_broadcast` flag for immediate data on subscribe

### Phase 3: Add backend caching

1. Implement content-addressed `PeaksCacheKey` struct
2. Create global `peaks_cache` HashMap with LRU eviction
3. Add change detection via `computeTrackItemsHash()`
4. Only regenerate peaks for items whose content changed

### Phase 4: Frontend integration

1. Add `PeaksSlice` to store
2. Create `usePeaksSubscription` hook
3. Update `TimelineWaveformOverlay` to:
   - Accept `coloredTrackGuid` prop (derived from `selectedItemGuid`)
   - Use `usePeaksSubscription(coloredTrackGuid)`
   - Render from subscription data, no loading states
4. Remove `useBatchPeaksFetch` hook (deprecated)

### Phase 5: Cleanup

1. Remove frontend `PeaksCache.ts` (no longer needed)
2. Deprecate or remove `item/getPeaks` (or keep for ItemsTimeline detail view)
3. Update API documentation
4. Remove old selection helpers (`makeItemKey`, `parseItemKey`)

---

## Testing Checklist

- [ ] Subscribe to track A, receive peaks for all items
- [ ] Resize item on track A, receive updated peaks
- [ ] Switch take on item, receive updated peaks
- [ ] Delete item, next peaks event excludes it
- [ ] Add item to track, next peaks event includes it
- [ ] Switch to track B, receive peaks for track B
- [ ] Disconnect client, subscription cleaned up
- [ ] Multiple clients subscribe to same track
- [ ] Multiple clients subscribe to different tracks
- [ ] Cache hit on unchanged items (verify via logging)
- [ ] LRU eviction when cache full

---

## Open Questions

1. **Broadcast rate**: Should peaks push be 5Hz (with items) or lower (2Hz)?
   - Lower rate is fine since peaks change infrequently
   - Could piggyback on items event for simplicity

2. **Initial subscribe latency**: If track has 100 items, first subscribe may take 100-200ms
   - Acceptable for one-time cost
   - Could show brief loading indicator if needed

3. **Stereo vs mono encoding**: How to represent in JSON?
   - Option A: `[[min,max], ...]` for mono, `[[lMin,lMax,rMin,rMax], ...]` for stereo
   - Option B: Separate `peaksL` and `peaksR` arrays for stereo
   - Option A is more compact, Option B is clearer

4. **Keep `item/getPeaks`?**: Still useful for ItemsTimeline detail view
   - Yes, keep it for high-resolution on-demand fetching
   - Subscription is for low-res timeline blobs only
