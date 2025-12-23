# Reamo WebSocket Extension Plan

## Overview

This document outlines a plan to build a native REAPER extension (dylib/dll) in Zig that provides a WebSocket-based API for Reamo, replacing the current HTTP polling architecture with a push-based system and enabling new capabilities not possible with REAPER's built-in HTTP control surface.

> **Note for future sessions:** Before implementing, run `git log --oneline -10` to check recent commits. The codebase may have evolved beyond this plan. If you find deviations, check with the human operator before proceeding.

## Project Structure

```txt
├── extension/           # Zig REAPER extension (WebSocket server)
│   ├── src/main.zig     # Plugin entry point
│   ├── build.zig        # Zig 0.15 build config
│   └── build.zig.zon    # Package manifest
├── frontend/            # React timeline UI (Vite + TypeScript)
│   └── src/
├── docs/
│   └── websocket-api-spec.yaml  # OpenAPI 3.0 message schemas (see note below)
├── Makefile             # `make all` builds both, `make extension` installs to REAPER
└── PLAN.md
```

## Project - Current State

- **Phase 1 complete**: WebSocket server running, clients can connect, command queue working
- **Phase 2 complete**: Transport state polling, change detection, play/stop/pause/record/toggle/seek commands
- **Phase 3 complete**: Markers & regions enumeration, change detection, CRUD commands
- **Phase 4 complete**: Items & takes enumeration, time selection filtering, item/take commands
- **Code refactored**: Clean module structure (reaper.zig, transport.zig, markers.zig, items.zig, protocol.zig, commands.zig, ws_server.zig)
- **Next step**: Client Integration (Phase 5)

## Development Notes (Project-Specific)

### Key Files & Resources

- **REAPER API headers**: `docs/reaper_plugin_functions.h` — authoritative function signatures
- **Frontend types**: `frontend/src/core/types.ts` — command IDs, PlayState enum, protocol definitions
- **Test client**: `extension/test-client.html` — browser-based WebSocket testing

### REAPER Extension Gotchas

1. **Use STOP_SAVE (1016) not STOP (40667)** — 40667 can crash if state isn't right
2. **Deferred init is mandatory** — Never start servers in `ReaperPluginEntry`, use timer callback
3. **File logging for debugging**: `/tmp/reamo-extension.log` with timestamps helps debug shutdown issues
4. **websocket.zig shutdown quirk**: The library's `stop()` blocks forever on a condition variable. Solution: detach the thread immediately after starting, skip `stop()` on shutdown, let OS clean up

### Zig Gotchas

1. **Avoid primitive type names as variables** — `i1`, `i2`, `i8`, `u1`, `u8` etc. are Zig types. Use `item1` not `i1`
2. **Use `const` for loop variables** — Zig 0.15 errors on `var` when you don't mutate (e.g., `const w = stream.writer()`)

### Extension Module Structure

```txt
extension/src/
├── main.zig        # Entry point, lifecycle, timers
├── reaper.zig      # REAPER API wrapper, safe function loading
├── transport.zig   # Transport state polling, change detection (has unit tests)
├── markers.zig     # Marker/region state, change detection (has unit tests)
├── items.zig       # Item/take state, time selection filtering (has unit tests)
├── protocol.zig    # JSON parsing/building (has unit tests)
├── commands.zig    # Command registry pattern - add new commands here
└── ws_server.zig   # WebSocket server, client management, ring buffer queue
```

### Adding New Commands

1. Add handler function in `commands.zig`
2. Add entry to `registry` array
3. If new REAPER API needed, add to `reaper.zig` Api struct and load() function

## Background

### Project Philosophy

Reamo is a **songwriting-focused remote control surface** for REAPER. The core philosophy is **"idea capture, not production"** — keeping musicians at their instruments (with a tablet/iPad) rather than at their computers during the creative capture phase.

Key workflows:

- Pre-structure songs with regions (Intro, Verse, Chorus, etc.)
- Stay at instrument with tablet control
- Tap in tempo, capture rough takes quickly
- A/B compare takes without touching the computer
- Make quick keep/trash decisions
- Build a song scaffold, polish later at the desk

The app deliberately avoids becoming a full DAW replacement. Detailed editing, mixing, and production belong in REAPER's native interface.

### Current Architecture Limitations

The app currently uses REAPER's built-in HTTP control surface (`/_/` endpoints), which has significant limitations:

#### 1. Time Selection Sync — Cursor Movement Hack

**File:** `src/hooks/useTimeSelectionSync.ts`

REAPER's HTTP API doesn't expose time selection directly. The current workaround uses a state machine that:

1. Saves current cursor position
2. Moves cursor to project end (baseline)
3. Moves cursor to selection start (checks if position changed)
4. Moves cursor to project start (baseline)
5. Moves cursor to selection end (checks if position changed)
6. Restores original cursor position

**Problems:** Visibly moves the playhead, requires 100ms delays between steps, can interfere with user actions.

#### 2. BPM Reverse-Calculated from BEATPOS

**File:** `src/store/slices/transportSlice.ts:77-100`

No direct BPM endpoint exists. BPM is calculated from beat position data:

```typescript
const rawBpm = (beatPos.fullBeatPosition / beatPos.positionSeconds) * 60;
const calculatedBpm = rawBpm * (4 / beatPos.timeSignatureDenominator);
```

Requires normalization for time signature denominators and has validation bounds (20-300 BPM) suggesting edge cases were encountered.

#### 3. Bar Offset Inference

**File:** `src/hooks/useBarOffset.ts:22-39`

Projects can start at any bar number. No API exists to query bar origin, so it's inferred by comparing REAPER's reported bar with a mathematically calculated bar.

#### 4. Continuous HTTP Polling

**File:** `src/hooks/useReaperConnection.ts:86-97`

No push/subscription mechanism exists. The app polls at 30ms intervals, creating constant HTTP traffic even when nothing changes.

#### 5. Script Detection Polling

**Files:** `src/hooks/useRegionEditScriptDetection.ts`, `src/hooks/useMarkerEditScriptDetection.ts`

Polls EXTSTATE every 5 seconds to check if helper scripts are installed.

#### 6. No Item/Take Access

REAPER's HTTP control surface does not expose media items or takes. This prevents:

- Seeing what was actually recorded in each section
- Managing takes (switch, delete, rename)
- Basic item operations (move, trim, color, notes)

---

## Proposed Solution

Build a native REAPER extension in **Zig** that:

1. Runs a **WebSocket server** inside REAPER's process
2. Provides **push-based state updates** (only send changes)
3. Exposes **direct API access** for time selection, BPM, items, takes
4. Enables **new capabilities** not possible with HTTP control surface

### Why Zig?

- Excellent C interop for consuming REAPER's C API
- Produces .dylib (macOS) and .dll (Windows) directly
- Cross-compilation without additional toolchains
- Proven viable: working REAPER extension proof-of-concept exists
- Memory safety without garbage collection (suitable for audio context)

### Why WebSocket?

| Aspect | Current HTTP | WebSocket |
|--------|--------------|-----------|
| Connections | New connection per poll | 1 persistent |
| Updates | Client polls constantly | Server pushes changes |
| Traffic | ~33 requests/sec, full responses | Deltas only when changed |
| Latency | Poll interval + HTTP overhead | <15ms push |
| Capabilities | Limited to HTTP endpoints | Full REAPER API |

---

## Architecture

```txt
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

### Threading Model

1. **Main thread** (REAPER's GUI thread): All REAPER API calls happen here via timer callback (~30ms or faster)
2. **WebSocket thread**: Handles connections, receives commands, sends responses
3. **Mutex-protected shared state**: Command queue for incoming requests, client list for broadcasting

### Library Choice

**websocket.zig** (github.com/karlseguin/websocket.zig):

- Uses epoll (Linux) / kqueue (macOS) for non-blocking I/O
- Thread-safe `conn.write()` and `server.stop()`
- Falls back to blocking mode on Windows

---

## Installation & Configuration

### Design Philosophy

Non-technical musicians should never see error dialogs or need to configure ports. The extension should "just work" in the common case, with options for advanced users when needed.

### Deferred Initialization

**Critical:** Never start the WebSocket server in `ReaperPluginEntry()`. REAPER's main window may not exist yet, and blocking operations will freeze the startup.

```c
static bool g_needs_init = true;

void deferredInit() {
    if (!g_needs_init) return;
    g_needs_init = false;

    // Now safe to access REAPER APIs and start server
    startWebSocketServer();

    // Unregister timer after initialization
    plugin_register("-timer", deferredInit);
}

int ReaperPluginEntry(HINSTANCE hInstance, reaper_plugin_info_t* rec) {
    if (!rec) {
        // Cleanup on unload
        stopWebSocketServer();
        return 0;
    }

    // Defer actual initialization to first timer tick
    rec->Register("timer", deferredInit);
    return 1;
}
```

### Port Selection

#### Auto-Increment on Conflict

If the default port (9224) is in use, silently try the next port:

```c
int tryStartServer(int basePort, int maxAttempts) {
    for (int i = 0; i < maxAttempts; i++) {
        int port = basePort + i;
        if (startServer(port) == SUCCESS) {
            // Store successful port in EXTSTATE
            SetExtState("Reamo", "WebSocketPort", intToString(port), false);
            return port;
        }
    }
    // All ports failed - log to console, don't show dialog
    ShowConsoleMsg("Reamo: Could not bind to ports 9224-9233\n");
    return -1;
}
```

- Default port: 9224
- Max attempts: 10 (ports 9224-9233)
- No error dialogs on failure — just a console message
- Stores successful port in EXTSTATE for client discovery

#### Manual Configuration

For advanced users or specific network setups, provide a menu command:

**Menu Path:** Extensions → Reamo → Configure Port...

```c
// User input dialog
char buf[64] = "9224";
if (GetUserInputs("Reamo Port Configuration",
                  1,                          // Number of fields
                  "WebSocket Port:",          // Field label
                  buf,                        // Buffer for input
                  sizeof(buf))) {
    int port = atoi(buf);
    if (port >= 1024 && port <= 65535) {
        restartServerOnPort(port);
        SetExtState("Reamo", "WebSocketPort", buf, true);  // persist = true
    }
}
```

The `persist = true` flag saves to `reaper-extstate.ini`, so user-configured ports survive REAPER restarts.

### Menu Integration

Register extension menu items:

```c
// 1. Assign a command ID
int g_commandId = rec->Register("command_id", NULL);

// 2. Create menu entry
gaccel_register_t accel = {
    .accel = { .cmd = g_commandId },
    .desc = "Reamo: Configure Port..."
};
rec->Register("gaccel", &accel);

// 3. Handle command execution
static bool hookCommandProc(int command, int flag) {
    if (command == g_commandId) {
        showPortConfigDialog();
        return true;  // Handled
    }
    return false;  // Not our command
}
rec->Register("hookcommand", hookCommandProc);
```

### Port Discovery (Client Side)

The web UI discovers the WebSocket port by querying EXTSTATE via the existing HTTP control surface:

```javascript
async function discoverWebSocketPort() {
    // Query EXTSTATE through HTTP control surface
    const response = await fetch('/_/GET/EXTSTATE/Reamo/WebSocketPort');
    const text = await response.text();

    // EXTSTATE response is tab-separated: "EXTSTATE\tReamo\tWebSocketPort\t9224"
    const parts = text.trim().split('\t');
    if (parts.length >= 4 && parts[0] === 'EXTSTATE') {
        return parseInt(parts[3], 10);
    }
    return 9224;  // Default fallback
}

async function connectWebSocket() {
    const port = await discoverWebSocketPort();
    const token = await discoverAuthToken();

    const ws = new WebSocket(`ws://localhost:${port}?token=${token}`);
    // ...
}
```

**Benefits:**

- Web UI already knows how to reach HTTP control surface (same host)
- No hardcoded port in client
- Works even when port auto-incremented due to conflict
- Single source of truth (EXTSTATE)

### Authentication

Prevent random processes from connecting to the WebSocket:

#### Session-Based Token

Generate a random token on each REAPER launch:

```c
void generateAuthToken() {
    char token[32];
    // Generate random hex string
    for (int i = 0; i < 16; i++) {
        snprintf(token + i*2, 3, "%02x", rand() % 256);
    }
    SetExtState("Reamo", "AuthToken", token, false);  // persist = false
}
```

- Token changes every REAPER session
- Not persisted (wiped on restart)
- Client queries token via EXTSTATE HTTP, same as port
- WebSocket connection requires `?token=xxx` query parameter

#### Validation

```c
void onWebSocketConnect(ws_conn* conn, const char* url) {
    char* token = extractQueryParam(url, "token");
    char expected[64];
    GetExtState("Reamo", "AuthToken", expected, sizeof(expected));

    if (!token || strcmp(token, expected) != 0) {
        ws_close(conn, 4001, "Invalid token");
        return;
    }

    // Connection accepted
    addClient(conn);
    sendSnapshot(conn);
}
```

#### Why This Works

- Token is only accessible via REAPER's HTTP control surface
- If attacker can query HTTP control surface, they already have full REAPER access
- No user configuration needed — completely transparent
- New token each session — no stale credentials

### Error Handling Philosophy

| Situation | Response |
|-----------|----------|
| Port in use | Silently try next port |
| All ports fail | Console message only |
| WebSocket thread crash | Log error, attempt restart |
| Client sends bad command | Return error response, don't disconnect |
| REAPER shutting down | Graceful WebSocket close |

**Never show `MB_OK` error dialogs.** Musicians don't want modal popups interrupting their session. Console messages are sufficient for debugging.

---

## API Design

> **Detailed API Spec:** See [`docs/websocket-api-spec.yaml`](docs/websocket-api-spec.yaml) for complete message schemas.
> Currently in OpenAPI 3.0 format (with workarounds). TODO: Migrate to [AsyncAPI](https://www.asyncapi.com/) for proper WebSocket API documentation.

### Protocol

```txt
ws://localhost:9224

Messages: JSON
{
  "type": "event" | "command" | "response" | "error",
  "id": "optional-correlation-id",
  "event": "snapshot" | "transport" | "timeSelection" | "markers" | "regions" | "items",
  "command": "transport/play" | "item/setActiveTake" | ...,
  "payload": { ... }
}
```

### Connection Flow

1. Client connects to `ws://localhost:9224`
2. Server sends full state `snapshot` event
3. Server pushes delta updates when state changes
4. Client sends commands, receives responses + state updates

### Delta Strategy: Hybrid with Full State

Rather than sending minimal operation-only deltas (which risk client desync) or always sending everything (wasteful), we use a **hybrid approach**:

**Principle:** Send operation hint + full state per category.

```json
{
  "type": "event",
  "event": "tracks",
  "payload": {
    "hint": { "action": "delete", "trackId": 5 },
    "tracks": [ ...all 9 remaining tracks... ]
  }
}
```

**Benefits:**

- **Simple client logic** — just replace state, no complex diffing
- **Optional hints for UI polish** — animate deletions, highlight additions
- **Self-healing** — if client misses a message, next update corrects state
- **Easy debugging** — full state visible in every message
- **Categories are independent** — track change doesn't resend markers/regions

**When events fire:**

- `transport` — only when transport state changes
- `timeSelection` — only when time selection changes
- `markers` — only when markers change
- `regions` — only when regions change
- `tracks` — only when tracks change
- `items` — only when items change (or time selection changes in Items mode)

**Idle = no traffic.** If nothing changes, nothing is sent.

### Events (Server → Client)

#### snapshot

Sent on connection. Full state dump.

```json
{
  "type": "event",
  "event": "snapshot",
  "payload": {
    "transport": { ... },
    "timeSelection": { ... },
    "project": { ... },
    "markers": [ ... ],
    "regions": [ ... ]
  }
}
```

#### transport

Pushed when transport state changes.

```json
{
  "type": "event",
  "event": "transport",
  "payload": {
    "playState": "playing",
    "positionSeconds": 45.5,
    "positionBeats": "12.3.00",
    "cursorPosition": 45.5,
    "bpm": 120.0,
    "timeSignature": { "numerator": 4, "denominator": 4 },
    "barOffset": 0
  }
}
```

**Key improvement:** `bpm` and `barOffset` are direct values, not calculated.

#### timeSelection

Pushed when time selection changes.

```json
{
  "type": "event",
  "event": "timeSelection",
  "payload": {
    "hasSelection": true,
    "startSeconds": 40.0,
    "endSeconds": 50.0,
    "startFormatted": "11.1.00",
    "endFormatted": "13.3.00",
    "loop": {
      "enabled": false,
      "startSeconds": 0,
      "endSeconds": 0
    }
  }
}
```

**Key improvement:** Direct access via `GetSet_LoopTimeRange2()`, no cursor movement hack.

#### markers / regions

Pushed when markers or regions change.

```json
{
  "type": "event",
  "event": "markers",
  "payload": {
    "markers": [
      {
        "id": 1,
        "position": 10.5,
        "name": "Verse 1",
        "color": 16749525,
        "positionFormatted": "3.1.00"
      }
    ]
  }
}
```

#### items

Pushed when items change or time selection changes (for Items mode).

```json
{
  "type": "event",
  "event": "items",
  "payload": {
    "tracks": [
      {
        "trackId": 4,
        "trackName": "Guitar",
        "items": [
          {
            "itemId": 101,
            "position": 13.2,
            "length": 5.8,
            "color": 16749525,
            "locked": false,
            "notes": "",
            "activeTakeIndex": 2,
            "takeCount": 3,
            "takes": [
              { "index": 0, "name": "04-AGTR-09.wav", "color": 0 },
              { "index": 1, "name": "", "color": 0 },
              { "index": 2, "name": "keeper!", "color": 16749525 }
            ]
          }
        ]
      }
    ]
  }
}
```

### Commands (Client → Server)

#### Transport Commands

```txt
transport/play
transport/pause
transport/stop
transport/record
transport/toggle
transport/seek        { position: seconds }
transport/seekBeats   { bar: int, beat: number }
```

#### Time Selection Commands

```txt
timeSelection/set     { startSeconds, endSeconds }
timeSelection/clear
timeSelection/setLoop { startSeconds, endSeconds, enabled }
```

#### Marker Commands

```txt
marker/add            { position, name?, color? }
marker/update         { id, position?, name?, color? }
marker/delete         { id }
marker/goto           { id }
```

#### Region Commands

```txt
region/add            { start, end, name?, color? }
region/update         { id, start?, end?, name?, color? }
region/delete         { id }
region/goto           { id }
```

#### Item Commands

```txt
item/setActiveTake    { itemId, takeIndex }
item/deleteTake       { itemId }              // Deletes active take
item/cropToActiveTake { itemId }              // Keep active, delete others
item/move             { itemId, position }
item/trim             { itemId, start, end }
item/setColor         { itemId, color }
item/setLocked        { itemId, locked }
item/setNotes         { itemId, notes }
item/delete           { itemId }
```

#### Take Commands

```txt
take/setName          { itemId, takeIndex, name }
```

#### Batch Commands

```txt
batch                 { commands: [ ... ] }   // Atomic execution
```

### Responses

```json
{
  "type": "response",
  "id": "cmd-123",
  "success": true,
  "payload": { "id": 42 }
}
```

### Errors

```json
{
  "type": "error",
  "id": "cmd-123",
  "error": {
    "code": "NOT_FOUND",
    "message": "Item 999 not found"
  }
}
```

---

## New Feature: Items Mode

### Rationale

The current app shows regions (song structure) but not what's actually recorded in them. Users must go to the computer to see/manage takes. This breaks the "stay at instrument" workflow.

### UI Concept

**Level of Detail (LOD) approach:**

**Zoomed Out (Navigate/Regions mode):**
Items shown as aggregate blobs — visual reference only, read-only.

```txt
┌─────────────────────────────────────────┐
│ Verse 1          │ Chorus               │
│ ▓▓░░▓▓▓░░▓▓     │ ▓▓▓▓░░░▓▓           │
└─────────────────────────────────────────┘
```

**Zoomed In (Items mode):**
Double-tap region or zoom to time selection. Single track view with detailed item management.

```txt
┌─────────────────────────────────────────────────────┐
│ Track: Guitar ▼              [Time Selection]       │
├─────────────────────────────────────────────────────┤
│                                                     │
│    ┌─────────────┐              ┌─────────────┐    │
│    │     1/3     │              │     2/3     │    │
│    │ ▓▓▓▓▓▓▓▓▓▓▓ │              │ ▓▓▓▓▓▓▓▓▓▓▓ │    │
│    └─────────────┘              └─────────────┘    │
│         ▲                                          │
│     (selected)                                     │
├─────────────────────────────────────────────────────┤
│ Take 1 of 3  [◀][▶]  [Crop] [🗑] [Notes] [Color]   │
└─────────────────────────────────────────────────────┘
```

**Key UI decisions:**

- Show ONE track at a time (not all tracks)
- Track dropdown shows tracks with items in the time selection
- Items shown as single bars (active take color) with take count badge ("1/3")
- No visual stacking of takes (unlike REAPER's arrange view)
- ItemInfoBar for selected item: take switching, actions

### Supported Item Actions

| Action | Purpose | REAPER API |
|--------|---------|------------|
| Switch take | Navigate takes | `SetMediaItemInfo_Value(item, "I_CURTAKE", index)` |
| Delete take | Remove bad take | `Main_OnCommand(40129, 0)` |
| Crop to active | "This is the keeper" | `Main_OnCommand(40131, 0)` |
| Move item | Nudge position | `SetMediaItemInfo_Value(item, "D_POSITION", pos)` |
| Trim item | Adjust boundaries | Modify `D_POSITION` + `D_LENGTH` + take offsets |
| Set color | Visual organization | `SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", color)` |
| Lock | Protect from accidents | `SetMediaItemInfo_Value(item, "C_LOCK", 1)` |
| Add notes | "Good energy", etc. | `GetSetMediaItemInfo_String(item, "P_NOTES", ...)` |
| Delete item | Remove entirely | `DeleteTrackMediaItem(track, item)` |

### What This Is NOT

- No comping lanes
- No crossfades
- No waveform editing
- No split/glue
- No detailed MIDI editing

Just: **"See what I recorded, tidy it up, make quick keep/trash decisions, move on."**

---

## Enhancement: Metering with Clip Indicators

### Metering - Current State

The app has input metering but it's transient-only — no peak hold or clip indication. Users can't tell at a glance if they clipped during a take.

### Proposed Enhancement

Add sticky clip indicators that persist until manually cleared:

```json
{
  "type": "event",
  "event": "meters",
  "payload": {
    "tracks": [
      {
        "trackId": 1,
        "peak": 0.85,
        "clipped": true,
        "clipCount": 3
      }
    ]
  }
}
```

| Field | Description |
|-------|-------------|
| `peak` | Current peak level (0.0 - 1.0+) |
| `clipped` | Sticky flag, true if signal exceeded 0dBFS |
| `clipCount` | Number of clip events this session |

### UI Behavior

- Show red indicator on track meter when `clipped: true`
- Tap meter to reset clip indicator for that track
- Optional: show clip count badge

### REAPER API

```c
// Get track peak volume
double GetTrackPeakInfo(MediaTrack* track, int idx);
// idx: 0=left, 1=right, for stereo tracks

// Clip detection would need to be tracked in extension
// (check if peak > 1.0 and set sticky flag)
```

### Why It Matters

"Is my input level OK?" — users need to know without squinting at the computer across the room. A persistent clip indicator answers this at a glance.

---

## REAPER API Reference

### Extension Entry Point

```c
extern "C" int ReaperPluginEntry(HINSTANCE hInstance, reaper_plugin_info_t *rec);

typedef struct reaper_plugin_info_t {
    int caller_version;  // Must match REAPER_PLUGIN_VERSION (0x20E)
    HWND hwnd_main;
    int (*Register)(const char *name, void *infostruct);
    void* (*GetFunc)(const char *name);
} reaper_plugin_info_t;
```

### Timer Registration (Main Thread Callbacks)

```c
// Register: runs at ~30Hz on main thread
rec->Register("timer", (void*)MyTimerCallback);

// Unregister on shutdown
rec->Register("-timer", (void*)MyTimerCallback);
```

### Key API Functions

#### Transport & Time Selection

```c
int GetPlayState();                              // &1=playing, &2=paused, &4=recording
double GetPlayPosition();                        // Playback position (seconds)
double GetCursorPosition();                      // Edit cursor position (seconds)
void GetProjectTimeSignature2(proj, &bpm, &num, &denom);  // Direct BPM!
void GetSet_LoopTimeRange2(proj, isSet, isLoop, &start, &end, allowAuto);  // Direct time selection!
int GetProjectStateChangeCount(proj);            // Change detection
```

#### Items & Takes

```c
// Enumeration (no GetItemsInTimeRange — must iterate and filter)
int CountMediaItems(proj);
MediaItem* GetMediaItem(proj, idx);
int CountTrackMediaItems(track);
MediaItem* GetTrackMediaItem(track, idx);

// Item properties
double GetMediaItemInfo_Value(item, "D_POSITION");   // Position
double GetMediaItemInfo_Value(item, "D_LENGTH");     // Length
int GetMediaItemInfo_Value(item, "I_CURTAKE");       // Active take index
int GetMediaItemInfo_Value(item, "I_CUSTOMCOLOR");   // Color
int GetMediaItemInfo_Value(item, "C_LOCK");          // Locked state
bool GetSetMediaItemInfo_String(item, "P_NOTES", buf, false);  // Notes

// Takes
int GetMediaItemNumTakes(item);
MediaItem_Take* GetMediaItemTake(item, idx);
MediaItem_Take* GetActiveTake(item);
void SetActiveTake(take);  // Or SetMediaItemInfo_Value(item, "I_CURTAKE", idx)

// Take properties
char* via GetSetMediaItemTakeInfo_String(take, "P_NAME", buf, false);  // Name
int GetMediaItemTakeInfo_Value(take, "I_CUSTOMCOLOR");                  // Color

// Take operations (no direct DeleteTake API)
Main_OnCommand(40129, 0);  // Delete active take
Main_OnCommand(40131, 0);  // Crop to active take

// Item operations
SetMediaItemInfo_Value(item, "D_POSITION", newPos);  // Move
DeleteTrackMediaItem(track, item);                    // Delete

// Undo
Undo_BeginBlock2(0);
// ... modifications ...
Undo_EndBlock2(0, "Description", UNDO_STATE_ITEMS);
```

### Thread Safety

**All REAPER API calls must happen on the main thread.** The pattern:

1. WebSocket thread receives command
2. Push to mutex-protected queue
3. Timer callback (main thread) processes queue
4. Execute REAPER API calls
5. Push response/updates to clients

---

## Codebase Migration Strategy (TBD)

> **Note:** This strategy is not set in stone. The exact approach will be refined as implementation progresses.

### Proposed Approach: Parallel & Incremental

Rather than a big-bang rewrite, run both connection types in parallel and migrate incrementally:

#### Phase A: Run Both

- Keep existing HTTP connection working
- Add WebSocket as optional/experimental connection type
- Feature flag or config to switch between them

#### Phase B: New Features on WebSocket Only

- Items mode only available via WebSocket
- Metering enhancements only via WebSocket
- This drives adoption of the new path

#### Phase C: Migrate Existing Features

- Transport → WebSocket (remove BPM reverse-calculation)
- Time selection → WebSocket (remove cursor movement hack)
- Markers/Regions → WebSocket
- Each migration is isolated and testable

#### Phase D: Deprecate HTTP

- Remove `ReaperConnection.ts` and HTTP polling code
- Remove `useTimeSelectionSync.ts` (cursor hack)
- Remove workaround code in slices
- Clean, single code path

### Files Likely to Change

| Action | File(s) |
|--------|---------|
| Replace | `src/core/ReaperConnection.ts` → new `WebSocketConnection.ts` |
| Delete | `src/hooks/useTimeSelectionSync.ts` |
| Simplify | `src/store/slices/transportSlice.ts` (remove BPM calculation) |
| Delete | `src/hooks/useBarOffset.ts` (server provides directly) |
| Delete | `src/hooks/useRegionEditScriptDetection.ts` (no longer needed) |
| Delete | `src/hooks/useMarkerEditScriptDetection.ts` (no longer needed) |
| Add | Items mode UI components |
| Add | WebSocket message types and handlers |

### Benefits of Incremental Approach

- App keeps working throughout migration
- Each piece can be tested in isolation
- Easy to rollback if issues found
- Team can learn WebSocket patterns gradually

---

## Potential Enhancement: Client-Side Interpolation (Research Needed)

### The Problem

Currently the time display updates at ~30ms intervals (33fps), which can appear slightly choppy. Even with WebSocket, if we push position updates at 30-50ms intervals, the display won't be buttery smooth.

### Potential Solution

**Client-side interpolation:** Instead of displaying exactly what the server sends, the client predicts position between updates:

```text
Server pushes (every ~50ms):
├── positionSeconds: 45.5
├── playState: "playing"
├── bpm: 120

Client interpolates (every ~16ms / 60fps):
├── displayPosition = serverPosition + (timeSinceLastUpdate × playRate)
├── Smooth animation via requestAnimationFrame
├── Re-sync when next server update arrives
```

### How It Would Work

1. Server pushes position + playState + BPM
2. Client stores timestamp of last update
3. When `playState === "playing"`:
   - Run `requestAnimationFrame` loop at 60fps
   - Calculate: `display = lastPosition + (elapsed × bpm/60)`
   - Small drift corrected on each server sync
4. When `playState !== "playing"`:
   - Stop interpolation, display exact server position

### Trade-offs

| Pros | Cons |
|------|------|
| Buttery smooth 60fps display | More client complexity |
| Works regardless of network latency | Potential for small drift |
| Standard technique in remote controls | Needs careful sync logic |

### Status

**Undecided.** Need more research on:

- How much visual improvement in practice?
- Complexity vs. benefit trade-off
- How other DAW remote controls handle this
- Whether the current choppiness is even noticeable to users

This may be a "nice to have" optimization rather than essential.

---

## Implementation Phases

### Phase 1: Core Extension ✅

- [x] Zig project setup with build.zig for dylib/dll output
- [x] REAPER plugin entry point and API function loading
- [x] Timer callback registration
- [x] WebSocket server on background thread
- [x] Mutex-protected command queue (ring buffer)

### Phase 2: Transport & Time Selection ✅

- [x] Transport state polling and change detection
- [x] Direct time selection via GetSet_LoopTimeRange2
- [x] Direct BPM via GetProjectTimeSignature2
- [x] Push-based updates to connected clients
- [x] Transport commands (play, pause, stop, seek, toggle, record)

### Phase 3: Markers & Regions ✅

- [x] Marker/region enumeration and change detection
- [x] CRUD commands for markers and regions (add, update, delete, goto)
- [x] Push-based updates (full state per category, as designed)

### Phase 4: Items & Takes ✅

- [x] Item enumeration within time selection (filters to overlapping items)
- [x] Take enumeration per item (with isActive flag)
- [x] Item/take property access (position, length, color, locked, notes, activeTakeIdx)
- [x] Item commands (setActiveTake, move, color, lock, notes, delete, goto)
- [x] Take commands (delete, cropToActive via REAPER action commands)

**Implementation notes:**
- Items identified by `trackIdx` + `itemIdx` pair (not unique IDs)
- Time selection filtering: only items overlapping selection are broadcast
- Take operations use REAPER's built-in action commands (40129, 40131) which operate on selected items

### Phase 5: Client Integration

- [ ] Update Reamo to use WebSocket connection
- [ ] Remove HTTP polling code
- [ ] Remove time selection hack
- [ ] Remove BPM calculation workaround
- [ ] Implement Items mode UI

---

## Resources

### Official Documentation

- REAPER SDK: <https://www.reaper.fm/sdk/plugin/plugin.php>
- ReaScript API: <https://www.reaper.fm/sdk/reascript/reascripthelp.html>
- Plugin header: <https://www.reaper.fm/sdk/plugin/reaper_plugin.h>

### Reference Implementations

- REAPER SDK (GitHub): <https://github.com/justinfrankel/reaper-sdk>
- SWS Extension: <https://github.com/reaper-oss/sws>
- Zig REAPER extension: <https://gist.github.com/cfillion/f32b04e75e84e03cc463abb1eda41400>
- websocket.zig: <https://github.com/karlseguin/websocket.zig>

### Related Projects

- reaper-rs (Rust bindings): <https://github.com/helgoboss/reaper-rs>
- reapy (Python): <https://github.com/Levitanus/reapy-boost>
- reaper-websockets (OSC bridge): <https://github.com/lucianoiam/reaper-websockets>

---

## Distribution

### Installation Model

Follow the SWS pattern — the gold standard for REAPER extension distribution:

#### Installer Packages

| Platform | Format | Contents |
|----------|--------|----------|
| Windows | `.exe` (NSIS or similar) | `reaper_reamo.dll` → `%APPDATA%\REAPER\UserPlugins\` |
| macOS | `.pkg` or `.dmg` | `reaper_reamo.dylib` → `~/Library/Application Support/REAPER/UserPlugins/` |

**Installer responsibilities:**

- Detect REAPER installation (portable vs standard)
- Copy dylib/dll to correct UserPlugins folder
- Optionally offer to install for all users vs current user
- Show brief "what is this" explanation
- No restart required (REAPER loads plugins on next launch)

#### Manual Installation

For power users or portable REAPER installs:

1. Download `reaper_reamo.dylib` (macOS) or `reaper_reamo.dll` (Windows)
2. Copy to REAPER's `UserPlugins` folder
3. Restart REAPER

#### ReaPack (Future)

Consider ReaPack distribution for automatic updates:

- Requires maintaining a ReaPack index
- Enables one-click install from within REAPER
- Automatic update notifications
- Lower friction for users already using ReaPack

### GitHub Releases

Each release includes:

```txt
reamo-extension-v1.0.0/
├── Reamo-1.0.0-Windows.exe       # Windows installer
├── Reamo-1.0.0-macOS.pkg         # macOS installer
├── reaper_reamo.dll              # Windows manual install
├── reaper_reamo.dylib            # macOS manual install
├── CHANGELOG.md
└── README.md
```

### Build Matrix

Zig's cross-compilation makes this straightforward:

```bash
# From macOS, build both targets
zig build -Dtarget=x86_64-windows    # → reaper_reamo.dll
zig build -Dtarget=x86_64-macos      # → reaper_reamo.dylib
zig build -Dtarget=aarch64-macos     # → reaper_reamo.dylib (Apple Silicon)
```

Universal binary for macOS (Intel + Apple Silicon) via `lipo` or Zig's multi-target support.

---

## Versioning

### Why Version Everything

A version mismatch between client and extension can cause silent failures, confusing errors, or crashes. Version from day one to avoid pain later.

### Extension Versioning

Semantic versioning: `MAJOR.MINOR.PATCH`

- **MAJOR**: Breaking protocol changes (client must update)
- **MINOR**: New features, backwards compatible
- **PATCH**: Bug fixes only

Embed version in the extension:

```c
#define REAMO_VERSION_MAJOR 1
#define REAMO_VERSION_MINOR 0
#define REAMO_VERSION_PATCH 0
#define REAMO_VERSION_STRING "1.0.0"
```

### Protocol Versioning

Include protocol version in the connection handshake:

**Client → Server (on connect):**

```json
{
  "type": "hello",
  "clientVersion": "1.2.0",
  "protocolVersion": 1
}
```

**Server → Client (snapshot includes version):**

```json
{
  "type": "event",
  "event": "snapshot",
  "payload": {
    "extensionVersion": "1.0.0",
    "protocolVersion": 1,
    "transport": { ... },
    "regions": [ ... ]
  }
}
```

### Compatibility Rules

| Scenario | Behavior |
|----------|----------|
| Protocol versions match | Normal operation |
| Client protocol > Server | Client shows "Please update REAPER extension" |
| Server protocol > Client | Server sends error, client shows "Please update Reamo app" |
| Minor version difference | Continue (backwards compatible) |

### Version Check on Connect

```c
void onClientHello(ws_conn* conn, JsonObject* msg) {
    int clientProtocol = json_get_int(msg, "protocolVersion");

    if (clientProtocol < REAMO_PROTOCOL_VERSION) {
        // Client too old
        sendError(conn, "PROTOCOL_MISMATCH",
            "Client protocol v%d is outdated. Server requires v%d.",
            clientProtocol, REAMO_PROTOCOL_VERSION);
        ws_close(conn, 4002, "Protocol mismatch");
        return;
    }

    if (clientProtocol > REAMO_PROTOCOL_VERSION) {
        // Server too old - this is fine, client should handle gracefully
        // Log it but continue
        ShowConsoleMsg("Reamo: Client has newer protocol version\n");
    }

    // Proceed with connection
    sendSnapshot(conn);
}
```

### EXTSTATE Version

Expose version via EXTSTATE for diagnostics:

```c
SetExtState("Reamo", "ExtensionVersion", REAMO_VERSION_STRING, false);
```

Client can query this before attempting WebSocket connection to pre-check compatibility.

---

## Robustness & Testing

### Prime Directive: Never Crash REAPER

**A crash in our extension = potential data loss for the user.**

REAPER may have unsaved project changes. A crash could lose hours of work. This is unacceptable. The extension must be bulletproof.

### Defensive Programming Principles

#### 1. Validate Everything

```c
void handleCommand(const char* json) {
    if (!json) return;
    if (strlen(json) > MAX_COMMAND_SIZE) {
        sendError(conn, "PAYLOAD_TOO_LARGE", "Command exceeds size limit");
        return;
    }

    JsonObject* cmd = json_parse(json);
    if (!cmd) {
        sendError(conn, "INVALID_JSON", "Failed to parse command");
        return;
    }

    // Validate required fields before using
    const char* type = json_get_string(cmd, "type");
    if (!type) {
        sendError(conn, "MISSING_FIELD", "Command missing 'type' field");
        json_free(cmd);
        return;
    }

    // ... process command ...
    json_free(cmd);
}
```

#### 2. Bounds Check All Arrays

```c
void setActiveTake(MediaItem* item, int takeIndex) {
    if (!item) return;

    int numTakes = GetMediaItemNumTakes(item);
    if (takeIndex < 0 || takeIndex >= numTakes) {
        sendError(conn, "INVALID_TAKE_INDEX",
            "Take index %d out of range (0-%d)", takeIndex, numTakes - 1);
        return;
    }

    // Safe to proceed
    SetMediaItemInfo_Value(item, "I_CURTAKE", takeIndex);
}
```

#### 3. Handle NULL from REAPER APIs

REAPER functions can return NULL. Always check:

```c
MediaItem* item = GetMediaItem(proj, itemIndex);
if (!item) {
    sendError(conn, "NOT_FOUND", "Item %d not found", itemIndex);
    return;
}

MediaItem_Take* take = GetActiveTake(item);
if (!take) {
    // Item exists but has no takes - valid state, not an error
    // Handle accordingly
}
```

#### 4. Catch Panics (Zig)

Zig's `@panic` can be caught to prevent crashes:

```zig
fn safeHandleMessage(conn: *Connection, msg: []const u8) void {
    handleMessage(conn, msg) catch |err| {
        // Log error, send error response, but don't crash
        log.err("Error handling message: {}", .{err});
        sendError(conn, "INTERNAL_ERROR", "Unexpected error occurred");
    };
}
```

#### 5. Timeouts on Everything

No operation should hang indefinitely:

```c
// WebSocket read timeout
ws_set_timeout(conn, 30000);  // 30 seconds

// If parsing takes too long, abort
if (parse_time > MAX_PARSE_TIME_MS) {
    sendError(conn, "TIMEOUT", "Request processing timeout");
    return;
}
```

#### 6. Memory Safety

Zig provides memory safety by default. Additionally:

- Use arena allocators for request-scoped memory
- Clear/free all allocations before returning
- No manual pointer arithmetic
- No use-after-free possible with Zig's ownership model

#### 7. Safe Numeric Conversions

Zig's `@intFromFloat` will panic on NaN/Inf values. REAPER APIs return floats that may be corrupt. Always use safe wrappers:

```zig
// Generic safe conversion (reaper.zig)
fn safeFloatToInt(comptime T: type, val: f64, default: T) T {
    if (std.math.isNan(val) or std.math.isInf(val)) return default;
    const min_val: f64 = @floatFromInt(std.math.minInt(T));
    const max_val: f64 = @floatFromInt(std.math.maxInt(T));
    const clamped = @max(min_val, @min(max_val, val));
    return @intFromFloat(clamped);
}

// Domain-specific with clamping (transport.zig)
fn safeTimeSigNum(val: f64) u32 {
    if (std.math.isNan(val) or std.math.isInf(val)) return 4;
    const clamped = @max(1.0, @min(32.0, val));  // Valid range: 1-32
    return @intFromFloat(clamped);
}

// Input validation at trust boundary (commands.zig)
fn validatePosition(pos: ?f64) ?f64 {
    const p = pos orelse return null;
    if (std.math.isNan(p) or std.math.isInf(p)) return null;
    if (p < 0) return null;
    return p;
}
```

Use the appropriate pattern:
- `safeFloatToInt`: When reading REAPER API values that become integers
- Domain-specific (like `safeTimeSigNum`): When valid ranges are known
- `validatePosition`: At WebSocket boundary to reject bad client input

### Testing Strategy

#### Unit Tests

Test individual functions in isolation:

```zig
test "parseTransportState handles missing fields" {
    const json = "{}";
    const result = parseTransportState(json);
    try testing.expect(result == null);
}

test "formatPosition handles negative time" {
    const result = formatPosition(-1.0);
    try testing.expectEqualStrings("0.0.00", result);
}
```

#### Integration Tests

Test against a real REAPER instance:

```python
# test_integration.py
def test_transport_play():
    ws = connect_to_reamo()

    # Send play command
    ws.send('{"type":"command","id":"1","command":"transport/play"}')

    # Wait for response
    response = ws.recv(timeout=1.0)
    assert response["type"] == "response"
    assert response["success"] == True

    # Verify state update received
    update = ws.recv(timeout=1.0)
    assert update["event"] == "transport"
    assert update["payload"]["playState"] == "playing"
```

#### Fuzz Testing

Throw garbage at the WebSocket and ensure no crashes:

```bash
# Use a fuzzer to generate random WebSocket messages
# Extension must never crash, only return errors
```

Test cases:

- Empty messages
- Invalid JSON
- Valid JSON, invalid schema
- Extremely long strings
- Negative numbers where positive expected
- Missing required fields
- Extra unexpected fields
- Binary data (not JSON)
- Rapid connect/disconnect
- Many simultaneous connections
- Messages during REAPER shutdown

#### Stress Testing

```python
def test_high_frequency_commands():
    ws = connect_to_reamo()

    # Send 1000 commands as fast as possible
    for i in range(1000):
        ws.send(f'{{"type":"command","id":"{i}","command":"transport/seek","payload":{{"position":{i}}}}}')

    # Extension should handle all without crashing
    # May return errors for some, but never crash
```

### Logging

Comprehensive logging for debugging production issues:

```c
#define LOG_DEBUG 0
#define LOG_INFO  1
#define LOG_WARN  2
#define LOG_ERROR 3

void reamo_log(int level, const char* fmt, ...) {
    if (level < g_log_level) return;

    char buf[1024];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);

    // Output to REAPER console
    ShowConsoleMsg(buf);
    ShowConsoleMsg("\n");

    // Optionally write to file for persistent logs
    if (g_log_file) {
        fprintf(g_log_file, "[%s] %s\n", timestamp(), buf);
        fflush(g_log_file);
    }
}
```

Log levels configurable via EXTSTATE:

```c
// User can set: Extensions → Reamo → Set Log Level...
// "DEBUG" | "INFO" | "WARN" | "ERROR"
char level[32];
GetExtState("Reamo", "LogLevel", level, sizeof(level));
```

### Graceful Degradation

If something goes wrong, degrade gracefully rather than crash:

| Failure | Response |
|---------|----------|
| WebSocket thread panic | Log, restart thread, notify clients |
| REAPER API returns unexpected value | Log warning, skip operation, continue |
| Out of memory | Return error to client, don't allocate |
| JSON parse failure | Return error, don't crash |
| Client sends garbage | Disconnect that client, others unaffected |

### Pre-Release Checklist

Before any release:

- [ ] All unit tests pass
- [ ] All integration tests pass
- [ ] Fuzz testing: 10,000 random messages, zero crashes
- [ ] Stress testing: 1,000 rapid commands, zero crashes
- [ ] Memory leak check (Zig's leak detection or Valgrind)
- [ ] Test on Windows (x64)
- [ ] Test on macOS Intel
- [ ] Test on macOS Apple Silicon
- [ ] Test with portable REAPER install
- [ ] Test REAPER startup with extension loaded
- [ ] Test REAPER shutdown with active connections
- [ ] Test disconnect/reconnect cycle
- [ ] Manual smoke test of all commands

---

## Open Questions

1. ~~**Port number:** Is 9224 appropriate, or should it be configurable?~~
   **Resolved:** Default 9224, auto-increment on conflict (9224-9233), manual config via Extensions menu. See [Installation & Configuration](#installation--configuration).

2. ~~**Multiple clients:** Support multiple simultaneous connections?~~
   **Resolved:** Yes. Server maintains client list, broadcasts to all. Enables phone + tablet, or collaborative use with bandmates. Conflicts self-resolve via delta strategy (e.g., two users delete same region → first succeeds, second gets "not found", both receive updated state).

3. ~~**Authentication:** Any need for connection authentication?~~
   **Resolved:** Session-based token generated on REAPER launch, stored in EXTSTATE, queried by client via HTTP, passed as WebSocket query parameter. See [Authentication](#authentication).

4. ~~**Backwards compatibility:** Run alongside HTTP control surface or replace?~~
   **Resolved:** Run alongside. WebSocket uses different port (9224) than HTTP control surface. Client discovers port via EXTSTATE query through HTTP. Migration is incremental. See [Migration Strategy](#codebase-migration-strategy-tbd).

5. ~~**Error recovery:** How to handle REAPER crashes/restarts?~~
   **Resolved:** Keep it simple:
   - WebSocket disconnect → client shows red status icon immediately, auto-retry with backoff (1s, 2s, 4s...)
   - Reconnection → server sends fresh snapshot, client instantly in sync
   - Command fails → return error response, client shows toast, no auto-retry
   - Delta strategy provides self-healing — any missed update corrected by next event
   - Transport commands (play/stop/seek) can be optimistic; data mutations (regions, items) wait for response

6. **Performance threshold:** How fast can we poll internally? 10ms? 5ms?
   **Status:** Open. Needs real-world measurement. REAPER timer documented as ~30Hz but may vary. Start with default rate, measure, optimize if needed. Human perception threshold: ~100ms for UI, ~20ms for audio feedback.

---

## Success Criteria

1. **Eliminate workarounds:**
   - Time selection accessible without cursor movement
   - BPM directly available, not calculated
   - Bar offset directly available, not inferred

2. **Reduce client complexity:**
   - Single WebSocket connection vs multiple HTTP requests
   - Push-based updates vs constant polling
   - No client-side state calculation

3. **Enable new capabilities:**
   - Item/take visibility in time selection
   - Basic take management (switch, delete, crop)
   - Basic item management (move, trim, notes)

4. **Maintain philosophy:**
   - "Idea capture, not production"
   - Stay at instrument
   - Quick decisions, polish later
