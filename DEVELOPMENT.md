# REAmo Development Guide

> **Writing Zig code?** Start with **[ZIG_GUIDE.md](docs/ZIG_GUIDE.md)** — a concise guide covering memory safety, FFI correctness, and common pitfalls. This document is the comprehensive reference; the guide is the quick-start.

How the extension and its build fit together, and the REAPER quirks behind the
code. Frontend conventions are in
[frontend/FRONTEND_DEVELOPMENT.md](frontend/FRONTEND_DEVELOPMENT.md), the
protocol in [extension/API.md](extension/API.md), the security model in
[docs/architecture/SECURITY.md](docs/architecture/SECURITY.md).

## Table of Contents

- [Quick Start](#quick-start) (incl. [Windows](#windows))
- [Architecture](#architecture)
- [Data Flow and Subscriptions](#data-flow-and-subscriptions)
- [CSurf Push-Based Architecture](#csurf-push-based-architecture)
- [Extensions Menu](#extensions-menu)
- [Conventions](#conventions)
- [REAPER API Critical Knowledge](#reaper-api-critical-knowledge)
- [Frontend Notes](#frontend-notes)
- [Clock Synchronization](#clock-synchronization)
- [Testing Conventions](#testing-conventions)
- [Extension Robustness](#extension-robustness)
- [Protocol and Configuration](#protocol-and-configuration)
- [Build and Test](#build-and-test)
- [Debugging](#debugging)
- [Common Pitfalls](#common-pitfalls)

---

## Quick Start

`make` on its own lists every target with a line on what it does. The ones
marked **(REAPER)** write into your REAPER's resource folder or quit and
relaunch REAPER; nothing else touches REAPER.

### Prerequisites

| Tool | Version | Why |
| ---- | ------- | --- |
| Node | 22.22.2+ or 24.15+ (`frontend/package.json` engines) | frontend and `tests/ws-integration` |
| npm | 11.16+ (`npm install -g npm@11` if older) | the `.npmrc` supply-chain settings need it; older npm is refused |
| Zig | **0.15.x** exactly (release builds use 0.15.2) | the extension; 0.16 and later don't build it |
| GNU Make, a POSIX shell | any | the Makefile (on Windows, Git Bash: see [Windows](#windows)) |
| Docker | 23+ (BuildKit) | optional: the container checks and the live-REAPER harness |
| Python 3 | any | optional: the harness's tour coverage check |

If the `zig` on your `PATH` is another version, point the Makefile at 0.15:
`make test-extension ZIG=/path/to/zig-0.15/zig` (or `export ZIG=...`). Every
Zig target checks the version first and says so if it's wrong.

### First run

```bash
make install    # npm ci in frontend/ and tests/ws-integration/, the git hooks, Playwright's Chromium
make check      # lint, typecheck, unit + E2E + Zig tests
```

On Linux, Chromium also needs system libraries: `cd frontend && sudo npx
playwright install-deps chromium` once (or use `make container-check`).

`frontend/.npmrc` (and `tests/ws-integration/.npmrc`) turn off dependency
install scripts, which also stops `npm ci` installing the git hooks, so
`make install` runs `npm run prepare` for them. They also hold back any
version published in the last 7 days, and refuse dependencies from git or a
URL instead of the npm registry. Dependabot proposes updates weekly, with the
same 7-day wait.

### With only Docker

```bash
make container-check    # `make check` in a container with pinned Node, npm, Chromium and Zig
```

This builds `scripts/container/Dockerfile` (Playwright's image, pinned by
digest, plus npm 11.21.1 and Zig 0.15.2 checked against its SHA-256) and runs
the checks on a copy of the working tree: nothing is written to the checkout.

### Building into REAPER

```bash
make frontend    # Build the web UI → reamo/, and copy it to REAPER's reaper_www_root/reamo/ (REAPER)
make extension   # Build the extension → REAPER's UserPlugins (REAPER; restart REAPER to load)
```

**Frontend changes** are visible immediately: the web UI auto-reloads when the HTML file is updated.

**Extension changes** require restarting REAPER to load the new plugin.

### Windows

- Install with winget, reopening the terminal after each so `PATH` updates:
  `winget install zig.zig --version 0.15.2`, `OpenJS.NodeJS.LTS`, `Git.Git`,
  `ezwinports.make`. A plain `winget install zig.zig` takes the newest Zig,
  which can't build REAmo; if winget has no 0.15.2, download
  `zig-x86_64-windows-0.15.2.zip` from ziglang.org and pass `ZIG=C:/path/to/zig.exe`.
- Run `make` from **Git Bash**: recipes use POSIX commands. Git for Windows
  has no `make`, hence `ezwinports.make`.
- npm runs scripts with `cmd.exe` whatever shell calls it, and the frontend
  build uses `rm`/`cp`, so once: `npm config set script-shell "C:\Program Files\Git\bin\bash.exe"`.
- Node's bundled npm may be older than 11.16: `npm install -g npm@11`.
- Install REAPER (x64) to the default location. `make install`, `make frontend`,
  `make extension` as on other platforms; `make dev-notests` for the dev cycle.
- Known quirks:
  - Windows builds are `ReleaseSafe`: Debug builds overflow Windows' 1 MB
    default thread stack (8 MB on macOS) with Zig's large debug frames.
  - The DLL lands in `zig-out/bin/`, not `zig-out/lib/`; the Makefile handles it.
  - Unpacking Zig on NTFS is slow (many small files).

## Architecture

### Project Structure

```text
<repo>/
├── extension/              # Zig REAPER extension: HTTP + WebSocket server
│   ├── build.zig(.zon)     # build options: -Dcsurf, -Ddev, -Dtracy; Zig 0.15.x
│   ├── API.md              # WebSocket protocol reference (every command and event)
│   ├── effects/REAmo/      # JSFX shipped with the extension (PitchDetect.jsfx, the tuner)
│   └── src/
│       ├── main.zig        # entry point, timer loop, state broadcasting
│       ├── core/           # protocol parsing, errors, FFI validation, logging, constants
│       ├── reaper/         # REAPER API layer: raw.zig, RealBackend, MockBackend (mock/), CSurf C++ shim
│       ├── server/         # HTTP server, WebSocket clients, host validation, CSurf dirty flags, tiered arenas
│       ├── state/          # polled REAPER state: transport, tracks, items, markers, FX, peaks tiles, playlist
│       ├── subscriptions/  # per-client subscriptions (track viewport, peaks, FX, routing, tuner)
│       ├── commands/       # command handlers; registry.zig lists them, mod.zig dispatches
│       ├── audio/          # audio hook and Mix Monitoring stream
│       └── platform/       # Extensions menu, SWELL/Win32, timers, network detection, QR window
├── frontend/               # React 19 + TypeScript + Vite web UI (builds into ../reamo/)
│   ├── src/                # core/ (protocol, connection machine, sync engines), store/ (Zustand
│   │                       # slices), hooks/, components/, views/, lib/, utils/, audio/
│   ├── e2e/                # Playwright E2E tests
│   └── FRONTEND_DEVELOPMENT.md
├── reamo/                  # built web UI (gitignored): what the extension serves
├── tests/ws-integration/   # Vitest suite driving a real REAPER over WebSocket
├── test-fixtures/          # test-project-1.RPP and its media, used by ws-integration and the harness
├── scripts/
│   ├── harness/            # live-REAPER harness: headless REAPER in Docker (README.md)
│   ├── container/          # the check image `make container-check` runs in
│   ├── bump-version.sh     # set the version in every file that carries it
│   └── check-cpu-baseline.py  # release CI: no instructions beyond the baseline CPU
├── installer/              # Install/Uninstall Lua scripts and README shipped in the release zip
├── docs/                   # architecture notes, REAPER API headers, ZIG_GUIDE.md
└── Makefile                # build, test and install targets: `make` lists them
```

### Threading

- **All REAPER API calls happen on the main thread.** CSurf callbacks and
  timer callbacks both run there.
- The server threads only parse and queue: a command goes into a
  mutex-protected queue, and the main thread drains it (fast timer: 100 Hz on
  macOS, ~63 Hz on Windows, see `platform/fast_timer.zig`; otherwise the 30 Hz
  timer),
  calls REAPER, and queues responses.
- Exceptions answered on the server thread, never touching REAPER:
  `clockSync` and `ping` (`server/http_server.zig`, types parsed in
  `core/protocol.zig`). Clock sync must skip the queue so `t1` is the true
  arrival time; queue wait (0-33 ms) would swamp the measurement.
- httpz runs HTTP and WebSocket handlers concurrently on a thread pool, so
  handler state is write-once or locked.

### Backend Layering (testability)

- `reaper/raw.zig` returns exactly what the C API returns (e.g. `f64`). No
  validation.
- `reaper/real.zig` (`RealBackend`) validates: NaN/Inf/range via
  `ffi.safeFloatToInt`, `roundFloatToInt` (round first, for beats/ticks),
  `isFinite`. Methods return `FFIError!T`; callers use `catch null` so corrupt
  data reaches JSON as `null`, not garbage.
- `reaper/mock/` (`MockBackend`) holds field-based state and `inject_*_error`
  flags to exercise error paths without REAPER.
- `reaper/backend.zig` `validateBackend(T)` checks at compile time that a
  backend has every required method, so a method added to one and not the
  other fails the build.
- State modules and handlers take `api: anytype`. Function pointers can't be
  generic, so dispatch is a comptime tuple (`commands/registry.zig`, 183
  commands) unrolled with `inline for` in `commands/mod.zig`. Zero runtime
  cost.
- Handler signature: `fn (api: anytype, cmd: CommandMessage, response: *ResponseWriter) void`.
- Shared state beyond the API (subscriptions, GUID and item caches, tiered
  arenas, audio stream) lives in `commands/mod.zig` `CommandContext`
  (`mod.g_ctx`), set by `main.zig` at init and cleared at shutdown. A handler
  whose field is null answers with an error, not a crash.
- Tests: `mod.testRunHandler(&mock, handler, json)`, then assert on mock state
  (e.g. `commands/transport.zig`).

### Server libraries (forked)

- HTTP and WebSocket: **httpz** (http.zig), which embeds **websocket.zig**. Both
  by karlseguin; REAmo pins our forks, `conormkelly/http.zig` and
  `conormkelly/websocket.zig`.
- Non-blocking (epoll/kqueue) on macOS and Linux; blocking, one thread per
  connection, on Windows.
- Each fork's `reamo` branch holds every fix REAmo needs on top of upstream.
  - Fix on a topic branch, then merge it into `reamo` (merge commit).
  - Pin `extension/build.zig.zon` (httpz) and httpz's own `build.zig.zon`
    (websocket.zig) to a commit on `reamo`, never on a topic branch: a topic
    branch can miss fixes that are only on `reamo`.
  - Pin by commit URL. Get the hash with `zig fetch <url>`.
- When a REAmo release ships, tag the pinned commit in each fork
  `reamo-v<version>` (e.g. `reamo-v0.8.1`), so each release's fork code is
  easy to find and diff.
- Test a fork change before pushing: point the pin at the checkout with
  `.path = "<relative path>"`, and put the URL pin back before committing.
- Why one port for HTTP and WebSocket: no port discovery (an ExtState lookup
  hung on iOS cold start), and one origin allows CSP `'self'` and the Origin
  check. Details: `docs/architecture/HTTP_SERVER.md`.

### Polling tiers and arenas

- `server/tiered_state.zig`: one double-buffered arena per tier, swapped
  between frames, plus a scratch arena reset every frame for JSON.
  - HIGH, 30 Hz: transport, subscribed tracks, meters.
  - MEDIUM, 5 Hz: items, markers, regions, FX, sends.
  - LOW, 1 Hz: tempo map, track skeleton.
- Arenas are sized from the project's entity counts (20 MB floor, 200 MB
  ceiling). Data is flattened, so nothing points across tiers when an arena
  swaps.
- Fixed caps still apply (`core/constants.zig`): `MAX_TRACKS` 128 on the
  full-poll path, `MAX_ITEMS` 512, `MAX_MARKERS` 256, `MAX_REGIONS` 256.
  Beyond a cap, entities are skipped, never a crash.
- Why arenas, not stack `State` values: timer callbacks can run under REAPER's
  modal dialogs (missing media, startup prompts) with ~45 frames already on
  the stack, and Zig reserves a function's locals at entry, so large stack
  structs overflow.
- JSON goes through `toJsonAlloc(scratch)` / `protocol.serializeAlloc`, never
  a fixed stack buffer.

## Data Flow and Subscriptions

1. The 30 Hz timer polls subscribed tracks and meters; hashes decide what changed.
2. The extension sends `tracks` (`{total, tracks: [...]}`, on change) and
   `meters` (map keyed by GUID, 30 Hz) as separate events. `total` counts user
   tracks only, for virtual scrollbars.
3. The frontend's XState connection (`core/websocketMachine.ts`, driven by
   `core/websocketActor.ts`) hands messages to `handleWebSocketMessage()` in
   `store/index.ts`, which updates Zustand slices; components read them via hooks.

### Track subscriptions (viewport-driven)

- Clients declare which tracks they need; only those are polled at 30 Hz.
  `track/subscribe` with either:
  - **range** `[start, end]` of unified index slots (mixer scrolling), plus up
    to 8 extra GUIDs; or
  - **guids** (filtered views), at most 64 per client.
- **Slots, not entities, for reads:** "tracks 20-30" means whatever is in
  those slots now. A delete or reorder just shows new slot contents on the
  next poll; no stable-ID bookkeeping.
- **GUIDs for writes:** a fader drag sends `trackGuid`, resolved per command
  (`tracks.resolveTrack`, `state/guid_cache.zig`), so a reorder mid-drag still
  hits the right track. Gesture commands resolve the GUID at gesture start.
- **Master is `"master"`**, not its GUID: `GetTrackGUID` is inconsistent for
  the master track, so the server maps `"master"` to `GetMasterTrack()`.
- **No structure versioning:** new skeletons arrive within ~1 s and GUID
  lookups already say whether a track exists, so a version check would only
  add a "stale, refresh" failure mode.
- FX and sends are addressed by track GUID + index: a reorder of the FX chain
  or sends mid-gesture could hit the wrong one. Accepted; it's rare.
- The skeleton (`state/track_skeleton.zig`, LOW tier) lists name, GUID and
  send/hardware-output/item counts for every track, broadcast on change.
- Grace period 500 ms: a track that leaves the viewport stays subscribed
  briefly so scrolling back is instant.
- Subscribing sets `force_broadcast`: the next poll sends current state even
  if unchanged, so a refreshed page never waits on a change.

### Items, markers and regions

- Broadcast to every client on connect and on change (5 Hz). The frontend
  filters to its viewport. Per-client time-range subscriptions were rejected:
  on a LAN the bandwidth is negligible and the frontend filters anyway.

### Peaks (waveforms)

- `subscriptions/peaks_generator.zig` calls `GetMediaItemTake_Peaks` for the
  whole item at the LOD's peak rate (REAPER reads its `.reapeaks` cache),
  slices it into tiles and caches them (`state/peaks_tile.zig`, key
  `{take_guid, epoch, lod, tile_index}`, 500-entry LRU). The epoch hashes
  source properties (incl. start offset and playrate), so edits invalidate.
- 7 LOD levels, 4x apart, 256 peaks per tile; rationale and thresholds in the
  `peaks_tile.zig` doc comments.
- Sent as binary frames (int8 quantized, layout in `core/binary_protocol.zig`
  and API.md), on every viewport change, with a 50% buffer each side. Peaks
  broadcasts are rate-limited to one per 100 ms.
- Always request 2 channels: REAPER writes 2 even for mono sources on some
  platforms. `GetMediaSourceNumChannels` gives the real count.
- Frontend: tiles in `store/slices/peaksSlice.ts`; `core/TileBitmapCache.ts`
  pre-renders to `ImageBitmap` (200 bitmaps, ~50 MB, `bitmap.close()` on
  evict); one canvas per track (`components/Timeline/WaveformCanvas.tsx`),
  1x DPR, never cleared whole (no flash), with a direct draw or an adjacent
  LOD as fallback.

### FX and routing subscriptions

- `trackFx/subscribe`: one track's FX chain (`trackFxChain` event on change).
- `trackFxParams/subscribe`: one FX's parameter values, by `range` or
  `indices`. `paramCount` and `nameHash` in every event let the client refetch
  its skeleton (`trackFx/getParams`, which returns the same `nameHash`) when
  the plugin's parameters change.
- `routing/subscribe`: one track's sends, receives and hardware outputs at
  30 Hz, so send faders don't lag during a drag.
- FX parameters, sends, receives and hardware outputs are wrapped in
  `gesture/start`/`gesture/end`; see Common Pitfalls for undo.

## CSurf Push-Based Architecture

The extension registers an `IReaperControlSurface` so REAPER pushes changes,
and keeps polling as the source of truth.

- **Hybrid, not pure callbacks.** Callbacks set dirty flags; the 30 Hz loop
  consumes them, polls every subscribed entity, and broadcasts when the hash
  changed **or** a flag is set. Polling is never filtered by dirty bits: a
  missed callback would then mean a missed update.
- **What callbacks buy:** marker/region, tempo, FX and send changes go out on
  the next frame (<33 ms) instead of at their tier's rate (5 Hz or 1 Hz).
- **2 s heartbeat** (`csurf_dirty.SAFETY_POLL_INTERVAL`, the interval SWS
  uses) marks every track dirty to force a full comparison, catching
  ReaScript edits and rapid undo/redo.
- **Drift logging:** a hash change with no dirty flag means a missed callback;
  it's logged (rate-limited, `main.zig`) as `"Track drift without dirty flag"`.
- **Wyhash** of every field that appears in the JSON detects changes; it costs
  nanoseconds against microseconds per REAPER API call.
- Registered as `csurf_inst`, not `csurf`: it activates on load, never shows in
  Preferences, needs no setup.
- `Extended()` always returns 0: never consume a callback other surfaces may
  need (SWS practice; the return value's meaning is undocumented).
- `reverse_map_valid` (`server/csurf_dirty.zig`): between `SetTrackListChange`
  and the GUID cache rebuild, track pointers are stale; callbacks bail out.
- C++ shim (`reaper/zig_control_surface.cpp`/`.h`): Zig can't implement a C++
  vtable, so the shim inherits the interface and forwards to C function
  pointers (`server/csurf.zig`). Per-track flags are `BitSet(1024)`.
- `zig build -Dcsurf=false` builds pure polling, to rule CSurf out when debugging.

Known callback gaps (why polling stays):

- `OnTrackSelection()` fires only for mouse clicks in the TCP/MCP, not for
  selection by action or API; it doesn't fire at all when the Mixer option
  "Scroll view when tracks activated" is off; and it arrives before
  `CSURF_EXT_SETLASTTOUCHEDTRACK`.
- `CSURF_EXT_SETFXCHANGE` doesn't fire when FX are dragged between tracks,
  and fires once per FX on a project switch.
- A project-tab switch fires only `SetTrackListChange()`, the same as a track
  add/remove/reorder; telling them apart needs a project-pointer comparison.
- Undo/redo has no callback.

Nothing handles these explicitly today; the heartbeat catches them within 2 s.

Still polled (no callback exists): playhead (30 Hz), meters (30 Hz; no CSurf
metering), edit cursor and time selection (30 Hz), undo state (5 Hz), project
length (1 Hz).

## Extensions Menu

`platform/menu.zig` (registration, hook, dispatch) and
`platform/menu_items.zig` (the declarative item table, in display order,
grouped connection / settings / diagnostics, then top-level).

- **Register in `ReaperPluginEntry`, not in the deferred init timer.** The
  `hookcustommenu` flag=0 event fires once, when the Extensions menu is first
  built; SWS can build it during plugin loading, so a timer registers too late.
- Order: `custom_action` for each item → `hookcommand2` → `hookcustommenu` →
  `AddExtensionsMainMenu()` (idempotent; SWS and ReaPack call it too).
- `swell.init()` must run before any SWELL call: function getters return null
  until `SWELLAPI_GetFunc` is set, silently.
- Hook: handle `menuidstr == "Main extensions"` only. flag=0 builds items
  (no checked/grayed state, no icons, don't keep submenu handles); flag=1
  runs on every open and sets toggle state.
- `hookcommand2` returns `false` for commands that aren't ours, so other
  extensions still get them.
- SWELL is not Win32 (macOS/Linux; Windows calls Win32 directly, `platform/swell.zig`):
  - `MIIM_*` values differ: `MIIM_ID`=1, `MIIM_STATE`=2, `MIIM_TYPE`=4,
    `MIIM_SUBMENU`=8, `MIIM_DATA`=16. No `MIIM_STRING`/`MIIM_FTYPE`; use
    `MIIM_TYPE`. `MF_*`/`MFS_*`/`MFT_*` match Win32.
  - `AppendMenu`/`InsertMenu` are macros, not loadable: load
    `SWELL_InsertMenu` and pass `pos=-1` to append.
  - `InsertMenuItem` returns `void`.
  - `MENUITEMINFO` pointer fields (`hSubMenu`, `hbmp*`, `dwItemData`,
    `dwTypeData`) are pointer-width, so the struct is larger on 64-bit.
  - `HMENU` is a bare `NSMenu*` on macOS (`?*anyopaque` in Zig).
- Adding an item: one entry in `menu_items.zig`, a branch in
  `menu.zig` `dispatchAction`, and the handler (e.g. `platform/network_action.zig`).

## Conventions

- Undo descriptions start with `"REAmo: "` (e.g. `"REAmo: Adjust time signature"`).
- Commands are `domain/action`: `track/setVolume`, `transport/seek`, `marker/update`.
- Every new command goes into `commands/registry.zig` and `extension/API.md`;
  new backend methods go into `real.zig` and the mock (`validateBackend` enforces it).

## REAPER API Critical Knowledge

- **Track indexing:** `GetTrack(proj, 0)` is the first *user* track;
  `CountTracks()` excludes master. We use unified indexing (0 = master,
  1+ = user tracks) via `getTrackByUnifiedIdx`.
- **Custom colours:** `I_CUSTOMCOLOR` bit 24 (`0x01000000`) is the "set" flag;
  without it the value is a theme colour, report 0. Use
  `ColorToNative`/`ColorFromNative`: Windows stores RGB, macOS BGR.
- **Master mute/solo:** `B_MUTE`/`I_SOLO` are unreliable on the master track.
  Read `GetMasterMuteSoloFlags()` (`&1` muted, `&2` soloed); write with
  `CSurf_OnMuteChange`/`CSurf_OnSoloChange`, which also honour grouping
  (`allowGang=true`).
- **Metering:** `Track_GetPeakInfo` is post-fader linear amplitude (1.0 = 0 dB);
  `Track_GetPeakHoldDB` is sticky until cleared. There is no pre-fader meter API.
- **Play position:** use `GetPlayPosition()` (latency-compensated: what's
  heard), not `GetPlayPosition2()`.
- **Wrapper sources:** for an item with a take offset,
  `GetMediaItemTake_Source` can return a wrapper with length 0 and sample rate
  0. Walk `GetMediaSourceParent` (`raw.getRootSource`) before reading source
  properties. Known gap: nothing calls `getRootSource` today;
  `peaks_generator.zig` reads the take source directly.
- **Hardware outputs and send mute have no CSurf setter.**
  `CSurf_OnSendVolumeChange` only covers category 0 (sends). Use
  `SetTrackSendInfo_Value(track, 1, idx, "D_VOL", v)` for hardware outputs and
  `B_MUTE` for send mute. Check `docs/reaper_plugin_functions.h` before
  assuming a CSurf function doesn't exist.
- **Continuous controls** (volume, pan, send level): use the CSurf setters,
  which coalesce undo per gesture and honour grouping and master handling.
- **Action IDs:** native actions have stable numeric IDs; SWS, ReaScript and
  custom actions don't (assigned at startup). Store their string ID from
  `ReverseNamedCommandLookup`, which drops the leading `_`: prepend it. 128
  bytes covers every ID (`SNM_MAX_ACTION_CUSTID_LEN`). The frontend runs IDs
  starting with `_` by name.
- **MIDI from the instruments** uses `StuffMIDIMessage` mode 0 (virtual
  keyboard), which reaches record-armed/monitored tracks. CC and program
  change are sent on mode 1 too, so MIDI Learn and control surfaces see them
  (`raw.zig` `sendMidi*`).
- **Undo blocks don't nest:** see Common Pitfalls.

## Frontend Notes

Conventions, lint rules and patterns are in
[frontend/FRONTEND_DEVELOPMENT.md](frontend/FRONTEND_DEVELOPMENT.md). Points
that span both halves:

- **`transport` vs `tt` events.** `transport` (full state) goes out on
  play/pause/stop and on seeks while stopped; during playback only `tt`
  (position `p`, server time `t`, beats `b`, BPM, time sig, bar.beat.ticks)
  is sent. Both `TransportSyncEngine` (beats) and `TransportAnimationEngine`
  (time) must receive `tt` (`store/index.ts`), or their display freezes
  during playback. `p` lets the animation engine catch seeks (e.g. playlist
  jumps): error >250 ms snaps, >50 ms corrects 15% per update.
- **Animation bypasses React** (`useTransportAnimation`, refs + direct DOM).
  The engine notifies synchronously while React batches, so a callback that
  depends on React-derived values (e.g. timeline bounds) must also recompute
  in a `useLayoutEffect` when those values change.
- **iOS Safari cold start:** the first WebSocket in a new page context can sit
  in `CONNECTING` with no events. `core/websocketMachine.ts` first fetches
  `/api/ping` (Safari) and, on iOS Safari, opens a throwaway WebSocket from
  the page to prime NSURLSession, then connects; `CONNECT_TIMEOUT` (5 s)
  catches a stuck attempt. A `srcdoc` iframe can't do the warm-up: its Origin
  is `null`, which the server refuses. Didn't help: delays (200-1000 ms),
  focus manipulation, aggressive retries, `document.readyState` checks.
- **Suspended PWAs:** iOS kills a backgrounded PWA's socket without `onclose`,
  and `readyState` still says `OPEN`. On visibility return the machine
  verifies with a ping (`verifying` state) and reconnects if it fails;
  heartbeat ping every 10 s, pong within 3 s. `useReaperConnection.ts` also
  reconnects on `online`. `ConnectionStatus.tsx` waits 2.5 s before showing
  "Disconnected" on first load.
- **Updates:** the hello carries `extensionVersion` and `htmlMtime`; on a
  mismatch the app clears caches, unregisters service workers and reloads
  with a cache-busting query (`utils/versionStorage.ts`). Always automatic.
- **Same origin:** the token comes from `<meta name="reamo-token">`, the port
  from `location.port`.

## Clock Synchronization

NTP-style sync so beat displays line up over WiFi
(`core/TransportSyncEngine.ts`, `lib/transport-sync/`).

- `clockSync {t0}` → server replies `t0, t1, t2` on the server thread,
  bypassing the command queue (see Threading).
- `RTT = (t3 - t0) - (t2 - t1)`, `offset = ((t1 - t0) + (t2 - t3)) / 2`;
  the minimum-RTT sample wins.
- Offset changes slew at 0.5 ms/s; above 100 ms they step. Resync every
  5 min or when drift exceeds 50 ms.
- Server time is `time_precise() * 1000`; the client uses `Date.now()`. The
  offset absorbs any difference in origin, so the two needn't share an epoch.
- Jitter is measured as relative delay (the WebRTC NetEQ approach) with a
  0.983 forget factor (`JitterMeasurement.ts`).
- `AdaptiveBuffer` holds 35-150 ms. Floor 35 ms because iOS Low Power Mode
  renders at 30 fps (33 ms frames); above 150 ms feels laggy.
- `BeatPredictor` predicts from the tempo map; prediction is disabled for a
  fixed 100 ms after a state change.
- Network Stats modal (long-press the connection dot): RTT, jitter, buffer,
  offset, and a ±50 ms manual offset saved in `localStorage` (`reamo:manualOffset`).
- Deliberately not done: a 60 Hz event rate, MessagePack, a separate sync
  socket, Ableton Link. None is needed at the current accuracy.

Known gaps:

- Low Power Mode isn't detected: `AdaptiveBuffer.setMinDelay` exists but only
  tests call it. No browser API reports the mode; the planned method counts
  frames slower than 25 ms, raises the floor to 50 ms after more than 10, and
  restores 35 ms once the count decays to 0.
- Prediction keeps running while the page is hidden; resync happens on
  `visibilitychange` only, not `window.focus`.
- No accuracy or drift validation exists. Targets for one: recovery under
  3 s from an injected 2 s dropout; heap under 20 MB with no leak over 1 h;
  initial sync under 2 s; drift simulated at 100 ppm; good/moderate/poor/
  hiccup network profiles via `tc netem` (Linux) or `dnctl`/`pfctl` (macOS);
  a perception test passing with 4 of 5 musicians.

## Testing Conventions

- Behaviour-driven: tests describe user actions and outcomes, use fixtures
  (`songStructure()`), actions (`actions.move([0], 5)`) and names
  (`findRegion('Intro')`, not `displayRegions[0]`: order changes after moves).
- Don't assert on internals or intermediate state unless testing a state machine.
- Zustand is synchronous: call `useReaperStore.getState()` fresh after a mutation.
- Long-press and timeouts: `vi.useFakeTimers()` + `vi.advanceTimersByTime()`.
  JSDOM pointer events are limited; real gestures belong in Playwright.
- "Works at 0, breaks at non-zero" usually means a stale default; test with
  non-zero initial state (see the playhead tests in `Timeline.test.tsx`).
- E2E: call `_setTestMode(true)` on `window.__REAPER_STORE__` before setting
  state, so the real WebSocket can't overwrite it.
- Zig: `mod.testRunHandler(&mock, handler, json)` and assert on mock state;
  keep mock array sizes small (Common Pitfalls).
- Against real REAPER: `tests/ws-integration/` and the live-REAPER harness
  (`scripts/harness/README.md`).

## Extension Robustness

**Never crash REAPER**: the user may have unsaved work.

- Validate at trust boundaries: positions and lengths are finite and >= 0
  (`mod.validatePosition`, `ffi.isFinite`); every float→int goes through
  `ffi.safeFloatToInt` (`@intFromFloat` panics on NaN/Inf).
- Check every REAPER pointer for null, and `validateTrackPtr`/`validateItemPtr`
  before using one across a poll: the user can delete tracks mid-enumeration.
- Failures degrade: bad API value → log and skip; bad JSON or garbage from a
  client → error to that client; out of memory → error, no crash; stale
  pointer → skip or error.
- Rate-limit repeated error logs (e.g. WebSocket write errors: first at once,
  then at most every 5 s).
- Host and Origin validation, the session token and the other server
  defences are in [docs/architecture/SECURITY.md](docs/architecture/SECURITY.md).
  Host checks run on the bare hostname, never a prefix match on the Host
  string: `127.rebind.evil.example` starts with `127.` too
  (`server/host_validation.zig`).

### Memory

| Callback | Thread | malloc/free | Large stack buffers |
|---|---|---|---|
| Timer, CSurf | main | yes | **no** |
| Audio hook | audio (real-time) | no | no |

- Timer callbacks can fire inside REAPER's modal dialogs with a deep stack.
  Never put buffers over ~1 KB on the stack there; use `std.heap.c_allocator`
  (safe on the main thread) with `defer` free, or the tiered arenas.
- Prefer per-call allocation over shared static buffers (reentrancy).

## Protocol and Configuration

- Hello: the client sends `{type: "hello", clientVersion, protocolVersion, token}`;
  the server answers with `extensionVersion`, `protocolVersion` and
  `htmlMtime`. `PROTOCOL_VERSION` is in `core/protocol.zig`.
  - Client protocol newer than the server's: the client asks the user to
    update the extension. Server's newer: the server sends an error and closes
    with 4002.
- Musicians never see error dialogs (`MB_OK`) or need to configure a port:
  - Default port 9224; if taken, the next free one up to 9233, silently.
  - **Extensions > REAmo > Change Server Port...** stores the port in
    ExtState `Reamo/ServerPort`.

### Large messages

- `action/getActions` is ~985 KB of JSON. Fine on a LAN today; nothing is
  compressed.
- If compression is added: app-level deflate (`DecompressionStream` in the
  browser) for messages over a size threshold, **not** permessage-deflate:
  Safari has a history of permessage-deflate bugs.

## Build and Test

`make` lists every target; the main ones:

```bash
# Checks that need no REAPER
make check            # lint + typecheck + test
make lint             # ESLint: frontend/ and tests/ws-integration/
make typecheck        # TypeScript: frontend/ and tests/ws-integration/
make test             # test-frontend + test-e2e + test-extension
make test-frontend    # Vitest unit tests
make test-e2e         # Playwright E2E tests (starts Vite on 5173, or reuses one already there)
make test-extension   # Zig unit tests
make container-check  # `make check` in the pinned check container (needs only Docker)

# Against a real REAPER
make test-ws          # tests/ws-integration against your REAPER, with test-fixtures/test-project-1.RPP open
make test-ws-harness  # the same suite against headless REAPER in Docker
make harness          # live-REAPER harness scenarios (scripts/harness/README.md)
make release-check    # release gate: every scenario on the oldest and the pinned REAPER

# Build
make frontend-build   # web UI → reamo/ (nothing outside the checkout)
make frontend         # frontend-build, then copy to REAPER's reaper_www_root/reamo/ (REAPER)
make extension        # build, then copy to REAPER's UserPlugins (REAPER)
make all              # test, then frontend and extension (REAPER)

# Extension development cycle (REAPER)
make dev              # tests → quit REAPER → dev-extension → relaunch
make dev-notests      # the same without the tests, for rapid iteration
make frontend-dev     # Vite dev server with hot reload
```

`make test-e2e` reuses a server already listening on 5173 (outside CI), so
stop any other checkout's `make frontend-dev` first or it tests that code.

Release zips are built only by `.github/workflows/release.yml`, which names
every target and CPU explicitly (a build for the build machine's CPU can crash
REAPER at startup on older ones) and checks them with
`scripts/check-cpu-baseline.py`.

### Extension development cycle

- **No hot reload for the extension.** macOS memory-maps a loaded `.dylib`;
  overwriting it while REAPER runs gives a half-old, half-new binary and
  crashes nobody can debug. Rebuild, restart REAPER, test.
- `make dev` runs the tests, quits REAPER, installs the dev build and
  relaunches REAPER with its output in the terminal; `make dev-notests` skips
  the tests.

### Tracy profiler

- `make tracy` builds with [Tracy](https://github.com/wolfpld/tracy) via
  ztracy (ReleaseFast: Zig 0.15 bug). Frame markers in `doProcessing()`,
  zones in `action/getActions`. Without `-Dtracy` the calls are no-op stubs.

## Debugging

- Log: `Logs/reamo.log` in REAPER's resource folder (**Extensions > REAmo >
  Open Log Folder**). 1 MB per file; the live file plus 3 rotations.
- Level: `REAMO_LOG_LEVEL` = `error` | `warn` | `info` | `debug`, set before
  launching REAPER. Default `info`, or `debug` in a Debug build (macOS
  `make extension` builds Debug). **Extensions > REAmo > Debug Logging (until
  REAPER restarts)** switches to debug for the session.
- References: `docs/reaper_plugin_functions.h` (authoritative signatures),
  `extension/API.md`, `frontend/src/core/types.ts`.
- Talking to the server by hand: `GET /` serves the UI, `GET /ws` upgrades
  (port 9224, or the next free one up to 9233). The first message must be a
  hello carrying the token from the served HTML's
  `<meta name="reamo-token">`. `scripts/harness/reamo_client.py` and
  `tests/ws-integration/helpers/client.ts` are complete clients.

## Common Pitfalls

1. **Track index 0 is not master in the raw API.** Use `getTrackByUnifiedIdx()`.
2. **Colour 0 means "no custom colour".** Check the `0x01000000` flag.
3. **Meters are linear amplitude, not dB**, and arrive in their own `meters`
   event, not merged into `tracks`.
4. **REAPER must restart after an extension change** (no hot reload).
5. **`@intFromFloat` panics on NaN/Inf.** Use `ffi.safeFloatToInt()` on every
   REAPER value.
6. **`anytype` can't go in a function pointer type.** Use the comptime-tuple
   registry with `inline for`.
7. **A handler not in `commands/registry.zig` is never dispatched.**
8. **A new backend method needs `real.zig` and the mock**; `validateBackend()`
   fails the build otherwise.
9. **Beat.ticks precision:** scale to an integer before splitting.
   `@mod(6.76, 1.0)` is `0.7599999998`, giving 75 ticks, not 76:

   ```zig
   const scaled: u32 = try ffi.roundFloatToInt(u32, val * 100.0); // 676
   const whole = scaled / 100; // 6
   const frac = scaled % 100;  // 76
   ```

10. **Validation lives in `RealBackend`, not `raw.zig`.** `FFIError!T` methods
    need `catch`; `catch null` turns corrupt data into a JSON `null`.
11. **Gestures need both halves.** The frontend sends `gesture/start` before a
    drag and `gesture/end` after; handlers call `gestures.recordActivity()` on
    each change. A gesture with no activity for 10 s is flushed
    (`server/gesture_state.zig` `GESTURE_TIMEOUT_NS`), and a disconnect cleans
    up. A new continuous control needs: `ControlId.ControlType` and a
    constructor (`gesture_state.zig`), parsing in `commands/gesture.zig`
    `parseControlId`, the `recordActivity()` call, and API.md.
12. **Compound controls need `sub_idx`**: sends, receives and hardware outputs
    are identified by track and send/hw index (`ControlId.sendVolume(track, send)`).
13. **Undo blocks don't nest.** `Undo_BeginBlock2` twice before
    `Undo_EndBlock2` corrupts REAPER's undo state, and a block held open
    across timer ticks breaks undo for the session if the drag never ends
    (timeout, disconnect). So `undo/begin`/`undo/end` aren't commands, and
    nothing keeps a block open across ticks:
    - Track volume/pan: CSurf setters coalesce; gesture end calls
      `CSurf_FlushUndo(true)`.
    - Sends, receives, hardware outputs, FX parameters: changes apply at once,
      and when the last open manual-undo gesture ends, one
      `Undo_OnStateChangeEx2` point is recorded (`gesture_state.zig`
      `beginManualUndo`/`endManualUndo`, `commands/gesture.zig`).
14. **Gesture commands take `trackGuid`** (resolved with
    `tracks.resolveTrack()`), so a reorder mid-drag can't hit another track.
    The frontend sends `trackGuid` when it has one, else `trackIdx`.
15. **Responses grow to fit.** `ResponseWriter.success()` formats into an
    exact-size heap buffer for large payloads, up to 2 MB, then refuses with
    `RESPONSE_TOO_LARGE` (`commands/mod.zig`). `successLargePayload` is the
    same call.
16. **No silent `catch return` / `catch return null`.** The client just times
    out and the log is empty. Log first: `err` for "can't happen", `warn` for
    unexpected but recoverable, `debug` for expected edge cases. `catch null`
    is fine in a helper whose caller handles `null`.
17. **JSON goes through `toJsonAlloc(scratch)`**, sized from the content, not a
    fixed stack buffer.
18. **C strings from a `[N]u8` buffer:** take a sentinel slice
    (`buf[0..len :0]` after writing the 0), not `@ptrCast(&buf)`: the cast
    compiles but drops the type-checked sentinel. See
    [docs/ZIG_GUIDE.md](docs/ZIG_GUIDE.md).
19. **Store string IDs for SWS/script/custom actions** (see REAPER API
    Critical Knowledge); a numeric ID runs a different action after a restart.
20. **Keep MockBackend arrays small** (`reaper/mock/state.zig`). Nested arrays
    (tracks × FX × params) blow the stack (SIGILL in tests) and explode debug
    info (binaries of hundreds of MB, slow compiles). Production sizes come
    from `core/constants.zig`.
21. **Wrapper sources:** walk to the root source before reading source
    properties (REAPER API Critical Knowledge).
