# Timeline Waveform Rendering Strategy

## Problem Statement

The current waveform rendering system (`TimelineWaveformOverlay`) was designed for single-track mode:
- Subscribes to **one track** at a time
- Renders all items at a **fixed Y position** (25% height, centered)
- Clears all peaks data when switching tracks

With multi-track lanes (Phase 2), waveforms render in the wrong position because:
1. All items assume the same vertical center
2. Only one track can be subscribed at a time
3. No per-lane Y offset calculation

**Goal:** Render waveforms for multiple visible tracks simultaneously, each in its correct lane.

---

## Current Architecture

### Backend (Zig Extension)

```
PeaksSubscriptions      Per-client subscription state (one track)
       ↓
PeaksGenerator          Generates peaks for subscribed track's items
       ↓
PeaksCache              LRU cache, content-addressed by take properties
       ↓
WebSocket Event         peaks { trackGuid, items[] }
```

**Key characteristics:**
- Single track per client subscription
- Peaks generated per-item using AudioAccessor
- 30 samples per item by default

**Cache key structure** (from `peaks_cache.zig`):
```zig
pub const PeaksCacheKey = struct {
    take_guid: [40]u8,        // Take GUID (identifies audio source)
    take_guid_len: u8,
    start_offset_ms: i32,     // offset × 1000 (milliseconds)
    playrate_x1000: i32,      // playrate × 1000 (1.0 = 1000)
    length_ms: i32,           // length × 1000 (milliseconds)
    sample_count: u16,        // Number of peak samples
};
```

**Why this matters:** Cache is content-addressed by *take* properties, not track. The same take used on multiple tracks shares cached peaks. This remains efficient for multi-track subscriptions.

### Frontend (React)

```
usePeaksSubscription(trackGuid)
       ↓
peaksSlice.peaksData: Map<itemGuid, WSItemPeaks>
       ↓
TimelineWaveformOverlay
       ↓
Canvas per visible item (fixed Y position)
```

**Key limitation:** `subscribedTrackGuid` is singular, `peaksData` is cleared on change.

### Index System Reference

**Critical:** The codebase uses multiple index systems that must be carefully distinguished:

| System | Base | Example | Used In |
|--------|------|---------|---------|
| `skeleton[]` | 0-based | `skeleton[0]` = master, `skeleton[1]` = first user track | Frontend track lookup |
| `trackIndices[]` | 1-based | `[1, 2, 3, 4]` for first bank | Bank navigation, subscription ranges |
| `WSItem.trackIdx` | 1-based | `trackIdx: 1` = first user track | Item positioning, filtering |
| Range subscription | 1-based | `range: { start: 1, end: 8 }` | Backend track subscriptions |

**Correct mapping in frontend:**
```typescript
// trackIndices from bank navigation (1-based)
const displayTrackIndices = [1, 2, 3, 4];

// Lookup in skeleton (0-based array, but values align)
const track = skeleton[displayTrackIndices[laneIdx]];
// skeleton[1] = first user track, displayTrackIndices[0] = 1 → correct

// Lane assignment for items
const laneIdx = multiTrackIndices.indexOf(item.trackIdx);
```

**Common mistake:** Using 0-based indices for subscription ranges will include master track unexpectedly.

---

## Design Options

### Option A: Multiple Single-Track Subscriptions

Expand current model to support N simultaneous track subscriptions.

**Backend changes:**
- `PeaksSubscriptions` holds `Set<trackGuid>` instead of single `trackGuid`
- Generate peaks for all subscribed tracks each cycle
- Send separate event per track OR combined event

**Frontend changes:**
- `peaksSlice.subscribedTrackGuids: Set<string>`
- `peaksData: Map<trackGuid, Map<itemGuid, WSItemPeaks>>`
- Subscribe to visible bank tracks + prefetch

**Pros:**
- Minimal protocol change
- Reuses existing per-track generation
- Cache still effective

**Cons:**
- Many subscriptions = many events
- Need to manage add/remove subscriptions carefully

### Option B: Range-Based Subscription (like Tracks)

Subscribe to track index range, similar to `track.subscribe`.

**Command:**
```typescript
peaks.subscribe({
  range: { start: 1, end: 8 },  // Track indices
  sampleCount: 30
})
```

**Backend changes:**
- New subscription mode: range [start, end]
- Generate peaks for all tracks in range
- Combined event with all tracks' peaks

**Frontend changes:**
- Subscribe based on bank navigation (same pattern as mixer)
- Prefetch adjacent banks

**Pros:**
- Familiar pattern (mirrors track subscription)
- Efficient for sequential bank navigation
- Single command for range

**Cons:**
- Doesn't work well for filtered/custom banks (non-contiguous)
- Need GUID mode as fallback

### Option C: Hybrid Range + GUID Mode (Recommended)

Support both range mode (for sequential banks) and GUID mode (for filtered views).

**Command:**
```typescript
// Range mode - for "All Tracks" sequential navigation
peaks.subscribe({ range: { start: 1, end: 8 }, sampleCount: 30 })

// GUID mode - for custom banks / filtered views
peaks.subscribe({ guids: ['guid1', 'guid2', ...], sampleCount: 30 })
```

**Event (combined for all subscribed tracks):**
```typescript
{
  type: 'event',
  event: 'peaks',
  payload: {
    tracks: {
      [trackGuid: string]: WSItemPeaks[]
    }
  }
}
```

**Pros:**
- Handles both use cases efficiently
- Single event with all peaks (GUID-keyed map)
- Matches existing track subscription pattern exactly

**Cons:**
- More complex subscription logic
- Backend tracks both modes

---

## Recommended Approach: Option C (Hybrid)

This mirrors the proven `track.subscribe` pattern and handles both sequential and filtered scenarios.

### Event Payload Structure

```typescript
interface PeaksEventPayload {
  tracks: Record<string, WSItemPeaks[]>;  // trackGuid → items
}
```

This allows O(1) lookup by track GUID, similar to meters.

### Frontend State

```typescript
interface PeaksState {
  // Subscription state
  subscriptionMode: 'range' | 'guids' | null;
  subscribedRange: { start: number; end: number } | null;
  subscribedGuids: string[] | null;

  // Data - keyed by track GUID for efficient lookup
  peaksByTrack: Map<string, Map<string, WSItemPeaks>>;  // trackGuid → itemGuid → peaks
}
```

### Hook Interface

```typescript
// For multi-track timeline
const peaksByTrack = usePeaksSubscription({
  mode: 'range',
  range: { start: bank.prefetchStart, end: bank.prefetchEnd },
  sampleCount: 30,
});

// OR for filtered view
const peaksByTrack = usePeaksSubscription({
  mode: 'guids',
  guids: filteredTrackGuids,
  sampleCount: 30,
});

// Returns: Map<trackGuid, Map<itemGuid, WSItemPeaks>>
```

---

## Frontend Waveform Positioning

**Critical:** Waveform Y positions must exactly match `MultiTrackLanes.tsx` item positioning.

### Lane Geometry (from MultiTrackLanes.tsx)

```typescript
// Constants
const LANE_COUNT = 4;                              // Typical: 4 tracks per bank
const TIMELINE_HEIGHT = 200;                       // Container height in px
const ITEM_HEIGHT_PERCENT = 0.6;                   // 60% of lane height

// Calculated values
const laneHeight = TIMELINE_HEIGHT / LANE_COUNT;  // e.g., 200/4 = 50px
const itemTopPercent = (1 - ITEM_HEIGHT_PERCENT) / 2; // (1 - 0.6) / 2 = 0.2 (20%)
const itemHeight = laneHeight * ITEM_HEIGHT_PERCENT;  // 50 * 0.6 = 30px
```

### Per-Waveform Positioning

```typescript
// For an item on lane N (0-indexed):
function getWaveformPosition(laneIdx: number, containerHeight: number, laneCount: number) {
  const laneHeight = containerHeight / laneCount;
  const itemHeightPercent = 0.6;
  const itemTopPercent = (1 - itemHeightPercent) / 2;

  return {
    top: laneIdx * laneHeight + (laneHeight * itemTopPercent),
    height: laneHeight * itemHeightPercent,
  };
}

// Example: Lane 2 in 4-lane, 200px container
// top = 2 * 50 + (50 * 0.2) = 100 + 10 = 110px
// height = 50 * 0.6 = 30px
```

### CSS Percentage Equivalent

```css
/* For lane N in a 4-lane layout */
.waveform-lane-N {
  /* Lane 0: top: 5%, Lane 1: top: 30%, Lane 2: top: 55%, Lane 3: top: 80% */
  top: calc((N * 25%) + 5%);
  height: 15%;  /* 60% of 25% lane = 15% */
}
```

### Comparison: Single-Track vs Multi-Track

| Mode | Item Height | Item Top | Container |
|------|-------------|----------|-----------|
| Single-track (old) | 25% of container | Centered (37.5%) | 120px |
| Multi-track lanes | 60% of lane (15% of container) | 20% into lane | 200px |

---

## Implementation Phases

### Phase 1: Backend - Multi-Track Subscription

**Files to modify:**
- `extension/src/peaks_subscriptions.zig`
- `extension/src/commands/peaks_subs.zig`
- `extension/src/peaks_generator.zig`

**Changes:**
1. Expand subscription state to hold range OR guids
2. Add `peaks/subscribe` command variants
3. Generate peaks for all subscribed tracks
4. Change event format to track-keyed map

**New subscription state** (pattern from `track_subscriptions.zig`):

```zig
/// Subscription mode (mutually exclusive).
pub const SubscriptionMode = enum {
    none,   // No subscription
    range,  // Subscribe to unified indices [start, end]
    guids,  // Subscribe to specific GUIDs
};

/// Per-client subscription state.
pub const ClientSubscription = struct {
    mode: SubscriptionMode = .none,

    // Range mode fields
    range_start: c_int = 0,
    range_end: c_int = 0,

    // GUID mode fields (stored GUIDs)
    guids: [MAX_GUIDS_PER_CLIENT][40]u8 = undefined,
    guid_lens: [MAX_GUIDS_PER_CLIENT]usize = [_]usize{0} ** MAX_GUIDS_PER_CLIENT,
    guid_count: usize = 0,

    // Common fields
    sample_count: u16 = 30,

    /// Clear subscription state.
    pub fn clear(self: *ClientSubscription) void {
        self.mode = .none;
        self.range_start = 0;
        self.range_end = 0;
        self.guid_count = 0;
    }

    /// Get stored GUID at index.
    pub fn getGuid(self: *const ClientSubscription, idx: usize) ?[]const u8 {
        if (idx >= self.guid_count) return null;
        return self.guids[idx][0..self.guid_lens[idx]];
    }
};
```

**Key constants** (from `constants.zig`):
- `MAX_GUIDS_PER_CLIENT = 32` — Max tracks per GUID subscription
- `MAX_SUBSCRIPTION_CLIENTS = 16` — Max concurrent clients

### Phase 2: Backend - Event Format Change

**Current event:**
```json
{
  "event": "peaks",
  "payload": {
    "trackGuid": "...",
    "items": [...]
  }
}
```

**New event:**
```json
{
  "event": "peaks",
  "payload": {
    "tracks": {
      "trackGuid1": [...items...],
      "trackGuid2": [...items...],
    }
  }
}
```

### Phase 3: Frontend - State Restructure

**Files to modify:**
- `frontend/src/store/slices/peaksSlice.ts`
- `frontend/src/hooks/usePeaksSubscription.ts`
- `frontend/src/core/WebSocketTypes.ts`
- `frontend/src/core/WebSocketCommands.ts`

**Changes:**
1. Update `PeaksEventPayload` type
2. Change `peaksData` to `peaksByTrack` (nested Map)
3. Update subscription commands
4. Handle both range and GUID modes

### Phase 4: Frontend - Multi-Track Waveform Rendering

**Files to modify:**
- `frontend/src/components/Timeline/TimelineWaveformOverlay.tsx` (or new component)
- `frontend/src/components/Timeline/MultiTrackLanes.tsx`

**Changes:**
1. Create `MultiTrackWaveformOverlay` or integrate into `MultiTrackLanes`
2. Accept `peaksByTrack` map
3. Render per-lane waveforms with correct Y offset
4. Calculate lane height, item strip height (60% of lane)

### Phase 5: Integration with TimelineView

**Changes:**
1. Subscribe to peaks based on `displayTrackIndices` or `laneTracks`
2. Handle filtered vs unfiltered subscription modes
3. Prefetch adjacent banks (same pattern as track data)
4. Pass peaks data to waveform overlay component

---

## Performance Considerations

### Cache Efficiency

The existing `PeaksCache` should remain effective:
- Content-addressed by take properties (not track)
- Same take used by multiple items benefits from cache
- Track changes detected via hash comparison

### Subscription Throttling

Consider:
- Debounce subscription changes (similar to track subscription)
- Grace period for tracks leaving viewport
- Limit max simultaneous tracks (e.g., 16)

### Event Size

With many tracks, peaks events can be substantial. **Corrected calculation:**

```
Per item (stereo, 30 samples):
- JSON structure overhead: ~150 bytes (guid, position, length, channels, brackets)
- Peak data: 30 samples × 2 channels × 2 values (min/max) × ~8 chars = ~960 bytes
- Total per item: ~1,100 bytes

Full event (4 tracks × 20 items = 80 items):
- 80 items × 1,100 bytes = ~88 KB
- Plus event wrapper and track keys: ~90-95 KB total
```

**Implications:**
- This is ~10× larger than initially estimated
- Still acceptable for infrequent updates (peaks change rarely)
- Consider: Only send changed tracks (delta updates) for optimization
- Or: Accept full updates since peaks change infrequently
- With prefetch (8 visible + 16 prefetch = 24 tracks), worst case: ~500 KB

### Generation Load

Generating peaks for many tracks simultaneously:
- Spread across poll cycles if needed
- Prioritize visible tracks over prefetch
- Cache makes regeneration rare after initial load

### Change Detection Strategy

**Current approach** (single-track): `PeaksCache.trackChanged()` computes a hash of all items on the track and compares to stored hash.

**Multi-track approach:** Track hash per subscribed track, check all on each poll cycle.

```zig
// In poll loop (conceptual):
fn pollPeaksForClient(client_id: usize, sub: *ClientSubscription) void {
    var changed_tracks: [MAX_GUIDS_PER_CLIENT][]const u8 = undefined;
    var changed_count: usize = 0;

    // Check each subscribed track
    const track_guids = sub.getSubscribedTrackGuids();
    for (track_guids) |guid| {
        if (peaks_cache.trackChanged(guid, api, track_ptr)) {
            changed_tracks[changed_count] = guid;
            changed_count += 1;
        }
    }

    // Only regenerate and send changed tracks
    if (changed_count > 0 or sub.force_broadcast) {
        generateAndBroadcast(client_id, changed_tracks[0..changed_count]);
    }
}
```

**Optimization:** Only include changed tracks in event (delta updates), not full state.

### Error Handling

**AudioAccessor failures:**
- Individual item fails → skip item, continue with others
- Track not found (deleted) → exclude from response, no error to client
- Memory allocation failure → return error response to client

**Partial success:** Valid data is returned for items that succeeded. Missing items are simply absent from the response—frontend renders solid-colored blocks for items without peaks data.

**No `errors` field needed:** Omission is sufficient signal. Frontend doesn't need to distinguish "no audio" from "accessor failed."

---

## Viewport-Aware Peaks (Future Enhancement)

Currently: Subscribe to tracks, get peaks for ALL items on those tracks.

Future option: Subscribe with viewport time range, only get peaks for visible items.

```typescript
peaks.subscribe({
  range: { start: 1, end: 8 },
  viewport: { start: 0, end: 30 },  // Only items in this time range
  sampleCount: 30,
})
```

**Tradeoff:**
- Pros: Less data for long projects with many items
- Cons: More subscription updates on pan/scroll, cache less effective

**Recommendation:** Start without viewport awareness. Add later if needed.

---

## API Summary

### New Commands

```typescript
// Subscribe to peaks for track range
peaks.subscribe({
  range: { start: number, end: number },
  sampleCount?: number  // default 30
})

// Subscribe to peaks for specific tracks
peaks.subscribe({
  guids: string[],
  sampleCount?: number
})

// Unsubscribe
peaks.unsubscribe()
```

### New Event Format

```typescript
interface PeaksEventPayload {
  tracks: Record<string, WSItemPeaks[]>;
}
```

### Frontend Hook

```typescript
function usePeaksSubscription(options: {
  mode: 'range' | 'guids';
  range?: { start: number; end: number };
  guids?: string[];
  sampleCount?: number;
}): Map<string, Map<string, WSItemPeaks>>;
```

---

## Open Questions

1. **Max tracks to subscribe?**
   - Timeline shows 4-8 lanes, prefetch adds 4-16 more
   - Total: ~24 tracks max seems reasonable
   - Backend limit: Make configurable, start with 24

After checking on ipad I'd say 4 tracks is right for phone, maybe 6 for ipad.
So adjust prefetch accordingly. It doesn't matter if there's a very slight delay anyway, like the meters its just nice to have some prefetching to avoid loading pop-in.

2. **Separate peaks events per track OR combined?**
   - Combined (recommended): Single event, all tracks, GUID-keyed
   - Matches meters pattern, simpler state management

Single event all tracks, GUID keyed.

3. **Waveform in MultiTrackLanes OR separate overlay?**
   - Option A: Integrate into MultiTrackLanes (waveform per lane div)
   - Option B: Separate MultiTrackWaveformOverlay (canvas per item)
   - Recommendation: Start with Option A, simpler positioning

Whatever involves less rework.

4. **Backward compatibility?**
   - Old single-track subscription should still work
   - Or: Deprecate and update all usages

Keep it for now but document that we will deprecate it once done the plan.

5. **Delta updates?**
   - Full state on each event (simpler, current approach)
   - Or: Only send changed tracks (optimization if needed)

Full state for now, lets make it right then delta updates can be a v2 optimization.

6. **Master track (idx 0) in peaks subscriptions?**
   - Option A: Range starts at 1 (exclude master by convention)
   - Option B: Allow 0 for master, document clearly
   - Master rarely has audio items, so less critical

According to a web research claude:

```
Yes, it's possible in Reaper, though it's not enabled by default.
To show the master track in the arrange view:

Go to Options → Show master track in arrange (or right-click in the track panel area and select it)

Once the master track is visible in the arrange view, you can drag audio items onto it just like any other track. The audio will be added to the final output along with everything else routed to the master.
That said, it's generally not a common workflow—most people use regular tracks and route them to the master for final processing (limiting, EQ, etc.). But if you have a specific reason to put audio directly on the master (like a reference track or a final mix bounce you want to compare against), Reaper gives you that flexibility.
```

So, we should fetch this option and include master in the track lanes IF this options is enabled. So we'll need to do further research on this one. Obviously not a critical immediate priority but we dont want to lock ourselves in design wise.

7. **Grace period for peaks subscriptions?**
   - Track subscriptions have 500ms grace period to prevent thrashing
   - Pro: Smooth bank navigation without constant re-subscribing
   - Con: Briefly stale waveforms visible after bank change
   - Recommendation: Yes, match track subscription behavior

Match track sub behaviour. We dont need to show stale waveforms. Remember, we'll get fresh state on any changes. So, like... draw whatever waveforms we have on the takes that we can see etc.


8. **Canvas architecture for multi-track waveforms?**
   - Single canvas for all lanes: One render pass, complex coordinate math
   - Per-lane canvas: Matches MultiTrackLanes structure, easier clipping
   - Per-item canvas: Current approach, most flexible, more DOM elements
   - Recommendation: Per-item canvas (current) for simplicity

We might need to do a research query into best practice for this later. For now lets keep it per-item canvas for simplicity.

9. **Stereo display in cramped lanes?**
   - Combined (mono-style): Saves vertical space, lanes are tight at ~50px
   - Dual channel: Full stereo information visible
   - Recommendation: Combined for multi-track, dual for single-track focus

I'll go with the recommendation.

10. **Adaptive sample count based on zoom level?**
    - Zoomed out: fewer samples needed (items small on screen)
    - Zoomed in: more samples for detail
    - Cost: subscription update on zoom change, more cache entries
    - Recommendation: Fixed 30 samples initially, evaluate later

Lets keep it at 30 samples initially yea and eval later.

11. **Focused track priority (higher-res waveforms)?**
    - Could request 60 samples for focused track, 20 for others
    - Adds complexity to subscription management
    - Recommendation: Uniform sample count, simplifies caching

Uniform for now.

12. **Frontend memory budget for peaks cache?**
    - Current: Clear all peaks on track change (single-track mode)
    - Multi-track: Cache multiple banks for smooth scrolling?
    - Risk: Memory growth in hour-long sessions
    - Recommendation: LRU cache with ~100 track limit (matches backend)

LRU cache.

13. **Loading state indication for waveforms?**
    - Skeleton/shimmer on items without peaks data?
    - Progress indicator per track?
    - Silent (just shows colored blocks until data arrives)?
    - Recommendation: Silent—colored blocks are sufficient placeholder

Silent, we can optimize later if laggy.

14. **Partial data arrival handling?**
    - Render what we have, others show solid color
    - Wait for all subscribed tracks before first render?
    - Recommendation: Render incrementally, don't block on full data

Render incrementally.

15. **Backward compatibility migration plan?**
    - Phase 1: Add new multi-track endpoint, keep single-track working
    - Phase 2: Frontend migrates to new endpoint
    - Phase 3: Deprecate single-track (or keep for simple single-track views)
    - Recommendation: Keep single-track for backward compat, new endpoint for multi-track

We are pre-release so it doesnt matter too much, just need to note it as being unused for now, we may end up using it later. if we dont, at least we know and can deprecate or delete the functionality.

---

## Implementation Status

### Completed (Backend - Phases 1 & 2)

- [x] **peaks_subscriptions.zig**: Multi-track subscription with range/GUID modes
  - `SubscriptionMode` enum (none, range, guids)
  - `ClientSubscription` struct with range_start/end and guids array
  - `subscribeRange()` and `subscribeGuids()` methods
  - `getSubscribedIndices()` for resolving to track indices
  - Grace period support matching track subscriptions
- [x] **peaks_subs.zig**: Command handlers updated for range/GUID modes
- [x] **peaks_generator.zig**: New `generatePeaksForSubscription()` function
  - Resolves subscription to track indices
  - Generates peaks for all tracks in subscription
  - `serializeMultiTrackPeaksEvent()` for track-keyed map format
- [x] **main.zig**: Polling loop updated for multi-track model

### Completed (Frontend - Phases 3-5)

- [x] **peaksSlice.ts**: Updated state structure
  - `peaksByTrack: Map<trackIdx, Map<itemGuid, WSItemPeaks>>`
  - `handlePeaksEvent()` for track-keyed map format
  - `setPeaksSubscriptionRange()` and `setPeaksSubscriptionGuids()`
- [x] **WebSocketTypes.ts**: New `PeaksEventPayload` with track-keyed map format
  - `TrackPeaksData` interface for per-track data
- [x] **WebSocketCommands.ts**: New `peaks.subscribe()` with range/GUID modes
  - `PeaksSubscribeParams` interface
- [x] **usePeaksSubscription.ts**: Hook updated for multi-track
  - Returns `{ peaksByTrack, getPeaksForTrack, getPeaksForItem }`
  - `useSingleTrackPeaks()` for backward compatibility
- [x] **MultiTrackLanes.tsx**: Integrated waveform rendering
  - `LaneWaveform` component with combined mono-style for cramped lanes
  - `peaksByTrack` prop for peaks data
- [x] **TimelineView.tsx**: Peaks subscription integration
  - Range mode for unfiltered (with prefetch)
  - GUID mode for filtered views

---

## Success Criteria

- [x] Multi-track peaks subscription works (range and GUID modes) ✅
- [x] Waveforms render in correct lane positions ✅
- [x] Prefetch works for adjacent banks (smooth scrolling) ✅
- [x] Filtered views subscribe to correct GUIDs ✅
- [x] Cache remains effective (no regeneration thrashing) ✅
- [x] Performance acceptable with 8 visible + 16 prefetch tracks ✅

---

## Related Files

**Backend:**
- `extension/src/peaks_subscriptions.zig`
- `extension/src/peaks_generator.zig`
- `extension/src/peaks_cache.zig`
- `extension/src/commands/peaks_subs.zig`

**Frontend:**
- `frontend/src/store/slices/peaksSlice.ts`
- `frontend/src/hooks/usePeaksSubscription.ts`
- `frontend/src/components/Timeline/TimelineWaveformOverlay.tsx`
- `frontend/src/components/Timeline/MultiTrackLanes.tsx`
- `frontend/src/core/WebSocketTypes.ts`
- `frontend/src/core/WebSocketCommands.ts`

**Reference (similar patterns):**
- `extension/src/track_subscriptions.zig` (range + GUID subscription)
- `frontend/src/hooks/useTrackSubscription.ts` (subscription hook pattern)
- Meters event format (GUID-keyed map)
