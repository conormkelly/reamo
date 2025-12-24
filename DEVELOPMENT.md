# Reamo Development Guide

This document captures implementation details, API quirks, and outstanding work for the Reamo REAPER web controller.

## Architecture Overview

### Project Structure

```
reaper_www_root/
├── extension/           # Zig REAPER extension (WebSocket server)
│   └── src/
│       ├── main.zig           # Entry point, timer loop, state broadcasting
│       ├── reaper.zig         # REAPER C API bindings and helpers
│       ├── tracks.zig         # Track state polling and JSON serialization
│       ├── ws_server.zig      # WebSocket server and client management
│       ├── protocol.zig       # JSON parsing for commands
│       └── commands/          # Command handlers
│           ├── mod.zig        # Command registry
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

### Metering

- `Track_GetPeakInfo(track, channel)` → **post-fader linear amplitude** (1.0 = 0dB)
- `Track_GetPeakHoldDB(track, channel, clear)` → peak hold in dB, sticky until cleared
- **No pre-fader metering API exists** - this is a known REAPER limitation

Convert linear to dB: `dB = 20 * log10(linear)`

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
make dev              # Run frontend dev server with hot reload
make install          # Install frontend npm dependencies
```

**Note**: After extension changes, restart REAPER to load the new plugin.

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
