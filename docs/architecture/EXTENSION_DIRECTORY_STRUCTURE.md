# Extension Directory Structure

This document describes the target directory structure for `extension/src/`, designed for navigability, feature cohesion, and dependency clarity.

## Overview

```
extension/src/
├── commands/        # Command handlers (36 files)
├── reaper/          # REAPER C FFI boundary
├── core/            # Pure types, infrastructure
├── state/           # REAPER state polling + caches
├── subscriptions/   # Per-client subscriptions + generators
├── server/          # Runtime orchestration
├── platform/        # OS-specific + external integrations
├── main.zig         # Entry point
└── reaper.zig       # Root aggregator (re-exports)
```

**6 directories, 2 root files** (down from 42 flat files)

## Directory Responsibilities

### `commands/` (unchanged)

Command handlers dispatched by `mod.zig`. Already well-organized.

```
commands/
├── mod.zig              # dispatch(), CommandContext, ResponseWriter
├── registry.zig         # Comptime tuple of all handlers
├── transport.zig        # transport/play, transport/stop, etc.
├── tracks.zig           # track/setVolume, track/setMute, etc.
├── ... (32 more)
```

### `reaper/` — REAPER C FFI Boundary

Isolates all REAPER API interaction. Contains C/C++ shims for Control Surface.

```
reaper/
├── raw.zig                  # C function pointers (~80 functions)
├── real.zig                 # RealBackend - FFI validation wrapper
├── backend.zig              # validateBackend() comptime check
├── types.zig                # Shared types (BeatsInfo, MarkerInfo, etc.)
├── mock/                    # MockBackend for unit tests
│   ├── mod.zig
│   ├── state.zig
│   ├── transport.zig
│   ├── tracks.zig
│   ├── markers.zig
│   ├── project.zig
│   ├── preferences.zig
│   └── inputs.zig
├── zig_control_surface.cpp  # C++ shim implementing IReaperControlSurface
├── zig_control_surface.h
└── reaper_csurf.h           # REAPER's control surface header
```

### `core/` — Pure Types, Infrastructure

Cross-cutting utilities with no REAPER dependencies. Used by everything.

```
core/
├── protocol.zig     # Zero-allocation JSON parsing
├── constants.zig    # MAX_TRACKS, MAX_ITEMS, etc.
├── errors.zig       # Error types, ErrorCode registry, rate limiting
├── ffi.zig          # safeFloatToInt, roundFloatToInt, isFinite
└── logging.zig      # Ring buffer logging, crash recovery, log levels
```

### `state/` — REAPER State Polling + Caches

Modules that poll REAPER state via `fn poll(api: anytype) -> State` pattern.
Includes caches that provide O(1) lookups into state.

```
state/
├── transport.zig        # Transport state (30Hz HIGH tier)
├── tracks.zig           # Track state + metering (30Hz HIGH tier)
├── markers.zig          # Markers/regions (5Hz MEDIUM tier)
├── items.zig            # Items/takes (5Hz MEDIUM tier)
├── project.zig          # Project-level state
├── tempomap.zig         # Tempo markers (1Hz LOW tier)
├── fx.zig               # FX chain state
├── sends.zig            # Send/receive state
├── track_skeleton.zig   # Lightweight name+GUID list (1Hz LOW tier)
├── playlist.zig         # Playlist entries, loop counts
├── guid_cache.zig       # GUID → track pointer (O(1) lookup)
├── item_guid_cache.zig  # GUID → item pointer (O(1) lookup)
└── peaks_tile.zig       # Tile LOD math, TileKey (pure calculations)
```

> **Note:** `peaks_tile.zig` is pure math with no REAPER deps and could live in `core/`.
> It's placed in `state/` for cohesion with other peaks-related code. This is intentional.

### `subscriptions/` — Per-Client State + Generators

Per-client subscription management and JSON generation for subscribed data.

```
subscriptions/
├── track_subscriptions.zig       # Track viewport subscriptions (range/GUID mode)
├── peaks_subscriptions.zig       # Peak/waveform tile subscriptions
├── peaks_generator.zig           # Peak JSON generation
├── peaks_cache.zig               # Subscription-specific tile cache
├── routing_subscriptions.zig     # Routing subscriptions
├── routing_generator.zig         # Routing JSON generation
├── trackfx_subscriptions.zig     # FX chain subscriptions
├── trackfx_generator.zig         # FX chain JSON generation
├── trackfxparam_subscriptions.zig # FX param subscriptions
├── trackfxparam_generator.zig    # FX param JSON generation
├── toggle_subscriptions.zig      # Action toggle subscriptions
└── project_notes.zig             # Project notes subscriptions
```

### `server/` — Runtime Orchestration

WebSocket server, polling coordination, client lifecycle, memory management.

```
server/
├── ws_server.zig            # WebSocket server, client connections
├── client_management.zig    # Disconnect cleanup, gesture timeouts, snapshots
├── gesture_state.zig        # Gesture tracking for undo coalescing
├── tier_polling.zig         # HIGH/MEDIUM/LOW tier orchestration
├── subscription_polling.zig # Subscription-based polling dispatch
├── tiered_state.zig         # Arena management for tiers
├── frame_arena.zig          # Double-buffered arena swap
├── playlist_tick.zig        # Playlist engine tick
├── csurf.zig                # CSurf callback → dirty flag wiring
└── csurf_dirty.zig          # DirtyFlags BitSet per-track
```

### `platform/` — OS-Specific + External Integrations

Platform-specific code and external system bridges.

```
platform/
├── swell.zig                # SWELL GUI bindings (macOS/Linux)
├── zig_swell_bridge.h       # SWELL/Cocoa bridge header
├── zig_swell_bridge.mm      # Objective-C++ implementation
├── qr_window.zig            # QR code window (SWELL)
├── qr_render.zig            # QR code rendering
├── network_detect.zig       # Network interface detection
├── network_action.zig       # QR code action menu
└── lua_peak_bridge.zig      # Zig↔Lua peak data bridge
```

## Dependency Direction

```
                    ┌──────────┐
                    │  main    │
                    └────┬─────┘
                         │
         ┌───────────────┼───────────────┐
         ▼               ▼               ▼
    ┌─────────┐    ┌──────────┐    ┌──────────┐
    │ server  │───▶│  subs    │───▶│  state   │
    └─────────┘    └──────────┘    └────┬─────┘
         │               │               │
         └───────────────┼───────────────┤
                         ▼               ▼
                    ┌─────────┐    ┌─────────┐
                    │  core   │    │ reaper  │
                    └─────────┘    └─────────┘
                         ▲
                         │
                    ┌──────────┐
                    │ platform │
                    └──────────┘
```

- `server/` imports from `subscriptions/`, `state/`, `core/`
- `subscriptions/` imports from `state/`, `core/`
- `state/` imports from `core/`, `reaper/`
- `core/` has no internal dependencies (only `std`)
- `reaper/` and `platform/` are FFI boundaries, import `core/`
- `commands/` imports from all layers (handlers need everything)

## Import Patterns

After migration, imports change from flat to directory-qualified:

```zig
// Before (flat)
const transport = @import("transport.zig");
const logging = @import("logging.zig");

// After (directory-qualified)
const transport = @import("state/transport.zig");
const logging = @import("core/logging.zig");
```

For cross-directory imports, use the root aggregator:

```zig
// reaper.zig (root aggregator)
pub const Api = @import("reaper/raw.zig").Api;
pub const RealBackend = @import("reaper/real.zig").RealBackend;
pub const MockBackend = @import("reaper/mock/mod.zig").MockBackend;
```

## Test Discovery

Zig does **not** auto-discover tests in subdirectories. Tests must be explicitly imported.

The pattern in `main.zig`:

```zig
// Re-export tests from modules
test {
    // core/
    _ = @import("core/errors.zig");
    _ = @import("core/ffi.zig");
    _ = @import("core/logging.zig");
    _ = @import("core/protocol.zig");

    // state/
    _ = @import("state/transport.zig");
    _ = @import("state/tracks.zig");
    _ = @import("state/markers.zig");
    _ = @import("state/items.zig");
    // ... etc

    // server/
    _ = @import("server/ws_server.zig");
    _ = @import("server/gesture_state.zig");
    // ... etc

    // commands/
    _ = @import("commands/mod.zig");
}
```

When adding new files, remember to add them to this test block or they won't run with `zig build test`.

## File Migration Map

| Current Location | New Location |
|------------------|--------------|
| `transport.zig` | `state/transport.zig` |
| `tracks.zig` | `state/tracks.zig` |
| `markers.zig` | `state/markers.zig` |
| `items.zig` | `state/items.zig` |
| `project.zig` | `state/project.zig` |
| `tempomap.zig` | `state/tempomap.zig` |
| `fx.zig` | `state/fx.zig` |
| `sends.zig` | `state/sends.zig` |
| `track_skeleton.zig` | `state/track_skeleton.zig` |
| `playlist.zig` | `state/playlist.zig` |
| `guid_cache.zig` | `state/guid_cache.zig` |
| `item_guid_cache.zig` | `state/item_guid_cache.zig` |
| `peaks_tile.zig` | `state/peaks_tile.zig` |
| `track_subscriptions.zig` | `subscriptions/track_subscriptions.zig` |
| `peaks_subscriptions.zig` | `subscriptions/peaks_subscriptions.zig` |
| `peaks_generator.zig` | `subscriptions/peaks_generator.zig` |
| `peaks_cache.zig` | `subscriptions/peaks_cache.zig` |
| `routing_subscriptions.zig` | `subscriptions/routing_subscriptions.zig` |
| `routing_generator.zig` | `subscriptions/routing_generator.zig` |
| `trackfx_subscriptions.zig` | `subscriptions/trackfx_subscriptions.zig` |
| `trackfx_generator.zig` | `subscriptions/trackfx_generator.zig` |
| `trackfxparam_subscriptions.zig` | `subscriptions/trackfxparam_subscriptions.zig` |
| `trackfxparam_generator.zig` | `subscriptions/trackfxparam_generator.zig` |
| `toggle_subscriptions.zig` | `subscriptions/toggle_subscriptions.zig` |
| `project_notes.zig` | `subscriptions/project_notes.zig` |
| `ws_server.zig` | `server/ws_server.zig` |
| `client_management.zig` | `server/client_management.zig` |
| `gesture_state.zig` | `server/gesture_state.zig` |
| `tier_polling.zig` | `server/tier_polling.zig` |
| `subscription_polling.zig` | `server/subscription_polling.zig` |
| `tiered_state.zig` | `server/tiered_state.zig` |
| `frame_arena.zig` | `server/frame_arena.zig` |
| `playlist_tick.zig` | `server/playlist_tick.zig` |
| `csurf.zig` | `server/csurf.zig` |
| `csurf_dirty.zig` | `server/csurf_dirty.zig` |
| `protocol.zig` | `core/protocol.zig` |
| `constants.zig` | `core/constants.zig` |
| `errors.zig` | `core/errors.zig` |
| `ffi.zig` | `core/ffi.zig` |
| `logging.zig` | `core/logging.zig` |
| `swell.zig` | `platform/swell.zig` |
| `qr_window.zig` | `platform/qr_window.zig` |
| `qr_render.zig` | `platform/qr_render.zig` |
| `network_detect.zig` | `platform/network_detect.zig` |
| `network_action.zig` | `platform/network_action.zig` |
| `lua_peak_bridge.zig` | `platform/lua_peak_bridge.zig` |
| `zig_swell_bridge.h` | `platform/zig_swell_bridge.h` |
| `zig_swell_bridge.mm` | `platform/zig_swell_bridge.mm` |
| `zig_control_surface.cpp` | `reaper/zig_control_surface.cpp` |
| `zig_control_surface.h` | `reaper/zig_control_surface.h` |
| `reaper_csurf.h` | `reaper/reaper_csurf.h` |

**Files that stay at root:**
- `main.zig` — Entry point
- `reaper.zig` — Root aggregator (re-exports)

**Directories unchanged:**
- `commands/` — Already organized
- `reaper/` — Keep existing structure, add C++ files

## Rationale

This structure was designed based on:

1. **Zig community conventions** — Analysis of Zig stdlib, TigerBeetle, Ghostty showed 5-8 top-level directories is ideal for 20-50k line projects

2. **Navigability** — "Where's X?" has one obvious answer:
   - State polling? → `state/`
   - Subscriptions? → `subscriptions/`
   - WebSocket? → `server/`
   - Platform-specific? → `platform/`

3. **Dependency clarity** — Clear layering prevents circular dependencies

4. **FFI isolation** — REAPER API in `reaper/`, OS/Lua in `platform/`

5. **Testability preserved** — MockBackend pattern unchanged, state modules remain pure

## Migration Strategy

1. Create directories: `core/`, `state/`, `subscriptions/`, `server/`, `platform/`
2. Move files in dependency order (leaves first): `core/` → `state/` → `subscriptions/` → `server/` → `platform/`
3. Update imports in each file after moving
4. Update `build.zig` if needed for C++/ObjC++ file paths
5. Run `zig build test` after each batch
6. Update `main.zig` imports last
