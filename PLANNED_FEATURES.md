# Planned Features

## Table of Contents (Priority Order)

1. [Public Release](#public-release) — Cross-platform builds and GitHub distribution
2. [View Switcher](#view-switcher) — Switch between Edit, Transport, and Mixer views *(quick win, frontend-only)*
3. [Items Mode](#items-mode) — View/manage recorded takes without leaving the instrument
4. [Tempo Marker Support](#tempo-marker-support) — Respect tempo map during playback *(easy fix)*
5. [FX Preset Switching](#fx-preset-switching) — Navigate REAPER-saved presets from tablet
6. [Extension Performance Optimizations](#extension-performance-optimizations) — Idle when no clients

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

#### Extension

**Prerequisites:**
- [ ] Add `TrackFX_GetCount` to get FX count per track
- [ ] Add `TrackFX_GetFXName` to get plugin names
- [ ] Add `TrackFX_GetPresetIndex` for preset state
- [ ] Add `TrackFX_GetPreset` for preset name + modified flag

**State polling:**
- [ ] Add `fx` array to track state
- [ ] Poll FX state on track change (not every 30ms — too expensive)
- [ ] Consider `CSURF_EXT_TRACKFX_PRESET_CHANGED` for notifications

**Commands:**
- [ ] Add `fx/presetNext` handler using `TrackFX_NavigatePresets(+1)`
- [ ] Add `fx/presetPrev` handler using `TrackFX_NavigatePresets(-1)`
- [ ] Add `fx/presetSet` handler using `TrackFX_SetPresetByIndex`

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

### Rationale

Different contexts call for different interfaces. When recording a verse, you want full timeline visibility with regions and markers. When performing or running down a song with the band, you want big transport controls visible from across the room. When mixing, you want as many faders on screen as possible.

Rather than forcing users to mount multiple devices (though that's still supported via WebSocket), a simple view switcher lets one device adapt to the current workflow.

**Key insight:** This is frontend-only. No protocol changes, no extension work. Just reorganizing existing components.

---

### Views

| View | Purpose | Components |
|------|---------|------------|
| **Edit** (default) | Songwriting workflow | Timeline + regions + markers + mixer + transport |
| **Transport** | Performer/big display | Large play/stop/record, BPM, bar.beat counter, minimal else |
| **Mixer** | Mixing focus | Full-width faders, more tracks visible, compact transport |

---

### UI Concept

**Access:** Hamburger menu or bottom nav bar.

```txt
┌─────────────────────────────────────────────────────┐
│ ☰ Reamo                              [Edit ▼]       │
├─────────────────────────────────────────────────────┤
│                                                     │
│  (current view content)                             │
│                                                     │
└─────────────────────────────────────────────────────┘
```

**Dropdown options:**
- Edit View (timeline + mixer)
- Transport View (big controls)
- Mixer View (faders focus)

---

### Transport View

Large touch targets for stage/studio use. Visible from 10+ feet away.

```txt
┌─────────────────────────────────────────────────────┐
│                                                     │
│                    ♩ = 120 BPM                      │
│                                                     │
│                    17 . 3 . 2                       │
│                  (bar.beat.sub)                     │
│                                                     │
│     ┌───────┐    ┌───────┐    ┌───────┐           │
│     │       │    │       │    │       │           │
│     │  ⏮️   │    │  ⏯️   │    │  ⏹️   │           │
│     │       │    │       │    │       │           │
│     └───────┘    └───────┘    └───────┘           │
│                                                     │
│                   ┌───────┐                         │
│                   │  ⏺️   │                         │
│                   │RECORD │                         │
│                   └───────┘                         │
│                                                     │
│  [Cycle: OFF]  [Click: ON]  [Punch: OFF]           │
└─────────────────────────────────────────────────────┘
```

**Key elements:**
- Huge play/pause button (primary action)
- Big bar.beat display
- BPM display (tap to change)
- Record button with visual feedback
- Status indicators for cycle, click, punch

---

### Mixer View

Maximize fader real estate. More tracks, less timeline.

```txt
┌─────────────────────────────────────────────────────┐
│ ▶ 17.3.2    120 BPM    [⏺]           [Edit ▼]      │
├────┬────┬────┬────┬────┬────┬────┬────┬────┬────┤
│ Drm│ Bas│ Gtr│ Vox│ Syn│ Pad│ FX │ Bus│ ... │    │
│ ▓▓▓│ ▓░░│ ▓▓░│ ▓░░│ ░░░│ ▓▓▓│ ▓▓░│ ▓▓▓│     │    │
│ ║  │ ║  │ ║  │ ║  │ ║  │ ║  │ ║  │ ║  │     │    │
│ ║▓▓│ ║▓░│ ║▓▓│ ║▓░│ ║░░│ ║▓▓│ ║▓▓│ ║▓▓│     │    │
│ ║▓▓│ ║░░│ ║▓░│ ║▓░│ ║░░│ ║▓▓│ ║▓░│ ║▓▓│     │    │
│ M S│ M S│ M S│ M S│ M S│ M S│ M S│ M S│     │    │
└────┴────┴────┴────┴────┴────┴────┴────┴────┴────┘
```

**Key elements:**
- Compact transport strip at top
- Horizontal scrolling for many tracks
- Taller faders (more precision)
- No timeline/regions (use Edit view for that)

---

### Storage

```typescript
const VIEW_STORAGE_KEY = 'reamo_current_view';

type View = 'edit' | 'transport' | 'mixer';

// Load on startup
const savedView = localStorage.getItem(VIEW_STORAGE_KEY) as View || 'edit';

// Save on change
localStorage.setItem(VIEW_STORAGE_KEY, currentView);
```

Per-device storage is appropriate here — each mounted device can have its own preferred view.

---

### Implementation Checklist

#### State

- [ ] Add `currentView: View` to app state (Zustand or context)
- [ ] Load saved view from localStorage on mount
- [ ] Save view to localStorage on change

#### Components

- [ ] `ViewSwitcher` — dropdown/menu for view selection
- [ ] `TransportView` — new component with big controls
- [ ] `MixerView` — new component (or existing mixer in expanded mode)
- [ ] Conditional rendering in `App.tsx` based on `currentView`

#### Transport View specifics

- [ ] Large bar.beat display with prominent font
- [ ] Big touch-friendly transport buttons
- [ ] BPM display (reuse existing tap-tempo logic)
- [ ] Toggle indicators for cycle, click, punch modes

#### Mixer View specifics

- [ ] Compact transport strip
- [ ] Horizontal scroll for tracks
- [ ] Taller faders
- [ ] Hide timeline/region components

---

### Future Enhancements

- **Custom views:** Let users pick which components appear in each view
- **Gesture switching:** Swipe left/right to change views
- **Auto-switch:** Automatically switch to Transport when recording starts
- **Per-project view:** Store preferred view in project EXTSTATE

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

## Tempo Marker Support

### The Problem

The current implementation uses `GetProjectTimeSignature2()` to fetch BPM and time signature, which **only returns project-level defaults**. This ignores tempo markers entirely.

```zig
// Current (BROKEN for tempo markers):
api.getProjectTimeSignature2(null, &bpm, &num, &denom);
// Returns: project default tempo (e.g., 120 BPM, 4/4)
// Ignores: any tempo markers in the project
```

### Correct API

`TimeMap_GetTimeSigAtTime()` returns **both** BPM and time signature at any position, fully respecting the tempo map including linear ramps:

```c
void TimeMap_GetTimeSigAtTime(
    ReaProject* proj,           // NULL for active project
    double time,                // position in seconds
    int* timesig_numOut,        // beats per measure (e.g., 4)
    int* timesig_denomOut,      // note value per beat (e.g., 4)
    double* tempoOut            // BPM at this position
);
```

**Key findings:**
- Single call returns both tempo AND time signature (no need for `TimeMap2_GetDividedBpmAtTime`)
- Handles tempo ramps (linear interpolation) automatically
- Works even with zero tempo markers (returns project defaults)
- At exact marker boundary, returns NEW values (post-marker)

### Gotchas

**Zero time sig values mean "inherit":** When a tempo marker only changes BPM (not time sig), the API returns 0 for timesig_num/denom. Always handle this:

```zig
if (timesig_num == 0) timesig_num = 4;  // Default to 4/4
if (timesig_denom == 0) timesig_denom = 4;
```

**`positionBeats` already works:** Our `TimeMap2_timeToBeats()` call already respects tempo markers - no changes needed there.

### Performance Optimization (Optional)

For projects with sparse tempo changes, cache the next change time to reduce API calls:

```c
static double s_nextChangeTime = -1;
// Only re-query if we've crossed a marker boundary
if (s_nextChangeTime < 0 || currentPos >= s_nextChangeTime) {
    TimeMap_GetTimeSigAtTime(NULL, currentPos, ...);
    s_nextChangeTime = TimeMap2_GetNextChangeTime(NULL, currentPos);
}
```

For tempo ramps, per-frame queries are still needed during interpolation.

### Implementation Checklist

**Extension (`transport.zig`):**
- [ ] Add REAPER API binding for `TimeMap_GetTimeSigAtTime`
- [ ] Replace `getProjectTimeSignature2()` with `TimeMap_GetTimeSigAtTime()`
- [ ] Pass current play position (or edit cursor when stopped)
- [ ] Handle zero timesig values (default to 4/4)

**Frontend:**
- [ ] No changes required - transport event structure unchanged

**Testing:**
- [ ] Create test project with multiple tempo markers
- [ ] Verify BPM updates when cursor crosses tempo marker during playback
- [ ] Verify time signature updates when crossing time sig marker
- [ ] Test tempo ramps (linear interpolation between markers)
- [ ] Test project with no tempo markers (should use defaults)

### Future: Tempo Map Visualization

For displaying the full tempo map in UI:

| Function | Purpose |
|----------|---------|
| `CountTempoTimeSigMarkers(proj)` | Count markers |
| `GetTempoTimeSigMarker(proj, idx, ...)` | Read marker details |
| `FindTempoTimeSigMarker(proj, time)` | Find marker at position |
| `TimeMap2_GetNextChangeTime(proj, time)` | Find next tempo change (-1 if none)

---

## Extension Performance Optimizations

### Idle When No Clients Connected

**The Problem:**
The extension currently polls REAPER state every 30ms regardless of whether any WebSocket clients are connected. This wastes CPU cycles when the frontend isn't running.

**Solution:**
Skip the polling loop when `clientCount == 0`. Only resume polling when a client connects.

**Implementation:**
```zig
// In the 30ms timer callback:
if (server.clientCount() == 0) return; // Early exit, no work to do

// ... existing polling logic ...
```

**Considerations:**
- First client connection may see a slight delay as state is gathered
- Could optionally do a single immediate poll on client connect to minimize latency
- Track `wasIdle` state to log when transitioning between idle/active

## Project Notes Support

Project notes are useful for session-level metadata: "Client: Acme Records", "Reference tempo: 128 BPM before we slowed it down", "TODO: re-record verse 2 vocals", etc. Currently requires going to the computer (`File > Project Notes...`). Should be accessible from the WebUI.

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
