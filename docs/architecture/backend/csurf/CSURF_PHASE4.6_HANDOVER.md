# CSurf Phase 4.6 Handover Document

## Plan Reference

Main plan: `docs/architecture/CSURF_MIGRATION.md`

## Completed Phases

| Phase | Description | Status |
|-------|-------------|--------|
| Phase 0 | CSurf infrastructure (C++ shim, callback module) | ✅ Complete |
| Phase 1 | DirtyFlags struct in `csurf_dirty.zig` | ✅ Complete |
| Phase 2 | reverse_map in `guid_cache.zig` | ✅ Complete |
| Phase 3 | Wire callbacks to dirty flags in `csurf.zig` | ✅ Complete |
| Phase 4 | Main loop integration (skeleton rebuild, heartbeat) | ✅ Complete |
| Phase 5 | ResetCachedVolPanStates callback | ✅ Complete |
| Phase 4.5 | Global dirty flag consumption (transport/markers/tempo) | ✅ Complete |
| **Phase 4.6** | **Per-track dirty flag consumption** | ⏳ **NEXT** |

## Current State Summary

The CSurf push-based architecture is mostly complete. Callbacks from REAPER set dirty flags, and the main loop consumes global dirty flags (transport, markers, tempo, skeleton) for immediate polling outside tier intervals.

**What's working:**
- CSurf callbacks set `track_dirty`, `fx_dirty`, `sends_dirty` bitsets
- Global flags (`transport_dirty`, `markers_dirty`, `tempo_dirty`, `skeleton_dirty`) are consumed and trigger immediate polling
- Heartbeat every 2 seconds sets `all_tracks_dirty` for safety net
- Skeleton rebuilds immediately when `skeleton_dirty` is set (minimizes stale pointer window)

**What's NOT yet integrated:**
- Per-track dirty bitsets (`track_dirty`, `fx_dirty`, `sends_dirty`) are SET by callbacks but NOT YET CONSUMED by the main loop
- Track polling still polls all subscribed tracks every frame (30Hz)

## The Architectural Problem

The original plan (Phase 4.6) proposed filtering `subscribed_indices` by dirty bits to reduce polling. However, this **breaks change detection**.

### Current Change Detection Pattern

```zig
// main.zig lines 718-733
const subscribed_indices = track_subs.getSubscribedIndices(...);  // e.g., [1,2,3,4,5]
const track_state = tracks.State.pollIndices(allocator, api, subscribed_indices);
high_state.tracks = track_state.tracks;  // Slice of 5 Track structs

// Later...
const tracks_changed = !tracksSliceEql(high_state.tracks, high_prev.tracks);
if (tracks_changed or force_broadcast) {
    broadcast(...);
}
```

### Why Filtering Breaks This

If we filter indices by dirty bits:
- Frame N: poll tracks [1,2,3,4,5] → `high_state.tracks` has 5 elements
- Frame N+1: only track 3 dirty → poll tracks [3] → `high_state.tracks` has 1 element
- `tracksSliceEql` compares 5-element slice vs 1-element slice → **always "changed"**
- Result: broadcast every frame = spam

## Candidate Approaches

### Option A: Latency-only optimization (simpler, lower risk)
- Keep polling all subscribed tracks (no change to pollIndices)
- Use dirty flags to FORCE broadcast even when change detection says "same"
- CPU savings: Minimal for track polling (already subscription-filtered)
- Latency savings: Instant response to CSurf callbacks
- ~15 lines of code, no architectural risk

### Option B-1: Hash-based change detection
- Always poll all subscribed tracks
- Compute hash of track state after polling (like markers/items already do)
- Compare hash with previous frame
- Pro: Simple, works with current architecture
- Con: Still polls all tracks (no API call reduction)

### Option B-2: Dirty-flag-driven broadcast (no change detection)
- If CSurf enabled and any subscribed track has dirty bit → poll dirty tracks → broadcast
- If no dirty bits → don't poll, don't broadcast
- Heartbeat sets `all_tracks_dirty` for safety
- Pro: Maximum CPU savings (99% as plan claims)
- Con: Requires refactoring change detection; dirty flags become sole source of truth

### Option B-3: Per-track hash with index-keyed comparison
- Store prev state in HashMap keyed by track index (not slice)
- When polling subset, only compare tracks we polled
- Pro: Works with partial polling
- Con: Need to track which indices polled vs skipped, more complex

## Existing Codebase Patterns

The codebase already uses hash-based change detection in several places:
- `markers.zig` - `computeHash()` for markers and regions
- `items.zig` - `computeHash()` for items
- `routing_subscriptions.zig` - per-client `prev_hash` with `checkChanged()`
- `project_notes.zig` - hash-based change detection
- `tempomap.zig` - simple hash for change detection

This is a well-established pattern. The `routing_subscriptions.zig` approach (per-client hash storage) is most relevant.

## Key Files for Phase 4.6

| File | Relevance |
|------|-----------|
| `extension/src/main.zig` | doProcessing() lines 465-785 - dirty flag consumption, track polling |
| `extension/src/csurf_dirty.zig` | DirtyFlags struct, consumeTrackDirty() method |
| `extension/src/tracks.zig` | Track struct, pollIndices(), State.eql() |
| `extension/src/track_subscriptions.zig` | getSubscribedIndices(), consumeForceBroadcast() |
| `docs/architecture/CSURF_MIGRATION.md` | Original plan with CPU savings estimates |

## CPU Savings Context

The plan claims:
- 100 tracks idle: 3000 polls/s → 30 polls/s (99% reduction)
- This assumes we STOP polling tracks that aren't dirty

With current subscription-based filtering:
- 32-track viewport × 30Hz = 960 API calls/sec (already reduced from 3000)
- Full optimization would reduce to ~10-50 calls/sec during activity

The question is whether the additional complexity of Options B-2/B-3 is worth the ~900 calls/sec savings.

## Research Query

The following research query was sent to another Claude instance to investigate best practices:

---

```
RESEARCH QUERY: Optimizing Real-Time State Synchronization for DAW Control Surface with Push-Based Callbacks
Context: REAmo - REAPER DAW Web Controller Extension We're building a Zig-based REAPER extension that serves as a WebSocket bridge between REAPER and a React web UI. The extension polls REAPER state at 30Hz and broadcasts changes to connected clients. Current Architecture:
Polling loop runs at 30Hz on REAPER's main thread
Track state is polled for subscribed tracks only (viewport-driven filtering)
Change detection uses slice comparison: tracksSliceEql(current, previous) compares Track structs element by element
Double-buffered arenas - current frame's data allocated from one arena, previous frame's from another, swap each frame
Broadcast only when change detection says data differs
New CSurf Integration: We've implemented REAPER's IReaperControlSurface callbacks via a C++ shim. When REAPER state changes, callbacks fire:
SetSurfaceVolume(track, vol) - track volume changed
SetSurfacePan(track, pan) - track pan changed
SetSurfaceMute(track, mute) - track mute toggled
SetSurfaceSolo(track, solo) - track solo toggled
SetSurfaceSelected(track, sel) - track selection changed
SetTrackListChange() - track added/removed/reordered
Extended(SETFXPARAM, track, ...) - FX parameter changed
Dirty Flag System Already Implemented:

pub const DirtyFlags = struct {
    reverse_map_valid: bool = false,  // Guard for stale track pointers
    track_dirty: std.StaticBitSet(1024) = ...,  // Per-track dirty
    fx_dirty: std.StaticBitSet(1024) = ...,
    sends_dirty: std.StaticBitSet(1024) = ...,
    transport_dirty: bool = false,
    skeleton_dirty: bool = false,
    markers_dirty: bool = false,
    tempo_dirty: bool = false,
    all_tracks_dirty: bool = false,  // Overflow/heartbeat fallback
};
Callbacks set dirty bits; main loop consumes them. THE PROBLEM: We want to reduce polling from O(subscribed_tracks) to O(changed_tracks). The plan claims:
100 subscribed tracks idle: 3000 API calls/sec → 30 API calls/sec (99% reduction)
100 tracks with changes: ~10-50 API calls/sec (only poll changed tracks)
But the current change detection architecture breaks:

// Current approach
const subscribed_indices = track_subs.getSubscribedIndices(...);  // e.g., [1,2,3,4,5]
const track_state = tracks.State.pollIndices(allocator, api, subscribed_indices);
high_state.tracks = track_state.tracks;  // Slice of 5 Track structs

// Later...
const tracks_changed = !tracksSliceEql(high_state.tracks, high_prev.tracks);
if (tracks_changed or force_broadcast) {
    broadcast(track_state.toJson());
}
If we filter indices by dirty bits:
Frame N: poll tracks [1,2,3,4,5] → high_state.tracks has 5 elements
Frame N+1: only track 3 is dirty → poll tracks [3] → high_state.tracks has 1 element
tracksSliceEql compares 5-element slice vs 1-element slice → always "changed"
Result: broadcast every frame, defeating optimization
EXISTING PATTERNS IN CODEBASE: The codebase already uses hash-based change detection elsewhere:

// markers.zig
pub fn computeHash(self: *const MarkersState) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&self.markers.len));
    for (self.markers) |m| {
        hasher.update(std.mem.asBytes(&m.id));
        hasher.update(std.mem.asBytes(&m.position));
        // ...
    }
    return hasher.final();
}

// routing_subscriptions.zig - per-client hash storage
prev_hash: [MAX_CLIENTS]u64,

pub fn checkChanged(self: *Self, slot: usize, data_hash: u64) bool {
    if (self.prev_hash[slot] != data_hash) {
        self.prev_hash[slot] = data_hash;
        return true;
    }
    return false;
}
CANDIDATE APPROACHES: Option B-1: Hash-based change detection
Always poll all subscribed tracks (unchanged)
Compute hash of track state after polling
Compare hash with previous frame's hash
If different, broadcast; if same, skip
Pro: Simple, works with current architecture
Con: Still polls all tracks (no API call reduction)
Option B-2: Dirty-flag-driven broadcast (no change detection)
If CSurf enabled and any subscribed track has dirty bit → poll dirty tracks → broadcast
If no dirty bits → don't poll, don't broadcast
Heartbeat (every 2s) sets all_tracks_dirty for safety
Pro: Maximum CPU savings (only poll changed tracks)
Con: Requires refactoring change detection; dirty flags are the sole source of truth
Option B-3: Persistent track state with merge
Keep non-arena persistent HashMap keyed by track index
When dirty, poll just those tracks, merge into persistent state
Compare persistent state with prev for broadcast
Pro: Full optimization
Con: Complex, breaks arena model, memory management complexity
Option B-4: Per-track hash with index-keyed comparison
Store prev state in HashMap keyed by track index (not slice)
When polling subset, only compare tracks we polled
If any polled track differs from prev at that index → changed
Pro: Works with partial polling
Con: Need to track which indices were polled vs skipped
SPECIFIC QUESTIONS:
Which approach best balances CPU savings vs architectural complexity for a 30Hz real-time system?
How do production DAW control surfaces (MCU, HUI, OSC implementations) handle incremental state sync? Do they rely purely on callbacks (never poll), or use hybrid approaches?
Are there known CSurf callback edge cases where state changes but callbacks don't fire? SWS Extension uses 2-second "safety poll" - is this sufficient, or are there specific scenarios to watch for?
For hash-based change detection: is computing a hash of ~32 Track structs (~150 bytes each) per frame (30Hz) a meaningful CPU cost? Wyhash is fast, but is it negligible compared to REAPER API call overhead?
What are best practices for "eventual consistency" in real-time state sync? If we miss a CSurf callback and the heartbeat catches it 2 seconds later, is 2-second staleness acceptable for a mixer UI? Should we have different staleness tolerances for different data (faders vs selection vs FX)?
For the dirty-flag-driven approach (B-2): if we trust dirty flags as the sole change signal, what validation should the heartbeat do? Just set all_dirty and poll everything? Or actively compare against REAPER state and log drift?
Are there race conditions between CSurf callbacks and our timer callback? Both run on REAPER's main thread, but can a CSurf callback interrupt our timer callback mid-execution? SWS sets flags in callbacks and processes in Run() - is there ordering guarantee?
CONSTRAINTS:
Must never crash REAPER (users have unsaved work)
REAPER 7.x on macOS ARM64 / Windows x64
Zig 0.15 with C++ interop for IReaperControlSurface
Extension loaded via plugin_register("csurf_inst", ...) for auto-activation
30Hz timer callback for polling (separate from CSurf's Run())
WebSocket clients may be on WiFi (20-50ms latency acceptable)
SUCCESS CRITERIA:
Reduce CPU usage measurably for idle 100-track project
Maintain <33ms latency for fader/mute/solo changes
No regressions in change detection (no missed updates, no spam)
Graceful degradation when CSurf disabled (fall back to full polling)
Would this research query give you enough context to investigate thoroughly? I want to ensure the research Claude has everything needed to:
Search for real-world DAW control surface implementations
Look for academic/industry papers on incremental state sync
Find REAPER forum discussions about CSurf edge cases
Recommend a specific approach based on tradeoffs
```

---

## Research Results

See: `./CSURF_RESEARCH.md`

## Research Key Findings

The research (`CSURF_RESEARCH.md`) revealed critical insights:

1. **Hybrid is universal**: All production CSurf implementations (MCU, HUI, SWS, CSI, ReaLearn) use callback + polling. Pure callbacks are insufficient due to documented gaps.

2. **Known callback gaps**:
   - `OnTrackSelection()` - doesn't fire for action/API-based selection
   - `CSURF_EXT_SETFXCHANGE` - doesn't fire when dragging FX between tracks
   - Undo/redo - no dedicated callback at all
   - Project tab switching only triggers `SetTrackListChange()`

3. **Hash computation is negligibly cheap**: Wyhash at 30Hz = ~0.0008% CPU. Hash comparison (2ns) is 10-100x cheaper than API calls (100ns-10μs).

4. **Threading guarantees**: All CSurf callbacks and timer callbacks run on main thread. No race conditions possible.

5. **Latency constraints**: REAPER's timer fires at ~27-33ms. WebSocket adds 20-50ms over WiFi. Total: 50-80ms is achievable, well within "acceptable" (36-64ms for fader feedback). Professional target (<10ms) requires wired/local clients.

6. **Research conclusion**: "callback-primary with polling safety net: trust callbacks for immediate response, process changes in Run() using dirty flags, run 2-second hash-based safety poll to catch drift and log debugging information"

## Decision: Option B-1 + A Hybrid with Drift Logging

**Chosen approach**: Hash-based change detection + dirty flag force broadcast + drift logging

### Rationale

1. **Why NOT Option B-2 (dirty-flag-driven)**:
   - Research explicitly warns against trusting dirty flags as sole source of truth
   - Documented callback gaps (undo, selection, FX drag) would cause missed updates
   - The 99% CPU savings claim assumes perfect callbacks, which don't exist

2. **Why hash-based (B-1)**:
   - Already established pattern in codebase (markers, items, routing, tempomap)
   - Catches callback gaps via continued polling
   - Hash is negligibly cheap (~2ns) compared to API overhead
   - Replaces fragile slice comparison with robust hash comparison

3. **Why add dirty flag consumption (Option A benefit)**:
   - Force broadcast when dirty flags set, even if hash unchanged
   - Provides instant latency response to callback-driven changes
   - Best-in-class latency within REAPER's ~27ms physical constraints

4. **Why drift logging**:
   - Research recommends: "drift logs identify which callbacks you're missing"
   - Helps discover undocumented REAPER behaviors
   - Valuable for debugging, can reduce to metrics-only in production

### Scope Decisions

1. **Tracks only for Phase 4.6**: FX/sends data is fetched on-demand (not continuously polled), so hash detection doesn't apply. Track FX will move to subscription mechanism in a future phase.

2. **fx_dirty/sends_dirty bitsets**: Will be used for latency improvement when those subscription systems are added. Not consumed in Phase 4.6.

## Implementation Plan

**~50 lines of changes across 2 files:**

### 1. tracks.zig - Add computeHash() (~25 lines)

**CRITICAL**: Hash ALL fields that appear in broadcast JSON (from toJsonWithTotal).
The Track.eql() function (lines 108-133) already compares all fields correctly - use as reference.

```zig
pub fn computeHash(track_slice: []const Track) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&track_slice.len));
    for (track_slice) |*t| {
        // All fields from Track.eql() / toJsonWithTotal():
        hasher.update(std.mem.asBytes(&t.idx));
        hasher.update(t.name[0..t.name_len]);  // Variable-length name
        hasher.update(std.mem.asBytes(&t.name_len));
        hasher.update(std.mem.asBytes(&t.color));
        hasher.update(std.mem.asBytes(&t.volume));
        hasher.update(std.mem.asBytes(&t.pan));
        hasher.update(std.mem.asBytes(&t.mute));
        hasher.update(std.mem.asBytes(&t.solo));
        hasher.update(std.mem.asBytes(&t.rec_arm));
        hasher.update(std.mem.asBytes(&t.rec_mon));
        hasher.update(std.mem.asBytes(&t.fx_enabled));
        hasher.update(std.mem.asBytes(&t.selected));
        hasher.update(std.mem.asBytes(&t.folder_depth));
        hasher.update(std.mem.asBytes(&t.fx_count));
        hasher.update(std.mem.asBytes(&t.send_count));
        hasher.update(std.mem.asBytes(&t.receive_count));
        hasher.update(std.mem.asBytes(&t.hw_output_count));
        hasher.update(std.mem.asBytes(&t.rec_input));
        hasher.update(t.guid[0..t.guid_len]);  // Variable-length GUID
        hasher.update(std.mem.asBytes(&t.guid_len));
    }
    return hasher.final();
}
```

### 2. main.zig - Consume dirty flags + hash comparison (~35 lines)

```zig
// Add state variables (module level)
var prev_tracks_hash: u64 = 0;
var last_drift_log_time: i64 = 0;  // For rate limiting drift logs

// In doProcessing(), after track polling:
const current_hash = tracks.computeHash(high_state.tracks);

// Consume dirty flags
const dirty_result = if (g_dirty_flags) |df| df.consumeTrackDirty() else .{ .bits = ..., .all = false };
const any_dirty = dirty_result.all or dirty_result.bits.count() > 0;

// Change detection
const hash_changed = current_hash != prev_tracks_hash;
const tracks_changed = hash_changed or force_broadcast or any_dirty;

// Drift logging with rate limiting (max 1 per second to avoid spam during undo/redo bursts)
if (hash_changed and !any_dirty and !force_broadcast) {
    const now_ms = std.time.milliTimestamp();
    if (now_ms - last_drift_log_time > 1000) {  // 1 second cooldown
        logging.warn("Track state drift detected without dirty flag (undo/selection/FX drag?)", .{});
        last_drift_log_time = now_ms;
    }
}

if (tracks_changed) {
    broadcast(...);
    prev_tracks_hash = current_hash;
}
```

**Note on drift logging**: Rate-limited to 1/second to prevent log spam during rapid undo/redo sequences (which can cause 10+ drift events per second). The important diagnostic is knowing drift occurs, not every instance.

### Files NOT touched (guard rails)

- `csurf.zig` ✓
- `csurf_dirty.zig` ✓
- `guid_cache.zig` ✓

## Success Criteria

1. `zig build -Dcsurf=true` succeeds
2. `zig build test -Dcsurf=true` passes
3. `zig build` (without CSurf) succeeds - fallback works
4. Dirty flag changes trigger immediate broadcast (<33ms)
5. Undo/redo changes are caught by hash comparison (not 2s heartbeat)
6. Drift warnings appear in logs when expected (undo, action-based selection)

## External Review Feedback (Addressed)

Review from another Claude instance raised these points:

| Point | Status | Notes |
|-------|--------|-------|
| Hash all broadcast fields | ✅ Addressed | Updated computeHash() pseudocode to include ALL fields from Track.eql()/toJsonWithTotal() |
| Subscription changes between frames | ✅ Expected | Client changes subscribed tracks → first fetch broadcasts full state |
| Drift log rate limiting | ✅ Addressed | Added 1-second cooldown to prevent spam during undo/redo bursts |
| Master track handling | ✅ Verified | guid_cache.zig returns idx=0 for master, reverse_map works correctly |
| Soak test suggestion | ⏳ Plan | Run for 1 week before making CSurf default (Phase 6) |

## After Phase 4.6

Only one phase remains:
- **Phase 6**: Make CSurf the default (flip `orelse false` to `orelse true` in build.zig) - trivial, one line

**Soak test before Phase 6**: Run CSurf-enabled build in daily use for 1 week minimum. Monitor drift logs for unexpected patterns. Only flip default after confidence is high.

Then manual testing per CSURF_MIGRATION.md testing checklist.

## Build Commands

```bash
cd extension && zig build -Dcsurf=true        # Build with CSurf
cd extension && zig build test -Dcsurf=true   # Run tests
cd extension && zig build                      # Build without CSurf (fallback)
```
