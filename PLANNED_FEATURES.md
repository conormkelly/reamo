# Planned Features

## Table of Contents (Priority Order)

1. [View Switcher](#view-switcher) — Tab bar + persistent transport with 7 views, Studio default *(see [full spec](features/VIEW_SWITCHER_FEATURE.md))*
2. [Items Mode](#items-mode) — View/manage recorded takes without leaving the instrument
3. [Track Management](#track-management) — Rename, create, duplicate, delete tracks *(see [full spec](features/TRACK_MANAGEMENT_FEATURE.md))*
4. [Cue List](#cue-list) — Setlist/playlist mode with SWS import *(see [full spec](features/CUE_LIST_FEATURE.md))*
5. [FX Preset Switching](#fx-preset-switching) — Navigate REAPER-saved presets from tablet ✅
6. [Send Control](#send-control) — Adjust send levels to aux/cue buses *(see [full spec](features/SEND_CONTROL_FEATURE.md))* ✅
7. [Project Notes](#project-notes-support) — Session metadata accessible from tablet ✅
8. [Minor Enhancements](#minor-enhancements) — isDirty flag, SMPTE timecode
9. [Public Release](#public-release) — Cross-platform builds and GitHub distribution
10. [Extension Performance Optimizations](#extension-performance-optimizations) — Idle when no clients (low priority)

---

## Public Release

### Cross-Platform Builds

Zig cross-compilation verified working from macOS:

| Target | Command | Output |
|--------|---------|--------|
| macOS ARM | `zig build` | `libreaper_reamo.dylib` (arm64) |
| macOS x64 | `zig build -Dtarget=x86_64-macos` | `libreaper_reamo.dylib` (x86_64) |
| Windows x64 | `zig build -Dtarget=x86_64-windows-gnu` | `reaper_reamo.dll` |
| Linux x64 | `zig build -Dtarget=x86_64-linux-gnu` | `libreaper_reamo.so` |

**Note:** Windows DLL outputs to `zig-out/bin/`, not `zig-out/lib/`.

---

### GitHub Release Artifacts

```
Reamo-v0.1.0-macOS-arm64.zip
Reamo-v0.1.0-macOS-x64.zip
Reamo-v0.1.0-Windows-x64.zip
Reamo-v0.1.0-Linux-x64.zip
```

Each ZIP contains:
- `reaper_reamo.dylib` (or `.dll`/`.so`)
- `reamo.html`
- `README.txt` (quick install steps)

---

### Installation Paths

| OS | UserPlugins (extension) | www folder (frontend) |
|----|-------------------------|----------------------|
| macOS | `~/Library/Application Support/REAPER/UserPlugins/` | `~/Library/Application Support/REAPER/reaper_www_root/` |
| Windows | `%APPDATA%\REAPER\UserPlugins\` | `%APPDATA%\REAPER\reaper_www_root\` |
| Linux | `~/.config/REAPER/UserPlugins/` | `~/.config/REAPER/reaper_www_root/` |

---

### Release Checklist

#### Phase 1: Beta (GitHub Releases)

- [ ] Build all 4 platform binaries
- [ ] Create ZIP archives with extension + frontend + README.txt
- [ ] Update main README.md with download table
- [ ] Create GitHub Release (mark as Pre-release)
- [ ] Post to r/Reaper for testers

#### Phase 2: Stable (after testing)

- [ ] Confirm Windows/Linux work from community testers
- [ ] Remove Pre-release tag
- [ ] Consider ReaPack integration for one-click install

---

### Future: ReaPack Integration

ReaPack is REAPER's package manager. Users add a repo URL → one-click install/update.

**Requirements:**
- Host `index.xml` on GitHub Pages or in repo
- Point to release ZIPs per platform
- Maintain version metadata

**Skip for v0.1** — manual install is fine for 2 files. Add ReaPack for v0.2+ when stable.

---

## FX Preset Switching

### Rationale

Guitarists and keyboard players want to switch between tones/patches without walking to the computer. While most modern plugins (Neural DSP, Kontakt, etc.) use internal preset browsers that bypass REAPER's API, **REAPER's own preset system works universally**.

**The workflow:**
1. User dials in a tone in their plugin
2. User saves it as a REAPER preset (click "+" in FX header)
3. REAPER stores complete plugin state in `.rpl` file
4. Reamo can browse and switch these presets

This trades factory preset discovery for universal compatibility. For guitarists with 20-50 curated tones, this is actually preferred — they don't need 500 factory presets, just their saved tones.

**For plugins with internal browsers:** Use the Toolbar with MIDI CC to control preset switching via the plugin's MIDI learn feature.

---

### REAPER API

```c
// Get current preset index and count
int TrackFX_GetPresetIndex(MediaTrack* track, int fx, int* numberOfPresetsOut);
// Returns: current index (0-based), or -1 on error
// numberOfPresetsOut: total preset count (factory + user)

// Set preset by index
bool TrackFX_SetPresetByIndex(MediaTrack* track, int fx, int presetIndex);
// Special values: -1 = default user preset, -2 = factory defaults

// Get current preset name
bool TrackFX_GetPreset(MediaTrack* track, int fx, char* presetname, int presetname_sz);
// Returns: true if parameters match loaded preset exactly

// Navigate presets relatively
bool TrackFX_NavigatePresets(MediaTrack* track, int fx, int presetmove);
// presetmove: +1 = next, -1 = previous
```

**Key limitation:** No API to enumerate preset names. Can only get count and current name. Must iterate (slow) to build full list.

---

### State Changes

Extend tracks event with FX info:

```json
{
  "type": "event",
  "event": "tracks",
  "payload": {
    "tracks": [{
      "idx": 1,
      "name": "Guitar",
      "fx": [{
        "name": "Neural DSP Archetype Gojira",
        "presetName": "My Clean Tone",
        "presetIndex": 3,
        "presetCount": 12,
        "modified": false
      }]
    }]
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `fx[].name` | string | Plugin name |
| `fx[].presetName` | string | Current preset name |
| `fx[].presetIndex` | int | Current preset index (0-based) |
| `fx[].presetCount` | int | Total preset count |
| `fx[].modified` | bool | Parameters changed since preset load |

---

### Protocol

**Navigate presets:**
```json
{"type": "command", "command": "fx/presetNext", "trackIdx": 1, "fxIdx": 0, "id": "1"}
{"type": "command", "command": "fx/presetPrev", "trackIdx": 1, "fxIdx": 0, "id": "1"}
{"type": "command", "command": "fx/presetSet", "trackIdx": 1, "fxIdx": 0, "presetIdx": 5, "id": "1"}
```

---

### UI Concept

**Minimal (MVP):** Add to track long-press menu or dedicated FX panel.

```txt
┌─────────────────────────────────────────────────────┐
│ Guitar                                    [FX ▼]    │
├─────────────────────────────────────────────────────┤
│                                                     │
│              Neural DSP Archetype Gojira            │
│                                                     │
│    ┌──────┐    "My Clean Tone"      ┌──────┐       │
│    │  ◀   │        3 of 12          │  ▶   │       │
│    │ PREV │                         │ NEXT │       │
│    └──────┘                         └──────┘       │
│                                                     │
│               [Modified ●]                          │
└─────────────────────────────────────────────────────┘
```

**FX selector dropdown** when track has multiple plugins. Shows first FX by default.

---

### Implementation Checklist

#### Extension ✅ COMPLETE

**Prerequisites:**
- [x] Add `TrackFX_GetCount` to get FX count per track
- [x] Add `TrackFX_GetFXName` to get plugin names
- [x] Add `TrackFX_GetPresetIndex` for preset state
- [x] Add `TrackFX_GetPreset` for preset name + modified flag

**State polling:**
- [x] Add `fx` array to track state
- [x] Poll FX state at 5Hz (MEDIUM tier), merge into 30Hz track events
- [x] Skip FX API calls for tracks with 0 FX (optimization)

**Commands:**
- [x] Add `fx/presetNext` handler using `TrackFX_NavigatePresets(+1)`
- [x] Add `fx/presetPrev` handler using `TrackFX_NavigatePresets(-1)`
- [x] Add `fx/presetSet` handler using `TrackFX_SetPresetByIndex`

**Limits:** 64 FX per track, 128 char name limit. See `extension/API.md` for protocol details.

#### Frontend

- [ ] Add FX state to Track type
- [ ] Create FX preset UI component
- [ ] Integrate with track selection or dedicated panel
- [ ] Handle "no presets" case (show guidance to save REAPER presets)

---

### Gotchas

**Plugins with internal browsers:** Will show 0 or very few presets. Detect and show:
> "This plugin manages presets internally. Save your favorite sounds as REAPER presets to control them from Reamo, or use Quick Actions with MIDI CC."

**Undo points:** Each `TrackFX_SetPreset` creates an undo point. Consider debouncing for rapid clicking.

**Performance:** Don't poll FX state every 30ms. Poll on:
- Track selection change
- `CSURF_EXT_TRACKFX_PRESET_CHANGED` notification
- Manual refresh

---

## View Switcher

> **Full specification:** [features/VIEW_SWITCHER_FEATURE.md](features/VIEW_SWITCHER_FEATURE.md)

Core navigation architecture for Reamo. Tab bar with persistent transport.

**Layout:**
```
┌─────────────────────────────────────────────────────────┐
│                   ACTIVE VIEW AREA                      │
├─────────────────────────────────────────────────────────┤
│Studio│Timeline│ Mixer │ Clock │ Cues │ Actions │ Notes │ ← Tab bar
├─────────────────────────────────────────────────────────┤
│  ◄◄  │  ▶/❚❚  │  ⏹  │  ⏺  │    17.3.2    │  120 BPM  │ ← Persistent transport
└─────────────────────────────────────────────────────────┘
```

**Key principles:**
- Persistent transport bar at bottom of ALL views (can hide via Full Screen Mode)
- Tab bar above transport (7 purpose-built views, no hamburger menus)
- Studio as default — the "radically simple" all-in-one view
- Per-device view memory via localStorage
- Full Screen Mode — double-tap to hide tab bar + transport for dedicated-device setups

**The seven views:**

| View | Purpose |
|------|---------|
| **Studio** | All-in-one: transport + mixer + regions (default, current layout) |
| **Timeline** | Visual arrangement with regions, markers, playhead |
| **Mixer** | Faders, meters, track control |
| **Clock** | Big transport, BPM, bar.beat (80-100pt buttons) |
| **Cues** | Region list, playlist mode |
| **Actions** | User-configurable quick action buttons |
| **Notes** | Project notes, session metadata |

**Implementation:** Frontend-only. No protocol changes.

---

## Cue List

> **Full specification:** [features/CUE_LIST_FEATURE.md](features/CUE_LIST_FEATURE.md)

Vertical list view of regions for quick tap-to-jump navigation, plus playlist mode with loop counts for arrangement sketching and live performance.

**Key capabilities:**
- Navigation mode: Tap region → jump to position
- Playlist mode: Define sequence with loop counts, auto-advance on region end
- SWS import: Read-only import of existing SWS Region Playlists from .RPP files
- Arrangement sketching: "What would Verse x4, Chorus x2 sound like?" without duplicating regions

**Implementation:** Requires extension work for playlist playback engine (boundary detection, seeking). Frontend-only for basic navigation mode.

---

## Items Mode

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

**Architecture decision:** Backend sends ALL items (no server-side filtering). Frontend filters by time selection as needed. This enables LOD overview (colored bars showing "stuff here") and avoids round-trips when switching views. Time selection is obtained from the transport event, not the items event.

> See [ITEMS_MODE_FEATURE.md](ITEMS_MODE_FEATURE.md) for detailed implementation spec.

### Supported Item Actions

| Action | Purpose | REAPER API |
|--------|---------|------------|
| Switch take | Navigate takes | `SetMediaItemInfo_Value(item, "I_CURTAKE", index)` |
| Delete take | Remove bad take | `Main_OnCommand(40129, 0)` |
| Crop to active | "This is the keeper" | `Main_OnCommand(40131, 0)` |
| Move item | Nudge position | `SetMediaItemInfo_Value(item, "D_POSITION", pos)` |
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

## Track Management

> **Full specification:** [features/TRACK_MANAGEMENT_FEATURE.md](features/TRACK_MANAGEMENT_FEATURE.md)
> **Backend plan:** [TRACK_MANAGEMENT_BACKEND_PLAN.md](TRACK_MANAGEMENT_BACKEND_PLAN.md)

Extend track control beyond mixer operations to full track lifecycle management.

**Key capabilities:**
- Rename tracks (inline or via context menu)
- Create new tracks (with optional name, insert position)
- Duplicate tracks (copies settings, FX, items)
- Delete tracks (with confirmation for non-empty)
- Folder-aware display (indentation, collapse/expand)

**Backend: DONE ✅**
- [x] `track/rename` command (master track protected)
- [x] `track/create` command with optional name and afterTrackIdx
- [x] `track/duplicate` command (undo block + action 40062)
- [x] `track/duplicateSelected` command (action 40062 on selection)
- [x] `track/delete` command (master track protected)
- [x] `track/deleteSelected` command (action 40005 on selection)
- [x] `folderDepth` field in tracks event

**Frontend: PENDING**
- [ ] Track context menu (long-press trigger)
- [ ] Rename modal or inline edit
- [ ] New track button/FAB
- [ ] Folder indentation in track list
- [ ] Optional: folder collapse/expand toggle

---

## Send Control

> **Full specification:** [features/SEND_CONTROL_FEATURE.md](features/SEND_CONTROL_FEATURE.md)

Expose track send levels for aux/cue bus control. Targets the 5-10% of users with DAW-based cue systems who need to adjust headphone mixes remotely.

**Key capabilities:**
- View sends per track (destination name, level, mute state)
- Adjust send level via fader
- Mute/unmute individual sends
- Per-track expandable panel UI (long-press track → slide-up panel)

**Out of scope:** Hardware output routing (never adjusted mid-session), creating/deleting sends (setup-time operation), MIDI routing.

**Backend: DONE**
- [x] Send data polling at 5Hz (destination name, volume, mute state, mode)
- [x] `send/setVolume` command (uses CSurf_OnSendVolumeChange for undo coalescing)
- [x] `send/setMute` command
- [x] Sends included in tracks event payload

**Frontend: PENDING**
- [ ] SendPanel component (slide-up panel UI)
- [ ] Integration with track long-press gesture

---

## Extension Performance Optimizations

### Context: 30Hz Polling is Fine

REAPER's timer callback system runs at ~30Hz on the main UI thread—this is the **designed operating point** for the CSurf (Control Surface) system. Most REAPER API getter calls (`GetTrack()`, `GetPlayState()`, `GetMediaTrackInfo_Value()`) are lightweight pointer lookups designed for control surfaces polling at this rate.

**Key insight**: Main-thread polling has no direct interaction with audio rendering. The audio thread has hard deadlines of 1.4-11.6ms (depending on buffer size), while extensions run on the UI thread with ~16ms soft deadlines. Extension overhead does not cause audio glitches unless callbacks exceed ~10ms.

Testing by extension developers showed 100 concurrent `defer()` scripts—each executing at 30Hz—produced no measurable performance impact.

---

### Current Implementation Strengths

The extension already follows real-time best practices:

| Pattern | Status | Location |
|---------|--------|----------|
| Fixed-size stack buffers | ✅ | All state modules use `[N]T` arrays |
| Change detection before broadcast | ✅ | `eql()` comparisons in each state module |
| `GetProjectStateChangeCount` | ✅ | `project.zig:59` |
| Async WebSocket (separate thread) | ✅ | `ws_server.zig` with mutex-protected queue |
| Zero allocations per callback | ✅ | All buffers pre-allocated |

**Target metrics** (based on professional audio software):

| Metric | Target | Current (estimated) |
|--------|--------|---------------------|
| Average callback duration | < 1ms | Likely < 0.5ms |
| Worst-case callback | < 10ms | Unknown (needs profiling) |
| Baseline CPU | < 0.5% | Unknown |
| Memory allocations/callback | 0 | 0 ✅ |

---

### Phase 1: Idle When No Clients (Trivial)

**Priority: Low** — Valid optimization but minimal real-world impact.

Skip all polling when no WebSocket clients are connected:

```zig
// In processTimerCallback, after command processing:
if (shared_state.clientCount() == 0) return;
```

**Trade-offs:**
- First client sees ~30ms delay to first update
- Could add immediate poll on connect if latency matters
- Saves CPU when frontend isn't running (user at computer, not using tablet)

**Verdict**: 1-line change, worth doing, but not urgent.

---

### Phase 2: Tiered Polling Rates (Moderate)

**Priority: Medium** — Easy wins with measurable impact.

Not all state needs 30Hz updates. Professional audio software uses tiered rates:

| Data Type | Current Rate | Optimal Rate | Rationale |
|-----------|--------------|--------------|-----------|
| Meters | 30Hz | 30-60Hz | Smooth animation required |
| Transport position | 30Hz | 30Hz | Playhead smoothness |
| Transport state | 30Hz | 10Hz or event | Changes feel instant at 100ms |
| Tracks (vol/pan/mute) | 30Hz | 30Hz | Fader responsiveness |
| Markers/Regions | 30Hz | 5Hz | Rarely change during playback |
| Items | 30Hz | 5Hz | Rarely change during playback |
| Project (undo/redo) | 30Hz | 5Hz | User doesn't need instant undo label |
| Tempo map | 30Hz | 1Hz or event | Almost never changes |

**Implementation**: Use frame counters:

```zig
var g_frame_counter: u32 = 0;

fn processTimerCallback() {
    g_frame_counter +%= 1;

    // Every frame (30Hz)
    pollTransport();
    pollTracks();
    pollMetering();

    // Every 6th frame (~5Hz)
    if (g_frame_counter % 6 == 0) {
        pollMarkers();
        pollItems();
        pollProject();
    }

    // Every 30th frame (~1Hz)
    if (g_frame_counter % 30 == 0) {
        pollTempoMap();
    }
}
```

**Adaptive idle detection**: When `GetPlayState()` returns stopped and no recent changes, extend poll interval to 100ms. Resume 30Hz when transport starts or user interaction occurs. The mvMeter2 plugin documented **50% CPU reduction** from this single optimization.

---

### Phase 3: CSurf Hybrid Architecture (Significant)

**Priority: Low** — Large refactor, but offers 50%+ CPU reduction.

REAPER's CSurf (Control Surface) interface provides **push notifications** for most track-level state changes, eliminating redundant polling:

| CSurf Callback | Replaces Polling For |
|----------------|---------------------|
| `SetPlayState(play, pause, rec)` | Transport state |
| `SetSurfaceVolume(track, vol)` | Track volume |
| `SetSurfacePan(track, pan)` | Track pan |
| `SetSurfaceMute(track, mute)` | Track mute |
| `SetSurfaceSolo(track, solo)` | Track solo |
| `SetTrackListChange()` | Track add/remove/reorder |
| `Extended(CSURF_EXT_SETPROJECTMARKERCHANGE)` | Marker/region changes |
| `Extended(CSURF_EXT_SETBPMANDPLAYRATE)` | Tempo/BPM changes |
| `Extended(CSURF_EXT_SETFXENABLED)` | FX bypass state |

**CSurf gaps** (still require polling):
- Media item changes (add/delete/move/resize)
- Cursor position
- Time selection
- Envelope edits
- Meter values (always polled)
- Zoom/scroll

**The SWS Pattern**: Callbacks set dirty flags; `Run()` processes in batches:

```cpp
// Callback (called by REAPER when state changes)
void SetSurfaceVolume(MediaTrack* track, double volume) {
    m_tracksDirty = true;  // Flag for Run() to process
}

// Run() called at 30Hz
void Run() {
    if (m_tracksDirty) {
        m_tracksDirty = false;
        BroadcastTrackState();
    }
    // Poll for state CSurf doesn't notify...
    PollItems();
    PollCursor();
}
```

**Implementation requirements**:
1. Implement `IReaperControlSurface` interface in Zig (or C wrapper)
2. Register via `plugin_register("csurf_inst", &surface)`
3. Convert polling to dirty-flag pattern
4. Maintain polling for CSurf gaps

**Why this is low priority**: The current 30Hz polling is within REAPER's designed parameters. CSurf hybrid is a significant refactor for gains that may not be perceptible to users. Worth considering if profiling shows actual CPU concerns.

---

### Profiling Strategy

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

### API Calls to Avoid in Polling Loops

These are expensive and should only be called on-demand:

| Function | Why Expensive | Alternative |
|----------|---------------|-------------|
| `GetTrackStateChunk()` | Serializes entire track to XML | Don't use for polling |
| `AudioAccessor` functions | Buffer operations, main-thread-only | Call only for `item/getPeaks` |
| `CalcMediaSrcLoudness()` | Full render-based analysis | Never in polling loop |
| `EnumTrackMIDIProgramNames()` | String enumeration | Cache on demand |

---

### Summary: Recommended Approach

1. **Now**: Do nothing. Current implementation is solid and within REAPER's design parameters.

2. **If profiling shows concerns**: Implement Phase 2 (tiered polling). Easy wins, measurable impact.

3. **If Phase 2 insufficient**: Implement Phase 1 (idle when no clients). Trivial change.

4. **Future consideration**: Phase 3 (CSurf hybrid) only if the extension needs to scale to larger projects or lower-power devices.

The SWS Extension—the gold standard for REAPER extension performance—uses the CSurf hybrid pattern and is described by users as having "no noticeable CPU impact." That's the north star, but our current polling-only approach is likely already invisible to users

## Project Notes Support ✅ COMPLETE

Project notes are useful for session-level metadata: "Client: Acme Records", "Reference tempo: 128 BPM before we slowed it down", "TODO: re-record verse 2 vocals", etc. Accessible from the Notes view in the WebUI.

---

### REAPER API

```c
void GetSetProjectNotes(
    ReaProject* proj,      // NULL for active project
    bool set,              // false = get, true = set
    char* notesNeedBig,    // buffer for notes
    int notesNeedBig_sz    // buffer size
);
```

**Key characteristics:**

- Returns `void` — no way to query required size
- No documented max length (practically unbounded, stored as text in RPP)
- Notes may contain newlines (`\n`, `\r\n`, or `\r` depending on platform/history)
- Empty project notes = empty string (not null)

---

### Buffer Strategy

Since the API doesn't report truncation, use iterative resizing. The heuristic: if `strlen(result) >= bufferSize - 1`, the content was likely truncated.

```zig
fn getProjectNotes(allocator: Allocator) ![:0]u8 {
    var size: usize = 4096; // Start reasonable

    while (size <= 1024 * 1024) { // Cap at 1MB
        const buf = try allocator.allocSentinel(u8, size - 1, 0);
        errdefer allocator.free(buf);

        @memset(buf, 0);
        api.GetSetProjectNotes(null, false, buf.ptr, @intCast(size));

        const len = std.mem.indexOfScalar(u8, buf, 0) orelse size - 1;

        // If we didn't fill the buffer, we got everything
        if (len < size - 1) {
            // Optionally shrink to actual size
            if (allocator.resize(buf, len + 1)) |resized| {
                return resized[0..len :0];
            }
            return buf[0..len :0];
        }

        // Likely truncated — double and retry
        allocator.free(buf);
        size *= 2;
    }

    return error.NotesTooLarge;
}

fn setProjectNotes(notes: [:0]const u8) void {
    // Cast away const - REAPER doesn't modify when set=true, but signature isn't const
    const ptr: [*]u8 = @constCast(notes.ptr);
    api.GetSetProjectNotes(null, true, ptr, @intCast(notes.len + 1));
}
```

---

### Protocol Design

**Decision: On-demand, not polled.**

Unlike transport (continuous) or regions (polled for external changes), project notes:

- Change infrequently
- Can be large
- Don't need real-time sync

Use request/response pattern instead of continuous polling.

#### Messages

**Client → Server: Request notes**

```json
{
  "type": "getProjectNotes"
}
```

**Server → Client: Notes response**

```json
{
  "type": "projectNotes",
  "notes": "Session notes here...\nLine 2\nLine 3"
}
```

**Client → Server: Set notes**

```json
{
  "type": "setProjectNotes",
  "notes": "Updated notes content"
}
```

**Server → Client: Confirmation**

```json
{
  "type": "projectNotesSet",
  "success": true
}
```

Optionally, after successful set, server can echo back the saved notes (re-fetched from REAPER) to confirm round-trip integrity.

---

### UI Concept

**Access:** Button in transport bar or settings/menu area: `[📝]` or `[Notes]`

**Modal/Panel:**

```txt
┌─────────────────────────────────────────────────────┐
│ Project Notes                              [×]      │
├─────────────────────────────────────────────────────┤
│ ┌─────────────────────────────────────────────────┐ │
│ │ Client: Acme Records                            │ │
│ │ Session date: 2024-01-15                        │ │
│ │                                                 │ │
│ │ TODO:                                           │ │
│ │ - Re-record verse 2 vocals                      │ │
│ │ - Fix timing on bridge guitar                   │ │
│ │                                                 │ │
│ │                                                 │ │
│ └─────────────────────────────────────────────────┘ │
├─────────────────────────────────────────────────────┤
│                           [Cancel]  [Save]          │
└─────────────────────────────────────────────────────┘
```

**Behavior:**

- Opens modal or slide-out panel
- Fetches current notes on open (shows loading state)
- Textarea for editing (auto-resize or fixed with scroll)
- Cancel = discard local changes, close
- Save = send to server, wait for confirmation, close
- Dirty indicator if local changes exist (prompt to confirm before closing)

---

### Implementation Checklist

#### Extension

- [ ] Add REAPER API import: `GetSetProjectNotes`
- [ ] Implement get function with iterative buffer resize strategy
- [ ] Implement set function
- [ ] Add WebSocket message handler for `getProjectNotes` request
- [ ] Add WebSocket message handler for `setProjectNotes` request
- [ ] Send `projectNotes` response with fetched content
- [ ] Send `projectNotesSet` confirmation after successful write

#### Shared Types

```typescript
// Server → Client
interface ProjectNotesEvent {
  type: 'projectNotes';
  notes: string;
}

interface ProjectNotesSetEvent {
  type: 'projectNotesSet';
  success: boolean;
  error?: string;
}

// Client → Server
interface GetProjectNotesRequest {
  type: 'getProjectNotes';
}

interface SetProjectNotesRequest {
  type: 'setProjectNotes';
  notes: string;
}
```

#### Frontend State

**Required state fields:**

| Field | Type | Purpose |
|-------|------|---------|
| `serverNotes` | `string \| null` | Last value fetched from server (`null` = never fetched) |
| `localNotes` | `string \| null` | Current editor content (`null` = editor closed) |
| `isLoading` | `boolean` | Fetch request in progress |
| `isSaving` | `boolean` | Save request in progress |
| `error` | `string \| null` | Last error message |

**Derived state:**

| Selector | Logic | Purpose |
|----------|-------|---------|
| `isDirty` | `localNotes !== null && localNotes !== serverNotes` | Unsaved changes exist |

#### Frontend Functionality

**Required behaviors:**

- Send `getProjectNotes` request and track loading state
- Receive `projectNotes` message, store server value, initialize local editor if open
- Track local edits in state (separate from server value)
- Send `setProjectNotes` request with local content, track saving state
- Receive `projectNotesSet` confirmation, sync local/server state, clear saving
- Discard local changes (reset editor to server value or close)
- Handle and display errors

#### UI Components

- [ ] Trigger button/icon in toolbar or menu
- [ ] Modal or panel container with open/close handling
- [ ] Textarea with controlled state binding
- [ ] Loading indicator during fetch
- [ ] Saving indicator during save (disable inputs)
- [ ] Dirty state indicator
- [ ] Confirmation prompt when closing with unsaved changes
- [ ] Error display

#### WebSocket Integration

- [ ] Handle outgoing `getProjectNotes` request
- [ ] Handle outgoing `setProjectNotes` request
- [ ] Handle incoming `projectNotes` message
- [ ] Handle incoming `projectNotesSet` message

---

### Gotchas & Edge Cases

#### Newline Normalization

REAPER may store `\r\n` (Windows) or `\r` (old Mac). Normalize to `\n` on receive for consistent textarea behavior:

```typescript
// On receive
const normalized = notes.replace(/\r\n?/g, '\n');
```

REAPER is tolerant of mixed newlines, so conversion on save is optional.

#### Empty vs Null

| State | Meaning | UI |
|-------|---------|-----|
| `serverNotes === null` | Never fetched | Show loading or fetch prompt |
| `serverNotes === ""` | Fetched, project has no notes | Show empty textarea |
| `localNotes === null` | Editor not open | N/A |
| `localNotes === ""` | User cleared all content | Empty textarea, dirty if server had content |

#### Large Notes

If someone pastes a very large amount of text:

- **Frontend:** Consider warning if content exceeds ~100KB before save
- **Extension:** Cap at 1MB, return error if exceeded
- **WebSocket:** Large messages may need consideration depending on server config

#### Concurrent Edits

If notes are open in WebUI and someone edits directly in REAPER:

**Simple approach (acceptable for single-user DAW):** Last-write-wins.

**Better UX:** Track the server value when editor was opened. On save, compare current server value — if changed, warn user:

> "Notes were modified elsewhere. Overwrite?"

Options: Overwrite / Discard my changes / Cancel

---

### Future Enhancements

- **Markdown preview:** Toggle between edit mode and rendered view
- **Auto-save draft:** LocalStorage backup of unsaved changes (survives browser refresh)
- **Timestamps:** Display "Last modified: 2 hours ago" if REAPER exposes this (it doesn't natively, but could track in extension)
- **Search:** Ctrl+F / Cmd+F within notes (browser native may suffice for textarea)
- **Character/word count:** Footer showing content length

---

## Minor Enhancements

Small additions that don't warrant full feature specs.

---

### Project Dirty Flag ✅ COMPLETE

Track whether project has unsaved changes to provide visual feedback on save button.

**Backend: DONE**
- [x] Added `IsProjectDirty` to REAPER API bindings
- [x] Added `isDirty` field to project event payload

**Frontend: DONE**
- [x] Show indicator on save button when `isDirty` is true

---

### SMPTE Timecode Display

Allow time display to cycle between formats for different workflows.

**Display modes:**

| Mode | Format | Use Case |
|------|--------|----------|
| Time | `0:32.451` | General |
| Bars.Beats | `17.3.2` | Music production |
| SMPTE | `00:00:32:13` | Film scoring |

**Backend: DONE**

- [x] Added `TimeMap_curFrameRate` to REAPER API bindings
- [x] Added `FrameRateInfo` type with `frame_rate: f64` and `drop_frame: bool`
- [x] Added `getFrameRate()` to `RealBackend` and `MockBackend`
- [x] Added `frameRate` and `dropFrame` fields to project event
- [x] Updated API.md with field documentation and SMPTE conversion code

**Frontend (TODO):**
- [ ] Store `timeDisplayMode` in localStorage
- [ ] Tap time display to cycle modes (Time → Bars.Beats → SMPTE → Time)
- [ ] Convert seconds to SMPTE using `secondsToSMPTE()` helper (see API.md)
- [ ] Use semicolon separator for drop-frame timecode (29.97fps/59.94fps)
