## Development Notes (Project-Specific)

### Key Files & Resources

- **REAPER API headers**: `docs/reaper_plugin_functions.h` — authoritative function signatures
- **Frontend types**: `frontend/src/core/types.ts` — command IDs, PlayState enum, protocol definitions
- **Test client**: `extension/test-client.html` — browser-based WebSocket testing

### Testing WebSocket Commands

**Getting the session token:**

```bash
# Query EXTSTATE via HTTP (port 8099 or whatever REAPER's HTTP is on)
curl -s "http://localhost:8099/_/GET/EXTSTATE/Reamo/WebsocketPort"
curl -s "http://localhost:8099/_/GET/EXTSTATE/Reamo/SessionToken"
# Returns: EXTSTATE	Reamo	SessionToken	<32-char-hex-token>
```

**Sending commands via websocat:**

```bash
TOKEN="<paste-token-here>"
/bin/bash -c '(echo "{\"type\":\"hello\",\"clientVersion\":\"1.0.0\",\"protocolVersion\":1,\"token\":\"'$TOKEN'\"}"
 echo "{\"type\":\"command\",\"command\":\"transport/playPause\",\"id\":\"1\"}"
 sleep 0.3) | websocat ws://localhost:9224 2>&1 | head -5'
```

**Example commands:**

```json
// Transport
{"type":"command","command":"transport/play","id":"1"}
{"type":"command","command":"transport/stop","id":"2"}
{"type":"command","command":"transport/seek","params":{"position":10.5},"id":"3"}

// Track
{"type":"command","command":"track/setMute","params":{"trackIdx":0},"id":"4"}
{"type":"command","command":"track/setVolume","params":{"trackIdx":0,"volume":0.5},"id":"5"}

// Markers
{"type":"command","command":"marker/add","params":{"position":5.0,"name":"Verse"},"id":"6"}
```

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



### Library Choice

**websocket.zig** (github.com/karlseguin/websocket.zig):

- Uses epoll (Linux) / kqueue (macOS) for non-blocking I/O
- Thread-safe `conn.write()` and `server.stop()`
- Falls back to blocking mode on Windows

---

## Configuration

### Design Philosophy

Non-technical musicians should never see error dialogs or need to configure ports. The extension should "just work" in the common case, with options for advanced users when needed.

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

**Never show `MB_OK` error dialogs.** Musicians don't want modal popups interrupting their session. Console messages are sufficient for debugging.

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

### Thread Safety

**All REAPER API calls must happen on the main thread.** The pattern:

1. WebSocket thread receives command
2. Push to mutex-protected queue
3. Timer callback (main thread) processes queue
4. Execute REAPER API calls
5. Push response/updates to clients

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
