# Reamo Development Guide

This document captures implementation details, API quirks, and outstanding work for the Reamo REAPER web controller.

## Architecture Overview

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

// Old HTTP format (no longer used):
meterToDb(value)        // Was for dB * 10 integer format - DEPRECATED
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

## Outstanding Work

### 1. Meter Smoothing (Optional Polish)

Current 30ms updates can look choppy. Options:

**CSS transition** (simplest):
```tsx
// In LevelMeter.tsx, already has duration-75 but could increase:
className={`... transition-all duration-100 ...`}
```

**Separate meter polling** (smoother but more complex):
- Run meter polling at 10-15ms instead of 30ms
- Send meters as separate event type
- Would need to decouple from track state change detection

## Build & Test

```bash
# Build everything
make all

# Build just extension (installs to REAPER UserPlugins)
make extension

# Build just frontend (copies to reamo.html)
make frontend

# Run frontend dev server with hot reload
make dev

# After extension changes: restart REAPER to load new plugin
```

## Debugging

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
