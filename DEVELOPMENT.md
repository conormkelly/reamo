# Reamo Development Guide

This document captures implementation details, API quirks, and outstanding work for the Reamo REAPER web controller.

## Table of Contents

- [Quick Start](#quick-start)
- [Architecture Overview](#architecture-overview)
- [Data Flow](#data-flow)
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

```
reaper_www_root/
├── extension/           # Zig REAPER extension (WebSocket server)
│   └── src/
│       ├── main.zig           # Entry point, timer loop, state broadcasting
│       ├── reaper.zig         # Re-exports: RealBackend, MockBackend, raw types
│       ├── reaper/            # REAPER API abstraction layer
│       │   ├── raw.zig        # C function pointers (~80 raw functions)
│       │   ├── types.zig      # Shared types (BeatsInfo, MarkerInfo, etc.)
│       │   ├── backend.zig    # validateBackend() comptime check
│       │   ├── real.zig       # RealBackend - production wrapper around raw.Api
│       │   └── mock/          # MockBackend for testing
│       │       ├── mod.zig    # MockBackend struct composition
│       │       ├── state.zig  # MockTrack, MockItem, encoding helpers
│       │       ├── transport.zig  # Transport mock methods
│       │       ├── tracks.zig     # Track/item mock methods
│       │       ├── markers.zig    # Marker/region mock methods
│       │       └── project.zig    # Project/undo/extstate mock methods
│       ├── transport.zig      # Transport state polling (poll(api: anytype))
│       ├── tracks.zig         # Track state & metering (poll(api: anytype))
│       ├── items.zig          # Item/take state polling
│       ├── markers.zig        # Marker/region state polling
│       ├── ws_server.zig      # WebSocket server and client management
│       ├── protocol.zig       # JSON parsing for commands
│       └── commands/          # Command handlers (~70 handlers)
│           ├── mod.zig        # dispatch() with inline for
│           ├── registry.zig   # Comptime tuple of all handlers
│           ├── tracks.zig     # track/setVolume, track/setMute, etc.
│           ├── transport.zig  # transport/play, transport/stop, etc.
│           └── ...
├── frontend/            # React/TypeScript web UI
│   └── src/
│       ├── core/              # Types, WebSocket connection
│       │   ├── types.ts       # Track, Region, Marker types
│       │   ├── WebSocketTypes.ts    # WSTrack, WSMeter, event payloads
│       │   └── WebSocketCommands.ts # Command builders
│       ├── store/             # Zustand state management
│       │   ├── index.ts       # Main store, WebSocket message handler
│       │   └── slices/        # tracksSlice, transportSlice, etc.
│       ├── hooks/             # useTrack, useTracks, useTransport
│       ├── components/        # React components
│       │   └── Track/         # TrackStrip, LevelMeter, Fader, etc.
│       └── utils/             # volume.ts, color.ts, pan.ts
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

**FFI validation files:**
- `src/reaper/raw.zig` — Pure C bindings, returns `f64` from REAPER
- `src/reaper/real.zig` — `RealBackend` with `ffi.safeFloatToInt()` validation
- `src/reaper/mock/tracks.zig` — `inject_*_error` fields for testing error paths
- `src/ffi.zig` — `safeFloatToInt()` and `FFIError` definitions

**Testability key files:**

| File | Purpose |
|------|---------|
| `reaper/backend.zig` | `validateBackend(T)` — comptime validates ~100 required methods |
| `reaper/real.zig` | `RealBackend` — thin wrapper around `raw.Api`, used in production |
| `reaper/mock/mod.zig` | `MockBackend` — field-based state for tests, no REAPER needed |
| `commands/registry.zig` | Comptime tuple of all ~70 command handlers |
| `commands/mod.zig` | `dispatch()` using `inline for` over registry |

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
    // ... ~70 entries
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
   - Calls `tracks.State.poll(api)` → iterates all tracks via unified indexing
   - Calls `tracks.MeteringState.poll(api)` → gets peak levels for all tracks
   - Compares with previous state for change detection

2. **Extension broadcasts JSON** via WebSocket
   ```json
   {
     "type": "event",
     "event": "tracks",
     "payload": {
       "tracks": [{"idx": 0, "name": "MASTER", "volume": 1.0, ...}],
       "meters": [{"trackIdx": 0, "peakL": 0.5, "peakR": 0.45, "clipped": false}]
     }
   }
   ```

3. **Frontend receives** in `WebSocketConnection.ts` → dispatches to store

4. **Store processes** in `handleWebSocketMessage()`:
   - Converts `WSTrack` → `Track` objects
   - Builds flags bitfield from boolean fields
   - Merges meter data into track objects

5. **React components** consume via hooks (`useTrack`, `useTracks`)

## Conventions

### Undo Blocks

All REAPER undo blocks must be prefixed with "Reamo: " for easy identification in REAPER's undo history:

```zig
api.undoBeginBlock();
// ... make changes ...
api.undoEndBlock("Reamo: Adjust time signature");
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

**GetMediaSourceNumChannels is unreliable** — returns 1 for stereo files in many cases. This is a known REAPER bug. Do NOT rely on it for mono/stereo detection.

**Workaround:** Use `AudioAccessor` to read actual audio samples, then detect mono vs stereo by comparing L/R channel data:

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

### Graceful Degradation

| Failure | Response |
|---------|----------|
| REAPER API returns unexpected value | Log warning, skip operation, continue |
| JSON parse failure | Return error to client, don't crash |
| Client sends garbage | Disconnect that client, others unaffected |
| Out of memory | Return error to client, don't allocate |

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
curl -s "http://localhost:8099/_/GET/EXTSTATE/Reamo/WebsocketPort"
curl -s "http://localhost:8099/_/GET/EXTSTATE/Reamo/SessionToken"
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

## Debugging

### Key Files & Resources

- **REAPER API headers**: `docs/reaper_plugin_functions.h` — authoritative function signatures
- **Frontend types**: `frontend/src/core/types.ts` — command IDs, PlayState enum, protocol definitions
- **Test client**: `extension/test-client.html` — browser-based WebSocket testing

### WebSocket Testing

```bash
# Get token and port
curl -s "http://localhost:8099/_/GET/EXTSTATE/Reamo/SessionToken"
curl -s "http://localhost:8099/_/GET/EXTSTATE/Reamo/WebsocketPort"

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
