# main.zig Refactoring Plan

## Current State

`main.zig` is 2316 lines containing multiple distinct responsibilities:

| Section | Lines | Description |
|---------|-------|-------------|
| Imports + Globals | 1-85 | Module imports, global state variables |
| LuaPeakBridge | 93-503 | Complete struct for Lua peak data transfer |
| Error rate limiting | 506-548 | Rate-limited error broadcasting |
| Hot reload | 509-524 | HTML file change detection |
| initTimerCallback | 556-800 | Deferred initialization logic |
| StaticBuffers + ProcessingState | 803-850 | Static memory for processing |
| Helper functions | 864-916 | Slice comparison helpers |
| **doProcessing()** | **918-2111** | **Main 30Hz timer callback (~1200 lines)** |
| shutdown() | 2113-2266 | Cleanup on unload |
| ReaperPluginEntry | 2273-2299 | C entry point |
| Test re-exports | 2301-2316 | Test module references |

### The Core Problem

`doProcessing()` is a ~1200 line function handling:
- CSurf dirty flag consumption
- Skeleton rebuild
- WebSocket server startup
- Command dispatch
- Disconnected client cleanup
- Gesture timeout handling
- Client snapshot sending
- HIGH tier polling (transport, tracks, metering, toggles, peaks, routing, trackfx, trackfxparam)
- Playlist engine tick
- MEDIUM tier polling (project, markers, regions, items, fx, sends)
- LOW tier polling (tempomap, skeleton, project notes)
- HTML hot reload check

This is untestable as a unit because:
1. Deeply coupled to global state
2. No way to test individual polling behaviors in isolation
3. Error paths are hard to exercise

---

## Refactoring Goals

1. **Reduce main.zig to orchestration only** - ~500-600 lines
2. **Extract testable modules** with clear interfaces
3. **Preserve behavior exactly** - no functional changes
4. **Enable unit testing** of individual polling/subscription logic

---

## Extraction Plan

### Phase 1: Extract LuaPeakBridge (Low Risk)

**New file:** `lua_peak_bridge.zig`

**What moves:**
- Lines 93-503: entire `LuaPeakBridge` struct
- All vararg wrappers, request/response system, API registration

**Interface:**
```zig
// lua_peak_bridge.zig
pub const LuaPeakBridge = struct {
    // ... existing implementation ...

    pub fn register(plugin_register: PluginRegisterFn) void;
    pub fn initScript(api: *const reaper.Api) bool;
    pub fn bridgeFetchAdapter(track_idx: i32, item_idx: i32, ...) ?[]const f64;
    pub fn isAvailable() bool;
};

// Global API reference (set by main.zig during init)
pub var g_api: ?*const reaper.Api = null;
```

**main.zig changes:**
```zig
const lua_peak_bridge = @import("lua_peak_bridge.zig");

// In doInitialization():
lua_peak_bridge.g_api = &g_api.?;
lua_peak_bridge.LuaPeakBridge.register(plugin_register);
if (lua_peak_bridge.LuaPeakBridge.initScript(&g_api.?)) {
    peaks_generator.setLuaBridgeFn(&lua_peak_bridge.LuaPeakBridge.bridgeFetchAdapter);
}
```

**Lines removed from main.zig:** ~410

---

### Phase 2: Extract Subscription Polling (Medium Risk)

**New file:** `subscription_polling.zig`

**What moves:** The subscription polling loops from doProcessing():
- Peaks subscription polling (~80 lines)
- Routing subscription polling (~40 lines)
- TrackFx subscription polling (~40 lines)
- TrackFxParam subscription polling (~60 lines)
- Toggle subscription polling (~20 lines)

**Interface:**
```zig
// subscription_polling.zig
pub const PollingContext = struct {
    tiered: *tiered_state.TieredArenas,
    backend: *reaper.RealBackend,
    shared_state: *ws_server.SharedState,
    guid_cache: *guid_cache.GuidCache,

    // CSurf dirty flags for this frame
    csurf_fx_dirty: csurf_dirty.TrackDirtyResult,
    csurf_sends_dirty: csurf_dirty.TrackDirtyResult,
};

pub fn pollPeaksSubscriptions(
    ctx: *const PollingContext,
    peaks_subs: *peaks_subscriptions.PeaksSubscriptions,
    tile_cache: *peaks_tile.TileCache,
) void;

pub fn pollRoutingSubscriptions(
    ctx: *const PollingContext,
    routing_subs: *routing_subscriptions.RoutingSubscriptions,
) void;

pub fn pollTrackFxSubscriptions(
    ctx: *const PollingContext,
    trackfx_subs: *trackfx_subscriptions.TrackFxSubscriptions,
) void;

pub fn pollTrackFxParamSubscriptions(
    ctx: *const PollingContext,
    trackfxparam_subs: *trackfxparam_subscriptions.TrackFxParamSubscriptions,
) void;

pub fn pollToggleSubscriptions(
    ctx: *const PollingContext,
    toggle_subs: *toggle_subscriptions.ToggleSubscriptions,
    api: *const reaper.Api,
) void;
```

**Testability gain:** Each function can be unit tested with a mock backend and mock subscriptions.

**Lines removed from main.zig:** ~240

---

### Phase 3: Extract Tier Polling (Medium Risk)

**New file:** `tier_polling.zig`

**What moves:** The HIGH/MEDIUM/LOW tier polling blocks:
- Transport polling and broadcast (~50 lines)
- Track polling with hash-based change detection (~120 lines)
- Metering polling (~30 lines)
- Markers/regions polling and broadcast (~80 lines)
- Items polling (~40 lines)
- FX/sends polling (~50 lines)
- Tempomap polling (~30 lines)
- Skeleton polling (~50 lines)
- Project notes polling (~20 lines)

**Interface:**
```zig
// tier_polling.zig
pub const TierContext = struct {
    tiered: *tiered_state.TieredArenas,
    backend: *reaper.RealBackend,
    shared_state: *ws_server.SharedState,
    guid_cache: *guid_cache.GuidCache,
    track_subs: ?*track_subscriptions.TrackSubscriptions,

    // Mutable state for change detection
    prev_tracks_hash: *u64,
    last_skeleton: *track_skeleton.State,
    last_skeleton_buf: *[]track_skeleton.SkeletonTrack,
    last_markers: *markers.State,
    last_markers_buf: *[markers.MAX_MARKERS]markers.Marker,
    last_regions_buf: *[markers.MAX_REGIONS]markers.Region,
};

pub const HighTierResult = struct {
    transport: *transport.State,
    tracks_changed: bool,
};

pub fn pollHighTier(
    ctx: *TierContext,
    force_transport: bool,
    csurf_track_dirty: bool,
) !HighTierResult;

pub fn pollMediumTier(
    ctx: *TierContext,
    force_markers: bool,
    playlist_state: *playlist.State,
    last_playlist: *playlist.State,
) !void;

pub fn pollLowTier(
    ctx: *TierContext,
    force_tempo: bool,
    notes_subs: ?*project_notes.NotesSubscriptions,
    api: *const reaper.Api,
) !void;
```

**Lines removed from main.zig:** ~450

---

### Phase 4: Extract Playlist Engine Tick (Low Risk)

**New file:** `playlist_tick.zig`

**What moves:** Lines 1556-1738 - the playlist engine tick logic

**Interface:**
```zig
// playlist_tick.zig
pub fn syncWithTransport(
    engine: *playlist.Engine,
    transport_state: *const transport.State,
    backend: anytype,
) bool; // returns true if state changed

pub fn tick(
    state: *playlist.State,
    transport_state: *const transport.State,
    regions: []const markers.Region,
    backend: anytype,
    scratch_allocator: std.mem.Allocator,
    shared_state: *ws_server.SharedState,
) void;
```

**Lines removed from main.zig:** ~180

---

### Phase 5: Extract Client Management (Low Risk)

**New file:** `client_management.zig`

**What moves:**
- Disconnected client cleanup (lines 1022-1080)
- Gesture timeout handling (lines 1082-1107)
- Client snapshot sending (lines 1109-1163)

**Interface:**
```zig
// client_management.zig
pub const ClientContext = struct {
    shared_state: *ws_server.SharedState,
    gesture_state: ?*gesture_state.GestureState,
    toggle_subs: ?*toggle_subscriptions.ToggleSubscriptions,
    notes_subs: ?*project_notes.NotesSubscriptions,
    track_subs: ?*track_subscriptions.TrackSubscriptions,
    peaks_subs: ?*peaks_subscriptions.PeaksSubscriptions,
    routing_subs: ?*routing_subscriptions.RoutingSubscriptions,
    trackfx_subs: ?*trackfx_subscriptions.TrackFxSubscriptions,
    trackfxparam_subs: ?*trackfxparam_subscriptions.TrackFxParamSubscriptions,
    api: *const reaper.Api,
};

pub fn cleanupDisconnectedClients(ctx: *ClientContext) void;
pub fn checkGestureTimeouts(ctx: *ClientContext) void;
pub fn sendSnapshotsToNewClients(
    ctx: *ClientContext,
    tiered: *tiered_state.TieredArenas,
    backend: anytype,
    playlist_state: *const playlist.State,
    markers_state: *const markers.State,
) void;
```

**Lines removed from main.zig:** ~150

---

## Summary of Changes

| Phase | New File | Lines Moved | Risk |
|-------|----------|-------------|------|
| 1 | `lua_peak_bridge.zig` | ~410 | Low |
| 2 | `subscription_polling.zig` | ~240 | Medium |
| 3 | `tier_polling.zig` | ~450 | Medium |
| 4 | `playlist_tick.zig` | ~180 | Low |
| 5 | `client_management.zig` | ~150 | Low |
| **Total** | **5 new files** | **~1430** | - |

**Resulting main.zig:** ~900 lines (down from 2316)

---

## Resulting doProcessing() Structure

After refactoring, `doProcessing()` becomes orchestration only:

```zig
fn doProcessing() !void {
    if (!g_init_complete) return;

    ztracy.FrameMark();
    const zone = ztracy.ZoneN(@src(), "doProcessing");
    defer zone.End();

    const api = &(g_api orelse return error.ApiNotInitialized);
    const shared_state = g_shared_state orelse return error.StateNotInitialized;
    var tiered = &(g_tiered orelse return error.TieredNotInitialized);
    var backend = reaper.RealBackend{ .inner = api };

    try tiered.beginFrame(g_frame_counter);

    // 1. Consume CSurf dirty flags
    const dirty = consumeDirtyFlags();

    // 2. Immediate skeleton rebuild if needed
    if (dirty.force_skeleton) rebuildSkeleton(&backend);

    // 3. Deferred WebSocket startup
    if (!g_ws_started and g_frame_counter >= WS_START_DELAY_FRAMES) {
        try startWebSocketServer(api, shared_state);
    }

    // 4. Process commands
    processCommands(&backend, shared_state);

    // 5. Client management
    client_management.cleanupDisconnectedClients(&client_ctx);
    client_management.checkGestureTimeouts(&client_ctx);
    client_management.sendSnapshotsToNewClients(&client_ctx, tiered, &backend, ...);

    g_frame_counter +%= 1;

    // 6. HIGH tier (30Hz)
    const high_result = try tier_polling.pollHighTier(&tier_ctx, dirty.force_transport, dirty.csurf_track_dirty);

    // 7. Subscription polling (30Hz)
    subscription_polling.pollToggleSubscriptions(&poll_ctx, g_toggle_subs, api);
    subscription_polling.pollPeaksSubscriptions(&poll_ctx, g_peaks_subs, g_tile_cache);
    subscription_polling.pollRoutingSubscriptions(&poll_ctx, g_routing_subs);
    subscription_polling.pollTrackFxSubscriptions(&poll_ctx, g_trackfx_subs);
    subscription_polling.pollTrackFxParamSubscriptions(&poll_ctx, g_trackfxparam_subs);

    // 8. Playlist engine tick
    playlist_tick.syncWithTransport(&g_playlist_state.engine, high_result.transport, &backend);
    playlist_tick.tick(&g_playlist_state, high_result.transport, g_last_markers.regions, &backend, ...);

    // 9. MEDIUM tier (5Hz)
    if (g_frame_counter % MEDIUM_TIER_INTERVAL == 0 or dirty.force_markers) {
        try tier_polling.pollMediumTier(&tier_ctx, dirty.force_markers, &g_playlist_state, &g_last_playlist);
    }

    // 10. LOW tier (1Hz)
    if (g_frame_counter % LOW_TIER_INTERVAL == 0 or dirty.force_tempo) {
        try tier_polling.pollLowTier(&tier_ctx, dirty.force_tempo, g_notes_subs, api);
    }

    // 11. Heartbeat safety net (2s)
    if (csurf.enabled and g_frame_counter % csurf_dirty.SAFETY_POLL_INTERVAL == 0) {
        if (g_dirty_flags) |flags| flags.setAllTracksDirty();
    }

    // 12. HTML hot reload check
    checkHtmlReload(shared_state);
}
```

This is ~80 lines of orchestration vs ~1200 lines of interleaved logic.

---

## Implementation Order

1. **Phase 1 (lua_peak_bridge)** - Start here, lowest risk, immediate win
2. **Phase 5 (client_management)** - Low risk, self-contained
3. **Phase 4 (playlist_tick)** - Low risk, self-contained
4. **Phase 2 (subscription_polling)** - Medium risk, but high testability gain
5. **Phase 3 (tier_polling)** - Medium risk, most complex extraction

Each phase should:
1. Create new file with extracted code
2. Update main.zig to use new module
3. Run `zig build test` to verify no regressions
4. Run manual smoke test in REAPER

---

## Testing Strategy

After extraction, each new module can have unit tests:

```zig
// subscription_polling.zig
test "pollPeaksSubscriptions broadcasts when force_broadcast set" {
    var mock_backend = reaper.MockBackend{};
    var mock_shared_state = testing.MockSharedState{};
    // ... setup subscriptions ...

    pollPeaksSubscriptions(&ctx, &peaks_subs, &tile_cache);

    try testing.expect(mock_shared_state.broadcast_count > 0);
}
```

This is impossible with the current monolithic `doProcessing()`.

---

## Non-Goals

- **Don't change behavior** - This is pure refactoring
- **Don't optimize** - Performance changes are separate work
- **Don't reduce global state yet** - That's a larger architectural change
- **Don't touch playlist.zig** - It's already well-structured
