# REAmo Development Guide

This document captures implementation details, API quirks, and outstanding work for the REAmo REAPER web controller.

## Table of Contents

- [Quick Start](#quick-start)
- [Architecture Overview](#architecture-overview)
- [Data Flow](#data-flow)
- [CSurf Push-Based Architecture](#csurf-push-based-architecture)
- [Conventions](#conventions)
- [REAPER API Critical Knowledge](#reaper-api-critical-knowledge) — Track indexing, colors, master track quirks, metering
- [Frontend Conventions](#frontend-conventions) — Volume/color conversion, UI patterns, gestures, animation
- [Testing Conventions](#testing-conventions)
- [Extension Robustness](#extension-robustness)
- [Protocol & Versioning](#protocol--versioning)
- [Extension Configuration](#extension-configuration)
- [Build & Test](#build--test)
- [Debugging](#debugging) — [WebSocket Testing](#websocket-testing)
- [Common Pitfalls](#common-pitfalls)

---

## Quick Start

```bash
make frontend    # Build frontend → reamo.html (auto-reloads on iPad)
make extension   # Build extension → REAPER UserPlugins (restart REAPER to load)
make test        # Run all tests before committing
```

**Frontend changes** are visible immediately — the web UI auto-reloads when `reamo.html` is updated.

**Extension changes** require restarting REAPER to load the new plugin.

## Architecture Overview

### Project Structure

```text
reaper_www_root/
├── extension/           # Zig REAPER extension (WebSocket server)
│   └── src/
│       ├── main.zig           # Entry point, timer loop, state broadcasting
│       ├── constants.zig      # Shared MAX_* constants (MAX_TRACKS, MAX_ITEMS, etc.)
│       ├── errors.zig         # Error type hierarchy, ErrorCode registry, rate limiting
│       ├── ffi.zig            # FFI validation: safeFloatToInt(), NaN/Inf checks
│       ├── logging.zig        # Ring buffer logging, crash recovery, log levels
│       ├── protocol.zig       # JSON parsing for commands (no allocations)
│       ├── reaper.zig         # Re-exports: RealBackend, MockBackend, raw types
│       ├── reaper/            # REAPER API abstraction layer
│       │   ├── raw.zig        # C function pointers (~80 raw functions)
│       │   ├── types.zig      # Shared types (BeatsInfo, MarkerInfo, etc.)
│       │   ├── backend.zig    # validateBackend() comptime check (~150 methods)
│       │   ├── real.zig       # RealBackend - production wrapper around raw.Api
│       │   └── mock/          # MockBackend for testing (7 files)
│       │       ├── mod.zig        # MockBackend struct composition + delegation
│       │       ├── state.zig      # MockTrack, MockItem, encoding helpers
│       │       ├── transport.zig  # Transport mock methods
│       │       ├── tracks.zig     # Track/item mock methods
│       │       ├── markers.zig    # Marker/region mock methods
│       │       ├── project.zig    # Project/undo/extstate mock methods
│       │       └── preferences.zig # Smooth seek & preferences mock methods
│       ├── frame_arena.zig    # DoubleBufferedState for swappable arenas
│       ├── tiered_state.zig   # Tiered arenas: HIGH/MEDIUM/LOW + scratch
│       ├── transport.zig      # Transport state polling (HIGH tier, 30Hz)
│       ├── tracks.zig         # Track state & metering (HIGH tier, 30Hz)
│       ├── items.zig          # Item/take state polling (MEDIUM tier, 5Hz)
│       ├── markers.zig        # Marker/region state polling (MEDIUM tier, 5Hz)
│       ├── project.zig        # Project state: length, BPM, undo, repeat
│       ├── fx.zig             # FX chain state: plugins, enabled, presets
│       ├── sends.zig          # Send state: destination, volume, pan, mute
│       ├── tempomap.zig       # Tempo marker state (LOW tier, 1Hz)
│       ├── track_skeleton.zig # Lightweight name+GUID list (LOW tier, 1Hz)
│       ├── track_subscriptions.zig  # Per-client track viewport subscriptions (index range or GUIDs)
│       ├── timeline_subscriptions.zig # Per-client time-range subscriptions (items only)
│       ├── toggle_subscriptions.zig # Action toggle state subscriptions
│       ├── project_notes.zig  # Project notes subscription management
│       ├── guid_cache.zig     # O(1) GUID → track pointer lookup
│       ├── gesture_state.zig  # Gesture tracking for undo coalescing
│       ├── playlist.zig       # Playlist state (entries, loop counts)
│       ├── ws_server.zig      # WebSocket server and client management
│       ├── peaks_subscriptions.zig    # Per-client peak/waveform tile subscriptions
│       ├── trackfx_subscriptions.zig  # Per-client FX chain subscriptions
│       ├── trackfxparam_subscriptions.zig # Per-client FX param subscriptions
│       ├── trackfxparam_generator.zig # FX param JSON generation with nameHash
│       ├── csurf.zig          # CSurf callback → dirty flag wiring
│       ├── csurf_dirty.zig    # DirtyFlags struct with BitSet(1024) per-track
│       └── commands/          # Command handlers (120+ handlers in 30+ files)
│           ├── mod.zig        # dispatch() with inline for, ResponseWriter
│           ├── registry.zig   # Comptime tuple of all handlers
│           ├── tracks.zig     # track/setVolume, track/setMute, etc.
│           ├── transport.zig  # transport/play, transport/stop, etc.
│           ├── playlist.zig   # playlist/create, play, stop, etc. (15 handlers)
│           ├── timeline_subs.zig # timeline/subscribe, timeline/unsubscribe
│           └── ...
├── frontend/            # React/TypeScript web UI
│   └── src/
│       ├── core/              # Types, WebSocket connection
│       │   ├── types.ts       # Track, Region, Marker types
│       │   ├── WebSocketTypes.ts    # WSTrack, WSMeter, event payloads
│       │   └── WebSocketCommands.ts # Command builders
│       ├── store/             # Zustand state management
│       │   ├── index.ts       # Main store, WebSocket message handler
│       │   └── slices/        # State slices:
│       │       ├── tracksSlice.ts      # Track state and metering
│       │       ├── transportSlice.ts   # Transport state
│       │       ├── peaksSlice.ts       # Tile cache with LRU eviction
│       │       ├── fxChainSlice.ts     # FX chain subscription state
│       │       ├── fxParamSlice.ts     # FX param state with skeleton cache
│       │       ├── fxBrowserSlice.ts   # Installed plugin list cache
│       │       └── ...
│       ├── hooks/             # useTrack, useTracks, useTransport
│       ├── components/        # React components
│       │   └── Track/         # TrackStrip, LevelMeter, Fader, etc.
│       └── utils/             # volume.ts, color.ts, pan.ts
├── Scripts/Reamo/       # Lua scripts called by the Zig extension
│   └── reamo_internal_fetch_peaks.lua  # Peak data fetching via GetMediaItemTake_Peaks
├── Makefile             # Build commands: make all, make extension, make frontend
└── reamo.html           # Built frontend (single-file, copied from frontend/dist)
```

### Threading Model

```
┌─────────────────────┐     ┌──────────────────────┐
│  Main Thread        │     │  WebSocket Thread    │
│  (REAPER context)   │     │  server.listen()     │
│                     │     │                      │
│  Timer callback:    │     │  Handler callbacks:  │
│  - Poll REAPER state│◄───►│  - clientMessage()   │
│  - Diff & push      │     │  - close()           │
│  - Process commands │     │                      │
└─────────┬───────────┘     └──────────┬───────────┘
          │                            │
          └────────────┬───────────────┘
                       ▼
              ┌────────────────────┐
              │  Shared State      │
              │  (Mutex-protected) │
              │  - Command queue   │
              │  - Connected clients│
              │  - Cached state    │
              └────────────────────┘
```

**All REAPER API calls must happen on the main thread.** The pattern:

1. WebSocket thread receives command
2. Push to mutex-protected queue
3. Timer callback (main thread) processes queue
4. Execute REAPER API calls
5. Push response/updates to clients

### Testability Architecture (Comptime Generics)

The extension uses **comptime duck typing via `anytype`** to enable mock injection for unit testing while maintaining zero runtime overhead.

```
┌─────────────────────────────────────────────────────────┐
│                    State Modules                        │
│   transport.zig, tracks.zig, markers.zig, etc.         │
│         fn poll(api: anytype) State                     │
└──────────────────────────┬──────────────────────────────┘
                           │ duck typing via anytype
          ┌────────────────┴────────────────┐
          ▼                                 ▼
  ┌──────────────────┐            ┌───────────────────┐
  │   RealBackend    │            │   MockBackend     │
  │  (production)    │            │  (tests)          │
  │  FFI validation  │            │  injectable errs  │
  └────────┬─────────┘            └───────────────────┘
           │
           ▼
  ┌──────────────────┐
  │     raw.Api      │
  │ Pure C bindings  │
  │ Returns raw f64  │
  └──────────────────┘
```

### FFI Validation Layer

**Principle: `raw.zig` returns exactly what REAPER's C API returns.** All validation and type conversion happens in `RealBackend`.

This separation ensures:
1. **raw.zig stays simple** — direct passthrough to C, no error handling
2. **Validation is testable** — MockBackend can inject errors to test caller handling
3. **Single source of truth** — all NaN/Inf checks happen in one place

**Example — getTrackSolo:**
```zig
// raw.zig — pure binding, returns what REAPER returns
pub fn getTrackSolo(self: *const Api, track: *anyopaque) f64 {
    const f = self.getMediaTrackInfo_Value orelse return 0;
    return f(track, "I_SOLO");
}

// real.zig — adds validation
pub fn getTrackSolo(self: *const RealBackend, track: *anyopaque) ffi.FFIError!c_int {
    return ffi.safeFloatToInt(c_int, self.inner.getTrackSolo(track));
}

// mock/tracks.zig — injectable errors for testing
pub fn getTrackSolo(self: *const Tracks, track: *anyopaque) ffi.FFIError!c_int {
    if (self.inject_track_solo_error) return ffi.FFIError.NaN;
    // ... normal mock behavior
}
```

**Caller pattern — graceful degradation with nullable fields:**
```zig
// tracks.zig — uses catch null to propagate corrupt data
t.color = api.getTrackColor(track) catch null;  // ?c_int
t.solo = api.getTrackSolo(track) catch 0;       // FFIError!c_int → default

// items.zig — same pattern
item.selected = api.getItemSelected(item_ptr) catch null;  // ?bool
```

**JSON serialization** handles null values automatically — clients see `"color": null` for corrupt data instead of garbage values or crashes.

**FFI validation utilities in `ffi.zig`:**

| Function | Use Case |
|----------|----------|
| `safeFloatToInt(T, val)` | Direct conversion with NaN/Inf/range validation |
| `roundFloatToInt(T, val)` | Rounds first, then validates — use for beat/tick formatting |
| `isFinite(val)` | Quick NaN/Inf check before arithmetic |

```zig
// safeFloatToInt - for direct conversions (sample counts, indices)
const samples: usize = ffi.safeFloatToInt(usize, length * SAMPLE_RATE) catch {
    response.err("INVALID_LENGTH", "Item length too large");
    return;
};

// roundFloatToInt - for display formatting (beats, ticks)
const scaled: u32 = ffi.roundFloatToInt(u32, (beat_in_bar + 1.0) * 100.0) catch {
    return error.InvalidBeatValue;
};

// isFinite - for early validation before arithmetic
if (!ffi.isFinite(length) or length <= 0) {
    response.err("INVALID_LENGTH", "Item has invalid length");
    return;
}
```

**FFI validation files:**
- `src/reaper/raw.zig` — Pure C bindings, returns `f64` from REAPER
- `src/reaper/real.zig` — `RealBackend` with `ffi.safeFloatToInt()` validation
- `src/reaper/mock/tracks.zig` — `inject_*_error` fields for testing error paths
- `src/ffi.zig` — `safeFloatToInt()`, `roundFloatToInt()`, `isFinite()` definitions

**Testability key files:**

| File | Purpose |
|------|---------|
| `reaper/backend.zig` | `validateBackend(T)` — comptime validates ~150 required methods |
| `reaper/real.zig` | `RealBackend` — thin wrapper around `raw.Api`, used in production |
| `reaper/mock/mod.zig` | `MockBackend` — field-based state for tests, no REAPER needed |
| `commands/registry.zig` | Comptime tuple of all 114 command handlers |
| `commands/mod.zig` | `dispatch()` using `inline for`, `CommandContext` for handler globals |
| `constants.zig` | Shared `MAX_*` constants used across modules |

**Why `anytype`?**

- Function pointers cannot use generics — the signature is fixed at compile time
- `anytype` with a single `validateBackend()` check is cleaner than full generics
- Duck typing works for both `*RealBackend` and `*MockBackend`
- Zero runtime overhead — all dispatch is resolved at compile time

**Command dispatch pattern:**

```zig
// registry.zig — comptime tuple of handlers
pub const all = .{
    .{ "transport/play", transport.handlePlay },
    .{ "transport/stop", transport.handleStop },
    // ... 114 entries total
};

// mod.zig — dispatch with inline for (unrolls at comptime)
pub fn dispatch(api: anytype, client_id: usize, data: []const u8, ...) void {
    inline for (comptime_registry.all) |entry| {
        if (std.mem.eql(u8, cmd.command, entry[0])) {
            entry[1](api, cmd, &response);
            return;
        }
    }
}
```

**Handler signature:**

```zig
// All handlers accept anytype for mock injection
pub fn handlePlay(api: anytype, cmd: CommandMessage, response: *ResponseWriter) void {
    api.runCommand(Command.PLAY);
    response.success(null);
}
```

**CommandContext for handler globals:**

Some handlers need access to shared state beyond the REAPER API (subscriptions, caches, arena allocators). These are consolidated into a single `CommandContext` struct in `commands/mod.zig`:

```zig
pub const CommandContext = struct {
    toggle_subs: ?*ToggleSubscriptions = null,
    notes_subs: ?*NotesSubscriptions = null,
    guid_cache: ?*GuidCache = null,
    track_subs: ?*TrackSubscriptions = null,
    tiered: ?*TieredArenas = null,
};

pub var g_ctx: CommandContext = .{};
```

Handlers access these via `mod.g_ctx`:

```zig
pub fn handleSubscribe(_: anytype, cmd: CommandMessage, response: *ResponseWriter) void {
    const subs = mod.g_ctx.track_subs orelse {
        response.err("NOT_INITIALIZED", "Track subscriptions not initialized");
        return;
    };
    // ... use subs
}
```

`main.zig` sets these fields during initialization and clears them on cleanup.

**Testing with MockBackend:**

```zig
test "transport/play runs correct command" {
    var mock = MockBackend{};
    var response = TestResponseWriter{};
    transport.handlePlay(&mock, .{}, &response);
    try testing.expectEqual(Command.PLAY, mock.last_command);
}
```

### Library Choice

**websocket.zig** (github.com/karlseguin/websocket.zig):

- Uses epoll (Linux) / kqueue (macOS) for non-blocking I/O
- Thread-safe `conn.write()` and `server.stop()`
- Falls back to blocking mode on Windows

## Data Flow

1. **Extension polls REAPER** (~30ms timer in main.zig)
   - Calls `tracks.State.pollIndices(api, indices)` → iterates subscribed tracks only
   - Calls `tracks.MeteringState.poll(api)` → gets peak levels for subscribed tracks
   - Compares with previous state for change detection

2. **Extension broadcasts JSON** via WebSocket (two separate events)
   ```json
   // tracks event (only when data changes)
   {
     "type": "event",
     "event": "tracks",
     "payload": {
       "total": 847,
       "tracks": [{"idx": 0, "guid": "master", "name": "MASTER", "volume": 1.0, ...}]
     }
   }

   // meters event (30Hz, map keyed by GUID)
   {
     "type": "event",
     "event": "meters",
     "m": {"master": {"i": 0, "l": 0.5, "r": 0.45, "c": false}}
   }
   ```

3. **Frontend receives** in `WebSocketConnection.ts` → dispatches to store

4. **Store processes** in `handleWebSocketMessage()`:
   - `tracks` event: Converts `WSTrack` → `Track` objects, builds flags bitfield
   - `meters` event: O(1) lookup by GUID, updates meter state directly

5. **React components** consume via hooks (`useTrack`, `useTracks`, `useMeter`)

### Viewport-Driven Track Subscriptions

Large projects (1000+ tracks) cannot poll all tracks at 30Hz — the JSON alone would be megabytes per second. The extension uses a **subscription-based** model where clients declare which tracks they need.

**Architecture:**

```
┌─────────────────────┐     ┌──────────────────────┐
│  TrackSkeleton      │     │  TrackSubscriptions  │
│  (1Hz LOW tier)     │     │  (per-client state)  │
│                     │     │                      │
│  Poll name + GUID   │────►│  Range mode: [0..31] │
│  for ALL tracks     │     │  GUID mode: [guids]  │
│  Broadcast on change│     │                      │
└─────────────────────┘     └──────────────────────┘
          │                            │
          ▼                            ▼
┌─────────────────────┐     ┌──────────────────────┐
│  GuidCache          │     │  Selective Polling   │
│  (rebuild on change)│     │  (30Hz HIGH tier)    │
│                     │     │                      │
│  GUID → track ptr   │────►│  Only poll tracks    │
│  O(1) lookup        │     │  with subscriptions  │
└─────────────────────┘     └──────────────────────┘
```

**Key components:**

| Component | File | Purpose |
|-----------|------|---------|
| `TrackSkeleton` | `track_skeleton.zig` | Lightweight list (name + GUID) for all tracks. Polled at 1Hz. |
| `TrackSubscriptions` | `track_subscriptions.zig` | Per-client track subscription state. Range or GUID mode. |
| `TimelineSubscriptions` | `timeline_subscriptions.zig` | Per-client time-range subscriptions for items. |
| `GuidCache` | `guid_cache.zig` | O(1) GUID → track pointer lookup for write commands. |

**Subscription modes:**

1. **Range mode** — Client subscribes to index slots `[start, end]`. For scrollable mixer views where tracks slide in/out as user scrolls.

2. **GUID mode** — Client subscribes to specific track GUIDs. For filtered views where track set is stable but positions may change.

**Grace period:** 500ms. When a track leaves the viewport, it stays subscribed briefly for smoother scroll UX.

**Force broadcast on subscribe:** When a client subscribes (or updates their subscription), the `force_broadcast` flag is set. The poll loop checks this flag and broadcasts the current track state unconditionally on the next cycle. This ensures new subscribers receive data immediately without waiting for track state to change. Without this, a page refresh could leave tracks in a "loading" state indefinitely if the track data hadn't changed since the previous session.

**Write commands with GUIDs:** During fader gestures, the user might reorder tracks. If the client sends `trackIdx=5` but the user just moved that track to position 8, the wrong track gets modified. Use `trackGuid` parameter instead — GUIDs are stable across reordering.

**Total count:** The `tracks` event includes `total` (user tracks only, excludes master) so clients can render accurate virtual scrollbars even when only receiving a subset of tracks.

### Timeline Subscriptions (Items Only)

Timeline subscriptions provide **per-client filtering** for items based on time range. Markers and regions are **broadcast to all clients** (no subscription required).

**Commands:**
- `timeline/subscribe` — Subscribe to items for a time range, receive filtered `items` events at 5Hz
- `timeline/unsubscribe` — Clear items subscription for this client

**Frontend-calculated buffer:** The frontend specifies the exact range it wants, including any buffer:
```javascript
const buffer = viewportEnd - viewportStart;  // 100% of visible duration
const start = Math.max(0, viewportStart - buffer);
const end = viewportEnd + buffer;
ws.send({ command: "timeline/subscribe", timeRange: { start, end } });
```

**Markers/regions (broadcast):** Sent automatically to all clients in the snapshot on connect, then on change at 5Hz. No subscription required.

**Items (subscription required):** Requires `timeline/subscribe` with time range. Items overlapping the subscribed range are sent at 5Hz when changed.

**Per-client change detection:** Each client has its own hash tracking for items. Events are only sent when the filtered data actually changes (or on initial subscription via `force_broadcast`).

### Tile-Based Peaks/Waveform System

The waveform rendering system uses a **tile-based LOD architecture** with a Lua bridge for peak data fetching.

**Architecture:**

```
┌─────────────────────┐     ┌──────────────────────┐     ┌───────────────────┐
│  Frontend           │     │  Zig Extension       │     │  Lua Bridge       │
│                     │     │                      │     │                   │
│  peaks/subscribe    │────►│  peaks_subscriptions │────►│  Main_OnCommand   │
│  with viewport      │     │  Tile generation     │     │  fetch_peaks.lua  │
│                     │◄────│  JSON broadcast      │◄────│  GetMediaItemTake │
│  TileBitmapCache    │     │  per-client state    │     │  _Peaks API       │
└─────────────────────┘     └──────────────────────┘     └───────────────────┘
```

**8-Level LOD System:**

| LOD | Peaks/sec | Tile Duration | Use Case |
|-----|-----------|---------------|----------|
| 7   | 1024      | 0.5s          | Finest zoom (1-3s viewport) |
| 6   | 256       | 1s            | Close zoom |
| 5   | 64        | 4s            | Medium zoom |
| 4   | 16        | 16s           | Default view |
| 3   | 4         | 64s           | Zoomed out |
| 2   | 1         | 256s          | ~4 min view |
| 1   | 0.25      | 1024s         | ~17 min view |
| 0   | 0.0625    | 4096s         | Coarsest (~1hr+ viewport) |

Adjacent LODs have a 4x ratio, enabling smooth fallback rendering when exact LOD tiles aren't cached.

**Lua Bridge (`Scripts/Reamo/reamo_internal_fetch_peaks.lua`):**

The Zig extension cannot directly call `GetMediaItemTake_Peaks` reliably on ARM64 macOS due to ABI issues with REAPER's function pointer casting. The workaround uses a Lua script called synchronously via `Main_OnCommand`:

1. Zig sets request parameters via custom API functions (`Reamo_GetPeakRequest*`)
2. Zig triggers the Lua script via `Main_OnCommand`
3. Lua calls `GetMediaItemTake_Peaks` and packs results into binary
4. Lua passes data back via `Reamo_ReceivePeakData`
5. Zig signals completion via `Reamo_SetPeakRequestComplete`

**Key implementation details:**

- **Root source traversal:** Items with take offsets have wrapper sources that return 0 peaks. The Lua script traverses via `GetMediaSourceParent` to find the root source.
- **Retry with BuildPeaks:** If initial fetch returns 0 peaks, tries `PCM_Source_BuildPeaks` then retries.
- **Always request 2 channels:** `GetMediaSourceNumChannels` is unreliable on ARM64. Request stereo, detect mono by comparing L/R.
- **Stereo rendering:** L channel in top half, R channel in bottom half. Mono files render centered.

**Frontend tile caching:**

- `TileBitmapCache`: Pre-renders tiles to `ImageBitmap` via `OffscreenCanvas`, LRU eviction at 200 bitmaps (~50MB)
- Per-track canvases (not per-item) — eliminates DOM overhead for projects with many items
- Never-clear rendering — only clear item rects before redraw to prevent flash-to-black
- Synchronous fallback — draw peaks directly when `ImageBitmap` not cached
- 1x DPR rendering — 4x memory savings vs retina (waveforms don't need subpixel precision)

**Key files:**

| File | Purpose |
|------|---------|
| `peaks_subscriptions.zig` | Per-client subscription state, tile generation orchestration |
| `Scripts/Reamo/reamo_internal_fetch_peaks.lua` | Lua bridge for `GetMediaItemTake_Peaks` |
| `frontend/src/store/slices/peaksSlice.ts` | Tile cache with LRU eviction, `assemblePeaksForViewport()` |
| `frontend/src/components/Timeline/TileBitmapCache.ts` | ImageBitmap pre-rendering |
| `frontend/src/components/Timeline/WaveformCanvas.tsx` | Per-track canvas rendering |

**Reference:** [research/ADAPTIVE_WAVEFORM_ZOOM.md](research/ADAPTIVE_WAVEFORM_ZOOM.md)

### FX Subscriptions

Two subscription types for FX data, following the same per-client pattern as tracks and peaks.

**FX Chain Subscription (`trackFx/subscribe`):**

Subscribe to a track's FX chain to receive real-time updates when plugins are added, removed, reordered, or presets change.

```json
// Request
{"type": "command", "command": "trackFx/subscribe", "trackGuid": "{...}", "id": "1"}

// Event (pushed at 5Hz when changed)
{
  "type": "event",
  "event": "trackFxChain",
  "payload": {
    "trackGuid": "{...}",
    "fx": [
      {"fxGuid": "{...}", "name": "ReaEQ", "presetName": "Default", "enabled": true}
    ]
  }
}
```

**FX Parameter Subscription (`trackFxParams/subscribe`):**

Subscribe to parameter values for a specific FX plugin. Supports two modes:

- **Range mode:** Subscribe to parameter indices `[start, end]` for virtual scrolling
- **Indices mode:** Subscribe to specific indices for filtered parameter lists

```json
// Range mode
{"command": "trackFxParams/subscribe", "trackGuid": "{...}", "fxGuid": "{...}",
 "range": {"start": 0, "end": 20}, "id": "1"}

// Indices mode (sparse subscription)
{"command": "trackFxParams/subscribe", "trackGuid": "{...}", "fxGuid": "{...}",
 "indices": [0, 5, 12, 47], "id": "1"}
```

**Gesture support for FX params:** FX parameter changes use the same gesture wrapping as other continuous controls. Frontend sends `gesture/start` before drag, `gesture/end` after release. Undo coalesces into single "REAmo: Adjust FX parameters" entry.

**Key files:**

| File | Purpose |
|------|---------|
| `trackfx_subscriptions.zig` | FX chain subscription state |
| `trackfxparam_subscriptions.zig` | FX param subscription state |
| `trackfxparam_generator.zig` | JSON generation with nameHash for skeleton invalidation |
| `commands/trackfx_subs.zig` | Chain subscribe/unsubscribe handlers |
| `commands/trackfxparam_subs.zig` | Param subscribe/unsubscribe handlers |
| `frontend/src/store/slices/fxChainSlice.ts` | FX chain state |
| `frontend/src/store/slices/fxParamSlice.ts` | FX param state with LRU skeleton cache |

### Routing Subscriptions

The Routing Modal uses a subscription for real-time send/receive/hardware output updates during fader drags.

**Commands:**
- `routing/subscribe` — Subscribe to a track's routing state (sends, receives, hw outputs)
- `routing/unsubscribe` — Clear subscription

**Why subscription vs on-demand:** The previous approach of fetching after each change caused visible lag when dragging send faders. The subscription pushes updates at 30Hz, matching mixer fader responsiveness.

**Hardware output gesture tracking:** CSurf doesn't support `category=1` (hardware outputs) — `CSurf_OnSendVolumeChange` only works for category=0 sends. Hardware output undo relies on gesture tracking with a shared undo block (see Common Pitfalls #22).

**Key files:**

| File | Purpose |
|------|---------|
| `routing_subscriptions.zig` | Per-client subscription state |
| `routing_generator.zig` | JSON generator for routing_state events |
| `frontend/src/store/slices/routingSlice.ts` | Routing subscription state |

## CSurf Push-Based Architecture

The extension uses REAPER's **IReaperControlSurface** (CSurf) API to receive push-based callbacks when state changes, reducing latency from polling intervals to near-instant (<33ms).

### What CSurf Actually Achieves

The original plan claimed 99% API call reduction — **this was not implemented** because research showed filtering polling by dirty flags is unsafe (callback gaps would cause missed updates). Instead, we kept full polling and use dirty flags for latency optimization.

**Tangible benefits:**

| Benefit | Before | After |
|---------|--------|-------|
| Marker/region change latency | 200ms (5Hz MEDIUM tier) | <33ms when callback fires |
| Tempo change latency | 1000ms (1Hz LOW tier) | <33ms when callback fires |
| Change detection | Fragile slice comparison | Robust hash comparison |
| Debugging | Blind to missed updates | Drift logging shows callback gaps |

**FX and sends dirty flags:** The main loop now consumes `fx_dirty` and `sends_dirty` bitsets from CSurf callbacks (`SETFXPARAM`, `SETFXENABLED`, `SETSENDVOLUME`, etc.) to force immediate broadcast when FX params or send levels change. This provides instant latency response in addition to hash-based change detection.

### Why Hybrid, Not Pure Callbacks

Research and production experience (SWS, MCU, HUI, ReaLearn) confirmed that pure callback-driven architectures don't work reliably. CSurf has documented gaps:

- `OnTrackSelection()` doesn't fire for action/API-based selection
- `CSURF_EXT_SETFXCHANGE` doesn't fire when dragging FX between tracks
- Undo/redo has no dedicated callback
- Project tab switching only triggers `SetTrackListChange()`

**Solution:** Callback-primary with polling safety net. Trust callbacks for immediate response, use dirty flags for instant latency, run hash-based comparison to catch drift.

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  REAPER IReaperControlSurface Callbacks                         │
│  SetPlayState(), SetSurfaceVolume(), SetTrackListChange(), etc. │
└────────────────────────────┬────────────────────────────────────┘
                             │ Push (main thread)
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│  C++ Shim (zig_control_surface.cpp)                             │
│  Forwards virtual calls to Zig function pointers                │
└────────────────────────────┬────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│  DirtyFlags (csurf_dirty.zig)                                   │
│  - Per-track: track_dirty, fx_dirty, sends_dirty (BitSet 1024)  │
│  - Global: transport_dirty, skeleton_dirty, markers_dirty       │
│  - reverse_map_valid: guard against stale pointers              │
└────────────────────────────┬────────────────────────────────────┘
                             │ Consumed every frame
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│  Main Loop (doProcessing @ 30Hz)                                │
│  1. Consume dirty flags → force immediate polling/broadcast     │
│  2. Skeleton rebuild if dirty (before track flag consumption)   │
│  3. Poll all subscribed tracks, hash-based change detection     │
│  4. Broadcast if hash changed OR dirty flag set                 │
│  5. 2-second heartbeat sets all_dirty (safety net)              │
└─────────────────────────────────────────────────────────────────┘
```

### Key Design Decisions

1. **`csurf_inst` registration** — Uses `plugin_register("csurf_inst", ...)` not `"csurf"`. Surface auto-activates on plugin load, never appears in Preferences, requires zero user configuration.

2. **Dirty flags, not direct broadcast** — Callbacks set flags; main loop consumes them. Avoids race conditions and maintains single source of truth (polling).

3. **Poll ALL subscribed tracks, use flags for latency** — We do NOT filter polling by dirty bits. Callback gaps would cause missed updates. Instead, dirty flags force immediate broadcast even if hash unchanged.

4. **Hash-based change detection** — Wyhash of all 19 track fields that appear in JSON. Catches any drift from missed callbacks. Cost: ~0.0008% CPU at 30Hz.

5. **2-second heartbeat** — SWS-validated interval. Sets `all_tracks_dirty` to force full comparison, catching ReaScript changes and rapid undo/redo.

6. **Reverse map validity guard** — Between `SetTrackListChange` and rebuild, track pointers are stale. Callbacks check `reverse_map_valid` and bail early if false.

7. **Always return 0 from Extended()** — Per SWS best practice, never consume callbacks. Return value semantics are undocumented.

### What Still Polls (No Callback Exists)

| State | Polling Rate | Notes |
|-------|--------------|-------|
| Playhead position | 30Hz | Core transport display |
| Peak meters | 30Hz | No CSurf metering callback |
| Edit cursor / time selection | 30Hz | No callback |
| Undo state | 5Hz | No callback |
| Project length | 1Hz | Rarely changes |

### Key Files

| File | Purpose |
|------|---------|
| `zig_control_surface.cpp` | C++ shim implementing IReaperControlSurface |
| `zig_control_surface.h` | Callback typedefs and struct |
| `csurf.zig` | Zig module wiring callbacks to dirty flags |
| `csurf_dirty.zig` | DirtyFlags struct with BitSet(1024) per-track granularity |
| `guid_cache.zig` | Includes reverse_map (track pointer → index) for callback resolution |

### Build Options

CSurf is enabled by default. To disable for debugging:

```bash
zig build -Dcsurf=false    # Reverts to pure polling
make extension             # Uses default (CSurf enabled)
```

### Debugging CSurf Issues

**Drift logging:** When hash changes without a dirty flag, the extension logs a warning. This indicates a missed callback (common causes: undo/redo, action-based selection, FX drag).

**Symptoms of callback gaps:**
- State changes not reflected until 2-second heartbeat
- Drift warnings in logs: `"Track drift without dirty flag"`

**If CSurf causes issues:** Build with `-Dcsurf=false` to isolate. The extension gracefully falls back to pure time-based polling.

See `docs/architecture/CSURF_MIGRATION.md` for full implementation plan and research references.

## Conventions

### Undo Blocks

All REAPER undo blocks must be prefixed with "REAmo: " for easy identification in REAPER's undo history:

```zig
api.undoBeginBlock();
// ... make changes ...
api.undoEndBlock("REAmo: Adjust time signature");
```

### Command Naming

WebSocket commands use `domain/action` format:
- `track/setVolume`, `track/setMute`, `track/setSelected`
- `transport/play`, `transport/stop`, `transport/seek`
- `meter/clearClip`
- `marker/update`, `marker/delete`

## REAPER API Critical Knowledge

### Track Indexing

REAPER's C API has a **strict separation** between master and user tracks:

```zig
// GetTrack(project, 0) returns FIRST USER TRACK, not master!
// GetMasterTrack(project) returns the master track

// We use "unified indexing" to match HTTP API convention:
// idx 0 = master, idx 1+ = user tracks
pub fn getTrackByUnifiedIdx(self: *const Api, idx: c_int) ?*anyopaque {
    if (idx == 0) {
        return self.masterTrack();
    } else {
        return self.getTrackByIdx(idx - 1);
    }
}
```

**CountTracks()** returns user track count only (excludes master).

### Key API Functions

```c
// Transport & Time Selection
int GetPlayState();                              // &1=playing, &2=paused, &4=recording
double GetPlayPosition();                        // Playback position (seconds)
double GetCursorPosition();                      // Edit cursor position (seconds)
void GetProjectTimeSignature2(proj, &bpm, &num, &denom);  // Direct BPM!
void GetSet_LoopTimeRange2(proj, isSet, isLoop, &start, &end, allowAuto);
int GetProjectStateChangeCount(proj);            // Change detection
```

### Custom Colors

`I_CUSTOMCOLOR` uses bit 24 (0x01000000) as an "enabled" flag:

```zig
const raw = GetMediaTrackInfo_Value(track, "I_CUSTOMCOLOR");
const CUSTOM_COLOR_FLAG: c_int = 0x01000000;
if ((raw & CUSTOM_COLOR_FLAG) == 0) {
    return 0; // No custom color - uses theme default
}
return raw; // Has custom color (includes the flag bit)
```

Without this check, you get garbage theme colors (e.g., 0x00C04000 orange-red) instead of 0.

**Cross-platform note**: Use `ColorToNative()`/`ColorFromNative()` for RGB conversion. Windows uses RGB order, macOS uses BGR in the lower 24 bits.

### Master Track Mute/Solo

`GetMediaTrackInfo_Value(track, "B_MUTE")` and `I_SOLO` are **unreliable for the master track**. They often return stale or incorrect values.

**For reading:** Use `GetMasterMuteSoloFlags()` which returns a bitmask:
- `&1` = master muted
- `&2` = master soloed

**For writing:** Use the CSurf API (`CSurf_OnMuteChange`, `CSurf_OnSoloChange`) instead of `SetMediaTrackInfo_Value`. These also enable gang mute/solo support (respects track grouping when `allowGang=true`).

```zig
// Reading master mute/solo (reliable)
const flags = api.getMasterMuteFlags();
const is_muted = (flags & 1) != 0;
const is_soloed = (flags & 2) != 0;

// Writing mute/solo (works for all tracks including master)
api.csurfSetMute(track, mute, true);  // allowGang=true
api.csurfSetSolo(track, solo, true);
```

### Metering

- `Track_GetPeakInfo(track, channel)` → **post-fader linear amplitude** (1.0 = 0dB)
- `Track_GetPeakHoldDB(track, channel, clear)` → peak hold in dB, sticky until cleared
- **No pre-fader metering API exists** - this is a known REAPER limitation

Convert linear to dB: `dB = 20 * log10(linear)`

### Audio Peaks / Waveform Data

**GetMediaItemTake_Peaks is unreliable via Zig FFI on ARM64 macOS** — The function works in Lua but fails intermittently when called via Zig's C FFI. This appears to be an ABI issue with how REAPER's `GetFunc()` casts function pointers on Apple Silicon. The workaround uses a Lua bridge script. See the Tile-Based Peaks System section for details.

**GetMediaSourceNumChannels is unreliable** — returns 1 for stereo files in many cases. This is a known REAPER bug. Do NOT rely on it for mono/stereo detection.

**Workaround:** Always request 2 channels and detect mono vs stereo by comparing L/R channel data:

```zig
// Always request stereo from AudioAccessor
const num_channels: usize = 2;

// After reading peaks, detect actual channel count
const detected_channels: usize = blk: {
    const epsilon = 0.0001;
    for (0..num_peaks) |i| {
        if (@abs(peak_max[i * 2] - peak_max[i * 2 + 1]) > epsilon or
            @abs(peak_min[i * 2] - peak_min[i * 2 + 1]) > epsilon) {
            break :blk 2; // Different L/R = true stereo
        }
    }
    break :blk 1; // All L/R identical = mono (or dual mono)
};
```

**GetMediaItemTake_Peaks** also has issues — returns all zeros for some source types. We use `AudioAccessor` (`CreateTakeAudioAccessor` / `GetAudioAccessorSamples`) instead, which reads actual audio samples reliably.

**AudioAccessor approach:**
1. `CreateTakeAudioAccessor(take)` - create accessor
2. `GetAudioAccessorSamples(accessor, samplerate, numchannels, starttime, numsamplespersec, samplebuffer)` - read raw samples
3. Compute min/max peaks from sample windows
4. `DestroyAudioAccessor(accessor)` - cleanup

### Track Selection

To get/set track selection:
```c
// Get: returns 1.0 if selected, 0.0 if not
double selected = GetMediaTrackInfo_Value(track, "I_SELECTED");

// Set:
SetMediaTrackInfo_Value(track, "I_SELECTED", 1.0);  // select
SetMediaTrackInfo_Value(track, "I_SELECTED", 0.0);  // deselect
```

## Frontend Conventions

### Volume/Meter Conversion

```typescript
// volume.ts - key functions:
volumeToDb(linear)      // Linear amplitude → dB (1.0 → 0dB)
dbToVolume(dB)          // dB → linear amplitude
volumeToFader(linear)   // Linear → fader position (0-1, logarithmic)
faderToVolume(pos)      // Fader position → linear
```

### Color Conversion

```typescript
// color.ts
reaperColorToHex(color)     // 0x01RRGGBB → "#rrggbb" or null if 0
reaperColorToRgb(color)     // → {r, g, b} or null
getContrastColor(color)     // → "black" or "white" for text
```

### Track Flags

The `Track.flags` bitfield (built from WebSocket booleans):
```typescript
const TrackFlags = {
  FOLDER: 1,
  SELECTED: 2,
  HAS_FX: 4,          // Inverted: fxEnabled=false sets this
  MUTED: 8,
  SOLOED: 16,
  RECORD_ARMED: 64,
  RECORD_MONITOR_ON: 128,
  RECORD_MONITOR_AUTO: 256,
};
```

### Connection Hook Pattern

**Always use `useReaper()` in components** to access the WebSocket connection. Never call `useReaperConnection()` directly — it creates a new WebSocket connection each time.

```typescript
// CORRECT - uses shared connection from context
import { useReaper } from '../../components/ReaperProvider';
const { connected, sendCommand, sendCommandAsync } = useReaper();

// WRONG - creates a duplicate WebSocket connection!
import { useReaperConnection } from '../../hooks/useReaperConnection';
const { connectionState, sendCommand } = useReaperConnection(); // Don't do this!
```

`useReaperConnection()` is only called once in `ReaperProvider` at the app root. All other components access the connection via `useReaper()` context.

### UI State: Store vs Local

**Use Zustand store** for UI state shared across components (like `mixerLocked`):

```typescript
const mixerLocked = useReaperStore((s) => s.mixerLocked);
```

**Use local `useState`** for UI state scoped to one component (like section collapse):

```typescript
const [mixerCollapsed, setMixerCollapsed] = useState(false);
```

### Collapsible Sections (Studio View)

Studio view uses a unified collapsible sections pattern with state managed in Zustand. All sections (Project, Toolbar, Timeline, Mixer) are wrapped in `<CollapsibleSection>` components.

**State Management:**
```typescript
// Zustand store (studioLayoutSlice)
interface SectionConfig {
  collapsed: boolean;
  order: number;
}

sections: {
  project: SectionConfig;
  toolbar: SectionConfig;
  timeline: SectionConfig;
  mixer: SectionConfig;
};
```

**Component Pattern:**
```tsx
import { CollapsibleSection } from './components/Studio';

// In StudioView
const { sections, toggleSection } = useReaperStore();

<CollapsibleSection
  id="timeline"
  title="Timeline"
  collapsed={sections.timeline.collapsed}
  onToggle={() => toggleSection('timeline')}
  headerControls={<TimelineHeaderControls />}
>
  <TimelineSection />
</CollapsibleSection>
```

**Mobile Defaults:**
- On first load with viewport ≤768px, only Timeline section is expanded
- Other sections (Project, Toolbar, Mixer) default to collapsed
- Desktop: all sections expanded by default
- State persisted to localStorage per device

**Reordering:**
- Sections can be reordered via Settings → Studio → Reorder Sections
- Modal with drag-and-drop (desktop) and touch support (mobile)
- Order persisted to localStorage

### Disabling Interactive Controls

Pattern for making controls respect a "disabled" state:

1. **Early return in handler** - prevents the action
2. **Visual feedback** - shows the user it's disabled

```typescript
// In handler:
if (mixerLocked) return;

// In className:
className={`... ${mixerLocked ? 'opacity-50 cursor-not-allowed' : 'cursor-pointer'}`}
```

### Icons

The project uses `lucide-react` for icons. Import individually:

```typescript
import { Lock, Unlock, Circle, Headphones } from 'lucide-react';
```

### Tap/Long-Press Gestures

The `useLongPress` hook handles both tap and long-press with proper touch/mouse separation:

```tsx
const { handlers } = useLongPress({
  onTap: () => toggleSelection(),
  onLongPress: () => exclusiveSelect(),
  duration: 400,
});

return <div {...handlers}>Tap or hold me</div>;
```

**Key implementation detail:** Touch devices fire both touch events AND synthesized mouse events. The hook tracks `isTouchRef` to ignore the synthetic mouse events that follow touch events, preventing double-triggers. After a touch interaction ends, there's a 300ms window where mouse events are blocked.

### React Hooks Placement

**All hooks must be called unconditionally before any early returns.** React requires hooks to be called in the same order on every render. Placing a `useEffect` after an early return causes React error #310: "Rendered more hooks than during the previous render."

```tsx
// BAD: Hook after early return
function MyComponent({ mode }) {
  if (mode === 'disabled') return null;  // Early return

  useEffect(() => { /* cleanup */ }, []);  // ❌ Not called when disabled!
  return <div>...</div>;
}

// GOOD: Hook before early return
function MyComponent({ mode }) {
  useEffect(() => { /* cleanup */ }, []);  // ✅ Always called

  if (mode === 'disabled') return null;
  return <div>...</div>;
}
```

This is especially important for components that switch between modes (e.g., RegionInfoBar switching between navigate and regions mode).

### Touch Instruments (MIDI Input)

The Instruments view provides touch-based MIDI input via drum pads, piano keyboard, and chord strips.

**Backend commands:**

| Command | Parameters | Notes |
|---------|------------|-------|
| `midi/noteOn` | `channel`, `note`, `velocity` | Velocity 0 = note-off |
| `midi/cc` | `channel`, `cc`, `value` | Continuous controller (e.g., mod wheel) |
| `midi/pitchBend` | `channel`, `value` | 14-bit pitch bend (-8192 to 8191) |

All MIDI commands use **VKB mode** (mode 0) which routes to the armed track's virtual keyboard input. This achieves 5-15ms latency, matching Logic Remote.

**Pointer Events API for multi-touch:**

Touch instruments use Pointer Events (not Touch Events) for unified mouse/touch handling with proper multi-touch support:

```tsx
const activePointers = useRef<Map<number, number>>(new Map()); // pointerId → note

const handlePointerDown = (e: React.PointerEvent, note: number) => {
  e.preventDefault();
  (e.target as HTMLElement).setPointerCapture(e.pointerId);
  activePointers.current.set(e.pointerId, note);
  sendCommand('midi/noteOn', { channel, note, velocity: 100 });
};

const handlePointerUp = (e: React.PointerEvent) => {
  const note = activePointers.current.get(e.pointerId);
  if (note !== undefined) {
    sendCommand('midi/noteOn', { channel, note, velocity: 0 }); // Note-off
    activePointers.current.delete(e.pointerId);
  }
};

// On each pad element:
<div
  onPointerDown={(e) => handlePointerDown(e, note)}
  onPointerUp={handlePointerUp}
  onPointerCancel={handlePointerUp}
  style={{ touchAction: 'none' }}  // Prevent browser gestures
/>
```

**Key patterns:**

- **`setPointerCapture()`** — Ensures pointer events continue to fire on the originating element even if finger slides off
- **`touchAction: 'none'`** — Prevents browser scroll/zoom gestures from interfering
- **`pointerId` tracking** — Maps each touch point to its note for correct note-off when released
- **Velocity 0 for note-off** — Standard running status optimization, no separate `midi/noteOff` command needed

**Orientation locking:**

Some instruments work better in specific orientations:
- Drum Pads: Portrait only (4x4 grid fits better)
- Piano/Chord Strips: Landscape only (needs horizontal space)

Components show a "rotate device" warning when in wrong orientation rather than rendering a cramped layout.

**Per-instrument channel persistence:**

Each instrument type remembers its own MIDI channel independently:
```typescript
localStorage.setItem('reamo_instruments_drums_channel', '9');  // Channel 10 (0-indexed)
localStorage.setItem('reamo_instruments_piano_channel', '0');  // Channel 1
```

**Key files:**

| File | Purpose |
|------|---------|
| `views/instruments/InstrumentsView.tsx` | Main view with instrument/channel selectors |
| `components/Instruments/DrumPadGrid.tsx` | 4x4 drum grid with GM mapping |
| `components/Instruments/PianoKeyboard.tsx` | 2-octave keyboard with expression |
| `components/Instruments/ChordStrips.tsx` | Diatonic chord strips with inversions |
| `extension/src/commands/midi.zig` | Backend MIDI command handlers |

### Transport Animation (60fps Interpolation)

For smooth playhead and time display updates, we use client-side interpolation via `TransportAnimationEngine`. This avoids React re-renders for high-frequency position updates.

**Pattern:** Use refs + direct DOM manipulation instead of state:

```tsx
import { useRef } from 'react';
import { useTransportAnimation } from '../../hooks';

function SmoothPosition() {
  const ref = useRef<HTMLSpanElement>(null);

  useTransportAnimation((state) => {
    if (ref.current) {
      ref.current.textContent = state.position.toFixed(2);
    }
  }, []);

  return <span ref={ref}>0.00</span>;
}
```

**Key files:**
- `core/TransportAnimationEngine.ts` - Singleton engine, receives server updates, interpolates at 60fps
- `hooks/useTransportAnimation.ts` - Hook to subscribe to engine updates
- `TimelinePlayhead.tsx`, `TimeDisplay.tsx` - Components using this pattern

**When to use:** Any UI element that displays transport position during playback and needs smooth visual updates.

#### Transport Event Architecture

The extension sends **two types of transport events** to minimize bandwidth while maintaining accurate display:

| Event | Size | Trigger | Contains |
|-------|------|---------|----------|
| `transport` | ~350 bytes | State changes (play/pause/stop), seeks when stopped | Full transport state, loop points, project info |
| `tt` (tick) | ~140 bytes | Position changes during playback (~30Hz) | Position (`p`), beat time (`b`), BPM, time sig (`ts`), bar.beat.ticks (`bbt`) |

**Key insight:** During playback, only `tt` events are sent. If a component only listens to `transport` events, its display will update on play/pause/stop but freeze during playback.

**Event handler wiring in `store/index.ts`:**

```typescript
// Full transport event - state changes
if (isTransportEvent(message)) {
  transportEngine.onServerUpdate(data);  // Animation engine
  // Also updates store state for React components
}

// Lightweight tick event - playback position updates
else if (isTransportTickEvent(message)) {
  const p = message.payload as TransportTickEventPayload;
  transportSyncEngine.onTickEvent(p.t, p.b, p.bpm, p.ts, p.bbt);  // Clock sync engine
  transportEngine.onTickUpdate(p.p, p.bbt);  // Animation engine - position + bar.beat.ticks
}
```

**Critical:** Both `TransportSyncEngine` (for beat display) AND `TransportAnimationEngine` (for time display) must receive `tt` events. Missing either connection causes stale display during playback.

**Why position (seconds) is in `tt` events:**

Client-side interpolation works well for smooth animation but cannot handle seeks. When playlist mode jumps to a new region, the client's interpolated position drifts from reality. The `tt` event's `p` field (position in seconds) allows the animation engine to detect and correct large errors (>250ms = snap, >50ms = smooth correction).

**Timing Race Condition:** The animation engine notifies subscribers synchronously, but React state updates are batched. If your callback uses derived values from React state (like `renderTimeToPercent` which depends on timeline bounds), the callback may see stale values on the first notification.

**Fix pattern:** When derived values change, recalculate position in a `useLayoutEffect`:

```tsx
useLayoutEffect(() => {
  renderTimeToPercentRef.current = renderTimeToPercent;
  // Recalculate with updated bounds
  if (containerRef.current) {
    const state = transportEngine.getState();
    containerRef.current.style.left = `${renderTimeToPercent(state.position)}%`;
  }
}, [renderTimeToPercent]);
```

This ensures position is recalculated when bounds change, not just when the animation engine notifies.

### Clock Synchronization (NTP-Style)

For beat-accurate visual display over WiFi, the app uses NTP-style clock synchronization. This achieves ±15ms visual accuracy — below the 20ms human perception threshold.

**Architecture:**

```
┌─────────────────────┐     ┌──────────────────────┐
│  TransportSyncEngine│     │  lib/transport-sync/ │
│  (Singleton)        │     │                      │
│                     │     │  ClockSync           │
│  60fps animation    │◄───►│  BeatPredictor       │
│  Subscriber pattern │     │  AdaptiveBuffer      │
│  Network monitoring │     │  NetworkState        │
└─────────────────────┘     └──────────────────────┘
```

**Key classes:**

| Class | Purpose |
|-------|---------|
| `ClockSync` | NTP-style offset calculation from server timestamps |
| `BeatPredictor` | Extrapolates beat position from tempo and synced time |
| `AdaptiveBuffer` | Dynamic jitter buffer (35-150ms) based on network quality |
| `NetworkState` | Connection quality tracking (OPTIMAL/GOOD/MODERATE/POOR/DEGRADED) |

**Time base:** Both client and server use Unix epoch time (`Date.now()` on client, `time_precise() * 1000` on server). This is critical — using `performance.now()` would cause trillion-millisecond offset errors since it measures from page load.

**Clock sync flow:**

1. Client sends `clockSync` request with `t0` (client send time)
2. Server responds immediately (bypasses command queue) with `t0`, `t1` (receive), `t2` (send)
3. Client calculates: `RTT = (t3 - t0) - (t2 - t1)`, `offset = ((t1 - t0) + (t2 - t3)) / 2`
4. Offset is slewed gradually (0.5ms/s) to avoid jarring jumps
5. Resync every 5 minutes or when drift exceeds 50ms

**Network Stats Modal:**

Long-press the connection status dot to access real-time sync metrics:

| Metric | Meaning |
|--------|---------|
| RTT | Round-trip time to server (< 1ms on localhost) |
| Jitter | Network variability — how much RTT fluctuates |
| Buffer | Adaptive delay to absorb jitter spikes |
| Offset | Clock difference between client and server |
| Manual Offset | User adjustment ±50ms for perceived sync issues |

**Key files:**

- `frontend/src/core/TransportSyncEngine.ts` — Singleton wiring all sync logic
- `frontend/src/lib/transport-sync/` — Modular sync classes with 72 unit tests
- `frontend/src/components/NetworkStatsModal.tsx` — Advanced sync settings UI
- `extension/src/ws_server.zig` — Clock sync bypass handler (line ~290)

### PWA WebSocket Connection (iOS/Android)

iOS aggressively suspends PWAs after ~5 seconds in background, killing WebSocket connections **without firing `onclose`**. Android gives ~5 minutes before suspension. The extension implements robust reconnection handling for both platforms.

**Key insight:** `readyState === OPEN` lies after iOS suspension — the connection appears open but is dead (a "zombie connection"). The fix uses `visibilitychange` events and application-level heartbeats to detect and recover.

**Architecture (`WebSocketConnection.ts`):**

| Component | Purpose |
|-----------|---------|
| Suspension detection | Tracks `lastActiveTime`, forces reconnect after >10s hidden |
| Application heartbeat | Ping/pong every 10s to detect zombie connections |
| PWA init delay | 200ms delay on cold start for network stack readiness |
| EXTSTATE fetch timeout | 2s timeout prevents hanging if network not ready |
| Visibility handler | Forces health check or reconnect on every page visible event |
| Online/offline events | Safari bug fallback + network change detection |

**Timing constants:**

```typescript
SUSPENSION_THRESHOLD_MS = 10000   // If hidden >10s, assume connection dead
HEARTBEAT_INTERVAL_MS = 10000     // Ping server every 10s when visible
HEARTBEAT_TIMEOUT_MS = 3000       // Pong must arrive within 3s
PWA_INIT_DELAY_MS = 200           // Delay initial connection in standalone mode
```

**Connection banner grace period:**

The `ConnectionBanner` component has a 500ms grace period before showing "Disconnected" on initial load. This accounts for PWA cold start timing (200ms init delay + EXTSTATE fetch + WebSocket handshake).

**Visibility change flow:**

1. User backgrounds PWA → `lastActiveTime` recorded, heartbeat stopped
2. iOS suspends PWA (WebSocket dies silently)
3. User returns → `visibilitychange` fires
4. If >10s suspended → force reconnect (close socket, reset retry state, reconnect)
5. If <10s suspended and connected → send health check ping
6. If <10s suspended and connecting for >3s → force reconnect (stalled connection)
7. If disconnected/error → kick any stalled retry timers, reconnect immediately

**Ping/pong protocol:**

```json
// Client → Server
{"type": "ping", "timestamp": 1704067200000}

// Server → Client (bypasses command queue for low latency)
{"type": "pong", "timestamp": 1704067200000}
```

The `timestamp` field enables RTT measurement for network quality monitoring.

**Key files:**

- `frontend/src/core/WebSocketConnection.ts` — Connection manager with heartbeat and suspension detection
- `frontend/src/hooks/useReaperConnection.ts` — React hook with visibility/online/offline handlers
- `frontend/src/components/ConnectionStatus.tsx` — Banner with grace period
- `extension/src/ws_server.zig` — Ping handler bypassing command queue
- `research/PWA_RESEARCH.md` — Full research on iOS PWA WebSocket behavior

**Testing PWA behavior:**

1. iOS: Add to Home Screen, open PWA, background for >10s, return
2. Expected: Brief "Reconnecting..." then connected within 1-2s
3. Check Safari Web Inspector console for `[WS] Suspended for Xms` logs

### PWA Auto-Update Detection

iOS Safari's aggressive dual-layer caching can serve stale HTML/JS even after the extension updates. The app detects version mismatches and handles updates gracefully.

**Detection:** On each WebSocket connect, the server sends `extensionVersion` and `htmlMtime` in the hello response. Frontend compares against stored values in localStorage.

**Auto-update flow (default):**

1. Version mismatch detected
2. Clear Cache Storage and unregister ServiceWorkers
3. Navigate with cache-busting query param (`?v=timestamp`)
4. Fresh page load stores new version info

**Manual update flow (if `autoUpdateEnabled=false`):**

1. Version mismatch detected
2. Show "New version available" banner
3. User taps banner → triggers hard refresh

**Key files:**

- `frontend/src/utils/versionStorage.ts` — Version tracking and `hardRefresh()`
- `frontend/src/components/UpdateBanner.tsx` — Tap-to-update UI
- `frontend/src/store/slices/connectionSlice.ts` — `updateAvailable` state
- `frontend/src/store/slices/uiPreferencesSlice.ts` — `autoUpdateEnabled` preference

### iOS Safari Cold Start Fix

Safari's NSURLSession has a WebSocket lazy initialization bug: on cold start (PWA or browser), the WebSocket sits in `CONNECTING` state indefinitely with no `onopen`, `onerror`, or `onclose` events firing. A page refresh or navigate-away-and-back fixes it.

**Root cause:** Safari's shared network context isn't initialized on cold start. All JavaScript-observable state (`navigator.onLine`, `document.visibilityState`, `document.hasFocus()`) appears correct — the problem is in WebKit internals.

**Solution:** Hidden iframe pre-connection. Before the main WebSocket connection, create a hidden iframe that attempts its own WebSocket. This warms Safari's shared network context, allowing the main page's subsequent connection to succeed.

**Implementation (`WebSocketConnection.ts` → `warmupViaIframe()`):**

```typescript
// In discoverAndConnect(), for iOS Safari (PWA or browser):
const isIOS = /iPad|iPhone|iPod/.test(navigator.userAgent);
const isSafari = navigator.userAgent.includes('Safari') && !navigator.userAgent.includes('Chrome');
if (isIOS && isSafari) {
  await this.warmupViaIframe(wsUrl);
}

// The warmup method:
private async warmupViaIframe(wsUrl: string): Promise<void> {
  // Creates hidden iframe with inline script
  // Iframe attempts WebSocket, posts message on open/error/timeout
  // Parent waits for message, cleans up iframe, then proceeds
  // 3-second fallback timeout
}
```

**Key insight:** The iframe's WebSocket attempt initializes Safari's network stack. Whether it succeeds or fails doesn't matter — the act of attempting warms the context.

**What didn't work:** HTTP pre-warm, delays (200-1000ms), focus manipulation, aggressive retry strategies, `document.readyState` checks. The issue is in WebKit's internal state, not anything JavaScript can observe or influence directly.

## Testing Conventions

### Philosophy

- **Behavior-driven**: Tests describe user actions and expected outcomes
- **Use fixtures**: `songStructure()`, not inline region arrays
- **Use actions**: `actions.move([0], 5)`, not `store.moveRegion(...)`
- **Find by name**: `findRegion('Intro')`, not `displayRegions[0]`
- **Test outcomes**: "section moves to position 5", not "pendingChanges[0].newStart === 5"

### Avoid

- Don't test internal implementation details
- Don't assert on intermediate state (unless specifically testing state machine)
- Don't write brittle tests that break on refactoring
- Don't duplicate coverage (behavior tests cover what unit tests cover)

### Lessons Learned

1. **Zustand state is synchronous** - Always call `useReaperStore.getState()` fresh after mutations, don't cache the result.

2. **Display indices ≠ region indices** - Regions are sorted by start time for display. Use `_pendingKey` to map back to original indices.

3. **The ripple logic is complex** - "Remove then insert" behavior means moving a region forward causes the region behind it to fill the gap.

4. **Tests should use `findRegion(name)`** - Not `displayRegions[0]` because order changes after moves.

5. **Long-press needs async** - Use `vi.useFakeTimers()` and `vi.advanceTimersByTime()` for testing hold gestures.

6. **Pointer events in JSDOM are limited** - Full gesture testing requires mocking `getBoundingClientRect()`. State integration tests are more reliable. Use Playwright for real gesture testing.

7. **Hooks with timeouts need refs for current values** - If a timeout callback needs the "current" value (not the stale closure value), store it in a ref that's updated on each render. See `usePeakHold` for the pattern.

8. **"Works at 0, breaks at non-zero" is a diagnostic pattern** - Often indicates calculations using stale/default values. Test with non-zero initial state to catch this.

9. **Test initial load with non-zero positions** - Animation/interpolation systems may work during playback but fail on initial load when state hasn't synced yet. The playhead visibility tests in `Timeline.test.tsx` demonstrate this pattern.

10. **Use `_testMode` for E2E connection state control** - Enable test mode early in E2E tests to prevent the real WebSocket from overwriting store state:
    ```typescript
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      store.getState()._setTestMode(true);  // Enable FIRST
      store.setState({ connected: true, ... }); // Then set state
    });
    ```
    Test mode prevents both WebSocket messages AND connection state changes from updating the store, allowing deterministic E2E tests regardless of whether REAPER is running.

11. **MockBackend array sizes cause crashes and giant binaries** - If Zig tests crash with SIGILL or produce 600MB+ binaries, check `reaper/mock/state.zig` constants. Nested arrays (tracks × FX × params) that exceed ~250KB total will overflow the stack. See Common Pitfalls #24 for details.

## Extension Robustness

### Prime Directive: Never Crash REAPER

A crash in our extension = potential data loss for the user. REAPER may have unsaved project changes. The extension must be bulletproof.

### Defensive Programming

**Validate everything at trust boundaries:**

```zig
fn validatePosition(pos: ?f64) ?f64 {
    const p = pos orelse return null;
    if (std.math.isNan(p) or std.math.isInf(p)) return null;
    if (p < 0) return null;
    return p;
}
```

**Safe numeric conversions** - Zig's `@intFromFloat` panics on NaN/Inf:

```zig
fn safeFloatToInt(comptime T: type, val: f64, default: T) T {
    if (std.math.isNan(val) or std.math.isInf(val)) return default;
    const min_val: f64 = @floatFromInt(std.math.minInt(T));
    const max_val: f64 = @floatFromInt(std.math.maxInt(T));
    const clamped = @max(min_val, @min(max_val, val));
    return @intFromFloat(clamped);
}
```

**Always check REAPER API returns for NULL:**

```zig
const item = api.getMediaItem(proj, itemIndex) orelse {
    writer.err("NOT_FOUND", "Item not found");
    return;
};
```

### WebSocket Security

**Host header validation** prevents DNS rebinding attacks where a malicious website could connect to `ws://localhost:9224` via DNS tricks:

```zig
// In Client.init() - validate Host header before accepting connection
const host = h.headers.get("host") orelse {
    conn.close(.{ .code = 4003, .reason = "Missing Host header" }) catch {};
    return error.MissingHost;
};
if (!isValidLocalhost(host)) {
    conn.close(.{ .code = 4003, .reason = "Invalid Host" }) catch {};
    return error.InvalidHost;
}

fn isValidLocalhost(host: []const u8) bool {
    return std.mem.startsWith(u8, host, "127.0.0.1:") or
           std.mem.startsWith(u8, host, "localhost:");
}
```

**Rate-limited error logging** for WebSocket write failures prevents log spam while maintaining visibility:

```zig
// Log first error immediately, then max once per 5 seconds
fn logWriteError(self: *SharedState, err: anyerror) void {
    const count = self.write_error_count.fetchAdd(1, .monotonic) + 1;
    const now = std.time.milliTimestamp();
    const last = self.last_error_log_time.load(.monotonic);
    if ((count == 1) or (now - last >= 5000)) {
        _ = self.last_error_log_time.cmpxchgStrong(last, now, .monotonic, .monotonic);
        logging.warn("WebSocket write error (count={d}): {}", .{ count, err });
    }
}
```

### REAPER Pointer Validation

REAPER pointers can become invalid if the user deletes tracks/items during enumeration. Use `validateTrackPtr`/`validateItemPtr` before dereferencing:

```zig
// In polling loops - validate before use
const track = api.getTrackByUnifiedIdx(idx) orelse continue;
if (!api.validateTrackPtr(track)) continue;  // Track was deleted

// In command handlers - return error to client
const track = api.getTrackByUnifiedIdx(track_idx) orelse {
    response.err("NOT_FOUND", "Track not found");
    return;
};
if (!api.validateTrackPtr(track)) {
    response.err("STALE_POINTER", "Track was deleted");
    return;
}
```

### Graceful Degradation

| Failure | Response |
|---------|----------|
| REAPER API returns unexpected value | Log warning, skip operation, continue |
| JSON parse failure | Return error to client, don't crash |
| Client sends garbage | Disconnect that client, others unaffected |
| Out of memory | Return error to client, don't allocate |
| Stale REAPER pointer | Skip entity or return error to client |

### Memory Management

REAPER timer callbacks run on the **main/UI thread**, not the audio thread. This distinction is critical for memory allocation safety.

| Callback Type | Thread | malloc/free Safe? | Large Stack Alloc Safe? |
|---------------|--------|-------------------|-------------------------|
| Timer (`plugin_register`) | Main/UI | ✅ Yes | ❌ No (nested calls) |
| Audio Hook (`OnAudioBuffer`) | Audio RT | ❌ No | ❌ No |

**Why stack allocation is dangerous in timer callbacks:**

REAPER's startup sequence shows modal dialogs that create deeply nested call stacks (~45+ frames). Timer callbacks fire during these modal states, leaving limited stack space. Zig allocates ALL local variables at function entry, so a function declaring a 128KB buffer needs that space before any code runs. This caused crashes on Finder launch — see `DEBUG_REAPER_CRASH.md`.

**Guidelines:**

1. **Never stack-allocate large buffers** (>1KB) in timer callbacks or functions called from them
2. **Use heap allocation** (`std.heap.c_allocator`) for large temporary buffers — it's safe on the main thread
3. **Prefer per-call allocation** over shared static buffers to avoid reentrancy issues
4. **Use `defer` for cleanup** to ensure buffers are freed on all return paths

**Pattern for large temporary buffers:**

```zig
pub fn handleLargeResponse(self: *ResponseWriter, data: []const u8) void {
    const allocator = std.heap.c_allocator;
    const buf = allocator.alloc(u8, 131072) catch {
        self.err("ALLOC_FAILED", "Failed to allocate buffer");
        return;
    };
    defer allocator.free(buf);

    // Use buf...
    const result = std.fmt.bufPrint(buf, ...) catch return;
    self.shared_state.sendToClient(self.client_id, result);
}
```

**For large persistent state** (like `tracks.State` at ~2.5MB), use static storage via `ProcessingState` — these are allocated once at compile time, not per-call. See `main.zig` for the pattern.

For detailed research on Zig memory patterns in REAPER plugins, see `research/ZIG_MEMORY_MANAGEMENT.md`.

### Tiered Arena Architecture

The extension uses **double-buffered arenas per polling tier** to prevent crashes and support large projects without fixed entity limits.

**The Problem:**

Zig allocates ALL local variables at function entry. Large `State` structs on the stack cause overflow when REAPER's startup creates deeply nested call stacks (~45+ frames during modal dialogs like "missing media" prompts).

**Interim Fix:**

The `pollInto()` pattern wrote to static storage instead of returning by value. This avoided stack allocation but required careful lifetime management.

**Final Solution — Tiered Double-Buffered Arenas:**

```
┌─────────────────────────────────────────────────────────┐
│  TieredArenas (tiered_state.zig)                        │
├─────────────────────────────────────────────────────────┤
│  HIGH tier (30Hz)   - Tracks + meters                   │
│                       Swaps each poll cycle             │
│  MEDIUM tier (5Hz)  - Items, markers, FX, sends         │
│                       Swaps at 5Hz                      │
│  LOW tier (1Hz)     - Tempo map, track skeleton         │
│                       Swaps at 1Hz                      │
│  SCRATCH            - JSON serialization                │
│                       Reset every frame                 │
└─────────────────────────────────────────────────────────┘
```

**Benefits:**

- **Dynamic sizing** — Arenas sized based on actual project entity counts (20MB min, 200MB ceiling)
- **Graceful degradation** — Skip entities when full, never crash
- **No cross-tier pointer dependencies** — Flattened data model prevents dangling pointers when arenas swap
- **Zero fixed limits** — Supports extreme projects (3000 tracks, 10000 items)

**Double-buffering pattern:**

Each tier maintains two arenas. While one is being read by serialization, the other is being written by polling. Swap pointers atomically between frames:

```zig
// In polling loop
const write_arena = tiered.high.getWriteArena();
tracks.pollInto(api, write_arena);
tiered.high.swap();  // Write becomes read, read becomes write
```

See `tiered_state.zig` for implementation and `research/BACKEND_ARENA_RESEARCH.md` for design rationale.

## Protocol & Versioning

### Hello Handshake

Client → Server (on connect):
```json
{
  "type": "hello",
  "clientVersion": "1.2.0",
  "protocolVersion": 1,
  "token": "session-token"
}
```

Server → Client:
```json
{
  "type": "hello",
  "extensionVersion": "1.0.0",
  "protocolVersion": 1
}
```

### Compatibility Rules

| Scenario | Behavior |
|----------|----------|
| Protocol versions match | Normal operation |
| Client protocol > Server | Client shows "Please update REAPER extension" |
| Server protocol > Client | Server sends error, close with 4002 |

### EXTSTATE Discovery

Client discovers WebSocket port via HTTP:

```bash
curl -s "http://localhost:8099/_/GET/EXTSTATE/REAmo/WebsocketPort"
curl -s "http://localhost:8099/_/GET/EXTSTATE/REAmo/SessionToken"
```

## Extension Configuration

### Design Philosophy

Non-technical musicians should never see error dialogs or need to configure ports. The extension should "just work."

- Default port: 9224
- Max attempts: 10 (ports 9224-9233)
- No error dialogs on failure — just a console message
- Stores successful port in EXTSTATE for client discovery

**Never show `MB_OK` error dialogs.** Musicians don't want modal popups interrupting their session.

## Build & Test

```bash
# Build everything (runs tests first, then builds)
make all

# Run all tests (frontend unit + E2E + extension)
make test

# Run individual test suites
make test-frontend    # Vitest unit tests
make test-e2e         # Playwright E2E tests
make test-extension   # Zig unit tests

# Build without tests
make frontend         # Build frontend (copies to reamo.html)
make extension        # Build extension (installs to REAPER UserPlugins)

# Development
make install          # Install frontend npm dependencies

# Extension development cycle (tests → kill REAPER → build → relaunch)
make dev              # Full cycle with tests
make dev-notests      # Quick cycle without tests (for rapid iteration)
```

### Extension Development Workflow

**⚠️ Hot reload is NOT supported for native extensions.** When REAPER loads a `.dylib`, macOS memory-maps the file. Overwriting it while REAPER is running creates a "Frankenstein binary" (part old code, part new) causing impossible-to-debug crashes.

**The only safe workflow is: rebuild → restart REAPER → test.**

Use `make dev` to automate this cycle:
1. Runs all tests (extension + frontend)
2. Kills REAPER
3. Builds and installs extension
4. Relaunches REAPER with stdout attached for debugging

For rapid iteration after tests pass, use `make dev-notests`.

### Tracy Profiler Integration

The extension includes optional [Tracy](https://github.com/wolfpld/tracy) profiler support via [ztracy](https://github.com/ziglang/zig/wiki/ztracy) for diagnosing performance bottlenecks.

```bash
make tracy    # Build with Tracy enabled (requires ReleaseFast due to Zig 0.15 bug)
```

**Instrumented areas:**
- `doProcessing()` — Frame markers for 30Hz timer visibility
- `action/getActions` — Zone markers (identified as slow path, ~985KB JSON)

**When disabled:** ztracy provides no-op stubs, so instrumentation has zero runtime overhead in normal builds.

**Research:** See `research/REAPER_EXTENSION_OPTIMIZATION.md` for memory overhead analysis and `research/REAPER_TIMER_API.md` for timer reentrancy behavior.

## Debugging

### Log Files

Extension logs are written to:
```
~/Library/Application Support/REAPER/Logs/reamo.log  (macOS)
%APPDATA%\REAPER\Logs\reamo.log                      (Windows)
~/.config/REAPER/Logs/reamo.log                      (Linux)
```

Set `REAMO_LOG_LEVEL` environment variable to control verbosity: `err`, `warn`, `info`, `debug`

Log rotation: 1MB max, keeps last 3 files.

### Key Files & Resources

- **REAPER API headers**: `docs/reaper_plugin_functions.h` — authoritative function signatures
- **Frontend types**: `frontend/src/core/types.ts` — command IDs, PlayState enum, protocol definitions
- **Test client**: `extension/test-client.html` — browser-based WebSocket testing

### WebSocket Testing

```bash
# Get token and port
curl -s "http://localhost:8099/_/GET/EXTSTATE/REAmo/SessionToken"
curl -s "http://localhost:8099/_/GET/EXTSTATE/REAmo/WebsocketPort"

# Connect with websocat
TOKEN="<token>"
echo '{"type":"hello","clientVersion":"1.0.0","protocolVersion":1,"token":"'$TOKEN'"}' | \
  websocat ws://localhost:9224

# Send a command
echo '{"type":"command","command":"track/setVolume","trackIdx":1,"volume":0.5,"id":"1"}' | \
  websocat ws://localhost:9224
```

**Multi-command testing (hello + command + wait for response):**

The shell environment may not handle subshells `(...)` directly. Wrap in `/bin/bash -c '...'` and use escaped quotes for JSON:

```bash
# Pattern: hello handshake, then command, then wait for response
/bin/bash -c 'TOKEN="your-token-here"
(echo "{\"type\":\"hello\",\"clientVersion\":\"1.0.0\",\"protocolVersion\":1,\"token\":\"$TOKEN\"}"
 echo "{\"type\":\"command\",\"command\":\"tempo/snap\",\"time\":15.7,\"id\":\"1\"}"
 sleep 0.3) | /opt/homebrew/bin/websocat ws://localhost:9224 2>&1'

# Filter for specific event types
/bin/bash -c 'TOKEN="..."
(echo "{\"type\":\"hello\",...}"
 sleep 0.3) | websocat ws://localhost:9224 2>&1 | grep -m1 "\"event\":\"transport\""'
```

**Key escaping rules inside `/bin/bash -c '...'`:**
- Use `\"` for JSON quotes (not single quotes, since outer command uses them)
- Variables like `$TOKEN` expand normally
- Newlines between `echo` statements are fine

### Enable Debug Logging

In `extension/src/reaper.zig`:
```zig
pub const DEBUG_LOGGING = true;  // Set to true for console output
```

Then check REAPER's console (Actions → Show console).

## WebSocket Compression

**Status:** Blocked on upstream library

The `action/getActions` command returns ~985KB of JSON (15,619 actions across 6 sections). Fine for local WiFi (<1 second) but could benefit from compression.

websocket.zig library has per-message deflate disabled for Zig 0.15. Library author noted: "Compression is disabled as part of the 0.15 upgrade. I do hope to re-enable it soon."

**When library supports it:**
```zig
.compression = .{
    .write_threshold = 256, // Only compress messages > 256 bytes
    .retain_write_buffer = true,
},
```

**Expected:** ~985KB → ~60-80KB compressed.

**Workaround if needed:** Link system zlib via `@cImport`, compress at application layer, send binary frames with gzip magic bytes (`0x1f 0x8b`).

---

## Profiling Strategy

Before optimizing, measure actual impact:

1. **Baseline comparison**: Measure REAPER CPU with extension disabled vs enabled
2. **Per-callback timing**: Add `std.time.Timer` instrumentation to `processTimerCallback`
3. **Callback jitter**: Record actual intervals between callbacks (should be ~33ms ± 5ms)

```zig
var timer = try std.time.Timer.start();
// ... callback work ...
const elapsed_ns = timer.read();
if (elapsed_ns > 1_000_000) { // > 1ms
    log("Slow callback: {}ms", elapsed_ns / 1_000_000);
}
```

**Tracy integration** (optional): Real-time profiling with callstack support. Requires adding TracyClient.cpp to build.

---

## Common Pitfalls

1. **Track index 0 is NOT master in raw REAPER API** - always use `getTrackByUnifiedIdx()`

2. **Color value 0 means "no custom color"** - check the 0x01000000 flag

3. **Meter values are linear amplitude, not dB** - use `volumeToDb()` to convert

4. **Frontend must process `meters` array** - it's not automatically merged into tracks

5. **REAPER must be restarted** after extension changes - it's a native plugin

6. **Pre-fader metering doesn't exist** - Track_GetPeakInfo is always post-fader

7. **Zig `@intFromFloat` panics on NaN/Inf** - always use `safeFloatToInt()` for REAPER API values

8. **`anytype` cannot be used in function pointers** - Zig function pointer types must have concrete signatures. Use comptime tuples with `inline for` dispatch instead (see Testability Architecture section).

9. **New command handlers must be added to registry.zig** - Creating a handler function isn't enough. Add it to `commands/registry.zig`'s `all` tuple for dispatch to find it.

10. **New backend methods need both RealBackend and MockBackend** - If a handler needs a new REAPER API method, add it to both `reaper/real.zig` and `reaper/mock/mod.zig` (or the appropriate mock subdomain file). The `validateBackend()` check will catch missing methods at compile time.

11. **Floating-point precision loss when extracting beat.ticks** - When converting a float like `6.7565` to beat=6, ticks=76, don't divide then modulo. The division `676/100.0 = 6.76` looks correct, but `@mod(6.76, 1.0)` returns `0.7599999998` due to IEEE 754 representation, giving ticks=75 instead of 76. Scale to integer first:
   ```zig
   // BAD: "6.6.75" displayed instead of "6.6.76"
   const rounded = @round(val * 100.0) / 100.0;  // 6.76 (looks fine)
   const frac = @mod(rounded, 1.0);              // 0.7599999998 (precision loss!)
   const ticks = @intFromFloat(frac * 100.0);    // 75 (wrong!)

   // GOOD: integer arithmetic preserves exact values
   const scaled: u32 = @intFromFloat(@round(val * 100.0));  // 676
   const whole = scaled / 100;  // 6 (exact)
   const frac = scaled % 100;   // 76 (exact)
   ```

12. **FFI validation happens in RealBackend, not raw.zig** - `raw.zig` returns exactly what REAPER's C API returns (e.g., `f64`). All NaN/Inf validation happens in `RealBackend` via `ffi.safeFloatToInt()`. Methods returning `FFIError!T` require `catch` handling in callers — use `catch null` for nullable fields to propagate corrupt data as JSON nulls.

13. **Use CSurf APIs for continuous controls (faders/knobs)** - For controls users drag continuously (volume, pan, send levels), use CSurf APIs (`CSurf_OnVolumeChange`, `CSurf_OnPanChange`, `CSurf_OnSendVolumeChange`) instead of `SetMediaTrackInfo_Value`. CSurf APIs provide:
    - Automatic undo coalescing (one undo point per gesture, not per value change)
    - Gang control support (`allowGang=true` respects track grouping)
    - Proper master track handling

    For toggles (mute, solo), CSurf is optional but recommended for consistency.

14. **Gesture tracking requires both backend and frontend coordination** - For proper undo coalescing:
    - **Backend**: Handler calls `gestures.recordActivity(ControlId)` on each value change
    - **Frontend**: Sends `gesture/start` before drag, `gesture/end` after release
    - **Safety nets**: 500ms timeout auto-flushes abandoned gestures; client disconnect cleans up

    When adding new continuous controls, update:
    1. `gesture_state.zig` - Add to `ControlType` enum and constructor
    2. `commands/gesture.zig` - Add parsing in `parseControlId()`
    3. Command handler - Call `gestures.recordActivity()`
    4. `API.md` - Document the new controlType

15. **Compound control IDs need sub_idx** - Controls like sends and hardware outputs require both track index AND send/hw index. The `ControlId` struct has `sub_idx` for this:
    ```zig
    // Track volume: only needs track_idx
    ControlId.volume(track_idx)

    // Send volume: needs track_idx AND send_idx
    ControlId.sendVolume(track_idx, send_idx)
    ControlId.sendPan(track_idx, send_idx)

    // Hardware output: needs track_idx AND hw_idx
    ControlId.hwOutputVolume(track_idx, hw_idx)
    ControlId.hwOutputPan(track_idx, hw_idx)
    ```

16. **Not all controls have CSurf equivalents** - Some controls lack CSurf APIs:
    - **Hardware outputs**: `CSurf_OnSendVolumeChange` only works for category 0 (sends), not category 1 (hardware outputs) — its signature `(track, send_idx, volume, relative)` has no category parameter. Use `SetTrackSendInfo_Value(track, 1, hw_idx, "D_VOL", value)` directly; undo coalescing relies on gesture tracking.
    - **Send mute**: Use `SetTrackSendInfo_Value(track, 0, idx, "B_MUTE", value)` since there's no `CSurf_OnSendMuteChange`.

    Always check `docs/reaper_plugin_functions.h` for available CSurf functions before assuming one doesn't exist — e.g., `CSurf_OnFXChange` exists for FX chain enable and we do use it.

17. **ResponseWriter buffer sizes** - `ResponseWriter.success()` uses a 512-byte buffer, which silently fails (via `catch return`) for large payloads. For commands returning user content (project notes, item peaks, etc.), use `successLargePayload()` which heap-allocates a 128KB buffer per call. This avoids both stack overflow and shared-state issues between concurrent commands. Heap allocation is safe for timer callbacks since they run on the main thread (see `research/ZIG_MEMORY_MANAGEMENT.md`). The silent failure in `success()` causes frontend timeouts with no error in logs — a subtle bug. Rule of thumb: if the response includes user-generated content that could exceed ~400 chars, use `successLargePayload()`.

18. **Never use silent `catch return null` or `catch return;`** - These patterns silently swallow errors, making debugging extremely difficult. When a buffer overflow or serialization error occurs, the frontend sees no response (timeout) and there's nothing in the logs. Always add logging before returning:
    ```zig
    // BAD: Silent failure - impossible to debug
    const payload = std.fmt.bufPrint(&buf, "...", .{...}) catch return;

    // GOOD: Failure is logged - shows up in REAPER console
    const payload = std.fmt.bufPrint(&buf, "...", .{...}) catch {
        logging.warn("myHandler: response format failed", .{});
        return;
    };

    // ACCEPTABLE: Helper function where caller handles null meaningfully
    fn formatValue(buf: []u8, val: i32) ?[]const u8 {
        return std.fmt.bufPrint(buf, "{d}", .{val}) catch null;
    }
    // ...but only if caller does: `formatValue(...) orelse { response.err(...); return; }`
    ```

    **Logging levels for catch blocks:**
    - `logging.err()` — Should never happen, indicates bug
    - `logging.warn()` — Unexpected but recoverable (buffer overflow with real data)
    - `logging.debug()` — Expected in edge cases (very large payloads)

    See `PENDING_ITEMS.md` for remaining items.

19. **Use `toJsonAlloc` with scratch arena for JSON serialization** - All production JSON serialization should use the scratch arena via `toJsonAlloc` rather than fixed stack buffers. This supports extreme projects (3000+ tracks) without buffer overflow:
    ```zig
    // BAD: Fixed buffer - will fail on large projects
    var buf: [65536]u8 = undefined;
    if (state.toJson(&buf)) |json| {
        broadcast(json);
    }

    // GOOD: Dynamic allocation from scratch arena
    const scratch = tiered.scratchAllocator();
    if (state.toJsonAlloc(scratch)) |json| {
        broadcast(json);
    } else |_| {}
    ```

    The scratch arena is sized dynamically based on entity counts (see `tiered_state.zig`). Pattern for adding `toJsonAlloc` to a module:
    ```zig
    pub fn toJsonAlloc(self: *const State, allocator: std.mem.Allocator) ![]const u8 {
        // Estimate size: base overhead + per-item bytes
        const estimated_size = 100 + (self.items.len * 200);
        const buf = try allocator.alloc(u8, estimated_size);
        const json = self.toJson(buf) orelse return error.JsonSerializationFailed;
        return json; // Arena-owned, no free needed
    }
    ```

20. **`@ptrCast` for u8 arrays doesn't need `@alignCast`** - When casting u8 array pointers to `[*:0]const u8` for C strings, `@alignCast` is unnecessary because u8 has alignment 1 (always valid). Add a SAFETY comment to prevent future audit flags:
    ```zig
    var buf: [256]u8 = undefined;
    @memcpy(buf[0..len], str[0..len]);
    buf[len] = 0;
    // SAFETY: @alignCast unnecessary - u8 has alignment 1, always valid
    const c_str: [*:0]const u8 = @ptrCast(&buf);
    ```

21. **Store string IDs for SWS/script actions, numeric IDs for native actions** - REAPER action IDs have different stability guarantees:

    | Action Type | Numeric ID Stable? | String ID | Storage Strategy |
    |-------------|-------------------|-----------|------------------|
    | Native REAPER | ✅ Yes | NULL | Store `"40001"` |
    | SWS Extension | ❌ No | `_SWS_*` | Store `"_SWS_SAVESEL"` |
    | ReaScripts | ❌ No | `_RS*` | Store `"_RS7f8a2b..."` |
    | Custom Actions | ❌ No | `_` + 32 hex | Store `"_113088d1..."` |

    **Why this matters:** SWS/ReaPack/script action numeric IDs are assigned dynamically at REAPER startup and change between sessions. Storing the numeric ID means the wrong action executes after restart. Always use `ReverseNamedCommandLookup` to get the stable string identifier for non-native actions.

    **API quirk:** `ReverseNamedCommandLookup` returns the string **without** the leading underscore. Prepend `_` when storing:
    ```zig
    const raw_id = api.reverseNamedCommandLookup(cmd_id);
    if (raw_id) |id| {
        // id = "SWS_SAVESEL", store as "_SWS_SAVESEL"
        buf[0] = '_';
        @memcpy(buf[1..], id);
    }
    ```

    **Frontend pattern:** Check `actionId.startsWith('_')` to determine execution method:
    ```typescript
    if (action.actionId.startsWith('_')) {
      sendCommand(actionCmd.executeByName(action.actionId, action.sectionId));
    } else {
      sendCommand(actionCmd.execute(parseInt(action.actionId, 10), action.sectionId));
    }
    ```

    **Buffer size:** 128 bytes is safe for all action string IDs (SWS-established limit `SNM_MAX_ACTION_CUSTID_LEN`). Longest observed in practice: 47 characters.

22. **REAPER doesn't support nested undo blocks** - Calling `Undo_BeginBlock2()` twice before `Undo_EndBlock2()` corrupts REAPER's undo state. This matters when multiple clients gesture simultaneously on different controls. See `research/REAPER_UNDO_BLOCKS.md` for detailed findings.

    **For CSurf-based controls** (track volume/pan, send volume/pan): No problem — CSurf handles undo coalescing internally.

    **For non-CSurf continuous controls** (hardware outputs): All gestures must share a single undo block:
    ```zig
    // In gesture.zig handleStart - open block on FIRST hw gesture
    if (is_new and gesture_state.GestureState.isHwOutputControl(control.control_type)) {
        if (gestures.beginHwUndoBlock()) {  // Returns true if count was 0
            api.undoBeginBlock();
        }
    }

    // In gesture.zig handleEnd - close block on LAST hw gesture
    if (gesture_state.GestureState.isHwOutputControl(control.control_type)) {
        if (gestures.endHwUndoBlock()) {  // Returns true if count becomes 0
            api.undoEndBlock("REAmo: Adjust audio hardware outputs");
        }
    }
    ```

    The `GestureState.hw_gesture_control_count` tracks how many distinct hw controls have active gestures. Generic description is used since multiple controls may have been adjusted.

    **When adding new non-CSurf continuous controls:**
    1. Add control type to `ControlId.ControlType` enum
    2. Decide: share existing undo block category OR create new counter (if semantically distinct)
    3. Update `isHwOutputControl()` or add similar helper
    4. Handle cleanup in `main.zig` disconnect and timeout paths

23. **Gesture commands must accept trackGuid for reorder safety** - During a fader gesture, the user might reorder tracks in REAPER. If the frontend sends `trackIdx` and the track moved, the gesture end closes the wrong track's undo. Always use `trackGuid` in gesture commands and resolve via `tracks.resolveTrack()`:
    ```zig
    // gesture.zig parseControlId - accepts EITHER trackIdx or trackGuid
    const resolution = tracks.resolveTrack(api, cmd) orelse return null;
    const track_idx = resolution.idx;  // Resolved index at this moment
    ```

    Frontend sends `trackGuid` when available (preferred), falls back to `trackIdx`:
    ```typescript
    params: {
      controlType,
      ...(trackGuid ? { trackGuid } : { trackIdx }),
      ...(hwIdx !== undefined && { hwIdx }),
    }
    ```

24. **MockBackend array sizes must stay small** - Tests using `MockBackend` will crash with SIGILL or produce 600MB-2GB binaries if array sizes are too large. Root cause: nested arrays like `32 tracks × 64 FX × 128 params` create ~31MB structs that overflow the 8MB stack limit. Also, Zig generates debug symbols for every type instantiation — 262,144 nested generic types explodes debug info to 4GB+.

    **Solution:** Mock constants in `reaper/mock/state.zig` are intentionally small:
    ```zig
    pub const MAX_TRACKS = 16;           // Production: 1024
    pub const MAX_FX_PER_TRACK = 8;      // Production: 64
    pub const MAX_PARAMS_PER_FX = 16;    // Production: 128
    ```

    These only affect `MockBackend` — production uses constants from `constants.zig`.

    **Symptoms of too-large mock arrays:**
    - SIGILL (signal 4) crashes in tests
    - Binaries >100MB (should be ~30MB)
    - Compile time >30s per test file
    - RAM usage >1GB during compilation

25. **GetMediaItemTake_Peaks is unreliable on ARM64 macOS** - The native Zig FFI call to this function fails intermittently due to ABI issues when REAPER casts function pointers via `GetFunc()`. The workaround uses a Lua bridge script (`Scripts/Reamo/reamo_internal_fetch_peaks.lua`) called synchronously via `Main_OnCommand`. See the Tile-Based Peaks System section for architecture details.

26. **Wrapper sources return 0 peaks** - Items with take offsets (e.g., trimmed start) have wrapper sources where `GetMediaItemTake_Source` returns a source with `length=0, samplerate=0`. Always traverse to the root source via `GetMediaSourceParent` loop before fetching peaks or other source properties.
